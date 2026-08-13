import SwiftUI
import KimiAgentCore

struct WorkspacePaneRenderer: View {
  let layout: WorkspaceLayout
  let content: (WorkspacePaneKind) -> AnyView

  var body: some View {
    render(layout.root)
  }

  private func render(_ node: WorkspaceSplitNode) -> AnyView {
    switch node {
    case let .pane(kind):
      return AnyView(content(kind).frame(maxWidth: .infinity, maxHeight: .infinity))
    case let .split(orientation, ratio, leading, trailing):
      return AnyView(
        GeometryReader { proxy in
          Group {
            if orientation == .horizontal {
              HStack(spacing: 0) {
                render(leading).frame(width: max(220, proxy.size.width * ratio))
                Divider().overlay(WorkbenchTheme.border)
                render(trailing).frame(maxWidth: .infinity)
              }
            } else {
              VStack(spacing: 0) {
                render(leading).frame(height: max(170, proxy.size.height * ratio))
                Divider().overlay(WorkbenchTheme.border)
                render(trailing).frame(maxHeight: .infinity)
              }
            }
          }
        }
      )
    }
  }
}

struct WorkspacePaneSummary: View {
  let kind: WorkspacePaneKind
  let task: AgentTask

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(displayTitle, systemImage: displaySymbol)
        .font(.subheadline.weight(.semibold))
      switch kind {
      case .tasks, .subagents:
        ForEach(task.agentRuns.prefix(6)) { run in
          HStack(spacing: 8) {
            Circle().fill(color(for: run.state)).frame(width: 7, height: 7)
            Text(run.definition.kind.rawValue.capitalized).font(.caption)
            Spacer()
            Text(run.state.rawValue).font(.caption2).foregroundStyle(WorkbenchTheme.secondaryText)
          }
        }
      case .plan:
        Text(task.workItems.map { $0.role.rawValue }.joined(separator: "\n"))
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .lineLimit(8)
      case .diff:
        Text(task.diffSnapshot.map { "\($0.files.count) 个文件变更" } ?? "暂无 Diff")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      case .verification:
        Text(task.verificationResult.map { $0.passed ? "验证通过" : "验证未通过" } ?? "尚未执行验证")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      case .terminal:
        Text(task.terminalSession?.agentContextSummary ?? "终端会话将在侧栏中持续运行。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .lineLimit(6)
      case .browser:
        Text(task.browserVerificationResult?.repairSummary ?? "尚未执行浏览器验证")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      case .integrations:
        Text("外部集成状态在右侧 Inspector 管理。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      case .files:
        Text(task.worktreePath ?? task.workspacePath)
          .font(.caption.monospaced())
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .lineLimit(4)
      case .chat:
        EmptyView()
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(WorkbenchTheme.content)
  }

  private func color(for state: AgentRunState) -> Color {
    switch state {
    case .completed: WorkbenchTheme.success
    case .failed, .cancelled: WorkbenchTheme.destructive
    case .running: WorkbenchTheme.accent
    case .paused, .awaitingApproval, .interrupted: WorkbenchTheme.warning
    case .queued: WorkbenchTheme.secondaryText
    }
  }

  private var displayTitle: String {
    switch kind {
    case .chat: "对话"
    case .diff: "Diff"
    case .terminal: "终端"
    case .browser: "浏览器"
    case .files: "文件"
    case .plan: "计划"
    case .tasks: "任务"
    case .subagents: "Subagents"
    case .verification: "验证"
    case .integrations: "集成"
    }
  }

  private var displaySymbol: String {
    switch kind {
    case .chat: "bubble.left.and.bubble.right"
    case .diff: "doc.text.magnifyingglass"
    case .terminal: "terminal"
    case .browser: "safari"
    case .files: "folder"
    case .plan: "list.bullet.rectangle"
    case .tasks: "checklist"
    case .subagents: "person.3"
    case .verification: "checkmark.seal"
    case .integrations: "link"
    }
  }
}
