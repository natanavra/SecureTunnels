import Foundation

struct TunnelFile: Codable {
  var version: Int
  var tunnels: [Tunnel]
}

public enum TunnelStorage {
  public static func exists() -> Bool {
    FileManager.default.fileExists(atPath: AppPaths.tunnelsFile.path)
  }

  public static func load() throws -> [Tunnel] {
    guard exists() else { return [] }
    let data = try Data(contentsOf: AppPaths.tunnelsFile)
    return try JSONDecoder().decode(TunnelFile.self, from: data).tunnels
  }

  public static func save(_ tunnels: [Tunnel]) throws {
    try AppPaths.ensureDirectories()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(TunnelFile(version: 1, tunnels: tunnels))
    try data.write(to: AppPaths.tunnelsFile, options: .atomic)
  }
}
