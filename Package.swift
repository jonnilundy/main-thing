// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mainthing",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MainThingCore", targets: ["MainThingCore"]),
        .library(name: "MainThingApp", targets: ["MainThingApp"]),
        .executable(name: "MainThing", targets: ["MainThing"]),
        .executable(name: "mainthing-checks", targets: ["mainthing-checks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .target(name: "MainThingCore"),
        // The app itself, a library so Xcode can render its previews. The executable only calls in.
        .target(
            name: "MainThingApp",
            dependencies: ["MainThingCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(name: "MainThing", dependencies: ["MainThingApp"]),
        .executableTarget(name: "mainthing-checks", dependencies: ["MainThingCore"]),
    ]
)
