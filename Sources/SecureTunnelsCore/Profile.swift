import Foundation

/// A reusable SSH server definition: host, port, username and identity file. Its key passphrase and password live in
/// the Keychain keyed by `id`. Tunnels that reference a profile take all of these from it.
public struct Profile: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var host: String
  public var port: Int
  public var username: String
  public var identityFile: String

  public init(
    id: UUID = UUID(),
    name: String = "New Profile",
    host: String = "",
    port: Int = 22,
    username: String = "",
    identityFile: String = ""
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.identityFile = identityFile
  }

  public var summary: String {
    let destination = username.isEmpty ? host : "\(username)@\(host)"
    return port == 22 ? destination : "\(destination):\(port)"
  }
}
