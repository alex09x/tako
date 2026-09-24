# Upstream Swift tests not ported here

Upstream test suite baseline: upstream macOS `Tests/` (20 files) and
`TakoUITests/` (7 test files + 2 helpers). 19 of the 20 `Tests/` files are ported
verbatim or near-verbatim into this directory. The 7 `TakoUITests/` files are ported
too, but into a separate Xcode project (`macos_uitests/`, see its own README.md)
since SPM has no UI-Testing-Bundle target kind -- see that project's own notes for
why actually running them needs more than this repo alone provides. This file
accounts for the one upstream test file that isn't ported at all.

## `Tests/BenchmarkTests.swift` -- not ported

Calls `tako_benchmark_cli`, a real Zig `TakoKit` symbol our shim
(`swift/Sources/TakoKit/TakoKit.swift`) never implements -- it's a
pure-Swift stand-in for the ~19 symbols the app layer actually calls, not a
general Zig FFI bridge. The test is also permanently disabled upstream
(`.enabled(if: false)`) and hardcodes the original author's home directory
path; it says outright it's "not meant to be run in general," only profiled
manually via Xcode's Instruments integration. Nothing to port.
