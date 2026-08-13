import Foundation

struct WorkspaceAccessGrant {
  let url: URL
  let bookmarkData: Data?
  let isStale: Bool
}

final class WorkspaceAccessToken: @unchecked Sendable {
  private let url: URL
  private let shouldStopAccessing: Bool
  private let lock = NSLock()
  private var isActive = true

  init(url: URL, shouldStopAccessing: Bool) {
    self.url = url
    self.shouldStopAccessing = shouldStopAccessing
  }

  deinit {
    stop()
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard isActive else { return }
    isActive = false
    if shouldStopAccessing {
      url.stopAccessingSecurityScopedResource()
    }
  }
}

enum WorkspaceAccessManager {
  static func grantForUserSelectedWorkspace(_ url: URL) -> WorkspaceAccessGrant {
    let standardizedURL = url.standardizedFileURL
    let bookmarkData = try? standardizedURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    return WorkspaceAccessGrant(url: standardizedURL, bookmarkData: bookmarkData, isStale: false)
  }

  static func restoreWorkspace(path: String?, bookmarkData: Data?) -> WorkspaceAccessGrant? {
    guard let path else { return nil }
    if let bookmarkData,
       let resolved = try? resolveBookmark(bookmarkData) {
      return resolved
    }
    return WorkspaceAccessGrant(
      url: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
      bookmarkData: nil,
      isStale: false
    )
  }

  static func startAccessing(path: String?, bookmarkData: Data?) -> WorkspaceAccessToken? {
    guard let grant = restoreWorkspace(path: path, bookmarkData: bookmarkData) else { return nil }
    return startAccessing(grant)
  }

  static func startAccessing(_ grant: WorkspaceAccessGrant) -> WorkspaceAccessToken {
    let scoped = grant.bookmarkData != nil
    let didStart = scoped ? grant.url.startAccessingSecurityScopedResource() : false
    return WorkspaceAccessToken(url: grant.url, shouldStopAccessing: didStart)
  }

  private static func resolveBookmark(_ bookmarkData: Data) throws -> WorkspaceAccessGrant {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ).standardizedFileURL
    let refreshedBookmarkData = isStale
      ? try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
      : bookmarkData
    return WorkspaceAccessGrant(url: url, bookmarkData: refreshedBookmarkData, isStale: isStale)
  }
}
