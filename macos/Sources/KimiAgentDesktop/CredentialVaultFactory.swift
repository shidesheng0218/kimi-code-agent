import Foundation
import KimiAgentCore
import Security

struct CredentialVaultSelection {
  let vault: CredentialVault
  let mode: CredentialStorageMode
}

enum CredentialVaultFactory {
  static func makeDefault(
    applicationSupportDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> CredentialVaultSelection {
    let mode = CredentialStoragePolicy.defaultMode(
      environment: environment,
      hasStableSigningIdentity: hasStableSigningIdentity()
    )
    let baseVault: CredentialVault
    switch mode {
    case .keychain:
      baseVault = KeychainCredentialVault()
    case .localFile:
      baseVault = FileCredentialVault(
        fileURL: applicationSupportDirectory.appendingPathComponent("credentials.json")
      )
    }
    return CredentialVaultSelection(vault: CachingCredentialVault(base: baseVault), mode: mode)
  }

  private static func hasStableSigningIdentity() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
          let code else {
      return false
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode else {
      return false
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    ) == errSecSuccess,
      let values = information as? [String: Any],
      let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String,
      !teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return true
  }
}
