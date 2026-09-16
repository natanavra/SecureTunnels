import XCTest
@testable import SecureTunnelsCore

/// Records requests and answers them from a queue, so the API client can be tested without the network.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
  var requests: [URLRequest] = []
  var responses: [(Int, String)] = []

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let (status, body) = responses.isEmpty ? (200, #"{"success":true,"result":null}"#) : responses.removeFirst()
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

final class CloudflareTests: XCTestCase {
  func testQuickTunnelURLAndConnectionMarkerParsing() {
    let log = """
    2026-09-16T08:00:00Z INF Thank you for trying Cloudflare Tunnel.
    2026-09-16T08:00:01Z INF +--------------------------------------------------------------------------------------------+
    2026-09-16T08:00:01Z INF |  https://quiet-otter-fox-mars.trycloudflare.com                                            |
    2026-09-16T08:00:01Z INF +--------------------------------------------------------------------------------------------+
    2026-09-16T08:00:02Z INF Registered tunnel connection connIndex=0 connection=abc location=ams
    """
    XCTAssertEqual(Cloudflared.quickTunnelURL(in: log), "https://quiet-otter-fox-mars.trycloudflare.com")
    XCTAssertTrue(Cloudflared.isConnected(log))
    XCTAssertNil(Cloudflared.quickTunnelURL(in: "nothing here"))
    XCTAssertFalse(Cloudflared.isConnected("2026 INF Starting tunnel"))
  }

  func testFriendlyErrors() {
    XCTAssertEqual(
      Cloudflared.friendlyError(from: "2026 ERR Provided Tunnel token is not valid.", exitStatus: 1),
      "Cloudflare rejected the tunnel token. Check the API token in Settings and provision the tunnel again."
    )
    XCTAssertEqual(Cloudflared.friendlyError(from: "2026 ERR failed to connect to origin error=\"dial tcp: connection refused\"", exitStatus: 1),
      "failed to connect to origin error=\"dial tcp: connection refused\"")
    XCTAssertEqual(Cloudflared.friendlyError(from: "", exitStatus: 2), "cloudflared exited with status 2.")
  }

  func testZoneMatchingPrefersLongestSuffix() {
    let zones = [CloudflareAPI.Zone(id: "1", name: "example.com"), CloudflareAPI.Zone(id: "2", name: "dev.example.com")]
    XCTAssertEqual(CloudflareAPI.zone(for: "app.dev.example.com", in: zones)?.id, "2")
    XCTAssertEqual(CloudflareAPI.zone(for: "app.example.com", in: zones)?.id, "1")
    XCTAssertEqual(CloudflareAPI.zone(for: "example.com", in: zones)?.id, "1")
    XCTAssertNil(CloudflareAPI.zone(for: "other.net", in: zones))
  }

  func testProvisionCreatesTunnelIngressDNSAndFetchesToken() async throws {
    let transport = FakeTransport()
    transport.responses = [
      (200, #"{"success":true,"result":[{"id":"z1","name":"example.com"}]}"#),
      (200, #"{"success":true,"result":{"id":"t1","name":"securetunnels-preview"}}"#),
      (200, #"{"success":true,"result":{}}"#),
      (200, #"{"success":true,"result":{"id":"r1","name":"preview.example.com","type":"CNAME","content":"t1.cfargotunnel.com"}}"#),
      (200, #"{"success":true,"result":"eyJ0b2tlbiI6IjEifQ"}"#),
    ]
    let api = CloudflareAPI(token: "secret", transport: transport)
    let result = try await api.provision(accountID: "acc", hostname: "preview.example.com", serviceURL: "http://localhost:3000",
      tunnelName: "securetunnels-preview", existing: CloudflareConfig())
    XCTAssertEqual(result, CloudflareAPI.Provisioned(tunnelID: "t1", zoneID: "z1", dnsRecordID: "r1", token: "eyJ0b2tlbiI6IjEifQ"))

    let paths = transport.requests.map { $0.httpMethod! + " " + $0.url!.path }
    XCTAssertEqual(transport.requests[0].url!.query, "per_page=50&status=active")
    XCTAssertEqual(paths, [
      "GET /client/v4/zones",
      "POST /client/v4/accounts/acc/cfd_tunnel",
      "PUT /client/v4/accounts/acc/cfd_tunnel/t1/configurations",
      "POST /client/v4/zones/z1/dns_records",
      "GET /client/v4/accounts/acc/cfd_tunnel/t1/token",
    ])
    XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    let ingress = try JSONSerialization.jsonObject(with: transport.requests[2].httpBody!) as! [String: Any]
    let rules = (ingress["config"] as! [String: Any])["ingress"] as! [[String: Any]]
    XCTAssertEqual(rules[0]["hostname"] as? String, "preview.example.com")
    XCTAssertEqual(rules[0]["service"] as? String, "http://localhost:3000")
    XCTAssertEqual(rules[1]["service"] as? String, "http_status:404")
    let dns = try JSONSerialization.jsonObject(with: transport.requests[3].httpBody!) as! [String: Any]
    XCTAssertEqual(dns["content"] as? String, "t1.cfargotunnel.com")
    XCTAssertEqual(dns["proxied"] as? Bool, true)
  }

  func testProvisionReusesExistingTunnelAndUpdatesExistingDNS() async throws {
    let transport = FakeTransport()
    transport.responses = [
      (200, #"{"success":true,"result":[{"id":"z1","name":"example.com"}]}"#),
      (200, #"{"success":true,"result":{}}"#),
      (400, #"{"success":false,"errors":[{"code":81057,"message":"Record already exists."}]}"#),
      (200, #"{"success":true,"result":[{"id":"r9","name":"preview.example.com","type":"CNAME","content":"old"}]}"#),
      (200, #"{"success":true,"result":{"id":"r9","name":"preview.example.com","type":"CNAME","content":"t1.cfargotunnel.com"}}"#),
      (200, #"{"success":true,"result":"tok"}"#),
    ]
    let api = CloudflareAPI(token: "secret", transport: transport)
    let result = try await api.provision(accountID: "acc", hostname: "preview.example.com", serviceURL: "http://localhost:3000",
      tunnelName: "n", existing: CloudflareConfig(hostname: "preview.example.com", tunnelID: "t1"))
    XCTAssertEqual(result.tunnelID, "t1")
    XCTAssertEqual(result.dnsRecordID, "r9")
    let paths = transport.requests.map { $0.httpMethod! + " " + $0.url!.path }
    XCTAssertFalse(paths.contains("POST /client/v4/accounts/acc/cfd_tunnel"))
    XCTAssertEqual(paths.last, "GET /client/v4/accounts/acc/cfd_tunnel/t1/token")
    XCTAssertTrue(paths.contains("PUT /client/v4/zones/z1/dns_records/r9"))
  }

  func testAPIErrorSurfacesMessages() async {
    let transport = FakeTransport()
    transport.responses = [(403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)]
    let api = CloudflareAPI(token: "bad", transport: transport)
    do {
      _ = try await api.accounts()
      XCTFail("expected an error")
    } catch let error as CloudflareAPIError {
      XCTAssertEqual(error.status, 403)
      XCTAssertEqual(error.messages, ["Authentication error"])
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testCloudflareTunnelDescriptionsAndDecoding() throws {
    var tunnel = Tunnel(name: "Preview", type: .cloudflare, bindPort: 3000)
    XCTAssertEqual(tunnel.forwardDescription, "localhost:3000 → temporary trycloudflare.com URL")
    XCTAssertNil(tunnel.cloudflarePublicURL)
    tunnel.cloudflare.hostname = "preview.example.com"
    XCTAssertEqual(tunnel.forwardDescription, "localhost:3000 → https://preview.example.com")
    XCTAssertEqual(tunnel.cloudflareServiceURL, "http://localhost:3000")
    XCTAssertFalse(tunnel.listensLocally)
    XCTAssertFalse(tunnel.type.usesSSH)

    let old = #"{"id":"9ACAC557-E1BD-4A2E-84D0-6BF4A7EEABD0","name":"x","type":"local"}"#
    let decoded = try JSONDecoder().decode(Tunnel.self, from: Data(old.utf8))
    XCTAssertEqual(decoded.cloudflare, CloudflareConfig())
  }
}

final class CloudflareRemoteTunnelTests: XCTestCase {
  func testRemoteTunnelDecodesStatusAndConnectionCount() throws {
    let json = #"[{"id":"t1","name":"prod","status":"healthy","created_at":"2026-01-01T00:00:00Z","connections":[{"id":"a"},{"id":"b"}]},{"id":"t2","name":"idle"}]"#
    let tunnels = try JSONDecoder().decode([CloudflareAPI.RemoteTunnel].self, from: Data(json.utf8))
    XCTAssertEqual(tunnels[0].status, "healthy")
    XCTAssertEqual(tunnels[0].connectionCount, 2)
    XCTAssertNil(tunnels[1].status)
    XCTAssertNil(tunnels[1].connectionCount)
  }

  func testIngressDropsCatchAllRule() async throws {
    let transport = FakeTransport()
    transport.responses = [(200, #"{"success":true,"result":{"config":{"ingress":[{"hostname":"app.example.com","service":"http://localhost:3000"},{"service":"http_status:404"}]}}}"#)]
    let api = CloudflareAPI(token: "t", transport: transport)
    let rules = try await api.ingress(accountID: "acc", tunnelID: "t1")
    XCTAssertEqual(rules, [CloudflareAPI.Ingress(hostname: "app.example.com", service: "http://localhost:3000")])
    XCTAssertEqual(transport.requests[0].url!.path, "/client/v4/accounts/acc/cfd_tunnel/t1/configurations")
  }

  func testDeleteTunnelAndRoutesRemovesOnlyMatchingCNAMEs() async throws {
    let transport = FakeTransport()
    transport.responses = [
      (200, #"{"success":true,"result":[{"id":"z1","name":"example.com"}]}"#),
      (200, #"{"success":true,"result":[{"id":"r1","name":"app.example.com","type":"CNAME","content":"T1.cfargotunnel.com"},{"id":"r2","name":"app.example.com","type":"TXT","content":"x"}]}"#),
      (200, #"{"success":true,"result":{}}"#),
      (200, #"{"success":true,"result":{}}"#),
    ]
    let api = CloudflareAPI(token: "t", transport: transport)
    try await api.deleteTunnelAndRoutes(accountID: "acc", tunnelID: "t1", hostnames: ["app.example.com", "other.net"])
    let calls = transport.requests.map { $0.httpMethod! + " " + $0.url!.path }
    XCTAssertEqual(calls, [
      "GET /client/v4/zones",
      "GET /client/v4/zones/z1/dns_records",
      "DELETE /client/v4/zones/z1/dns_records/r1",
      "DELETE /client/v4/accounts/acc/cfd_tunnel/t1",
    ])
    XCTAssertEqual(transport.requests[3].url!.query, "cascade=true")
  }

  func testAdoptedConfigDecodesWithDefault() throws {
    let decoded = try JSONDecoder().decode(CloudflareConfig.self, from: Data(#"{"hostname":"a.example.com","scheme":"http","tunnelID":"t1"}"#.utf8))
    XCTAssertFalse(decoded.adopted)
    XCTAssertEqual(decoded.tunnelID, "t1")
  }
}
