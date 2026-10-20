import AppKit
import Combine
import Foundation

// Drawing the crab, and getting it into the tab.
//
// Upstream already puts a horizontal stack in `tab.accessoryView` for the
// key-equivalent label and the zoom button, so the crab joins that stack
// instead of replacing the tab bar.

extension Tako {
    /// The crab in upstream's tab accessory stack: the classic strip's
    /// `CrabLayer`, so it looks and moves as the brand sheet has it.
    final class CrabView: NSView {
        var state: CrabState = .idle {
            didSet { if state != oldValue { refresh() } }
        }

        /// Set when something happened in this tab that the user has not
        /// seen; drawn as a dot beside the crab.
        var unread = false {
            didSet { if unread != oldValue { refresh() } }
        }

        let crab = CrabLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.addSublayer(crab)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // Whole pixels only: the mark is a pixel grid and any fractional
        // size turns it to mush.
        override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
        override var isFlipped: Bool { false }

        override func layout() {
            super.layout()
            refresh()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            refresh()
        }

        private func refresh() {
            let motion = LivingAnimationState.shared
            crab.apply(state: state, in: bounds, unread: unread, reduceMotion: motion.reduceMotion,
                       paused: motion.isTimelinePaused, scale: window?.backingScaleFactor ?? 2)
        }
    }

    /// Binds one surface's crab to the tab of the window it lives in.
    @MainActor
    final class CrabTabBinding {
        private let crabView = CrabView()
        private let progressLabel: NSTextField = {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            return label
        }()
        private var cancellables: Set<AnyCancellable> = []

        private static func surfaces(in window: NSWindow) -> [SurfaceView] {
            Tako.surfaces(in: window)
        }

        static func aggregateProgress(for surfaces: [SurfaceView]) -> (state: ProgressState, progress: Int?)? {
            guard !surfaces.isEmpty else { return nil }
            let eff: (SurfaceView) -> (state: ProgressState, progress: Int?) = { s in
                if s.crab.progressState != .none { return (s.crab.progressState, s.crab.progress) }
                return (s.activeProgressState, s.activeProgressValue)
            }
            if let err = surfaces.map(eff).first(where: { $0.state == .error }) {
                return (.error, err.progress)
            }
            if let paused = surfaces.map(eff).first(where: { $0.state == .paused }) {
                return (.paused, paused.progress)
            }
            let normalPanes = surfaces.map(eff).filter { $0.state == .normal }
            if !normalPanes.isEmpty {
                let values = normalPanes.compactMap { $0.progress }
                let avg = values.isEmpty ? nil : values.reduce(0, +) / values.count
                return (.normal, avg)
            }
            if surfaces.map(eff).contains(where: { $0.state == .indeterminate }) {
                return (.indeterminate, nil)
            }
            return nil
        }

        private func refresh(for surfaces: [SurfaceView]) {
            guard !surfaces.isEmpty else { return }
            let dominant = surfaces.max(by: { $0.crab.paneStatus.priority < $1.crab.paneStatus.priority }) ?? surfaces[0]
            crabView.state = dominant.crab.state
            crabView.unread = surfaces.contains(where: { $0.crab.unread })
            if let prog = Self.aggregateProgress(for: surfaces) {
                switch prog.state {
                case .none:
                    progressLabel.stringValue = ""
                case .normal:
                    progressLabel.stringValue = prog.progress.map { "\($0)%" } ?? ""
                case .error:
                    progressLabel.stringValue = prog.progress.map { "\($0)% !" } ?? "error"
                case .paused:
                    progressLabel.stringValue = prog.progress.map { "\($0)% ||" } ?? "paused"
                case .indeterminate:
                    progressLabel.stringValue = "..."
                }
            } else if let progress = dominant.crab.progress {
                progressLabel.stringValue = "\(progress)%"
            } else {
                progressLabel.stringValue = ""
            }
            progressLabel.isHidden = progressLabel.stringValue.isEmpty
        }

        /// Puts the crab at the head of upstream's tab accessory stack.
        ///
        /// A view can be re-added to the same window (splits, tab moves), so
        /// any crab already in this stack is removed first -- otherwise the
        /// tab collects one crab per call.
        init?(surface: SurfaceView, window: NSWindow) {
            guard let stack = window.tab.accessoryView as? NSStackView else { return nil }
            for existing in stack.arrangedSubviews {
                if existing is CrabView || existing === progressLabel {
                    stack.removeArrangedSubview(existing)
                    existing.removeFromSuperview()
                }
            }
            stack.insertArrangedSubview(crabView, at: 0)
            stack.insertArrangedSubview(progressLabel, at: 1)
            crabView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            crabView.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let allSurfaces = Self.surfaces(in: window)
            let surfacesToWatch = allSurfaces.contains(where: { $0 === surface }) ? allSurfaces : (allSurfaces + [surface])

            for s in surfacesToWatch {
                s.crab.$paneStatus
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh(for: surfacesToWatch) }
                    .store(in: &cancellables)
                s.crab.$unread
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh(for: surfacesToWatch) }
                    .store(in: &cancellables)
                s.crab.$state
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh(for: surfacesToWatch) }
                    .store(in: &cancellables)
                s.crab.$progress
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh(for: surfacesToWatch) }
                    .store(in: &cancellables)
                s.crab.$progressState
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh(for: surfacesToWatch) }
                    .store(in: &cancellables)
            }
            refresh(for: surfacesToWatch)
        }
    }
}
