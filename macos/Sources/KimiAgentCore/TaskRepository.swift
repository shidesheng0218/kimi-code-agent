import Foundation

public final class TaskRepository {
  private let fileURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.encoder.dateEncodingStrategy = .millisecondsSince1970
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.decoder = JSONDecoder()
    self.decoder.dateDecodingStrategy = .millisecondsSince1970
  }

  public func load() throws -> AppState {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return AppState()
    }
    return try decoder.decode(AppState.self, from: Data(contentsOf: fileURL))
  }

  public func save(_ state: AppState) throws {
    try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(state).write(to: fileURL, options: .atomic)
  }
}
