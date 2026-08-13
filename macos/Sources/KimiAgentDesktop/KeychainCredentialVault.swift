import Foundation
import KimiAgentCore
import Security

final class KeychainCredentialVault: CredentialVault, @unchecked Sendable {
  private let service: String

  init(service: String = "com.kimiagent.desktop.native") {
    self.service = service
  }

  func read(key: String) throws -> String? {
    var query = baseQuery(key: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw keychainError(status)
    }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func write(_ value: String, key: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(key: key)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw keychainError(updateStatus)
    }
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else {
      throw keychainError(insertStatus)
    }
  }

  func delete(key: String) throws {
    let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  private func baseQuery(key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key
    ]
  }

  private func keychainError(_ status: OSStatus) -> NSError {
    NSError(
      domain: "KeychainCredentialVault",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败：\(status)"]
    )
  }
}
