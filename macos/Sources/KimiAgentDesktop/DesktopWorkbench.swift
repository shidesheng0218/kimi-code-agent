import AppKit
import SwiftUI
import KimiAgentCore

struct DesktopWorkbench: View {
  @ObservedObject var model: DesktopAppModel
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.openWindow) private var openWindow
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var layoutMode: WorkbenchLayoutMode = .full
  @State private var showWorkspaceActions = false
  @State private var showSidebarSearch = false
  @State private var showSidebarNotifications = false
  @State private var showSidebarBrandMenu = false
  @State private var sidebarSearchQuery = ""
  @State private var sidebarTerminalQuery = ""
  @State private var showRecentSessions = true
  @State private var showProjects = true
  @State private var rightUtility: WorkbenchRightUtility = WorkbenchSidebarPolicy.defaultRightUtility
  @State private var showTerminalSettings = false

  var body: some View {
    GeometryReader { proxy in
      NavigationSplitView(columnVisibility: $columnVisibility) {
        taskNavigation
      } detail: {
        VStack(spacing: 0) {
          ProjectTopBar(
            workspacePath: model.state.workspacePath,
            task: model.selectedTask,
            openLocation: openWorkspaceLocation,
            chooseWorkspace: model.chooseWorkspace,
            toggleInspector: toggleInspector
          )
          Divider()
            .overlay(WorkbenchTheme.border)

          HStack(spacing: 0) {
            activityWorkspace

            if layoutMode == .full {
              Divider()
              rightUtilityPanel
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 390)
                .transition(
                  accessibilityReduceMotion
                    ? .opacity
                    : .move(edge: .trailing).combined(with: .opacity)
                )
            }
          }
        }
      }
      .navigationSplitViewStyle(.balanced)
      .onAppear {
        applyLayout(for: proxy.size.width)
      }
      .onChange(of: proxy.size.width) { _, width in
        applyLayout(for: width)
      }
      .animation(accessibilityReduceMotion ? nil : WorkbenchTheme.shortAnimation, value: layoutMode)
    }
    .tint(WorkbenchTheme.accent)
    .foregroundStyle(WorkbenchTheme.primaryText)
    .background(WorkbenchTheme.canvas)
    .alert(item: $model.notice) { notice in
      Alert(
        title: Text(notice.kind == .success ? "Kimi Agent Desktop" : "需要注意"),
        message: Text(notice.text),
        dismissButton: .default(Text("知道了"))
      )
    }
    .confirmationDialog(
      "允许 Kimi 自动执行吗？",
      isPresented: $model.showAutomaticConfirmation,
      titleVisibility: .visible
    ) {
      Button("允许本次自动执行") {
        model.confirmAutomaticTask()
      }
      Button("取消", role: .cancel) {
        model.cancelAutomaticTask()
      }
    } message: {
      Text("Edit / Agent 可能修改文件或运行命令。确认后，本次任务会在隔离 Worktree 中执行；Plan 模式始终保持只读。")
    }
    .confirmationDialog(
      model.pendingToolApproval?.action ?? "允许工具操作吗？",
      isPresented: Binding(
        get: { model.pendingToolApproval != nil },
        set: { if !$0 { model.resolvePendingToolApproval(.reject) } }
      ),
      titleVisibility: .visible
    ) {
      Button("允许一次") {
        model.resolvePendingToolApproval(.approve)
      }
      if model.pendingToolApproval?.allowSession == true {
        Button("本任务始终允许") {
          model.resolvePendingToolApproval(.approveForSession)
        }
      }
      Button("拒绝", role: .destructive) {
        model.resolvePendingToolApproval(.reject)
      }
    } message: {
      Text(model.pendingToolApproval?.description ?? "Kimi 请求执行一个需要确认的操作。")
    }
    .confirmationDialog(
      model.pendingTerminalApproval.map { _ in "允许终端命令吗？" } ?? "允许终端命令吗？",
      isPresented: Binding(
        get: { model.pendingTerminalApproval != nil },
        set: { if !$0 { model.resolvePendingTerminalApproval(.reject) } }
      ),
      titleVisibility: .visible
    ) {
      Button("允许一次") {
        model.resolvePendingTerminalApproval(.approveOnce)
      }
      if model.pendingTerminalApproval?.allowSession == true {
        Button("本会话始终允许") {
          model.resolvePendingTerminalApproval(.approveForSession)
        }
      }
      Button("拒绝", role: .destructive) {
        model.resolvePendingTerminalApproval(.reject)
      }
    } message: {
      if let approval = model.pendingTerminalApproval {
        Text("\(approval.reason)\n\n\(approval.command)")
      }
    }
    .confirmationDialog(
      "确认粘贴到终端？",
      isPresented: Binding(
        get: { model.pendingInteractiveTerminalPaste != nil },
        set: { if !$0 { model.resolveInteractiveTerminalPaste(false) } }
      ),
      titleVisibility: .visible
    ) {
      Button("粘贴并执行") { model.resolveInteractiveTerminalPaste(true) }
      Button("取消", role: .cancel) { model.resolveInteractiveTerminalPaste(false) }
    } message: {
      Text(model.pendingInteractiveTerminalPaste?.text ?? "检测到需要确认的终端输入。")
    }
    .sheet(isPresented: $model.showLoginSheet) {
      KimiLoginSheet(model: model)
    }
    .sheet(isPresented: $showTerminalSettings) {
      TerminalSettingsSheet(
        workspace: model.terminalWorkspace,
        saveSSH: model.saveSSHProfile,
        saveSSHCredential: model.saveSSHCredential,
        deleteSSH: model.deleteSSHProfile,
        saveEnvironment: model.saveEnvironmentProfile,
        deleteEnvironment: model.deleteEnvironmentProfile,
        tmuxSessions: model.tmuxSessions,
        discoverTmux: model.discoverTmuxSessions,
        credentialStorageTitle: model.credentialStorageTitle
      )
    }
  }

  private func applyLayout(for width: CGFloat) {
    let nextMode = WorkbenchLayoutPolicy.mode(for: width)
    guard nextMode != layoutMode else { return }
    layoutMode = nextMode

    switch nextMode {
    case .full:
      columnVisibility = .all
    case .focused:
      columnVisibility = .doubleColumn
    case .singleColumn:
      columnVisibility = .detailOnly
    }
  }

  private func toggleSidebarVisibility() {
    switch columnVisibility {
    case .all:
      columnVisibility = .detailOnly
    case .doubleColumn:
      columnVisibility = .detailOnly
    case .detailOnly:
      columnVisibility = .all
    default:
      columnVisibility = .all
    }
  }

  private func toggleInspector() {
    if layoutMode == .full {
      if rightUtility == .terminal {
        rightUtility = .inspector
      } else {
        layoutMode = .focused
        columnVisibility = .doubleColumn
      }
    } else {
      layoutMode = .full
      columnVisibility = .all
      rightUtility = .inspector
    }
  }

  private func showRightUtility(_ utility: WorkbenchRightUtility) {
    rightUtility = utility
    if layoutMode != .full {
      layoutMode = .full
      columnVisibility = .all
    }
  }

  private func openWorkspaceLocation() {
    guard let workspaceURL = model.workspaceURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
  }

  private var projectGroups: [ProjectSidebarGroup] {
    var paths: [String] = []
    if let active = model.state.workspacePath {
      paths.append(active)
    }
    for task in model.state.tasks where !paths.contains(task.workspacePath) {
      paths.append(task.workspacePath)
    }
    return paths.map { path in
      ProjectSidebarGroup(
        path: path,
        tasks: model.state.tasks
          .filter { $0.workspacePath == path }
          .sorted { $0.updatedAt > $1.updatedAt }
      )
    }
  }

  private var filteredRecentTasks: [AgentTask] {
    let query = sidebarSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.state.tasks
      .sorted { $0.updatedAt > $1.updatedAt }
      .filter { task in
        guard !query.isEmpty else { return true }
        return task.title.localizedCaseInsensitiveContains(query) || task.status.title.localizedCaseInsensitiveContains(query)
      }
  }

  private var taskNavigation: some View {
    VStack(spacing: 0) {
      SidebarBrandHeader(
        showSearch: $showSidebarSearch,
        showNotifications: $showSidebarNotifications,
        showBrandMenu: $showSidebarBrandMenu,
        chooseWorkspace: model.chooseWorkspace,
        openSettings: model.openKimiConnectionSettings,
        runDiagnostics: model.runDiagnostics
      )

      if showSidebarSearch {
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(WorkbenchTheme.secondaryText)
          TextField("搜索会话", text: $sidebarSearchQuery)
            .textFieldStyle(.plain)
          if !sidebarSearchQuery.isEmpty {
            Button { sidebarSearchQuery = "" } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(WorkbenchTheme.secondaryText)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WorkbenchTheme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(WorkbenchTheme.border, lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }

      VStack(spacing: 2) {
        SidebarActionRow(
          title: "新对话",
          symbol: "square.and.pencil",
          isSelected: model.isComposingNewConversation,
          action: model.startNewConversation
        )
        SidebarActionRow(title: WorkbenchSidebarPolicy.recentSectionTitle, symbol: "clock") {
          withAnimation(WorkbenchTheme.shortAnimation) {
            showRecentSessions.toggle()
          }
        }
        SidebarActionRow(
          title: WorkbenchSidebarPolicy.terminalSectionTitle,
          symbol: "terminal",
          isSelected: rightUtility == .terminal
        ) {
          withAnimation(WorkbenchTheme.shortAnimation) { showRightUtility(.terminal) }
        }
        SidebarActionRow(
          title: "检查器",
          symbol: "sidebar.right",
          isSelected: rightUtility == .inspector
        ) {
          withAnimation(WorkbenchTheme.shortAnimation) { showRightUtility(.inspector) }
        }
        SidebarActionRow(title: "扩展与 MCP", symbol: "puzzlepiece.extension") {
          model.refreshExtensions()
          if model.state.workspacePath != nil {
            model.openExtensionConfiguration()
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 12)

      Divider()
        .overlay(WorkbenchTheme.border)

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          SidebarSectionHeading(
            title: WorkbenchSidebarPolicy.recentSectionTitle,
            subtitle: filteredRecentTasks.isEmpty ? nil : "\(filteredRecentTasks.count)",
            isExpanded: $showRecentSessions
          )

          if showRecentSessions {
            if filteredRecentTasks.isEmpty {
              SidebarEmptyState(compact: true)
                .padding(.vertical, 8)
            } else {
              LazyVStack(spacing: 3) {
                ForEach(filteredRecentTasks) { task in
                  TaskSidebarRow(
                    task: task,
                    isSelected: model.selectedTaskID == task.id,
                    selectTask: { model.openConversation(id: task.id) }
                  )
                }
              }
              .padding(.leading, 2)
            }
          }

          Divider()
            .overlay(WorkbenchTheme.border)

          HStack {
            SidebarSectionHeading(
              title: WorkbenchSidebarPolicy.projectSectionTitle,
              subtitle: projectGroups.isEmpty ? nil : "\(projectGroups.count)",
              isExpanded: $showProjects
            )
            Button(action: model.chooseWorkspace) {
              Image(systemName: "plus")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("添加项目")
            .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent)
          }

          if showProjects {
            ProjectSidebarList(
              groups: projectGroups,
              activeWorkspacePath: model.state.workspacePath,
              selectedTaskID: model.selectedTaskID,
              chooseWorkspace: model.chooseWorkspace,
              selectWorkspace: { model.selectWorkspace(path: $0) },
              selectTask: { model.openConversation(id: $0) }
            )
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
      }
      .scrollIndicators(.automatic)

      Divider()
        .overlay(WorkbenchTheme.border)

      HStack(spacing: 8) {
        Button {
          showWorkspaceActions.toggle()
        } label: {
          Label("Kimi Agent · \(model.kimiRuntimeIdentity.mode.shortTitle)", systemImage: "sparkle")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WorkbenchTheme.border.opacity(0.88), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .workbenchHoverFeedback(radius: 10, hoverColor: WorkbenchTheme.accent)
        .accessibilityLabel("Kimi 连接设置")
        .accessibilityHint("打开工作区与运行时操作")
        .popover(
          isPresented: $showWorkspaceActions,
          attachmentAnchor: .rect(.bounds),
          arrowEdge: .top
        ) {
          VStack(alignment: .leading, spacing: 8) {
            Button("选择项目…", action: model.chooseWorkspace)
            Divider()
            Button("Kimi 连接设置…", action: model.openKimiConnectionSettings)
            Button("打开 GitHub 授权页") { model.openIntegrationAuthorization(provider: .github) }
            Button("打开 GitLab 授权页") { model.openIntegrationAuthorization(provider: .gitlab) }
            Button("检查 Kimi Runtime", action: model.runDiagnostics)
            Button("检查 Computer Use 权限", action: model.runComputerUseDiagnostics)
          }
          .font(.caption)
          .padding(14)
          .frame(width: 240, alignment: .leading)
          .background(WorkbenchTheme.content)
        }

        Button(action: toggleSidebarVisibility) {
          Label("切换侧栏", systemImage: "chevron.up.chevron.down")
            .labelStyle(.iconOnly)
            .font(.caption2.weight(.semibold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(WorkbenchTheme.border.opacity(0.88), lineWidth: 1)
        }
        .workbenchHoverFeedback(radius: 8, hoverColor: WorkbenchTheme.accent)
        .accessibilityLabel("切换侧栏显示")
      }
    }
    .background(WorkbenchTheme.sidebar)
    .navigationSplitViewColumnWidth(min: 232, ideal: 268, max: 340)
  }

  private var activityWorkspace: some View {
    GeometryReader { _ in
      ZStack(alignment: .bottom) {
        Group {
          switch WorkbenchConversationNavigationPolicy.page(
            selectedTaskID: model.selectedTaskID,
            hasSelectedTask: model.selectedTask != nil,
            isComposingNewConversation: model.isComposingNewConversation
          ) {
          case let .existingConversation(taskID):
            if let task = model.selectedTask, task.id == taskID {
              WorkspacePaneRenderer(layout: task.workspaceLayout ?? WorkspaceLayout.defaultLayout()) { pane in
                AnyView(workspacePaneContent(pane, task: task))
              }
              .id(task.id)
            } else {
              WorkspaceHome(
                state: model.state,
                chooseWorkspace: model.chooseWorkspace,
                selectTask: { model.openConversation(id: $0) }
              )
              .id("home")
            }
          case .newConversation:
            NewConversationWorkspace(
              workspacePath: model.state.workspacePath,
              chooseWorkspace: model.chooseWorkspace
            )
            .id("new-conversation")
          case .home:
            WorkspaceHome(
              state: model.state,
              chooseWorkspace: model.chooseWorkspace,
              selectTask: { model.openConversation(id: $0) }
            )
            .id("home")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The composer is installed with safeAreaInset below. Reserving a
        // guessed height here made long assistant replies render underneath
        // the composer and appear truncated.

      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          ComposerContextBar(
            workspacePath: model.state.workspacePath,
            task: model.selectedTask,
            handleAction: model.handleComposerContextAction
          )
          TaskComposer(
            workspaceIsSelected: model.state.workspacePath != nil,
            isCompact: layoutMode != .full,
            mode: $model.selectedMode,
            modelID: $model.selectedModelID,
            prompt: $model.draftPrompt,
            availableModels: model.kimiAvailableModels,
            isRefreshingModels: model.isRefreshingKimiModels,
            modelRefreshError: model.kimiModelRefreshError,
            chooseWorkspace: model.chooseWorkspace,
            refreshModels: model.refreshKimiModels,
            submit: model.submitComposerPrompt
          )
        }
        .background(WorkbenchTheme.content.opacity(0.97))
        .overlay(alignment: .top) {
          Rectangle()
            .fill(WorkbenchTheme.border.opacity(0.75))
            .frame(height: 1)
        }
      }
    }
    .background(WorkbenchTheme.content)
    .navigationSplitViewColumnWidth(min: 480, ideal: 700, max: .infinity)
  }

  @ViewBuilder
  private func workspacePaneContent(_ pane: WorkspacePaneKind, task: AgentTask) -> some View {
    switch pane {
    case .chat:
      TaskActivityWorkspace(
        task: task,
        run: model.runSelectedTask,
        stop: model.cancelSelectedTask,
        pause: model.pauseSelectedTask,
        resume: model.resumeSelectedTask,
        verify: model.runVerificationForSelectedTask,
        merge: model.mergeSelectedTask,
        retry: model.resumeSelectedTask
      )
    default:
      WorkspacePaneSummary(kind: pane, task: task)
    }
  }

  @ViewBuilder
  private var contextInspector: some View {
    if let task = model.selectedTask {
      TaskContextInspector(
        task: task,
        events: model.events(for: task),
        pendingApproval: model.pendingToolApproval,
        extensionConfiguration: model.extensionConfiguration,
        discoveredSkills: model.extensionSkills,
        plugins: model.extensionPlugins,
        hookResults: model.extensionHookResults[task.id] ?? [],
        mcpStatuses: model.extensionMCPStatuses,
        integrationAccounts: model.integrationAccounts,
        kimiRuntimeIdentity: model.kimiRuntimeIdentity,
        availableModelCount: model.kimiAvailableModels.count,
        lastRefreshAt: model.lastKimiModelRefreshAt,
        isRefreshingModels: model.isRefreshingKimiModels,
        modelRefreshError: model.kimiModelRefreshError,
        retryWebResearchSource: { source in model.retryWebResearchSource(source, for: task) },
        refreshKimiModels: model.refreshKimiModels,
        refreshExtensions: model.refreshExtensions,
        openConfiguration: model.openExtensionConfiguration,
        connectIntegration: model.connectIntegration,
        disconnectIntegration: model.disconnectIntegration,
        openIntegrationAuthorization: model.openIntegrationAuthorization,
        openKimiConnectionSettings: model.openKimiConnectionSettings,
        addWorkspacePane: model.addWorkspacePane,
        resetWorkspaceLayout: model.resetWorkspaceLayout,
        runAgent: { runID in model.runAgentRun(taskID: task.id, runID: runID) },
        cancelAgent: { runID in model.cancelAgentRun(taskID: task.id, runID: runID) },
        verify: model.runVerificationForSelectedTask,
        acceptFile: model.acceptDiffFile,
        rejectFile: model.rejectDiffFile,
        acceptHunk: model.acceptDiffHunk,
        rejectHunk: model.rejectDiffHunk,
        addComment: model.addDiffComment
      )
    } else {
      ProjectContextInspector(
        workspacePath: model.state.workspacePath,
        taskCount: model.state.tasks.count,
        extensionConfiguration: model.extensionConfiguration,
        extensionSkills: model.extensionSkills,
        plugins: model.extensionPlugins,
        mcpStatuses: model.extensionMCPStatuses,
        integrationAccounts: model.integrationAccounts,
        kimiRuntimeIdentity: model.kimiRuntimeIdentity,
        availableModelCount: model.kimiAvailableModels.count,
        lastRefreshAt: model.lastKimiModelRefreshAt,
        isRefreshingModels: model.isRefreshingKimiModels,
        modelRefreshError: model.kimiModelRefreshError,
        refreshKimiModels: model.refreshKimiModels,
        refreshExtensions: model.refreshExtensions,
        openConfiguration: model.openExtensionConfiguration,
        connectIntegration: model.connectIntegration,
        disconnectIntegration: model.disconnectIntegration,
        openIntegrationAuthorization: model.openIntegrationAuthorization,
        openKimiConnectionSettings: model.openKimiConnectionSettings,
        chooseWorkspace: model.chooseWorkspace
      )
    }
  }

  private var rightUtilityPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        utilityTab("终端", symbol: "terminal", utility: .terminal)
        utilityTab("检查器", symbol: "sidebar.right", utility: .inspector)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(WorkbenchTheme.content)
      Divider().overlay(WorkbenchTheme.border)

      Group {
        if rightUtility == .terminal {
          rightTerminalPanel
        } else {
          contextInspector
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(WorkbenchTheme.content)
  }

  private func utilityTab(_ title: String, symbol: String, utility: WorkbenchRightUtility) -> some View {
    Button { rightUtility = utility } label: {
      Label(title, systemImage: symbol)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(rightUtility == utility ? WorkbenchTheme.accentSurface : Color.clear, in: Capsule())
    }
    .buttonStyle(.plain)
    .workbenchHoverFeedback(radius: 12, hoverColor: WorkbenchTheme.accent, isSelected: rightUtility == utility)
  }

  private var rightTerminalPanel: some View {
    SidebarTerminalPanel(
      task: model.selectedTask,
      workspace: model.terminalWorkspace,
      query: $sidebarTerminalQuery,
      run: model.submitTerminalCommand,
      stop: { if let task = model.selectedTask { model.stopTerminalCommand(for: task.id) } },
      openInteractive: { model.openInteractiveTerminalTab() },
      openInteractiveWithEnvironment: { id in model.openInteractiveTerminalTab(environmentProfileID: id) },
      openSSH: { profile in model.openSSHTerminalTab(profile: profile) },
      selectInteractive: model.selectInteractiveTerminalTab,
      closeInteractive: model.closeInteractiveTerminalTab,
      sendInteractiveInput: model.sendInteractiveTerminalInput,
      sendInteractiveData: model.sendInteractiveTerminalData,
      stopInteractive: model.stopInteractiveTerminal,
      resizeInteractive: { metrics in
        model.resizeInteractiveTerminal(rows: metrics.rows, columns: metrics.columns)
      },
      resizeInteractiveForTab: { tabID, metrics in
        model.resizeInteractiveTerminal(tabID: tabID, rows: metrics.rows, columns: metrics.columns)
      },
      reconnectInteractive: model.reconnectInteractiveTerminal,
      configureSplit: model.configureTerminalSplit,
      resetSplit: model.resetTerminalSplit,
      clearOutput: model.clearInteractiveTerminalOutput,
      exportOutput: model.exportInteractiveTerminal,
      openDetached: { openWindow(id: "terminal-workspace") },
      openSettings: { showTerminalSettings = true }
    )
    .padding(10)
  }
}

private struct SidebarBrandHeader: View {
  @Binding var showSearch: Bool
  @Binding var showNotifications: Bool
  @Binding var showBrandMenu: Bool
  let chooseWorkspace: () -> Void
  let openSettings: () -> Void
  let runDiagnostics: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button {
        showBrandMenu.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "sparkles")
            .foregroundStyle(WorkbenchTheme.accent)
          Text("Kimi Agent")
            .foregroundStyle(WorkbenchTheme.primaryText)
            .font(.headline.weight(.semibold))
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
      .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent, isSelected: showBrandMenu)
      .popover(isPresented: $showBrandMenu, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Kimi Agent")
            .font(.headline.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
          Divider()
          Button("选择项目…") {
            showBrandMenu = false
            chooseWorkspace()
          }
          Button("Kimi 连接设置…") {
            showBrandMenu = false
            openSettings()
          }
          Button("检查 Runtime") {
            showBrandMenu = false
            runDiagnostics()
          }
        }
        .padding(8)
        .frame(width: 190, alignment: .leading)
      }
      Button {
        withAnimation(WorkbenchTheme.shortAnimation) {
          showSearch.toggle()
        }
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(.plain)
      .help("搜索会话")
      .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent, isSelected: showSearch)
      Button {
        showNotifications.toggle()
      } label: {
        Image(systemName: "bell")
      }
      .buttonStyle(.plain)
      .help("通知")
      .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent)
      .popover(isPresented: $showNotifications, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Text("通知")
            .font(.headline.weight(.semibold))
          Text("当前没有新的任务通知。运行中的任务、审批和验证结果会显示在会话时间线里。")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(WorkbenchTheme.content)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 14)
  }
}

private struct SidebarActionRow: View {
  let title: String
  let symbol: String
  var isSelected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .contentShape(Rectangle())
    .background(
      isSelected ? WorkbenchTheme.accentSurface.opacity(0.9) : Color.clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent, isSelected: isSelected)
  }
}

private struct ProjectSidebarGroup: Identifiable {
  let path: String
  let tasks: [AgentTask]
  var id: String { path }
}

private struct SidebarSectionHeading: View {
  let title: String
  let subtitle: String?
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      withAnimation(WorkbenchTheme.shortAnimation) {
        isExpanded.toggle()
      }
    } label: {
      HStack(spacing: 5) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.secondaryText)
        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText.opacity(0.85))
        }
        Spacer()
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent)
  }
}

private struct ProjectSidebarList: View {
  let groups: [ProjectSidebarGroup]
  let activeWorkspacePath: String?
  let selectedTaskID: AgentTask.ID?
  let chooseWorkspace: () -> Void
  let selectWorkspace: (String) -> Void
  let selectTask: (AgentTask.ID) -> Void
  @State private var expandedPaths: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if groups.isEmpty {
        Button(action: chooseWorkspace) {
          SidebarEmptyState(compact: true)
        }
        .buttonStyle(.plain)
        .workbenchHoverFeedback(radius: 8, hoverColor: WorkbenchTheme.accent)
      } else {
        ForEach(groups) { group in
          let isExpanded = expandedPaths.contains(group.path)
          VStack(alignment: .leading, spacing: 4) {
            Button {
              selectWorkspace(group.path)
              withAnimation(WorkbenchTheme.shortAnimation) {
                if isExpanded {
                  expandedPaths.remove(group.path)
                } else {
                  expandedPaths.insert(group.path)
                }
              }
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "folder")
                  .foregroundStyle(group.path == activeWorkspacePath ? WorkbenchTheme.accent : WorkbenchTheme.secondaryText)
                Text(URL(fileURLWithPath: group.path).lastPathComponent)
                  .font(.callout)
                  .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(WorkbenchTheme.secondaryText)
              }
              .padding(.horizontal, 9)
              .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent, isSelected: group.path == activeWorkspacePath)

            if isExpanded {
              if group.tasks.isEmpty {
                SidebarEmptyState(compact: true)
                  .padding(.top, 8)
              } else {
                LazyVStack(spacing: 3) {
                  ForEach(group.tasks) { task in
                    TaskSidebarRow(
                      task: task,
                      isSelected: selectedTaskID == task.id,
                      selectTask: { selectTask(task.id) }
                    )
                  }
                }
                .padding(.leading, 10)
              }
            }
          }
        }
      }
    }
    .onAppear {
      expandedPaths.removeAll()
    }
  }
}

private struct ProjectTopBar: View {
  let workspacePath: String?
  let task: AgentTask?
  let openLocation: () -> Void
  let chooseWorkspace: () -> Void
  let toggleInspector: () -> Void

  private var projectName: String {
    guard let workspacePath else { return "Kimi Agent Desktop" }
    return URL(fileURLWithPath: workspacePath).lastPathComponent
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .foregroundStyle(WorkbenchTheme.primaryText)
      Text(projectName)
        .font(.headline.weight(.semibold))
        .lineLimit(1)
      if let task {
        Text("·")
          .foregroundStyle(WorkbenchTheme.secondaryText)
        Text(task.title)
          .font(.subheadline)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .lineLimit(1)
      }

      Menu {
        Button("选择其他项目…", action: chooseWorkspace)
        if workspacePath != nil {
          Button("在 Finder 中显示", action: openLocation)
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.headline.weight(.semibold))
          .frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton)
      .help("项目操作")
      .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent)

      Spacer(minLength: 12)

      if workspacePath != nil {
        Button(action: openLocation) {
          Label("打开位置", systemImage: "arrow.up.right.square")
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent)
      }

      Button(action: toggleInspector) {
        Image(systemName: "sidebar.right")
          .font(.caption.weight(.semibold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("显示或隐藏上下文面板")
      .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(WorkbenchTheme.content)
  }
}

private struct SidebarEmptyState: View {
  var compact = false

  var body: some View {
    VStack(spacing: 9) {
      Image(systemName: "rectangle.stack.badge.plus")
        .font(compact ? .caption : .title2)
        .foregroundStyle(.secondary)
      Text(compact ? "暂无会话" : "任务会出现在这里")
        .font(compact ? .caption : .callout.weight(.medium))
      if !compact {
        Text("在下方描述你的目标，Kimi 会建立一个可审阅的工作流。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 28)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct TaskSidebarRow: View {
  let task: AgentTask
  let isSelected: Bool
  let selectTask: () -> Void

  var body: some View {
      Button(action: selectTask) {
        HStack(alignment: .top, spacing: 9) {
        Circle()
          .fill(task.status.tint)
          .frame(width: 7, height: 7)
          .padding(.top, 6)
        VStack(alignment: .leading, spacing: 4) {
          Text(task.title)
            .lineLimit(2)
            .font(.callout)
          HStack(spacing: 5) {
            Text(task.mode.title)
            Text("·")
            Text(task.status.title)
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(
      isSelected ? WorkbenchTheme.accentSurface.opacity(0.88) : WorkbenchTheme.canvas.opacity(0.46),
      in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous)
    )
    .contentShape(Rectangle())
    .workbenchHoverFeedback(
      radius: WorkbenchTheme.smallRadius,
      hoverColor: WorkbenchTheme.accent,
      isSelected: isSelected
    )
  }
}

private struct SidebarTerminalPanel: View {
  let task: AgentTask?
  let workspace: TerminalWorkspaceState
  @Binding var query: String
  let run: (String) -> Void
  let stop: () -> Void
  let openInteractive: () -> Void
  let openInteractiveWithEnvironment: (UUID) -> Void
  let openSSH: (SSHProfile) -> Void
  let selectInteractive: (UUID) -> Void
  let closeInteractive: (UUID) -> Void
  let sendInteractiveInput: (String) -> Void
  let sendInteractiveData: (UUID, Data) -> Void
  let stopInteractive: () -> Void
  let resizeInteractive: (TerminalViewportMetrics) -> Void
  let resizeInteractiveForTab: (UUID, TerminalViewportMetrics) -> Void
  let reconnectInteractive: (UUID) -> Void
  let configureSplit: (UUID, TerminalPaneOrientation) -> Void
  let resetSplit: () -> Void
  let clearOutput: (UUID?) -> Void
  let exportOutput: (UUID?, Bool) -> Void
  let openDetached: () -> Void
  let openSettings: () -> Void
  @State private var command = ""
  @State private var historyIndex: Int?

  private var session: TerminalSession? { task?.terminalSession }
  private var cwd: String? { session?.cwd ?? task?.worktreePath ?? task?.workspacePath }
  private var isRunning: Bool { session?.status == .running }
  private var activeTab: TerminalTabRecord? {
    guard let id = workspace.activeTabID else { return nil }
    return workspace.tabs.first(where: { $0.id == id })
  }

  private var splitTab: TerminalTabRecord? {
    guard let activeID = workspace.activeTabID,
          let splitID = workspace.paneLayout?.panes.first(where: { $0 != activeID }) else { return nil }
    return workspace.tabs.first(where: { $0.id == splitID })
  }

  private var splitOrientation: TerminalPaneOrientation {
    workspace.paneLayout?.orientation ?? .horizontal
  }

  private var terminalSearchMatches: [TerminalSearchMatch] {
    guard let activeTab else { return [] }
    return TerminalSearchQuery(text: query).matches(in: TerminalScreenBuffer.render(activeTab.output))
  }

  private var filteredHistory: [TerminalCommandRecord] {
    let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let history = session?.history ?? []
    guard !filter.isEmpty else { return history }
    return history.filter {
      $0.command.localizedCaseInsensitiveContains(filter) ||
        $0.stdout.localizedCaseInsensitiveContains(filter) ||
        $0.stderr.localizedCaseInsensitiveContains(filter)
    }
  }

  private var commandHistory: [String] {
    Array(Set((session?.history ?? []).map(\.command))).reversed()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        Image(systemName: "terminal")
          .foregroundStyle(WorkbenchTheme.accent)
        Text(WorkbenchSidebarPolicy.terminalSectionTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.secondaryText)
        Text(terminalStatusTitle)
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText.opacity(0.82))
        Spacer()
        if workspace.tabs.count > 1 {
          Menu {
            Button("单窗格", action: resetSplit)
            Divider()
            ForEach(workspace.tabs.filter { $0.id != workspace.activeTabID }) { tab in
              Button("左右分栏：\(tab.title)") { configureSplit(tab.id, .horizontal) }
              Button("上下分栏：\(tab.title)") { configureSplit(tab.id, .vertical) }
            }
          } label: {
            Image(systemName: splitTab == nil ? "rectangle" : "rectangle.split.2x1")
              .font(.caption2.weight(.semibold))
          }
          .menuStyle(.borderlessButton)
          .help("终端分栏")
          .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
        }
        Button(action: openDetached) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help("在独立窗口中打开终端")
        .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
        Menu {
          Button("清屏") { clearOutput(workspace.activeTabID) }
          Button("导出纯文本") { exportOutput(workspace.activeTabID, false) }
          Button("导出 HTML") { exportOutput(workspace.activeTabID, true) }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.caption2.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .help("终端操作")
        .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
        Button(action: openSettings) {
          Image(systemName: "slider.horizontal.3")
            .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help("终端配置")
        .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
        if !query.isEmpty {
          Button { query = "" } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.caption)
              .foregroundStyle(WorkbenchTheme.secondaryText)
          }
          .buttonStyle(.plain)
          .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
        }
      }

      HStack(spacing: 5) {
        if workspace.tabs.isEmpty {
          Button {
            openInteractive()
          } label: {
            Label("新建交互终端", systemImage: "plus")
              .font(.caption2)
          }
          .buttonStyle(.plain)
          .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent)
        } else {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
              ForEach(workspace.tabs) { tab in
                HStack(spacing: 4) {
                  Button {
                    selectInteractive(tab.id)
                  } label: {
                    HStack(spacing: 4) {
                      Circle()
                        .fill(tab.status == .running ? WorkbenchTheme.success : WorkbenchTheme.secondaryText)
                        .frame(width: 5, height: 5)
                      Text(tab.title)
                        .lineLimit(1)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                      workspace.activeTabID == tab.id ? WorkbenchTheme.accentSurface : WorkbenchTheme.canvas,
                      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                  }
                  .buttonStyle(.plain)
                  .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent, isSelected: workspace.activeTabID == tab.id)
                  Button {
                    closeInteractive(tab.id)
                  } label: {
                    Image(systemName: "xmark")
                      .font(.system(size: 8, weight: .semibold))
                  }
                  .buttonStyle(.plain)
                  .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.destructive)
                  if tab.status == .interrupted || tab.status == .disconnected {
                    Button { reconnectInteractive(tab.id) } label: {
                      Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("恢复连接")
                    .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
                  }
                }
              }
            }
          }
          Menu {
            Button("新建本地终端", action: openInteractive)
            if !workspace.environmentProfiles.isEmpty {
              Divider()
              ForEach(workspace.environmentProfiles) { profile in
                Button("使用环境：\(profile.name)") {
                  openInteractiveWithEnvironment(profile.id)
                }
              }
            }
            if !workspace.sshProfiles.isEmpty {
              Divider()
              ForEach(workspace.sshProfiles) { profile in
                Button("连接 (profile.name)") { openSSH(profile) }
              }
            }
          } label: {
            Image(systemName: "plus")
              .font(.caption2.weight(.semibold))
          }
          .menuStyle(.borderlessButton)
          .help("新建终端")
          .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
        }
        Spacer(minLength: 0)
      }

      if let activeTab {
        if let splitTab, splitTab.id != activeTab.id {
          terminalSplitView(activeTab: activeTab, splitTab: splitTab)
        } else {
          TerminalPTYOutputView(
            tab: activeTab,
            sendInput: { sendInteractiveData(activeTab.id, $0) },
            resize: resizeInteractive
          )
        }
      }

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText)
        TextField("搜索终端输出", text: $query)
          .textFieldStyle(.plain)
          .font(.caption)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(WorkbenchTheme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, activeTab != nil {
        Text(terminalSearchMatches.isEmpty ? "终端输出中没有匹配内容" : "终端输出：\(terminalSearchMatches.count) 处匹配")
          .font(.caption2)
          .foregroundStyle(terminalSearchMatches.isEmpty ? WorkbenchTheme.secondaryText : WorkbenchTheme.accent)
      }

      Text(cwd ?? "选择一个会话后显示终端输出。")
        .font(.caption2)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .lineLimit(1)

      if filteredHistory.isEmpty {
        HStack(spacing: 7) {
          Image(systemName: "circle.dashed")
            .foregroundStyle(WorkbenchTheme.secondaryText)
          Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "等待命令执行。" : "没有匹配到终端输出。")
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        .font(.caption)
        .padding(.vertical, 8)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(filteredHistory.suffix(60)) { record in
              TerminalCommandRow(record: record)
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 210)
        .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(WorkbenchTheme.border.opacity(0.6), lineWidth: 1)
        }
      }

      if task != nil && activeTab == nil {
        HStack(spacing: 5) {
          Button { selectHistory(step: 1) } label: { Image(systemName: "chevron.up") }
            .buttonStyle(.plain)
            .disabled(commandHistory.isEmpty)
            .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
          Button { selectHistory(step: -1) } label: { Image(systemName: "chevron.down") }
            .buttonStyle(.plain)
            .disabled(commandHistory.isEmpty)
            .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
          TextField("输入终端命令", text: $command)
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .onSubmit(submit)
          if isRunning {
            Button(action: stop) {
              Image(systemName: "stop.fill").foregroundStyle(WorkbenchTheme.destructive)
            }
            .buttonStyle(.plain)
            .help("停止当前命令")
            .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.destructive)
          } else {
            Button(action: submit) {
              Image(systemName: "arrow.up")
                .foregroundStyle(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? WorkbenchTheme.secondaryText : WorkbenchTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("运行命令")
            .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(WorkbenchTheme.border, lineWidth: 1)
        }
      }
    }
    .padding(10)
    .background(WorkbenchTheme.content.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(WorkbenchTheme.border.opacity(0.9), lineWidth: 1)
    }
  }

  private var terminalStatusTitle: String {
    switch session?.status {
    case .awaitingApproval: "等待确认"
    case .running: "运行中"
    case .failed: "失败"
    default: "空闲"
    }
  }

  @ViewBuilder
  private func terminalSplitView(activeTab: TerminalTabRecord, splitTab: TerminalTabRecord) -> some View {
    if splitOrientation == .vertical {
      VStack(spacing: 6) {
        TerminalPTYOutputView(tab: activeTab, sendInput: { sendInteractiveData(activeTab.id, $0) }, resize: { resizeInteractiveForTab(activeTab.id, $0) })
          .frame(height: 102)
        TerminalPTYOutputView(tab: splitTab, sendInput: { sendInteractiveData(splitTab.id, $0) }, resize: { resizeInteractiveForTab(splitTab.id, $0) })
          .frame(height: 102)
      }
    } else {
      HStack(spacing: 6) {
        TerminalPTYOutputView(tab: activeTab, sendInput: { sendInteractiveData(activeTab.id, $0) }, resize: { resizeInteractiveForTab(activeTab.id, $0) })
        TerminalPTYOutputView(tab: splitTab, sendInput: { sendInteractiveData(splitTab.id, $0) }, resize: { resizeInteractiveForTab(splitTab.id, $0) })
      }
    }
  }

  private func submit() {
    let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !isRunning else { return }
    if activeTab != nil {
      sendInteractiveInput(value + "\r")
    } else {
      run(value)
    }
    command = ""
    historyIndex = nil
  }

  private func selectHistory(step: Int) {
    let values = commandHistory
    guard !values.isEmpty else { return }
    let current = historyIndex ?? (step > 0 ? -1 : values.count)
    let next = min(max(current + step, 0), values.count - 1)
    historyIndex = next
    command = values[next]
  }
}

private struct TerminalPTYOutputView: View {
  let tab: TerminalTabRecord
  let sendInput: (Data) -> Void
  let resize: (TerminalViewportMetrics) -> Void

  var body: some View {
    SwiftTermTerminalView(
      tabID: tab.id,
      output: tab.output,
      rows: tab.rows,
      columns: tab.columns,
      sendInput: sendInput,
      resize: resize
    )
    .id(tab.id)
    .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .frame(height: 210)
  }
}

struct DetachedTerminalWorkspace: View {
  @ObservedObject var model: DesktopAppModel
  @State private var input = ""

  private var activeTab: TerminalTabRecord? {
    guard let id = model.terminalWorkspace.activeTabID else { return nil }
    return model.terminalWorkspace.tabs.first(where: { $0.id == id })
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "terminal.fill").foregroundStyle(WorkbenchTheme.accent)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            ForEach(model.terminalWorkspace.tabs) { tab in
              Button {
                model.selectInteractiveTerminalTab(tab.id)
              } label: {
                HStack(spacing: 5) {
                  Circle()
                    .fill(tab.status == .running ? WorkbenchTheme.success : WorkbenchTheme.secondaryText)
                    .frame(width: 6, height: 6)
                  Text(tab.title).lineLimit(1)
                }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(model.terminalWorkspace.activeTabID == tab.id ? WorkbenchTheme.accentSurface : Color.clear, in: Capsule())
              }
              .buttonStyle(.plain)
              .workbenchHoverFeedback(radius: 12, hoverColor: WorkbenchTheme.accent, isSelected: model.terminalWorkspace.activeTabID == tab.id)
            }
          }
        }
        Button { model.openInteractiveTerminalTab() } label: { Image(systemName: "plus") }
          .buttonStyle(.plain)
          .help("新建本地终端")
          .workbenchHoverFeedback(radius: 6, hoverColor: WorkbenchTheme.accent)
      }
      .padding(12)
      .background(WorkbenchTheme.content)
      Divider()

      if let activeTab {
        TerminalPTYOutputView(
          tab: activeTab,
          sendInput: { model.sendInteractiveTerminalData(tabID: activeTab.id, data: $0) },
          resize: { metrics in
            model.resizeInteractiveTerminal(tabID: activeTab.id, rows: metrics.rows, columns: metrics.columns)
          }
        )
        .padding(12)
        .frame(maxHeight: .infinity)
      } else {
        ContentUnavailableView("还没有终端", systemImage: "terminal", description: Text("新建一个本地 Shell 或从侧栏连接 SSH。"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Divider()
      HStack(spacing: 8) {
        Text("$").font(.system(.body, design: .monospaced)).foregroundStyle(WorkbenchTheme.accent)
        TextField("输入命令并按回车", text: $input)
          .textFieldStyle(.plain)
          .font(.system(.body, design: .monospaced))
          .onSubmit(send)
        Button(action: send) {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeTab == nil)
        .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent)
        Button {
          model.sendInteractiveTerminalControl(3)
        } label: {
          Image(systemName: "stop.fill")
            .foregroundStyle(WorkbenchTheme.destructive)
        }
        .buttonStyle(.borderless)
        .help("发送 Ctrl-C")
        .disabled(activeTab == nil)
        .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.destructive)
      }
      .padding(12)
      .background(WorkbenchTheme.content)
    }
    .background(Color.black.opacity(0.92))
  }

  private func send() {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, activeTab != nil else { return }
    model.sendInteractiveTerminalInput(value + "\r")
    input = ""
  }
}

private struct TextFlow: View {
  let chunks: [TerminalANSIChunk]

  var body: some View {
    chunks.reduce(Text("")) { partial, chunk in
      partial + Text(chunk.text)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(color(for: chunk.style))
    }
    .textSelection(.enabled)
  }

  private func color(for style: TerminalANSIStyle) -> Color {
    switch style.foreground {
    case .black: return .black
    case .red: return .red
    case .green: return .green
    case .yellow: return .yellow
    case .blue: return .blue
    case .magenta: return .purple
    case .cyan: return .cyan
    case .white: return .white
    case .brightBlack: return .gray
    case .brightRed: return Color(red: 1, green: 0.35, blue: 0.35)
    case .brightGreen: return Color(red: 0.35, green: 1, blue: 0.45)
    case .brightYellow: return Color(red: 1, green: 0.9, blue: 0.35)
    case .brightBlue: return Color(red: 0.4, green: 0.65, blue: 1)
    case .brightMagenta: return Color(red: 1, green: 0.45, blue: 1)
    case .brightCyan: return Color(red: 0.35, green: 1, blue: 1)
    case .brightWhite, .indexed: return .white
    case nil: return Color.white.opacity(0.88)
    }
  }
}

private struct TerminalSettingsSheet: View {
  let workspace: TerminalWorkspaceState
  let saveSSH: (SSHProfile) -> Void
  let saveSSHCredential: (UUID, String) -> Void
  let deleteSSH: (UUID) -> Void
  let saveEnvironment: (TerminalEnvironmentProfile) -> Void
  let deleteEnvironment: (UUID) -> Void
  let tmuxSessions: [UUID: [TmuxSessionRecord]]
  let discoverTmux: (SSHProfile) -> Void
  let credentialStorageTitle: String
  @Environment(\.dismiss) private var dismiss
  @State private var sshProfiles: [SSHProfile]
  @State private var environmentProfiles: [TerminalEnvironmentProfile]
  @State private var selectedSSHID: UUID?
  @State private var selectedEnvironmentID: UUID?
  @State private var sshDraft: SSHProfile
  @State private var environmentDraft: TerminalEnvironmentProfile
  @State private var environmentText: String
  @State private var sshSecret = ""

  init(
    workspace: TerminalWorkspaceState,
    saveSSH: @escaping (SSHProfile) -> Void,
    saveSSHCredential: @escaping (UUID, String) -> Void,
    deleteSSH: @escaping (UUID) -> Void,
    saveEnvironment: @escaping (TerminalEnvironmentProfile) -> Void,
    deleteEnvironment: @escaping (UUID) -> Void,
    tmuxSessions: [UUID: [TmuxSessionRecord]],
    discoverTmux: @escaping (SSHProfile) -> Void,
    credentialStorageTitle: String
  ) {
    self.workspace = workspace
    self.saveSSH = saveSSH
    self.saveSSHCredential = saveSSHCredential
    self.deleteSSH = deleteSSH
    self.saveEnvironment = saveEnvironment
    self.deleteEnvironment = deleteEnvironment
    self.tmuxSessions = tmuxSessions
    self.discoverTmux = discoverTmux
    self.credentialStorageTitle = credentialStorageTitle
    let ssh = workspace.sshProfiles
    let environments = workspace.environmentProfiles
    _sshProfiles = State(initialValue: ssh)
    _environmentProfiles = State(initialValue: environments)
    _selectedSSHID = State(initialValue: ssh.first?.id)
    _selectedEnvironmentID = State(initialValue: environments.first?.id)
    _sshDraft = State(initialValue: ssh.first ?? SSHProfile(name: "新 SSH", host: "", username: ""))
    let firstEnvironment = environments.first ?? TerminalEnvironmentProfile(name: "新环境")
    _environmentDraft = State(initialValue: firstEnvironment)
    _environmentText = State(initialValue: Self.encodeVariables(firstEnvironment.variables))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("终端配置").font(.title3.weight(.semibold))
          Text("SSH、环境变量和恢复策略会保存在本机项目状态中。秘密变量只在运行时注入。")
            .font(.caption).foregroundStyle(WorkbenchTheme.secondaryText)
        }
        Spacer()
        Button("完成") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(20)
      Divider()
      TabView {
        sshEditor
          .tabItem { Label("SSH 主机", systemImage: "server.rack") }
        environmentEditor
          .tabItem { Label("环境配置", systemImage: "slider.horizontal.3") }
      }
      .padding(16)
    }
    .frame(width: 760, height: 500)
  }

  private var sshEditor: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("已保存配置").font(.headline)
          Spacer()
          Button { newSSH() } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless)
        }
        List(selection: $selectedSSHID) {
          ForEach(sshProfiles) { profile in
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.name).lineLimit(1)
              Text("\(profile.username)@\(profile.host):\(profile.port)")
                .font(.caption2).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            .tag(profile.id)
            .contentShape(Rectangle())
            .onTapGesture { loadSSH(profile) }
          }
          .onDelete { offsets in
            offsets.map { sshProfiles[$0].id }.forEach(deleteSSH)
            sshProfiles.remove(atOffsets: offsets)
            if let first = sshProfiles.first { loadSSH(first) }
          }
        }
        .listStyle(.sidebar)
      }
      .frame(width: 230)
      Divider()
      Form {
        Section("连接信息") {
          TextField("名称", text: $sshDraft.name)
          TextField("主机", text: $sshDraft.host)
          TextField("用户名", text: $sshDraft.username)
          HStack {
            TextField("端口", value: $sshDraft.port, format: .number)
            Text("默认 22").font(.caption).foregroundStyle(WorkbenchTheme.secondaryText)
          }
          TextField("私钥路径（可选）", text: stringBinding($sshDraft.identityFile))
          TextField("ProxyJump（可选）", text: stringBinding($sshDraft.proxyJump))
          TextField("远程目录（可选）", text: stringBinding($sshDraft.workingDirectory))
          TextField("Shell", text: $sshDraft.shellPath)
          Picker("主机指纹策略", selection: $sshDraft.hostKeyPolicy) {
            Text("每次询问").tag(SSHHostKeyPolicy.ask)
            Text("严格校验").tag(SSHHostKeyPolicy.strict)
            Text("首次接受").tag(SSHHostKeyPolicy.acceptNew)
          }
          TextField("known_hosts 路径（可选）", text: stringBinding($sshDraft.knownHostsFile))
          TextField("期望指纹（可选）", text: stringBinding($sshDraft.expectedHostFingerprint))
            .help("用于审阅 SSH 连接目标；实际校验仍由 OpenSSH known_hosts 完成。")
          SecureField("私钥密码 / SSH 密码（可选）", text: $sshSecret)
          Button("保存凭据到 \(credentialStorageTitle)") {
            saveSSHCredential(sshDraft.id, sshSecret)
            sshDraft.credentialReference = .keychain(account: "SSH \(sshDraft.name)", service: "com.kimiagent.desktop.ssh")
            sshSecret = ""
          }
          .disabled(sshSecret.isEmpty || !sshProfiles.contains(where: { $0.id == sshDraft.id }))
          HStack {
            Text("认证")
            Spacer()
            Text(sshDraft.credentialReference?.displayName ?? (sshDraft.identityFile?.isEmpty == false ? "私钥文件" : "ssh-agent"))
              .foregroundStyle(WorkbenchTheme.secondaryText)
          }
          Button("发现远程 tmux 会话") { discoverTmux(sshDraft) }
            .disabled(!SSHProfileValidation.validate(sshDraft).isEmpty)
          if let sessions = tmuxSessions[sshDraft.id] {
            if sessions.isEmpty {
              Text("没有可恢复的 tmux 会话").font(.caption).foregroundStyle(WorkbenchTheme.secondaryText)
            } else {
              ForEach(sessions) { session in
                Text("\(session.name) · \(session.windowCount) 个窗口 · \(session.lastActivity)")
                  .font(.caption)
              }
            }
          }
        }
        HStack {
          Button("保存") {
            saveSSH(sshDraft)
            if let index = sshProfiles.firstIndex(where: { $0.id == sshDraft.id }) { sshProfiles[index] = sshDraft } else { sshProfiles.append(sshDraft) }
            selectedSSHID = sshDraft.id
          }
          .buttonStyle(.borderedProminent)
          Button("删除", role: .destructive) {
            deleteSSH(sshDraft.id)
            sshProfiles.removeAll { $0.id == sshDraft.id }
            if let first = sshProfiles.first { loadSSH(first) } else { newSSH() }
          }
          .disabled(!sshProfiles.contains { $0.id == sshDraft.id })
        }
      }
      .formStyle(.grouped)
    }
  }

  private var environmentEditor: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("已保存环境").font(.headline)
          Spacer()
          Button { newEnvironment() } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless)
        }
        List(selection: $selectedEnvironmentID) {
          ForEach(environmentProfiles) { profile in
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.name).lineLimit(1)
              Text("\(profile.variables.count) 个变量")
                .font(.caption2).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            .tag(profile.id)
            .contentShape(Rectangle())
            .onTapGesture { loadEnvironment(profile) }
          }
          .onDelete { offsets in
            offsets.map { environmentProfiles[$0].id }.forEach(deleteEnvironment)
            environmentProfiles.remove(atOffsets: offsets)
            if let first = environmentProfiles.first { loadEnvironment(first) }
          }
        }
        .listStyle(.sidebar)
      }
      .frame(width: 230)
      Divider()
      Form {
        Section("运行环境") {
          TextField("名称", text: $environmentDraft.name)
          TextField("工作目录（可选）", text: stringBinding($environmentDraft.workingDirectory))
          TextField("Shell", text: $environmentDraft.shellPath)
          Text("每行一个 KEY=VALUE").font(.caption).foregroundStyle(WorkbenchTheme.secondaryText)
          TextEditor(text: $environmentText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 130)
          TextField("秘密变量名（逗号分隔）", text: Binding(get: { environmentDraft.secretVariableNames.joined(separator: ", ") }, set: { environmentDraft.secretVariableNames = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }))
        }
        Button("保存") {
          environmentDraft.variables = Self.decodeVariables(environmentText)
          saveEnvironment(environmentDraft)
          if let index = environmentProfiles.firstIndex(where: { $0.id == environmentDraft.id }) { environmentProfiles[index] = environmentDraft } else { environmentProfiles.append(environmentDraft) }
          selectedEnvironmentID = environmentDraft.id
        }
        .buttonStyle(.borderedProminent)
      }
      .formStyle(.grouped)
    }
  }

  private func newSSH() {
    sshDraft = SSHProfile(name: "新 SSH", host: "", username: "")
    selectedSSHID = sshDraft.id
  }

  private func loadSSH(_ profile: SSHProfile) {
    sshDraft = profile
    selectedSSHID = profile.id
  }

  private func newEnvironment() {
    environmentDraft = TerminalEnvironmentProfile(name: "新环境")
    environmentText = ""
    selectedEnvironmentID = environmentDraft.id
  }

  private func loadEnvironment(_ profile: TerminalEnvironmentProfile) {
    environmentDraft = profile
    environmentText = Self.encodeVariables(profile.variables)
    selectedEnvironmentID = profile.id
  }

  private static func encodeVariables(_ variables: [String: String]) -> String {
    variables.keys.sorted().map { "\($0)=\(variables[$0] ?? "")" }.joined(separator: "\n")
  }

  private static func decodeVariables(_ text: String) -> [String: String] {
    Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let key = parts.first, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      return (String(key).trimmingCharacters(in: .whitespaces), parts.count == 2 ? String(parts[1]) : "")
    })
  }
  private func stringBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding<String>(get: { source.wrappedValue ?? "" }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
  }
}

private struct TerminalCommandRow: View {
  let record: TerminalCommandRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Text("$").foregroundStyle(WorkbenchTheme.accent)
        Text(record.command).foregroundStyle(Color.white.opacity(0.96))
        Spacer(minLength: 4)
        Text(statusTitle).foregroundStyle(statusColor)
      }
      .font(.system(.caption, design: .monospaced))
      if !record.stdout.isEmpty {
        Text(record.stdout.trimmingCharacters(in: .newlines))
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.76))
          .textSelection(.enabled)
          .lineLimit(12)
      }
      if !record.stderr.isEmpty {
        Text(record.stderr.trimmingCharacters(in: .newlines))
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
          .textSelection(.enabled)
          .lineLimit(12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 6)
  }

  private var statusTitle: String {
    switch record.status {
    case .queued: "队列"
    case .awaitingApproval: "确认"
    case .running: "运行"
    case .completed: "完成"
    case .failed: "失败"
    case .denied: "拒绝"
    case .cancelled: "已停止"
    case .interrupted: "中断"
    }
  }

  private var statusColor: Color {
    switch record.status {
    case .completed: WorkbenchTheme.success
    case .failed, .denied: WorkbenchTheme.destructive
    case .awaitingApproval: WorkbenchTheme.warning
    case .running: WorkbenchTheme.accent
    case .queued, .cancelled, .interrupted: WorkbenchTheme.secondaryText
    }
  }
}

private struct WorkspaceHome: View {
  let state: AppState
  let chooseWorkspace: () -> Void
  let selectTask: (AgentTask.ID) -> Void

  private var summary: WorkbenchHomeSummary {
    WorkbenchHomeSummary(state: state)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "sparkles")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(WorkbenchTheme.accent)
      Text(state.workspacePath == nil ? "从一个项目开始" : "今天想推进什么？")
        .font(.system(size: 30, weight: .semibold, design: .rounded))
        .foregroundStyle(WorkbenchTheme.primaryText)
      Text(state.workspacePath == nil
           ? "先选择本地项目。之后你可以让 Kimi 规划、修改、验证并在独立 Worktree 中准备代码变更。"
           : "描述目标后，Kimi 会将过程沉淀为清晰的任务流：计划、执行、审阅、验证和合并。")
        .font(.body)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      if state.workspacePath == nil {
        Button("选择本地项目", action: chooseWorkspace)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(WorkbenchTheme.accent)
      } else {
        HomeOverviewCard(summary: summary, tasks: state.tasks, selectTask: selectTask)
      }
    }
    .frame(maxWidth: 780, alignment: .leading)
    .padding(.horizontal, 44)
  }
}

private struct NewConversationWorkspace: View {
  let workspacePath: String?
  let chooseWorkspace: () -> Void

  private var workspaceName: String? {
    workspacePath.map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(WorkbenchTheme.accent)
      Text("新对话")
        .font(.system(size: 30, weight: .semibold, design: .rounded))
        .foregroundStyle(WorkbenchTheme.primaryText)
      Text(workspaceName.map { "当前项目：\($0)。在下方输入一句话，Kimi 会从一个新的会话开始回复。" } ??
           "先选择本地项目，然后在下方输入一句话开始新的会话。")
        .font(.body)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .frame(maxWidth: 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      if workspacePath == nil {
        Button("选择本地项目", action: chooseWorkspace)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(WorkbenchTheme.accent)
      }
    }
    .frame(maxWidth: 780, alignment: .leading)
    .padding(.horizontal, 44)
  }
}

private struct HomeOverviewCard: View {
  let summary: WorkbenchHomeSummary
  let tasks: [AgentTask]
  let selectTask: (AgentTask.ID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("本地活动")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text("最近任务")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        HomeMetric(
          label: "任务",
          value: "\(summary.totalTasks)",
          isInteractive: !tasks.isEmpty,
          action: summary.preferredTaskID(for: .total, in: tasks).map { id in { selectTask(id) } }
        )
        HomeMetric(
          label: "进行中",
          value: "\(summary.activeTasks)",
          isInteractive: summary.activeTasks > 0,
          action: summary.preferredTaskID(for: .active, in: tasks).map { id in { selectTask(id) } }
        )
        HomeMetric(
          label: "待审阅",
          value: "\(summary.reviewReadyTasks)",
          isInteractive: summary.reviewReadyTasks > 0,
          action: summary.preferredTaskID(for: .reviewReady, in: tasks).map { id in { selectTask(id) } }
        )
        HomeMetric(
          label: "已完成",
          value: "\(summary.completedTasks)",
          isInteractive: summary.completedTasks > 0,
          action: summary.preferredTaskID(for: .completed, in: tasks).map { id in { selectTask(id) } }
        )
      }

      Divider()
        .overlay(WorkbenchTheme.border)

      if tasks.isEmpty {
        Text("还没有本地任务，直接在下方描述你想推进的工作。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      } else {
        ForEach(tasks.prefix(3)) { task in
          Button {
            selectTask(task.id)
          } label: {
            HStack(spacing: 8) {
              Circle()
                .fill(task.status.tint)
                .frame(width: 6, height: 6)
              Text(task.title)
                .font(.caption)
                .lineLimit(1)
              Spacer()
              Text(task.status.title)
                .font(.caption2)
                .foregroundStyle(task.status.tint)
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WorkbenchTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(WorkbenchTheme.canvas.opacity(0.46), in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius, hoverColor: WorkbenchTheme.primaryText)
        }
      }
    }
    .padding(16)
    .workbenchSurface(color: WorkbenchTheme.sidebar, radius: WorkbenchTheme.controlRadius)
    .frame(maxWidth: 780)
  }
}

private struct HomeMetric: View {
  let label: String
  let value: String
  var isInteractive: Bool = false
  var action: (() -> Void)? = nil

  var body: some View {
    Group {
      if let action, isInteractive {
        Button(action: action) {
          metricBody
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WorkbenchTheme.content, in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
        .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius, hoverColor: WorkbenchTheme.accent)
      } else {
        metricBody
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(WorkbenchTheme.content, in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
      }
    }
  }

  private var metricBody: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(label)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
        if action != nil && isInteractive {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
      }
      Text(value)
        .font(.title3.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.primaryText)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TaskActivityWorkspace: View {
  let task: AgentTask
  let run: () -> Void
  let stop: () -> Void
  let pause: () -> Void
  let resume: () -> Void
  let verify: () -> Void
  let merge: () -> Void
  let retry: () -> Void

  private var presentation: TaskWorkspacePresentation {
    TaskWorkspacePresentation(status: task.status)
  }

  var body: some View {
    let conversation = AgentConversationPresentation.entries(for: task)
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 12) {
            TaskStatusPill(task: task, presentation: presentation)
            Spacer(minLength: 12)
            TaskPrimaryButton(
              action: presentation.primaryAction,
              run: run,
              resume: resume,
              stop: stop,
              pause: pause,
              showsPauseButton: task.status == .running,
              verify: verify,
              merge: merge
            )
          }
          .padding(.top, 24)

          TaskContextLine(task: task)
            .padding(.top, 10)

          if !task.agentRuns.isEmpty {
            AgentRunActivityStrip(runs: task.agentRuns)
              .padding(.top, 16)
          }

          ConversationTranscript(entries: conversation, isRunning: task.status == .running)
            .padding(.top, 26)

          if task.status == .failed || task.status == .blocked {
            ConversationFailureCard(task: task, retry: retry)
              .padding(.top, 18)
          }

          Color.clear
            .frame(height: 1)
            .id("conversation-bottom")
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(.horizontal, 34)
        .padding(.bottom, 30)
      }
      .onAppear {
        proxy.scrollTo("conversation-bottom", anchor: .bottom)
      }
      .onChange(of: conversation.last?.id) { _, _ in
        withAnimation(WorkbenchTheme.shortAnimation) {
          proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
      }
      .onChange(of: conversation.last?.text) { previousText, currentText in
        guard ConversationDisplayPolicy.shouldFollowStreamingText(
          previousID: conversation.last?.id,
          previousText: previousText,
          currentID: conversation.last?.id,
          currentText: currentText
        ) else { return }
        withAnimation(WorkbenchTheme.shortAnimation) {
          proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
      }
    }
  }
}

private struct AgentRunActivityStrip: View {
  let runs: [AgentRun]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(runs.enumerated()), id: \.element.id) { _, run in
          HStack(spacing: 6) {
            Image(systemName: run.definition.kind.symbolName)
              .font(.caption2.weight(.semibold))
            Text(run.definition.kind.title)
              .font(.caption.weight(.medium))
            if run.state == .running {
              ProgressView()
                .controlSize(.mini)
            } else {
              Text(run.state.title)
                .font(.caption2)
            }
          }
          .foregroundStyle(run.state == .failed ? WorkbenchTheme.destructive : run.state == .completed ? WorkbenchTheme.success : WorkbenchTheme.secondaryText)
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(run.state == .running ? WorkbenchTheme.accentSurface : WorkbenchTheme.canvas, in: Capsule())
          .overlay {
            Capsule().strokeBorder(WorkbenchTheme.border.opacity(0.72), lineWidth: 1)
          }
        }
      }
    }
  }
}

private struct ConversationFailureCard: View {
  let task: AgentTask
  let retry: () -> Void

  private var message: String {
    AgentConversationPresentation.presentableError(task.turns.last?.errorMessage ?? "这一轮没有完成。")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(WorkbenchTheme.destructive)
        Text("这轮执行失败")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("重试", action: retry)
          .buttonStyle(.borderedProminent)
          .tint(WorkbenchTheme.accent)
      }
      Text(message)
        .font(.callout)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Text("重试会继续当前会话，不会创建新的侧栏会话。")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
    }
    .padding(14)
    .background(WorkbenchTheme.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(WorkbenchTheme.destructive.opacity(0.22), lineWidth: 1)
    }
  }
}

private struct TaskStatusPill: View {
  let task: AgentTask
  let presentation: TaskWorkspacePresentation

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(task.status.tint)
        .frame(width: 8, height: 8)
      Text(task.status.title)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(task.status.tint)
      Text("·")
        .foregroundStyle(.tertiary)
      Text(presentation.stageTitle)
        .foregroundStyle(WorkbenchTheme.secondaryText)
      Text("·")
        .foregroundStyle(.tertiary)
      Text(task.mode.title)
        .foregroundStyle(WorkbenchTheme.secondaryText)
    }
    .font(.subheadline)
    .lineLimit(1)
  }
}

private struct ConversationTranscript: View {
  let entries: [AgentConversationEntry]
  let isRunning: Bool

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 18) {
      ForEach(entries) { entry in
        ConversationEntryRow(entry: entry)
      }
      if isRunning {
        ConversationRunningRow()
      }
    }
  }
}

private struct ConversationEntryRow: View {
  let entry: AgentConversationEntry

  var body: some View {
    switch entry.role {
    case .user:
      HStack(alignment: .top) {
        Spacer(minLength: 56)
        Text(ConversationDisplayPolicy.visibleText(entry.text))
          .font(.body)
          .textSelection(.enabled)
          .foregroundStyle(WorkbenchTheme.primaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .background(WorkbenchTheme.accentSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(WorkbenchTheme.accent.opacity(0.22), lineWidth: 1)
          }
      }
    case .assistant:
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: "sparkles")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.accent)
          .frame(width: 22, height: 22)
          .background(WorkbenchTheme.accentSurface, in: Circle())
        Text(ConversationDisplayPolicy.visibleText(entry.text))
          .font(.body)
          .lineSpacing(3)
          .textSelection(.enabled)
          .foregroundStyle(WorkbenchTheme.primaryText)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    case .status:
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: statusSymbol)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(statusColor)
          .frame(width: 18, height: 18)
        Text(entry.text)
          .font(.caption)
          .textSelection(.enabled)
          .foregroundStyle(statusColor)
          .lineLimit(3)
      }
      .padding(.leading, 33)
    }
  }

  private var statusSymbol: String {
    switch entry.tone {
    case .success:
      "checkmark.circle.fill"
    case .warning:
      "hand.raised.fill"
    case .error:
      "exclamationmark.triangle.fill"
    case .normal, .muted:
      "circle.fill"
    }
  }

  private var statusColor: Color {
    switch entry.tone {
    case .success:
      WorkbenchTheme.success
    case .warning:
      WorkbenchTheme.warning
    case .error:
      WorkbenchTheme.destructive
    case .normal:
      WorkbenchTheme.primaryText
    case .muted:
      WorkbenchTheme.secondaryText
    }
  }
}

private struct ConversationRunningRow: View {
  var body: some View {
    HStack(spacing: 9) {
      ProgressView()
        .controlSize(.small)
      Text("Kimi 正在回复…")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
    }
    .padding(.leading, 33)
  }
}

private struct AgentRunsInspector: View {
  let runs: [AgentRun]
  let runAgent: (UUID) -> Void
  let cancelAgent: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("Agent 编排", systemImage: "arrow.triangle.branch")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text("\(runs.filter { $0.state == .completed }.count)/\(runs.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
      if runs.isEmpty {
        Text("发送任务后会自动拆分 Explore、Plan、Implement、Test 和 Review。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      } else {
        ForEach(Array(runs.enumerated()), id: \.element.id) { _, run in
          HStack(spacing: 8) {
            Image(systemName: run.definition.kind.symbolName)
              .font(.caption)
              .foregroundStyle(runStatusColor(run.state))
              .frame(width: 16)
            Text(run.definition.kind.title)
              .font(.caption.weight(.medium))
            Spacer()
            Text(run.state.title)
              .font(.caption2)
              .foregroundStyle(runStatusColor(run.state))
            if run.state == .running || run.state == .awaitingApproval {
              Button("取消") { cancelAgent(run.id) }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(WorkbenchTheme.secondaryText)
                .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.destructive)
            } else if run.state == .queued || run.state == .failed || run.state == .interrupted || run.state == .paused {
              Button("运行") { runAgent(run.id) }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WorkbenchTheme.accent)
                .workbenchHoverFeedback(radius: 5, hoverColor: WorkbenchTheme.accent)
            }
          }
        }
      }
    }
    .padding(12)
    .workbenchSurface(color: WorkbenchTheme.content, radius: WorkbenchTheme.controlRadius)
  }

  private func runStatusColor(_ state: AgentRunState) -> Color {
    switch state {
    case .completed: WorkbenchTheme.success
    case .failed, .cancelled: WorkbenchTheme.destructive
    case .running: WorkbenchTheme.accent
    case .paused, .awaitingApproval, .interrupted: WorkbenchTheme.warning
    case .queued: WorkbenchTheme.secondaryText
    }
  }
}

private struct WorkspaceLayoutInspector: View {
  let layout: WorkspaceLayout
  let addPane: (WorkspacePaneKind, WorkspacePaneKind) -> Void
  let reset: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("工作区", systemImage: "rectangle.3.group")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("重置", action: reset)
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .workbenchHoverFeedback(radius: 6)
      }
      Text(layout.visiblePaneKinds.map(\.title).joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .lineLimit(2)
      HStack(spacing: 6) {
        ForEach([WorkspacePaneKind.diff, .terminal, .browser, .files, .subagents], id: \.self) { pane in
          if !layout.visiblePaneKinds.contains(pane) {
            Button {
              addPane(pane, .chat)
            } label: {
              Label(pane.title, systemImage: pane.symbolName)
                .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(WorkbenchTheme.accent)
          }
        }
      }
    }
    .padding(12)
    .workbenchSurface(color: WorkbenchTheme.content, radius: WorkbenchTheme.controlRadius)
  }
}

private extension AgentKind {
  var symbolName: String {
    switch self {
    case .explore: "magnifyingglass"
    case .plan: "list.bullet.rectangle"
    case .implement: "pencil.and.outline"
    case .test: "checkmark.seal"
    case .review: "checklist"
    case .webResearch: "globe"
    case .browser: "safari"
    case .browserVerification: "safari"
    case .computerUse: "macwindow"
    case .debug: "ladybug"
    }
  }
}

private extension AgentRunState {
  var title: String {
    switch self {
    case .queued: "排队中"
    case .running: "执行中"
    case .paused: "已暂停"
    case .awaitingApproval: "待确认"
    case .completed: "已完成"
    case .failed: "失败"
    case .cancelled: "已取消"
    case .interrupted: "可恢复"
    }
  }
}

private extension WorkspacePaneKind {
  var title: String {
    switch self {
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

  var symbolName: String {
    switch self {
    case .chat: "bubble.left.and.bubble.right"
    case .diff: "doc.text.magnifyingglass"
    case .terminal: "terminal"
    case .browser: "safari"
    case .files: "folder"
    case .plan: "list.bullet.rectangle"
    case .tasks: "checklist"
    case .subagents: "person.3"
    case .verification: "checkmark.seal"
    case .integrations: "puzzlepiece.extension"
    }
  }
}

private struct TaskPrimaryButton: View {
  let action: TaskWorkspacePresentation.PrimaryAction
  let run: () -> Void
  let resume: () -> Void
  let stop: () -> Void
  let pause: () -> Void
  let showsPauseButton: Bool
  let verify: () -> Void
  let merge: () -> Void

  var body: some View {
    switch action {
    case .none:
      EmptyView()
    case .run:
      Button("运行", action: run)
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchTheme.accent)
    case .resume:
      HStack(spacing: 8) {
        Button("继续", action: resume)
          .buttonStyle(.borderedProminent)
          .tint(WorkbenchTheme.accent)
        if showsPauseButton {
          Button("暂停", action: pause)
            .buttonStyle(.bordered)
        }
      }
    case .stop:
      HStack(spacing: 8) {
        Button("停止", role: .destructive, action: stop)
          .buttonStyle(.bordered)
        Button("暂停", action: pause)
          .buttonStyle(.bordered)
      }
    case .verify:
      Button("运行验证", action: verify)
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchTheme.accent)
    case .merge:
      Button("合并变更", action: merge)
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchTheme.accent)
    }
  }
}

private struct TaskContextLine: View {
  let task: AgentTask

  var body: some View {
    HStack(spacing: 14) {
      if let branch = task.branch {
        Label(branch, systemImage: "arrow.triangle.branch")
      } else if task.mode.isReadOnly {
        Label("只读分析", systemImage: "eye")
      } else {
        Label("准备独立 Worktree", systemImage: "arrow.triangle.branch")
      }
      if let modelID = task.modelID {
        Label(modelID, systemImage: "cpu")
      }
      Text("更新于 \(task.updatedAt, format: .relative(presentation: .named))")
    }
    .font(.caption)
    .foregroundStyle(WorkbenchTheme.secondaryText)
    .lineLimit(1)
  }
}

private struct PlanningStage: View {
  let task: AgentTask

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("准备就绪")
        .font(.subheadline.weight(.semibold))
      Text(task.mode.safetyNote)
        .font(.subheadline)
        .foregroundStyle(WorkbenchTheme.secondaryText)
      if !task.workItems.isEmpty {
        HStack(spacing: 8) {
          ForEach(task.workItems) { item in
            Label(item.role.title, systemImage: item.role.symbolName)
          }
        }
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
      }
    }
  }
}

private struct EventSearchBar: View {
  @Binding var query: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(WorkbenchTheme.secondaryText)
      TextField("搜索活动记录", text: $query)
        .textFieldStyle(.plain)
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(WorkbenchTheme.content, in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous)
        .strokeBorder(WorkbenchTheme.border.opacity(0.9), lineWidth: 1)
    }
  }
}

private struct EventTimeline: View {
  let events: [String]
  let query: String

  var body: some View {
    let filtered = TaskEventSearch.filter(events: Array(events.suffix(400)), query: query)
    if filtered.isEmpty {
      HStack(spacing: 10) {
        Image(systemName: "clock")
          .foregroundStyle(WorkbenchTheme.secondaryText)
        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "等待任务开始后显示活动。" : "没有匹配到活动记录。")
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
      .font(.subheadline)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(filtered.enumerated()), id: \.offset) { index, event in
          ActivityEventRow(event: event, showsConnector: index < filtered.count - 1)
        }
      }
    }
  }
}

private struct ActivityEventRow: View {
  let event: String
  let showsConnector: Bool

  private var appearance: ActivityAppearance {
    ActivityAppearance(event: event)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(spacing: 0) {
        Image(systemName: appearance.symbol)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(appearance.color)
          .frame(width: 20, height: 20)
          .background(appearance.color.opacity(0.12), in: Circle())
        if showsConnector {
          Rectangle()
            .fill(WorkbenchTheme.border)
            .frame(width: 1, height: 28)
        }
      }
      Text(event)
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 1)
    }
  }
}

private struct ActivityAppearance {
  let symbol: String
  let color: Color

  init(event: String) {
    if event.localizedCaseInsensitiveContains("失败") || event.localizedCaseInsensitiveContains("错误") || event.localizedCaseInsensitiveContains("拒绝") {
      symbol = "xmark"
      color = WorkbenchTheme.destructive
    } else if event.localizedCaseInsensitiveContains("验证") || event.localizedCaseInsensitiveContains("合并") || event.localizedCaseInsensitiveContains("完成") {
      symbol = "checkmark"
      color = WorkbenchTheme.success
    } else if event.localizedCaseInsensitiveContains("审批") || event.localizedCaseInsensitiveContains("确认") {
      symbol = "hand.raised"
      color = WorkbenchTheme.warning
    } else if event.localizedCaseInsensitiveContains("命令") || event.localizedCaseInsensitiveContains("工具") {
      symbol = "terminal"
      color = WorkbenchTheme.accent
    } else {
      symbol = "circle.fill"
      color = WorkbenchTheme.secondaryText
    }
  }
}

private struct ComposerContextBar: View {
  let workspacePath: String?
  let task: AgentTask?
  let handleAction: (ComposerContextChipAction) -> Void
  @State private var activeChipID: String?

  var body: some View {
    HStack(spacing: 7) {
      ForEach(ComposerContextPresentation(workspacePath: workspacePath, task: task).chips) { chip in
        Group {
          if chip.isEnabled {
            Button {
              activeChipID = chip.id
            } label: {
              ContextChipLabel(
                title: chip.title,
                symbol: chip.symbol,
                showsMenuIndicator: true,
                isSelected: activeChipID == chip.id
              )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chip.title)
            .accessibilityHint(chip.surfaceDescription)
            .popover(
              isPresented: Binding(
                get: { activeChipID == chip.id },
                set: { showing in
                  if !showing && activeChipID == chip.id {
                    activeChipID = nil
                  }
                }
              ),
              attachmentAnchor: .rect(.bounds),
              arrowEdge: .top
            ) {
              ComposerContextPopover(
                chip: chip,
                primaryAction: { handleAction(chip.action) },
                secondaryAction: { action in handleAction(action) },
                dismiss: { activeChipID = nil }
              )
              .frame(width: 280)
            }
            .help(chip.availabilityText ?? chip.title)
          } else {
            ContextChipLabel(title: chip.title, symbol: chip.symbol, showsMenuIndicator: false, isSelected: false)
              .opacity(0.56)
              .help(chip.availabilityText ?? chip.title)
              .accessibilityLabel(chip.title)
              .accessibilityHint(chip.availabilityText ?? chip.surfaceDescription)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: 780, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .contentShape(Rectangle())
  }
}

private struct ContextChipLabel: View {
  let title: String
  let symbol: String
  let showsMenuIndicator: Bool
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 5) {
      Label(title, systemImage: symbol)
        .labelStyle(.titleAndIcon)
      if showsMenuIndicator {
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
    }
      .font(.caption)
      .foregroundStyle(WorkbenchTheme.primaryText)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(WorkbenchTheme.sidebar, in: Capsule())
      .overlay {
        Capsule()
          .strokeBorder(WorkbenchTheme.border.opacity(0.9), lineWidth: 1)
      }
      .workbenchHoverFeedback(radius: 999, isSelected: isSelected)
      .contentShape(Capsule())
      .accessibilityElement(children: .combine)
  }
}

private struct ComposerContextPopover: View {
  let chip: ComposerContextChip
  let primaryAction: () -> Void
  let secondaryAction: (ComposerContextChipAction) -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(chip.surfaceTitle)
          .font(.headline.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.primaryText)
        Text(chip.surfaceDescription)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button {
        primaryAction()
        dismiss()
      } label: {
        Label("执行主动作", systemImage: chip.symbol)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderedProminent)
      .tint(WorkbenchTheme.accent)

      if !chip.menuItems.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(chip.menuItems) { item in
            Button {
              secondaryAction(item.action)
              dismiss()
            } label: {
              Label(item.title, systemImage: item.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchTheme.content)
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(WorkbenchTheme.border.opacity(0.95), lineWidth: 1)
    }
  }
}

private struct TaskComposer: View {
  let workspaceIsSelected: Bool
  let isCompact: Bool
  @Binding var mode: TaskMode
  @Binding var modelID: String
  @Binding var prompt: String
  let availableModels: [KimiModelSummary]
  let isRefreshingModels: Bool
  let modelRefreshError: String?
  let chooseWorkspace: () -> Void
  let refreshModels: () -> Void
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $prompt)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(height: 64)
          .accessibilityLabel("任务描述")
          .onKeyPress(.return, phases: .down) { keyPress in
            switch ComposerKeyPolicy.action(
              for: "return",
              command: keyPress.modifiers.contains(.command),
              shift: keyPress.modifiers.contains(.shift),
              option: keyPress.modifiers.contains(.option)
            ) {
            case .submit:
              submit()
              return .handled
            case .insertNewline, .ignore:
              return .ignored
            }
          }
        if prompt.isEmpty {
          Text(workspaceIsSelected
               ? "描述任务或提出问题…"
               : "先选择一个本地项目，再描述任务…")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
      }

      HStack(spacing: 10) {
        Button(action: chooseWorkspace) {
          Image(systemName: "plus")
            .font(.body.weight(.medium))
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help("添加项目或上下文")
        .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent)

        Picker("模式", selection: $mode) {
          ForEach(TaskMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 78, idealWidth: 92, maxWidth: 104)
        .tint(WorkbenchTheme.primaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(WorkbenchTheme.canvas, in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(WorkbenchTheme.border.opacity(0.9), lineWidth: 1)
        }
        .contentShape(Capsule())
        .workbenchHoverFeedback(radius: 999, hoverColor: WorkbenchTheme.accent)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.permissionBadgeHint)

        PermissionBadge(mode: mode)

        ModelSelectionMenu(
          selectedModelID: $modelID,
          availableModels: availableModels,
          isRefreshingModels: isRefreshingModels,
          modelRefreshError: modelRefreshError,
          refreshModels: refreshModels
        )

        if !isCompact {
          Text(mode.safetyNote)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        Text("⌘↵")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)

        if workspaceIsSelected {
          Button(action: submit) {
            Label("创建任务", systemImage: "arrow.up")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderedProminent)
          .tint(WorkbenchTheme.accent)
          .keyboardShortcut(.return, modifiers: [.command])
          .help("创建任务（⌘↵）")
        } else {
          Button("选择项目", action: chooseWorkspace)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(12)
    .workbenchSurface(color: WorkbenchTheme.content, radius: WorkbenchTheme.controlRadius)
    .shadow(color: Color.black.opacity(0.08), radius: 14, y: 5)
    .padding(.horizontal, 24)
    .padding(.vertical, 10)
  }
}

private struct ModelSelectionMenu: View {
  @Binding var selectedModelID: String
  let availableModels: [KimiModelSummary]
  let isRefreshingModels: Bool
  let modelRefreshError: String?
  let refreshModels: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Menu {
        if availableModels.isEmpty {
          Button("暂无可刷新模型") {}
            .disabled(true)
        } else {
          ForEach(availableModels) { model in
            Button {
              selectedModelID = model.id
            } label: {
              HStack {
                Text(model.displayName)
                if model.id == selectedModelID {
                  Spacer()
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
        Divider()
        Button("刷新模型列表", action: refreshModels)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "cpu")
          Text(selectedLabel)
            .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(WorkbenchTheme.primaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WorkbenchTheme.canvas, in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(WorkbenchTheme.border.opacity(0.9), lineWidth: 1)
        }
      }
      .menuStyle(.borderlessButton)
      .workbenchHoverFeedback(radius: 999, hoverColor: WorkbenchTheme.accent)

      Button(action: refreshModels) {
        Image(systemName: isRefreshingModels ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise")
          .font(.caption2.weight(.semibold))
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .disabled(isRefreshingModels)
      .workbenchHoverFeedback(radius: 7, hoverColor: WorkbenchTheme.accent)
      .help("刷新模型列表")

      if isRefreshingModels {
        ProgressView()
          .controlSize(.small)
      }
    }
    .overlay(alignment: .bottomLeading) {
      if let modelRefreshError, !modelRefreshError.isEmpty {
        Text("刷新失败：\(modelRefreshError)")
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(.top, 2)
          .offset(y: 18)
      } else if !availableModels.isEmpty {
        Text("\(availableModels.count) 个模型")
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .padding(.top, 2)
          .offset(y: 18)
      }
    }
  }

  private var selectedLabel: String {
    if !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return selectedModelID
    }
    return availableModels.first?.id ?? "默认模型"
  }
}

private struct PermissionBadge: View {
  let mode: TaskMode
  @State private var isShowingInfo = false

  var body: some View {
    Button {
      isShowingInfo.toggle()
    } label: {
      Label(mode.permissionBadgeTitle, systemImage: mode.permissionBadgeSymbol)
        .font(.caption2.weight(.medium))
        .foregroundStyle(mode.isReadOnly ? WorkbenchTheme.accent : WorkbenchTheme.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
          (mode.isReadOnly ? WorkbenchTheme.accentSurface : WorkbenchTheme.warning.opacity(0.12)),
          in: Capsule()
        )
    }
    .buttonStyle(.plain)
    .workbenchHoverFeedback(radius: 999, hoverColor: WorkbenchTheme.accent, isSelected: isShowingInfo)
    .contentShape(Capsule())
    .accessibilityLabel(mode.permissionBadgeTitle)
    .accessibilityHint(mode.permissionBadgeHint)
    .popover(
      isPresented: $isShowingInfo,
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .top
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Text(mode.title)
          .font(.headline.weight(.semibold))
        Text(mode.permissionBadgeHint)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        Text(mode.safetyNote)
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
      .padding(14)
      .frame(width: 260, alignment: .leading)
      .background(WorkbenchTheme.content)
    }
  }
}

private struct TaskContextInspector: View {
  let task: AgentTask
  let events: [String]
  let pendingApproval: PendingToolApproval?
  let extensionConfiguration: ProjectAgentConfiguration?
  let discoveredSkills: [SkillDescriptor]
  let plugins: [KimiPluginDescriptor]
  let hookResults: [HookResult]
  let mcpStatuses: [MCPServerStatus]
  let integrationAccounts: [AccountRecord]
  let kimiRuntimeIdentity: KimiRuntimeIdentityRecord
  let availableModelCount: Int
  let lastRefreshAt: Date?
  let isRefreshingModels: Bool
  let modelRefreshError: String?
  let retryWebResearchSource: (WebResearchSource) -> Void
  let refreshKimiModels: () -> Void
  let refreshExtensions: () -> Void
  let openConfiguration: () -> Void
  let connectIntegration: (IntegrationProvider, String, String, String) -> Void
  let disconnectIntegration: (IntegrationProvider) -> Void
  let openIntegrationAuthorization: (IntegrationProvider) -> Void
  let openKimiConnectionSettings: () -> Void
  let addWorkspacePane: (WorkspacePaneKind, WorkspacePaneKind) -> Void
  let resetWorkspaceLayout: () -> Void
  let runAgent: (UUID) -> Void
  let cancelAgent: (UUID) -> Void
  let verify: () -> Void
  let acceptFile: (String) -> Void
  let rejectFile: (String) -> Void
  let acceptHunk: (String) -> Void
  let rejectHunk: (String) -> Void
  let addComment: (String, Int, String) -> Void

  private var presentation: TaskWorkspacePresentation {
    TaskWorkspacePresentation(status: task.status)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        InspectorHeading(
          title: presentation.stageTitle,
          subtitle: presentation.statusDescription,
          symbol: presentation.stageSymbol
        )

        InspectorMetadata(task: task)
        AgentRunsInspector(runs: task.agentRuns, runAgent: runAgent, cancelAgent: cancelAgent)
        WorkspaceLayoutInspector(
          layout: task.workspaceLayout ?? WorkspaceLayout.defaultLayout(),
          addPane: addWorkspacePane,
          reset: resetWorkspaceLayout
        )
        KimiRuntimeStatusCard(
          identity: kimiRuntimeIdentity,
          availableModelCount: availableModelCount,
          lastRefreshAt: lastRefreshAt,
          isRefreshingModels: isRefreshingModels,
          modelRefreshError: modelRefreshError,
          openSettings: openKimiConnectionSettings,
          refreshModels: refreshKimiModels
        )
        WebResearchSourcesPanel(
          sources: task.webResearchSources,
          usage: task.webResearchUsage,
          citationStatus: task.webResearchCitationStatus,
          retry: retryWebResearchSource
        )
        ExtensionManagementPanel(
          configuration: extensionConfiguration,
          discoveredSkills: discoveredSkills,
          plugins: plugins,
          hookResults: hookResults,
          mcpStatuses: mcpStatuses,
          refresh: refreshExtensions,
          openConfiguration: openConfiguration
        )
        IntegrationManagementPanel(
          accounts: integrationAccounts,
          connect: connectIntegration,
          disconnect: disconnectIntegration,
          openAuthorization: openIntegrationAuthorization
        )

        Divider()
          .overlay(WorkbenchTheme.border)

        switch presentation.inspector {
        case .plan:
          WorkflowInspector(workItems: task.workItems, mode: task.mode)
        case .activity:
          ActivityInspector(events: events, workItems: task.workItems)
        case .approval:
          ApprovalInspector(pendingApproval: pendingApproval, task: task)
        case .review:
          ReviewInspector(
            snapshot: task.diffSnapshot,
            reviewState: task.reviewState,
            acceptFile: acceptFile,
            rejectFile: rejectFile,
            acceptHunk: acceptHunk,
            rejectHunk: rejectHunk,
            addComment: addComment
          )
        case .verification:
          VerificationPanel(
            result: task.verificationResult,
            browserResult: task.browserVerificationResult,
            isVerifying: task.status == .verifying,
            verify: verify
          )
        case .summary:
          CompletionInspector(task: task)
        }

        Divider()
          .overlay(WorkbenchTheme.border)

      }
      .padding(20)
    }
    .background(WorkbenchTheme.sidebar)
  }
}

private struct ProjectContextInspector: View {
  let workspacePath: String?
  let taskCount: Int
  let extensionConfiguration: ProjectAgentConfiguration?
  let extensionSkills: [SkillDescriptor]
  let plugins: [KimiPluginDescriptor]
  let mcpStatuses: [MCPServerStatus]
  let integrationAccounts: [AccountRecord]
  let kimiRuntimeIdentity: KimiRuntimeIdentityRecord
  let availableModelCount: Int
  let lastRefreshAt: Date?
  let isRefreshingModels: Bool
  let modelRefreshError: String?
  let refreshKimiModels: () -> Void
  let refreshExtensions: () -> Void
  let openConfiguration: () -> Void
  let connectIntegration: (IntegrationProvider, String, String, String) -> Void
  let disconnectIntegration: (IntegrationProvider) -> Void
  let openIntegrationAuthorization: (IntegrationProvider) -> Void
  let openKimiConnectionSettings: () -> Void
  let chooseWorkspace: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      InspectorHeading(title: "项目上下文", subtitle: "本地优先的 Agent 工作台", symbol: "sidebar.right")
      Divider()
      KimiRuntimeStatusCard(
        identity: kimiRuntimeIdentity,
        availableModelCount: availableModelCount,
        lastRefreshAt: lastRefreshAt,
        isRefreshingModels: isRefreshingModels,
        modelRefreshError: modelRefreshError,
        openSettings: openKimiConnectionSettings,
        refreshModels: refreshKimiModels
      )
      if let workspacePath {
        InspectorRow(label: "项目", value: URL(fileURLWithPath: workspacePath).lastPathComponent)
        InspectorRow(label: "位置", value: workspacePath, monospaced: true)
        InspectorRow(label: "任务", value: "\(taskCount) 个")
        ExtensionManagementPanel(
          configuration: extensionConfiguration,
          discoveredSkills: extensionSkills,
          plugins: plugins,
          hookResults: [],
          mcpStatuses: mcpStatuses,
          refresh: refreshExtensions,
          openConfiguration: openConfiguration
        )
        IntegrationManagementPanel(
          accounts: integrationAccounts,
          connect: connectIntegration,
          disconnect: disconnectIntegration,
          openAuthorization: openIntegrationAuthorization
        )
      } else {
        Text("选择一个项目后，Kimi 会在本地保存任务、会话、Diff 和验证记录。代码与任务内容默认不会上传。")
          .font(.subheadline)
          .foregroundStyle(WorkbenchTheme.secondaryText)
        Button("选择本地项目", action: chooseWorkspace)
          .buttonStyle(.borderedProminent)
          .tint(WorkbenchTheme.accent)
      }
      Spacer()
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(WorkbenchTheme.sidebar)
  }
}

private struct InspectorHeading: View {
  let title: String
  let subtitle: String
  let symbol: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(WorkbenchTheme.accent)
        .frame(width: 24, height: 24)
        .background(WorkbenchTheme.accentSurface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
    }
  }
}

private struct InspectorMetadata: View {
  let task: AgentTask

  var body: some View {
    VStack(spacing: 10) {
      InspectorRow(label: "状态", value: task.status.title, tint: task.status.tint)
      InspectorRow(label: "模式", value: task.mode.title)
      if let branch = task.branch {
        InspectorRow(label: "分支", value: branch, monospaced: true)
      } else if !task.mode.isReadOnly {
        InspectorRow(label: "隔离目录", value: task.worktreePath == nil ? "将在运行时创建" : "已创建")
      }
      if let modelID = task.modelID {
        InspectorRow(label: "模型", value: modelID, monospaced: true)
      }
    }
  }
}

private struct InspectorRow: View {
  let label: String
  let value: String
  var monospaced = false
  var tint: Color? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .frame(width: 56, alignment: .leading)
      Text(value)
        .font(monospaced ? .caption.monospaced() : .subheadline)
        .foregroundStyle(tint ?? WorkbenchTheme.primaryText)
        .lineLimit(2)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }
}

private struct WorkflowInspector: View {
  let workItems: [WorkItem]
  let mode: TaskMode

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("执行计划")
        .font(.subheadline.weight(.semibold))
      if workItems.isEmpty {
        Text(mode.safetyNote)
          .font(.subheadline)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      } else {
        ForEach(workItems) { item in
          HStack(spacing: 10) {
            Image(systemName: item.role.symbolName)
              .foregroundStyle(WorkbenchTheme.secondaryText)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
              Text(item.role.title)
                .font(.subheadline)
              Text(item.status.title)
                .font(.caption)
                .foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Spacer()
            if !item.dependencies.isEmpty {
              Text("依赖 \(item.dependencies.count)")
                .font(.caption2)
                .foregroundStyle(WorkbenchTheme.secondaryText)
            }
          }
        }
      }
      Text(mode.safetyNote)
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .padding(.top, 4)
    }
  }
}

private struct ActivityInspector: View {
  let events: [String]
  let workItems: [WorkItem]
  @State private var searchText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("当前进度")
        .font(.subheadline.weight(.semibold))
      Text(TaskEventSearch.filter(events: events, query: searchText).last ?? "正在建立执行上下文…")
        .font(.subheadline)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      EventSearchBar(query: $searchText)
      if !workItems.isEmpty {
        Divider()
        Text("Workers")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.secondaryText)
        ForEach(workItems) { item in
          HStack {
            Image(systemName: item.role.symbolName)
              .frame(width: 16)
            Text(item.role.title)
            Spacer()
            Text(item.status.title)
              .foregroundStyle(item.status.tint)
          }
          .font(.caption)
        }
      }
    }
  }
}

private struct ApprovalInspector: View {
  let pendingApproval: PendingToolApproval?
  let task: AgentTask

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("等待你的决定")
        .font(.subheadline.weight(.semibold))
      Text(pendingApproval?.description ?? "Kimi 已暂停执行，等待你在审批对话框中确认下一步操作。")
        .font(.subheadline)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if !task.mode.isReadOnly {
        Text("写入、命令、网络与系统操作均受当前任务的权限策略限制。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }
    }
  }
}

private struct ReviewInspector: View {
  let snapshot: DiffSnapshot?
  let reviewState: DiffReviewState
  let acceptFile: (String) -> Void
  let rejectFile: (String) -> Void
  let acceptHunk: (String) -> Void
  let rejectHunk: (String) -> Void
  let addComment: (String, Int, String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      Text("代码变更")
        .font(.subheadline.weight(.semibold))
      if let snapshot, !snapshot.files.isEmpty {
        ChangeSummary(snapshot: snapshot, reviewState: reviewState)
      }
      DiffReviewPanel(
        snapshot: snapshot,
        reviewState: reviewState,
        acceptFile: acceptFile,
        rejectFile: rejectFile,
        acceptHunk: acceptHunk,
        rejectHunk: rejectHunk,
        addComment: addComment
      )
    }
  }
}

private struct ChangeSummary: View {
  let snapshot: DiffSnapshot
  let reviewState: DiffReviewState

  private var additions: Int { snapshot.files.reduce(0) { $0 + $1.additions } }
  private var deletions: Int { snapshot.files.reduce(0) { $0 + $1.deletions } }

  var body: some View {
    HStack(spacing: 12) {
      Text("\(snapshot.files.count) 个文件")
      Text("+\(additions)")
        .foregroundStyle(WorkbenchTheme.success)
      Text("−\(deletions)")
        .foregroundStyle(WorkbenchTheme.destructive)
      if !reviewState.comments.isEmpty {
        Text("\(reviewState.comments.count) 条评论")
      }
    }
    .font(.caption)
    .foregroundStyle(WorkbenchTheme.secondaryText)
  }
}

private struct DiffReviewPanel: View {
  let snapshot: DiffSnapshot?
  let reviewState: DiffReviewState
  let acceptFile: (String) -> Void
  let rejectFile: (String) -> Void
  let acceptHunk: (String) -> Void
  let rejectHunk: (String) -> Void
  let addComment: (String, Int, String) -> Void

  @State private var selectedPath: String?
  @State private var comment = ""

  var body: some View {
    if let snapshot, !snapshot.files.isEmpty {
      let selected = snapshot.files.first { $0.path == selectedPath } ?? snapshot.files[0]
      VStack(alignment: .leading, spacing: 12) {
        Picker("文件", selection: $selectedPath) {
          ForEach(snapshot.files) { file in
            Text(file.path).tag(Optional(file.path))
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()

        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text(selected.path)
              .font(.caption.monospaced())
              .lineLimit(1)
            Text("+\(selected.additions) / −\(selected.deletions)")
              .font(.caption2.monospaced())
              .foregroundStyle(WorkbenchTheme.secondaryText)
          }
          Spacer(minLength: 8)
          Button("接受") { acceptFile(selected.path) }
            .controlSize(.small)
          Button("拒绝", role: .destructive) { rejectFile(selected.path) }
            .controlSize(.small)
        }

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(selected.hunks) { hunk in
              let hunkKey = DiffReviewPanel.hunkDecisionKey(filePath: selected.path, hunk: hunk)
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                  Text("@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                    .font(.caption2.monospaced())
                    .foregroundStyle(WorkbenchTheme.secondaryText)
                  Spacer()
                  if let decision = reviewState.hunkDecisions[hunkKey] {
                    Text(decision == .accepted ? "已接受" : "已拒绝")
                      .font(.caption2)
                      .foregroundStyle(decision == .accepted ? WorkbenchTheme.success : WorkbenchTheme.destructive)
                  }
                  Button("接受") { acceptHunk(hunkKey) }
                    .controlSize(.mini)
                  Button("拒绝") { rejectHunk(hunkKey) }
                    .controlSize(.mini)
                }
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                  Text(line.isEmpty ? " " : line)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    .background(diffLineColor(line))
                    .contextMenu {
                      Button("评论此行") {
                        addComment(selected.path, hunk.newStart + index, "请审阅此处变更")
                      }
                    }
                }
              }
            }
          }
        }
        .frame(minHeight: 160, maxHeight: 300)

        HStack(spacing: 8) {
          TextField("添加评论", text: $comment)
            .textFieldStyle(.roundedBorder)
          Button("发送") {
            let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            addComment(selected.path, 0, text)
            comment = ""
          }
          .controlSize(.small)
        }
      }
    } else {
      Text("完成 Edit 或 Agent 任务后，这里会显示可审阅的 Diff。")
        .font(.subheadline)
        .foregroundStyle(WorkbenchTheme.secondaryText)
    }
  }

  private func diffLineColor(_ line: String) -> Color {
    if line.hasPrefix("+") { return WorkbenchTheme.success.opacity(0.12) }
    if line.hasPrefix("-") { return WorkbenchTheme.destructive.opacity(0.12) }
    return .clear
  }

  private static func hunkDecisionKey(filePath: String, hunk: DiffHunk) -> String {
    "\(filePath):\(hunk.oldStart):\(hunk.oldCount):\(hunk.newStart):\(hunk.newCount)"
  }
}

private struct VerificationPanel: View {
  let result: VerificationResult?
  let browserResult: BrowserVerificationResult?
  let isVerifying: Bool
  let verify: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(isVerifying ? "正在验证" : result?.passed == true ? "验证通过" : "尚未验证")
            .font(.subheadline.weight(.semibold))
          Text("仅以真实测试与构建结果作为合并依据。")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        Spacer()
        Button(isVerifying ? "验证中…" : "运行", action: verify)
          .controlSize(.small)
          .tint(WorkbenchTheme.accent)
          .disabled(isVerifying)
      }

      if let result {
        ForEach(result.steps) { step in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Label(step.kind.rawValue, systemImage: step.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(step.passed ? WorkbenchTheme.success : WorkbenchTheme.destructive)
              Spacer()
              Text("exit \(step.exitCode)")
                .font(.caption2.monospaced())
            }
            if !step.standardOutput.isEmpty {
              Text(step.standardOutput)
                .font(.caption2.monospaced())
                .lineLimit(4)
                .textSelection(.enabled)
            }
            if !step.standardError.isEmpty {
              Text(step.standardError)
                .font(.caption2.monospaced())
                .foregroundStyle(WorkbenchTheme.destructive)
                .lineLimit(4)
                .textSelection(.enabled)
            }
          }
          .padding(.vertical, 4)
          if step.id != result.steps.last?.id { Divider() }
        }
      }

      if let browserResult {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label(
              browserResult.passed ? "浏览器验证通过" : "浏览器验证失败",
              systemImage: browserResult.passed ? "safari.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(browserResult.passed ? WorkbenchTheme.success : WorkbenchTheme.destructive)
            Spacer()
            if let currentURL = browserResult.currentURL {
              Text(currentURL.host(percentEncoded: false) ?? currentURL.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(WorkbenchTheme.secondaryText)
            }
          }
          ForEach(browserResult.artifacts.prefix(4)) { artifact in
            VStack(alignment: .leading, spacing: 3) {
              Text(artifact.kind.rawValue)
                .font(.caption2.weight(.semibold))
              Text(artifact.path ?? artifact.text ?? artifact.name)
                .font(.caption2.monospaced())
                .foregroundStyle(artifact.kind == .consoleError ? WorkbenchTheme.destructive : WorkbenchTheme.secondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
            }
          }
        }
      }
    }
  }
}

private struct IntegrationManagementPanel: View {
  let accounts: [AccountRecord]
  let connect: (IntegrationProvider, String, String, String) -> Void
  let disconnect: (IntegrationProvider) -> Void
  let openAuthorization: (IntegrationProvider) -> Void
  @State private var expandedProviders: Set<IntegrationProvider> = [.github, .gitlab]
  @State private var drafts: [IntegrationProvider: IntegrationDraft] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("外部集成")
            .font(.subheadline.weight(.semibold))
          Text(summary)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        Spacer()
      }

      ForEach(IntegrationProvider.allCases) { provider in
        IntegrationProviderCard(
          provider: provider,
          account: account(for: provider),
          isExpanded: expandedProviders.contains(provider),
          draft: binding(for: provider),
          toggle: {
            if expandedProviders.contains(provider) {
              expandedProviders.remove(provider)
            } else {
              expandedProviders.insert(provider)
            }
          },
          openAuthorization: { openAuthorization(provider) },
          connect: { draft in
            connect(provider, draft.accountName, draft.credential, draft.defaultRepository)
          },
          disconnect: { disconnect(provider) }
        )
      }
    }
    .padding(14)
    .workbenchSurface(color: WorkbenchTheme.content, radius: WorkbenchTheme.controlRadius)
  }

  private var summary: String {
    let connected = accounts.filter(\.isConnected).count
    return "\(connected) 个已连接 · token 存储在本机安全凭据库"
  }

  private func account(for provider: IntegrationProvider) -> AccountRecord {
    accounts.first { $0.provider == provider } ?? AccountRecord(provider: provider)
  }

  private func binding(for provider: IntegrationProvider) -> Binding<IntegrationDraft> {
    Binding(
      get: {
        drafts[provider] ?? IntegrationDraft(accountName: account(for: provider).accountName, defaultRepository: account(for: provider).defaultRepository ?? "")
      },
      set: { drafts[provider] = $0 }
    )
  }
}

private struct KimiRuntimeStatusCard: View {
  let identity: KimiRuntimeIdentityRecord
  let availableModelCount: Int
  let lastRefreshAt: Date?
  let isRefreshingModels: Bool
  let modelRefreshError: String?
  let openSettings: () -> Void
  let refreshModels: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Kimi 连接", systemImage: "server.rack")
          .font(.caption.weight(.semibold))
        Spacer()
        Circle()
          .fill(identity.mode == .apiKey && identity.isAPIConfigured ? WorkbenchTheme.success : WorkbenchTheme.warning)
          .frame(width: 7, height: 7)
      }
      InspectorRow(label: "模式", value: identity.mode.fullTitle)
      InspectorRow(label: "模型", value: identity.modelID, monospaced: true)
      InspectorRow(label: "可选模型", value: identity.mode == .apiKey ? "\(availableModelCount) 个" : "Kimi Code 内置")
      if let lastRefreshAt {
        InspectorRow(label: "刷新", value: lastRefreshAt.formatted(date: .omitted, time: .shortened))
      }
      InspectorRow(label: "Base URL", value: identity.baseURL, monospaced: true)
      InspectorRow(
        label: "Key",
        value: identity.mode == .apiKey
          ? (identity.isAPIConfigured ? "已配置" : "未配置")
          : (identity.apiKeyStatus == "configured" ? "已保存" : "未配置")
      )
      if let modelRefreshError, !modelRefreshError.isEmpty {
        Text("模型刷新失败：\(modelRefreshError)")
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button(isRefreshingModels ? "刷新中…" : "刷新模型", action: refreshModels)
          .controlSize(.small)
          .disabled(isRefreshingModels || !identity.isAPIConfigured)
        Spacer()
        Button("打开连接设置", action: openSettings)
          .controlSize(.small)
      }
    }
    .padding(12)
    .workbenchSurface(color: WorkbenchTheme.canvas, radius: WorkbenchTheme.smallRadius)
  }
}

private struct IntegrationDraft: Equatable {
  var accountName = ""
  var credential = ""
  var defaultRepository = ""
}

private struct IntegrationProviderCard: View {
  let provider: IntegrationProvider
  let account: AccountRecord
  let isExpanded: Bool
  @Binding var draft: IntegrationDraft
  let toggle: () -> Void
  let openAuthorization: () -> Void
  let connect: (IntegrationDraft) -> Void
  let disconnect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: toggle) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .frame(width: 12)
          Circle()
            .fill(account.isConnected ? WorkbenchTheme.success : WorkbenchTheme.warning)
            .frame(width: 7, height: 7)
          Text(provider.title)
            .font(.caption.weight(.semibold))
          Text(account.isConnected ? "connected" : "needs token")
            .font(.caption2.monospaced())
            .foregroundStyle(account.isConnected ? WorkbenchTheme.success : WorkbenchTheme.warning)
          Spacer()
        }
      }
      .buttonStyle(.plain)
      .workbenchHoverFeedback(radius: 8, hoverColor: WorkbenchTheme.accent)

      if isExpanded {
        VStack(alignment: .leading, spacing: 8) {
          InspectorRow(label: "账号", value: account.accountName.isEmpty ? "未连接" : account.accountName)
          InspectorRow(label: "Token", value: account.tokenStatus)
          InspectorRow(label: "默认仓库", value: account.defaultRepository ?? "未绑定", monospaced: true)
          if let lastSyncedAt = account.lastSyncedAt {
            InspectorRow(label: "同步", value: lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
          }

          TextField("账号名称", text: $draft.accountName)
            .textFieldStyle(.roundedBorder)
          SecureField("Access Token / OAuth Token", text: $draft.credential)
            .textFieldStyle(.roundedBorder)
          TextField(provider == .github ? "owner/repo" : "group/project", text: $draft.defaultRepository)
            .textFieldStyle(.roundedBorder)

          HStack(spacing: 8) {
            Button("授权页", action: openAuthorization)
              .controlSize(.small)
            Button("保存凭据") {
              connect(draft)
              draft.credential = ""
            }
            .controlSize(.small)
            .tint(WorkbenchTheme.accent)
            .disabled(draft.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if account.isConnected {
              Button("断开", role: .destructive, action: disconnect)
                .controlSize(.small)
            }
          }
        }
        .padding(.leading, 18)
      }
    }
  }
}

private struct WebResearchSourcesPanel: View {
  let sources: [WebResearchSource]
  let usage: WebResearchUsageRecord
  let citationStatus: WebResearchCitationStatus
  let retry: (WebResearchSource) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "globe.asia.australia")
          .foregroundStyle(WorkbenchTheme.accent)
        Text("联网来源")
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 8)
        if usage.searchCount + usage.fetchCount > 0 {
          Text("搜索 \(usage.searchCount) · 抓取 \(usage.fetchCount)")
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        Text(citationLabel)
          .font(.caption2.weight(.medium))
          .foregroundStyle(citationColor)
      }

      if sources.isEmpty {
        Text("本轮尚未产生可引用来源。联网后，搜索和抓取结果会保存在这里，重启后仍可审阅。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ForEach(sources.prefix(8)) { source in
          SourceRow(source: source, retry: { retry(source) })
        }
        if sources.count > 8 {
          Text("另有 \(sources.count - 8) 个来源已保存在本地任务记录中。")
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
      }
    }
    .padding(14)
    .workbenchSurface(color: WorkbenchTheme.content, radius: WorkbenchTheme.controlRadius)
  }

  private var citationLabel: String {
    switch citationStatus {
    case .notApplicable: ""
    case .pending: "引用检查中"
    case .verified: "引用已验证"
    case .needsReview: "引用待审阅"
    }
  }

  private var citationColor: Color {
    switch citationStatus {
    case .notApplicable, .pending: WorkbenchTheme.secondaryText
    case .verified: WorkbenchTheme.success
    case .needsReview: WorkbenchTheme.warning
    }
  }
}

private struct SourceRow: View {
  let source: WebResearchSource
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
          .padding(.top, 5)
        VStack(alignment: .leading, spacing: 2) {
          Text(source.title)
            .font(.caption.weight(.medium))
            .lineLimit(2)
          Text(source.domain)
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 2)
        Button(action: openSource) {
          Image(systemName: "arrow.up.right.square")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius)
        .help("在默认浏览器打开来源")
      }

      if let evidence = source.summary?.isEmpty == false ? source.summary : source.snippet.nonEmpty {
        Text(evidence)
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText)
          .lineLimit(3)
      }

      HStack(spacing: 8) {
        Button("复制引用", action: copyCitation)
          .buttonStyle(.plain)
          .font(.caption2.weight(.medium))
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius)
        Button("重新抓取", action: retry)
          .buttonStyle(.plain)
          .font(.caption2.weight(.medium))
          .foregroundStyle(WorkbenchTheme.accent)
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius)
      }
    }
    .padding(.vertical, 4)
  }

  private var statusColor: Color {
    switch source.status {
    case .discovered: WorkbenchTheme.accent
    case .fetched: WorkbenchTheme.success
    case .failed: WorkbenchTheme.destructive
    }
  }

  private func openSource() {
    guard let url = URL(string: source.url) else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyCitation() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("\(source.title) — \(source.url)", forType: .string)
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

private struct CompletionInspector: View {
  let task: AgentTask

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(task.status == .merged ? "变更已合并" : "任务已完成")
        .font(.subheadline.weight(.semibold))
      Text(task.status == .merged
           ? "已将经过审阅的 Worktree 变更写入项目分支。"
           : "此任务的活动记录、Diff 和验证结果会保存在本机，随时可以回看。")
        .font(.subheadline)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ExtensionManagementPanel: View {
  let configuration: ProjectAgentConfiguration?
  let discoveredSkills: [SkillDescriptor]
  let plugins: [KimiPluginDescriptor]
  let hookResults: [HookResult]
  let mcpStatuses: [MCPServerStatus]
  let refresh: () -> Void
  let openConfiguration: () -> Void
  @State private var expandedSections: Set<String> = ["skills", "hooks", "mcp"]
  @State private var selectedRowID: String?

  private var presentation: ExtensionManagementPresentation {
    ExtensionManagementPresentation(
      configuration: configuration,
      discoveredSkills: discoveredSkills,
      hookResults: hookResults,
      mcpStatuses: mcpStatuses,
      plugins: plugins
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(presentation.title)
            .font(.subheadline.weight(.semibold))
          Text(presentation.subtitle)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
        }
        Spacer(minLength: 8)
        Button("刷新", action: refresh)
          .buttonStyle(.plain)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(WorkbenchTheme.canvas.opacity(0.72), in: Capsule())
          .overlay {
            Capsule().strokeBorder(WorkbenchTheme.border.opacity(0.8), lineWidth: 1)
          }
          .workbenchHoverFeedback(radius: 999)
        Button("配置", action: openConfiguration)
          .buttonStyle(.plain)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(WorkbenchTheme.canvas.opacity(0.72), in: Capsule())
          .overlay {
            Capsule().strokeBorder(WorkbenchTheme.border.opacity(0.8), lineWidth: 1)
          }
          .workbenchHoverFeedback(radius: 999)
      }

      ForEach(presentation.sections) { section in
        ExtensionManagementSectionView(
          section: section,
          isExpanded: expandedSections.contains(section.id),
          selectedRowID: selectedRowID,
          toggleExpansion: {
            if expandedSections.contains(section.id) {
              expandedSections.remove(section.id)
            } else {
              expandedSections.insert(section.id)
            }
          },
          selectRow: { rowID in
            selectedRowID = rowID
            expandedSections.insert(section.id)
          }
        )
        if section.id != presentation.sections.last?.id {
          Divider().overlay(WorkbenchTheme.border.opacity(0.75))
        }
      }

      if let selectedRow = selectedRow {
        ExtensionManagementDetailCard(row: selectedRow)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .padding(14)
    .workbenchSurface(color: WorkbenchTheme.content, radius: WorkbenchTheme.controlRadius)
    .animation(WorkbenchTheme.shortAnimation, value: expandedSections)
    .animation(WorkbenchTheme.shortAnimation, value: selectedRowID)
  }

  private var selectedRow: ExtensionManagementRow? {
    for section in presentation.sections {
      if let row = section.rows.first(where: { $0.id == selectedRowID }) {
        return row
      }
    }
    return nil
  }
}

private struct ExtensionManagementSectionView: View {
  let section: ExtensionManagementSection
  let isExpanded: Bool
  let selectedRowID: String?
  let toggleExpansion: () -> Void
  let selectRow: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: toggleExpansion) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .frame(width: 12)
          Text(section.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.primaryText)
          Text(section.summary)
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .lineLimit(1)
          Spacer()
        }
        .padding(.vertical, 2)
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
      .workbenchHoverFeedback(radius: 8, hoverColor: WorkbenchTheme.primaryText)

      if isExpanded {
        if section.rows.isEmpty {
          Text("暂无内容。")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .padding(.leading, 18)
        } else {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(section.rows) { row in
              ExtensionManagementRowView(
                row: row,
                isSelected: row.id == selectedRowID,
                selectRow: selectRow
              )
            }
          }
          .padding(.leading, 18)
        }
      }
    }
  }
}

private struct ExtensionManagementRowView: View {
  let row: ExtensionManagementRow
  let isSelected: Bool
  let selectRow: (String) -> Void

  private var tint: Color {
    switch row.severity {
    case .neutral: WorkbenchTheme.secondaryText
    case .success: WorkbenchTheme.success
    case .warning: WorkbenchTheme.warning
    case .destructive: WorkbenchTheme.destructive
    }
  }

  var body: some View {
    Button {
      selectRow(row.id)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle()
          .fill(tint)
          .frame(width: 6, height: 6)
          .padding(.top, 5)
        VStack(alignment: .leading, spacing: 2) {
          Text(row.title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
          Text(row.detail)
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Text(row.statusText)
          .font(.caption2.monospaced())
          .foregroundStyle(tint)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(WorkbenchTheme.canvas, in: Capsule())
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(
        isSelected ? WorkbenchTheme.accentSurface.opacity(0.92) : WorkbenchTheme.canvas.opacity(0.42),
        in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous)
          .strokeBorder(
            isSelected ? WorkbenchTheme.accent.opacity(0.72) : WorkbenchTheme.border.opacity(0.62),
            lineWidth: 1
          )
      }
      .shadow(
        color: isSelected ? WorkbenchTheme.accent.opacity(0.14) : .clear,
        radius: isSelected ? 7 : 0,
        x: 0,
        y: 2
      )
    }
    .buttonStyle(.plain)
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius, hoverColor: WorkbenchTheme.accent)
  }
}

private struct ExtensionManagementDetailCard: View {
  let row: ExtensionManagementRow

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle()
          .fill(WorkbenchTheme.accent)
          .frame(width: 6, height: 6)
        Text(row.title)
          .font(.caption.weight(.semibold))
        Text(row.statusText)
          .font(.caption2.monospaced())
          .foregroundStyle(WorkbenchTheme.secondaryText)
        Spacer()
      }
      Text(row.detail)
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)
      ForEach(row.details, id: \.self) { detail in
        HStack(alignment: .top, spacing: 6) {
          Rectangle()
            .fill(WorkbenchTheme.secondaryText.opacity(0.38))
            .frame(width: 4, height: 4)
            .padding(.top, 6)
          Text(detail)
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.secondaryText)
          Spacer()
        }
      }
    }
    .padding(10)
    .background(WorkbenchTheme.canvas.opacity(0.62), in: RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchTheme.smallRadius, style: .continuous)
        .strokeBorder(WorkbenchTheme.border.opacity(0.58), lineWidth: 1)
    }
  }
}

private struct KimiLoginSheet: View {
  @ObservedObject var model: DesktopAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectedMode: KimiRuntimeIdentityMode
  @State private var apiKey = ""
  @State private var baseURL: String
  @State private var apiModelID: String

  init(model: DesktopAppModel) {
    self.model = model
    _selectedMode = State(initialValue: model.kimiRuntimeIdentity.mode)
    _baseURL = State(initialValue: model.kimiRuntimeIdentity.baseURL)
    _apiModelID = State(initialValue: model.kimiRuntimeIdentity.modelID)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Kimi 连接")
          .font(.title2.weight(.semibold))
        Text("API Key 模式使用你的 Moonshot / Kimi API 额度；Kimi Code 模式使用独立的网页登录配置。两者不会互相覆盖。")
          .foregroundStyle(WorkbenchTheme.secondaryText)
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: model.credentialStorageMode == .keychain ? "key.fill" : "lock.document.fill")
            .foregroundStyle(WorkbenchTheme.accent)
          VStack(alignment: .leading, spacing: 3) {
            Text("凭据存储：\(model.credentialStorageTitle)")
              .font(.caption.weight(.semibold))
            Text(model.credentialStorageHint)
              .font(.caption2)
              .foregroundStyle(WorkbenchTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(10)
        .workbenchSurface(color: WorkbenchTheme.accentSurface, radius: WorkbenchTheme.smallRadius)

        Picker("连接方式", selection: $selectedMode) {
          ForEach(KimiRuntimeIdentityMode.allCases, id: \.self) { mode in
            Text(mode.fullTitle).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedMode) { _, newValue in
          if newValue == .kimiCode {
            model.selectKimiRuntimeMode(.kimiCode)
          } else if model.kimiRuntimeIdentity.isAPIConfigured {
            model.selectKimiRuntimeMode(.apiKey)
          }
        }

        HStack(spacing: 8) {
          Circle()
            .fill(model.kimiRuntimeIdentity.mode == .apiKey && model.kimiRuntimeIdentity.isAPIConfigured ? WorkbenchTheme.success : WorkbenchTheme.warning)
            .frame(width: 8, height: 8)
          Text(currentStatus)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.secondaryText)
          Spacer()
        }

        if selectedMode == .apiKey {
          apiKeyForm
        } else {
          kimiCodeLoginForm
        }

        Divider()
          .overlay(WorkbenchTheme.border)

        WebResearchSettingsForm(model: model)

        HStack {
          Spacer()
          Button("关闭") { dismiss() }
        }
      }
      .padding(24)
    }
    .frame(minWidth: 640, minHeight: 620)
    .onChange(of: model.kimiRuntimeIdentity) { _, identity in
      if selectedMode == identity.mode {
        baseURL = identity.baseURL
        apiModelID = identity.modelID
      }
    }
  }

  private var currentStatus: String {
    switch model.kimiRuntimeIdentity.mode {
    case .apiKey:
      model.kimiRuntimeIdentity.isAPIConfigured
        ? "当前使用 API Key 模式 · \(model.kimiRuntimeIdentity.modelID)"
        : "API Key 模式尚未配置"
    case .kimiCode:
      "当前使用 Kimi Code 登录模式"
    }
  }

  private var apiKeyForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 7) {
        Text("API Key")
          .font(.caption.weight(.semibold))
        SecureField(model.kimiRuntimeIdentity.isAPIConfigured ? "已保存，可留空只更新模型或 Base URL" : "例如：sk-xxxxxxxxxxxxxxxx", text: $apiKey)
          .textFieldStyle(.roundedBorder)
        ConnectionGuidanceBlock(
          title: "怎么填",
          hint: KimiRuntimeConnectionGuidance.apiKeyHint(),
          example: KimiRuntimeConnectionGuidance.apiKeyExample()
        )
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("Base URL")
          .font(.caption.weight(.semibold))
        TextField("例如：https://api.moonshot.cn/v1", text: $baseURL)
          .textFieldStyle(.roundedBorder)
        ConnectionGuidanceBlock(
          title: "怎么填",
          hint: KimiRuntimeConnectionGuidance.baseURLHint(),
          example: KimiRuntimeConnectionGuidance.baseURLExample()
        )
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("默认模型")
          .font(.caption.weight(.semibold))
        ModelSelectionMenu(
          selectedModelID: $apiModelID,
          availableModels: model.kimiAvailableModels,
          isRefreshingModels: model.isRefreshingKimiModels,
          modelRefreshError: model.kimiModelRefreshError,
          refreshModels: model.refreshKimiModels
        )
        ConnectionGuidanceBlock(
          title: "怎么选",
          hint: KimiRuntimeConnectionGuidance.modelHint(),
          example: KimiRuntimeConnectionGuidance.modelExample()
        )
        Text("这里会写入 Kimi Code 的本地 provider 配置；Composer 里的模型选择仍可为单个任务覆盖。")
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }

      HStack(spacing: 10) {
        Button("保存并启用 API 模式") {
          model.saveKimiAPIConnection(apiKey: apiKey, baseURL: baseURL, modelID: apiModelID)
          apiKey = ""
          selectedMode = .apiKey
        }
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchTheme.accent)
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.kimiRuntimeIdentity.isAPIConfigured)

        if model.kimiRuntimeIdentity.isAPIConfigured {
          Button("清除 API Key", role: .destructive) {
            model.disconnectKimiAPIConnection()
            selectedMode = .kimiCode
            apiKey = ""
          }
        }
      }
    }
    .padding(14)
    .workbenchSurface(color: WorkbenchTheme.sidebar, radius: WorkbenchTheme.smallRadius)
  }

  private var kimiCodeLoginForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      ConnectionGuidanceBlock(
        title: "怎么做",
        hint: KimiRuntimeConnectionGuidance.codeModeHint(),
        example: KimiRuntimeConnectionGuidance.codeModeExample()
      )

      ScrollView {
        Text(model.loginOutput.isEmpty ? "等待登录输出…" : model.loginOutput)
          .font(.callout.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .padding(12)
      .workbenchSurface(color: WorkbenchTheme.sidebar, radius: WorkbenchTheme.smallRadius)

      HStack {
        Button("开始 Kimi Code 登录", action: model.startKimiLogin)
          .buttonStyle(.borderedProminent)
          .tint(WorkbenchTheme.accent)
        Button("停止", role: .destructive, action: model.stopKimiLogin)
        Spacer()
      }
    }
  }
}

private struct WebResearchSettingsForm: View {
  @ObservedObject var model: DesktopAppModel
  @State private var provider: WebSearchProvider
  @State private var apiKey = ""
  @State private var endpoint: String
  @State private var allowedDomains: String
  @State private var defaultResultLimit: Int
  @State private var showAdvanced = false

  init(model: DesktopAppModel) {
    self.model = model
    _provider = State(initialValue: model.webResearchSettings.provider)
    _endpoint = State(initialValue: model.webResearchSettings.endpoint)
    _allowedDomains = State(initialValue: model.webResearchSettings.allowedDomains.joined(separator: ", "))
    _defaultResultLimit = State(initialValue: model.webResearchSettings.defaultResultLimit)
    _showAdvanced = State(initialValue: model.webResearchSettings.provider != .kimiOfficial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Web Search 与 Fetch")
          .font(.headline.weight(.semibold))
        Circle()
          .fill(connectionPresentation.isReady ? WorkbenchTheme.success : WorkbenchTheme.warning)
          .frame(width: 7, height: 7)
        Text(connectionPresentation.statusText)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.secondaryText)
        Spacer()
      }

      Text("普通用户默认使用 Kimi 官方联网，直接复用 Kimi API 额度；搜索结果会进入来源中心，抓取正文后在回答中带回可点击引用。")
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.secondaryText)

      if !showAdvanced {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "checkmark.shield")
            .foregroundStyle(WorkbenchTheme.success)
          VStack(alignment: .leading, spacing: 4) {
            Text("Kimi 官方联网（推荐）")
              .font(.subheadline.weight(.semibold))
            Text("不需要 Brave Key 或 SearxNG 地址。只要当前连接使用 Kimi API Key，搜索和 FetchURL 会复用你的 Kimi API 额度。")
              .font(.caption)
              .foregroundStyle(WorkbenchTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 6)
        }
        .padding(12)
        .workbenchSurface(color: WorkbenchTheme.accentSurface, radius: WorkbenchTheme.smallRadius)

        HStack(spacing: 10) {
          Button("测试官方联网") {
            model.testWebResearchConnection()
          }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchTheme.accent)
          Button("高级：自定义搜索服务") {
            showAdvanced = true
            if provider == .kimiOfficial {
              provider = .brave
              endpoint = WebResearchSettingsStore.defaultBraveEndpoint
            }
          }
          .buttonStyle(.plain)
          .font(.caption.weight(.medium))
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius)
        }
      } else {
        HStack {
          Text("高级自定义联网服务")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Button("改回 Kimi 官方联网") {
            provider = .kimiOfficial
            endpoint = WebResearchSettingsStore.defaultKimiOfficialEndpoint
            showAdvanced = false
          }
          .buttonStyle(.plain)
          .font(.caption.weight(.medium))
          .foregroundStyle(WorkbenchTheme.accent)
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius)
        }

        Picker("搜索服务", selection: $provider) {
          Text(WebSearchProvider.brave.title).tag(WebSearchProvider.brave)
          Text(WebSearchProvider.searxng.title).tag(WebSearchProvider.searxng)
        }
        .pickerStyle(.segmented)
        .onChange(of: provider) { _, value in
          if value == .brave, endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endpoint = WebResearchSettingsStore.defaultBraveEndpoint
          }
        }
      }

      if showAdvanced && provider.requiresAPIKey {
        VStack(alignment: .leading, spacing: 7) {
          Text("Brave Search API Key")
            .font(.caption.weight(.semibold))
          SecureField(model.webResearchSettings.apiKeyStatus == "configured" ? "已保存，可留空只更新其他设置" : "例如：BSA-xxxxxxxxxxxxxxxx", text: $apiKey)
            .textFieldStyle(.roundedBorder)
          ConnectionGuidanceBlock(
            title: "怎么填",
            hint: "填写 Brave Search API 的订阅 Key。它会保存到本机安全凭据库，不会写入项目或普通日志。",
            example: "示例：BSA-xxxxxxxxxxxxxxxx"
          )
        }
      }

      if showAdvanced {
        VStack(alignment: .leading, spacing: 7) {
        Text(provider == .brave ? "Brave API 地址" : "SearxNG 搜索地址")
          .font(.caption.weight(.semibold))
        TextField(provider == .brave ? "https://api.search.brave.com/res/v1/web/search" : "例如：https://search.example.com/search", text: $endpoint)
          .textFieldStyle(.roundedBorder)
        ConnectionGuidanceBlock(
          title: "怎么填",
          hint: provider == .brave
            ? "通常保持默认 Brave API 地址。"
            : "填写你自己部署的 SearxNG 的 /search 地址；系统会请求 JSON 格式结果。",
          example: provider == .brave
            ? "示例：https://api.search.brave.com/res/v1/web/search"
            : "示例：https://search.example.com/search"
        )
        }
      }

      HStack(spacing: 16) {
        Stepper("默认返回 \(defaultResultLimit) 条", value: $defaultResultLimit, in: 1...10)
          .font(.caption)
        Text("结果越少，速度和模型上下文成本越可控。")
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.secondaryText)
      }

      if showAdvanced {
        VStack(alignment: .leading, spacing: 7) {
        Text("Native Host 直接抓取授权域名（高级）")
          .font(.caption.weight(.semibold))
        TextField("例如：docs.moonshot.cn, github.com", text: $allowedDomains)
          .textFieldStyle(.roundedBorder)
        ConnectionGuidanceBlock(
          title: "怎么用",
          hint: "用逗号、空格或换行分隔域名。它约束 Native Host 的 web.fetch / network.fetch；CLI 回退时的 FetchURL 仍遵循 Kimi Code 自身的公共 URL 安全策略。",
          example: "搜索结果携带 sourceID 时，Native Host 可对该结果做一次只读正文抓取，不需要预先把每个来源都填进这里。"
        )
        }
      }

      HStack(spacing: 10) {
        Button("保存并启用联网研究") {
          model.saveWebResearchSettings(
            provider: provider,
            apiKey: apiKey,
            endpoint: endpoint,
            allowedDomains: allowedDomains,
            defaultResultLimit: defaultResultLimit
          )
          apiKey = ""
        }
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchTheme.accent)

        if showAdvanced {
          Button("测试自定义服务") {
            model.testWebResearchConnection()
          }
          .buttonStyle(.plain)
          .font(.caption.weight(.medium))
          .workbenchHoverFeedback(radius: WorkbenchTheme.smallRadius)
        }

        if model.webResearchSettings.isEnabled {
          Button("关闭并清除 Key", role: .destructive) {
            model.disconnectWebResearch()
            apiKey = ""
          }
        }
      }
    }
    .padding(14)
    .workbenchSurface(color: WorkbenchTheme.sidebar, radius: WorkbenchTheme.smallRadius)
    .onChange(of: model.webResearchSettings) { _, value in
      provider = value.provider
      endpoint = value.endpoint
      allowedDomains = value.allowedDomains.joined(separator: ", ")
      defaultResultLimit = value.defaultResultLimit
      showAdvanced = value.provider != .kimiOfficial
    }
  }

  private var connectionPresentation: WebResearchConnectionPresentation {
    WebResearchConnectionPresentation(
      settings: model.webResearchSettings,
      identity: model.kimiRuntimeIdentity,
      capability: model.webResearchCapability
    )
  }
}

private struct ConnectionGuidanceBlock: View {
  let title: String
  let hint: String
  let example: String

  init(_ text: String) {
    self.title = "说明"
    self.hint = text
    self.example = ""
  }

  init(title: String, hint: String, example: String) {
    self.title = title
    self.hint = hint
    self.example = example
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.secondaryText)
      Text(hint)
        .font(.caption2)
        .foregroundStyle(WorkbenchTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if !example.isEmpty {
        Text(example)
          .font(.caption2)
          .foregroundStyle(WorkbenchTheme.accent)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension TaskMode {
  var title: String {
    switch self {
    case .plan: "Plan"
    case .edit: "Edit"
    case .agent: "Agent"
    }
  }

  var safetyNote: String {
    switch self {
    case .plan: "只分析和规划，不写入项目文件。"
    case .edit: "面向明确的代码变更；不会默认开启自动授权。"
    case .agent: "适合连续执行任务；高风险操作需要明确审批。"
    }
  }
}

private extension KimiRuntimeIdentityMode {
  var shortTitle: String {
    switch self {
    case .kimiCode: "Kimi Code"
    case .apiKey: "API Key"
    }
  }

  var fullTitle: String {
    switch self {
    case .kimiCode: "Kimi Code 登录"
    case .apiKey: "API Key 模式"
    }
  }
}

private extension TaskStatus {
  var title: String {
    switch self {
    case .draft: "草稿"
    case .planning: "已创建"
    case .running: "执行中"
    case .waitingForApproval: "等待审批"
    case .waitingForUser: "等待操作"
    case .reviewReady: "待审阅"
    case .verifying: "验证中"
    case .mergeReady: "可合并"
    case .merged: "已合并"
    case .completed: "已完成"
    case .failed: "失败"
    case .cancelled: "已停止"
    case .blocked: "受阻"
    }
  }

  var tint: Color {
    switch self {
    case .draft, .planning: WorkbenchTheme.secondaryText
    case .running: WorkbenchTheme.accent
    case .waitingForApproval, .waitingForUser: WorkbenchTheme.warning
    case .reviewReady, .mergeReady, .merged, .completed: WorkbenchTheme.success
    case .verifying: WorkbenchTheme.accent
    case .failed, .cancelled, .blocked: WorkbenchTheme.destructive
    }
  }
}

private extension WorkItemStatus {
  var title: String {
    switch self {
    case .queued: "等待中"
    case .planning: "规划中"
    case .awaitingApproval: "等待审批"
    case .running: "执行中"
    case .reviewReady: "待审阅"
    case .verifying: "验证中"
    case .mergeReady: "可合并"
    case .merged: "已合并"
    case .failed: "失败"
    case .retrying: "重试中"
    case .blocked: "受阻"
    case .cancelling: "正在停止"
    case .cancelled: "已停止"
    case .cleaned: "已清理"
    }
  }

  var tint: Color {
    switch self {
    case .queued: WorkbenchTheme.secondaryText
    case .planning, .running, .retrying: WorkbenchTheme.accent
    case .awaitingApproval: WorkbenchTheme.warning
    case .reviewReady, .mergeReady, .merged, .cleaned: WorkbenchTheme.success
    case .verifying: WorkbenchTheme.accent
    case .failed, .blocked, .cancelling, .cancelled: WorkbenchTheme.destructive
    }
  }
}

private extension WorkerRole {
  var title: String {
    switch self {
    case .analyzer: "分析"
    case .implementer: "实现"
    case .testRunner: "测试"
    case .reviewer: "审阅"
    }
  }

  var symbolName: String {
    switch self {
    case .analyzer: "magnifyingglass"
    case .implementer: "hammer"
    case .testRunner: "checkmark.circle"
    case .reviewer: "eye"
    }
  }
}
