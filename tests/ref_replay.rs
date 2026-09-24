// Replay of recorded PTY sessions against approved screen snapshots.
//
// The fixtures under `tests/fixtures/ref/` are Alacritty's reference
// recordings (Apache-2.0), vendored as data: each `input.recording` is the
// raw byte stream a real program wrote to a real PTY, and `size.json` is the
// geometry it was recorded at. Programs covered include vim, tmux running
// htop and git log, zsh tab completion, fish, and several vttest sections.
//
// Capturing streams like these by hand is the expensive part of this kind of
// testing, and it has already been done. What we assert is ours: the screen
// is compared against our own `dump()` snapshot, not Alacritty's grid format.
//
// Regenerate every snapshot after an intentional behaviour change:
//
//     UPDATE_SNAPSHOTS=1 cargo test --test ref_replay
//
// and read the resulting diff before committing it. A snapshot that changes
// without a reason in the same commit is the bug this file exists to catch.

use std::fs;
use std::path::{Path, PathBuf};

use tako_core::terminal::Terminal;

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ref")
}

/// Every recorded case, in a stable order.
fn cases() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(fixtures_dir())
        .expect("tests/fixtures/ref is missing")
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.join("input.recording").is_file())
        .collect();
    dirs.sort();
    assert!(!dirs.is_empty(), "no recordings found under tests/fixtures/ref");
    dirs
}

/// `size.json` holds exactly `{"columns":N,"screen_lines":M}`. Reading two
/// integers out of it directly is less machinery than a JSON dependency for
/// a file this shape.
fn geometry(dir: &Path) -> (usize, usize) {
    let raw = fs::read_to_string(dir.join("size.json"))
        .unwrap_or_else(|e| panic!("{}: size.json unreadable: {e}", name(dir)));

    let field = |key: &str| -> usize {
        let at = raw
            .find(key)
            .unwrap_or_else(|| panic!("{}: size.json has no {key}", name(dir)));
        raw[at + key.len()..]
            .trim_start_matches(|c: char| c == '"' || c == ':' || c.is_whitespace())
            .chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>()
            .parse()
            .unwrap_or_else(|e| panic!("{}: bad {key}: {e}", name(dir)))
    };

    (field("columns"), field("screen_lines"))
}

fn name(dir: &Path) -> String {
    dir.file_name().unwrap().to_string_lossy().into_owned()
}

/// Feeds `chunks` of the recording into a terminal of the recorded size and
/// returns the resulting snapshot. Output is drained as it accumulates so a
/// long recording's device replies never dominate memory.
fn replay(dir: &Path, chunks: &[&[u8]]) -> String {
    let (cols, rows) = geometry(dir);
    let mut term = Terminal::new(cols, rows);
    for chunk in chunks {
        term.feed(chunk);
        let _ = term.take_output();
    }
    term.dump()
}

fn recording(dir: &Path) -> Vec<u8> {
    fs::read(dir.join("input.recording"))
        .unwrap_or_else(|e| panic!("{}: input.recording unreadable: {e}", name(dir)))
}

/// Every recording replays to its approved screen.
#[test]
fn recorded_sessions_match_their_snapshots() {
    let updating = std::env::var_os("UPDATE_SNAPSHOTS").is_some();
    let mut failures: Vec<String> = Vec::new();
    let mut written = 0usize;

    for dir in cases() {
        let bytes = recording(&dir);
        let actual = replay(&dir, &[&bytes]);
        let snapshot = dir.join("snapshot.txt");

        if updating || !snapshot.exists() {
            fs::write(&snapshot, &actual).expect("failed to write snapshot");
            written += 1;
            continue;
        }

        let expected = fs::read_to_string(&snapshot).expect("failed to read snapshot");
        if expected != actual {
            failures.push(format!(
                "{}: screen differs from its snapshot\n{}",
                name(&dir),
                first_difference(&expected, &actual)
            ));
        }
    }

    if written > 0 {
        // Not a silent pass: a run that only wrote files has verified nothing.
        eprintln!("wrote {written} snapshot(s); re-run to verify them");
    }
    assert!(failures.is_empty(), "\n\n{}", failures.join("\n\n"));
}

/// A real PTY hands the parser whatever the kernel had ready, so the same
/// stream arrives split at arbitrary offsets. The screen must not depend on
/// where those splits fall -- a sequence straddling a chunk boundary is a
/// classic terminal bug, and these recordings are far more varied than any
/// stream written by hand for the purpose.
#[test]
fn replay_is_independent_of_chunk_boundaries() {
    let mut failures: Vec<String> = Vec::new();

    for dir in cases() {
        let bytes = recording(&dir);
        let whole = replay(&dir, &[&bytes]);

        for size in [1usize, 7, 64, 997] {
            let chunks: Vec<&[u8]> = bytes.chunks(size).collect();
            let split = replay(&dir, &chunks);
            if split != whole {
                failures.push(format!(
                    "{}: {size}-byte chunks diverge from a single feed\n{}",
                    name(&dir),
                    first_difference(&whole, &split)
                ));
                break;
            }
        }
    }

    assert!(failures.is_empty(), "\n\n{}", failures.join("\n\n"));
}

/// Every case must carry the geometry it was recorded at; replaying at the
/// wrong size silently compares the wrong thing.
#[test]
fn every_case_declares_a_usable_geometry() {
    for dir in cases() {
        let (cols, rows) = geometry(&dir);
        assert!(cols > 0 && rows > 0, "{}: empty geometry", name(&dir));
        assert!(
            cols <= 1000 && rows <= 1000,
            "{}: implausible geometry {cols}x{rows}",
            name(&dir)
        );
    }
}

/// The first line that differs, with a little context. A whole-screen diff of
/// a 24-row snapshot buries the one row that moved.
fn first_difference(expected: &str, actual: &str) -> String {
    let (exp, act): (Vec<&str>, Vec<&str>) = (expected.lines().collect(), actual.lines().collect());

    for (i, (e, a)) in exp.iter().zip(act.iter()).enumerate() {
        if e != a {
            return format!("  line {i}\n  expected: {e}\n  actual:   {a}");
        }
    }

    format!(
        "  expected {} lines, got {} (first extra: {:?})",
        exp.len(),
        act.len(),
        exp.get(act.len().min(exp.len())).or(act.get(exp.len().min(act.len())))
    )
}
