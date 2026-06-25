// swift-tools-version:5.9
import PackageDescription

// This repo is simultaneously an Elixir/Mix package (the codegen extension) and
// this Swift SPM package (the runtime). See ADR-0005.
let package = Package(
    name: "AshSwiftRuntime",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "AshSwiftRuntime", targets: ["AshSwiftRuntime"])
    ],
    targets: [
        // Zero third-party dependencies (ADR-0004).
        .target(name: "AshSwiftRuntime"),
        .testTarget(name: "AshSwiftRuntimeTests", dependencies: ["AshSwiftRuntime"])
    ]
)
