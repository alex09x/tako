/*
 * tako — The workspace window-frame sync setting, set through native Settings
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import ApplicationServices
import Foundation

/// `workspace-sync-window-frame` as a person sets it: Cmd+, opens the native
/// Settings panel, its search finds the setting, the hit opens its row, and
/// the row's toggle or ↺ changes it. Used by settings-terminal-effects and
/// workspace-frame-sync.
///
/// Retired with the old in-terminal settings list (no supported entry opens
/// it any more), so not checked here: its Cmd+2 Terminal Settings tab, its
/// "N items / No matching settings" summary, Escape clearing its query, a
/// row click followed by Space toggling while the query stays, and `d`
/// resetting. Native Settings has none of these: Escape closes the panel,
/// opening a search hit clears the query, and the toggle and ↺ are buttons.
struct WorkspaceFrameSyncSetting {
    static let key = "workspace-sync-window-frame"
    static let alias = "workspace-inherit-window-frame"
    let d: Driver
    var page: SettingsPage { SettingsPage(d) }
    var toggle: String { "DesktopSetting-\(Self.key)" }

    var isOpen: Bool { d.element(withIdentifier: "DesktopSettingsRoot") != nil }

    func configLines() throws -> [String] {
        try String(contentsOfFile: d.path("config"), encoding: .utf8)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Cmd+, and the panel; `place` moves the host window into view, which a
    /// journey that measures window frames must not do.
    func open(place: Bool) throws {
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { isOpen }, timeout: 5) else { throw Failure("Cmd+, did not open Settings (no DesktopSettingsRoot)") }
        if place { page.placeWindow() }
    }

    /// Types `query` into Settings search by real keys and waits for the field to hold it.
    func search(_ query: String) throws {
        try page.enter("DesktopSettingsSearch", query, submit: false)
        guard d.wait(for: { page.value("DesktopSettingsSearch") == query }, timeout: 5) else {
            throw Failure("Settings search did not receive \(query.debugDescription): \(page.value("DesktopSettingsSearch").debugDescription)")
        }
    }

    /// Whether the panel says the current query found nothing.
    func showsNoResults(for query: String) -> Bool {
        guard let root = d.element(withIdentifier: "DesktopSettingsRoot") else { return false }
        return d.descendants(of: root, role: kAXStaticTextRole).contains {
            ((d.attribute($0, kAXValueAttribute) as String?) ?? "").contains("No results for “\(query)”")
        }
    }

    /// Searches "sync", opens the setting's hit, and waits for its row.
    func revealRow() throws {
        try search("sync")
        let hit = "DesktopSearchSetting-\(Self.key)"
        guard d.wait(for: { d.element(withIdentifier: hit) != nil }, timeout: 5) else { throw Failure("searching sync did not list \(Self.key)") }
        try page.click(hit)
        guard d.wait(for: { d.element(withIdentifier: toggle) != nil }, timeout: 5) else { throw Failure("the search hit did not open \(Self.key)'s row") }
    }

    func toggleValue() -> String { page.value(toggle) }

    /// Turns the setting on with its toggle; the file then holds `= true`.
    func enable() throws {
        guard toggleValue() == "0" else { throw Failure("\(Self.key) was not off before enabling: \(toggleValue().debugDescription)") }
        try page.click(toggle)
        guard d.wait(for: { toggleValue() == "1" && ((try? configLines()) ?? []).contains("\(Self.key) = true") }, timeout: 5) else {
            throw Failure("the toggle did not save \(Self.key) = true (toggle \(toggleValue().debugDescription))")
        }
    }

    /// ↺ restores the default: no line for the key or its alias remains.
    func reset() throws {
        try page.click("DesktopSettingReset-\(Self.key)")
        guard d.wait(for: {
            // An unreadable config proves nothing: only a successful read can show the lines are gone.
            guard toggleValue() == "0", let lines = try? configLines() else { return false }
            return !lines.contains { $0.hasPrefix(Self.key) || $0.hasPrefix(Self.alias) }
        }, timeout: 5) else { throw Failure("↺ did not reset \(Self.key) (toggle \(toggleValue().debugDescription))") }
    }

    func closeWithEscape() throws {
        d.key(Key.escape)
        guard d.wait(for: { !isOpen }, timeout: 5) else { throw Failure("Escape did not close Settings") }
    }
}

/// settings-terminal-effects: native Settings search, the persisted toggle
/// and its reset, and typing that reaches the shell afterwards.
func runSettingsTerminalEffectsScenario(_ d: Driver) throws {
    let setting = WorkspaceFrameSyncSetting(d: d)
    try setting.open(place: true)

    // A query with no results says so; clearing it by keys brings the page back.
    let nothing = "nonexistentqueryxyz"
    try setting.search(nothing)
    guard d.wait(for: { setting.showsNoResults(for: nothing) }, timeout: 5) else { throw Failure("the empty search did not say it found nothing") }
    try setting.page.click("DesktopSettingsSearch")
    d.key(Key.a, .maskCommand)
    d.key(51) // Delete
    guard d.wait(for: { setting.page.value("DesktopSettingsSearch").isEmpty && !setting.showsNoResults(for: nothing) }, timeout: 5) else {
        throw Failure("clearing the query did not restore the page")
    }

    // "sync" finds the setting; its hit opens the row; the toggle saves it.
    try setting.revealRow()
    try setting.enable()
    try setting.closeWithEscape()
    guard try setting.configLines().contains("\(WorkspaceFrameSyncSetting.key) = true") else {
        throw Failure("config file was not updated with \(WorkspaceFrameSyncSetting.key) = true")
    }

    // Reopened, ↺ removes the override and its alias from the file.
    try setting.open(place: true)
    try setting.revealRow()
    guard setting.toggleValue() == "1" else { throw Failure("the reopened row did not show the saved setting on") }
    try setting.reset()
    try setting.closeWithEscape()

    try d.run("echo 'settings_effects_ok' > \(d.path("settings_effects_witness"))")
    try d.expect("settings_effects_witness", "settings_effects_ok\n", "terminal keyboard input after settings effect journey")
}
