import Darwin
import XCTest
@testable import SecureTunnelsCore

final class PortProbeTests: XCTestCase {
  func testParsesLsofFieldOutput() {
    let usage = PortProbe.parse("p1914\ncssh\np2000\ncnode\n", port: 8080)
    XCTAssertEqual(usage, PortUsage(port: 8080, processName: "ssh", pid: 1914))
    XCTAssertNil(PortProbe.parse("", port: 8080))
    XCTAssertEqual(usage?.description, "port 8080 is already in use by ssh (pid 1914)")
  }

  func testFindsThisProcessListeningOnAPort() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    XCTAssertEqual(bindResult, 0)
    XCTAssertEqual(listen(fd, 1), 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    let port = Int(UInt16(bigEndian: address.sin_port))

    let usage = try XCTUnwrap(PortProbe.listener(on: port))
    XCTAssertEqual(usage.pid, getpid())
    XCTAssertEqual(usage.port, port)
    XCTAssertNil(PortProbe.listener(on: 1))
  }
}
