import Foundation
import XCTest
@testable import SecureTunnelsCore

final class SecurePipesImporterTests: XCTestCase {
  private func loadFixture() throws -> [Tunnel] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "connections", withExtension: "plist", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    return SecurePipesImporter.parse(root)
  }

  func testParsesAllSupportedTypesAndSkipsUnknown() throws {
    let tunnels = try loadFixture()
    XCTAssertEqual(tunnels.map(\.name), ["Agent Key Redis", "Expose Web", "Office Proxy", "Prod Mongo"])
    XCTAssertEqual(tunnels.map(\.type), [.local, .remote, .dynamic, .local])
    XCTAssertTrue(tunnels.allSatisfy(\.importedFromSecurePipes))
  }

  func testLocalForwardFields() throws {
    let mongo = try XCTUnwrap(loadFixture().first { $0.name == "Prod Mongo" })
    XCTAssertEqual(mongo.id, UUID(uuidString: "9ACAC557-E1BD-4A2E-84D0-6BF4A7EEABD0"))
    XCTAssertEqual(mongo.host, "203.0.113.10")
    XCTAssertEqual(mongo.port, 2222)
    XCTAssertEqual(mongo.username, "ec2-user")
    XCTAssertEqual(mongo.identityFile, "/Users/me/keys/mongo.pem")
    XCTAssertEqual(mongo.bindAddress, "localhost")
    XCTAssertEqual(mongo.bindPort, 8082)
    XCTAssertEqual(mongo.targetHost, "localhost")
    XCTAssertEqual(mongo.targetPort, 27017)
    XCTAssertTrue(mongo.autoConnect)
    XCTAssertTrue(mongo.autoReconnect)
    XCTAssertEqual(mongo.reconnectInterval, 60)
    XCTAssertEqual(mongo.serverAliveInterval, 15)
    XCTAssertEqual(mongo.serverAliveCountMax, 3)
    XCTAssertTrue(mongo.compression)
  }

  func testNestedFolderAndDefaultsWhenFieldsMissing() throws {
    let redis = try XCTUnwrap(loadFixture().first { $0.name == "Agent Key Redis" })
    XCTAssertEqual(redis.identityFile, "", "identity file is dropped when useCustomIdentity is off")
    XCTAssertEqual(redis.port, 22)
    XCTAssertEqual(redis.bindAddress, "localhost")
    XCTAssertEqual(redis.bindPort, 6380)
    XCTAssertEqual(redis.targetHost, "10.0.0.5")
    XCTAssertFalse(redis.autoConnect)
    XCTAssertEqual(redis.reconnectInterval, 30)
  }

  func testRemoteForwardMapsBindAndTarget() throws {
    let web = try XCTUnwrap(loadFixture().first { $0.name == "Expose Web" })
    XCTAssertEqual(web.bindAddress, "0.0.0.0")
    XCTAssertEqual(web.bindPort, 9000)
    XCTAssertEqual(web.targetHost, "127.0.0.1")
    XCTAssertEqual(web.targetPort, 3000)
  }

  func testManagedSocksBecomesDynamic() throws {
    let proxy = try XCTUnwrap(loadFixture().first { $0.name == "Office Proxy" })
    XCTAssertEqual(proxy.type, .dynamic)
    XCTAssertEqual(proxy.bindPort, 1080)
    XCTAssertEqual(proxy.forwardDescription, "SOCKS on localhost:1080")
  }
}
