import Foundation

public final class CachingCredentialVault: CredentialVault, @unchecked Sendable {
  private let base: CredentialVault
  private let lock = NSLock()
  private var cache: [String: String?] = [:]

  public init(base: CredentialVault) {
    self.base = base
  }

  public func read(key: String) throws -> String? {
    lock.lock()
    if let cached = cache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    let value = try base.read(key: key)

    lock.lock()
    cache[key] = value
    lock.unlock()
    return value
  }

  public func write(_ value: String, key: String) throws {
    try base.write(value, key: key)
    lock.lock()
    cache[key] = value
    lock.unlock()
  }

  public func delete(key: String) throws {
    try base.delete(key: key)
    lock.lock()
    cache[key] = nil
    lock.unlock()
  }
}
