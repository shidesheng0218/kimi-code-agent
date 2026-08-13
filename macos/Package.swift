// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "KimiAgentDesktop",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "KimiAgentCore", targets: ["KimiAgentCore"]),
    .executable(name: "KimiAgentDesktop", targets: ["KimiAgentDesktop"])
  ],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.18.0")
  ],
  targets: [
    .target(name: "KimiAgentCore"),
    .executableTarget(
      name: "KimiAgentDesktop",
      dependencies: ["KimiAgentCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
      resources: [.copy("Resources")]
    ),
    .executableTarget(name: "KimiAgentCoreChecks", dependencies: ["KimiAgentCore"])
  ]
)
