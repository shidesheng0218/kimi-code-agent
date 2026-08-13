import SwiftUI

@main
struct KimiAgentDesktopApp: App {
  @StateObject private var model = DesktopAppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      DesktopWorkbench(model: model)
        .frame(minWidth: 1_080, minHeight: 720)
    }
    .defaultSize(width: 1_280, height: 800)
    .windowStyle(.hiddenTitleBar)
    .onChange(of: scenePhase) { _, phase in
      if phase == .inactive {
        model.flushPendingState()
      }
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button("选择项目文件夹…") {
          model.chooseWorkspace()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("创建任务") {
          model.createTask()
        }
        .keyboardShortcut(.return, modifiers: [.command])
      }
    }

    WindowGroup("终端", id: "terminal-workspace") {
      DetachedTerminalWorkspace(model: model)
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 980, height: 660)
    .windowStyle(.titleBar)
  }
}
