// Placeholder entry point for the UI tests' host-application target.
//
// The target is a native macOS app target only so that Xcode gives the UI
// Testing Bundle a real Target Application to resolve `XCUIApplication()`
// against. Nothing here ever runs: the target's post-build script runs
// `python3 scripts/build-macapp.py` and replaces this product wholesale with
// the real Tako.app bundle that script produces.
import Foundation

exit(0)
