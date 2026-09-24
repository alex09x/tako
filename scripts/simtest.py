#!/usr/bin/env python3
"""Drive the iPhone app against local ssh servers in a simulator.

The unit tests say the engine parses what it is given, and the Rust
transport tests say a session can be opened. Neither says what a person
holding the phone sees, because between them sit the view, the Metal
renderer, the key row and the delivery pump -- and every bug found in this
app so far has been in that gap.

So this runs the shipped app, against a real sshd on this machine, and looks
at the result twice: the buffer the engine holds, and the pixels on screen.
A simulator rather than the phone because it shares the Mac's network and
filesystem, and because a locked phone cannot be launched into.

    ./scripts/simtest.py                 # every scenario
    ./scripts/simtest.py scroll colors   # only these
    ./scripts/simtest.py --keep          # leave the servers up afterwards

Results land in target/simtest/<scenario>/{dump.txt,screen.png}.
"""
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

OUT = "target/simtest"
FIXTURE = os.path.join(OUT, "sshd")
BUNDLE_ID = "dev.prod.takocore"
DEVICE = os.environ.get("TAKO_SIM_DEVICE", "iPhone 17 Pro")
PORT = int(os.environ.get("TAKO_SIM_SSH_PORT", "2224"))
# The byte-naming and MFA servers, past the three OpenSSH fixtures.
ECHO_PORT = PORT + len(["ed25519", "rsa", "ecdsa"])
MFA_PORT = ECHO_PORT + 1
FAULT_PROXY_PORT = ECHO_PORT + 2
FAULT_CONTROL_PORT = ECHO_PORT + 3
USER = os.environ["USER"]

# Host key types the server offers. The point is not that russh can do the
# maths -- the Rust tests cover that -- but that the app's trust-on-first-use
# prompt, which is the only thing standing between a password and a stranger,
# reaches the same verdict for each of them.
HOST_KEY_TYPES = ["ed25519", "rsa", "ecdsa"]


def run(cmd, check=True, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if check and r.returncode != 0:
        sys.exit(f"failed: {' '.join(cmd)}\n{r.stdout[-2000:]}\n{r.stderr[-4000:]}")
    return r


# ── the servers ──────────────────────────────────────────────────────────────
#
# Two kinds, because neither can do the other's job.
#
# OpenSSH is what a person actually connects to, so the behaviour scenarios
# run against it: a real login, a real shell, real colours. But it validates
# passwords through PAM against real accounts, so it cannot accept a made-up
# one, and its shell echoes what you type instead of saying what it received.
#
# examples/test_sshd.rs answers both: a password of our choosing, multi-round
# keyboard-interactive authentication, and a shell that names the bytes it is
# given -- which is the only way to see that ⌃ then c sent 0x03 rather than the
# letter c.

CLIENT_KEY_TYPES = ["ed25519", "rsa", "ecdsa"]
PASSWORD = "correct horse battery staple"
KEY_PASSPHRASE = "ocean-glass-7"
MFA_CODE = "246810"
MFA_DEVICE = "Simulator"


def openssh_config(name, port, host_key_types):
    """One sshd offering exactly the host key types named."""
    here = os.path.abspath(os.path.join(FIXTURE, name))
    os.makedirs(here, exist_ok=True)
    for kind in host_key_types:
        path = os.path.join(here, f"host_{kind}")
        if not os.path.exists(path):
            run(["ssh-keygen", "-q", "-t", kind, "-N", "", "-f", path],
                stdin=subprocess.DEVNULL)
    keys = "\n".join(f"HostKey {here}/host_{k}" for k in host_key_types)
    config = f"""
Port {port}
ListenAddress 127.0.0.1
{keys}
AuthorizedKeysFile {os.path.abspath(FIXTURE)}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PidFile {here}/sshd.pid
LogLevel ERROR
"""
    cfg = os.path.join(here, "sshd_config")
    with open(cfg, "w") as f:
        f.write(config.lstrip())
    return cfg


def refuse_if_taken(ports):
    """Someone else's server on our port is worse than no server at all.

    A stray test_sshd from an earlier run answers on the same port with a
    different key and a different password, so every scenario fails for a
    reason that has nothing to do with the app -- which is a morning lost.
    """
    taken = [p for p in ports
             if subprocess.run(["nc", "-z", "127.0.0.1", str(p)],
                               capture_output=True).returncode == 0]
    if taken:
        sys.exit(f"ports already in use: {taken} — something is still "
                 f"listening from an earlier run")


def wait_for_port(port, what):
    for _ in range(100):
        if subprocess.run(["nc", "-z", "127.0.0.1", str(port)],
                          capture_output=True).returncode == 0:
            return
        time.sleep(0.1)
    sys.exit(f"{what} did not come up on {port}")


def make_servers():
    """Every server the scenarios need, on the loopback.

    Bound to 127.0.0.1 on purpose: these accept keys sitting in a
    world-readable build directory and a password written in this file, so
    they have no business being reachable from the network.
    """
    if os.path.isdir(FIXTURE):
        stop_servers()
        shutil.rmtree(FIXTURE)
    os.makedirs(FIXTURE)
    refuse_if_taken(
        [PORT + i for i in range(len(HOST_KEY_TYPES))]
        + [ECHO_PORT, MFA_PORT, FAULT_PROXY_PORT, FAULT_CONTROL_PORT]
    )

    # A client key of each type, all authorized, so the auth matrix is a
    # choice of which one the app is handed rather than a different server.
    pubkeys = []
    for kind in CLIENT_KEY_TYPES:
        path = os.path.join(FIXTURE, f"client_{kind}")
        run(["ssh-keygen", "-q", "-t", kind, "-N", "", "-f", path],
            stdin=subprocess.DEVNULL)
        with open(path + ".pub") as f:
            pubkeys.append(f.read().strip())
    encrypted = os.path.join(FIXTURE, "client_encrypted-ed25519")
    run(["ssh-keygen", "-q", "-t", "ed25519", "-N", KEY_PASSPHRASE,
         "-f", encrypted], stdin=subprocess.DEVNULL)
    with open(encrypted + ".pub") as f:
        pubkeys.append(f.read().strip())
    with open(os.path.join(FIXTURE, "authorized_keys"), "w") as f:
        f.write("\n".join(pubkeys) + "\n")

    # One sshd per host key type: which type a server offers is not something
    # a client can ask for, so the only way to test all three against the
    # app's trust-on-first-use prompt is three servers.
    for i, kind in enumerate(HOST_KEY_TYPES):
        cfg = openssh_config(kind, PORT + i, [kind])
        run(["/usr/sbin/sshd", "-f", cfg,
             "-E", os.path.join(os.path.dirname(cfg), "sshd.log")])
        wait_for_port(PORT + i, f"sshd/{kind}")

    run(["cargo", "build", "--features", "ssh", "--example", "test_sshd"])
    log = open(os.path.join(FIXTURE, "test_sshd.log"), "w")
    proc = subprocess.Popen(
        ["target/debug/examples/test_sshd",
         "--port", str(ECHO_PORT),
         "--password", PASSWORD,
         "--authorized-keys", os.path.join(FIXTURE, "authorized_keys")],
        stdout=log, stderr=subprocess.STDOUT,
        # `--keep` outlives the launching terminal command. OpenSSH
        # daemonizes itself; these fixture processes do not, so without a
        # separate session the shell's SIGHUP silently removes them.
        start_new_session=True)
    with open(os.path.join(FIXTURE, "test_sshd.pid"), "w") as f:
        f.write(str(proc.pid))
    wait_for_port(ECHO_PORT, "test_sshd")

    # A separate endpoint requires password + two keyboard-interactive
    # rounds. This exercises the asynchronous challenge UI against a real SSH
    # transport instead of faking prompts inside the app.
    mfa_log = open(os.path.join(FIXTURE, "test_sshd_mfa.log"), "w")
    mfa = subprocess.Popen(
        ["target/debug/examples/test_sshd",
         "--port", str(MFA_PORT),
         "--mfa-password", PASSWORD,
         "--mfa-code", MFA_CODE,
         "--mfa-device", MFA_DEVICE],
        stdout=mfa_log, stderr=subprocess.STDOUT,
        start_new_session=True)
    with open(os.path.join(FIXTURE, "test_sshd_mfa.pid"), "w") as f:
        f.write(str(mfa.pid))
    wait_for_port(MFA_PORT, "test_sshd MFA")

    # Keep the OpenSSH listener alive while giving the UI walkthrough one
    # endpoint whose established TCP stream can be cut from underneath it.
    # The proxy itself stays up, so reconnect proves a new SSH handshake all
    # the way through rather than merely repainting a disconnected screen.
    proxy_log = open(os.path.join(FIXTURE, "fault_proxy.log"), "w")
    proxy = subprocess.Popen(
        [sys.executable, "scripts/tcp_fault_proxy.py",
         "--listen-port", str(FAULT_PROXY_PORT),
         "--control-port", str(FAULT_CONTROL_PORT),
         "--target-port", str(PORT)],
        stdout=proxy_log, stderr=subprocess.STDOUT,
        start_new_session=True)
    with open(os.path.join(FIXTURE, "fault_proxy.pid"), "w") as f:
        f.write(str(proxy.pid))
    wait_for_port(FAULT_PROXY_PORT, "fault proxy")
    wait_for_port(FAULT_CONTROL_PORT, "fault proxy control")


def stop_servers():
    for pid_file in (
        "sshd.pid", "test_sshd.pid", "test_sshd_mfa.pid", "fault_proxy.pid"
    ):
        for root, _, files in os.walk(FIXTURE):
            if pid_file in files:
                with open(os.path.join(root, pid_file)) as f:
                    subprocess.run(["kill", f.read().strip()], capture_output=True)


# ── the app ──────────────────────────────────────────────────────────────────

def build_and_install():
    run(["xcodegen", "-s", "ios/project.yml", "-p", "ios", "--quiet"])
    run(["xcodebuild", "-project", "ios/TakoCore.xcodeproj", "-scheme", "TakoCore",
         "-configuration", "Debug",
         "-destination", f"platform=iOS Simulator,name={DEVICE}",
         "-derivedDataPath", "target/ios-sim-derived", "build"])

    # Start from a freshly booted device, not whatever an earlier run (or a
    # person at the Simulator) left behind. `simctl boot` on a device that is
    # already up does nothing, so its runtime state lived as long as the
    # machine: one such device ended up refusing every rotation -- Safari's
    # as much as this app's -- until it was restarted, and the walkthrough's
    # portrait/landscape steps failed on it. That state is in memory, not in
    # the device's data, so a restart clears it and keeps everything else.
    subprocess.run(["xcrun", "simctl", "shutdown", DEVICE], capture_output=True)
    subprocess.run(["xcrun", "simctl", "boot", DEVICE], capture_output=True)
    run(["xcrun", "simctl", "bootstatus", DEVICE, "-b"])
    run(["xcrun", "simctl", "install", DEVICE,
         "target/ios-sim-derived/Build/Products/Debug-iphonesimulator/TakoCore.app"])


def container():
    r = run(["xcrun", "simctl", "get_app_container", DEVICE, BUNDLE_ID, "data"])
    return r.stdout.strip()


# ── scenarios ────────────────────────────────────────────────────────────────
#
# `send` is the -takoSend script: \n newline, \xNN a raw byte, \p a pause
# between steps, and a step starting `@` a key-row press. `expect` is what must
# appear in the buffer the engine holds; `reject` what must not.
#
# `key` picks which client key the app is handed, `password` uses password
# auth instead, and `port` picks the server -- PORT+n is the sshd offering
# HOST_KEY_TYPES[n], ECHO_PORT the one that names the bytes it receives.

BEHAVIOUR = [
    {
        "name": "hello",
        "why": "a session opens, a command runs, its output is parsed",
        # Deliberately plain: the login shell on the far end is whatever the
        # account has, and a scenario that fails because fish is not bash
        # tells you nothing about the terminal.
        "send": r"uname -s; echo TAKO-OK\n",
        "expect": ["Darwin", "TAKO-OK"],
    },
    {
        "name": "scroll",
        "why": "output taller than the screen leaves the tail visible, "
               "and the top of it in scrollback",
        "send": r"seq 1 300\n",
        "expect": ["300", "299"],
    },
    {
        "name": "colors",
        "why": "SGR reaches the renderer: 16 colours, 256, and true colour",
        "send": r"printf '\\033[31mRED\\033[0m \\033[38;5;208mORANGE\\033[0m "
                r"\\033[38;2;0;255;128mTRUE\\033[0m\\n'\n",
        "expect": ["RED", "ORANGE", "TRUE"],
    },
    {
        "name": "unicode",
        "why": "wide glyphs and combining marks do not smear the grid",
        # Checked against the buffer, not the screenshot, because the
        # simulator runtime does not hand AppleColorEmoji to a third-party
        # process -- CoreText says so itself and falls back to LastResort, so
        # emoji come out as tofu here and in colour on a phone. Combining
        # marks are the same story: composed on the device, drawn as two
        # glyphs here. Neither is a bug in the renderer, and a screenshot
        # comparison would report both forever.
        "send": "printf 'CJK[你好] EMOJI[\U0001f419] COMB[é]"
                "\\\\n'\\n",
        "expect": ["CJK[你好]", "EMOJI[\U0001f419]", "COMB[é]"],
    },
    {
        "name": "altscreen",
        "why": "a full-screen program takes the alternate screen and gives "
               "it back, leaving the scrollback it found",
        # The marker is split by an empty quote so the *typed* line never
        # contains it: the shell echoes what you type, and a reject check
        # that cannot tell drawn output from its own command is no check.
        "send": r"echo BEFORE-ALT\n\p"
                r"printf '\\033[?1049h\\033[HINSIDE''-ALT'\n\p"
                r"printf '\\033[?1049l'\n\pecho AFTER-ALT\n",
        "expect": ["BEFORE-ALT", "AFTER-ALT"],
        "reject": ["INSIDE-ALT"],
    },
    {
        "name": "ctrlc",
        "why": "^C reaches the far end and the prompt comes back without "
               "needing a return pressed after it",
        "send": r"tail -f /etc/hosts\n\p\x03\pecho AFTER-INTERRUPT\n",
        "expect": ["AFTER-INTERRUPT"],
    },
    {
        "name": "resize",
        "why": "the far end is told the size the app actually draws at, "
               "rather than being left at the size the PTY was opened with",
        # Against the byte-naming server because it reports the PTY request
        # and the window change as text. A real shell only reacts to them,
        # and a scenario that reads a reaction is a scenario that passes when
        # the size is wrong in a way the shell does not mind.
        "port": "echo",
        "send": r"\x0c",
        "expect": ["PTY xterm-256color 80x24", "RESIZE "],
        "reject": ["RESIZE 80x24"],
    },
]

# Which client key the app is given. Every one of these is listed in the same
# authorized_keys, so a failure is the app's handling of the key format and
# not the server's opinion of it.
AUTH = [
    {
        "name": f"auth-key-{kind}",
        "why": f"a {kind} private key gets in",
        "key": kind,
        "send": r"echo AUTH-OK\n",
        "expect": ["AUTH-OK"],
    }
    for kind in CLIENT_KEY_TYPES
] + [
    {
        "name": "auth-password",
        "why": "password auth gets in, against a server that checks one",
        "password": True,
        "port": "echo",
        "send": r"hello\n",
        "expect": ["AUTH password", "GOT ["],
    },
    {
        "name": "auth-wrong-password",
        "why": "a bad password fails, and says so, rather than hanging",
        "password": "wrong",
        "port": "echo",
        "send": "",
        "expect_status": "disconnected",
        "reject": ["AUTH "],
    },
    {
        "name": "auth-key-encrypted",
        "why": "a passphrase-protected OpenSSH key gets in through the shipped app",
        "key": "encrypted-ed25519",
        "passphrase": True,
        "send": r"echo ENCRYPTED-AUTH-OK\n",
        "expect": ["ENCRYPTED-AUTH-OK"],
    },
    {
        "name": "auth-key-wrong-passphrase",
        "why": "a wrong key passphrase fails clearly instead of hanging or authenticating",
        "key": "encrypted-ed25519",
        "passphrase": "wrong",
        "send": "",
        "expect_status": "disconnected",
        "reject": ["ENCRYPTED-AUTH-OK"],
    },
    {
        "name": "auth-key-missing-passphrase",
        "why": "an encrypted key without its passphrase is rejected promptly",
        "key": "encrypted-ed25519",
        "send": "",
        "expect_status": "disconnected",
        "reject": ["ENCRYPTED-AUTH-OK"],
    },
]

# Which host key type the server offers. The client cannot ask for one, so
# each is a server of its own -- and each is a first connection, so what is
# being tested is the trust-on-first-use path that stands between a password
# and a stranger.
HOST_KEYS = [
    {
        "name": f"hostkey-{kind}",
        "why": f"a server offering only a {kind} host key is trusted and reached",
        "port": index,
        "send": r"echo HOSTKEY-OK\n",
        "expect": ["HOSTKEY-OK"],
    }
    for index, kind in enumerate(HOST_KEY_TYPES)
]

# The keyboard. Against the byte-naming server, so what the row produced is
# on the screen in hex rather than inferred from a shell's reaction to it.
KEYBOARD = [
    {
        "name": "keys-typing",
        "why": "characters typed on the software keyboard arrive as themselves",
        "port": "echo",
        "send": r"ls -la\n",
        # The exact bytes, including the 0d: Return sends a carriage return,
        # not a line feed, and a check that let either through would not
        # notice the day that changed. The keyboard delivers one character
        # per keystroke, so each arrives in its own read.
        "expect": ['GOT [6c] "l"', 'GOT [73] "s"', 'GOT [20] " "',
                   'GOT [2d] "-"', 'GOT [61] "a"', 'GOT [0d]'],
    },
    {
        "name": "keys-control",
        "why": "the sticky ⌃ folds the next character into a control byte: "
               "⌃ then c is 0x03, not the letter c",
        "port": "echo",
        # `c` is deliberately a separate software-keyboard step. Keeping it
        # in `@ctrl+c` would send both through KeyRow and miss the real phone
        # regression where UIKit input bypassed the armed modifier.
        "send": r"@ctrl\pc",
        "expect": ["GOT [03]"],
        "reject": ['"c"'],
    },
    {
        "name": "keys-row",
        "why": "esc, tab and the arrows send what a terminal expects",
        "port": "echo",
        "send": r"@esc\p@tab\p@up\p@down",
        "expect": ["GOT [1b]", "GOT [09]", "GOT [1b 5b 41]", "GOT [1b 5b 42]"],
    },
    {
        "name": "keys-control-released",
        "why": "an armed ⌃ applies to one character and then lets go",
        "port": "echo",
        "send": r"@ctrl+c\pd",
        "expect": ["GOT [03]", '"d"'],
    },
]

# Regressions found only by looking at the visible phone screen. Keep these in
# the suite permanently: engine-only assertions can prove that text survives
# in scrollback while missing that a person can no longer see the login banner
# or first prompt after the software keyboard changes the terminal height.
REGRESSIONS = [
    {
        "name": "screen-shows-the-login",
        "why": "what the far end says before the first resize stays on screen",
        "port": "echo",
        "send": r"\x0c",
        "expect": ["── on screen ──"],
        "expect_on_screen": ["AUTH "],
    },
]

SCENARIOS = BEHAVIOUR + AUTH + HOST_KEYS + KEYBOARD + REGRESSIONS


def scenario(spec):
    name = spec["name"]
    out = os.path.join(OUT, name)
    os.makedirs(out, exist_ok=True)

    port = spec.get("port", 0)
    port = ECHO_PORT if port == "echo" else PORT + port

    data = container()
    docs = os.path.join(data, "Documents")
    os.makedirs(docs, exist_ok=True)
    # A fresh container per scenario would mean a reinstall per scenario; the
    # cheaper equivalent is to clear what the last one left, so a stale dump
    # can never be read as this run's result.
    for stale in ("dump.txt", "dump.png", "client_key", "password", "passphrase"):
        path = os.path.join(docs, stale)
        if os.path.exists(path):
            os.remove(path)

    args = ["-takoHost", f"127.0.0.1:{port}:{USER}", "-takoTrustHostKey"]
    if spec.get("password"):
        secret = PASSWORD if spec["password"] is True else spec["password"]
        with open(os.path.join(docs, "password"), "w") as f:
            f.write(secret)
        args += ["-takoPasswordPath", "password"]
    else:
        shutil.copy(os.path.join(FIXTURE, f"client_{spec.get('key', 'ed25519')}"),
                    os.path.join(docs, "client_key"))
        args += ["-takoKeyPath", "client_key"]
        if spec.get("passphrase"):
            secret = (KEY_PASSPHRASE if spec["passphrase"] is True
                      else spec["passphrase"])
            with open(os.path.join(docs, "passphrase"), "w") as f:
                f.write(secret)
            args += ["-takoPassphrasePath", "passphrase"]

    # Each scenario is a first connection, so the host key prompt is exercised
    # rather than skipped by one remembered from the last scenario.
    prefs = os.path.join(data, "Library/Preferences", f"{BUNDLE_ID}.plist")
    if os.path.exists(prefs):
        os.remove(prefs)

    steps = spec["send"].count(r"\p") + 1
    dump_at = 5 + steps * 2
    if spec["send"]:
        args += ["-takoSend", spec["send"]]
    args += ["-takoDump", str(dump_at)]

    subprocess.run(["xcrun", "simctl", "terminate", DEVICE, BUNDLE_ID],
                   capture_output=True)
    run(["xcrun", "simctl", "launch", DEVICE, BUNDLE_ID] + args)

    dump = os.path.join(docs, "dump.txt")
    deadline = time.time() + dump_at + 20
    while time.time() < deadline and not os.path.exists(dump):
        time.sleep(0.5)

    if not os.path.exists(dump):
        return {"name": name, "why": spec["why"], "ok": False,
                "note": "the app never wrote a dump"}

    shutil.copy(dump, os.path.join(out, "dump.txt"))
    png = os.path.join(docs, "dump.png")
    # write() creates dump.txt first and then asks the window server for the
    # pixels. Seeing the text file is therefore not proof that the screenshot
    # is ready; copying immediately made successful runs randomly lose their
    # visual evidence. Give the second, synchronous write its own bounded
    # deadline and fail the scenario if it never arrives.
    png_deadline = time.time() + 5
    while time.time() < png_deadline and not os.path.exists(png):
        time.sleep(0.1)
    screenshot_ok = os.path.exists(png)
    if os.path.exists(png):
        shutil.copy(png, os.path.join(out, "screen.png"))

    with open(dump) as f:
        text = f.read()

    # `expect_on_screen` is checked against the visible screen alone, which
    # the dump records separately from the whole buffer -- the two can differ,
    # and only one of them is what a person is looking at.
    screen = text.partition("── on screen ──")[2].partition("── buffer ──")[0]
    missing = [e for e in spec.get("expect", []) if e not in text]
    missing += [e for e in spec.get("expect_on_screen", []) if e not in screen]
    leaked = [r for r in spec.get("reject", []) if r in text]
    wanted_status = spec.get("expect_status", "connected")
    status_ok = f"status: {wanted_status}" in text
    return {
        "name": name,
        "why": spec["why"],
        "ok": not missing and not leaked and status_ok and screenshot_ok,
        "missing": missing,
        "leaked": leaked,
        "screenshot_ok": screenshot_ok,
        "status_ok": status_ok,
        "wanted_status": wanted_status,
    }


def export_walkthrough_screenshots(result):
    """Put the screenshots a person named next to the other QA artifacts.

    XCTest keeps attachments inside the opaque xcresult bundle and exports
    them under UUIDs along with videos, UI hierarchies and synthesized-event
    diagnostics. The attachment manifest retains our `shot("01 …")` names,
    so copy only those PNGs to a directory that can be reviewed without
    opening Xcode.
    """
    raw = os.path.join(OUT, "walkthrough-attachments")
    screenshots = os.path.join(OUT, "walkthrough-screenshots")
    shutil.rmtree(raw, ignore_errors=True)
    shutil.rmtree(screenshots, ignore_errors=True)

    exported = run(
        ["xcrun", "xcresulttool", "export", "attachments",
         "--path", result, "--output-path", raw],
        check=False)
    if exported.returncode != 0:
        return {"count": 0, "path": screenshots,
                "error": exported.stderr.strip() or exported.stdout.strip()}

    with open(os.path.join(raw, "manifest.json")) as f:
        manifest = json.load(f)

    os.makedirs(screenshots, exist_ok=True)
    count = 0
    for test in manifest:
        test_name = test["testIdentifier"].split("/")[-1].removesuffix("()")
        test_dir = os.path.join(screenshots, test_name)
        for attachment in test.get("attachments", []):
            human = attachment.get("suggestedHumanReadableName", "")
            # Our attachments are named "01 session list_0_<uuid>.png" by
            # xcresulttool ("12b ..." for a step added between two others).
            # System screenshots have timestamps instead.
            match = re.match(r"^(\d{2}[a-z]? .+?)_\d+_[0-9A-F-]+\.png$", human)
            if not match:
                continue
            os.makedirs(test_dir, exist_ok=True)
            readable = re.sub(r"[^A-Za-z0-9._ -]+", "-", match.group(1))
            destination = os.path.join(test_dir, f"{readable}.png")
            shutil.copy2(os.path.join(raw, attachment["exportedFileName"]),
                         destination)

            # XCUIScreen keeps the device's portrait pixel canvas even while
            # the interface is landscape, and writes no orientation metadata.
            # The pixels are correct but the exported proof is sideways. Make
            # named landscape steps readable, while checking dimensions first
            # so a future Xcode that exports a true landscape PNG is not
            # rotated twice.
            if "landscape" in match.group(1).lower():
                dimensions = run(
                    ["sips", "-g", "pixelWidth", "-g", "pixelHeight",
                     destination], check=False)
                width = re.search(r"pixelWidth: ([0-9]+)", dimensions.stdout)
                height = re.search(r"pixelHeight: ([0-9]+)", dimensions.stdout)
                if dimensions.returncode != 0 or not width or not height:
                    return {
                        "count": count,
                        "path": screenshots,
                        "error": dimensions.stderr.strip()
                                 or "could not inspect landscape screenshot",
                    }
                if int(height.group(1)) > int(width.group(1)):
                    rotated = run(
                        ["sips", "--rotate", "270", destination],
                        check=False)
                    if rotated.returncode != 0:
                        return {
                            "count": count,
                            "path": screenshots,
                            "error": rotated.stderr.strip()
                                     or "could not rotate landscape screenshot",
                        }
            count += 1

    shutil.rmtree(raw, ignore_errors=True)
    return {"count": count, "path": screenshots, "error": None}


def run_walkthrough():
    """The same app, used through its interface: taps and typing.

    Runs here rather than as its own command because it needs the same
    servers, and a UI test that depends on a server somebody else started is
    a UI test that passes until the day it does not.
    """
    key_path = os.path.abspath(os.path.join(FIXTURE, "client_ed25519"))
    env = dict(os.environ)
    env.update({
        "TAKO_TEST_HOST": "127.0.0.1",
        "TAKO_TEST_PORT": str(ECHO_PORT),
        "TAKO_TEST_USER": USER,
        "TAKO_TEST_PASSWORD": PASSWORD,
        "TAKO_TEST_MFA_PORT": str(MFA_PORT),
        "TAKO_TEST_MFA_CODE": MFA_CODE,
        "TAKO_TEST_MFA_DEVICE": MFA_DEVICE,
        "TAKO_TEST_OPENSSH_PORT": str(PORT),
        "TAKO_TEST_OPENSSH_SECOND_PORT": str(PORT + 1),
        "TAKO_TEST_FAULT_PROXY_PORT": str(FAULT_PROXY_PORT),
        "TAKO_TEST_FAULT_CONTROL_PORT": str(FAULT_CONTROL_PORT),
    })
    result = os.path.join(OUT, "walkthrough.xcresult")
    shutil.rmtree(result, ignore_errors=True)
    # TAKO_WALKTHROUGH_ONLY=WalkthroughTests/testConnectsToAHostAndTypesInIt
    # runs one test while working on it. Its coverage is that test's alone,
    # so ios-coverage-gate.py is only meaningful after an unfiltered run.
    only = os.environ.get("TAKO_WALKTHROUGH_ONLY")
    only = [f"-only-testing:TakoCoreUITests/{only}"] if only else []
    r = subprocess.run(
        ["xcodebuild", "test",
         # Line coverage of the app code the walkthrough drives; read back by
         # scripts/ios-coverage-gate.py from walkthrough.xcresult.
         "-enableCodeCoverage", "YES",
         "-project", "ios/TakoCore.xcodeproj",
         "-scheme", "TakoCore",
         "-destination", f"platform=iOS Simulator,name={DEVICE}",
         "-derivedDataPath", "target/ios-sim-derived",
         "-resultBundlePath", result,
         *only,
         "TAKO_TEST_HOST=127.0.0.1",
         f"TAKO_TEST_USER={USER}",
         f"TAKO_TEST_ECHO_PORT={ECHO_PORT}",
         f"TAKO_TEST_MFA_PORT={MFA_PORT}",
         f"TAKO_TEST_MFA_CODE={MFA_CODE}",
         f"TAKO_TEST_MFA_DEVICE={MFA_DEVICE}",
         f"TAKO_TEST_OPENSSH_PORT={PORT}",
         f"TAKO_TEST_OPENSSH_SECOND_PORT={PORT + 1}",
         f"TAKO_TEST_FAULT_PROXY_PORT={FAULT_PROXY_PORT}",
         f"TAKO_TEST_FAULT_CONTROL_PORT={FAULT_CONTROL_PORT}",
         f"TAKO_TEST_KEY_PATH={key_path}"],
        capture_output=True, text=True, env=env)
    summary_result = run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary",
         "--path", result, "--compact"],
        check=False)
    if summary_result.returncode == 0:
        summary = json.loads(summary_result.stdout)
        passed = summary["passedTests"]
        failed = [failure["failureText"]
                  for failure in summary.get("testFailures", [])]
    else:
        passed = 0
        failed = [line.strip() for line in r.stdout.splitlines()
                  if " error: " in line]
        if r.returncode != 0 and not failed:
            failed = [(r.stderr or r.stdout)[-2000:].strip()
                      or "xcodebuild failed without diagnostic output"]
    shots = export_walkthrough_screenshots(result)
    return {"passed": passed, "failed": failed, "result": result,
            "screenshots": shots}


def main():
    if any(arg in ("-h", "--help") for arg in sys.argv[1:]):
        print(__doc__.strip())
        print("\nScenarios:")
        for spec in SCENARIOS:
            print(f"  {spec['name']:<32} {spec['why']}")
        return

    unknown = [arg for arg in sys.argv[1:]
               if arg.startswith("-") and arg != "--keep"]
    if unknown:
        sys.exit(f"unknown option: {unknown[0]} (try --help)")

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    keep = "--keep" in sys.argv
    # "walkthrough" names the XCUITest walkthrough, which otherwise runs only
    # after a full scenario pass.
    walkthrough = not args or "walkthrough" in args
    names = [a for a in args if a != "walkthrough"]
    if not args:
        wanted = list(SCENARIOS)
    else:
        wanted = [s for s in SCENARIOS if s["name"] in names]
    if names and len(wanted) != len(set(names)) or (not wanted and not walkthrough):
        sys.exit(f"no such scenario; have: walkthrough, {', '.join(s['name'] for s in SCENARIOS)}")

    os.makedirs(OUT, exist_ok=True)
    # One run per machine at a time: the fixture servers use fixed ports and
    # every run drives the same simulator. A second run waits here instead of
    # fighting the first for both. Released when the process exits.
    lock = open("/tmp/tako-simtest.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("[simtest] another simtest run is using the simulator; waiting")
        fcntl.flock(lock, fcntl.LOCK_EX)
    print("[simtest] starting servers")
    make_servers()
    try:
        print("[simtest] building and installing")
        build_and_install()
        results = []
        for spec in wanted:
            print(f"[simtest] {spec['name']}: {spec['why']}")
            results.append(scenario(spec))
            r = results[-1]
            flag = "ok " if r["ok"] else "FAIL"
            detail = ""
            if r.get("missing"):
                detail += f" missing={r['missing']}"
            if r.get("leaked"):
                detail += f" leaked={r['leaked']}"
            if not r.get("status_ok", True):
                detail += f" (not {r['wanted_status']})"
            if not r.get("screenshot_ok", True):
                detail += " screenshot missing"
            if r.get("note"):
                detail += f" {r['note']}"
            print(f"[simtest]   {flag}{detail}")
    finally:
        if not keep:
            stop_servers()

    walk = None
    if walkthrough:
        print("[simtest] walkthrough: the app through its own interface")
        make_servers()
        try:
            walk = run_walkthrough()
        finally:
            stop_servers()
        for line in walk["failed"]:
            print(f"[simtest]   FAIL {line}")
        print(f"[simtest]   {walk['passed']} passed, {len(walk['failed'])} failed")
        shots = walk["screenshots"]
        if shots["error"]:
            print(f"[simtest]   FAIL exporting walkthrough screenshots: "
                  f"{shots['error']}")
        else:
            print(f"[simtest]   {shots['count']} named screenshots in "
                  f"{shots['path']}/")

    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump(results, f, indent=2)

    failed = [r for r in results if not r["ok"]]
    print(f"[simtest] {len(results) - len(failed)}/{len(results)} scenarios passed"
          f" — artifacts in {OUT}/")
    walkthrough_failed = walk and (
        walk["failed"] or
        walk["screenshots"]["error"] or
        walk["screenshots"]["count"] == 0
    )
    sys.exit(1 if failed or walkthrough_failed else 0)


if __name__ == "__main__":
    main()
