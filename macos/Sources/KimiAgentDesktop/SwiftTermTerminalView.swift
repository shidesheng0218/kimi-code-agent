import AppKit
import KimiAgentCore
import SwiftTerm
import SwiftUI

/// SwiftUI bridge for the full VT/xterm renderer. PTY ownership stays in DesktopAppModel;
/// this view only feeds bytes into SwiftTerm and routes user input back to the model.
struct SwiftTermTerminalView: NSViewRepresentable {
  let tabID: UUID
  let output: String
  let rows: Int
  let columns: Int
  let sendInput: (Data) -> Void
  let resize: (TerminalViewportMetrics) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(sendInput: sendInput, resize: resize)
  }

  func makeNSView(context: Context) -> TerminalView {
    let options = TerminalOptions(
      cols: max(20, columns),
      rows: max(2, rows),
      termName: "xterm-256color",
      scrollback: 100_000,
      enableSixelReported: true
    )
    let view = TerminalView(frame: .zero, options: options)
    view.configureNativeColors()
    view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.terminalDelegate = context.coordinator
    if !output.isEmpty {
      view.terminal.feed(buffer: ArraySlice(Array(output.utf8)))
    }
    context.coordinator.lastOutput = output
    context.coordinator.tabID = tabID
    context.coordinator.terminalView = view
    return view
  }

  func updateNSView(_ view: TerminalView, context: Context) {
    context.coordinator.sendInput = sendInput
    context.coordinator.resize = resize
    context.coordinator.tabID = tabID

    if context.coordinator.lastOutput == output { return }
    let delta: String
    if output.hasPrefix(context.coordinator.lastOutput) {
      delta = String(output.dropFirst(context.coordinator.lastOutput.count))
    } else {
      view.terminal.resetToInitialState()
      delta = output
    }
    context.coordinator.lastOutput = output
    guard !delta.isEmpty else { return }
    view.terminal.feed(buffer: ArraySlice(Array(delta.utf8)))
  }

  final class Coordinator: NSObject, TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var tabID: UUID?
    var lastOutput = ""
    var sendInput: (Data) -> Void
    var resize: (TerminalViewportMetrics) -> Void

    init(sendInput: @escaping (Data) -> Void, resize: @escaping (TerminalViewportMetrics) -> Void) {
      self.sendInput = sendInput
      self.resize = resize
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
      sendInput(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
      resize(TerminalViewportMetrics(rows: newRows, columns: newCols))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardRead(source: TerminalView) -> Data? {
      // Clipboard reads initiated by OSC 52 remain denied by default.
      nil
    }
  }
}
