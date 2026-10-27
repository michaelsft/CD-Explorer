// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CDExplorer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "DiscPrimer",
            path: "DiscPrimer",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "CDExplorer",
            dependencies: [
                "DiscPrimer",
                .product(name: "MPVKit-GPL", package: "MPVKit")
            ],
            path: "Sources",
            exclude: ["SelfTest.swift"],
            sources: ["EnhancedCDExtractor.swift"],
            linkerSettings: [
                .linkedFramework("OpenGL")
            ]
        )
    ]
)
