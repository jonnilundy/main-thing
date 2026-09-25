// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nextup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NextUpCore", targets: ["NextUpCore"]),
        .executable(name: "NextUp", targets: ["NextUp"]),
        .executable(name: "nextup-checks", targets: ["nextup-checks"]),
    ],
    targets: [
        .target(name: "NextUpCore"),
        .executableTarget(name: "NextUp", dependencies: ["NextUpCore"]),
        .executableTarget(name: "nextup-checks", dependencies: ["NextUpCore"]),
    ]
)
