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
import ApplicationServices
import Foundation

// MARK: - Scenarios 1–4: Tab Status Click, In-Terminal Dialogs, Tab Drag Reorder, Safe Paste Guard

private let pillTabConfig = "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\ntab-style = pill\n"

private func launchCleanPillTabs(_ d: Driver, size: CGSize = CGSize(width: 800, height: 500)) throws -> String {
    d.quit()
    try d.launch(config: pillTabConfig)
    d.setPosition(CGPoint(x: 100, y: 100))
    d.setSize(size)
    d.focus()
    usleep(800_000)
    return "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
}

func runTabStatusClickScenario(_ d: Driver) throws {
    let ctl = try launchCleanPillTabs(d)
    try d.run("tty > \(d.path("tsc_tab0_tty"))")
    let tab0Tty = try d.file("tsc_tab0_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("failed to resolve Tab 0 pane ID") }

    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else {
        throw Failure("Tab 1 pill element did not appear after Cmd+T")
    }
    usleep(800_000)
    try d.run("tty > \(d.path("tsc_tab1_tty"))")
    let tab1Tty = try d.file("tsc_tab1_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane1 = try d.focusedPaneId(), pane1 != pane0, tab1Tty != tab0Tty else {
        throw Failure("Tab 1 did not create a distinct pane/TTY")
    }

    // Switch back to Tab 0 via real mouse click so Tab 1 is in background
    try d.clickTab(index: 0)
    guard d.wait(for: { (try? d.focusedPaneId()) == pane0 }, timeout: 5) else {
        throw Failure("clicking Tab 0 did not focus pane0")
    }

    let initTab1 = try d.exec("\(ctl) status tab --target \(pane1) --json")
    guard initTab1.contains("\"status\":\"idle\"") && initTab1.contains("\"dot\":\"dim\"") && initTab1.contains("\"selected\":false"),
          d.wait(for: { d.paintedTabDot(index: 1) == "dot:#8a7f76" }, timeout: 5) else {
        throw Failure("expected Tab 1 initial idle/dim/unselected state and painted #8a7f76 dot, got: \(initTab1), painted=\(d.paintedTabDot(index: 1) ?? "nil")")
    }

    _ = try d.exec("\(ctl) status set working --text compiling --target \(pane1) --json")
    let workTab1 = try d.exec("\(ctl) status tab --target \(pane1) --json")
    guard workTab1.contains("\"status\":\"working\"") && workTab1.contains("\"dot\":\"ember\"") && workTab1.contains("\"color\":\"orange\""),
          d.wait(for: { d.paintedTabDot(index: 1) == "dot:#f4581c" && d.paintedTabDot(index: 0) == "dot:#8a7f76" }, timeout: 5) else {
        throw Failure("expected Tab 1 working/ember/orange and painted #f4581c dot, got: \(workTab1), painted1=\(d.paintedTabDot(index: 1) ?? "nil"), painted0=\(d.paintedTabDot(index: 0) ?? "nil")")
    }

    let activeTab0 = try d.exec("\(ctl) status tab --target \(pane0) --json")
    guard activeTab0.contains("\"status\":\"idle\"") && activeTab0.contains("\"dot\":\"dim\"") && activeTab0.contains("\"selected\":true") else {
        throw Failure("negative control failed: Tab 0 status was polluted by Tab 1 update: \(activeTab0)")
    }

    _ = try d.exec("\(ctl) status set waiting_for_input --target \(pane1) --json")
    let waitTab1 = try d.exec("\(ctl) status tab --target \(pane1) --json")
    guard waitTab1.contains("\"status\":\"waiting_for_input\"") && waitTab1.contains("\"dot\":\"claw\"") && waitTab1.contains("\"color\":\"amber\""),
          d.wait(for: { d.paintedTabDot(index: 1) == "dot:#ff7a3d" }, timeout: 5) else {
        throw Failure("expected Tab 1 waiting_for_input/claw/amber and painted #ff7a3d dot, got: \(waitTab1), painted=\(d.paintedTabDot(index: 1) ?? "nil")")
    }

    _ = try d.exec("\(ctl) status set done --target \(pane1) --json")
    let doneTab1 = try d.exec("\(ctl) status tab --target \(pane1) --json")
    guard doneTab1.contains("\"status\":\"done\"") && doneTab1.contains("\"unread\":true") && doneTab1.contains("\"dot\":\"ok\""),
          d.wait(for: { d.paintedTabDot(index: 1) == "dot:#7bd88f" }, timeout: 5) else {
        throw Failure("expected Tab 1 done/unread/ok and painted #7bd88f dot, got: \(doneTab1), painted=\(d.paintedTabDot(index: 1) ?? "nil")")
    }

    try d.clickTab(index: 1)
    guard d.wait(for: {
        guard let js = try? d.exec("\(ctl) status tab --target \(pane1) --json") else { return false }
        return js.contains("\"status\":\"idle\"") && js.contains("\"unread\":false") && js.contains("\"dot\":\"dim\"") && js.contains("\"selected\":true") && d.paintedTabDot(index: 1) == "dot:#8a7f76"
    }, timeout: 5) else {
        let cur = (try? d.exec("\(ctl) status tab --target \(pane1) --json")) ?? "nil"
        throw Failure("clicking Tab 1 did not reset done/unread to idle/dim (#8a7f76): \(cur), painted=\(d.paintedTabDot(index: 1) ?? "nil")")
    }

    try d.run("tty > \(d.path("tsc_rec_tty")) && echo 'tab_status_click_ok' > \(d.path("tsc_witness"))")
    try d.expect("tsc_witness", "tab_status_click_ok\n", "unassisted keyboard input after clicking Tab 1")
    guard try d.file("tsc_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines) == tab1Tty else {
        throw Failure("expected unassisted typing in Tab 1 TTY (\(tab1Tty))")
    }
}

func runTerminalDialogsScenario(_ d: Driver) throws {
    let ctl = try launchCleanPillTabs(d)
    try d.run("tty > \(d.path("dlg_init_tty"))")
    let initTty = try d.file("dlg_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)

    // Part A: Rename Tab via in-terminal TerminalDialogView.askText
    d.activate()
    usleep(200_000)
    guard d.pressMenuItem(titledPrefix: "Change Tab Title") else { throw Failure("failed to invoke Change Tab Title...") }
    var saveBtn: AXUIElement?
    guard d.wait(for: { saveBtn = d.button(titled: "Save"); return saveBtn != nil && d.hasText(containing: "Rename Tab") }, timeout: 5), let saveBtn else {
        throw Failure("Rename Tab in-terminal dialog did not appear")
    }
    try d.assertInTerminalDialog(title: "Rename Tab", bodyContains: "Title")
    try d.type("CustomRenamedTab")
    usleep(200_000)
    d.press(saveBtn)
    guard d.wait(for: { d.button(titled: "Save") == nil }, timeout: 5),
          d.wait(for: { ((try? d.exec("\(ctl) tree --json")) ?? "").contains("CustomRenamedTab") }, timeout: 5) else {
        throw Failure("Rename Tab did not save 'CustomRenamedTab'")
    }

    guard d.pressMenuItem(titledPrefix: "Change Tab Title"), d.wait(for: { d.button(titled: "Save") != nil }, timeout: 5) else {
        throw Failure("Rename Tab dialog did not reopen")
    }
    d.key(Key.delete)
    usleep(150_000)
    d.key(Key.returnKey)
    guard d.wait(for: { d.button(titled: "Save") == nil }, timeout: 5),
          d.wait(for: { !((try? d.exec("\(ctl) tree --json")) ?? "").contains("CustomRenamedTab") }, timeout: 5) else {
        throw Failure("empty Rename Tab submission did not clear custom title override")
    }

    // Part B: Multi-window Quit Confirmation (Cmd+Q with 2 busy windows)
    try d.run("sleep 60")
    usleep(500_000)
    d.key(Key.n, .maskCommand)
    guard d.wait(for: { d.windows().count == 2 }, timeout: 5) else { throw Failure("Cmd+N did not open second window") }
    usleep(600_000)
    try d.run("sleep 60")
    usleep(600_000)

    d.key(Key.q, .maskCommand)
    var cancelQuitBtn: AXUIElement?
    guard d.wait(for: {
        cancelQuitBtn = d.button(titled: "Cancel")
        return cancelQuitBtn != nil && d.button(titled: "Review Windows…") != nil && d.button(titled: "Terminate Processes") != nil
    }, timeout: 5), let cancelQuitBtn else {
        throw Failure("multi-window Quit Tako? dialog did not appear")
    }
    try d.assertInTerminalDialog(title: "Quit Tako?", bodyContains: "running")
    d.press(cancelQuitBtn)
    guard d.wait(for: { d.button(titled: "Terminate Processes") == nil }, timeout: 5), d.isRunning && d.windows().count == 2 else {
        throw Failure("Cancel on Quit Tako? did not preserve both running windows")
    }

    d.key(Key.c, .maskControl)
    usleep(300_000)
    d.key(Key.w, .maskCommand)
    guard d.wait(for: { d.windows().count == 1 }, timeout: 5) else { throw Failure("Window 2 did not close") }
    usleep(300_000)
    d.key(Key.c, .maskControl)
    usleep(300_000)

    // Part C: Connect AI Agents menu dialog (isolated to agent-hooks-home)
    let fm = FileManager.default
    let realHome = fm.homeDirectoryForCurrentUser.path
    let realPaths = [".gemini/config/hooks.json", ".gemini/settings.json", ".claude/settings.json", ".codex/hooks.json"].map {
        (realHome as NSString).appendingPathComponent($0)
    }
    let beforeReal = realPaths.map { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    let isolatedRoot = d.path("agent-hooks-home")
    try fm.createDirectory(atPath: (isolatedRoot as NSString).appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try fm.createDirectory(atPath: (isolatedRoot as NSString).appendingPathComponent(".codex"), withIntermediateDirectories: true)

    guard d.pressMenuItem(titledPrefix: "Connect AI Agents") else { throw Failure("failed to invoke Connect AI Agents…") }
    var okBtn: AXUIElement?
    guard d.wait(for: { okBtn = d.button(titled: "OK"); return okBtn != nil }, timeout: 5), let okBtn else {
        throw Failure("Connect AI Agents dialog did not present OK button")
    }
    try d.assertInTerminalDialog(title: "AI Agents Connected", bodyContains: "Configured hooks for")
    d.press(okBtn)
    guard d.wait(for: { d.button(titled: "OK") == nil }, timeout: 5) else {
        throw Failure("Connect AI Agents dialog did not dismiss after clicking OK")
    }
    guard fm.fileExists(atPath: (isolatedRoot as NSString).appendingPathComponent(".claude/settings.json")),
          fm.fileExists(atPath: (isolatedRoot as NSString).appendingPathComponent(".codex/hooks.json")) else {
        throw Failure("Connect AI Agents did not write hooks into isolated agent-hooks-home")
    }
    let afterReal = realPaths.map { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    guard beforeReal == afterReal else {
        throw Failure("Connect AI Agents modified real user hook config files")
    }

    try d.run("tty > \(d.path("dlg_rec_tty")) && echo 'dialogs_ok' > \(d.path("dlg_witness"))")
    try d.expect("dlg_witness", "dialogs_ok\n", "unassisted keyboard recovery after terminal dialogs")
    guard try d.file("dlg_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines) == initTty else {
        throw Failure("recovered TTY did not match initial TTY (\(initTty))")
    }
}

func runTabDragReorderScenario(_ d: Driver) throws {
    let ctl = try launchCleanPillTabs(d)
    try d.run("tty > \(d.path("drag_t0_tty"))")
    let tty0 = try d.file("drag_t0_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no pane0 ID") }

    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else {
        throw Failure("tab-1 did not appear after Cmd+T")
    }
    usleep(800_000)
    try d.run("tty > \(d.path("drag_t1_tty"))")
    let tty1 = try d.file("drag_t1_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane1 = try d.focusedPaneId(), pane1 != pane0, tty1 != tty0 else { throw Failure("no distinct pane1 ID/TTY") }

    func orderedTabPanes() -> [String] {
        guard let js = try? d.exec("\(ctl) tree --json"),
              let data = js.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let root = (obj["result"] as? [String: Any]) ?? obj
        guard let wins = root["windows"] as? [[String: Any]],
              let tabs = wins.first?["tabs"] as? [[String: Any]] else { return [] }
        return tabs.compactMap { (($0["panes"] as? [[String: Any]])?.first)?["id"] as? String }
    }

    guard orderedTabPanes() == [pane0, pane1] else {
        throw Failure("initial tab order was not [pane0, pane1]: \(orderedTabPanes())")
    }

    // Drag tab-0 across tab-1 to swap order
    let pt0 = try d.tabClickPoint(index: 0)
    let pt1 = try d.tabClickPoint(index: 1)
    try d.drag(from: pt0, to: CGPoint(x: pt1.x + 35, y: pt1.y), steps: 16)
    guard d.wait(for: { orderedTabPanes() == [pane1, pane0] }, timeout: 5) else {
        throw Failure("dragging tab-0 onto tab-1 did not reorder tabs to [pane1, pane0]: got \(orderedTabPanes())")
    }
    usleep(400_000)

    // Drag tab-1 back onto tab-0 to restore original order
    let pt0After = try d.tabClickPoint(index: 0)
    let pt1After = try d.tabClickPoint(index: 1)
    try d.drag(from: pt1After, to: CGPoint(x: max(20, pt0After.x - 15), y: pt0After.y), steps: 16)
    guard d.wait(for: { orderedTabPanes() == [pane0, pane1] }, timeout: 5) else {
        throw Failure("dragging tab-1 (\(pt1After)) back onto tab-0 (\(pt0After)) did not restore [pane0, pane1]: got \(orderedTabPanes())")
    }

    try d.clickTab(index: 1)
    guard d.wait(for: { (try? d.focusedPaneId()) == pane1 }, timeout: 5) else {
        throw Failure("clicking tab-1 after drag reorder did not focus pane1")
    }
    try d.run("tty > \(d.path("drag_rec_tty")) && echo 'drag_reorder_ok' > \(d.path("drag_witness"))")
    try d.expect("drag_witness", "drag_reorder_ok\n", "unassisted keyboard input after tab drag reorder")
    guard try d.file("drag_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines) == tty1 else {
        throw Failure("expected Tab 1 TTY (\(tty1)) after reorder")
    }
}

func runSafePasteGuardScenario(_ d: Driver) throws {
    _ = try launchCleanPillTabs(d)
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    let leak1 = d.path("sp_line1.txt")
    let leak2 = d.path("sp_line2.txt")
    try d.run("exec zsh -f")
    usleep(400_000)
    try d.run("PROMPT=$'%{\\033]133;D;0\\007\\033]133;A\\007%}> '")
    usleep(400_000)

    pasteboard.clearContents()
    pasteboard.setString("echo pasted1 > \(leak1)\necho pasted2 > \(leak2)\n", forType: .string)

    d.key(Key.v, .maskCommand)
    var cancelBtn: AXUIElement?
    guard d.wait(for: {
        cancelBtn = d.button(titled: "Cancel")
        return cancelBtn != nil && d.button(titled: "Paste") != nil && d.hasText(containing: "Pasting this text to the terminal may be dangerous.")
    }, timeout: 5), let cancelBtn else {
        throw Failure("Safe Paste confirmation dialog did not appear on multiline Cmd+V")
    }
    guard !FileManager.default.fileExists(atPath: leak1) && !FileManager.default.fileExists(atPath: leak2) else {
        throw Failure("multiline paste executed before user confirmed Paste")
    }

    d.press(cancelBtn)
    guard d.wait(for: { d.button(titled: "Paste") == nil }, timeout: 5) else {
        throw Failure("Safe Paste dialog did not dismiss after Cancel")
    }
    usleep(300_000)
    guard !FileManager.default.fileExists(atPath: leak1) else {
        throw Failure("Safe Paste executed payload despite Cancel")
    }

    d.key(Key.v, .maskCommand)
    var pasteBtn2: AXUIElement?
    guard d.wait(for: { pasteBtn2 = d.button(titled: "Paste"); return pasteBtn2 != nil }, timeout: 5), let pasteBtn2 else {
        throw Failure("Safe Paste dialog did not reappear on second Cmd+V")
    }
    d.press(pasteBtn2)
    guard d.wait(for: { d.button(titled: "Paste") == nil }, timeout: 5) else {
        throw Failure("Safe Paste dialog did not dismiss after clicking Paste")
    }
    d.key(Key.returnKey)
    try d.expect("sp_line1.txt", "pasted1\n", "first line of approved multiline paste")
    try d.expect("sp_line2.txt", "pasted2\n", "second line of approved multiline paste")
    try d.run("echo 'safe_paste_recovered' > \(d.path("sp_recovered.txt"))")
    try d.expect("sp_recovered.txt", "safe_paste_recovered\n", "unassisted keyboard input after safe paste")
}
