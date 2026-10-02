#!/usr/bin/env python3
"""Whether a built engine artifact matches the engine sources, by content.

    engine_fingerprint.py check ARTIFACT   exit 0 if ARTIFACT was built from
                                           exactly these sources, else 1
    engine_fingerprint.py write ARTIFACT   record that it was
    engine_fingerprint.py touch            mark every engine source as just
                                           changed, before a rebuild
    engine_fingerprint.py before-cargo TRIPLE...  touch the sources if cargo
                                           last compiled different ones for
                                           any of these targets
    engine_fingerprint.py after-cargo TRIPLE...   record what cargo just
                                           compiled for them

The record is ARTIFACT.inputs: a SHA-256 over every file under src/ plus
Cargo.toml and Cargo.lock, paths and contents. Timestamps are not used: on
the test Mac every sync recreates the directories (always newer) and keeps
the files' own times (possibly older than an artifact built from other
sources), so neither tells whether the content changed. Cargo itself decides
by timestamps, so before a rebuild for changed content the sources are
touched: otherwise it could find its old output newer and keep it.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fingerprint():
    digest = hashlib.sha256()
    paths = ["Cargo.toml", "Cargo.lock"]
    for base, dirs, files in os.walk(os.path.join(ROOT, "src")):
        dirs.sort()
        paths += [os.path.relpath(os.path.join(base, f), ROOT) for f in files]
    for path in sorted(paths):
        digest.update(path.encode() + b"\0")
        with open(os.path.join(ROOT, path), "rb") as handle:
            digest.update(handle.read())
        digest.update(b"\0")
    return digest.hexdigest()


def engine_files():
    files = [os.path.join(ROOT, "Cargo.toml"), os.path.join(ROOT, "Cargo.lock")]
    for base, _, names in os.walk(os.path.join(ROOT, "src")):
        files += [os.path.join(base, n) for n in names]
    return files


# What cargo last compiled for the engine, one record per target triple: a
# build for one target says nothing about another's output.
def cargo_record(triple):
    return os.path.join("target", triple, "engine-sources")


def main(args):
    if args == ["touch"]:
        for path in engine_files():
            os.utime(path)
        return 0
    if args[:1] == ["before-cargo"] and len(args) > 1:
        # Every script that runs cargo for the engine calls this first with
        # the targets it is about to build, so content that changed under
        # older timestamps is never taken for compiled already -- for any of
        # them, whoever calls the script.
        current = fingerprint()
        for triple in args[1:]:
            record = os.path.join(ROOT, cargo_record(triple) + ".inputs")
            seen = None
            if os.path.exists(record):
                with open(record) as handle:
                    seen = handle.read().strip()
            if seen != current:
                for path in engine_files():
                    os.utime(path)
                break
        return 0
    if args[:1] == ["after-cargo"] and len(args) > 1:
        current = fingerprint()
        for triple in args[1:]:
            record = os.path.join(ROOT, cargo_record(triple) + ".inputs")
            os.makedirs(os.path.dirname(record), exist_ok=True)
            with open(record, "w") as handle:
                handle.write(current + "\n")
        return 0
    if len(args) != 2 or args[0] not in ("check", "write"):
        sys.exit(__doc__)
    record = os.path.join(ROOT, args[1] + ".inputs")
    if args[0] == "write":
        os.makedirs(os.path.dirname(record), exist_ok=True)
        with open(record, "w") as handle:
            handle.write(fingerprint() + "\n")
        return 0
    if not os.path.exists(os.path.join(ROOT, args[1])) or not os.path.exists(record):
        return 1
    with open(record) as handle:
        return 0 if handle.read().strip() == fingerprint() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
