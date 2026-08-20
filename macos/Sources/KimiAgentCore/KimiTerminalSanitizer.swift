import Foundation

/// PTY output arrives as a raw byte stream full of ANSI escape sequences
/// (colors, cursor movement, bracketed paste markers such as `ESC[?2004h`).
/// The right-hand terminal pane renders plain text, so the stream must be
/// reduced to visible characters before it reaches SwiftUI.
public enum KimiTerminalSanitizer {
  public static func strip(_ input: String) -> String {
    var output = ""
    output.reserveCapacity(input.count)
    var index = input.startIndex
    while index < input.endIndex {
      let character = input[index]
      switch character {
      case "\u{1B}":
        index = skipEscapeSequence(in: input, from: index)
      case "\u{7}", "\u{0}":
        index = input.index(after: index)
      case "\r":
        // Simulate the carriage return so spinner/progress rewrites collapse
        // onto a single line instead of piling up control noise.
        while let last = output.last, last != "\n" { output.removeLast() }
        index = input.index(after: index)
      case "\u{8}":
        if !output.isEmpty { output.removeLast() }
        index = input.index(after: index)
      default:
        if character.isASCII, let scalar = character.unicodeScalars.first,
           scalar.value < 0x20, character != "\n", character != "\t" {
          index = input.index(after: index)
        } else {
          output.append(character)
          index = input.index(after: index)
        }
      }
    }
    return output
  }

  /// Returns the index just past the escape sequence starting at `escape`
  /// (which points at ESC). Handles CSI (`ESC [ ... final`), OSC
  /// (`ESC ] ... BEL` or `ESC ] ... ESC \`) and plain two-byte escapes.
  private static func skipEscapeSequence(in input: String, from escape: String.Index) -> String.Index {
    let introducer = input.index(after: escape)
    guard introducer < input.endIndex else { return input.endIndex }
    switch input[introducer] {
    case "[":
      // CSI: parameter/intermediate bytes until a final byte in 0x40...0x7E.
      var cursor = input.index(after: introducer)
      while cursor < input.endIndex {
        let current = input[cursor]
        cursor = input.index(after: cursor)
        if current >= "@" && current <= "~" { break }
      }
      return cursor
    case "]":
      // OSC: terminated by BEL or ST (ESC \).
      var cursor = input.index(after: introducer)
      while cursor < input.endIndex {
        let current = input[cursor]
        if current == "\u{7}" {
          return input.index(after: cursor)
        }
        if current == "\u{1B}" {
          let next = input.index(after: cursor)
          if next < input.endIndex, input[next] == "\\" {
            return input.index(after: next)
          }
        }
        cursor = input.index(after: cursor)
      }
      return cursor
    default:
      // Two-byte escape (charset selection, save/restore cursor, ...).
      return input.index(after: introducer)
    }
  }
}
