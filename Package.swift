// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SilentDiscoDiagnostics",
  platforms: [.macOS(.v10_15)],
  products: [.library(name: "DiagnosticsCore", targets: ["DiagnosticsCore"])],
  targets: [
    .target(
      name: "DiagnosticsCore", path: "ios/Runner/Diagnostics", exclude: ["DiagnosticBridge.swift"]
    ),
    .testTarget(
      name: "DiagnosticsCoreTests", dependencies: ["DiagnosticsCore"], path: "test/native"),
  ]
)
