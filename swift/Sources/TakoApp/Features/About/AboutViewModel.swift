import AppKit
import Combine

class AboutViewModel: ObservableObject {
    @Published var currentIcon: Tako.MacOSIcon?
    @Published var isHovering: Bool = false

    private var timerCancellable: AnyCancellable?

    // Upstream cycled through eight variants of its own artwork here. That
    // artwork is not ours, so only the app's own icon remains; the cycling
    // machinery stays because the About window is written against it.
    private let icons: [Tako.MacOSIcon] = [.official]

    func startCyclingIcons() {
        timerCancellable = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !isHovering else { return }
                advanceToNextIcon()
            }
    }

    func stopCyclingIcons() {
        timerCancellable = nil
        currentIcon = nil
    }

    /// The config line that selects the icon on show, if any.
    var currentIconConfig: String? {
        currentIcon.map { "macos-icon = \($0.rawValue)" }
    }

    /// Puts `currentIconConfig` on `pasteboard`, for pasting into a config.
    func copyCurrentIconConfig(to pasteboard: NSPasteboard = .general) {
        guard let config = currentIconConfig else { return }
        pasteboard.clearContents()
        pasteboard.setString(config, forType: .string)
    }

    func advanceToNextIcon() {
        let currentIndex = currentIcon.flatMap(icons.firstIndex(of:)) ?? 0
        let nextIndex = icons.indexWrapping(after: currentIndex)
        currentIcon = icons[nextIndex]
    }
}
