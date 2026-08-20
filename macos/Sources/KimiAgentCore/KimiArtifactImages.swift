import Foundation

/// Finds local image artifacts referenced in tool output text (the native
/// bridge reports screenshot paths there).
public enum KimiArtifactImages {
  private static let pattern = try! NSRegularExpression(pattern: #"(/[^\s"'()]+\.(?:png|jpg|jpeg))"#, options: [.caseInsensitive])

  public static func extract(from texts: [String]) -> [URL] {
    var seen = Set<String>()
    var urls: [URL] = []
    for text in texts {
      let range = NSRange(text.startIndex..., in: text)
      for match in pattern.matches(in: text, range: range) {
        guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
        let path = String(text[matchRange])
        guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
        seen.insert(path)
        urls.append(URL(fileURLWithPath: path))
      }
    }
    return urls
  }
}
