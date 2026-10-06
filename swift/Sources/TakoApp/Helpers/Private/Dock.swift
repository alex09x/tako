import Cocoa

// Private API to get Dock location
@_silgen_name("CoreDockGetOrientationAndPinning")
func CoreDockGetOrientationAndPinning(
    _ outOrientation: UnsafeMutablePointer<Int32>,
    _ outPinning: UnsafeMutablePointer<Int32>)

// Private API to get the current Dock auto-hide state
@_silgen_name("CoreDockGetAutoHideEnabled")
func CoreDockGetAutoHideEnabled() -> Bool

// Toggles the Dock's auto-hide state
@_silgen_name("CoreDockSetAutoHideEnabled")
func CoreDockSetAutoHideEnabled(_ flag: Bool)

enum DockOrientation: Int {
    case top = 1
    case bottom = 2
    case left = 3
    case right = 4
}

class Dock {
    /// Returns the orientation of the dock or nil if it can't be determined.
    static var orientation: DockOrientation? {
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        CoreDockGetOrientationAndPinning(&orientation, &pinning)
        return .init(rawValue: Int(orientation)) ?? nil
    }

    /// Set the dock autohide.
    static var autoHideEnabled: Bool {
        get { return autoHide.get() }
        set { autoHide.set(newValue) }
    }

    /// Where `autoHideEnabled` reads and writes: the real Dock, except in a
    /// test run, which keeps the value in memory. The preference is global
    /// and persistent, and a run that hid the Dock and died before restoring
    /// it left the Mac it ran on without one.
    nonisolated(unsafe) static var autoHide: DockAutoHide = runningTests
        ? .inMemory(startingAt: CoreDockGetAutoHideEnabled())
        : DockAutoHide(get: CoreDockGetAutoHideEnabled, set: CoreDockSetAutoHideEnabled, reachesTheDock: true)

    private static var runningTests: Bool {
        #if DEBUG
        NSClassFromString("XCTestCase") != nil
        #else
        false
        #endif
    }
}

/// Reads and writes the Dock's autohide preference; see `Dock.autoHide`.
struct DockAutoHide {
    let get: () -> Bool
    let set: (Bool) -> Void
    /// False for a stand-in that never reaches the real Dock.
    let reachesTheDock: Bool

    /// A stand-in that keeps the value in memory.
    static func inMemory(startingAt value: Bool) -> DockAutoHide {
        let box = Box(value)
        return DockAutoHide(get: { box.value }, set: { box.value = $0 }, reachesTheDock: false)
    }

    private final class Box {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }
}
