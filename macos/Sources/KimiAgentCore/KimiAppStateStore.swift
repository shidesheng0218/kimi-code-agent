import Foundation

/// The persisted boundary for the native shell.  Runtime session IDs are
/// intentionally kept as opaque strings inside `KimiUIState`; the Harness
/// session ID is local and stable so event replay can survive an app restart.
public struct KimiPersistedAppState: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let harnessSessionID: UUID
  public var uiState: KimiUIState

  public init(
    schemaVersion: Int = 1,
    harnessSessionID: UUID,
    uiState: KimiUIState
  ) {
    self.schemaVersion = max(1, schemaVersion)
    self.harnessSessionID = harnessSessionID
    self.uiState = uiState
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, harnessSessionID, uiState
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
      harnessSessionID: try container.decode(UUID.self, forKey: .harnessSessionID),
      uiState: try container.decode(KimiUIState.self, forKey: .uiState)
    )
  }
}

/// Small synchronous, atomic JSON store used only from the `KimiAppKernel`
/// actor.  Keeping the store value-like makes it straightforward to test and
/// avoids a second mutable state authority beside the Harness.
public struct KimiAppStateStore: Sendable {
  public let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL) {
    self.fileURL = fileURL
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  public func load() throws -> KimiPersistedAppState {
    let data = try Data(contentsOf: fileURL)
    return try decoder.decode(KimiPersistedAppState.self, from: data)
  }

  public func save(_ state: KimiPersistedAppState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(state)
    try data.write(to: fileURL, options: [.atomic])
  }
}
