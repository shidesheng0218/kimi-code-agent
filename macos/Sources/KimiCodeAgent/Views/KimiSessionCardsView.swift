import SwiftUI
import KimiAgentCore

/// The engine's working checklist for the active session, rendered above the
/// conversation so multi-step progress is visible without opening a panel.
struct KimiTodoListView: View {
  let todos: [KimiTodoItem]

  private var completedCount: Int { todos.filter(\.isCompleted).count }

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(todos) { todo in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: todo))
              .font(.caption)
              .foregroundStyle(color(for: todo))
              .padding(.top, 2)
            Text(todo.content)
              .font(.subheadline)
              .strikethrough(todo.isCompleted)
              .foregroundStyle(todo.isCompleted ? KimiDesign.muted : KimiDesign.text)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.top, 8)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "checklist")
          .foregroundStyle(KimiDesign.primary)
        Text("任务清单")
          .font(.subheadline.weight(.medium))
        Spacer()
        Text("\(completedCount)/\(todos.count)")
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
      }
    }
    .padding(12)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }

  private func icon(for todo: KimiTodoItem) -> String {
    switch todo.status {
    case "completed": "checkmark.circle.fill"
    case "cancelled": "xmark.circle"
    case "in_progress": "circle.lefthalf.filled"
    default: "circle"
    }
  }

  private func color(for todo: KimiTodoItem) -> Color {
    switch todo.status {
    case "completed": .green
    case "cancelled": KimiDesign.muted
    case "in_progress": KimiDesign.primary
    default: KimiDesign.muted
    }
  }
}

/// A structured question from the engine's question tool. Options answer
/// immediately for single-question requests; multi-question or multi-select
/// requests collect selections and submit once.
struct KimiQuestionCard: View {
  let request: KimiQuestionRequest
  let answer: ([[String]]) -> Void
  let reject: () -> Void

  @State private var selections: [String: [String]] = [:]
  @State private var customText: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Kimi 想确认几个问题", systemImage: "questionmark.circle.fill")
        .font(.subheadline.weight(.semibold))
      ForEach(request.questions) { question in
        VStack(alignment: .leading, spacing: 8) {
          if let header = question.header, !header.isEmpty {
            Text(header)
              .font(.caption.weight(.semibold))
              .foregroundStyle(KimiDesign.muted)
          }
          Text(question.question).font(.subheadline)
          ForEach(question.options) { option in
            optionRow(question: question, option: option)
          }
          if question.custom {
            TextField("其他（输入后回车）", text: customBinding(for: question.id))
              .textFieldStyle(.plain)
              .font(.subheadline)
              .padding(8)
              .background(Color.purple.opacity(0.06))
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .onSubmit {
                let text = (customText[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                selections[question.id] = [text]
                if request.questions.count == 1 { answer([selectedAnswers(for: question)]) }
              }
          }
        }
      }
      HStack {
        Button("跳过", action: reject).buttonStyle(.bordered)
        Spacer()
        if request.questions.count > 1 || request.questions.contains(where: \.multiple) {
          Button("提交回答") {
            answer(request.questions.map { selectedAnswers(for: $0) })
          }
          .buttonStyle(.borderedProminent)
          .tint(KimiDesign.primary)
          .disabled(request.questions.allSatisfy { selectedAnswers(for: $0).isEmpty })
        }
      }
    }
    .padding(14)
    .background(Color.purple.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }

  @ViewBuilder
  private func optionRow(question: KimiQuestionItem, option: KimiQuestionOption) -> some View {
    let selected = selections[question.id]?.contains(option.label) ?? false
    Button {
      if question.multiple {
        var current = selections[question.id] ?? []
        if let index = current.firstIndex(of: option.label) { current.remove(at: index) } else { current.append(option.label) }
        selections[question.id] = current
      } else {
        selections[question.id] = [option.label]
        if request.questions.count == 1 { answer([selectedAnswers(for: question)]) }
      }
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? KimiDesign.primary : KimiDesign.muted)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(option.label).font(.subheadline)
          if let description = option.description, !description.isEmpty {
            Text(description).font(.caption).foregroundStyle(KimiDesign.muted)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func selectedAnswers(for question: KimiQuestionItem) -> [String] {
    if let selected = selections[question.id], !selected.isEmpty { return selected }
    let text = (customText[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? [] : [text]
  }

  private func customBinding(for questionID: String) -> Binding<String> {
    Binding(
      get: { customText[questionID] ?? "" },
      set: { customText[questionID] = $0 }
    )
  }
}
