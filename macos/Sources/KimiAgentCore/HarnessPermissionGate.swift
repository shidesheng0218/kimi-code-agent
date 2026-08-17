import Foundation

/// Complete permission input for one Harness tool boundary. It is scoped to
/// an Operation rather than a SwiftUI view so the same decision can be
/// replayed, audited and applied to Child Sessions after restart.
public struct HarnessPermissionContext: Sendable {
  public let taskID: UUID
  public let sessionID: UUID
  public let parentSessionID: UUID?
  public let worktreePath: String?
  public let grants: [CapabilityGrant]
  public let allowedToolIDs: Set<String>
  public let allowPublicWebRead: Bool

  public init(
    taskID: UUID,
    sessionID: UUID,
    parentSessionID: UUID? = nil,
    worktreePath: String? = nil,
    grants: [CapabilityGrant] = [],
    allowedToolIDs: Set<String> = [],
    allowPublicWebRead: Bool = false
  ) {
    self.taskID = taskID
    self.sessionID = sessionID
    self.parentSessionID = parentSessionID
    self.worktreePath = worktreePath?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.grants = grants
    self.allowedToolIDs = allowedToolIDs
    self.allowPublicWebRead = allowPublicWebRead
  }
}

public protocol HarnessPermissionGate: Sendable {
  func evaluate(
    request: ToolExecutionRequest,
    tool: ToolDefinition,
    context: HarnessPermissionContext
  ) async -> PermissionDecision
}

/// The shared permission boundary. It denies invalid resource escape before
/// asking the user, honours durable capability grants, and only auto-allows
/// anonymous public read-only web calls when the task opted into web research.
public struct DefaultHarnessPermissionGate: HarnessPermissionGate, Sendable {
  public init() {}

  public func evaluate(
    request: ToolExecutionRequest,
    tool: ToolDefinition,
    context: HarnessPermissionContext
  ) async -> PermissionDecision {
    if !context.allowedToolIDs.isEmpty && !context.allowedToolIDs.contains(tool.id) {
      return .deny
    }

    if tool.permissionScopes.contains(.writeWorkspace),
       let resource = request.resource,
       !isInsideWorktree(resource, context: context) {
      return .deny
    }

    if context.allowPublicWebRead,
       WebToolApprovalPolicy.canAutoApprovePublicRead(toolID: tool.id, input: request.input) {
      return .allow
    }

    let actions = tool.permissionScopes.map(capabilityAction(for:))
    guard !actions.isEmpty else { return .allow }
    let resource = request.resource ?? context.worktreePath ?? ""
    let subjects = [context.taskID, context.sessionID, context.parentSessionID].compactMap { $0 }
    if !context.grants.isEmpty,
       actions.allSatisfy({ action in
         subjects.contains { subject in
           context.grants.contains { grant in
             grant.allows(action: action, resource: resource.isEmpty ? grant.resource : resource, subjectID: subject)
           }
         }
       }) {
      return .allow
    }

    return .ask
  }

  private func isInsideWorktree(_ resource: String, context: HarnessPermissionContext) -> Bool {
    guard let root = context.worktreePath, !root.isEmpty else { return false }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    let targetURL = URL(fileURLWithPath: resource).standardizedFileURL
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    return targetURL.path == rootURL.path || targetURL.path.hasPrefix(rootPath)
  }

  private func capabilityAction(for scope: PermissionScope) -> CapabilityAction {
    switch scope {
    case .readWorkspace: .read
    case .writeWorkspace: .write
    case .executeCommand: .execute
    case .network: .network
    case .browser: .browser
    case .systemComputerUse: .computerUse
    case .destructiveOperation: .destructive
    }
  }
}

/// Existing project/user policy resolvers can resolve only the remaining ask
/// state; the boundary can never be bypassed for a denied worktree escape or
/// forbidden child tool.
public struct LayeredHarnessPermissionGate: HarnessPermissionGate, Sendable {
  public let boundary: DefaultHarnessPermissionGate
  public let fallback: any ToolPermissionResolver

  public init(
    boundary: DefaultHarnessPermissionGate = DefaultHarnessPermissionGate(),
    fallback: any ToolPermissionResolver
  ) {
    self.boundary = boundary
    self.fallback = fallback
  }

  public func evaluate(
    request: ToolExecutionRequest,
    tool: ToolDefinition,
    context: HarnessPermissionContext
  ) async -> PermissionDecision {
    let boundaryDecision = await boundary.evaluate(request: request, tool: tool, context: context)
    return boundaryDecision == .ask
      ? await fallback.resolve(request: request, definition: tool)
      : boundaryDecision
  }
}
