#!/usr/bin/env python3
# tako — shell-integration probe for the bundled scripts
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Shell-integration probe for Tako's bundled scripts, outside the app.

Runs each shell under a PTY with the environment Tako's launch plan gives it
(PTY.shellLaunchPlan / shellIntegrationVariables), with no user startup files:
zsh's real ZDOTDIR is an empty temp dir, fish's XDG_CONFIG_HOME is an empty temp
dir, bash runs --noprofile --norc. Nothing in the user's home is read or written.

For each shell: cd into a temp git repo, run `echo hello`, `false`, `true`, exit.
Reports which OSC sequences arrived: 7 (cwd), 133;A/B/C/D (prompt/command marks,
exit status). Exit 1 if a shell that should be integrated misses any.
usage: probe.py RESOURCES_DIR OUT_DIR
"""
import json, os, pty, re, select, subprocess, sys, tempfile, time

RES, OUT = sys.argv[1], sys.argv[2]
BASE = RES + "/shell-integration"
os.makedirs(OUT, exist_ok=True)
repo = tempfile.mkdtemp(prefix="tako-shell-repo-")
subprocess.run(["git", "-C", repo, "init", "-q", "-b", "probe-branch"], check=True)
subprocess.run(["git", "-C", repo, "-c", "user.email=p@p", "-c", "user.name=p", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
empty = tempfile.mkdtemp(prefix="tako-shell-empty-")

common = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
          "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TAKO_RESOURCES_DIR": RES,
          "TAKO_SHELL_FEATURES": "prompt", "TERM_PROGRAM": "tako"}
CASES = [
    ("zsh", ["/bin/zsh", "-l"], {"ZDOTDIR": BASE + "/zsh", "TAKO_ZSH_ZDOTDIR": empty}, True, None),
    ("fish", ["/opt/homebrew/bin/fish", "-l"], {"XDG_DATA_DIRS": BASE + ":/usr/local/share:/usr/share", "XDG_CONFIG_HOME": empty}, True, None),
    # What Tako launches for stock macOS bash 3.2: an ordinary login shell, no injection (TakoBashBootstrapSupport < 4).
    ("bash-3.2-as-launched", ["/bin/bash", "--noprofile", "--norc", "-i"], {}, False, None),
    # The manual path the launch plan keeps for old bash: source the script yourself.
    ("bash-3.2-manual-source", ["/bin/bash", "--noprofile", "--norc", "-i"], {}, True, f"source {BASE}/bash/tako.bash"),
]
for name, path in [("nu", "/opt/homebrew/bin/nu"), ("bash-5", "/opt/homebrew/bin/bash")]:
    if not os.path.exists(path):
        CASES.append((name, None, {}, None, None))

def run(argv, env, pre):
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, env)
    buf = b""
    def pump(t):
        nonlocal buf
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try: buf += os.read(fd, 65536)
                except OSError: return
    pump(2.5)
    script = ([pre] if pre else []) + [f"cd {repo}", "echo hello", "false", "true", "exit"]
    for line in script:
        os.write(fd, (line + "\r").encode()); pump(1.2)
    pump(1.0)
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    return buf

report, bad = {}, 0
for name, argv, extra, should, pre in CASES:
    if argv is None:
        report[name] = {"skipped": "not installed"}; continue
    raw = run(argv, {**common, **extra}, pre)
    open(f"{OUT}/{name}.raw", "wb").write(raw)
    text = raw.decode("utf-8", "replace")
    osc = re.findall(r"\x1b\](133;[A-Z][^\x07\x1b]*|7;[^\x07\x1b]*)(?:\x07|\x1b\\)", text)
    marks = [o for o in osc if o.startswith("133;")]
    cwds = [o[2:] for o in osc if o.startswith("7;")]
    exits = [m for m in marks if m.startswith("133;D")]
    r = {"133;A": sum(m.startswith("133;A") for m in marks), "133;B": sum(m.startswith("133;B") for m in marks),
         "133;C": sum(m.startswith("133;C") for m in marks), "133;D": exits, "133;D_per_command_max": 0,
         "osc7_in_repo": any(repo.split("/")[-1] in c for c in cwds), "osc7_count": len(cwds)}
    r["D_bare"] = sum(e == "133;D" for e in exits)
    ok = r["133;A"] > 0 and r["133;C"] > 0 and any(e.split(";")[2:3] == ["1"] for e in exits) and r["osc7_in_repo"]
    r["integrated"] = ok
    if should is not None and ok != should:
        r["MISMATCH"] = f"expected integrated={should}"; bad += 1
    report[name] = r
json.dump({"repo": repo, "cases": report}, open(f"{OUT}/report.json", "w"), indent=1)
print(json.dumps(report, indent=1))
sys.exit(1 if bad else 0)
