import Foundation

/// Reads Secure Pipes' connection list (net.edgeservices.connections.plist).
///
/// Layout: top-level groups ("Local Forwards", "Remote Forwards", "SOCKS Proxies") with type 100 and a `children`
/// dictionary keyed by connection name. Each child has a `config` dictionary and an integer `type`:
/// 1 local forward, 2 remote forward, 3 SOCKS proxy, 9 managed SOCKS proxy.
public enum SecurePipesImporter {
  public static let domain = "net.edgeservices.connections"

  public static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(domain).plist")
  }

  public static func isAvailable() -> Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
  }

  /// Loads through the preferences system first so recent Secure Pipes edits are seen, then falls back to the file.
  public static func load() throws -> [Tunnel] {
    if let root = UserDefaults.standard.persistentDomain(forName: domain), !root.isEmpty {
      return parse(root)
    }
    let data = try Data(contentsOf: plistURL)
    guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      return []
    }
    return parse(root)
  }

  public static func parse(_ root: [String: Any]) -> [Tunnel] {
    var tunnels: [Tunnel] = []
    collect(from: root, into: &tunnels)
    return tunnels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private static func collect(from container: [String: Any], into tunnels: inout [Tunnel]) {
    for (key, value) in container {
      guard let entry = value as? [String: Any] else { continue }
      if let children = entry["children"] as? [String: Any] {
        collect(from: children, into: &tunnels)
        continue
      }
      guard let config = entry["config"] as? [String: Any], let type = int(entry["type"]) else { continue }
      if let tunnel = tunnel(from: config, type: type, fallbackName: key) {
        tunnels.append(tunnel)
      }
    }
  }

  private static func tunnel(from config: [String: Any], type: Int, fallbackName: String) -> Tunnel? {
    let tunnelType: TunnelType
    switch type {
    case 1: tunnelType = .local
    case 2: tunnelType = .remote
    case 3, 9: tunnelType = .dynamic
    default: return nil
    }

    let id = string(config["UUID"]).flatMap(UUID.init(uuidString:)) ?? UUID()
    let useCustomIdentity = bool(config["useCustomIdentity"]) ?? false

    var tunnel = Tunnel(
      id: id,
      name: string(config["name"]) ?? fallbackName,
      type: tunnelType,
      host: string(config["sshServer"]) ?? "",
      port: int(config["sshPort"]) ?? 22,
      username: string(config["sshUsername"]) ?? "",
      identityFile: useCustomIdentity ? (string(config["sshIdentityFile"]) ?? "") : "",
      autoConnect: bool(config["startOnLaunch"]) ?? false,
      autoReconnect: bool(config["autoReconnect"]) ?? true,
      reconnectInterval: int(config["reconnectInterval"]) ?? 30,
      serverAliveInterval: int(config["sshServerAliveInterval"]) ?? 30,
      serverAliveCountMax: int(config["sshServerAliveCountMax"]) ?? 5,
      compression: bool(config["compressData"]) ?? false,
      strictHostKeyChecking: false,
      importedFromSecurePipes: true
    )

    switch tunnelType {
    case .local:
      tunnel.bindAddress = string(config["localBindAddress"]) ?? "localhost"
      tunnel.bindPort = int(config["localBindPort"]) ?? 0
      tunnel.targetHost = string(config["remoteHost"]) ?? "localhost"
      tunnel.targetPort = int(config["remotePort"]) ?? 0
    case .remote:
      tunnel.bindAddress = string(config["remoteBindAddress"]) ?? "localhost"
      tunnel.bindPort = int(config["remoteBindPort"]) ?? 0
      tunnel.targetHost = string(config["localBindAddress"]) ?? "localhost"
      tunnel.targetPort = int(config["localBindPort"]) ?? 0
    case .dynamic:
      tunnel.bindAddress = string(config["localBindAddress"]) ?? "localhost"
      tunnel.bindPort = int(config["localBindPort"]) ?? 0
      tunnel.targetHost = ""
      tunnel.targetPort = 0
    case .cloudflare:
      return nil
    }
    return tunnel
  }

  // Secure Pipes stores numbers as strings, integers or booleans depending on the field, so normalise loosely.

  private static func string(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func int(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber: return number.intValue
    case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  private static func bool(_ value: Any?) -> Bool? {
    switch value {
    case let number as NSNumber: return number.boolValue
    case let text as String: return ["1", "true", "yes"].contains(text.lowercased())
    default: return nil
    }
  }
}
