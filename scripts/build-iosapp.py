#!/usr/bin/env python3
# tako — iOS simulator app assembly
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

"""Build the iPhone app for the simulator and install it.

The engine and the renderer are the same tako-core release the Mac builds
(scripts/tako_core.py); only the shell in swift/Sources/iOSApp is different,
because upstream's macOS app is AppKit throughout and none of it transfers.
"""
import os, subprocess, sys, plistlib, shutil
import tako_core

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
BUILD = "target/iosapp"
APP = os.path.join(BUILD, "TakoCore.app")
BUNDLE_ID = "com.tako-core.ios"


def run(cmd, what, env=None):
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        print(r.stdout[-3000:]); print(r.stderr[-8000:])
        sys.exit(f"failed: {what}")
    return r


def swift_files(root):
    out = []
    for d, _, fs in os.walk(root):
        out += [os.path.join(d, f) for f in sorted(fs) if f.endswith(".swift")]
    return out


sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                     capture_output=True, text=True).stdout.strip()
os.makedirs(BUILD, exist_ok=True)

# The engine (with its SSH transport: the phone has no fork/exec) and
# TakoCoreUI, from the pinned tako-core release.
try:
    tako_core.resolve()
    CORE = tako_core.locate()
except tako_core.Unresolved as e:
    sys.exit(f"failed: tako-core: {e}")
CORE_SLICE = CORE["slices"]["ios-arm64-simulator"]
TARGET = ["-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk]
CORE_HEADERS = ["-Xcc", "-I" + CORE_SLICE["headers"], "-I", CORE_SLICE["headers"]]

os.makedirs(APP, exist_ok=True)
run(["swiftc", *TARGET, "-emit-module", "-emit-library", "-static", "-parse-as-library",
     "-module-name", "TakoCoreUI", "-Onone", *CORE_HEADERS,
     "-emit-module-path", os.path.join(BUILD, "TakoCoreUI.swiftmodule"),
     "-o", os.path.join(BUILD, "libTakoCoreUI.a"), *tako_core.ui_swift_files(CORE)], "module TakoCoreUI")
files = swift_files("swift/Sources/iOSApp")

# TakoTerminalView renders with MetalTerminalRenderer, which asks the device
# for the process default library. This app is linked with `swiftc` directly,
# so the shared shaders are compiled for the simulator SDK here rather than by
# an Xcode build phase, and the result is bundled as default.metallib -- the
# name `MTLDevice.makeDefaultLibrary()` looks for.
metal_src = CORE["shader"]
metallib = os.path.join(BUILD, "default.metallib")
air = os.path.join(BUILD, "TerminalShaders.air")
run(["xcrun", "-sdk", "iphonesimulator", "metal",
     "-target", "air64-apple-ios17.0-simulator",
     "-c", metal_src, "-o", air], "compile metal shaders")
run(["xcrun", "-sdk", "iphonesimulator", "metallib", air, "-o", metallib],
    "link metallib")

run(["swiftc", *TARGET,
     "-module-name", "TakoCore", "-Onone", "-parse-as-library",
     *CORE_HEADERS, "-I", BUILD,
     "-o", os.path.join(APP, "TakoCore"),
     *files,
     os.path.join(BUILD, "libTakoCoreUI.a"),
     CORE_SLICE["library"],
     # Everything TakoCoreUI and the app shell import: the view layer, the
     # Metal renderer with its CAMetalLayer, the CoreText glyph atlas and the
     # ImageIO decode path behind the Kitty image cache.
     "-framework", "UIKit", "-framework", "SwiftUI", "-framework", "CoreText",
     "-framework", "CoreGraphics", "-framework", "Foundation",
     "-framework", "ImageIO", "-framework", "Metal", "-framework", "QuartzCore",
     ], "link ios app")

# An iOS bundle keeps its resources at the top level, not in Contents.
shutil.copy(metallib, os.path.join(APP, "default.metallib"))

with open(os.path.join(APP, "Info.plist"), "wb") as f:
    plistlib.dump({
        "CFBundleName": "TakoCore",
        "CFBundleDisplayName": "TakoCore",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleExecutable": "TakoCore",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": "17.0",
        "UILaunchScreen": {},
        "UIRequiredDeviceCapabilities": ["arm64"],
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
    }, f)

print(f"built {APP}")
