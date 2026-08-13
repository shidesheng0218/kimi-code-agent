import Foundation

public struct StreamingLineBuffer: Sendable {
  private var pending = ""

  public init() {}

  public mutating func append(_ text: String) -> [String] {
    pending += text
    var lines: [String] = []

    while let newline = pending.firstIndex(of: "\n") {
      let line = pending[..<newline].trimmingCharacters(in: .newlines)
      if !line.isEmpty {
        lines.append(line)
      }
      pending.removeSubrange(...newline)
    }

    return lines
  }

  public mutating func flush() -> [String] {
    let line = pending.trimmingCharacters(in: .newlines)
    pending = ""
    return line.isEmpty ? [] : [line]
  }
}
