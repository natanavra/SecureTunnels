import Foundation
import Security

public enum SecretKind: String, CaseIterable, Sendable {
  case passphrase
  case password
  case apiToken
}

public struct KeychainError: Error, LocalizedError {
  public let status: OSStatus

  public var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
  }
}

/// Generic-password items in the login keychain, one per owner (tunnel or profile) and secret kind.
public enum Keychain {
  static let service = "com.natanavra.SecureTunnels"

  static func account(_ kind: SecretKind, ownerID: UUID) -> String {
    "\(ownerID.uuidString).\(kind.rawValue)"
  }

  public static func read(_ kind: SecretKind, ownerID: UUID) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(kind, ownerID: ownerID),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Writes the secret, or removes the item when `value` is empty.
  public static func write(_ value: String, _ kind: SecretKind, ownerID: UUID) throws {
    guard !value.isEmpty else {
      try delete(kind, ownerID: ownerID)
      return
    }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(kind, ownerID: ownerID),
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

  public static func delete(_ kind: SecretKind, ownerID: UUID) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(kind, ownerID: ownerID),
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }

  public static func deleteAll(ownerID: UUID) {
    for kind in SecretKind.allCases {
      try? delete(kind, ownerID: ownerID)
    }
  }
}
