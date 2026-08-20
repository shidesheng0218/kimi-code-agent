import SwiftUI
import KimiAgentCore

/// 会话输入区：上下文信息条（项目、模型、权限提示）+ 输入框。
struct KimiComposerView: View {
  @ObservedObject var model: KimiAppViewModel

  private var activeProject: String? {
    model.state.sessions
      .first(where: { $0.id == model.state.activeSessionID })
      .flatMap { $0.projectPath }
      .map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  private var slashSuggestions: [KimiSlashCommand] {
    let text = model.composerText
    guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
    let query = String(text.dropFirst()).lowercased()
    guard !query.isEmpty else { return Array(model.state.availableCommands.prefix(6)) }
    return Array(model.state.availableCommands.filter { $0.name.lowercased().hasPrefix(query) }.prefix(6))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !slashSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(slashSuggestions) { command in
            Button {
              model.composerText = "/\(command.name) "
            } label: {
              HStack(spacing: 8) {
                Text("/\(command.name)")
                  .font(.subheadline.monospaced().weight(.medium))
                if let description = command.description, !description.isEmpty {
                  Text(description)
                    .font(.caption)
                    .foregroundStyle(KimiDesign.muted)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .background(KimiDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(KimiDesign.border, lineWidth: 1))
      }
      HStack(spacing: 8) {
        if let activeProject {
          chip(icon: "folder", text: activeProject)
        }
        modelMenu
        Spacer()
        HStack(spacing: 4) {
          Image(systemName: "hand.raised")
            .font(.caption2)
          Text(model.isActiveSessionBusy ? "执行中：回车可插入指令" : "高风险操作需逐次确认")
            .font(.caption2)
        }
        .foregroundStyle(KimiDesign.muted)
      }
      HStack(alignment: .bottom, spacing: 10) {
        TextField("描述你想完成的任务…", text: $model.composerText, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .padding(12)
          .background(KimiDesign.surface)
          .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
          .overlay(
            RoundedRectangle(cornerRadius: KimiDesign.radius)
              .stroke(KimiDesign.border, lineWidth: 1)
          )
          .onSubmit { model.sendPrompt() }
        if model.isActiveSessionBusy {
          Button(action: model.abortActive) {
            Image(systemName: "stop.fill")
              .font(.headline)
              .frame(width: 38, height: 38)
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .help("停止当前执行")
          Button(action: model.sendFollowUp) {
            Image(systemName: "clock.arrow.circlepath")
              .font(.headline)
              .frame(width: 38, height: 38)
          }
          .buttonStyle(.bordered)
          .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help("排队：本轮结束后自动发送")
        }
        Button(action: model.sendPrompt) {
          Image(systemName: model.isActiveSessionBusy ? "text.insert" : "arrow.up")
            .font(.headline)
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.borderedProminent)
        .tint(KimiDesign.primary)
        .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(model.isActiveSessionBusy ? "插入当前执行" : "发送")
      }
    }
  }

  private var modelMenu: some View {
    Menu {
      ForEach(model.state.modelCatalog, id: \.self) { item in
        Button {
          model.changeModel(item)
        } label: {
          HStack {
            Text(item)
            if item == model.state.selectedModel {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      chipContent(icon: "cpu", text: model.state.selectedModel)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
  }

  private func chip(icon: String, text: String) -> some View {
    chipContent(icon: icon, text: text)
  }

  private func chipContent(icon: String, text: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.caption2)
      Text(text)
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }
    .foregroundStyle(KimiDesign.muted)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(KimiDesign.surfaceSecondary)
    .clipShape(Capsule())
  }
}
