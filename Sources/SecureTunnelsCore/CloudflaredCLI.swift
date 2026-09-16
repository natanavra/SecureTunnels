import Foundation

/// Runs a command to completion off the main thread and returns its output.
public enum ProcessRunner {
  public struct Result: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
  }

  public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) async throws -> Result {
    try await Task.detached {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      var env = ProcessInfo.processInfo.environment
      for (key, value) in environment { env[key] = value }
      process.environment = env
      let out = Pipe(), err = Pipe()
      process.standardOutput = out
      process.standardError = err
      process.standardInput = FileHandle.nullDevice
      try process.run()
      let stdout = out.fileHandleForReading.readDataToEndOfFile()
      let stderr = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return Result(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }.value
  }
}

/// Account operations through the cloudflared CLI, for Macs where `cloudflared tunnel login` was run and no API
/// token is configured. Tunnels created this way keep their credentials in ~/.cloudflared/<id>.json and are run
/// with `tunnel run --url <service> <id>`, so no remote ingress configuration is involved.
public struct CloudflaredCLI: Sendable {
  public let binary: URL

  public init(binary: URL) {
    self.binary = binary
  }

  public static var configDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared", isDirectory: true)
  }

  public static var certificateURL: URL { configDirectory.appendingPathComponent("cert.pem") }

  public static var isLoggedIn: Bool {
    FileManager.default.fileExists(atPath: certificateURL.path)
  }

  /// The account and zone cloudflared was logged into, read from the token block inside cert.pem.
  public struct CertificateInfo: Equatable, Sendable {
    public var accountID: String
    public var zoneID: String
  }

  public static func certificateInfo() -> CertificateInfo? {
    guard let pem = try? String(contentsOf: certificateURL, encoding: .utf8) else { return nil }
    return parseCertificate(pem)
  }

  static func parseCertificate(_ pem: String) -> CertificateInfo? {
    guard let start = pem.range(of: "-----BEGIN ARGO TUNNEL TOKEN-----"),
      let end = pem.range(of: "-----END ARGO TUNNEL TOKEN-----", range: start.upperBound..<pem.endIndex)
    else { return nil }
    let base64 = pem[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
    guard let data = Data(base64Encoded: String(base64)),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accountID = json["accountID"] as? String,
      let zoneID = json["zoneID"] as? String
    else { return nil }
    return CertificateInfo(accountID: accountID, zoneID: zoneID)
  }

  public func credentialsFile(for tunnelID: String) -> URL {
    Self.configDirectory.appendingPathComponent("\(tunnelID).json")
  }

  // MARK: Commands

  public func listTunnels() async throws -> [CloudflareAPI.RemoteTunnel] {
    let result = try await ProcessRunner.run(binary, ["tunnel", "list", "-o", "json"])
    guard result.status == 0 else { throw CloudflaredCLIError(command: "tunnel list", output: result.stderr) }
    return try Self.parseTunnelList(result.stdout)
  }

  /// `cloudflared tunnel list -o json` prints an array of {id, name, created_at, connections}.
  static func parseTunnelList(_ json: String) throws -> [CloudflareAPI.RemoteTunnel] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "null" else { return [] }
    return try JSONDecoder().decode([CloudflareAPI.RemoteTunnel].self, from: Data(trimmed.utf8))
  }

  public func createTunnel(name: String) async throws -> String {
    let result = try await ProcessRunner.run(binary, ["tunnel", "create", name])
    guard result.status == 0, let id = Self.parseCreatedTunnelID(result.stdout + "\n" + result.stderr) else {
      throw CloudflaredCLIError(command: "tunnel create", output: result.stderr + result.stdout)
    }
    return id
  }

  /// The create command ends with "Created tunnel <name> with id <uuid>".
  static func parseCreatedTunnelID(_ output: String) -> String? {
    let pattern = #"with id ([0-9a-fA-F-]{36})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
      let range = Range(match.range(at: 1), in: output)
    else { return nil }
    return String(output[range]).lowercased()
  }

  /// Adds the CNAME for the hostname. cloudflared refuses when a record already exists for another target,
  /// which is surfaced as an error rather than overwritten.
  public func routeDNS(tunnelID: String, hostname: String) async throws {
    let result = try await ProcessRunner.run(binary, ["tunnel", "route", "dns", tunnelID, hostname])
    let output = result.stderr + result.stdout
    guard result.status == 0 || output.contains("already exists") && output.contains(tunnelID) else {
      throw CloudflaredCLIError(command: "tunnel route dns", output: output)
    }
  }

  public func deleteTunnel(tunnelID: String) async throws {
    let result = try await ProcessRunner.run(binary, ["tunnel", "delete", "-f", tunnelID])
    guard result.status == 0 else { throw CloudflaredCLIError(command: "tunnel delete", output: result.stderr) }
  }

  public func runArguments(tunnelID: String, serviceURL: String) -> [String] {
    ["tunnel", "--no-autoupdate", "run", "--url", serviceURL, tunnelID]
  }

  /// Opens the browser login. Returns once cloudflared exits, which happens after the user picks a zone.
  public func login() async throws {
    let result = try await ProcessRunner.run(binary, ["tunnel", "login"])
    guard result.status == 0 || Self.isLoggedIn else { throw CloudflaredCLIError(command: "tunnel login", output: result.stderr) }
  }
}

public struct CloudflaredCLIError: Error, LocalizedError {
  public let command: String
  public let output: String

  public var errorDescription: String? {
    let lines = output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
    let message = lines.last { $0.contains("ERR") || $0.lowercased().contains("error") || $0.lowercased().contains("failed") } ?? lines.last ?? ""
    let cleaned = message.replacingOccurrences(of: #"^\S+ ERR "#, with: "", options: .regularExpression)
    return "cloudflared \(command) failed: \(cleaned.isEmpty ? "no output" : cleaned)"
  }
}
