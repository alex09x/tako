// swift-tools-version:5.9
import PackageDescription

// TakoCoreUI: the rendering half of the terminal, so an app needs no
// third-party emulator. It draws the cells that TakoCore (Rust, via
// UniFFI) produces, with CoreText only -- no AppKit, no UIKit, so the same
// source serves macOS, iOS and offscreen rendering.
//
// Consumers add TakoCore.xcframework (built by
// scripts/build-xcframework.sh) plus the generated tako_core.swift, then
// this package for the view layer.
//
// The remaining targets (TakoKit, TakoObjC, Tako)
// exist for `swift test` only: they wrap upstream's verbatim macOS app
// layer (swift/Sources/TakoApp, see macos_port/README.md) plus the shim
// that lets it typecheck without upstream's Zig core,
// so upstream's own test suite (macos/Tests, macos/TakoUITests
// upstream) can run against it here. None of this is part
// of the shipped app binary, which is assembled separately by
// scripts/build-macapp.py using raw swiftc (SPM does not drive the real
// build -- see that script's own module/link ordering).
//
// The bridging header references the generated `tako_coreFFI.h`, so
// `./scripts/build-xcframework.sh` must have been run at least once before
// `swift test` will find it.
let package = Package(
    name: "TakoCoreUI",
    // macOS 14, matching the production manifest: TakoTerminalNSView drives
    // redraws with CADisplayLink, which does not exist on 13, so a lower
    // floor here cannot compile the view the package exports.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TakoCoreUI", targets: ["TakoCoreUI"]),
    ],
    targets: [
        // The compiled Rust core, as a real SPM dependency-graph edge --
        // unlike raw linker unsafeFlags, this propagates correctly into
        // `swift test`'s auto-generated aggregate test bundle, which needs
        // to link it even though no test calls into it directly.
        .binaryTarget(name: "TakoCoreXCFramework", path: "../TakoCore.xcframework"),

        // The checked-in Generated/tako_core.swift matches the checked-in
        // XCFramework so both local tests and remote SwiftPM consumers build
        // without relying on a gitignored target/bindings directory.
        .target(
            name: "TakoCoreUI",
            dependencies: ["TakoCoreXCFramework"],
            resources: [
                .process("Resources/TerminalShaders.metal"),
            ]
        ),

        // Upstream's own shim targets (see macos_port/README.md's table).
        .target(name: "TakoKit"),
        .target(
            name: "TakoObjC",
            publicHeadersPath: "."
        ),
        // Upstream's app layer, verbatim, plus the `Tako.*` adapter over
        // the Rust core (TakoShim). Test-only target: not linked against
        // the Rust static library, since nothing here calls into it
        // directly -- TakoKit is a pure-Swift shim, not a real FFI
        // bridge, and the bridging header's `tako_coreFFI.h` import is
        // type-only (upstream's own files never got that far into our
        // stack; see macos_port/README.md).
        .target(
            name: "Tako",
            dependencies: ["TakoKit", "TakoObjC"],
            // Upstream's app layer plus the `Tako.*` adapter over the
            // Rust core, as ONE module -- matching build-macapp.py's own
            // real build, which flat-compiles TakoApp + TakoShim +
            // TakoCoreUI + the generated tako_core.swift together (that's
            // why TakoShim's `Tako+App.swift` can reference
            // `TakoCore`/`TerminalRenderer`/`TerminalTheme` with no
            // import: they're in the same compilation unit, not a
            // dependency). `_TakoShim`, `_TakoCoreUI` and `_bindings`
            // are symlinks to the real locations -- SPM won't combine
            // sibling Sources/ directories into one target's sources, but
            // will follow symlinks placed inside the target's own path.
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
                // build-macapp.py excludes this too: it's upstream's iOS
                // app shell, incompatible with the macOS-only shim surface
                // TakoKit/TakoShim provide here.
                "App/iOS/iOSApp.swift",
                // Imported manually via -import-objc-header below, not
                // auto-detected as a target header (which would make this a
                // mixed Swift+ObjC target).
                "_TakoShim/Tako-Bridging-Header.h",
                // _bindings is a symlink to target/bindings (the UniFFI
                // codegen output): only tako_core.swift is a source file,
                // the C header/modulemap are for the real app link step,
                // not needed (and not Swift) here.
                "_bindings/tako_coreFFI.h",
                "_bindings/tako_coreFFI.modulemap",
                // The real TakoCoreUI target carries its checked-in generated
                // binding, while this flattened Tako test target supplies
                // the same binding through its own top-level _bindings link.
                "_TakoCoreUI/Generated",
                // TakoCoreUI owns and processes this shader resource. The
                // Tako test shim follows a symlink into that source tree,
                // but must not try to package the same resource a second time.
                "_TakoCoreUI/Resources",
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
                    "-Xcc", "-I../target/bindings",
                ])
            ]
        ),

        // Upstream's own test suite (macos/Tests, macos/TakoUITests),
        // ported verbatim where possible against the target above.
        .testTarget(
            name: "TakoTests",
            dependencies: ["Tako"],
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I../target/bindings",
                ])
            ]
        ),

        .testTarget(
            name: "TakoCoreUITests",
            dependencies: ["TakoCoreUI"]
        ),

        // Claims Sources/iOSApp explicitly so SPM doesn't treat it as an
        // orphaned implicit target (it has its own bridging header, same
        // "mixed language source files" trap as TakoShim did). Its real
        // source needs UIKit/the iOS SDK, which this macOS-only package
        // (see `platforms:` above) can't build, and is built instead by
        // ios/project.yml. Declared purely so the package graph resolves;
        // not part of the test suite.
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
