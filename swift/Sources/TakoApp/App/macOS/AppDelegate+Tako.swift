import AppKit

// MARK: Tako Delegate

/// This implements the Tako app delegate protocol which is used by the Tako
/// APIs for app-global information.
extension AppDelegate: Tako.Delegate {
    func takoSurface(id: UUID) -> Tako.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }

            for surface in controller.surfaceTree where surface.id == id {
                return surface
            }
        }

        return nil
    }
}
