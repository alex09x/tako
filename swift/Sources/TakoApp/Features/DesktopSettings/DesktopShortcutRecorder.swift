/*
 * tako — Shortcut recording with conflict review that never runs the typed action
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor
final class DesktopShortcutRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(action: String)
        /// The trigger already belongs to `holder`; the user must reassign or cancel.
        case conflict(action: String, trigger: String, holder: KeybindHolder)
    }

    struct KeybindHolder: Equatable {
        let id: String
        let title: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    /// The line under the list (reference `.pf-kmsg`): what just happened.
    @Published private(set) var status: String?
    let configFile: KeybindConfigFile
    private var monitor: Any?

    init(configFile: KeybindConfigFile) {
        self.configFile = configFile
    }

    /// Whether the key-down monitor that swallows presses is installed.
    var isMonitoring: Bool { monitor != nil }

    var recordingAction: String? {
        switch state {
        case .recording(let action), .conflict(let action, _, _): action
        case .idle: nil
        }
    }

    /// Starts recording. A local monitor swallows every key-down while
    /// recording so the menu or terminal never executes the typed shortcut.
    func begin(_ action: String, installMonitor: Bool = true) {
        state = .recording(action: action)
        lastError = nil
        status = "Press a shortcut. Esc to cancel, ⌫ to restore the default."
        guard installMonitor, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recordingAction != nil else { return event }
            _ = self.handle(keyCode: event.keyCode, modifiers: event.modifierFlags)
            return nil
        }
    }

    /// Returns true when the event was consumed by the recorder.
    @discardableResult
    func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if case .conflict = state {
            // Enter reassigns, Esc cancels; any other press is swallowed.
            if mods.isEmpty, keyCode == 36 || keyCode == 76 { confirmReassign() }
            else if mods.isEmpty, keyCode == 53 { cancel(message: "Reassignment canceled") }
            return true
        }
        guard case .recording(let action) = state else { return false }
        if keyCode == 53, mods.isEmpty {
            cancel(message: "Recording canceled")
            return true
        }
        if keyCode == 51, mods.isEmpty {
            reset(action)
            state = .idle
            stopMonitor()
            return true
        }
        guard let key = KeybindRegistry.keyName(for: keyCode) else {
            lastError = "This key cannot be assigned"
            return true
        }
        let isFunctionKey = key.hasPrefix("f") && Int(key.dropFirst()) != nil
        guard isFunctionKey || !mods.intersection([.command, .option, .control]).isEmpty else {
            lastError = "Add a ⌘, ⌥ or ⌃ modifier"
            return true
        }
        let trigger = Self.trigger(key: key, modifiers: mods)
        if let holder = configFile.findConflict(for: trigger, targetAction: action) {
            state = .conflict(action: action, trigger: trigger, holder: .init(id: holder.id, title: DesktopKeysCopy.title(holder.id)))
            status = "\(KeybindRegistry.format(trigger: trigger)) is assigned to “\(DesktopKeysCopy.title(holder.id))”. Enter to reassign, Esc to cancel."
            return true
        }
        commit(action: action, trigger: trigger)
        return true
    }

    /// Explicit reassignment: the trigger moves to `action`; the previous
    /// holder loses it (its default is shadowed, a custom line is removed).
    func confirmReassign() {
        guard case .conflict(let action, let trigger, _) = state else { return }
        commit(action: action, trigger: trigger)
    }

    func cancel(message: String? = nil) {
        state = .idle
        stopMonitor()
        if let message { status = message }
    }

    @discardableResult
    func reset(_ action: String) -> Bool {
        let ok = configFile.removeKeybind(action: action)
        lastError = ok ? nil : "Could not reset this shortcut"
        if ok { status = "Restored the default for “\(DesktopKeysCopy.title(action))”" + (display(for: action).map { " \($0)" } ?? "") }
        objectWillChange.send()
        return ok
    }

    @discardableResult
    func resetAll() -> Bool {
        let ok = configFile.resetAllKeybinds()
        lastError = ok ? nil : "Could not restore default shortcuts"
        objectWillChange.send()
        return ok
    }

    /// Custom override first, then the built-in default.
    func display(for action: String) -> String? {
        let canonical = KeybindConfigFile.canonicalActionName(action)
        if let custom = configFile.customOverrides[canonical] { return KeybindRegistry.format(trigger: custom) }
        return KeybindRegistry.defaultShortcut(for: action).map { KeybindRegistry.format(shortcut: $0) }
    }

    func isCustom(_ action: String) -> Bool {
        configFile.customOverrides[KeybindConfigFile.canonicalActionName(action)] != nil
    }

    static func trigger(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    private func commit(action: String, trigger: String) {
        if configFile.setKeybind(action: action, trigger: trigger) {
            lastError = nil
            status = "«\(DesktopKeysCopy.title(action))» — \(KeybindRegistry.format(trigger: trigger))"
        } else {
            lastError = "Could not save the shortcut to the configuration file"
        }
        state = .idle
        stopMonitor()
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
