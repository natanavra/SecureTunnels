import Foundation

public enum SSHCommand {
  public static let executable = "/usr/bin/ssh"
  /// Printed by ssh's LocalCommand once the session is up, which is the only reliable "connected" signal with -N.
  public static let connectedMarker = "SECURETUNNELS_CONNECTED"

  public static func arguments(for tunnel: Tunnel, knownHostsFile: String, hasPassword: Bool) -> [String] {
    var args: [String] = ["-N"]

    func option(_ keyValue: String) {
      args.append("-o")
      args.append(keyValue)
    }

    option("ExitOnForwardFailure=yes")
    option("ServerAliveInterval=\(tunnel.serverAliveInterval)")
    option("ServerAliveCountMax=\(tunnel.serverAliveCountMax)")
    option("TCPKeepAlive=yes")
    option("ConnectTimeout=15")
    option("StrictHostKeyChecking=\(tunnel.strictHostKeyChecking ? "yes" : "accept-new")")
    option("UserKnownHostsFile=\(knownHostsFile)")
    option("NumberOfPasswordPrompts=1")
    option("Compression=\(tunnel.compression ? "yes" : "no")")
    option("PermitLocalCommand=yes")
    option("LocalCommand=echo \(connectedMarker)")
    option("PreferredAuthentications=\(hasPassword ? "publickey,keyboard-interactive,password" : "publickey")")
    option("PasswordAuthentication=\(hasPassword ? "yes" : "no")")

    if !tunnel.identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
      args.append("-i")
      args.append(tunnel.expandedIdentityFile)
      option("IdentitiesOnly=yes")
    }

    args.append("-p")
    args.append(String(tunnel.port))

    switch tunnel.type {
    case .local:
      args.append("-L")
      args.append("\(tunnel.bindAddress):\(tunnel.bindPort):\(tunnel.targetHost):\(tunnel.targetPort)")
    case .remote:
      args.append("-R")
      args.append("\(tunnel.bindAddress):\(tunnel.bindPort):\(tunnel.targetHost):\(tunnel.targetPort)")
    case .dynamic:
      args.append("-D")
      args.append("\(tunnel.bindAddress):\(tunnel.bindPort)")
    case .cloudflare:
      break
    }

    args.append(tunnel.destination)
    return args
  }

  /// Turns ssh's stderr into a one-line explanation a person can act on.
  public static func friendlyError(from stderr: String, exitStatus: Int32) -> String {
    let lines = stderr
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
    let last = lines.last ?? ""
    let lowered = lines.joined(separator: "\n").lowercased()

    if lowered.contains("ssh_askpass") {
      return "The passphrase helper could not run. If the app came from a zip, run: xattr -dr com.apple.quarantine /Applications/SecureTunnels.app"
    }
    if lowered.contains("unprotected private key file") || lowered.contains("permissions") && lowered.contains("too open") {
      return "The identity file's permissions are too open. Run: chmod 600 <key file>"
    }
    if lowered.contains("no such identity") || lowered.contains("identity file") && lowered.contains("not accessible") {
      return "The identity file could not be read. Check the path and that SecureTunnels may access that folder."
    }
    if lowered.contains("permission denied") || lowered.contains("incorrect passphrase") || lowered.contains("no stored secret") {
      return "Authentication failed. Check the username, key file and passphrase."
    }
    if lowered.contains("address already in use") || lowered.contains("cannot listen to port") || lowered.contains("bind:") {
      return "Local port \(portHint(in: stderr)) is already in use."
    }
    if lowered.contains("remote host identification has changed") || stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
      return "The server's host key changed. Remove it from known_hosts if this is expected."
    }
    if lowered.contains("host key verification failed") {
      return "Host key verification failed. Disable strict host key checking to trust this server on first connect."
    }
    if lowered.contains("could not resolve hostname") {
      return "Could not resolve the host name."
    }
    if lowered.contains("timed out") || lowered.contains("timeout") {
      return "Connection timed out."
    }
    if lowered.contains("connection refused") {
      return "Connection refused by the server."
    }
    if lowered.contains("no such file or directory") && lowered.contains("identity") {
      return "The identity file could not be found."
    }
    if !last.isEmpty {
      return last
    }
    return exitStatus == 0 ? "Disconnected." : "ssh exited with status \(exitStatus)."
  }

  private static func portHint(in stderr: String) -> String {
    let pattern = #"(?:port:?\s*|\]:)(\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
      let range = Range(match.range(at: 1), in: stderr)
    else { return "" }
    return String(stderr[range])
  }
}
