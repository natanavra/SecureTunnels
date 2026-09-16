import XCTest
@testable import SecureTunnelsCore

final class CloudflaredCLITests: XCTestCase {
  func testParsesAccountAndZoneFromCertificate() {
    let payload = #"{"zoneID":"zone123","accountID":"acct456","apiToken":"secret","serviceKey":""}"#
    let pem = """
    -----BEGIN CERTIFICATE-----
    MIIB
    -----END CERTIFICATE-----
    -----BEGIN ARGO TUNNEL TOKEN-----
    \(Data(payload.utf8).base64EncodedString(options: [.lineLength64Characters]))
    -----END ARGO TUNNEL TOKEN-----
    """
    XCTAssertEqual(CloudflaredCLI.parseCertificate(pem), CloudflaredCLI.CertificateInfo(accountID: "acct456", zoneID: "zone123"))
    XCTAssertNil(CloudflaredCLI.parseCertificate("-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----"))
  }

  func testParsesTunnelListJSON() throws {
    let json = #"[{"id":"7a1c-1","name":"prod","created_at":"2026-01-01T00:00:00Z","connections":[{"id":"c1"}],"deleted_at":null}]"#
    let tunnels = try CloudflaredCLI.parseTunnelList(json)
    XCTAssertEqual(tunnels.count, 1)
    XCTAssertEqual(tunnels[0].name, "prod")
    XCTAssertEqual(tunnels[0].connectionCount, 1)
    XCTAssertEqual(try CloudflaredCLI.parseTunnelList("null\n"), [])
    XCTAssertEqual(try CloudflaredCLI.parseTunnelList(""), [])
  }

  func testParsesCreatedTunnelID() {
    let output = """
    Tunnel credentials written to /Users/me/.cloudflared/6ff42ae2-765d-4adf-8112-31c55c1551ef.json.
    Created tunnel securetunnels-preview-1a2b3c4d with id 6FF42AE2-765D-4ADF-8112-31C55C1551EF
    """
    XCTAssertEqual(CloudflaredCLI.parseCreatedTunnelID(output), "6ff42ae2-765d-4adf-8112-31c55c1551ef")
    XCTAssertNil(CloudflaredCLI.parseCreatedTunnelID("nothing"))
  }

  func testRunArgumentsAndErrorDescription() {
    let cli = CloudflaredCLI(binary: URL(fileURLWithPath: "/usr/local/bin/cloudflared"))
    XCTAssertEqual(cli.runArguments(tunnelID: "t1", serviceURL: "http://localhost:3000"),
      ["tunnel", "--no-autoupdate", "run", "--url", "http://localhost:3000", "t1"])
    let error = CloudflaredCLIError(command: "tunnel route dns", output: "2026-09-16T10:00:00Z ERR Failed to add route: code: 1003, reason: An A, AAAA, or CNAME record with that host already exists.")
    XCTAssertEqual(error.errorDescription, "cloudflared tunnel route dns failed: Failed to add route: code: 1003, reason: An A, AAAA, or CNAME record with that host already exists.")
  }
}
