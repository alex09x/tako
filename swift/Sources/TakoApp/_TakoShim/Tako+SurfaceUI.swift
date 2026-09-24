import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The SwiftUI face of a surface. Upstream's split views compose these, so the
// shapes and names are its own; the contents are our `SurfaceView`.

extension UTType {
    /// Drag payload identifying a surface being dragged between splits.
    static let takoSurfaceId = UTType(exportedAs: "com.tako.surface-id")
}

extension Tako {
    /// Hosts a `SurfaceView` in SwiftUI.
    struct SurfaceWrapper: NSViewRepresentable {
        let surfaceView: SurfaceView
        var isSplit: Bool = false

        func makeNSView(context: Context) -> SurfaceView { surfaceView }
        func updateNSView(_ nsView: SurfaceView, context: Context) {}
    }

    /// The surface plus whatever debugging chrome the inspector adds. With the
    /// inspector closed this is just the surface.
    ///
    /// It also publishes the focused surface's state upward. That is how the
    /// window learns its title, its proxy icon and its cell size: upstream's
    /// controller reads these focused values, and with nothing publishing
    /// them a window keeps the placeholder title forever.
    struct InspectableSurface: View {
        @ObservedObject var surfaceView: SurfaceView
        var isSplit: Bool = false

        init(surfaceView: SurfaceView, isSplit: Bool = false) {
            self.surfaceView = surfaceView
            self.isSplit = isSplit
        }

        var body: some View {
            ZStack(alignment: .topTrailing) {
                SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
                if let searchState = surfaceView.searchState {
                    SurfaceSearchBar(surfaceView: surfaceView, searchState: searchState)
                        .padding(8)
                }
            }
            .focusedValue(\.takoSurfaceView, surfaceView)
            .focusedValue(\.takoSurfacePwd, surfaceView.pwd ?? "")
            .focusedValue(\.takoSurfaceCellSize, surfaceView.cellSize)
        }
    }

    /// The find bar over a surface. Return goes to the next (older) match,
    /// shift-return to the previous one, escape closes the bar.
    struct SurfaceSearchBar: View {
        let surfaceView: SurfaceView
        @ObservedObject var searchState: Tako.OSSurfaceView.SearchState
        @FocusState private var fieldFocused: Bool

        init(surfaceView: SurfaceView, searchState: Tako.OSSurfaceView.SearchState) {
            self.surfaceView = surfaceView
            self.searchState = searchState
        }

        var body: some View {
            HStack(spacing: 6) {
                TextField("Find", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .focused($fieldFocused)
                    .onSubmit { submit(shift: NSEvent.modifierFlags.contains(.shift)) }
                    .onExitCommand { surfaceView.findHide(surfaceView) }
                Text(Self.counter(selected: searchState.selected, total: searchState.total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { surfaceView.findPrevious(surfaceView) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Next Match Below")
                Button { surfaceView.findNext(surfaceView) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .help("Next Match Above")
                Button { surfaceView.findHide(surfaceView) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide Find Bar")
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .onAppear { fieldFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: .takoSearchFocus)) { note in
                if note.object as? SurfaceView === surfaceView { fieldFocused = true }
            }
        }

        func submit(shift: Bool) {
            if shift {
                surfaceView.findPrevious(surfaceView)
            } else {
                surfaceView.findNext(surfaceView)
            }
        }

        /// "2/5" with a match selected, "0/0" with none, blank before the
        /// first search has run.
        static func counter(selected: UInt?, total: UInt?) -> String {
            guard let total else { return "" }
            guard let selected, total > 0 else { return "0/\(total)" }
            return "\(selected + 1)/\(total)"
        }
    }

    /// Reports which surface is currently being dragged, so a split can hide
    /// its own drop zone.
    struct DraggingSurfaceKey: PreferenceKey {
        static var defaultValue: SurfaceView.ID? { nil }
        static func reduce(value: inout SurfaceView.ID?, nextValue: () -> SurfaceView.ID?) {
            value = nextValue() ?? value
        }
    }
}

extension Tako.SurfaceView: Transferable {
    /// A dragged surface travels as its identifier; the receiving window
    /// looks up the live view rather than moving a serialized copy.
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation<Tako.SurfaceView, String>(exporting: { surface in
            String(describing: surface.id)
        })
    }
}

// MARK: - Focused values

// SwiftUI carries the focused surface's state up to the window chrome, which
// is how the title bar knows the working directory and the resize overlay
// knows the cell size.

struct TakoSurfaceViewKey: FocusedValueKey {
    typealias Value = Tako.SurfaceView
}

struct TakoSurfacePwdKey: FocusedValueKey {
    typealias Value = String
}

struct TakoSurfaceCellSizeKey: FocusedValueKey {
    typealias Value = NSSize
}

extension FocusedValues {
    var takoSurfaceView: TakoSurfaceViewKey.Value? {
        get { self[TakoSurfaceViewKey.self] }
        set { self[TakoSurfaceViewKey.self] = newValue }
    }

    var takoSurfacePwd: TakoSurfacePwdKey.Value? {
        get { self[TakoSurfacePwdKey.self] }
        set { self[TakoSurfacePwdKey.self] = newValue }
    }

    var takoSurfaceCellSize: TakoSurfaceCellSizeKey.Value? {
        get { self[TakoSurfaceCellSizeKey.self] }
        set { self[TakoSurfaceCellSizeKey.self] = newValue }
    }
}

// MARK: - Last focused surface

/// The surface that most recently had focus, kept even after focus is lost so
/// menu actions still have a target.
struct TakoLastFocusedSurfaceKey: EnvironmentKey {
    static let defaultValue: Weak<Tako.SurfaceView>? = nil
}

extension EnvironmentValues {
    var takoLastFocusedSurface: Weak<Tako.SurfaceView>? {
        get { self[TakoLastFocusedSurfaceKey.self] }
        set { self[TakoLastFocusedSurfaceKey.self] = newValue }
    }
}

extension View {
    func takoLastFocusedSurface(_ surface: Weak<Tako.SurfaceView>?) -> some View {
        environment(\.takoLastFocusedSurface, surface)
    }
}
