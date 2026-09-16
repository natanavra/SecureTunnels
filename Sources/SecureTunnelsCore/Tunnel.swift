import Foundation

public enum TunnelType: String, Codable, CaseIterable, Identifiable, Sendable {
  case local
  case remote
  case dynamic

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .local: return "Local Forward"
    case .remote: return "Remote Forward"
    case .dynamic: return "SOCKS Proxy"
    }
  }
}

/// One SSH tunnel definition. Secrets (key passphrase, password) live in the Keychain, keyed by `id`.
public struct Tunnel: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var type: TunnelType

  public var host: String
  public var port: Int
  public var username: String
  /// Path to a private key. Empty means ssh picks its default keys or the agent.
  public var identityFile: String

  /// Local forward and SOCKS: the local address to listen on. Remote forward: the address bound on the server.
  public var bindAddress: String
  public var bindPort: Int
  /// Local forward: the host reached from the server. Remote forward: the local host the server forwards to.
  public var targetHost: String
  public var targetPort: Int

  public var autoConnect: Bool
  public var autoReconnect: Bool
  public var reconnectInterval: Int
  public var serverAliveInterval: Int
  public var serverAliveCountMax: Int
  public var compression: Bool
  public var strictHostKeyChecking: Bool
  public var importedFromSecurePipes: Bool

  public init(
    id: UUID = UUID(),
    name: String = "New Tunnel",
    type: TunnelType = .local,
    host: String = "",
    port: Int = 22,
    username: String = "",
    identityFile: String = "",
    bindAddress: String = "localhost",
    bindPort: Int = 8080,
    targetHost: String = "localhost",
    targetPort: Int = 80,
    autoConnect: Bool = false,
    autoReconnect: Bool = true,
    reconnectInterval: Int = 30,
    serverAliveInterval: Int = 30,
    serverAliveCountMax: Int = 5,
    compression: Bool = false,
    strictHostKeyChecking: Bool = false,
    importedFromSecurePipes: Bool = false
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.host = host
    self.port = port
    self.username = username
    self.identityFile = identityFile
    self.bindAddress = bindAddress
    self.bindPort = bindPort
    self.targetHost = targetHost
    self.targetPort = targetPort
    self.autoConnect = autoConnect
    self.autoReconnect = autoReconnect
    self.reconnectInterval = reconnectInterval
    self.serverAliveInterval = serverAliveInterval
    self.serverAliveCountMax = serverAliveCountMax
    self.compression = compression
    self.strictHostKeyChecking = strictHostKeyChecking
    self.importedFromSecurePipes = importedFromSecurePipes
  }

  public var destination: String {
    username.isEmpty ? host : "\(username)@\(host)"
  }

  public var forwardDescription: String {
    switch type {
    case .local: return "\(bindAddress):\(bindPort) → \(targetHost):\(targetPort)"
    case .remote: return "server \(bindAddress):\(bindPort) → \(targetHost):\(targetPort)"
    case .dynamic: return "SOCKS on \(bindAddress):\(bindPort)"
    }
  }

  public var expandedIdentityFile: String {
    (identityFile as NSString).expandingTildeInPath
  }
}
