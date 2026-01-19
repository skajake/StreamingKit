// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "StreamingKit",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13)
    ],
    products: [
        .library(
            name: "StreamingKit",
            targets: ["StreamingKit"]
        )
    ],
    targets: [
        .target(
            name: "StreamingKit",
            path: "StreamingKit/StreamingKit",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AudioUnit", .when(platforms: [.macOS]))
            ]
        )
    ]
)
