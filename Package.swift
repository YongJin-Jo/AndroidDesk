// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AndroidDesk", targets: ["AndroidDesk"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibMTP"
        ),
        .target(
            name: "MTPBridge",
            dependencies: ["CLibMTP"],
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/libmtp/lib"]),
                .linkedLibrary("mtp")
            ]
        ),
        .executableTarget(
            name: "AndroidDesk",
            dependencies: ["MTPBridge"]
        )
    ]
)
