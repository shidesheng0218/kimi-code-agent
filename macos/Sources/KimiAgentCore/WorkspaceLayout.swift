import Foundation

public enum WorkspacePaneKind: String, Codable, CaseIterable, Sendable {
  case chat
  case diff
  case terminal
  case browser
  case files
  case plan
  case tasks
  case subagents
  case verification
  case integrations
}

public enum WorkspaceSplitOrientation: String, Codable, CaseIterable, Sendable {
  case horizontal
  case vertical
}

public indirect enum WorkspaceSplitNode: Codable, Equatable, Sendable {
  case pane(WorkspacePaneKind)
  case split(orientation: WorkspaceSplitOrientation, ratio: Double, leading: WorkspaceSplitNode, trailing: WorkspaceSplitNode)

  public func contains(_ kind: WorkspacePaneKind) -> Bool {
    switch self {
    case .pane(let pane): pane == kind
    case .split(_, _, let leading, let trailing): leading.contains(kind) || trailing.contains(kind)
    }
  }

  public var paneKinds: [WorkspacePaneKind] {
    switch self {
    case .pane(let pane): [pane]
    case .split(_, _, let leading, let trailing): leading.paneKinds + trailing.paneKinds
    }
  }

  public func replacing(_ target: WorkspacePaneKind, with node: WorkspaceSplitNode) -> WorkspaceSplitNode {
    switch self {
    case .pane(let pane): pane == target ? node : self
    case .split(let orientation, let ratio, let leading, let trailing):
      .split(
        orientation: orientation,
        ratio: ratio,
        leading: leading.replacing(target, with: node),
        trailing: trailing.replacing(target, with: node)
      )
    }
  }
}

public struct WorkspaceLayout: Codable, Equatable, Sendable {
  public var root: WorkspaceSplitNode
  public var focusedPane: WorkspacePaneKind?

  public init(root: WorkspaceSplitNode, focusedPane: WorkspacePaneKind? = .chat) {
    self.root = root
    self.focusedPane = focusedPane
  }

  public static func defaultLayout() -> WorkspaceLayout {
    WorkspaceLayout(
      root: .split(
        orientation: .horizontal,
        ratio: 0.76,
        leading: .pane(.chat),
        trailing: .split(orientation: .vertical, ratio: 0.52, leading: .pane(.tasks), trailing: .pane(.plan))
      )
    )
  }

  public var visiblePaneKinds: [WorkspacePaneKind] {
    root.paneKinds
  }

  public func splitting(
    _ pane: WorkspacePaneKind,
    beside target: WorkspacePaneKind,
    orientation: WorkspaceSplitOrientation,
    ratio: Double = 0.5
  ) -> WorkspaceLayout {
    guard !visiblePaneKinds.contains(pane), root.contains(target) else { return self }
    let normalizedRatio = min(max(ratio, 0.2), 0.8)
    return WorkspaceLayout(
      root: root.replacing(target, with: .split(orientation: orientation, ratio: normalizedRatio, leading: .pane(target), trailing: .pane(pane))),
      focusedPane: pane
    )
  }
}
