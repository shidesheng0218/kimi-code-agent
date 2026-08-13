// Swift 桥接层：TypeScript 动态规划器适配器
// macos/Sources/KimiAgentCore/DynamicPlanningBridge.swift

import Foundation

public struct DynamicPlanRequest: Codable, Sendable {
    public let userGoal: String
    public let projectPath: String
    public let existingContext: String?
    public let constraints: [String]?
    public let mode: String

    public init(
        userGoal: String,
        projectPath: String,
        existingContext: String? = nil,
        constraints: [String]? = nil,
        mode: String
    ) {
        self.userGoal = userGoal
        self.projectPath = projectPath
        self.existingContext = existingContext
        self.constraints = constraints
        self.mode = mode
    }
}

public struct DynamicPlanResponse: Codable, Sendable {
    public let summary: String
    public let rationale: String
    public let subtasks: [DynamicSubtask]
    public let risks: [String]
    public let assumptions: [String]
}

public struct DynamicSubtask: Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let agentKind: String
    public let dependencies: [String]
    public let estimatedComplexity: String
    public let toolsRequired: [String]
    public let isolation: String
    public let acceptanceCriteria: [String]
    public let verificationSteps: [String]
}

/// TypeScript 动态规划器桥接
public actor DynamicPlanningBridge {
    private let nodeExecutable: String
    private let runtimePath: String
    private let vault: CredentialVault

    public init(nodeExecutable: String? = nil, runtimePath: String? = nil, vault: CredentialVault) {
        // 默认使用应用包中的 node
        if let customNode = nodeExecutable {
            self.nodeExecutable = customNode
        } else {
            let bundle = Bundle.main
            let resourcePath = bundle.resourcePath ?? FileManager.default.currentDirectoryPath
            self.nodeExecutable = "\(resourcePath)/node-arm64"
        }
        // 默认使用项目根目录
        self.runtimePath = runtimePath ?? FileManager.default.currentDirectoryPath
        self.vault = vault
    }

    public func generatePlan(request: DynamicPlanRequest) async throws -> DynamicPlanResponse {
        // 调用 TypeScript 层的动态规划器
        // 在应用包内查找脚本
        let bundle = Bundle.main
        let resourcePath = bundle.resourcePath ?? FileManager.default.currentDirectoryPath
        let scriptPath = "\(resourcePath)/KimiAgentDesktop_KimiAgentDesktop.bundle/Resources/dynamicPlanningCLI.bundle.cjs"

        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        let requestJSON = String(data: requestData, encoding: .utf8)!

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodeExecutable)
        process.arguments = [scriptPath, requestJSON]

        // 从 vault 读取 API 密钥并设置环境变量
        var environment = ProcessInfo.processInfo.environment
        if let apiKey = try? vault.read(key: "kimi.runtime.identity.apiKey") {
            environment["KIMI_API_KEY"] = apiKey
        }

        // 设置 Kimi SDK 使用应用包中的 kimi.mjs
        let kimiScriptPath = "\(resourcePath)/KimiAgentDesktop_KimiAgentDesktop.bundle/Resources/kimi.mjs"

        // 创建一个符号链接或环境变量，让 SDK 找到 kimi
        // SDK 会执行 'kimi' 命令，我们需要让它指向 kimi.mjs
        environment["PATH"] = "\(resourcePath)/KimiAgentDesktop_KimiAgentDesktop.bundle/Resources:\(environment["PATH"] ?? "")"

        // 不设置 KIMI_SCRIPT，让 SDK 使用默认的 'kimi' 命令
        // 但我们已经把包含 kimi.mjs 的目录加入 PATH

        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "DynamicPlanning", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Dynamic planning failed: \(errorMessage)"
            ])
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        return try decoder.decode(DynamicPlanResponse.self, from: outputData)
    }
}

/// 将动态计划转换为 AgentOrchestrationPlan
extension AgentOrchestrator {
    public static func makeDynamicPlan(
        taskID: UUID,
        userGoal: String,
        projectPath: String,
        mode: TaskMode,
        sessionID: UUID = UUID(),
        model: String? = nil,
        bridge: DynamicPlanningBridge
    ) async throws -> AgentOrchestrationPlan {
        // 准备请求
        let modeString: String
        switch mode {
        case .plan: modeString = "plan"
        case .edit: modeString = "edit"
        case .agent: modeString = "agent"
        default: modeString = "agent"
        }

        let request = DynamicPlanRequest(
            userGoal: userGoal,
            projectPath: projectPath,
            mode: modeString
        )

        // 调用 TypeScript 层生成计划
        let response = try await bridge.generatePlan(request: request)

        // 转换为 AgentRun 列表
        var idMapping: [String: UUID] = [:]
        var runs: [AgentRun] = []

        for subtask in response.subtasks {
            let runID = UUID()
            idMapping[subtask.id] = runID

            // 映射 agentKind
            let kind = AgentKind(rawValue: subtask.agentKind) ?? .implement

            // 映射 isolation
            let isolation: AgentIsolation
            switch subtask.isolation {
            case "readOnlySnapshot": isolation = .readOnlySnapshot
            case "worktree": isolation = .worktree
            case "sharedWorkspace": isolation = .sharedWorkspace
            default: isolation = .readOnlySnapshot
            }

            // 映射 permissionMode
            let permissionMode: AgentPermissionMode
            if isolation == .readOnlySnapshot {
                permissionMode = .readOnly
            } else if subtask.toolsRequired.contains("write") || subtask.toolsRequired.contains("shell") {
                permissionMode = .interactive
            } else {
                permissionMode = .readOnly
            }

            let definition = AgentDefinition(
                name: subtask.id,
                description: subtask.description,
                kind: kind,
                model: model,
                allowedTools: subtask.toolsRequired,
                deniedTools: [],
                permissionMode: permissionMode,
                skills: [],
                mcpServers: [],
                hooks: [],
                isolation: isolation,
                maxTurns: subtask.estimatedComplexity == "high" ? 15 : 10
            )

            let run = AgentRun(
                id: runID,
                parentSessionID: sessionID,
                taskID: taskID,
                definition: definition,
                dependencies: [], // 稍后填充
                state: .queued,
                progress: 0
            )

            runs.append(run)
        }

        // 填充依赖关系
        for (index, subtask) in response.subtasks.enumerated() {
            let dependencies = subtask.dependencies.compactMap { idMapping[$0] }
            runs[index].dependencies = dependencies
        }

        return AgentOrchestrationPlan(
            taskID: taskID,
            sessionID: sessionID,
            runs: runs
        )
    }
}
