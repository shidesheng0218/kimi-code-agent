import Foundation

public enum TerminalANSIColor: String, Codable, Equatable, CaseIterable, Sendable {
  case black, red, green, yellow, blue, magenta, cyan, white
  case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
  case indexed
}

public struct TerminalANSIStyle: Codable, Equatable, Sendable {
  public var foreground: TerminalANSIColor?
  public var background: TerminalANSIColor?
  public var foregroundIndex: Int?
  public var backgroundIndex: Int?
  public var bold: Bool
  public var italic: Bool
  public var underline: Bool
  public var inverse: Bool

  public init(
    foreground: TerminalANSIColor? = nil,
    background: TerminalANSIColor? = nil,
    foregroundIndex: Int? = nil,
    backgroundIndex: Int? = nil,
    bold: Bool = false,
    italic: Bool = false,
    underline: Bool = false,
    inverse: Bool = false
  ) {
    self.foreground = foreground
    self.background = background
    self.foregroundIndex = foregroundIndex
    self.backgroundIndex = backgroundIndex
    self.bold = bold
    self.italic = italic
    self.underline = underline
    self.inverse = inverse
  }
}

public struct TerminalANSIChunk: Equatable, Sendable {
  public let text: String
  public let style: TerminalANSIStyle

  public init(text: String, style: TerminalANSIStyle) {
    self.text = text
    self.style = style
  }
}

public enum TerminalANSIParser {
  public static func parse(_ input: String, initialStyle: TerminalANSIStyle = TerminalANSIStyle()) -> [TerminalANSIChunk] {
    var style = initialStyle
    var chunks: [TerminalANSIChunk] = []
    var visible = ""
    var index = input.startIndex

    func flush() {
      guard !visible.isEmpty else { return }
      chunks.append(TerminalANSIChunk(text: visible, style: style))
      visible = ""
    }

    while index < input.endIndex {
      if input[index] == "\u{001B}", input.index(after: index) < input.endIndex {
        let next = input.index(after: index)
        if input[next] == "[" {
          var cursor = input.index(after: next)
          var sequence = ""
          while cursor < input.endIndex {
            let character = input[cursor]
            sequence.append(character)
            cursor = input.index(after: cursor)
            if character.isLetter || character == "@" { break }
          }
          index = cursor
          guard sequence.last == "m" else { continue }
          flush()
          applySGR(String(sequence.dropLast()), to: &style)
          continue
        }
      }
      visible.append(input[index])
      index = input.index(after: index)
    }
    flush()
    return chunks
  }

  private static func applySGR(_ raw: String, to style: inout TerminalANSIStyle) {
    let values = raw.isEmpty ? [0] : raw.split(separator: ";").compactMap { Int($0) }
    var index = 0
    while index < values.count {
      let value = values[index]
      switch value {
      case 0: style = TerminalANSIStyle()
      case 1: style.bold = true
      case 3: style.italic = true
      case 4: style.underline = true
      case 7: style.inverse = true
      case 22: style.bold = false
      case 23: style.italic = false
      case 24: style.underline = false
      case 27: style.inverse = false
      case 30...37: style.foreground = basicColor(value - 30); style.foregroundIndex = nil
      case 40...47: style.background = basicColor(value - 40); style.backgroundIndex = nil
      case 90...97: style.foreground = brightColor(value - 90); style.foregroundIndex = nil
      case 100...107: style.background = brightColor(value - 100); style.backgroundIndex = nil
      case 39: style.foreground = nil; style.foregroundIndex = nil
      case 49: style.background = nil; style.backgroundIndex = nil
      case 38, 48:
        let isForeground = value == 38
        guard index + 2 < values.count else { index += 1; continue }
        let mode = values[index + 1]
        if mode == 5 {
          let colorIndex = max(0, min(values[index + 2], 255))
          if isForeground { style.foreground = .indexed; style.foregroundIndex = colorIndex }
          else { style.background = .indexed; style.backgroundIndex = colorIndex }
          index += 2
        }
      default: break
      }
      index += 1
    }
  }

  private static func basicColor(_ value: Int) -> TerminalANSIColor {
    [.black, .red, .green, .yellow, .blue, .magenta, .cyan, .white][max(0, min(value, 7))]
  }

  private static func brightColor(_ value: Int) -> TerminalANSIColor {
    [.brightBlack, .brightRed, .brightGreen, .brightYellow, .brightBlue, .brightMagenta, .brightCyan, .brightWhite][max(0, min(value, 7))]
  }
}
