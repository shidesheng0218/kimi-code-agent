import Foundation

public struct TerminalSidebarPresentation: Equatable, Sendable {
  public let title: String
  public let subtitle: String
  public let lines: [String]
  public let emptyMessage: String

  public init(
    events: [String],
    query: String = "",
    limit: Int = 80,
    title: String = WorkbenchSidebarPolicy.terminalSectionTitle
  ) {
    let normalizedLimit = max(1, limit)
    let filtered = TaskEventSearch.filter(events: events, query: query)
    let visible = Array(filtered.suffix(normalizedLimit))
    self.title = title
    self.subtitle = visible.isEmpty ? "空闲" : "\(visible.count)"
    self.lines = visible
    self.emptyMessage = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "等待任务开始后显示终端输出。"
      : "没有匹配到终端输出。"
  }
}
