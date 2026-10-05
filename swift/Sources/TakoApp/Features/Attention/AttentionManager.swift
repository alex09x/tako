import AppKit
import Combine
import Foundation

/// Manages attention state, per-pane mute, already-seen tracking, and
/// cross-window attention navigation and jump history (B7).
@MainActor
final class AttentionManager: ObservableObject {
    static let shared = AttentionManager()

    /// Set of surface IDs that have attention muted (per-pane mute).
    @Published private(set) var mutedSurfaceIDs: Set<UUID> = []

    /// Attention event generation counter per surface.
    /// Incremented whenever a new attention-worthy event occurs (new notification,
    /// status change to error/needsApproval/waitingForInput, or crab unread).
    private var eventGenerations: [UUID: Int] = [:]

    /// The event generation when the surface was last seen/focused by the user.
    private var lastSeenGenerations: [UUID: Int] = [:]

    /// History stack of surfaces jumped from during attention navigation ("go back").
    private var backStack: [UUID] = []

    /// Forward stack to support toggling back and forth when invoking "go back".
    private var forwardStack: [UUID] = []

    init() {}

    // MARK: - Per-Pane Mute (B7)

    /// Checks if a surface is muted.
    func isMuted(surfaceId: UUID) -> Bool {
        mutedSurfaceIDs.contains(surfaceId)
    }

    /// Sets the mute state for a surface.
    func setMuted(_ muted: Bool, for surfaceId: UUID) {
        if muted {
            mutedSurfaceIDs.insert(surfaceId)
        } else {
            mutedSurfaceIDs.remove(surfaceId)
        }
        objectWillChange.send()
    }

    /// Toggles the mute state for a surface.
    func toggleMute(for surfaceId: UUID) {
        if isMuted(surfaceId: surfaceId) {
            setMuted(false, for: surfaceId)
        } else {
            setMuted(true, for: surfaceId)
        }
    }

    // MARK: - Event Generation & Seen Tracking (B7)

    /// Records that an attention event occurred on a surface (new notification,
    /// unread output, or status transition).
    func recordAttentionEvent(for surfaceId: UUID) {
        eventGenerations[surfaceId, default: 0] += 1
        objectWillChange.send()
    }

    /// Seeds an unseen attention event for a surface (e.g. when restoring unread notifications from disk).
    /// Ensures eventGeneration > lastSeenGeneration so isAlreadySeen returns false.
    func seedAttentionEvent(for surfaceId: UUID) {
        let lastSeen = lastSeenGenerations[surfaceId, default: 0]
        let currentGen = eventGenerations[surfaceId, default: 0]
        if currentGen <= lastSeen {
            eventGenerations[surfaceId] = lastSeen + 1
            objectWillChange.send()
        }
    }

    /// Marks a surface as seen up to its current event generation.
    func markSeen(surfaceId: UUID) {
        let currentGen = max(eventGenerations[surfaceId, default: 0], 1)
        eventGenerations[surfaceId] = currentGen
        lastSeenGenerations[surfaceId] = currentGen
        objectWillChange.send()
    }

    /// Marks a surface as seen.
    func markSeen(surface: Tako.SurfaceView) {
        markSeen(surfaceId: surface.id)
    }

    /// Checks if the attention state of this surface is already seen by the user.
    func isAlreadySeen(surfaceId: UUID) -> Bool {
        guard let lastSeen = lastSeenGenerations[surfaceId] else {
            // Surface has never been focused or marked seen by the user
            return false
        }
        let currentGen = eventGenerations[surfaceId, default: 0]
        return currentGen <= lastSeen
    }

    /// Checks whether a surface currently has active, unseen attention.
    /// Returns false if muted, currently focused, or already seen.
    func hasUnseenAttention(
        surface: Tako.SurfaceView,
        notificationStore: NotificationStore = .shared
    ) -> Bool {
        // Never lands on a muted pane
        if isMuted(surfaceId: surface.id) { return false }

        // Never lands on the currently focused pane
        if surface.isBeingLookedAt { return false }

        // Evaluate whether the surface is in an attention-worthy condition
        let unreadNotifs = notificationStore.unreadCount(for: surface.id) > 0
        let crabUnread = surface.crab.unread
        let crabAttention = surface.crab.state == .attention
        let status = surface.crab.paneStatus
        let statusAttention = (status == .error || status == .needsApproval || status == .waitingForInput)

        guard unreadNotifs || crabUnread || crabAttention || statusAttention else {
            return false
        }

        // Never lands on an already-seen pane
        return !isAlreadySeen(surfaceId: surface.id)
    }

    /// Checks if any pane across all windows currently has unseen attention.
    func hasAnyUnseenAttention(
        fromControllers customControllers: [BaseTerminalController]? = nil,
        notificationStore: NotificationStore = .shared
    ) -> Bool {
        !attentionSurfaces(fromControllers: customControllers, notificationStore: notificationStore).isEmpty
    }

    // MARK: - Surfaces Discovery (Across Windows & Tabs)

    /// Collects all open surfaces across all terminal windows and tabs in stable visual order.
    func allSurfaces(fromControllers customControllers: [BaseTerminalController]? = nil) -> [Tako.SurfaceView] {
        if let customControllers {
            var result: [Tako.SurfaceView] = []
            for controller in customControllers {
                for surface in controller.surfaceTree {
                    result.append(surface)
                }
            }
            return result
        }

        var result: [Tako.SurfaceView] = []
        var seenIDs = Set<UUID>()
        var controllers: [BaseTerminalController] = TerminalController.all
        if let app = NSApp?.delegate as? AppDelegate, app.quickControllerInitialized {
            controllers.append(app.quickController)
        }
        if let winControllers = NSApp?.windows.compactMap({ $0.windowController as? BaseTerminalController }) {
            for c in winControllers where !controllers.contains(where: { $0 === c }) {
                controllers.append(c)
            }
        }

        for controller in controllers {
            for surface in controller.surfaceTree {
                if !seenIDs.contains(surface.id) {
                    seenIDs.insert(surface.id)
                    result.append(surface)
                }
            }
        }
        return result
    }

    /// Collects all open surfaces that currently require attention and haven't been seen yet.
    func attentionSurfaces(
        fromControllers customControllers: [BaseTerminalController]? = nil,
        notificationStore: NotificationStore = .shared
    ) -> [Tako.SurfaceView] {
        allSurfaces(fromControllers: customControllers).filter {
            hasUnseenAttention(surface: $0, notificationStore: notificationStore)
        }
    }

    static func findSurface(byID id: UUID, inControllers customControllers: [BaseTerminalController]? = nil) -> Tako.SurfaceView? {
        let controllers: [BaseTerminalController]
        if let customControllers {
            controllers = customControllers
        } else {
            var all: [BaseTerminalController] = TerminalController.all
            if let winControllers = NSApp?.windows.compactMap({ $0.windowController as? BaseTerminalController }) {
                for c in winControllers where !all.contains(where: { $0 === c }) {
                    all.append(c)
                }
            }
            controllers = all
        }

        for controller in controllers {
            if let surface = controller.surfaceTree.first(where: { $0.id == id }) {
                return surface
            }
        }
        return nil
    }

    // MARK: - Navigation: Next & Previous Attention (B7)

    /// Finds the next surface needing attention across all windows in circular order.
    func nextAttentionSurface(
        from current: Tako.SurfaceView?,
        inControllers customControllers: [BaseTerminalController]? = nil,
        notificationStore: NotificationStore = .shared
    ) -> Tako.SurfaceView? {
        let candidates = attentionSurfaces(fromControllers: customControllers, notificationStore: notificationStore)
        guard !candidates.isEmpty else { return nil }

        let all = allSurfaces(fromControllers: customControllers)
        guard let current, let curIdx = all.firstIndex(where: { $0.id == current.id }) else {
            return candidates.first
        }

        // Circular search starting from curIdx + 1
        let count = all.count
        for offset in 1..<count {
            let candidateIdx = (curIdx + offset) % count
            let s = all[candidateIdx]
            if candidates.contains(where: { $0.id == s.id }) {
                return s
            }
        }

        return candidates.first(where: { $0.id != current.id })
    }

    /// Finds the previous surface needing attention across all windows in circular order.
    func previousAttentionSurface(
        from current: Tako.SurfaceView?,
        inControllers customControllers: [BaseTerminalController]? = nil,
        notificationStore: NotificationStore = .shared
    ) -> Tako.SurfaceView? {
        let candidates = attentionSurfaces(fromControllers: customControllers, notificationStore: notificationStore)
        guard !candidates.isEmpty else { return nil }

        let all = allSurfaces(fromControllers: customControllers)
        guard let current, let curIdx = all.firstIndex(where: { $0.id == current.id }) else {
            return candidates.last
        }

        // Circular search backwards starting from curIdx - 1
        let count = all.count
        for offset in 1..<count {
            let candidateIdx = (curIdx - offset + count) % count
            let s = all[candidateIdx]
            if candidates.contains(where: { $0.id == s.id }) {
                return s
            }
        }

        return candidates.last(where: { $0.id != current.id })
    }

    // MARK: - Jump History & Go Back (B7)

    /// Whether there is a previous pane to go back to.
    var canGoBack: Bool {
        backStack.contains { Self.findSurface(byID: $0) != nil } ||
        forwardStack.contains { Self.findSurface(byID: $0) != nil }
    }

    /// Records a jump from a source surface.
    func recordJump(from sourceId: UUID) {
        if backStack.last != sourceId {
            backStack.append(sourceId)
        }
        forwardStack.removeAll()
    }

    /// Resolves the previous pane the user was in before the jump.
    /// Updates history so that repeated invocations toggle or unwind cleanly.
    func resolveGoBackTarget(
        currentSurfaceId: UUID?,
        inControllers customControllers: [BaseTerminalController]? = nil
    ) -> Tako.SurfaceView? {
        // First try popping from backStack
        while let targetId = backStack.popLast() {
            if targetId == currentSurfaceId {
                continue
            }
            if let target = Self.findSurface(byID: targetId, inControllers: customControllers) {
                if let currentSurfaceId {
                    forwardStack.append(currentSurfaceId)
                }
                return target
            }
        }

        // If backStack is exhausted, try toggling from forwardStack
        while let targetId = forwardStack.popLast() {
            if targetId == currentSurfaceId {
                continue
            }
            if let target = Self.findSurface(byID: targetId, inControllers: customControllers) {
                if let currentSurfaceId {
                    backStack.append(currentSurfaceId)
                }
                return target
            }
        }

        return nil
    }

    /// Resets navigation history (e.g. for testing).
    func clearHistory() {
        backStack.removeAll()
        forwardStack.removeAll()
    }

    /// Resets all state (e.g. for testing).
    func reset() {
        mutedSurfaceIDs.removeAll()
        eventGenerations.removeAll()
        lastSeenGenerations.removeAll()
        clearHistory()
    }
}
