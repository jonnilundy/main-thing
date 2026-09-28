// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "main-thing",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MainThingCore", targets: ["MainThingCore"]),
        .library(name: "MainThingApp", targets: ["MainThingApp"]),
        .executable(name: "MainThing", targets: ["MainThing"]),
        .executable(name: "main-thing-checks", targets: ["main-thing-checks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        // Global shortcuts through Carbon hot keys (no Accessibility permission) and the recorder in Settings. MIT.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0"),
    ],
    targets: [
        .target(name: "MainThingCore"),
        // The app itself, a library so Xcode can render its previews. The executable only calls in.
        .target(
            name: "MainThingApp",
            dependencies: [
                "MainThingCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(name: "MainThing", dependencies: ["MainThingApp"]),
        .executableTarget(name: "main-thing-checks", dependencies: ["MainThingCore"]),
    ]
)
