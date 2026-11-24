/*
 * tako — Activity sound settings end-to-end check
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

/// Settings › Status & Activity › Sounds by real clicks: «Play sounds»
/// (activity-alert), a sound picked from an event's menu, None (▶ off), ▶,
/// and ↺; each is checked in the config file and in what the running app
/// reads (`takoctl config get`).
///
/// Private as the other settings journeys: private HOME, XDG dirs, history
/// and session namespace, panes not kept, the owner's shell history checked
/// on every exit. Every gesture -- scroll, click, menu item -- passes the
/// driver's ownership checks; nothing is pressed through AX. Nothing here
/// posts a notification or answers a permission prompt.
func runActivitySoundSettingsScenario(_ d: Driver) throws {
    d.quit()
    let saved = d.environment
    let home = d.path("sound-home"), sessions = d.path("sound-sessions")
    for dir in [home, home + "/.config", home + "/.local/share", home + "/.cache", sessions] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    d.environment["HOME"] = home
    d.environment["XDG_CONFIG_HOME"] = home + "/.config"
    d.environment["XDG_DATA_HOME"] = home + "/.local/share"
    d.environment["XDG_CACHE_HOME"] = home + "/.cache"
    d.environment["HISTFILE"] = home + "/.shell_history"
    d.environment["TAKO_SESSIONS_HOME"] = sessions
    defer { d.environment = saved }

    let owner = NSHomeDirectory()
    let ownerHistory = [".local/share/fish/fish_history", ".bash_history", ".zsh_history"].map { owner + "/" + $0 }
    func stamp() -> [String] {
        ownerHistory.map { path in
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "absent \(path)" }
            return "\(a[.size] ?? 0) \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(path)"
        }
    }
    let historyBefore = stamp()
    defer {
        let after = stamp()
        print("owner history: \(after == historyBefore ? "unchanged" : "CHANGED before=\(historyBefore) after=\(after)")")
    }

    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n"
                 + "session-persistence = false\n", settleTerminal: false)
    print("fixture app: pid \(d.pid), bundle \(d.bundleID), \(d.appURL.path)")
    d.setPosition(CGPoint(x: 100, y: 410))
    d.setSize(CGSize(width: 1000, height: 560))
    d.focus()
    usleep(800_000)
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    try d.run("echo \"$HOME|$XDG_DATA_HOME|$HISTFILE\" > \(d.path("sound_env"))")
    let seen = try d.file("sound_env").trimmingCharacters(in: .whitespacesAndNewlines)
    guard seen == "\(home)|\(home)/.local/share|\(home)/.shell_history" else { throw Failure("the shell is not private: \(seen)") }
    var persistent: [Bool] = []
    func collect(_ node: Any) {
        if let dict = node as? [String: Any] {
            if let flag = dict["persistentSession"] as? Bool { persistent.append(flag) }
            dict.values.forEach(collect)
        } else if let list = node as? [Any] { list.forEach(collect) }
    }
    collect(try JSONSerialization.jsonObject(with: Data(try d.exec("\(ctl) --json tree").utf8)))
    print("fixture panes: \(persistent.count), persistentSession: \(persistent)")
    guard !persistent.isEmpty, !persistent.contains(true) else { throw Failure("fixture panes must be non-persistent: \(persistent)") }

    d.key(Key.comma, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") != nil }, timeout: 5) else { throw Failure("Settings did not open") }
    let page = SettingsPage(d)
    page.placeWindow()

    let config = d.path("config")
    func file() -> String { (try? String(contentsOfFile: config, encoding: .utf8)) ?? "" }
    func applied(_ key: String) -> String { ((try? d.exec("\(ctl) config get \(key)")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func expect(_ key: String, file saved: String?, applied value: String, _ what: String) throws {
        let ok = d.wait(for: {
            let inFile = saved.map { file().contains("\(key) = \($0)") } ?? !file().contains(key)
            // A default reads «# key = value (default)».
            let effective = saved == nil ? applied(key) == "# \(key) = \(value) (default)" : applied(key).hasSuffix(value)
            return inFile && effective
        }, timeout: 5)
        print("\(what): \(ok ? "ok" : "FAILED") (file has key: \(file().contains(key)), applied: \(applied(key)))")
        if !ok { throw Failure("\(what): \(key) expected file \(saved ?? "absent"), applied \(value); got \(applied(key))") }
    }
    func playEnabled(_ event: String) -> Bool? {
        d.element(withIdentifier: "DesktopSetting-activity-sound-\(event)-play").flatMap { d.attribute($0, kAXEnabledAttribute) as Bool? }
    }

    try page.click("DesktopSettingsSection-activity")
    try page.click("DesktopSetting-activity-alert-never")
    try expect("activity-alert", file: "never", applied: "never", "Play sounds: Never")
    try page.click("DesktopSetting-activity-alert-unfocused")
    try expect("activity-alert", file: "unfocused", applied: "unfocused", "Play sounds: When Not Looking")
    try page.click("DesktopSetting-activity-alert-always")
    try expect("activity-alert", file: "always", applied: "always", "Play sounds: Always")

    try page.choose(menu: "DesktopSetting-activity-sound-needs-you", item: "Bottle")
    try expect("activity-sound-needs-you", file: "Bottle", applied: "Bottle", "Needs you: Bottle")
    guard playEnabled("needs-you") == true else { throw Failure("▶ is not enabled for Needs you") }
    try page.click("DesktopSetting-activity-sound-needs-you-play")
    try page.click("DesktopSettingReset-activity-sound-needs-you")
    try expect("activity-sound-needs-you", file: nil, applied: "Glass", "Needs you: ↺ back to Glass")
    guard d.wait(for: { playEnabled("needs-you") == true }, timeout: 3) else { throw Failure("▶ off after the reset") }

    try page.choose(menu: "DesktopSetting-activity-sound-done", item: "Pop")
    try expect("activity-sound-done", file: "Pop", applied: "Pop", "Done: Pop")
    guard playEnabled("done") == true else { throw Failure("▶ is not enabled for a chosen sound") }
    try page.click("DesktopSetting-activity-sound-done-play")

    try page.choose(menu: "DesktopSetting-activity-sound-failed", item: "None")
    try expect("activity-sound-failed", file: "none", applied: "none", "Failed: None")
    guard d.wait(for: { playEnabled("failed") == false }, timeout: 3) else { throw Failure("▶ stays enabled with None") }

    try page.click("DesktopSettingReset-activity-sound-done")
    try expect("activity-sound-done", file: nil, applied: "Hero", "Done: ↺ back to Hero")
    try page.click("DesktopSettingReset-activity-sound-failed")
    try expect("activity-sound-failed", file: nil, applied: "Basso", "Failed: ↺ back to Basso")
    try page.click("DesktopSettingReset-activity-alert")
    try expect("activity-alert", file: nil, applied: "unfocused", "Play sounds: ↺ back to When Not Looking")

    try page.click("DesktopSettingsClose")
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") == nil }, timeout: 5) else { throw Failure("Settings did not close") }
    guard stamp() == historyBefore else { throw Failure("the owner's shell history changed: \(stamp())") }
}
