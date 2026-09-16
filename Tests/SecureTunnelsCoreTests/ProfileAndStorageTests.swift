import XCTest
@testable import SecureTunnelsCore

final class ProfileAndStorageTests: XCTestCase {
  func testOldTunnelsFileWithoutGroupsOrProfilesStillDecodes() throws {
    let json = """
    {"version":1,"tunnels":[{"id":"9ACAC557-E1BD-4A2E-84D0-6BF4A7EEABD0","name":"Old","type":"local","host":"h",
    "port":22,"username":"u","identityFile":"","bindAddress":"localhost","bindPort":1,"targetHost":"localhost",
    "targetPort":2,"autoConnect":false,"autoReconnect":true,"reconnectInterval":30,"serverAliveInterval":30,
    "serverAliveCountMax":5,"compression":false,"strictHostKeyChecking":false,"importedFromSecurePipes":true}]}
    """
    let stored = try JSONDecoder().decode(StoredData.self, from: Data(json.utf8))
    XCTAssertEqual(stored.version, 1)
    XCTAssertEqual(stored.profiles, [])
    XCTAssertEqual(stored.tunnels.count, 1)
    XCTAssertEqual(stored.tunnels[0].group, "")
    XCTAssertNil(stored.tunnels[0].profileID)
    XCTAssertTrue(stored.tunnels[0].importedFromSecurePipes)
  }

  func testStoredDataRoundTrip() throws {
    let profile = Profile(name: "Bastion", host: "bastion.example.com", username: "ec2-user", identityFile: "~/.ssh/k.pem")
    let tunnel = Tunnel(name: "Mongo", group: "Prod", profileID: profile.id, bindPort: 27018, targetPort: 27017)
    let data = try JSONEncoder().encode(StoredData(tunnels: [tunnel], profiles: [profile]))
    let decoded = try JSONDecoder().decode(StoredData.self, from: data)
    XCTAssertEqual(decoded.version, 2)
    XCTAssertEqual(decoded.tunnels, [tunnel])
    XCTAssertEqual(decoded.profiles, [profile])
  }

  func testApplyingProfileOverridesConnectionFieldsOnly() {
    let profile = Profile(name: "Bastion", host: "bastion.example.com", port: 2200, username: "ec2-user", identityFile: "~/.ssh/k.pem")
    let tunnel = Tunnel(name: "Mongo", host: "old", port: 22, username: "old", identityFile: "old", bindPort: 27018, targetHost: "db", targetPort: 27017)
    let resolved = tunnel.applying(profile)
    XCTAssertEqual(resolved.host, "bastion.example.com")
    XCTAssertEqual(resolved.port, 2200)
    XCTAssertEqual(resolved.username, "ec2-user")
    XCTAssertEqual(resolved.identityFile, "~/.ssh/k.pem")
    XCTAssertEqual(resolved.bindPort, 27018)
    XCTAssertEqual(resolved.targetHost, "db")
    XCTAssertEqual(tunnel.applying(nil), tunnel)
  }

  func testProfileSummary() {
    XCTAssertEqual(Profile(host: "h", username: "u").summary, "u@h")
    XCTAssertEqual(Profile(host: "h", port: 2222, username: "").summary, "h:2222")
  }
}
