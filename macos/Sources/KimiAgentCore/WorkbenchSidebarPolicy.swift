import Foundation

public enum WorkbenchRightUtility: String, Codable, CaseIterable, Sendable {
  case terminal
  case inspector
}

public enum WorkbenchSidebarPolicy {
  public static let modeTitle = "代码"
  public static let recentSectionTitle = "最近"
  public static let projectSectionTitle = "项目"
  public static let sessionSectionTitle = "最近会话"
  public static let terminalSectionTitle = "终端"
  public static let defaultRightUtility: WorkbenchRightUtility = .terminal
  public static let showsCoworkMode = false
}
