import Foundation

// Upstream uses a `Notification` namespace (here `Tako.Notification`) and `Notification.Name` extensions
// to communicate between app-level controllers, window managers, tab bars, splits,
// and surfaces. Upstream is in the process of migrating notifications from the legacy
// namespace to standard `Notification.Name` extensions.
//
// We provide exact declarations for both namespaces so upstream's unmodified Swift
// application layer (Sources/TakoApp) compiles and routes notifications seamlessly
// against our pure-Rust core shim.

extension Tako {
    /// Namespace for notifications posted and observed across windows, tabs, splits, and surfaces.
    struct Notification {}
}

extension Tako.Notification {
    /// Configuration payload key used when spawning a new surface, window, tab, or split.
    static let NewSurfaceConfigKey = "com.tako-core.terminal.newSurfaceConfig"

    /// Notification posted when a new split is requested.
    static let takoNewSplit = Foundation.Notification.Name("com.tako-core.terminal.newSplit")

    /// Notification to close the calling surface.
    static let takoCloseSurface = Foundation.Notification.Name("com.tako-core.terminal.closeSurface")

    /// Notification to focus adjacent/previous/next split. UserInfo key `SplitDirectionKey`.
    static let takoFocusSplit = Foundation.Notification.Name("com.tako-core.terminal.focusSplit")
    static let SplitDirectionKey = takoFocusSplit.rawValue

    /// Notification to select a tab by index. UserInfo key `GotoTabKey`.
    static let takoGotoTab = Foundation.Notification.Name("com.tako-core.terminal.gotoTab")
    static let GotoTabKey = takoGotoTab.rawValue

    /// Notification to open a new tab.
    static let takoNewTab = Foundation.Notification.Name("com.tako-core.terminal.newTab")

    /// Notification to create a new terminal window.
    static let takoNewWindow = Foundation.Notification.Name("com.tako-core.terminal.newWindow")

    /// Notification to present/focus a terminal surface window.
    static let takoPresentTerminal = Foundation.Notification.Name("com.tako-core.terminal.presentTerminal")

    /// Notification to toggle full screen state for a window.
    static let takoToggleFullscreen = Foundation.Notification.Name("com.tako-core.terminal.toggleFullscreen")
    static let FullscreenModeKey = takoToggleFullscreen.rawValue

    /// Notification to toggle split zoom state.
    static let didToggleSplitZoom = Foundation.Notification.Name("com.tako-core.terminal.didToggleSplitZoom")

    /// Notification when initial window frame is received.
    static let didReceiveInitialWindowFrame = Foundation.Notification.Name("com.tako-core.terminal.didReceiveInitialWindowFrame")
    static let FrameKey = "com.tako-core.terminal.frame"

    /// Notification requesting inspector UI display.
    static let inspectorNeedsDisplay = Foundation.Notification.Name("com.tako-core.terminal.inspectorNeedsDisplay")

    /// Notification to show or hide the inspector.
    static let didControlInspector = Foundation.Notification.Name("com.tako-core.terminal.didControlInspector")

    /// Notification requesting clipboard access confirmation.
    static let confirmClipboard = Foundation.Notification.Name("com.tako-core.terminal.confirmClipboard")
    static let ConfirmClipboardStrKey = confirmClipboard.rawValue + ".str"
    static let ConfirmClipboardStateKey = confirmClipboard.rawValue + ".state"
    static let ConfirmClipboardRequestKey = confirmClipboard.rawValue + ".request"

    /// Notification sent to resize a split. UserInfo keys `ResizeSplitDirectionKey` & `ResizeSplitAmountKey`.
    static let didResizeSplit = Foundation.Notification.Name("com.tako-core.terminal.didResizeSplit")
    static let ResizeSplitDirectionKey = didResizeSplit.rawValue + ".direction"
    static let ResizeSplitAmountKey = didResizeSplit.rawValue + ".amount"

    /// Notification to equalize split sizes across a container.
    static let didEqualizeSplits = Foundation.Notification.Name("com.tako-core.terminal.didEqualizeSplits")

    /// Notification emitted when renderer health state changes.
    static let didUpdateRendererHealth = Foundation.Notification.Name("com.tako-core.terminal.didUpdateRendererHealth")

    /// Key sequence notifications.
    static let didContinueKeySequence = Foundation.Notification.Name("com.tako-core.terminal.didContinueKeySequence")
    static let didEndKeySequence = Foundation.Notification.Name("com.tako-core.terminal.didEndKeySequence")
    static let KeySequenceKey = didContinueKeySequence.rawValue + ".key"

    /// Key table notifications.
    static let didChangeKeyTable = Foundation.Notification.Name("com.tako-core.terminal.didChangeKeyTable")
    static let KeyTableKey = didChangeKeyTable.rawValue + ".action"
}

extension Notification.Name {
    /// App-wide or surface-specific configuration change notification.
    static let takoConfigDidChange = Notification.Name("com.tako-core.terminal.configDidChange")
    static let TakoConfigChangeKey = takoConfigDidChange.rawValue

    /// Color scheme change notification.
    static let takoColorDidChange = Notification.Name("com.tako-core.terminal.takoColorDidChange")
    static let TakoColorChangeKey = takoColorDidChange.rawValue

    /// Move tab notification.
    static let takoMoveTab = Notification.Name("com.tako-core.terminal.moveTab")
    static let TakoMoveTabKey = takoMoveTab.rawValue

    /// Close tab notification.
    static let takoCloseTab = Notification.Name("com.tako-core.terminal.closeTab")

    /// Close other tabs notification.
    static let takoCloseOtherTabs = Notification.Name("com.tako-core.terminal.closeOtherTabs")

    /// Close tabs to the right of the focused tab
    static let takoCloseTabsOnTheRight = Notification.Name("com.tako-core.terminal.closeTabsOnTheRight")

    /// Close window notification.
    static let takoCloseWindow = Notification.Name("com.tako-core.terminal.closeWindow")

    /// Reset window size notification.
    static let takoResetWindowSize = Notification.Name("com.tako-core.terminal.resetWindowSize")

    /// Terminal bell notification.
    static let takoBellDidRing = Notification.Name("com.tako-core.terminal.takoBellDidRing")

    /// Terminal selection change notification.
    static let takoSelectionDidChange = Notification.Name("com.tako-core.terminal.takoSelectionDidChange")

    /// Readonly state change notification.
    static let takoDidChangeReadonly = Notification.Name("com.tako-core.terminal.didChangeReadonly")
    static let ReadonlyKey = takoDidChangeReadonly.rawValue + ".readonly"

    /// Command palette toggle notification.
    static let takoCommandPaletteDidToggle = Notification.Name("com.tako-core.terminal.commandPaletteDidToggle")

    /// Toggle maximize of current window
    static let takoMaximizeDidToggle = Notification.Name("com.tako-core.terminal.maximizeDidToggle")

    /// Notification sent when scrollbar updates
    static let takoDidUpdateScrollbar = Notification.Name("com.tako-core.terminal.didUpdateScrollbar")
    static let ScrollbarKey = takoDidUpdateScrollbar.rawValue + ".scrollbar"

    /// Focus the search field
    static let takoSearchFocus = Notification.Name("com.tako-core.terminal.searchFocus")

    /// Drag ended without drop target.
    static let takoSurfaceDragEndedNoTarget = Notification.Name("takoSurfaceDragEndedNoTarget")
    static let takoSurfaceDragEndedNoTargetPointKey = takoSurfaceDragEndedNoTarget.rawValue + ".point"
}
