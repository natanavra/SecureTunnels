// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "SecureTunnels",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SecureTunnels", targets: ["SecureTunnels"]),
    .executable(name: "SecureTunnelsAskPass", targets: ["SecureTunnelsAskPass"]),
  ],
  targets: [
    .target(name: "SecureTunnelsCore"),
    .executableTarget(name: "SecureTunnels", dependencies: ["SecureTunnelsCore"]),
    .executableTarget(name: "SecureTunnelsAskPass", dependencies: ["SecureTunnelsCore"]),
    .testTarget(
      name: "SecureTunnelsCoreTests",
      dependencies: ["SecureTunnelsCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
