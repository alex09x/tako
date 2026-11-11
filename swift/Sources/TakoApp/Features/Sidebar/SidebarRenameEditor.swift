/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine

/// One rename in progress: which row, in which sidebar, and the text typed
/// so far. Started by a double-click, F2 or a row's «Rename» item.
///
/// - The edit belongs to the sidebar it was started in: another window
///   listing the same row keeps showing its name.
/// - The draft lives here, not in the field: a row that moves to another
///   status group mid-typing gets a new field with the same draft, and the
///   old field's going away does not end the edit.
/// - A name that cannot be saved keeps the edit open, with the draft and the
///   reason.
/// - Only the field observes the draft; the sidebar redraws when an edit
///   starts or ends, not on every key.
@MainActor
final class SidebarRenameEditor: ObservableObject {
    static let shared = SidebarRenameEditor()

    struct Edit: Equatable {
        let rowId: String
        let window: ObjectIdentifier?
    }

    final class Draft: ObservableObject {
        @Published var text = ""
        @Published var error: String?
    }

    @Published private(set) var edit: Edit?
    let draft = Draft()
    /// The field showing the edit now; an older one's blur is ignored.
    private(set) var activeMount = 0
    private var mounts = 0
    /// Where pane names are kept (tests give a private store).
    var paneTitles: PaneTitleStore = .shared

    func isEditing(_ rowId: String, in window: NSWindow?) -> Bool {
        edit == Edit(rowId: rowId, window: window.map(ObjectIdentifier.init))
    }

    /// Whether this window's sidebar shows a rename field, whose keys --
    /// Return, the arrows, F2 -- its list then leaves alone. An edit kept
    /// open in another window (say, after a failed save) does not count.
    func isEditing(in window: NSWindow?) -> Bool {
        guard let edit else { return false }
        return edit.window == window.map(ObjectIdentifier.init)
    }

    func begin(_ item: SessionSidebarItem, in window: NSWindow?, store: SessionSidebarStore) {
        guard store.canRename(item, around: window) else { return }
        draft.text = store.ownName(of: item, around: window, paneTitles: paneTitles) ?? item.title
        draft.error = nil
        dropPendingBlur()
        generation += 1
        edit = Edit(rowId: item.id, window: window.map(ObjectIdentifier.init))
    }

    func cancel() {
        dropPendingBlur()
        generation += 1
        edit = nil
        draft.error = nil
    }

    /// Keeps the draft as the row's name. False when it could not be kept:
    /// the edit stays, with the draft and the reason.
    @discardableResult
    func commit(_ item: SessionSidebarItem, in window: NSWindow?, store: SessionSidebarStore) -> Bool {
        if let error = store.setName(draft.text, of: item, around: window, paneTitles: paneTitles) {
            draft.error = error
            return false
        }
        cancel()
        return true
    }

    /// «Use Automatic Name». If that cannot be saved either, the row opens
    /// for editing with the reason, rather than looking reset.
    func useAutomaticName(_ item: SessionSidebarItem, in window: NSWindow?, store: SessionSidebarStore) {
        guard let error = store.setName("", of: item, around: window, paneTitles: paneTitles) else { return }
        begin(item, in: window, store: store)
        draft.error = error
    }

    /// A field showing the edit appeared: it is now the one that counts.
    func mounted() -> Int {
        mounts += 1
        activeMount = mounts
        return mounts
    }

    /// A field lost focus. Clicking away ends the edit; a field merely
    /// replaced by a new one (its row changed group), or one that gets the
    /// focus back before the pause is over, does not.
    func blurred(mount: Int) {
        pendingBlur?.invalidate()
        let generation = self.generation
        // A run-loop timer, not the main queue: it also fires inside a nested
        // run loop (a menu, a modal), where main-queue work waits.
        let timer = Timer(timeInterval: blurPause, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.edit != nil,
                      self.activeMount == mount, self.draft.error == nil else { return }
                self.cancel()
            }
        }
        pendingBlur = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The field has the focus (again): a click-away still pending is void.
    func focused(mount: Int) {
        guard mount == activeMount else { return }
        dropPendingBlur()
    }

    /// How long a field may be without focus before the edit ends.
    let blurPause: TimeInterval = 0.15
    private var pendingBlur: Timer?
    /// Bumped whenever an edit begins or ends: a pause from an earlier edit
    /// never ends a later one.
    private(set) var generation = 0

    private func dropPendingBlur() {
        pendingBlur?.invalidate()
        pendingBlur = nil
    }
}
