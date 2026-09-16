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
  /// Free-form group name shown as a section in the menu. Empty means ungrouped.
  public var group: String
  /// When set, host, port, username, identity file and secrets come from that profile instead of this tunnel.
  public var profileID: UUID?

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
    group: String = "",
    profileID: UUID? = nil,
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
    self.group = group
    self.profileID = profileID
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

  /// Tolerant decoding so tunnels.json files written by older versions keep loading.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Tunnel()
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
    type = try c.decodeIfPresent(TunnelType.self, forKey: .type) ?? defaults.type
    group = try c.decodeIfPresent(String.self, forKey: .group) ?? defaults.group
    profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
    host = try c.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
    username = try c.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
    identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? defaults.identityFile
    bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? defaults.bindAddress
    bindPort = try c.decodeIfPresent(Int.self, forKey: .bindPort) ?? defaults.bindPort
    targetHost = try c.decodeIfPresent(String.self, forKey: .targetHost) ?? defaults.targetHost
    targetPort = try c.decodeIfPresent(Int.self, forKey: .targetPort) ?? defaults.targetPort
    autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? defaults.autoConnect
    autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? defaults.autoReconnect
    reconnectInterval = try c.decodeIfPresent(Int.self, forKey: .reconnectInterval) ?? defaults.reconnectInterval
    serverAliveInterval = try c.decodeIfPresent(Int.self, forKey: .serverAliveInterval) ?? defaults.serverAliveInterval
    serverAliveCountMax = try c.decodeIfPresent(Int.self, forKey: .serverAliveCountMax) ?? defaults.serverAliveCountMax
    compression = try c.decodeIfPresent(Bool.self, forKey: .compression) ?? defaults.compression
    strictHostKeyChecking = try c.decodeIfPresent(Bool.self, forKey: .strictHostKeyChecking) ?? defaults.strictHostKeyChecking
    importedFromSecurePipes = try c.decodeIfPresent(Bool.self, forKey: .importedFromSecurePipes) ?? false
  }

  /// A copy whose connection fields come from `profile`. With nil it is the tunnel itself.
  public func applying(_ profile: Profile?) -> Tunnel {
    guard let profile else { return self }
    var copy = self
    copy.host = profile.host
    copy.port = profile.port
    copy.username = profile.username
    copy.identityFile = profile.identityFile
    return copy
  }

  /// Whether a local listening port is involved, which is what conflict detection checks.
  public var listensLocally: Bool {
    type == .local || type == .dynamic
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
