import Foundation

public enum AppPaths {
  public static let supportDirectory: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("SecureTunnels", isDirectory: true)
  }()

  public static var tunnelsFile: URL { supportDirectory.appendingPathComponent("tunnels.json") }
  public static var knownHostsFile: URL { supportDirectory.appendingPathComponent("known_hosts") }
  public static var logsDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }

  public static func logFile(for tunnelID: UUID) -> URL {
    logsDirectory.appendingPathComponent("\(tunnelID.uuidString).log")
  }

  public static func ensureDirectories() throws {
    try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
  }
}
