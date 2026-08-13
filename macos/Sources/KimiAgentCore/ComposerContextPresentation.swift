import Foundation

public struct ComposerContextPresentation: Equatable, Sendable {
  public let chips: [ComposerContextChip]

  public init(workspacePath: String?, task: AgentTask?) {
    var chips: [ComposerContextChip] = [
      ComposerContextChip(
        title: "Local",
        surfaceTitle: "本地环境",
        surfaceDescription: "检查 Kimi Runtime、Computer Use 权限和本机执行环境。",
        symbol: "laptopcomputer",
        action: .runDiagnostics,
        menuItems: [
          ComposerContextMenuItem(
            title: "检查 Kimi Runtime",
            symbol: "cpu",
            action: .runDiagnostics
          ),
          ComposerContextMenuItem(
            title: "检查 Computer Use 权限",
            symbol: "macwindow",
            action: .runComputerUseDiagnostics
          )
        ]
      )
    ]

    if let workspacePath {
      chips.append(
        ComposerContextChip(
          title: URL(fileURLWithPath: workspacePath).lastPathComponent,
          surfaceTitle: "当前项目",
          surfaceDescription: workspacePath,
          symbol: "folder",
          action: .revealWorkspace(path: workspacePath),
          menuItems: [
            ComposerContextMenuItem(
              title: "在 Finder 中显示",
              symbol: "finder",
              action: .revealWorkspace(path: workspacePath)
            ),
            ComposerContextMenuItem(
              title: "复制项目路径",
              symbol: "doc.on.doc",
              action: .copyText(workspacePath)
            )
          ]
        )
      )
    }

    if let branch = task?.branch {
      chips.append(
        ComposerContextChip(
          title: branch,
          surfaceTitle: "当前分支",
          surfaceDescription: "任务会在隔离 Worktree 中执行，审阅后再合并回主分支。",
          symbol: "arrow.triangle.branch",
          action: .copyText(branch),
          menuItems: [
            ComposerContextMenuItem(
              title: "复制分支名",
              symbol: "doc.on.doc",
              action: .copyText(branch)
            )
          ]
        )
      )
    }

    if workspacePath != nil && task?.mode.isReadOnly != true {
      let worktreePath = task?.worktreePath
      chips.append(
        ComposerContextChip(
          title: worktreePath == nil ? "Worktree" : "Worktree 已连接",
          surfaceTitle: "隔离 Worktree",
          surfaceDescription: worktreePath ?? "运行 Edit / Agent 后会自动创建隔离 Worktree。",
          symbol: "square.stack.3d.up",
          action: .revealWorktree(path: worktreePath),
          menuItems: worktreePath.map {
            [
              ComposerContextMenuItem(
                title: "在 Finder 中显示",
                symbol: "finder",
                action: .revealWorktree(path: $0)
              ),
              ComposerContextMenuItem(
                title: "复制 Worktree 路径",
                symbol: "doc.on.doc",
                action: .copyText($0)
              )
            ]
          } ?? [],
          isEnabled: worktreePath != nil,
          availabilityText: worktreePath == nil ? "运行 Edit / Agent 后会创建隔离 Worktree" : nil
        )
      )
    }

    self.chips = chips
  }
}

public struct ComposerContextChip: Equatable, Sendable, Identifiable {
  public let id: String
  public let title: String
  public let surfaceTitle: String
  public let surfaceDescription: String
  public let symbol: String
  public let action: ComposerContextChipAction
  public let menuItems: [ComposerContextMenuItem]
  public let isEnabled: Bool
  public let availabilityText: String?

  public init(
    title: String,
    surfaceTitle: String? = nil,
    surfaceDescription: String = "",
    symbol: String,
    action: ComposerContextChipAction,
    menuItems: [ComposerContextMenuItem] = [],
    isEnabled: Bool = true,
    availabilityText: String? = nil
  ) {
    self.id = "\(title)|\(symbol)|\(action.stableIdentifier)"
    self.title = title
    self.surfaceTitle = surfaceTitle ?? title
    self.surfaceDescription = surfaceDescription
    self.symbol = symbol
    self.action = action
    self.menuItems = menuItems
    self.isEnabled = isEnabled
    self.availabilityText = availabilityText
  }
}

public struct ComposerContextMenuItem: Equatable, Sendable, Identifiable {
  public let id: String
  public let title: String
  public let symbol: String
  public let action: ComposerContextChipAction

  public init(title: String, symbol: String, action: ComposerContextChipAction) {
    self.id = "\(title)|\(action.stableIdentifier)"
    self.title = title
    self.symbol = symbol
    self.action = action
  }
}

public enum ComposerContextChipAction: Equatable, Sendable, Hashable {
  case runDiagnostics
  case runComputerUseDiagnostics
  case revealWorkspace(path: String)
  case copyText(String)
  case revealWorktree(path: String?)

  var stableIdentifier: String {
    switch self {
    case .runDiagnostics:
      "runDiagnostics"
    case .runComputerUseDiagnostics:
      "runComputerUseDiagnostics"
    case let .revealWorkspace(path):
      "revealWorkspace:\(path)"
    case let .copyText(text):
      "copyText:\(text)"
    case let .revealWorktree(path):
      "revealWorktree:\(path ?? "nil")"
    }
  }
}
