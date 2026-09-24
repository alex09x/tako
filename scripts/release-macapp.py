#!/usr/bin/env python3
"""Turn a signed Tako.app into something a stranger can download and open.

Signing is not enough. macOS refuses a downloaded app that Apple has never
seen, whoever signed it, so a release is: build with a Developer ID
certificate, send the app to Apple to be notarized, staple Apple's answer
into the bundle, wrap it in a disk image, and notarize and staple that too.
Both get stapled because both get distributed -- someone will copy the app
out of the image and hand it on, and a stapled app is one that opens with no
network at all.

What this needs before it will run:

  1. A Developer ID Application certificate in the login keychain. Xcode ->
     Settings -> Accounts -> the Apple ID -> Manage Certificates -> "+" ->
     Developer ID Application. Only a team's Account Holder may create one,
     and only a paid Apple Developer Program membership has the option.

  2. Notarization credentials stored in the keychain, once:

         xcrun notarytool store-credentials tako \
             --apple-id you@example.com \
             --team-id TEAMID \
             --password APP_SPECIFIC_PASSWORD

     The app-specific password comes from appleid.apple.com -> Sign-In and
     Security -> App-Specific Passwords. It is not your Apple ID password,
     and once stored it lives in the keychain rather than in this repository
     or your shell history. Override the profile name with
     TAKO_NOTARY_PROFILE.

Then: python3 scripts/release-macapp.py
"""
import os, subprocess, sys, plistlib, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
BUILD = "target/macapp"
APP = os.path.join(BUILD, "Tako.app")
PROFILE = os.environ.get("TAKO_NOTARY_PROFILE", "tako")


def run(cmd, what, quiet=False):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-4000:])
        print(r.stderr[-8000:])
        sys.exit(f"failed: {what}")
    if not quiet and r.stdout.strip():
        print(r.stdout.strip())
    return r


def step(msg):
    print(f"==> {msg}")


# Refuse early and say what to fix, rather than failing deep inside
# notarytool with Apple's own wording.
def preflight():
    if not os.path.isdir(APP):
        sys.exit(f"no {APP} -- run scripts/build-macapp.py first")

    r = subprocess.run(["codesign", "-dv", "--verbose=4", APP],
                       capture_output=True, text=True)
    info = r.stderr
    if "Authority=Developer ID Application" not in info:
        sys.exit(
            f"{APP} is not signed with a Developer ID certificate.\n"
            "Apple will not notarize an ad-hoc or development signature.\n"
            "Create the certificate (see this file's docstring), then\n"
            "rebuild: python3 scripts/build-macapp.py")
    if "flags=0x10000(runtime)" not in info:
        sys.exit(f"{APP} is signed without the hardened runtime; rebuild it")

    r = subprocess.run(
        ["xcrun", "notarytool", "history", "--keychain-profile", PROFILE],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(
            f"no notarization credentials under the profile '{PROFILE}'.\n"
            "Store them once with xcrun notarytool store-credentials --\n"
            "see this file's docstring for the exact command.")

    # The signing certificate names the team; the identity line reads
    # "Developer ID Application: Name (TEAMID)".
    for line in info.splitlines():
        if line.startswith("Authority=Developer ID Application"):
            print(f"    {line}")
            break
    return info


def version_of(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        p = plistlib.load(f)
    return p["CFBundleShortVersionString"], p["CFBundleVersion"]


def notarize(path, what):
    """Submit, wait, and fail loudly with Apple's reasons if it is rejected."""
    step(f"notarizing {what} -- Apple decides this, so it takes minutes")
    r = subprocess.run(
        ["xcrun", "notarytool", "submit", path,
         "--keychain-profile", PROFILE, "--wait", "--timeout", "30m"],
        capture_output=True, text=True)
    print(r.stdout.strip())
    if r.returncode != 0 or "status: Accepted" not in r.stdout:
        # The submission id is the only way to read why it was refused.
        sub = ""
        for line in r.stdout.splitlines():
            if line.strip().startswith("id:"):
                sub = line.split(":", 1)[1].strip()
                break
        if sub:
            print("--- Apple's reasons ---")
            subprocess.run(["xcrun", "notarytool", "log", sub,
                            "--keychain-profile", PROFILE])
        print(r.stderr[-4000:])
        sys.exit(f"notarization refused for {what}")
    run(["xcrun", "stapler", "staple", path], f"staple {what}")


def main():
    preflight()
    version, build = version_of(APP)
    print(f"    Tako {version} ({build})")

    # Notarization takes an archive, not a bundle. ditto is the one that
    # preserves the signature; zip(1) mangles symlinks inside frameworks.
    zip_path = os.path.join(BUILD, f"Tako-{version}.zip")
    step("archiving the app for submission")
    run(["ditto", "-c", "-k", "--keepParent", APP, zip_path], "archive app")

    notarize(zip_path, "the app")
    os.remove(zip_path)

    # The disk image is built from the now-stapled app, so the copy a user
    # drags to Applications carries Apple's approval with it.
    dmg = os.path.join(BUILD, f"Tako-{version}.dmg")
    staging = os.path.join(BUILD, "dmg")
    if os.path.exists(dmg):
        os.remove(dmg)
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)
    step("building the disk image")
    run(["ditto", APP, os.path.join(staging, "Tako.app")], "stage app")
    # The Applications symlink is the whole install instruction: a window
    # with the app on one side and where it goes on the other.
    os.symlink("/Applications", os.path.join(staging, "Applications"))
    run(["hdiutil", "create", "-volname", f"Tako {version}",
         "-srcfolder", staging, "-ov", "-format", "UDZO", dmg],
        "create dmg", quiet=True)
    shutil.rmtree(staging)

    # A signed image is one Gatekeeper can attribute before it is opened.
    identity = None
    r = subprocess.run(["codesign", "-dv", "--verbose=4", APP],
                       capture_output=True, text=True)
    for line in r.stderr.splitlines():
        if line.startswith("Authority=Developer ID Application"):
            identity = line.split("=", 1)[1]
            break
    run(["codesign", "--force", "--sign", identity, "--timestamp", dmg],
        "sign dmg")

    notarize(dmg, "the disk image")

    step("verifying the way Gatekeeper will")
    run(["spctl", "-a", "-vvv", "-t", "install", APP], "assess app")
    run(["xcrun", "stapler", "validate", dmg], "validate dmg")

    size = os.path.getsize(dmg) / (1024 * 1024)
    print(f"\n{dmg} -- {size:.1f} MB, notarized and stapled")
    print("This opens on a Mac that has never seen it, with no right-click "
          "and no Gatekeeper prompt.")


if __name__ == "__main__":
    main()
