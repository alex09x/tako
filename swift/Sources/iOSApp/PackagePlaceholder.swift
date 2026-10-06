/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// The one file in this directory that SPM compiles.
///
/// The app is built against the iOS SDK by `ios/project.yml`, not by this
/// package, which is macOS-only. The target exists so SPM does not treat
/// Sources/iOSApp as an orphaned implicit target, and `Package.swift` points
/// its `sources` here -- so adding a UIKit file next door needs no
/// corresponding edit to an exclude list, which is how the list went stale
/// and broke `swift build` before.
enum IOSAppPackagePlaceholder {}
