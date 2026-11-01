// swift-tools-version:5.9

/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import PackageDescription

/// The production consumer package.
///
/// Keeping this manifest at the repository root lets another application pin
/// TakoCoreUI directly to a release or an exact Git revision. The larger manifest under `swift/` also builds the ported macOS
/// app and its tests; none of those test-only targets belong in a mobile
/// consumer's dependency graph.
let package = Package(
    name: "TakoCoreUI",
    platforms: [
        // macOS 14: TakoTerminalNSView drives redraws with CADisplayLink,
        // which does not exist on 13.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TakoCoreUI", targets: ["TakoCoreUI"]),
    ],
    targets: [
        .binaryTarget(
            name: "TakoCoreXCFramework",
            // The Rust engine for macOS arm64, iOS device and iOS Simulator,
            // published as a release asset rather than committed. Both values
            // are rewritten by scripts/package-xcframework.sh.
            url: "https://github.com/alex09x/tako/releases/download/v0.1.12/TakoCore.xcframework.zip",
            checksum: "8bb3de4a444469b608ae48ec16d6154c7cc11dfb2c1030ad63f3d43161508494"
        ),
        .target(
            name: "TakoCoreUI",
            dependencies: ["TakoCoreXCFramework"],
            path: "swift/Sources/TakoCoreUI",
            resources: [
                // Xcode compiles this into the package resource bundle's
                // default.metallib. TakoTerminalView / TakoTerminalNSView
                // explicitly asks Metal for the library in that bundle, so a
                // package consumer gets the GPU renderer without a custom build phase.
                .process("Resources/TerminalShaders.metal"),
            ]
        ),
        .testTarget(
            name: "TakoCoreUITests",
            dependencies: ["TakoCoreUI"],
            path: "swift/Tests/TakoCoreUITests"
        ),
    ]
)
