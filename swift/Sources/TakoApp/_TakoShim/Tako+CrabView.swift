import AppKit
import Combine
import Foundation

// Drawing the crab, and getting it into the tab.
//
// Upstream already puts a horizontal stack in `tab.accessoryView` for the
// key-equivalent label and the zoom button, so the crab joins that stack
// instead of replacing the tab bar.

extension Tako {
    /// The pixel-crab mark at tab size, tinted by state and animated per the
    /// brand sheet: it scurries while a command runs, hops on success,
    /// shivers on failure, pulses while reconnecting.
    final class CrabView: NSView {
        var state: CrabState = .idle {
            didSet {
                guard state != oldValue else { return }
                needsDisplay = true
                restartAnimation(for: state, from: oldValue)
            }
        }

        /// Set when something happened in this tab that the user has not
        /// seen; drawn as a dot beside the crab.
        var unread = false { didSet { needsDisplay = true } }

        private var phase = 0
        private var animation: Timer?
        /// Vertical offset for the hop, in points.
        private var hop: CGFloat = 0
        /// Horizontal offset for the shiver, in points.
        private var shiver: CGFloat = 0
        private var opacity: CGFloat = 1

        // Whole pixels only: the mark is a pixel grid and any fractional
        // size turns it to mush.
        override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
        override var isFlipped: Bool { false }

        deinit { animation?.invalidate() }

        private func restartAnimation(for state: CrabState, from previous: CrabState) {
            animation?.invalidate()
            animation = nil
            hop = 0; shiver = 0; opacity = 1; phase = 0

            switch state {
            case .running:
                // Scurrying: the legs alternate on a 0.8s cycle.
                animation = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.phase = (self.phase + 1) % 4
                        self.needsDisplay = true
                    }
                }
            case .succeeded, .attention:
                animate(steps: 12, interval: 1.0 / 60) { [weak self] t in
                    // One hop: up and back down.
                    self?.hop = sin(t * .pi) * 3
                }
            case .failed:
                animate(steps: 24, interval: 1.0 / 60) { [weak self] t in
                    // 0.4s shiver that decays.
                    self?.shiver = sin(t * .pi * 8) * 2 * (1 - t)
                }
            case .reconnecting:
                animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.phase = (self.phase + 1) % 60
                        self.opacity = 0.4 + 0.6 * (0.5 + 0.5 * cos(Double(self.phase) / 60 * 2 * .pi))
                        self.needsDisplay = true
                    }
                }
            case .ghost, .idle:
                break
            }
            _ = previous
        }

        /// Run `body` over `steps` frames with `t` going 0...1, then settle.
        private func animate(steps: Int, interval: TimeInterval, body: @escaping (Double) -> Void) {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            var frame = 0
            animation = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    frame += 1
                    body(Double(frame) / Double(steps))
                    self.needsDisplay = true
                    if frame >= steps {
                        timer.invalidate()
                        self.hop = 0; self.shiver = 0
                        self.needsDisplay = true
                    }
                }
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let tint = state.color.withAlphaComponent(opacity)

            // The mark is a 12x9 grid of pixels; only the cells that make the
            // crab are filled. Row 0 is the top.
            // Transcribed from assets/takocore-mark.svg. 2 is an eye,
            // which is a hole rather than a colour.
            let body: [[Int]] = [
                [1,1,0,0,0,0,0,0,1,1],
                [1,0,0,0,0,0,0,0,0,1],
                [0,1,0,0,0,0,0,0,1,0],
                [0,0,1,1,1,1,1,1,0,0],
                [0,0,1,2,1,1,2,1,0,0],
                [0,0,1,1,1,1,1,1,0,0],
                [0,1,0,1,0,0,1,0,1,0],
            ]
            // While running, the outer legs alternate to suggest motion.
            let legRow = body.count - 1
            let px = min(bounds.width / 10, bounds.height / 7)
            let originX = bounds.midX - px * 5 + shiver
            let originY = bounds.midY - px * 3.5 + hop

            ctx.setFillColor(tint.cgColor)
            for (r, row) in body.enumerated() {
                for (c, on) in row.enumerated() where on != 0 {
                    if state == .running, r == legRow {
                        // Lift alternating legs on alternating phases.
                        let lifted = (c + phase) % 2 == 0
                        if lifted { continue }
                    }
                    let rect = CGRect(x: originX + CGFloat(c) * px,
                                      y: originY + CGFloat(legRow - r) * px,
                                      width: px * 0.85, height: px * 0.85)
                    // An eye is the tab showing through, not a third colour.
                    if on == 2 { continue }
                    ctx.addRect(rect)
                }
            }
            ctx.fillPath()

            ctx.setBlendMode(.clear)
            for (r, row) in body.enumerated() {
                for (c, on) in row.enumerated() where on == 2 {
                    ctx.fill(CGRect(x: originX + CGFloat(c) * px,
                                    y: originY + CGFloat(legRow - r) * px,
                                    width: px * 0.85, height: px * 0.85))
                }
            }
            ctx.setBlendMode(.normal)

            if unread {
                ctx.setFillColor(Brand.claw.cgColor)
                ctx.fillEllipse(in: CGRect(x: bounds.maxX - 4, y: bounds.maxY - 4, width: 3, height: 3))
            }
        }
    }

    /// Binds one surface's crab to the tab of the window it lives in.
    @MainActor
    final class CrabTabBinding {
        private let crabView = CrabView()
        private let elapsedLabel: NSTextField = {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            return label
        }()
        private var cancellables: Set<AnyCancellable> = []

        /// Puts the crab at the head of upstream's tab accessory stack.
        ///
        /// A view can be re-added to the same window (splits, tab moves), so
        /// any crab already in this stack is removed first -- otherwise the
        /// tab collects one crab per call.
        init?(surface: SurfaceView, window: NSWindow) {
            guard let stack = window.tab.accessoryView as? NSStackView else { return nil }
            for existing in stack.arrangedSubviews {
                if existing is CrabView || existing === elapsedLabel {
                    stack.removeArrangedSubview(existing)
                    existing.removeFromSuperview()
                }
            }
            stack.insertArrangedSubview(crabView, at: 0)
            stack.insertArrangedSubview(elapsedLabel, at: 1)
            crabView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            crabView.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let crab = surface.crab
            crab.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.crabView.state = $0 }
                .store(in: &cancellables)
            crab.$unread
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.crabView.unread = $0 }
                .store(in: &cancellables)
            // The timer text and the progress share one slot: progress wins
            // when the program reports it, because it says more.
            crab.$elapsed
                .combineLatest(crab.$progress)
                .receive(on: RunLoop.main)
                .sink { [weak self] _, progress in
                    guard let self else { return }
                    if let progress {
                        self.elapsedLabel.stringValue = "\(progress)%"
                    } else {
                        self.elapsedLabel.stringValue = crab.elapsedLabel ?? ""
                    }
                    self.elapsedLabel.isHidden = self.elapsedLabel.stringValue.isEmpty
                }
                .store(in: &cancellables)
        }
    }
}
