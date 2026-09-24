import SwiftUI
import TakoKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Tako.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Tako.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Tako.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var tako: Tako.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Tako.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.takoSurfaceView) private var focusedSurface
    @FocusedValue(\.takoSurfacePwd) private var surfacePwd
    @FocusedValue(\.takoSurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch tako.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Tako.info.mode == TAKO_BUILD_MODE_DEBUG || Tako.info.mode == TAKO_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        action: { handleSplitAction($0) })
                        .environmentObject(tako)
                        .takoLastFocusedSurface(lastFocusedSurface)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { handleFocusedSurfaceChange($0) }
                        .onChange(of: pwdURL) { handlePwdChange($0) }
                        .onChange(of: cellSize) { handleCellSizeChange($0) }
                        .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: tako.config.macosTitlebarStyle == .hidden ? .top : [])

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        takoConfig: tako.config) { action in
                        handlePerformAction(action, on: surfaceView)
                    }
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }

    /// Extracted out of the `.onChange` modifier closure so it can be
    /// exercised directly in tests -- SwiftUI only invokes `onChange`
    /// closures during a live view update cycle, which a plain `view.body`
    /// construction in a test host never triggers.
    func handleFocusedSurfaceChange(_ newValue: Tako.SurfaceView?) {
        // We want to keep track of our last focused surface so even if
        // we lose focus we keep this set to the last non-nil value.
        guard newValue != nil else { return }
        lastFocusedSurface = .init(newValue)
        delegate?.focusedSurfaceDidChange(to: newValue)
    }

    func handlePwdChange(_ newValue: URL?) {
        delegate?.pwdDidChange(to: newValue)
    }

    func handleCellSizeChange(_ newValue: NSSize?) {
        guard let size = newValue else { return }
        delegate?.cellSizeDidChange(to: size)
    }

    func handleSplitAction(_ action: TerminalSplitOperation) {
        delegate?.performSplitAction(action)
    }

    func handlePerformAction(_ action: String, on surfaceView: Tako.SurfaceView) {
        delegate?.performAction(action, on: surfaceView)
    }
}

struct DebugBuildWarningView: View {
    @State var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Tako! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Tako are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Tako are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture { handleTap() }
    }

    /// Extracted so tests can drive it directly -- `onTapGesture` closures
    /// are only invoked by an actual pointer/tap event on a hosted view.
    func handleTap() {
        isPopover = true
    }
}
