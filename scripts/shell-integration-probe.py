#!/usr/bin/env python3
# tako — shell-integration probe for the bundled scripts
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Shell-integration probe for Tako's bundled scripts, outside the app.

Runs each shell under a PTY with the environment Tako's launch plan gives it
(PTY.shellLaunchPlan / shellIntegrationVariables) and nothing of the owner's:
HOME, XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME, ZDOTDIR's target and
HISTFILE are private temp dirs, so no startup file is read and no history is
written. The owner's history files are checked unchanged afterwards.

In each shell: cd into a temp git repo, `echo hello`, `false`, `true`, `exit`.
An integrated shell must mark exactly one command start (133;C) per command,
report each command's end once with its status (133;D;0, 0, 1, 0), send no
bare or duplicated end, and report the repo as its cwd (OSC 7).

Cases: zsh and fish as Tako launches them; stock bash as launched (no
injection: Tako injects only into bash 4+), as a sanitized --noprofile --norc
baseline rather than a full login startup; the same with tako.bash sourced by
hand; and, when installed, Homebrew bash (the supported --posix ENV path) and
nu. A shell that is not installed is reported as such, never left out.

usage: shell-integration-probe.py RESOURCES_DIR OUT_DIR
       (RESOURCES_DIR holds shell-integration/, e.g. Tako.app/Contents/Resources/tako)
exit 1 when a case does not behave as expected, or the owner's history changed.
"""
import json, os, pty, re, select, shutil, subprocess, sys, tempfile, time

RES, OUT = os.path.abspath(sys.argv[1]), sys.argv[2]
BASE = RES + "/shell-integration"
os.makedirs(OUT, exist_ok=True)
REAL_HOME = os.path.expanduser("~")
OWNER_HISTORY = [os.path.join(REAL_HOME, p) for p in
                 (".local/share/fish/fish_history", ".bash_history", ".zsh_history", ".zhistory")]

def stamp(paths):
    return {p: (os.stat(p).st_size, os.stat(p).st_mtime_ns) if os.path.exists(p) else None for p in paths}

before = stamp(OWNER_HISTORY)
root = tempfile.mkdtemp(prefix="tako-shell-probe-")
home, repo = os.path.join(root, "home"), os.path.join(root, "repo")
for d in ("home", "home/.config", "home/.local/share", "home/.cache", "zdotdir", "repo"):
    os.makedirs(os.path.join(root, d), exist_ok=True)
git = ["git", "-c", "user.email=p@p", "-c", "user.name=p", "-C", repo]
subprocess.run(git + ["init", "-q", "-b", "probe-branch"], check=True, env={"HOME": home, "PATH": "/usr/bin:/bin"})
subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "x"], check=True, env={"HOME": home, "PATH": "/usr/bin:/bin"})

common = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
          "HOME": home, "USER": os.environ.get("USER", ""), "XDG_CONFIG_HOME": home + "/.config",
          "XDG_DATA_HOME": home + "/.local/share", "XDG_CACHE_HOME": home + "/.cache",
          "HISTFILE": home + "/.shell_history", "TAKO_RESOURCES_DIR": RES, "TAKO_SHELL_FEATURES": "prompt",
          "TERM_PROGRAM": "tako"}
xdg = {"XDG_DATA_DIRS": BASE + ":/usr/local/share:/usr/share"}
bash_env = {"ENV": BASE + "/bash/tako.bash", "TAKO_BASH_INJECT": "1", "TAKO_BASH_ENV": "", "TAKO_BASH_ENV_SET": "0",
            "TAKO_BASH_POSIX": "0", "TAKO_BASH_INHERIT_ERREXIT": "0"}
# name, executable, argv after it, extra env, expected integrated, line typed first
CASES = [
    ("zsh", "/bin/zsh", ["-l"], {"ZDOTDIR": BASE + "/zsh", "TAKO_ZSH_ZDOTDIR": root + "/zdotdir"}, True, None),
    ("fish", "/opt/homebrew/bin/fish", ["-l"], xdg, True, None),
    ("bash-3.2-sanitized-as-launched", "/bin/bash", ["--noprofile", "--norc", "-i"], {}, False, None),
    ("bash-3.2-sanitized-manual-source", "/bin/bash", ["--noprofile", "--norc", "-i"], {}, True, f"source {BASE}/bash/tako.bash"),
    ("bash-homebrew-supported", "/opt/homebrew/bin/bash", ["--posix", "-l"], bash_env, True, None),
    ("nu", "/opt/homebrew/bin/nu", ["-l"], xdg, True, None),
]
COMMANDS = [f"cd {repo}", "echo hello", "false", "true"]
EXPECTED_STATUS = ["0", "0", "1", "0"]

def run(argv, env, pre):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(home)
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
    for line in ([pre] if pre else []) + COMMANDS + ["exit"]:
        os.write(fd, (line + "\r").encode()); pump(1.2)
    pump(1.0)
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    return buf

def judge(text):
    """The marks between the first command and exit, and what is wrong with them."""
    osc = re.findall(r"\x1b\](133;[A-Z][^\x07\x1b]*|7;[^\x07\x1b]*)(?:\x07|\x1b\\)", text)
    marks = [o for o in osc if o.startswith("133;")]
    starts = [i for i, m in enumerate(marks) if m.startswith("133;C")]
    ends = [m for m in marks if m.startswith("133;D")]
    statuses = [m.split(";")[2] for m in ends if len(m.split(";")) > 2]
    problems = []
    if not starts: problems.append("no 133;C")
    elif len(starts) != len(COMMANDS) + 1: problems.append(f"{len(starts)} command starts for {len(COMMANDS) + 1} commands")
    bare = sum(m == "133;D" for m in ends)
    if bare: problems.append(f"{bare} bare 133;D")
    if statuses[:len(EXPECTED_STATUS)] != EXPECTED_STATUS:
        problems.append(f"statuses {statuses[:6]} (want {EXPECTED_STATUS} first)")
    for a, b in zip(starts, starts[1:]):
        between = [m for m in marks[a + 1:b] if m.startswith("133;D")]
        if len(between) != 1: problems.append(f"{len(between)} ends between two command starts"); break
    if not any(repo.split("/")[-1] in o for o in osc if o.startswith("7;")): problems.append("no OSC 7 for the repo")
    return {"command_starts": len(starts), "ends": len(ends), "bare_ends": bare, "statuses": statuses,
            "prompt_marks": sum(m.startswith("133;A") for m in marks), "problems": problems}

report, bad = {}, 0
for name, exe, args, extra, should, pre in CASES:
    if not os.path.exists(exe):
        report[name] = {"result": "not installed", "executable": exe}; continue
    raw = run([exe] + args, {**common, **extra}, pre)
    open(f"{OUT}/{name}.raw", "wb").write(raw)
    r = judge(raw.decode("utf-8", "replace"))
    r["integrated"] = not r["problems"]
    if should is False:
        r["expected"] = "no integration (un-injected baseline)"
        ok = r["command_starts"] == 0
    else:
        r["expected"] = "integrated, one start and one end per command"
        ok = r["integrated"]
    r["result"] = "as expected" if ok else "UNEXPECTED"
    bad += not ok
    report[name] = r

after = stamp(OWNER_HISTORY)
changed = [p for p in OWNER_HISTORY if before[p] != after[p]]
report["owner-history"] = {"unchanged": not changed, "changed": changed}
bad += bool(changed)
json.dump({"cases": report}, open(f"{OUT}/report.json", "w"), indent=1)
print(json.dumps(report, indent=1))
shutil.rmtree(root, ignore_errors=True)
sys.exit(1 if bad else 0)
