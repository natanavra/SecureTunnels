import Foundation
import SecureTunnelsCore

/// Remembers the ssh processes this app started so a crash or a SIGTERM (for example `pkill` during reinstall)
/// does not leave orphaned sessions holding the local ports. Stale entries are killed on the next launch.
@MainActor
enum SessionRegistry {
  private static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("sessions.json") }

  private struct Entry: Codable {
    var pid: Int32
    var tunnelID: UUID
  }

  static func register(pid: Int32, tunnelID: UUID) {
    var entries = load()
    entries.removeAll { $0.pid == pid }
    entries.append(Entry(pid: pid, tunnelID: tunnelID))
    save(entries)
  }

  static func unregister(pid: Int32) {
    var entries = load()
    entries.removeAll { $0.pid == pid }
    save(entries)
  }

  static func clear() {
    save([])
  }

  /// Kills every recorded pid that is still an ssh process started by SecureTunnels, then clears the file.
  static func killStaleSessions() {
    let entries = load()
    for entry in entries where isSecureTunnelsSSH(pid: entry.pid) {
      kill(entry.pid, SIGTERM)
    }
    save([])
  }

  /// A pid can be reused by an unrelated process, so only trust it when its command line is ours.
  private static func isSecureTunnelsSSH(pid: Int32) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "command=", "-p", String(pid)]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output.hasPrefix(SSHCommand.executable) && output.contains(SSHCommand.connectedMarker)
  }

  private static func load() -> [Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  private static func save(_ entries: [Entry]) {
    try? AppPaths.ensureDirectories()
    try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
  }
}
