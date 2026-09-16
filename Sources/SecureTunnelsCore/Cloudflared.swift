import Foundation

/// Locates or installs the cloudflared binary and understands its log output.
public enum Cloudflared {
  public static let installDirectory = AppPaths.supportDirectory.appendingPathComponent("bin", isDirectory: true)
  public static var installedURL: URL { installDirectory.appendingPathComponent("cloudflared") }

  /// The first cloudflared found: one the app installed, then Homebrew, then /usr/local.
  public static func locate() -> URL? {
    let candidates = [installedURL.path, "/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
  }

  public static var downloadURL: URL {
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "amd64"
    #endif
    return URL(string: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-\(arch).tgz")!
  }

  /// Downloads the official release archive from GitHub and unpacks the binary into the app's support folder.
  public static func install() async throws -> URL {
    let (archive, response) = try await URLSession.shared.download(from: downloadURL)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CloudflaredError.download("GitHub returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", archive.path, "-C", installDirectory.path, "cloudflared"]
    tar.standardError = FileHandle.nullDevice
    try tar.run()
    tar.waitUntilExit()
    try? FileManager.default.removeItem(at: archive)
    guard tar.terminationStatus == 0, FileManager.default.fileExists(atPath: installedURL.path) else {
      throw CloudflaredError.download("The archive did not contain a cloudflared binary.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedURL.path)
    removexattr(installedURL.path, "com.apple.quarantine", 0)
    return installedURL
  }

  public static func version(at url: URL) -> String? {
    let process = Process()
    process.executableURL = url
    process.arguments = ["--version"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    guard (try? process.run()) != nil else { return nil }
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output.split(whereSeparator: \.isNewline).first.map(String.init)
  }

  // MARK: Arguments

  public static func quickTunnelArguments(serviceURL: String) -> [String] {
    ["tunnel", "--no-autoupdate", "--url", serviceURL]
  }

  /// Runs a named tunnel. The token is passed through the TUNNEL_TOKEN environment variable, not argv.
  public static func namedTunnelArguments() -> [String] {
    ["tunnel", "--no-autoupdate", "run"]
  }

  // MARK: Log parsing

  /// cloudflared prints the quick tunnel URL in a box of `|` characters and a "Registered tunnel connection"
  /// line for each edge connection. Both may be split across reads, so callers pass the accumulated text.
  public static func quickTunnelURL(in output: String) -> String? {
    let pattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
      let range = Range(match.range, in: output)
    else { return nil }
    return String(output[range])
  }

  public static func isConnected(_ output: String) -> Bool {
    output.contains("Registered tunnel connection")
  }

  /// A one-line explanation from cloudflared's error output.
  public static func friendlyError(from output: String, exitStatus: Int32) -> String {
    let lines = output.split(whereSeparator: \.isNewline).map { String($0) }
    let errors = lines.filter { $0.contains(" ERR ") || $0.lowercased().contains("error") }
    let lowered = output.lowercased()
    if lowered.contains("provided tunnel token is not valid") || lowered.contains("unauthorized") {
      return "Cloudflare rejected the tunnel token. Check the API token in Settings and provision the tunnel again."
    }
    if lowered.contains("no such host") || lowered.contains("dial tcp") && lowered.contains("timeout") {
      return "Could not reach Cloudflare's edge. Check the network connection."
    }
    if let last = errors.last {
      if let range = last.range(of: " ERR ") {
        return String(last[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      }
      return last
    }
    return exitStatus == 0 ? "Disconnected." : "cloudflared exited with status \(exitStatus)."
  }
}

public enum CloudflaredError: Error, LocalizedError {
  case notInstalled
  case download(String)

  public var errorDescription: String? {
    switch self {
    case .notInstalled: return "cloudflared is not installed. Install it from Settings > Cloudflare."
    case .download(let detail): return "Could not download cloudflared: \(detail)"
    }
  }
}
