// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScaleCLI", platforms: [.macOS(.v13)],
    products: [.executable(name: "scalectl", targets: ["scalectl"])],
    targets: [
        .target(name: "TerminalIO"),
        .target(name: "ScaleCore", dependencies: ["TerminalIO"]),
        .executableTarget(name: "scalectl", dependencies: ["ScaleCore"]),
        .executableTarget(name: "ScaleCoreChecks", dependencies: ["ScaleCore"], path: "Tests/ScaleCoreTests")
    ]
)
