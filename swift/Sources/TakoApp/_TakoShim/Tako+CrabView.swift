import AppKit
import Combine
import Foundation

// A tab's progress in upstream's tab accessory stack, beside the
// key-equivalent label and the zoom button. The crab that sat here is gone:
// tabs show the 1b ring (Tako.TabStatusLayer), in pills and classic tabs.

extension Tako {
    /// Binds one surface's progress to the tab of the window it lives in.
    @MainActor
    final class CrabTabBinding {
        static let labelIdentifier = NSUserInterfaceItemIdentifier("tako.tabProgress")
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

        /// Puts the progress at the head of upstream's tab accessory stack.
        ///
        /// A view can be re-added to the same window (splits, tab moves), so
        /// a label an earlier binding put there is removed first -- otherwise
        /// the tab collects one label per call.
        init?(surface: SurfaceView, window: NSWindow) {
            guard let stack = window.tab.accessoryView as? NSStackView else { return nil }
            for existing in stack.arrangedSubviews where existing.identifier == Self.labelIdentifier {
                stack.removeArrangedSubview(existing)
                existing.removeFromSuperview()
            }
            progressLabel.identifier = Self.labelIdentifier
            stack.insertArrangedSubview(progressLabel, at: 0)

            let allSurfaces = Self.surfaces(in: window)
            let surfacesToWatch = allSurfaces.contains(where: { $0 === surface }) ? allSurfaces : (allSurfaces + [surface])

            for s in surfacesToWatch {
                s.crab.$paneStatus
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
