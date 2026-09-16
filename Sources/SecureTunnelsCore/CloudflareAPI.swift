import Foundation

/// The parts of the Cloudflare v4 API the app needs: accounts, zones, named tunnels and DNS records.
/// The token needs Account > Cloudflare Tunnel > Edit and Zone > DNS > Edit.
public struct CloudflareAPI {
  public struct Account: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
  }

  public struct Zone: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
  }

  public struct RemoteTunnel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// inactive, degraded, healthy or down, as reported by Cloudflare.
    public var status: String?
    public var createdAt: String?
    public var connectionCount: Int?

    enum CodingKeys: String, CodingKey {
      case id, name, status, connections
      case createdAt = "created_at"
    }

    public init(id: String, name: String, status: String? = nil, createdAt: String? = nil, connectionCount: Int? = nil) {
      self.id = id
      self.name = name
      self.status = status
      self.createdAt = createdAt
      self.connectionCount = connectionCount
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      name = try c.decode(String.self, forKey: .name)
      status = try c.decodeIfPresent(String.self, forKey: .status)
      createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
      connectionCount = (try? c.decodeIfPresent([AnyDecodable].self, forKey: .connections))??.count
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(name, forKey: .name)
      try c.encodeIfPresent(status, forKey: .status)
      try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
  }

  struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
  }

  /// One ingress rule of a remotely managed tunnel.
  public struct Ingress: Codable, Equatable, Sendable {
    public var hostname: String?
    public var service: String

    public init(hostname: String? = nil, service: String) {
      self.hostname = hostname
      self.service = service
    }
  }

  public struct DNSRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let content: String
  }

  /// Everything the app created for one exposed tunnel.
  public struct Provisioned: Equatable, Sendable {
    public var tunnelID: String
    public var zoneID: String
    public var dnsRecordID: String
    public var token: String
  }

  public static let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

  public let token: String
  public var transport: HTTPTransport

  public init(token: String, transport: HTTPTransport = URLSessionTransport()) {
    self.token = token
    self.transport = transport
  }

  // MARK: Requests

  func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
    // Paths carry query strings, so build the URL from the string rather than appending a path component.
    guard let url = URL(string: Self.baseURL.absoluteString + "/" + path) else {
      throw CloudflareAPIError(status: 0, messages: ["Bad request path: \(path)"], code: nil)
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
    let (data, response) = try await transport.send(try request(method, path, body: body))
    let envelope = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    let success = envelope["success"] as? Bool ?? false
    guard success, (200..<300).contains(response.statusCode) else {
      let errors = (envelope["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
      throw CloudflareAPIError(status: response.statusCode, messages: errors, code: (envelope["errors"] as? [[String: Any]])?.first?["code"] as? Int)
    }
    return envelope["result"] ?? NSNull()
  }

  func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
  }

  // MARK: Reads

  public func verifyToken() async throws -> String {
    let result = try await call("GET", "user/tokens/verify") as? [String: Any]
    return result?["status"] as? String ?? "unknown"
  }

  public func accounts() async throws -> [Account] {
    try decode([Account].self, try await call("GET", "accounts?per_page=50"))
  }

  public func zones() async throws -> [Zone] {
    try decode([Zone].self, try await call("GET", "zones?per_page=50&status=active"))
  }

  public func tunnels(accountID: String) async throws -> [RemoteTunnel] {
    try decode([RemoteTunnel].self, try await call("GET", "accounts/\(accountID)/cfd_tunnel?is_deleted=false&per_page=100"))
  }

  /// The ingress rules of a tunnel configured through the dashboard or API. Empty for tunnels that use a local
  /// config.yml, which Cloudflare cannot see.
  public func ingress(accountID: String, tunnelID: String) async throws -> [Ingress] {
    let result = try await call("GET", "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations") as? [String: Any]
    guard let config = result?["config"] as? [String: Any], let rules = config["ingress"] else { return [] }
    return try decode([Ingress].self, rules).filter { $0.service != "http_status:404" }
  }

  public func dnsRecords(zoneID: String, name: String) async throws -> [DNSRecord] {
    try decode([DNSRecord].self, try await call("GET", "zones/\(zoneID)/dns_records?name=\(name)&per_page=50"))
  }

  /// Deletes the tunnel and every CNAME on the account's zones that pointed at it.
  public func deleteTunnelAndRoutes(accountID: String, tunnelID: String, hostnames: [String]) async throws {
    let zones = try await zones()
    for hostname in hostnames {
      guard let zone = Self.zone(for: hostname, in: zones) else { continue }
      for record in (try? await dnsRecords(zoneID: zone.id, name: hostname)) ?? []
      where record.type == "CNAME" && record.content.lowercased() == "\(tunnelID).cfargotunnel.com" {
        try? await deleteDNS(zoneID: zone.id, recordID: record.id)
      }
    }
    try await deleteTunnel(accountID: accountID, tunnelID: tunnelID)
  }

  /// Picks the zone whose name is the longest suffix of the hostname.
  public static func zone(for hostname: String, in zones: [Zone]) -> Zone? {
    let host = hostname.lowercased()
    return zones
      .filter { host == $0.name || host.hasSuffix("." + $0.name) }
      .max { $0.name.count < $1.name.count }
  }

  // MARK: Provisioning

  public func createTunnel(accountID: String, name: String) async throws -> RemoteTunnel {
    try decode(RemoteTunnel.self, try await call("POST", "accounts/\(accountID)/cfd_tunnel", body: ["name": name, "config_src": "cloudflare"]))
  }

  public func tunnelToken(accountID: String, tunnelID: String) async throws -> String {
    guard let token = try await call("GET", "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/token") as? String else {
      throw CloudflareAPIError(status: 200, messages: ["The tunnel token was missing from the response."], code: nil)
    }
    return token
  }

  /// Routes the hostname to the local service; everything else answers 404.
  public func setIngress(accountID: String, tunnelID: String, hostname: String, serviceURL: String) async throws {
    let body: [String: Any] = [
      "config": [
        "ingress": [
          ["hostname": hostname, "service": serviceURL],
          ["service": "http_status:404"],
        ]
      ]
    ]
    _ = try await call("PUT", "accounts/\(accountID)/cfd_tunnel/\(tunnelID)/configurations", body: body)
  }

  /// Creates the proxied CNAME to <tunnel>.cfargotunnel.com, or updates an existing record with that name.
  public func upsertDNS(zoneID: String, hostname: String, tunnelID: String) async throws -> DNSRecord {
    let content = "\(tunnelID).cfargotunnel.com"
    let body: [String: Any] = ["type": "CNAME", "name": hostname, "content": content, "proxied": true, "ttl": 1,
      "comment": "SecureTunnels"]
    do {
      return try decode(DNSRecord.self, try await call("POST", "zones/\(zoneID)/dns_records", body: body))
    } catch let error as CloudflareAPIError where error.code == 81057 || error.code == 81053 {
      let existing = try decode([DNSRecord].self, try await call("GET", "zones/\(zoneID)/dns_records?name=\(hostname)"))
      guard let record = existing.first else { throw error }
      return try decode(DNSRecord.self, try await call("PUT", "zones/\(zoneID)/dns_records/\(record.id)", body: body))
    }
  }

  public func deleteDNS(zoneID: String, recordID: String) async throws {
    _ = try await call("DELETE", "zones/\(zoneID)/dns_records/\(recordID)")
  }

  public func deleteTunnel(accountID: String, tunnelID: String) async throws {
    _ = try await call("DELETE", "accounts/\(accountID)/cfd_tunnel/\(tunnelID)?cascade=true")
  }

  /// Creates tunnel, ingress and DNS record for a hostname, or refreshes the ingress of an existing tunnel.
  public func provision(accountID: String, hostname: String, serviceURL: String, tunnelName: String, existing: CloudflareConfig) async throws -> Provisioned {
    let zones = try await zones()
    guard let zone = Self.zone(for: hostname, in: zones) else {
      throw CloudflareAPIError(status: 0, messages: ["No zone in this account matches \(hostname). Zones: \(zones.map(\.name).joined(separator: ", "))"], code: nil)
    }
    let tunnelID: String
    if let id = existing.tunnelID {
      tunnelID = id
    } else {
      tunnelID = try await createTunnel(accountID: accountID, name: tunnelName).id
    }
    try await setIngress(accountID: accountID, tunnelID: tunnelID, hostname: hostname, serviceURL: serviceURL)
    let record = try await upsertDNS(zoneID: zone.id, hostname: hostname, tunnelID: tunnelID)
    let token = try await tunnelToken(accountID: accountID, tunnelID: tunnelID)
    return Provisioned(tunnelID: tunnelID, zoneID: zone.id, dnsRecordID: record.id, token: token)
  }
}

public struct CloudflareAPIError: Error, LocalizedError, Equatable {
  public let status: Int
  public let messages: [String]
  public let code: Int?

  public var errorDescription: String? {
    messages.isEmpty ? "Cloudflare API returned HTTP \(status)." : messages.joined(separator: " ")
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
  public init() {}

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudflareAPIError(status: 0, messages: ["No HTTP response."], code: nil)
    }
    return (data, http)
  }
}
