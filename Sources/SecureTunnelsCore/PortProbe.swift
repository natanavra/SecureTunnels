import Foundation

public struct PortUsage: Equatable, Sendable {
  public let port: Int
  public let processName: String
  public let pid: Int32

  public var description: String {
    "port \(port) is already in use by \(processName) (pid \(pid))"
  }
}

/// Finds the process listening on a local TCP port, so a conflict is reported before ssh even starts.
public enum PortProbe {
  public static func listener(on port: Int) -> PortUsage? {
    guard port > 0 else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pc"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return parse(String(decoding: data, as: UTF8.self), port: port)
  }

  /// lsof -F pc prints one field per line: `p<pid>` then `c<command>` for each process.
  static func parse(_ output: String, port: Int) -> PortUsage? {
    var pid: Int32?
    for line in output.split(whereSeparator: \.isNewline) {
      guard let tag = line.first else { continue }
      let value = String(line.dropFirst())
      switch tag {
      case "p": pid = Int32(value)
      case "c":
        if let pid { return PortUsage(port: port, processName: value, pid: pid) }
      default: continue
      }
    }
    return nil
  }
}
