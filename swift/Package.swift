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

// The macOS app layer and its tests, for `swift test`.
//
// The terminal engine and its views (TakoCoreUI, over TakoCore.xcframework)
// come from tako-core at one exact release; SwiftPM checks the framework's
// checksum, and Package.resolved records the commit. The app links the same
// release: scripts/tako_core.py hands the resolved checkout and framework to
// scripts/build-macapp.py and scripts/build-iosapp.py, which drive swiftc
// directly (see their own module and link ordering).
//
// The remaining targets (TakoKit, TakoObjC, Tako) wrap the macOS app layer
// (swift/Sources/TakoApp, see ../ARCHITECTURE.md) so upstream's own test
// suite (macos/Tests, macos/TakoUITests upstream) can run against it here.
let package = Package(
    name: "Tako",
    // macOS 14: TakoTerminalNSView drives redraws with CADisplayLink, which
    // does not exist on 13.
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/alex09x/tako-core.git", exact: "0.1.2"),
    ],
    targets: [
        // App shim targets (see ../ARCHITECTURE.md).
        .target(name: "TakoKit"),
        .target(
            name: "TakoObjC",
            publicHeadersPath: "."
        ),
        // The macOS app layer plus the `Tako.*` adapter over the engine
        // (TakoShim), as ONE module -- matching build-macapp.py's own real
        // build.
        .target(
            name: "Tako",
            dependencies: [
                "TakoKit",
                "TakoObjC",
                .product(name: "TakoCoreUI", package: "tako-core"),
            ],
            path: "Sources/TakoApp",
            exclude: [
                "LICENSE",
                "NOTICE.md",
                // SPM auto-detects a target as executable when it sees a
                // literal `main.swift`, which conflicts with declaring
                // `Tako` as a library target. Not needed for testing --
                // the real app entry point stays in scripts/build-macapp.py's
                // own file list.
                "App/macOS/main.swift",
                "App/macOS/MainMenu.xib",
                // Imported manually via -import-objc-header below, not
                // auto-detected as a target header (which would make this a
                // mixed Swift+ObjC target).
                "_TakoShim/Tako-Bridging-Header.h",
                "Features/Settings/ConfigurationErrors.xib",
                "Features/ClipboardConfirmation/ClipboardConfirmation.xib",
                "Features/Terminal/Window Styles/Terminal.xib",
                "Features/Terminal/Window Styles/TerminalTabsTitlebarTahoe.xib",
                "Features/Terminal/Window Styles/TerminalTabsTitlebarVentura.xib",
                "Features/Terminal/Window Styles/TerminalTransparentTitlebar.xib",
                "Features/Terminal/Window Styles/TerminalHiddenTitlebar.xib",
                "Features/About/About.xib",
                "Features/QuickTerminal/QuickTerminal.xib",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-import-objc-header", "Sources/TakoApp/_TakoShim/Tako-Bridging-Header.h",
                ])
            ]
        ),

        // Upstream's own test suite (macos/Tests, macos/TakoUITests),
        // ported verbatim where possible against the target above.
        .testTarget(
            name: "TakoTests",
            dependencies: ["Tako"]
        ),

        // Claims Sources/iOSApp explicitly so SPM doesn't treat it as an
        // orphaned implicit target (it has its own bridging header). Its real
        // source needs UIKit/the iOS SDK, which this macOS-only test package
        // can't build, and is built instead by ios/project.yml. Declared purely
        // so the package graph resolves; not part of the test suite.
        //
        // Named as a `sources` allow-list rather than an `exclude` deny-list:
        // the deny-list silently went stale every time a file was added
        // beside it, and the failure landed on whoever next ran
        // `swift build` rather than on whoever added the file.
        .target(
            name: "iOSApp",
            sources: ["PackagePlaceholder.swift"]
        ),
    ]
)
