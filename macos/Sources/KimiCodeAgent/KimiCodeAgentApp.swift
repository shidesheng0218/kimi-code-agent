import SwiftUI
import KimiAgentCore
import Sparkle

@main
struct KimiCodeAgentApp: App {
  @StateObject private var model = KimiAppViewModel()
  private let updaterController: SPUStandardUpdaterController

  init() {
    // Start the updater early so scheduled background checks run even before
    // the user opens the update menu item. Sparkle reads SUFeedURL /
    // SUPublicEDKey from the bundle Info.plist at packaging time.
    updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  var body: some Scene {
    WindowGroup("Kimi Code Agent") {
      KimiRootView(model: model)
        .frame(minWidth: 1_120, minHeight: 720)
        .task { await model.start() }
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button("新建会话") { model.createSession() }
          .keyboardShortcut("n", modifiers: [.command])
      }
      CommandGroup(replacing: .appInfo) {
        Button("检查更新…") {
          updaterController.checkForUpdates(nil)
        }
      }
    }
  }
}

@MainActor
final class KimiAppViewModel: ObservableObject {
  @Published private(set) var state = KimiUIState()
  @Published var composerText = ""
  @Published private(set) var terminalOutput = ""
  @Published private(set) var terminalSessionID: UUID?

  let kernel: KimiAppKernel
  let terminalController: KimiTerminalController
  private var eventTask: Task<Void, Never>?
  private var terminalPollTask: Task<Void, Never>?

  init(kernel: KimiAppKernel? = nil) {
    self.kernel = kernel ?? Self.makeDefaultKernel()
    self.terminalController = KimiTerminalController()
    eventTask = Task { [weak self] in
      guard let self else { return }
      let stream = await self.kernel.events()
      for await event in stream {
        _ = event
        let next = await self.kernel.snapshot()
        await MainActor.run { [weak self] in self?.state = next }
      }
    }
  }

  private static func makeDefaultKernel() -> KimiAppKernel {
    let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Kimi Code Agent", isDirectory: true)
    guard let configuration = KimiHeadlessRuntimeFactory.makeConfiguration(
      resourcesDirectory: resources,
      applicationSupportDirectory: support
    ) else {
      return KimiAppKernel()
    }
    let supervisor = OpenCodeRuntimeSupervisor(configuration: configuration)
    let client = URLSessionOpenCodeSessionClient(endpoint: configuration.endpoint)
    let stateStore = KimiAppStateStore(fileURL: support.appendingPathComponent("settings/ui-state.json"))
    let harnessStore = HarnessEventStore(fileURL: support.appendingPathComponent("harness/events.jsonl"))
    return KimiAppKernel(
      sessionClient: client,
      runtimeSupervisor: supervisor,
      persistence: stateStore,
      harnessStore: harnessStore
    )
  }

  deinit {
    eventTask?.cancel()
    terminalPollTask?.cancel()
    let controller = terminalController
    Task { await controller.closeAll() }
  }

  func start() async {
    await kernel.startRuntime()
    await refresh()
    await startTerminalIfNeeded()
  }

  func startTerminalIfNeeded() async {
    guard terminalSessionID == nil else { return }
    let cwd = state.sessions.first(where: { $0.id == state.activeSessionID })?.projectPath
      ?? FileManager.default.currentDirectoryPath
    do {
      let id = try await terminalController.open(cwd: URL(fileURLWithPath: cwd, isDirectory: true))
      terminalSessionID = id
      terminalPollTask = Task { [weak self] in
        guard let self else { return }
        while !Task.isCancelled {
          guard let id = self.terminalSessionID else { return }
          let output = await self.terminalController.output(for: id)
          await MainActor.run { [weak self] in self?.terminalOutput = output }
          try? await Task.sleep(for: .milliseconds(80))
        }
      }
    } catch {
      terminalOutput = "终端启动失败：\(error.localizedDescription)"
    }
  }

  func sendTerminalInput(_ input: String) {
    guard let id = terminalSessionID else { return }
    Task { try? await terminalController.write(input, to: id) }
  }

  func refresh() async {
    state = await kernel.snapshot()
  }

  func createSession() {
    Task {
      try? await kernel.send(.createSession)
      await refresh()
    }
  }

  func select(_ id: UUID) {
    Task {
      try? await kernel.send(.selectSession(id))
      await refresh()
    }
  }

  func sendPrompt() {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    composerText = ""
    Task {
      try? await kernel.send(.prompt(PromptInput(text: text)))
      await refresh()
    }
  }

  func approve(_ id: UUID) {
    Task {
      try? await kernel.send(.approve(id))
      await refresh()
    }
  }

  func deny(_ id: UUID) {
    Task {
      try? await kernel.send(.deny(id))
      await refresh()
    }
  }

  func show(_ pane: KimiActivePane) {
    Task {
      switch pane {
      case .conversation:
        break
      case .diff:
        try? await kernel.send(.openDiff(UUID()))
      case .browser:
        try? await kernel.send(.openBrowser(UUID()))
      case .files:
        try? await kernel.send(.openFile(""))
      case .verification, .integrations:
        state.activePane = pane
      }
      await refresh()
    }
  }

  private func apply(_ event: KimiEvent) {
    switch event {
    case let .runtimeChanged(runtime): state.runtimeState = runtime
    case let .userText(text): state.messages.append(KimiMessage(role: .user, text: text))
    case let .assistantText(text): state.messages.append(KimiMessage(role: .assistant, text: text))
    case let .activity(activity): state.activities.append(activity)
    case let .permission(permission): state.pendingPermissions.append(permission)
    case let .error(error): state.lastError = error
    case let .sessionChanged(summary):
      if let index = state.sessions.firstIndex(where: { $0.id == summary.id }) { state.sessions[index] = summary }
      else { state.sessions.insert(summary, at: 0) }
      state.activeSessionID = summary.id
    }
  }
}

enum KimiDesign {
  static let background = Color(red: 0.965, green: 0.973, blue: 0.984)
  static let surface = Color.white
  static let surfaceSecondary = Color(red: 0.945, green: 0.953, blue: 0.969)
  static let primary = Color(red: 0.10, green: 0.40, blue: 0.95)
  static let accent = Color(red: 0.47, green: 0.35, blue: 0.95)
  static let text = Color(red: 0.12, green: 0.15, blue: 0.20)
  static let muted = Color(red: 0.44, green: 0.48, blue: 0.56)
  static let border = Color(red: 0.88, green: 0.90, blue: 0.93)
  static let radius: CGFloat = 12
}

struct KimiRootView: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    HStack(spacing: 0) {
      KimiSidebar(model: model)
        .frame(width: 248)
      Divider()
      KimiWorkspacePane(model: model)
        .frame(minWidth: 540, maxWidth: .infinity)
      Divider()
      KimiTerminalPane(state: model.state, output: model.terminalOutput, sendInput: model.sendTerminalInput)
        .frame(width: 360)
    }
    .background(KimiDesign.background)
    .preferredColorScheme(.light)
  }
}

struct KimiSidebar: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Circle().fill(KimiDesign.primary.gradient).frame(width: 30, height: 30)
          .overlay(Text("K").font(.headline.weight(.bold)).foregroundStyle(.white))
        VStack(alignment: .leading, spacing: 1) {
          Text("Kimi Code Agent").font(.headline)
          Text("原生智能工作台").font(.caption).foregroundStyle(KimiDesign.muted)
        }
      }
      Button(action: model.createSession) {
        Label("新建会话", systemImage: "plus")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderedProminent)
      .tint(KimiDesign.primary)

      Text("会话").font(.caption.weight(.semibold)).foregroundStyle(KimiDesign.muted)
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(model.state.sessions) { session in
            Button { model.select(session.id) } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(session.title).lineLimit(1)
                Text(session.status.rawValue).font(.caption2).foregroundStyle(KimiDesign.muted)
              }
              .padding(.horizontal, 10).padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(model.state.activeSessionID == session.id ? KimiDesign.surfaceSecondary : .clear)
              .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
          }
        }
      }

      Spacer()
      Divider()
      HStack(spacing: 8) {
        Circle().fill(model.state.runtimeState == .ready ? .green : .orange).frame(width: 8, height: 8)
        Text(model.state.runtimeState == .ready ? "运行时已连接" : "正在连接运行时")
          .font(.caption).foregroundStyle(KimiDesign.muted)
      }
    }
    .padding(16)
    .background(KimiDesign.surface)
  }
}

struct KimiWorkspacePane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    switch model.state.activePane {
    case .conversation:
      KimiConversationPane(model: model)
    case .diff:
      KimiAuxiliaryPane(
        title: "Diff 审阅",
        icon: "arrow.left.arrow.right",
        detail: "任务生成的 Worktree 修改会在这里展示。审批、变更摘要和最终合并保持分离。",
        empty: "当前会话还没有可审阅的修改。"
      ) { model.show(.conversation) }
    case .browser:
      KimiAuxiliaryPane(
        title: "Browser 验证",
        icon: "safari",
        detail: "公开网页验证、截图、控制台与网络产物会由原生 WKWebView 执行并回流到 Activity Card。",
        empty: "尚未发起浏览器验证。"
      ) { model.show(.conversation) }
    case .files:
      KimiAuxiliaryPane(
        title: "项目文件",
        icon: "folder",
        detail: "文件读取、搜索与 Worktree 变更受 Harness 和项目边界约束。",
        empty: "选择项目后将在这里显示文件与产物。"
      ) { model.show(.conversation) }
    case .verification:
      KimiAuxiliaryPane(
        title: "验证",
        icon: "checkmark.seal",
        detail: "测试、构建、Browser 产物和 Receipt 会在最终答复前进行一致性检查。",
        empty: "当前没有待展示的验证记录。"
      ) { model.show(.conversation) }
    case .integrations:
      KimiAuxiliaryPane(
        title: "集成",
        icon: "puzzlepiece.extension",
        detail: "MCP、Skills、Hooks、Plugins 和 Provider 的状态由 Headless Runtime 与 Harness 统一管理。",
        empty: "当前没有需要操作的集成。"
      ) { model.show(.conversation) }
    }
  }
}

struct KimiAuxiliaryPane: View {
  let title: String
  let icon: String
  let detail: String
  let empty: String
  let back: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Label(title, systemImage: icon).font(.title3.weight(.semibold))
        Spacer()
        Button("返回会话", action: back).buttonStyle(.bordered)
      }
      Text(detail).foregroundStyle(KimiDesign.muted)
      Spacer()
      VStack(spacing: 10) {
        Image(systemName: icon).font(.system(size: 36)).foregroundStyle(KimiDesign.primary)
        Text(empty).foregroundStyle(KimiDesign.muted)
      }
      .frame(maxWidth: .infinity)
      Spacer()
    }
    .padding(24)
    .background(KimiDesign.background)
  }
}

struct KimiConversationPane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("会话").font(.title3.weight(.semibold))
          Text("把想法变成可验证的代码").font(.caption).foregroundStyle(KimiDesign.muted)
        }
        Spacer()
        Menu {
          Button("Diff") { model.show(.diff) }
          Button("Browser") { model.show(.browser) }
          Button("Files") { model.show(.files) }
          Button("验证") { model.show(.verification) }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 24).padding(.vertical, 18)

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if model.state.messages.isEmpty {
              VStack(spacing: 10) {
                Text("你好，我是 Kimi Code Agent").font(.title2.weight(.semibold))
                Text("描述你的目标，我会分析、执行、验证并把结果交给你。").foregroundStyle(KimiDesign.muted)
              }
              .frame(maxWidth: .infinity).padding(.top, 120)
            }
            ForEach(model.state.messages) { message in
              KimiMessageRow(message: message)
                .id(message.id)
            }
            ForEach(model.state.activities) { activity in
              KimiActivityCard(activity: activity)
            }
            ForEach(model.state.pendingPermissions) { permission in
              KimiPermissionCard(permission: permission, approve: { model.approve(permission.id) }, deny: { model.deny(permission.id) })
            }
            if let error = model.state.lastError {
              Text(error).foregroundStyle(.red).padding(12).background(Color.red.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
          }
          .padding(24)
        }
        .onChange(of: model.state.messages.count) { _, _ in
          if let id = model.state.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
        }
      }

      KimiComposer(model: model)
        .padding(18)
    }
    .background(KimiDesign.background)
  }
}

struct KimiMessageRow: View {
  let message: KimiMessage

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: message.role == .user ? "person.circle.fill" : "sparkles")
        .foregroundStyle(message.role == .user ? KimiDesign.muted : KimiDesign.primary)
      Text(message.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(message.role == .user ? KimiDesign.surface : KimiDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }
}

struct KimiActivityCard: View {
  let activity: KimiActivity

  var body: some View {
    DisclosureGroup {
      if let detail = activity.detail { Text(detail).font(.caption).foregroundStyle(KimiDesign.muted).padding(.top, 5) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: activity.state == .completed ? "checkmark.circle.fill" : "gearshape.2")
          .foregroundStyle(activity.state == .failed ? .red : KimiDesign.primary)
        Text(activity.title).font(.subheadline.weight(.medium))
        Spacer()
        Text(activity.state.rawValue).font(.caption2).foregroundStyle(KimiDesign.muted)
      }
    }
    .padding(12)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }
}

struct KimiPermissionCard: View {
  let permission: KimiPermissionRequest
  let approve: () -> Void
  let deny: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("需要你的确认", systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold))
      Text(permission.reason).font(.subheadline)
      HStack {
        Button("拒绝", action: deny).buttonStyle(.bordered)
        Button("允许一次", action: approve).buttonStyle(.borderedProminent).tint(KimiDesign.primary)
      }
    }
    .padding(14)
    .background(Color.orange.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }
}

struct KimiComposer: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("描述你想完成的任务…", text: $model.composerText, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .padding(12)
        .background(KimiDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
        .onSubmit { model.sendPrompt() }
      Button(action: model.sendPrompt) {
        Image(systemName: "arrow.up").font(.headline).frame(width: 38, height: 38)
      }
      .buttonStyle(.borderedProminent)
      .tint(KimiDesign.primary)
    }
  }
}

struct KimiTerminalPane: View {
  let state: KimiUIState
  let output: String
  let sendInput: (String) -> Void
  @State private var input = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("终端", systemImage: "terminal")
        Spacer()
        Circle().fill(.green).frame(width: 7, height: 7)
      }
      .padding(16)
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        ScrollViewReader { proxy in
          ScrollView {
            Text(output.isEmpty ? "$ 等待命令…" : output)
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id("terminal-output")
          }
          .onChange(of: output) { _, _ in
            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("terminal-output", anchor: .bottom) }
          }
        }
        HStack(spacing: 6) {
          TextField("输入命令…", text: $input)
            .textFieldStyle(.plain)
            .font(.system(.footnote, design: .monospaced))
            .onSubmit {
              let command = input + "\n"
              input = ""
              sendInput(command)
            }
          Button {
            let command = input + "\n"
            input = ""
            sendInput(command)
          } label: { Image(systemName: "arrow.up.circle.fill") }
          .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      .padding(16)
    }
    .background(Color(red: 0.12, green: 0.14, blue: 0.18))
    .foregroundStyle(.white)
  }
}
