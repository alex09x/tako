#!/usr/bin/env python3
# tako — Archive a kept test directory without following any link
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Walk one already validated root by directory descriptors only.

Every entry is lstat'ed through its parent's descriptor and opened with
O_NOFOLLOW; the opened object must be the one lstat saw (device and inode),
so a file or directory swapped for a link after the check is refused, never
followed. Archived bytes are the ones read through that descriptor, bounded
to the per-file cap plus one: tar never reopens a path. Policy-excluded and
over-cap files are indexed from their metadata only and never read.
"""
import hashlib
import io
import os
import re
import stat
import tarfile

FILE_CAP = 8 * 1024 * 1024
PAYLOAD_CAP = 200 * 1024 * 1024
ENTRY_CAP = 20000

# Never read: credential homes and key files, every shell or REPL history,
# and raw environment or process dumps. Names are matched per component.
EXCLUDED_DIRS = {".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", "Keychains", "gh", ".password-store"}
EXCLUDED_FILE = re.compile(
    r"(?i)(history|histfile|\.lesshst$|^\.netrc$|^\.git-credentials$|^\.npmrc$|^\.pypirc$|^credentials"
    r"|^auth|token|secret|\.pem$|\.key$|\.p12$|\.pfx$|^id_(rsa|dsa|ecdsa|ed25519)|^environ|^env(\.|$)"
    r"|^printenv|^ps(\.|-|$)|^processes)")
# Best effort only: a file without a match is not proved free of secrets.
SECRET = {
    "github-token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"),
    "actions-token": re.compile(rb"ACTIONS_(RUNTIME|ID_TOKEN_REQUEST)_TOKEN"),
    "private-key": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "aws-key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "slack-token": re.compile(rb"xox[abpr]-[A-Za-z0-9-]{10,}"),
}


def kind(mode):
    for test, name in ((stat.S_ISREG, "file"), (stat.S_ISDIR, "dir"), (stat.S_ISLNK, "link"),
                       (stat.S_ISSOCK, "socket"), (stat.S_ISFIFO, "fifo"), (stat.S_ISCHR, "char-device"),
                       (stat.S_ISBLK, "block-device")):
        if test(mode):
            return name
    return "other"


def excluded(relative):
    parts = relative.split("/")
    if any(part in EXCLUDED_DIRS for part in parts[:-1]):
        return "privacy:credential-home"
    if EXCLUDED_FILE.search(parts[-1]):
        return "privacy:excluded-name"
    return None


class Budget:
    """Entry count and archived payload bytes (not physical tar bytes)."""

    def __init__(self, entries=ENTRY_CAP, payload=PAYLOAD_CAP, file_cap=FILE_CAP):
        self.entries, self.payload, self.file_cap = entries, payload, file_cap
        self.used_entries = self.used_payload = 0


def same(before, after):
    return (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino)


def read_bounded(fd, cap):
    chunks, total = [], 0
    while total <= cap:
        chunk = os.read(fd, min(1 << 20, cap + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def tar_info(name, status, kind_name, size=0, link=""):
    info = tarfile.TarInfo(name)
    info.mode = stat.S_IMODE(status.st_mode)
    info.mtime = int(status.st_mtime)
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.type = {"dir": tarfile.DIRTYPE, "link": tarfile.SYMTYPE}.get(kind_name, tarfile.REGTYPE)
    info.size, info.linkname = size, link
    return info


def archive_root(root_fd, root_name, archive, budget, entries, errors):
    """Archive the directory open at ROOT_FD (validated by the caller) into
    ARCHIVE, appending one index record per entry to ENTRIES and every
    traversal fault to ERRORS. Returns nothing; faults never stop siblings."""
    root_status = os.fstat(root_fd)
    archive.addfile(tar_info(root_name, root_status, "dir"))
    stack = [(root_fd, root_name, "")]
    try:
        while stack:
            fd, archive_dir, relative_dir = stack.pop()
            try:
                try:
                    names = sorted(os.listdir(fd))
                except OSError as error:
                    errors.append({"path": relative_dir or ".", "error": f"list: {error.strerror}"})
                    continue
                for name in names:
                    relative = f"{relative_dir}/{name}" if relative_dir else name
                    child = _entry(fd, name, relative, f"{archive_dir}/{name}", archive, budget, entries, errors)
                    if child is not None:
                        stack.append(child)
            finally:
                if fd != root_fd:
                    os.close(fd)
    finally:
        for fd, _, _ in stack:
            if fd != root_fd:
                os.close(fd)


def _entry(parent, name, relative, archive_name, archive, budget, entries, errors):
    record = {"path": relative}
    entries.append(record)
    if budget.used_entries >= budget.entries:
        record.update(decision="refused", reason="entry-cap")
        return None
    budget.used_entries += 1
    try:
        status = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as error:
        record.update(decision="missing", reason=f"lstat: {error.strerror}")
        return None
    kind_name = kind(status.st_mode)
    record.update(type=kind_name, mode=oct(stat.S_IMODE(status.st_mode)), size=status.st_size)
    if kind_name == "link":
        try:
            target = os.readlink(name, dir_fd=parent)
        except OSError as error:
            record.update(decision="error", reason=f"readlink: {error.strerror}")
            errors.append({"path": relative, "error": record["reason"]})
            return None
        record.update(decision="archived", target=target, outside=target.startswith("/") or ".." in target.split("/"))
        archive.addfile(tar_info(archive_name, status, "link", link=target))
        return None
    if kind_name == "dir":
        if relative.split("/")[-1] in EXCLUDED_DIRS:
            record.update(decision="excluded", reason="privacy:credential-home")
            return None
        try:
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        except OSError as error:
            record.update(decision="error", reason=f"open: {error.strerror}")
            errors.append({"path": relative, "error": record["reason"]})
            return None
        if not same(status, os.fstat(fd)):
            os.close(fd)
            record.update(decision="error", reason="race: replaced after lstat")
            errors.append({"path": relative, "error": record["reason"]})
            return None
        record.update(decision="archived")
        archive.addfile(tar_info(archive_name, status, "dir"))
        return fd, archive_name, relative
    if kind_name != "file":
        record.update(decision="indexed", reason="special file, not copied")
        return None
    reason = excluded(relative)
    if reason is None and status.st_size > budget.file_cap:
        reason = "file-cap"
    if reason is None and budget.used_payload + status.st_size > budget.payload:
        reason = "payload-cap"
    if reason is not None:
        record.update(decision="excluded", reason=reason)
        return None
    _file(parent, name, relative, archive_name, status, archive, budget, record, errors)
    return None


def _file(parent, name, relative, archive_name, status, archive, budget, record, errors):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except OSError as error:
        record.update(decision="error", reason=f"open: {error.strerror}")
        errors.append({"path": relative, "error": record["reason"]})
        return
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or not same(status, opened):
            record.update(decision="error", reason="race: replaced after lstat")
            errors.append({"path": relative, "error": record["reason"]})
            return
        data = read_bounded(fd, budget.file_cap)
    except OSError as error:
        record.update(decision="error", reason=f"read: {error.strerror}")
        errors.append({"path": relative, "error": record["reason"]})
        return
    finally:
        os.close(fd)
    if len(data) > budget.file_cap:
        record.update(decision="excluded", reason="file-cap (grew while read)")
        return
    if budget.used_payload + len(data) > budget.payload:
        record.update(decision="excluded", reason="payload-cap")
        return
    hit = next((label for label, pattern in SECRET.items() if pattern.search(data)), None)
    if hit is not None:
        record.update(decision="excluded", reason=f"privacy:secret-pattern:{hit}")
        return
    budget.used_payload += len(data)
    record.update(decision="archived", size=len(data), sha256=hashlib.sha256(data).hexdigest())
    archive.addfile(tar_info(archive_name, opened, "file", size=len(data)), io.BytesIO(data))
