import Foundation

public enum TunnelType: String, Codable, CaseIterable, Identifiable, Sendable {
  case local
  case remote
  case dynamic
  case cloudflare

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .local: return "Local Forward"
    case .remote: return "Remote Forward"
    case .dynamic: return "SOCKS Proxy"
    case .cloudflare: return "Cloudflare Tunnel"
    }
  }

  /// Runs over ssh (as opposed to cloudflared).
  public var usesSSH: Bool { self != .cloudflare }
}

/// Settings for a Cloudflare Tunnel that exposes a local service. `bindAddress`/`bindPort` on the tunnel are the
/// local service; `hostname` is the public name on one of the account's zones, empty for a quick tunnel.
public struct CloudflareConfig: Codable, Equatable, Hashable, Sendable {
  public var hostname: String
  public var scheme: String
  /// Filled in once the app has created the resources in the Cloudflare account.
  public var tunnelID: String?
  public var zoneID: String?
  public var dnsRecordID: String?
  /// True for a tunnel that already existed in the account. Its ingress and DNS stay as configured in the
  /// dashboard; the app only runs it.
  public var adopted: Bool

  public init(hostname: String = "", scheme: String = "http", tunnelID: String? = nil, zoneID: String? = nil, dnsRecordID: String? = nil, adopted: Bool = false) {
    self.hostname = hostname
    self.scheme = scheme
    self.tunnelID = tunnelID
    self.zoneID = zoneID
    self.dnsRecordID = dnsRecordID
    self.adopted = adopted
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
    scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? "http"
    tunnelID = try c.decodeIfPresent(String.self, forKey: .tunnelID)
    zoneID = try c.decodeIfPresent(String.self, forKey: .zoneID)
    dnsRecordID = try c.decodeIfPresent(String.self, forKey: .dnsRecordID)
    adopted = try c.decodeIfPresent(Bool.self, forKey: .adopted) ?? false
  }

  public var isQuick: Bool { hostname.trimmingCharacters(in: .whitespaces).isEmpty }
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
  public var cloudflare: CloudflareConfig

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
    importedFromSecurePipes: Bool = false,
    cloudflare: CloudflareConfig = CloudflareConfig()
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
    self.cloudflare = cloudflare
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
    cloudflare = try c.decodeIfPresent(CloudflareConfig.self, forKey: .cloudflare) ?? CloudflareConfig()
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

  /// True when the two versions differ in something ssh is started with, so a running tunnel must be restarted.
  /// Name, group and the auto-connect flag do not count.
  public func connectionDiffers(from other: Tunnel) -> Bool {
    type != other.type || profileID != other.profileID
      || host != other.host || port != other.port || username != other.username || identityFile != other.identityFile
      || bindAddress != other.bindAddress || bindPort != other.bindPort
      || targetHost != other.targetHost || targetPort != other.targetPort
      || serverAliveInterval != other.serverAliveInterval || serverAliveCountMax != other.serverAliveCountMax
      || compression != other.compression || strictHostKeyChecking != other.strictHostKeyChecking
      || cloudflare.hostname != other.cloudflare.hostname || cloudflare.scheme != other.cloudflare.scheme
  }

  /// The local address cloudflared forwards to, for example http://localhost:3000.
  public var cloudflareServiceURL: String {
    "\(cloudflare.scheme)://\(bindAddress):\(bindPort)"
  }

  /// Whether a local listening port is involved, which is what conflict detection checks.
  public var listensLocally: Bool {
    type == .local || type == .dynamic
  }

  /// The public address once the tunnel is provisioned (quick tunnels only know it after connecting).
  public var cloudflarePublicURL: String? {
    cloudflare.isQuick ? nil : "https://\(cloudflare.hostname)"
  }

  public var destination: String {
    username.isEmpty ? host : "\(username)@\(host)"
  }

  public var forwardDescription: String {
    switch type {
    case .local: return "\(bindAddress):\(bindPort) → \(targetHost):\(targetPort)"
    case .remote: return "server \(bindAddress):\(bindPort) → \(targetHost):\(targetPort)"
    case .dynamic: return "SOCKS on \(bindAddress):\(bindPort)"
    case .cloudflare:
      return cloudflare.isQuick
        ? "\(bindAddress):\(bindPort) → temporary trycloudflare.com URL"
        : "\(bindAddress):\(bindPort) → https://\(cloudflare.hostname)"
    }
  }

  public var expandedIdentityFile: String {
    (identityFile as NSString).expandingTildeInPath
  }
}
