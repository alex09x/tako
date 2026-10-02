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
# Where the profile lives when it is not in the default (data-protection)
# keychain -- CI stores it in a file keychain of its own.
KEYCHAIN = os.environ.get("TAKO_NOTARY_KEYCHAIN")


def profile_args():
    args = ["--keychain-profile", PROFILE]
    if KEYCHAIN:
        args += ["--keychain", KEYCHAIN]
    return args


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
        ["xcrun", "notarytool", "history", *profile_args()],
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


def notarize(path, what, staple=None, resume=None):
    """Submit, wait, and fail loudly with Apple's reasons if it is rejected.
    Then staple the ticket to `staple` (default: `path`) -- a ZIP cannot take
    one, so for a ZIP it is the app inside."""
    step(f"notarizing {what} -- Apple decides this: minutes, and for a new team's first submissions hours")
    # A submission already sent (`resume`) is waited on again rather than
    # uploaded again.
    if resume:
        cmd = ["xcrun", "notarytool", "wait", resume, *profile_args(), "--timeout", "2h"]
    else:
        cmd = ["xcrun", "notarytool", "submit", path, *profile_args(), "--wait", "--timeout", "2h"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(r.stdout.strip())
    if "Timeout of" in r.stdout + r.stderr:
        # Not a refusal: Apple has not answered yet, and the submission goes on.
        sub = resume or next((l.split(":", 1)[1].strip() for l in r.stdout.splitlines()
                              if l.strip().startswith("id:")), "")
        # Each stage resumes with its own variable; the disk image's resume
        # goes on with the very file that was sent, never a rebuilt one.
        var = "TAKO_NOTARY_SUBMISSION" if what == "the app" else "TAKO_NOTARY_DMG_SUBMISSION"
        sys.exit(f"Apple has not finished checking {what} yet -- nothing was refused.\n"
                 f"Wait for it and go on with:  {var}={sub} python3 scripts/release-macapp.py")
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
                            *profile_args()])
        print(r.stderr[-4000:])
        sys.exit(f"notarization refused for {what}")
    target = staple or path
    run(["xcrun", "stapler", "staple", target], f"staple {what}")
    run(["xcrun", "stapler", "validate", target], f"validate {what}")


def main():
    preflight()
    version, build = version_of(APP)
    print(f"    Tako {version} ({build})")

    # Notarization takes an archive, not a bundle. ditto is the one that
    # preserves the signature; zip(1) mangles symlinks inside frameworks.
    zip_path = os.path.join(BUILD, f"Tako-{version}.zip")
    dmg = os.path.join(BUILD, f"Tako-{version}.dmg")
    dmg_resume = os.environ.get("TAKO_NOTARY_DMG_SUBMISSION")
    if dmg_resume:
        # The app is already stapled and archived, the image built and sent:
        # only Apple's answer for it and the checks after it are left.
        for f in (dmg, zip_path):
            if not os.path.exists(f):
                sys.exit(f"no {f} -- the disk image's submission belongs to an earlier build; run without TAKO_NOTARY_DMG_SUBMISSION")
        notarize(dmg, "the disk image", resume=dmg_resume)
        finish(dmg, zip_path)
        return
    step("archiving the app for submission")
    run(["ditto", "-c", "-k", "--keepParent", APP, zip_path], "archive app")

    # Apple notarizes the ZIP but staples the app in it; the ZIP that ships
    # is made again from the stapled app, so it carries the ticket too.
    notarize(zip_path, "the app", staple=APP, resume=os.environ.get("TAKO_NOTARY_SUBMISSION"))
    os.remove(zip_path)
    step("archiving the stapled app for release")
    run(["ditto", "-c", "-k", "--keepParent", APP, zip_path], "archive stapled app")

    # The disk image is built from the now-stapled app, so the copy a user
    # drags to Applications carries Apple's approval with it.
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
    finish(dmg, zip_path)


def finish(dmg, zip_path):
    step("verifying the way Gatekeeper will")
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", APP], "verify signatures")
    run(["spctl", "-a", "-vvv", "-t", "exec", APP], "assess app")
    run(["xcrun", "stapler", "validate", dmg], "validate dmg")

    size = os.path.getsize(dmg) / (1024 * 1024)
    print(f"\n{dmg} -- {size:.1f} MB, notarized and stapled")
    print(f"{zip_path} -- the stapled app, for the release and the updater")
    print("This opens on a Mac that has never seen it, with no right-click "
          "and no Gatekeeper prompt.")


if __name__ == "__main__":
    main()
