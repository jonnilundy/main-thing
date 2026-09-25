// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mainthing",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MainThingCore", targets: ["MainThingCore"]),
        .executable(name: "MainThing", targets: ["MainThing"]),
        .executable(name: "mainthing-checks", targets: ["mainthing-checks"]),
    ],
    targets: [
        .target(name: "MainThingCore"),
        .executableTarget(name: "MainThing", dependencies: ["MainThingCore"]),
        .executableTarget(name: "mainthing-checks", dependencies: ["MainThingCore"]),
    ]
)
