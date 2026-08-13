import Foundation

/// A lightweight VT-style screen buffer for transcript rendering.
///
/// It intentionally does not emulate every xterm feature, but it covers the control sequences emitted by shells,
/// progress bars and common test runners so the user sees a stable terminal transcript rather than raw CR/ESC bytes.
public enum TerminalScreenBuffer {
  public static func render(_ input: String) -> String {
    var lines: [[Character]] = [[]]
    var row = 0
    var column = 0
    var index = input.startIndex

    func ensureRow(_ target: Int) {
      while lines.count <= target { lines.append([]) }
    }

    func eraseToLineEnd() {
      ensureRow(row)
      guard column < lines[row].count else { return }
      lines[row].removeSubrange(column..<lines[row].count)
    }

    func write(_ character: Character) {
      ensureRow(row)
      while lines[row].count < column { lines[row].append(" ") }
      if column < lines[row].count { lines[row][column] = character }
      else { lines[row].append(character) }
      column += 1
    }

    while index < input.endIndex {
      let character = input[index]
      if character == "\u{001B}", input.index(after: index) < input.endIndex, input[input.index(after: index)] == "[" {
        var cursor = input.index(index, offsetBy: 2)
        var parameters = ""
        while cursor < input.endIndex {
          let value = input[cursor]
          cursor = input.index(after: cursor)
          if value.isLetter || value == "@" || value == "`" || value == "~" {
            let numbers = parameters.split(separator: ";").compactMap { Int($0) }
            let amount = max(1, numbers.first ?? 1)
            switch value {
            case "K": eraseToLineEnd()
            case "J":
              if (numbers.first ?? 0) == 2 {
                lines = [[]]
                row = 0
                column = 0
              } else {
                eraseToLineEnd()
                if row + 1 < lines.count { lines.removeSubrange((row + 1)..<lines.count) }
              }
            case "A": row = max(0, row - amount)
            case "B": row += amount; ensureRow(row)
            case "C": column += amount
            case "D": column = max(0, column - amount)
            case "G": column = max(0, amount - 1)
            case "H", "f":
              row = max(0, (numbers.first ?? 1) - 1)
              column = max(0, (numbers.dropFirst().first ?? 1) - 1)
              ensureRow(row)
            default:
              break // SGR and unsupported CSI instructions affect presentation but not text geometry.
            }
            break
          }
          parameters.append(value)
        }
        index = cursor
        continue
      }

      switch character {
      case "\r": column = 0
      case "\n": row += 1; ensureRow(row); column = 0
      case "\u{08}", "\u{7F}": column = max(0, column - 1)
      default: write(character)
      }
      index = input.index(after: index)
    }
    return lines.map { String($0) }.joined(separator: "\n")
  }
}
