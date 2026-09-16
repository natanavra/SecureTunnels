import Foundation
import Security

public enum SecretKind: String, CaseIterable, Sendable {
  case passphrase
  case password
}

public struct KeychainError: Error, LocalizedError {
  public let status: OSStatus

  public var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
  }
}

/// Generic-password items in the login keychain, one per tunnel and secret kind.
public enum Keychain {
  static let service = "com.natanavra.SecureTunnels"

  static func account(_ kind: SecretKind, tunnelID: UUID) -> String {
    "\(tunnelID.uuidString).\(kind.rawValue)"
  }

  public static func read(_ kind: SecretKind, tunnelID: UUID) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(kind, tunnelID: tunnelID),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Writes the secret, or removes the item when `value` is empty.
  public static func write(_ value: String, _ kind: SecretKind, tunnelID: UUID) throws {
    guard !value.isEmpty else {
      try delete(kind, tunnelID: tunnelID)
      return
    }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(kind, tunnelID: tunnelID),
    ]
    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = "SecureTunnels \(kind.rawValue)"
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
  }

  public static func delete(_ kind: SecretKind, tunnelID: UUID) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(kind, tunnelID: tunnelID),
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }

  public static func deleteAll(tunnelID: UUID) {
    for kind in SecretKind.allCases {
      try? delete(kind, tunnelID: tunnelID)
    }
  }
}
