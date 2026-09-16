import Foundation

public struct StoredData: Codable, Equatable {
  public var version: Int
  public var tunnels: [Tunnel]
  public var profiles: [Profile]

  public init(tunnels: [Tunnel] = [], profiles: [Profile] = []) {
    version = 2
    self.tunnels = tunnels
    self.profiles = profiles
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    tunnels = try c.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
    profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
  }
}

public enum TunnelStorage {
  public static func exists() -> Bool {
    FileManager.default.fileExists(atPath: AppPaths.tunnelsFile.path)
  }

  public static func load() throws -> StoredData {
    guard exists() else { return StoredData() }
    let data = try Data(contentsOf: AppPaths.tunnelsFile)
    return try JSONDecoder().decode(StoredData.self, from: data)
  }

  public static func save(_ stored: StoredData) throws {
    try AppPaths.ensureDirectories()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var copy = stored
    copy.version = 2
    let data = try encoder.encode(copy)
    try data.write(to: AppPaths.tunnelsFile, options: .atomic)
  }
}
