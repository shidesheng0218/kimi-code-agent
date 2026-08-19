// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "KimiCodeAgent",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "KimiAgentCore", targets: ["KimiAgentCore"]),
    .executable(name: "KimiCodeAgent", targets: ["KimiCodeAgent"]),
    .executable(name: "KimiNativeBridge", targets: ["KimiNativeBridge"])
  ],
  dependencies: [],
  targets: [
    .target(name: "KimiAgentCore"),
    .executableTarget(name: "KimiCodeAgent", dependencies: ["KimiAgentCore"]),
    .executableTarget(name: "KimiNativeBridge", dependencies: ["KimiAgentCore"]),
    .executableTarget(name: "KimiAgentCoreChecks", dependencies: ["KimiAgentCore"])
  ]
)
