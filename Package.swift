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
            name: "CLibMTP",
            pkgConfig: "libmtp",
            providers: [
                .brew(["libmtp"])
            ]
        ),
        .target(
            name: "MTPBridge",
            dependencies: ["CLibMTP"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AndroidDesk",
            dependencies: ["MTPBridge"]
        )
    ]
)
