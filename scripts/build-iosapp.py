#!/usr/bin/env python3
"""Build the iPhone app for the simulator and install it.

The engine and the renderer are the same sources the Mac builds; only the
shell in swift/Sources/iOSApp is different, because upstream's macOS app is
AppKit throughout and none of it transfers.
"""
import os, subprocess, sys, plistlib, shutil

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

# The phone has no fork/exec, so the transport is not optional here:
# without it the app builds and can reach nothing.
ios_env = os.environ.copy()
ios_env["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
run(["cargo", "build", "--release", "--features", "ssh",
     "--target", "aarch64-apple-ios-sim"], "cargo ios-sim", env=ios_env)

os.makedirs(APP, exist_ok=True)
files = swift_files("swift/Sources/iOSApp") + swift_files("swift/Sources/TakoCoreUI")
if not any(f.endswith("tako_core.swift") for f in files) and os.path.exists("target/bindings/tako_core.swift"):
    files.append("target/bindings/tako_core.swift")

headers_dir = os.path.abspath("target/bindings") if os.path.exists("target/bindings/tako_coreFFI.h") else os.path.abspath("TakoCore.xcframework/ios-arm64-simulator/Headers")

# TakoTerminalView renders with MetalTerminalRenderer, which asks the device
# for the process default library. This app is linked with `swiftc` directly,
# so the shared shaders are compiled for the simulator SDK here rather than by
# an Xcode build phase, and the result is bundled as default.metallib -- the
# name `MTLDevice.makeDefaultLibrary()` looks for.
metal_src = "swift/Sources/TakoCoreUI/Resources/TerminalShaders.metal"
metallib = os.path.join(BUILD, "default.metallib")
air = os.path.join(BUILD, "TerminalShaders.air")
run(["xcrun", "-sdk", "iphonesimulator", "metal",
     "-target", "air64-apple-ios17.0-simulator",
     "-c", metal_src, "-o", air], "compile metal shaders")
run(["xcrun", "-sdk", "iphonesimulator", "metallib", air, "-o", metallib],
    "link metallib")

run(["swiftc", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
     "-module-name", "TakoCore", "-Onone", "-parse-as-library",
     "-Xcc", "-I" + headers_dir,
     "-import-objc-header", "swift/Sources/iOSApp/Bridging-Header.h",
     "-o", os.path.join(APP, "TakoCore"),
     *files,
     "target/aarch64-apple-ios-sim/release/libtako_core.a",
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
