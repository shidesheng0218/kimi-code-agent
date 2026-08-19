import Foundation
import Security

/// Keychain-backed vault used by the native App Kernel. The secret value is
/// never serialized into the Harness event store or UI snapshot.
public final class MacKeychainCredentialVault: CredentialVault, @unchecked Sendable {
  public let service: String
  private let accessGroup: String?

  public init(service: String = "com.kimicode.agent.native", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public func read(key: String) throws -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw keychainError(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func write(_ value: String, key: String) throws {
    let data = Data(value.utf8)
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }
    query[kSecValueData as String] = data
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
  }

  public func delete(key: String) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
  }

  private func keychainError(_ status: OSStatus) -> NSError {
    NSError(
      domain: NSOSStatusErrorDomain,
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Keychain 操作失败（\(status)）。"]
    )
  }
}
