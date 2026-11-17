#!/usr/bin/env python3
# tako — Kept failed-case state collection
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
import json
import os
import socket
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ci_kept_state as kept
import ci_kept_walk as walk


class KeptStateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(os.path.realpath(temporary.name))
        self.tmp = base / "tmp"
        self.home = base / "home"
        self.logs = base / "logs"
        self.persist = base / "persist"
        self.out = base / "out"
        for directory in (self.tmp, self.home / "Library/Application Support", self.logs, self.persist):
            directory.mkdir(parents=True)
        self.alias = base / "alias"
        self.alias.symlink_to(self.tmp)

    def root(self, name, files=None):
        path = self.tmp / name
        path.mkdir()
        for relative, data in (files or {}).items():
            (path / relative).parent.mkdir(parents=True, exist_ok=True)
            (path / relative).write_bytes(data)
        return path

    def log(self, *lines):
        (self.logs / "macapp-e2e-shard-4.log").write_text("\n".join(("noise",) + lines + ("tail",)) + "\n")

    def run_collect(self, **overrides):
        options = dict(tmp_root=str(self.tmp), tmp_alias=str(self.alias), home=str(self.home), uid=os.getuid())
        options.update(overrides)
        return kept.collect(str(self.logs), str(self.persist), str(self.out), **options)

    def roots(self, inventory):
        return {Path(r.get("named", "")).name: r for r in inventory["roots"]}

    def members(self, tar):
        with tarfile.open(self.out / tar) as archive:
            return {m.name: m for m in archive.getmembers()}

    def test_named_work_and_sessions_are_archived_with_modes_and_an_index(self):
        work = self.root("tkw.Abc123", {"config": b"font-size = 13\n", "bin/run": b"#!/bin/sh\n"})
        os.chmod(work / "bin/run", 0o755)
        os.chmod(work / "config", 0o600)
        self.root("tkd.Xyz789", {"layout": b"{}"})
        self.log(f"work kept: {work}, sessions {self.alias}/tkd.Xyz789", f"work kept: {work}")
        inventory = self.run_collect()
        self.assertEqual(inventory["status"], "complete")
        self.assertEqual(len(inventory["roots"]), 2)  # the repeated line is one root
        members = self.members("kept-tkw.Abc123.tar")
        self.assertEqual(members["tkw.Abc123/bin/run"].mode, 0o755)
        self.assertEqual(members["tkw.Abc123/config"].mode, 0o600)
        self.assertEqual(members["tkw.Abc123/config"].uid, 0)
        self.assertIn("tkd.Xyz789/layout", self.members("kept-tkd.Xyz789.tar"))
        on_disk = json.loads((self.out / "inventory.json").read_text())
        self.assertEqual(on_disk["status"], "complete")

    def test_foreign_or_malformed_descriptors_are_refused_and_reported(self):
        self.root("tkw.Good11")
        outside = Path(tempfile.mkdtemp())
        self.addCleanup(os.rmdir, outside)
        self.log(f"work kept: {self.tmp}/tkw.Good11, extra",
                 f"work kept: {outside}",
                 f"work kept: {self.tmp}/other.Abc123",
                 "work kept: relative/tkw.Abc123",
                 f"work kept: {self.tmp}/tkw.Gone11")
        inventory = self.run_collect()
        reasons = sorted(r["reason"] for r in inventory["roots"])
        self.assertEqual(reasons, ["malformed descriptor", "missing", "not an absolute path",
                                   f"outside {self.tmp}", "unexpected name"])
        self.assertEqual(inventory["status"], "partial")
        self.assertEqual(kept.main(["--logs", str(self.logs), "--out", str(self.out)]), 1,
                         "refused roots make the collection partial and the step non-zero")

    def test_a_symlinked_root_a_foreign_owner_and_a_symlinked_parent_are_refused(self):
        target = self.root("tkw.Real11", {"f": b"x"})
        (self.tmp / "tkw.Link11").symlink_to(target)
        self.log(f"work kept: {self.tmp}/tkw.Link11")
        self.assertEqual(self.roots(self.run_collect())["tkw.Link11"]["reason"], "root is a symlink")
        self.log(f"work kept: {target}")
        refused = self.roots(self.run_collect(uid=os.getuid() + 1))["tkw.Real11"]
        self.assertEqual(refused["reason"], "owned by another user")
        # Only the one leading alias is mapped; another symlinked parent is not canonical.
        self.log(f"work kept: {self.alias}/tkw.Real11")
        refused = self.roots(self.run_collect(tmp_root=str(self.alias), tmp_alias=None))["tkw.Real11"]
        self.assertEqual(refused["reason"], "path is not canonical")

    def test_links_and_special_files_are_indexed_never_followed(self):
        work = self.root("tkw.Links1", {"real": b"inside"})
        secret = self.home / "outside.txt"
        secret.write_bytes(b"must not be archived")
        (work / "escape").symlink_to(secret)
        (work / "loop").symlink_to(work)
        os.mkfifo(work / "pipe")
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        here = os.getcwd()
        os.chdir(work)  # a relative bind keeps the socket path under macOS's 104 bytes
        try:
            listener.bind("s")
        finally:
            os.chdir(here)
        self.log(f"work kept: {work}")
        inventory = self.run_collect()
        entries = {e["path"]: e for e in inventory["roots"][0]["entries"]}
        self.assertEqual((entries["escape"]["target"], entries["escape"]["outside"]), (str(secret), True))
        self.assertEqual(entries["pipe"]["decision"], "indexed")
        self.assertEqual(entries["s"]["type"], "socket")
        members = self.members("kept-tkw.Links1.tar")
        self.assertTrue(members["tkw.Links1/escape"].issym())
        self.assertNotIn("tkw.Links1/pipe", members)
        with tarfile.open(self.out / "kept-tkw.Links1.tar") as archive:
            for member in archive.getmembers():
                if member.isfile():
                    self.assertNotIn(b"must not be archived", archive.extractfile(member).read())

    def test_privacy_and_caps_exclude_without_reading(self):
        work = self.root("tkw.Priv11", {
            ".shell_history": b"echo hi", ".ssh/id_ed25519": b"key", "env.txt": b"PATH=/bin",
            "leak.txt": b"token ghp_" + b"a" * 30, "big.bin": b"x" * 64, "ok.txt": b"fine"})
        self.log(f"work kept: {work}")
        opened = []
        real_open = os.open

        def tracking_open(path, flags, *args, **kwargs):
            opened.append(path)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(walk.os, "open", tracking_open):
            inventory = self.run_collect(budget=walk.Budget(file_cap=48))  # leak.txt 40 B, big.bin 64 B
        entries = {e["path"]: e for e in inventory["roots"][0]["entries"]}
        self.assertEqual(entries[".shell_history"]["reason"], "privacy:excluded-name")
        self.assertEqual(entries[".ssh"]["reason"], "privacy:credential-home")
        self.assertEqual(entries["env.txt"]["reason"], "privacy:excluded-name")
        self.assertEqual(entries["big.bin"]["reason"], "file-cap")
        self.assertEqual(entries["leak.txt"]["reason"], "privacy:secret-pattern:github-token")
        for name in (".shell_history", ".ssh", "env.txt", "big.bin"):
            self.assertNotIn(name, opened, f"{name} must not be opened")
            self.assertNotIn("sha256", entries[name])
        self.assertEqual(sorted(self.members("kept-tkw.Priv11.tar")), ["tkw.Priv11", "tkw.Priv11/ok.txt"])
        self.assertEqual(inventory["status"], "complete")

    def test_payload_and_entry_caps_are_reported(self):
        work = self.root("tkw.Caps11", {f"f{i}": b"12345678" for i in range(5)})
        self.log(f"work kept: {work}")
        entries = self.run_collect(budget=walk.Budget(payload=20))["roots"][0]["entries"]
        self.assertEqual([e["decision"] for e in entries].count("archived"), 2)
        self.assertEqual([e.get("reason") for e in entries].count("payload-cap"), 3)

    def test_the_entry_cap_bounds_the_index_and_makes_the_collection_partial(self):
        work = self.root("tkw.Many11", {f"d{i}/f{j}": b"x" for i in range(20) for j in range(20)})
        self.log(f"work kept: {work}")
        inventory = self.run_collect(budget=walk.Budget(entries=7))
        entries = inventory["roots"][0]["entries"]
        self.assertEqual(len(entries), 8, "seven entries and one truncation marker, not all 420")
        self.assertEqual(entries[-1]["decision"], "truncated")
        self.assertIn("entry cap 7 reached", inventory["roots"][0]["errors"][-1]["error"])
        self.assertEqual(inventory["status"], "partial")
        self.assertEqual(kept.main(["--logs", str(self.logs), "--out", str(self.out)]), 1)

    def test_the_driver_provider_home_is_never_opened_or_archived(self):
        work = self.root("tkw.Prov11", {"k/config.toml": b'api_key = "sk-ant-not-a-known-pattern"\n',
                                        "k/.codex/auth.json": b"{}", "h/.claude/settings.json": b"{}",
                                        "config": b"font-size = 13\n"})
        self.log(f"work kept: {work}")
        opened = []
        real_open = os.open

        def tracking_open(path, flags, *args, **kwargs):
            opened.append(path)
            return real_open(path, flags, *args, **kwargs)
        with mock.patch.object(walk.os, "open", tracking_open):
            inventory = self.run_collect()
        entries = {e["path"]: e for e in inventory["roots"][0]["entries"]}
        self.assertEqual((entries["k"]["decision"], entries["k"]["reason"]), ("excluded", "privacy:provider-home"))
        self.assertEqual(entries["h/.claude"]["reason"], "privacy:credential-home")
        self.assertNotIn("k", opened)
        self.assertNotIn(".claude", opened)
        self.assertFalse(any(path.startswith("k/") for path in entries))
        data = (self.out / "kept-tkw.Prov11.tar").read_bytes()
        self.assertNotIn(b"sk-ant", data)
        self.assertIn("tkw.Prov11/config", self.members("kept-tkw.Prov11.tar"))
        self.assertEqual(inventory["status"], "complete")

    def test_only_the_current_path_holds_directory_descriptors(self):
        work = self.root("tkw.Wide11", {f"d{i:03}/a/b/f": b"x" for i in range(300)})
        self.log(f"work kept: {work}")
        live, peak = set(), [0]
        real_open, real_close = os.open, os.close

        def counting_open(path, flags, *args, **kwargs):
            fd = real_open(path, flags, *args, **kwargs)
            if flags & os.O_DIRECTORY:
                live.add(fd)
                peak[0] = max(peak[0], len(live))
            return fd

        def counting_close(fd):
            live.discard(fd)
            return real_close(fd)
        with mock.patch.object(walk.os, "open", counting_open), mock.patch.object(walk.os, "close", counting_close):
            inventory = self.run_collect()
        self.assertLessEqual(peak[0], 4, "root, d###, a, b: never the 300 siblings at once")
        self.assertEqual(live, set(), "every directory descriptor is closed")
        self.assertEqual(sum(e["path"].endswith("/b/f") and e["decision"] == "archived"
                             for e in inventory["roots"][0]["entries"]), 300)
        self.assertEqual(inventory["status"], "complete")

    def test_a_file_swapped_after_lstat_is_refused_not_followed(self):
        work = self.root("tkw.Race11", {"victim": b"original", "other": b"replacement"})
        (self.home / "target").write_bytes(b"outside")
        self.log(f"work kept: {work}")
        real_stat = os.stat

        def swap(replacement):
            def stat_then_swap(path, *args, **kwargs):
                result = real_stat(path, *args, **kwargs)
                if path == "victim" and kwargs.get("dir_fd") is not None:
                    replacement()
                return result
            return stat_then_swap

        with mock.patch.object(walk.os, "stat", swap(lambda: os.replace(work / "other", work / "victim"))):
            inventory = self.run_collect()
        self.assertEqual(self.entry(inventory, "victim")["reason"], "race: replaced after lstat")
        self.assertEqual(inventory["status"], "partial")
        (work / "victim").unlink()
        (work / "victim").write_bytes(b"original")

        def to_link():
            (work / "victim").unlink()
            (work / "victim").symlink_to(self.home / "target")
        with mock.patch.object(walk.os, "stat", swap(to_link)):
            inventory = self.run_collect()
        self.assertTrue(self.entry(inventory, "victim")["reason"].startswith("open: "))
        self.assertNotIn(b"outside", (self.out / "kept-tkw.Race11.tar").read_bytes())

    def entry(self, inventory, path):
        return next(e for e in inventory["roots"][0]["entries"] if e["path"] == path)

    def test_a_fault_in_one_root_is_reported_and_the_others_still_collected(self):
        bad = self.root("tkw.Bad111", {"sub/f": b"x"})
        good = self.root("tkw.Good11", {"f": b"y"})
        os.chmod(bad / "sub", 0)
        self.addCleanup(os.chmod, bad / "sub", 0o700)
        self.log(f"work kept: {bad}", f"work kept: {good}")
        inventory = self.run_collect()
        roots = self.roots(inventory)
        self.assertEqual(roots["tkw.Bad111"]["errors"][0]["path"], "sub")
        self.assertEqual(roots["tkw.Good11"]["decision"], "collected")
        self.assertEqual(inventory["status"], "partial")
        real_open = os.open

        def refuse_bad(path, flags, *args, **kwargs):
            if str(path) == str(bad):
                raise PermissionError(13, "Permission denied")
            return real_open(path, flags, *args, **kwargs)
        with mock.patch.object(kept.os, "open", refuse_bad):
            inventory = self.run_collect()
        self.assertEqual(self.roots(inventory)["tkw.Bad111"]["decision"], "error")
        self.assertEqual(self.roots(inventory)["tkw.Good11"]["decision"], "collected")
        self.assertEqual(inventory["status"], "error")

    def test_persistence_identity_names_sessions_and_its_own_support_only_when_kept(self):
        support_root = self.home / "Library/Application Support"
        bundle = "com.tako-core.terminal.e2e-persist-1794941970-27463"
        (support_root / bundle).mkdir()
        (support_root / bundle / "layout").write_bytes(b"{}")
        self.root("tkp.Sess11", {"s.owner": b"1"})
        case = self.persist / bundle
        case.mkdir()
        identity = f"scenario persist-live\nbundle {bundle}\nsessions {self.alias}/tkp.Sess11\nsupport {support_root}/{bundle}\n"
        (case / "identity.txt").write_text(identity)
        (case / "status.txt").write_text("runner 1\ncleanup 0\noutcome 1\n")
        roots = self.roots(self.run_collect())
        self.assertEqual(roots["tkp.Sess11"]["decision"], "collected")
        self.assertEqual(roots[bundle]["decision"], "collected")
        (case / "status.txt").write_text("runner 0\ncleanup 0\noutcome 0\n")
        self.assertEqual(self.run_collect()["roots"], [])
        (case / "status.txt").write_text("outcome 1\n")
        (case / "identity.txt").write_text(identity.replace(f"support {support_root}/{bundle}",
                                                            f"support {support_root}/com.example.other"))
        self.assertEqual(self.roots(self.run_collect())["com.example.other"]["reason"], "unexpected name")

    def test_nothing_named_is_a_complete_empty_collection(self):
        self.log()
        self.assertEqual(self.run_collect(), json.loads((self.out / "inventory.json").read_text()))
        self.assertEqual(self.run_collect()["status"], "complete")


if __name__ == "__main__":
    unittest.main()
