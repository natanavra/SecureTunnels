import XCTest
@testable import SecureTunnelsCore

final class SSHCommandTests: XCTestCase {
  private var tunnel: Tunnel {
    Tunnel(
      name: "Mongo",
      type: .local,
      host: "203.0.113.10",
      port: 2222,
      username: "ec2-user",
      identityFile: "~/keys/mongo.pem",
      bindAddress: "localhost",
      bindPort: 8082,
      targetHost: "localhost",
      targetPort: 27017,
      serverAliveInterval: 15,
      serverAliveCountMax: 3,
      compression: true,
      strictHostKeyChecking: true
    )
  }

  func testLocalForwardArguments() {
    let args = SSHCommand.arguments(for: tunnel, knownHostsFile: "/tmp/kh", hasPassword: false)
    XCTAssertEqual(args.first, "-N")
    XCTAssertTrue(args.contains("ServerAliveInterval=15"))
    XCTAssertTrue(args.contains("ServerAliveCountMax=3"))
    XCTAssertTrue(args.contains("Compression=yes"))
    XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(args.contains("UserKnownHostsFile=/tmp/kh"))
    XCTAssertTrue(args.contains("PasswordAuthentication=no"))
    XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
    XCTAssertEqual(args[args.firstIndex(of: "-i")! + 1], ("~/keys/mongo.pem" as NSString).expandingTildeInPath)
    XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
    XCTAssertEqual(args.last, "ec2-user@203.0.113.10")
    XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "localhost:8082:localhost:27017")
  }

  func testRemoteAndDynamicForwards() {
    var remote = tunnel
    remote.type = .remote
    remote.bindAddress = "0.0.0.0"
    remote.bindPort = 9000
    remote.targetHost = "127.0.0.1"
    remote.targetPort = 3000
    let remoteArgs = SSHCommand.arguments(for: remote, knownHostsFile: "kh", hasPassword: false)
    XCTAssertEqual(remoteArgs[remoteArgs.firstIndex(of: "-R")! + 1], "0.0.0.0:9000:127.0.0.1:3000")

    var socks = tunnel
    socks.type = .dynamic
    socks.bindPort = 1080
    let socksArgs = SSHCommand.arguments(for: socks, knownHostsFile: "kh", hasPassword: false)
    XCTAssertEqual(socksArgs[socksArgs.firstIndex(of: "-D")! + 1], "localhost:1080")
    XCTAssertFalse(socksArgs.contains("-L"))
  }

  func testNoIdentityFileAndPasswordAuth() {
    var t = tunnel
    t.identityFile = "  "
    t.strictHostKeyChecking = false
    t.username = ""
    let args = SSHCommand.arguments(for: t, knownHostsFile: "kh", hasPassword: true)
    XCTAssertFalse(args.contains("-i"))
    XCTAssertFalse(args.contains("IdentitiesOnly=yes"))
    XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
    XCTAssertTrue(args.contains("PasswordAuthentication=yes"))
    XCTAssertTrue(args.contains("PreferredAuthentications=publickey,keyboard-interactive,password"))
    XCTAssertEqual(args.last, "203.0.113.10")
  }

  func testFriendlyErrors() {
    XCTAssertEqual(
      SSHCommand.friendlyError(from: "Warning: Permanently added 'x' to the list of known hosts.\nec2-user@x: Permission denied (publickey).\n", exitStatus: 255),
      "Authentication failed. Check the username, key file and passphrase."
    )
    XCTAssertEqual(
      SSHCommand.friendlyError(from: "bind [localhost]:8082: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 8082\nCould not request local forwarding.\n", exitStatus: 255),
      "Local port 8082 is already in use."
    )
    XCTAssertEqual(SSHCommand.friendlyError(from: "", exitStatus: 255), "ssh exited with status 255.")
    XCTAssertTrue(SSHCommand.friendlyError(from: "ssh_askpass: exec(/Applications/SecureTunnels.app/Contents/MacOS/SecureTunnelsAskPass): Operation not permitted\nPermission denied (publickey).", exitStatus: 255).contains("xattr"))
    XCTAssertTrue(SSHCommand.friendlyError(from: "@ WARNING: UNPROTECTED PRIVATE KEY FILE! @\nPermissions 0644 for '/Users/me/key.pem' are too open.\nPermission denied (publickey).", exitStatus: 255).contains("chmod 600"))
    XCTAssertEqual(SSHCommand.friendlyError(from: "ssh: Could not resolve hostname nope: nodename nor servname provided", exitStatus: 255), "Could not resolve the host name.")
  }
}
