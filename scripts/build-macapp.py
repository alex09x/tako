#!/usr/bin/env python3
"""Build the macOS app: upstream's Swift app layer over the Rust core.

Produces Tako.app. The Rust staticlib, the Objective-C helpers and
all of upstream's Swift link into one binary -- nothing loads at runtime
that isn't in the bundle.
"""
import os, subprocess, sys, shutil, plistlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
BUILD = "target/macapp"
APP = os.path.join(BUILD, "Tako.app")
# Shown in the About window. The full licence, with every copyright
# notice it requires, ships in the bundle as Contents/Resources/LICENSE.
COPYRIGHT = "Tako. MIT licensed."


def git(*args, default=""):
    """A git query whose failure is not fatal -- a source tarball has no .git."""
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else default


# The version a user sees, and the build number Apple orders updates by.
#
# Both are derived rather than typed, so a release cannot ship claiming a
# version nobody bumped. TAKO_VERSION overrides the marketing string for a
# tagged build; otherwise the nearest tag names it, and an untagged tree is
# honestly 0.0.0. The build number is the commit count, which only ever
# increases -- Apple rejects an update whose CFBundleVersion did not.
VERSION = os.environ.get("TAKO_VERSION") or (
    git("describe", "--tags", "--abbrev=0", default="").lstrip("v") or "0.0.0")
BUILD_NUMBER = os.environ.get("TAKO_BUILD_NUMBER") or git(
    "rev-list", "--count", "HEAD", default="1")

def run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-4000:])
        print(r.stderr[-8000:])
        sys.exit(f"failed: {what}")
    return r

def swift_files(root):
    out = []
    for d, _, fs in os.walk(root):
        out += [os.path.join(d, f) for f in sorted(fs) if f.endswith(".swift")]
    return out

sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                     capture_output=True, text=True).stdout.strip()
# macOS 14: TakoTerminalNSView drives its redraws from CADisplayLink,
# which does not exist before 14. The app cannot both ship that surface
# and claim to run on 13.
BASE = ["-target", "arm64-apple-macos14.0", "-sdk", sdk]
# Release builds optimise; local ones stay incremental, which is the
# difference between a minute and a few seconds.
RELEASE = os.environ.get("RELEASE") == "1"
OPT = ["-O", "-whole-module-optimization"] if RELEASE else [
    "-Onone", "-incremental", "-enable-batch-mode",
    "-output-file-map", "target/macapp/output-file-map.json",
    "-module-cache-path", "target/macapp/modulecache",
]


def stamp(paths):
    """Newest mtime across paths, for skipping unchanged build steps."""
    newest = 0.0
    for p in paths:
        if os.path.isfile(p):
            newest = max(newest, os.path.getmtime(p))
        else:
            for d, _, fs in os.walk(p):
                for f in fs:
                    newest = max(newest, os.path.getmtime(os.path.join(d, f)))
    return newest


def up_to_date(output, inputs):
    """True when `output` is newer than everything in `inputs`."""
    if RELEASE or not os.path.exists(output):
        return False
    return os.path.getmtime(output) >= stamp(inputs)

os.makedirs(BUILD, exist_ok=True)
run(["cargo", "build", "--release", "--features", "ssh"], "cargo build")

# The direct Swift build consumes generated UniFFI sources from target/bindings.
# Keep them tied to the Rust ABI instead of silently reusing a stale file after
# an FFI record or method changes.
bindings_swift = "target/bindings/tako_core.swift"
if not up_to_date(bindings_swift, ["src", "Cargo.toml", "Cargo.lock"]):
    os.makedirs("target/bindings", exist_ok=True)
    run([
        "cargo", "run", "--quiet", "--bin", "uniffi-bindgen",
        "--features", "uniffi-cli,ssh", "--", "generate",
        "--language", "swift", "--out-dir", "target/bindings",
        "target/release/libtako_core.dylib",
    ], "generate Swift bindings")
    run([
        "sed", "-i", "", "-E", "s/[[:space:]]+$//",
        bindings_swift, "target/bindings/tako_coreFFI.h",
    ], "normalize generated Swift bindings")

# This app is linked with `swiftc` directly, so compile the Metal resource
# explicitly rather than relying on SwiftPM's automatic resource handling.
# The result is named default.metallib and shipped in Resources, because that
# is the one library `MTLDevice.makeDefaultLibrary(bundle:)` -- what
# MetalTerminalRenderer asks for -- will load.
metal_src = "swift/Sources/TakoCoreUI/Resources/TerminalShaders.metal"
if not up_to_date(os.path.join(BUILD, "default.metallib"), [metal_src]):
    air = os.path.join(BUILD, "TerminalShaders.air")
    run(["xcrun", "-sdk", "macosx", "metal", "-c", metal_src, "-o", air], "compile metal shader")
    run(["xcrun", "-sdk", "macosx", "metallib", air, "-o", os.path.join(BUILD, "default.metallib")], "link metallib")

# Upstream imports this as a module, so it is built first.
for name, root in [("TakoKit", "swift/Sources/TakoKit")]:
    run(["swiftc", "-emit-module", "-emit-library", "-static",
         "-module-name", name,
         "-emit-module-path", os.path.join(BUILD, name + ".swiftmodule"),
         "-o", os.path.join(BUILD, "lib" + name + ".a"),
         *BASE, *swift_files(root)], f"module {name}")

if not up_to_date(os.path.join(BUILD, "TakoObjC.o"), ["swift/Sources/TakoObjC"]):
  run(["clang", "-c", "-fobjc-arc", *BASE[:2], "-isysroot", sdk,
     "-o", os.path.join(BUILD, "TakoObjC.o"),
     "swift/Sources/TakoObjC/TakoObjC.m"], "objc helpers")

files = [f for f in swift_files("swift/Sources/TakoApp") if "/App/iOS/" not in f] \
        + [f for f in swift_files("swift/Sources/TakoCoreUI") if "/Generated/" not in f] \
        + ["target/bindings/tako_core.swift"]

# The incremental build needs an object file named for every source. It is
# regenerated each run, because a stale map sends new files to a temporary
# directory the linker then cannot find.
if not RELEASE:
    import json
    os.makedirs(os.path.join(BUILD, "obj"), exist_ok=True)
    file_map = {"": {"swift-dependencies": f"{BUILD}/obj/master.swiftdeps"}}
    seen = {}
    for f in files:
        base = os.path.splitext(os.path.basename(f))[0]
        n = seen.get(base, 0)
        seen[base] = n + 1
        key = base if n == 0 else f"{base}-{n}"
        file_map[f] = {"object": f"{BUILD}/obj/{key}.o",
                       "swift-dependencies": f"{BUILD}/obj/{key}.swiftdeps"}
    with open(os.path.join(BUILD, "output-file-map.json"), "w") as fh:
        json.dump(file_map, fh, indent=1)

binary = os.path.join(BUILD, "Tako")
run(["swiftc", "-module-name", "Tako", *BASE, *OPT,
     "-import-objc-header", "swift/Sources/TakoApp/_TakoShim/Tako-Bridging-Header.h",
     "-Xcc", "-I" + os.path.abspath("target/bindings"),
     "-Xcc", "-I" + os.path.abspath("swift/Sources/TakoObjC"),
     "-I", BUILD,
     "-o", binary,
     *files,
     os.path.join(BUILD, "TakoObjC.o"),
     os.path.join(BUILD, "libTakoKit.a"),
     "target/release/libtako_core.a",
     "-framework", "Cocoa", "-framework", "SwiftUI",
     "-framework", "UserNotifications", "-framework", "CoreText",
     "-framework", "UniformTypeIdentifiers", "-framework", "Carbon",
     "-framework", "OSAKit", "-framework", "ServiceManagement",
     ], "link app")

# Bundle it, because LaunchServices -- and therefore tabs, the dock icon and
# window restoration -- only work for a real .app.
if os.path.exists(APP):
    shutil.rmtree(APP)
macos = os.path.join(APP, "Contents", "MacOS")
res = os.path.join(APP, "Contents", "Resources")
os.makedirs(macos); os.makedirs(res)
shutil.copy(binary, os.path.join(macos, "Tako"))
# Upstream's interface files: the menu bar, the window styles, and the
# scripting definition. Their Swift loads these by name, so they ship
# compiled into Resources exactly as its Xcode target does.
for d, _, fs in os.walk("swift/Sources/TakoApp"):
    for f in fs:
        if f.endswith(".xib"):
            run(["ibtool", "--compile",
                 os.path.join(res, f[:-4] + ".nib"), os.path.join(d, f)],
                f"compile {f}")
shutil.copy("swift/Resources/Tako.sdef", os.path.join(res, "Tako.sdef"))
# MIT requires the copyright notices to travel with every copy.
shutil.copy("LICENSE", os.path.join(res, "LICENSE"))
shutil.copy(os.path.join(BUILD, "default.metallib"), os.path.join(res, "default.metallib"))
# The brand mark, rendered by brand/make-icons.swift.
shutil.copy("brand/out/TakoCore.icns", os.path.join(res, "AppIcon.icns"))
shutil.copytree("swift/Resources/themes", os.path.join(res, "themes"))
# Upstream bundles its default font rather than relying on what happens to
# be installed. macOS registers everything under ATSApplicationFontsPath.
shutil.copytree("swift/Resources/fonts", os.path.join(res, "fonts"))
# Upstream's shell integration. Without it the shell never reports its
# directory or its prompt boundaries, so window titles stay empty and
# prompt jumping does nothing.
shutil.copytree("swift/Resources/shell-integration",
                os.path.join(res, "tako", "shell-integration"))
run(["xcrun", "actool", "swift/Resources/Assets.xcassets",
     "--compile", res, "--platform", "macosx",
     "--minimum-deployment-target", "14.0",
     "--app-icon", "AppIcon",
     "--output-partial-info-plist", os.path.join(BUILD, "assets.plist")],
    "compile assets")

with open(os.path.join(APP, "Contents", "Info.plist"), "wb") as f:
    plistlib.dump({
        "CFBundleName": "Tako",
        "CFBundleDisplayName": "Tako",
        "CFBundleIdentifier": "com.tako-core.terminal",
        "CFBundleExecutable": "Tako",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD_NUMBER,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        # NSApplicationMain finds the app delegate through this nib.
        "NSMainNibFile": "MainMenu",
        "ATSApplicationFontsPath": "fonts",
        "CFBundleIconFile": "AppIcon.icns",
        "NSAppleScriptEnabled": True,
        "OSAScriptingDefinition": "Tako.sdef",
        "NSHumanReadableCopyright": COPYRIGHT,
    }, f)


# Signing.
#
# Two identities, and which one you get is a property of the machine rather
# than a flag: a build here signs ad-hoc, and a build on a machine holding a
# Developer ID Application certificate signs with it and turns on the
# hardened runtime, which notarization requires. Set TAKO_CODESIGN_IDENTITY
# to name one explicitly, or to "-" to force an ad-hoc build even where a
# real certificate exists.
#
# No entitlements file. The hardened runtime denies things this app does not
# do: everything is statically linked so no library is loaded at runtime,
# there is no JIT, no DYLD_* variable reaches the shell integration, and the
# children it forks immediately exec system binaries that carry their own
# signatures. An entitlement here would be a request for a permission
# nothing asks for, and each one is a thing notarization has to forgive.
def codesign_identity():
    forced = os.environ.get("TAKO_CODESIGN_IDENTITY")
    if forced:
        return forced
    r = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                       capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if "Developer ID Application" in line:
            # ') "Developer ID Application: Name (TEAMID)"' -> the quoted name.
            return line.split('"')[1]
    return "-"


identity = codesign_identity()
adhoc = identity == "-"
cmd = ["codesign", "--force", "--sign", identity]
if not adhoc:
    # --timestamp needs Apple's server and is what makes the signature
    # outlive the certificate. --options runtime is the hardened runtime.
    cmd += ["--options", "runtime", "--timestamp"]
run(cmd + [APP], "sign app")

print(f"built {APP} {VERSION} ({BUILD_NUMBER})")
if adhoc:
    print("signed ad-hoc -- runs here, refused on any other Mac. "
          "scripts/release-macapp.py explains what a shippable build needs.")
else:
    print(f"signed with {identity}")
