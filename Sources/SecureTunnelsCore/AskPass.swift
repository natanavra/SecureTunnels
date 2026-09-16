import Foundation

/// Secrets handed to the askpass helper over ssh's stdin, so nothing sensitive ends up in argv or the environment.
public struct AskPassPayload: Codable, Sendable {
  public var passphrase: String?
  public var password: String?

  public init(passphrase: String? = nil, password: String? = nil) {
    self.passphrase = passphrase
    self.password = password
  }
}

public enum AskPassResponder {
  /// Picks the answer for an ssh prompt. Returns nil when no stored secret fits, so ssh fails instead of hanging.
  public static func answer(prompt: String, payload: AskPassPayload) -> String? {
    let lowered = prompt.lowercased()
    if lowered.contains("passphrase") {
      return nonEmpty(payload.passphrase)
    }
    if lowered.contains("password") {
      return nonEmpty(payload.password)
    }
    if lowered.contains("(yes/no") {
      return "yes"
    }
    return nil
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
