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

// MARK: - Scenarios 5–8: Sidebar Interaction, Overview Selection, Attention Jump, Input Takeover & Confirm

extension Driver {
    func clickElement(_ element: AXUIElement) throws {
        guard let posVal: AXValue = attribute(element, kAXPositionAttribute),
              let sizeVal: AXValue = attribute(element, kAXSizeAttribute) else {
            throw Failure("cannot get AX position/size for element")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &pos)
        AXValueGetValue(sizeVal, .cgSize, &size)
        try click(at: CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2))
    }
}

private let humanTestConfig = "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\ntab-style = pill\n"

private func launchCleanHumanWindow(_ d: Driver, size: CGSize = CGSize(width: 840, height: 520)) throws -> String {
    d.quit()
    try d.launch(config: humanTestConfig)
    d.setPosition(CGPoint(x: 100, y: 100))
    d.setSize(size)
    d.focus()
    usleep(800_000)
    if d.hasText(containing: "Sessions") {
        d.key(Key.s, [.maskCommand, .maskAlternate])
        _ = d.wait(for: { !d.hasText(containing: "Sessions") }, timeout: 3)
    }
    return "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
}

func runSidebarInteractionScenario(_ d: Driver) throws {
    let ctl = try launchCleanHumanWindow(d)
    defer {
        if d.hasText(containing: "Sessions") {
            d.key(Key.s, [.maskCommand, .maskAlternate])
            usleep(200_000)
        }
    }
    let alphaDir = d.path("sb_alpha_dir")
    let betaDir = d.path("sb_beta_dir")
    try FileManager.default.createDirectory(atPath: alphaDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: betaDir, withIntermediateDirectories: true)

    guard let pane0 = try d.focusedPaneId() else { throw Failure("failed to get pane0 ID") }
    _ = try d.exec("\(ctl) split right --child-of \(pane0) --label sub-worker")
    usleep(400_000)
    _ = try d.exec("\(ctl) focus --target \(pane0)")
    usleep(300_000)
    try d.run("cd \(alphaDir) && tty > \(d.path("sb_t0_tty"))")
    let tty0 = try d.file("sb_t0_tty").trimmingCharacters(in: .whitespacesAndNewlines)

    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else {
        throw Failure("Tab 1 did not appear in sidebar scenario")
    }
    usleep(800_000)
    try d.run("cd \(betaDir) && tty > \(d.path("sb_t1_tty"))")
    let tty1 = try d.file("sb_t1_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane1 = try d.focusedPaneId(), pane1 != pane0, tty1 != tty0 else {
        throw Failure("Tab 1 did not create distinct pane/TTY")
    }

    // Open Session Sidebar via Cmd+Opt+S
    d.key(Key.s, [.maskCommand, .maskAlternate])
    guard d.wait(for: { d.hasText(containing: "Sessions") && d.hasText(containing: "[sub-worker]") }, timeout: 5) else {
        throw Failure("Session Sidebar did not display Sessions header and [sub-worker] row")
    }

    func findButtonByHelp(_ helpSubstr: String, in root: AXUIElement) -> AXUIElement? {
        d.descendants(of: root, role: kAXButtonRole as String).first { btn in
            let help: String? = d.attribute(btn, kAXHelpAttribute)
            let desc: String? = d.attribute(btn, kAXDescriptionAttribute)
            return help?.contains(helpSubstr) == true || desc?.contains(helpSubstr) == true
        }
    }
    guard let win = d.activeWindow(), let collapseBtn = findButtonByHelp("Collapse subagent group", in: win) else {
        throw Failure("could not find 'Collapse subagent group' button in Session Sidebar")
    }
    try d.clickElement(collapseBtn)
    guard d.wait(for: { !d.hasText(containing: "[sub-worker]") }, timeout: 5) else {
        throw Failure("clicking Collapse subagent group did not hide [sub-worker] child row")
    }
    guard let win2 = d.activeWindow(), let expandBtn = findButtonByHelp("Expand subagent group", in: win2) else {
        throw Failure("could not find 'Expand subagent group' button after collapsing")
    }
    try d.clickElement(expandBtn)
    guard d.wait(for: { d.hasText(containing: "[sub-worker]") }, timeout: 5) else {
        throw Failure("clicking Expand subagent group did not restore [sub-worker] child row")
    }

    guard let win3 = d.activeWindow(), let filterField = d.descendants(of: win3, role: kAXTextFieldRole as String).first else {
        throw Failure("could not locate 'Filter tabs...' text field in Session Sidebar")
    }
    try d.clickElement(filterField)
    usleep(200_000)
    try d.type("sb_alpha_dir")
    guard d.wait(for: { !d.hasText(containing: "[sub-worker]") && d.hasText(containing: "sb_alpha_dir") }, timeout: 5) else {
        throw Failure("filtering sidebar by 'sb_alpha_dir' did not narrow sidebar rows to 'sb_alpha_dir'")
    }

    guard let win4 = d.activeWindow(),
          let alphaText = d.descendants(of: win4, role: kAXStaticTextRole as String).first(where: {
              (d.attribute($0, kAXValueAttribute) as String?)?.contains("sb_alpha_dir") == true
          }) else { throw Failure("could not locate sb_alpha_dir text element in Session Sidebar") }
    try d.clickElement(alphaText)
    guard d.wait(for: { (try? d.focusedPaneId()) == pane0 }, timeout: 5) else {
        throw Failure("clicking sb_alpha_dir row in Session Sidebar did not switch active pane to pane0")
    }

    guard let win5 = d.activeWindow(), let closeBtn = findButtonByHelp("Close Session Sidebar", in: win5) else {
        throw Failure("could not find 'Close Session Sidebar' button in Session Sidebar")
    }
    try d.clickElement(closeBtn)
    guard d.wait(for: { !d.hasText(containing: "Sessions") }, timeout: 5) else {
        throw Failure("Session Sidebar did not close after clicking Close Session Sidebar button")
    }
    try d.run("tty > \(d.path("sb_rec_tty")) && echo 'sidebar_human_ok' > \(d.path("sb_witness"))")
    try d.expect("sb_witness", "sidebar_human_ok\n", "unassisted keyboard input after sidebar selection")
    guard try d.file("sb_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines) == tty0 else {
        throw Failure("expected Tab 0 TTY (\(tty0)) after sidebar selection")
    }
}

func runOverviewSelectionScenario(_ d: Driver) throws {
    _ = try launchCleanHumanWindow(d)
    let firstDir = d.path("ov_first_pane")
    let secondDir = d.path("ov_second_pane")
    try FileManager.default.createDirectory(atPath: firstDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: secondDir, withIntermediateDirectories: true)

    try d.run("cd \(firstDir) && tty > \(d.path("ov_t0_tty"))")
    let tty0 = try d.file("ov_t0_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no pane0 ID") }

    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else { throw Failure("Tab 1 did not appear") }
    usleep(800_000)
    try d.run("cd \(secondDir) && tty > \(d.path("ov_t1_tty"))")
    let tty1 = try d.file("ov_t1_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane1 = try d.focusedPaneId(), pane1 != pane0, tty1 != tty0 else { throw Failure("Tab 1 not distinct") }

    d.key(Key.o, [.maskCommand, .maskShift])
    guard d.wait(for: { d.hasText(containing: "Pane Overview") && d.hasText(containing: "2 panes") }, timeout: 5) else {
        throw Failure("Pane Overview did not open with '2 panes' badge")
    }

    guard let win = d.activeWindow(), let searchField = d.descendants(of: win, role: kAXTextFieldRole as String).first else {
        throw Failure("could not locate filter text field in Pane Overview")
    }
    try d.clickElement(searchField)
    usleep(150_000)
    try d.type("NO_SUCH_PANE_999")
    var clearBtn: AXUIElement?
    guard d.wait(for: { clearBtn = d.button(titled: "Clear Filter"); return clearBtn != nil && d.hasText(containing: "0 of 2") }, timeout: 5), let clearBtn else {
        throw Failure("Pane Overview did not show '0 of 2' and 'Clear Filter' button on unmatched query")
    }
    d.press(clearBtn)
    guard d.wait(for: { d.hasText(containing: "2 panes") }, timeout: 5) else {
        throw Failure("Clear Filter button did not restore '2 panes' in Pane Overview")
    }

    guard let win2 = d.activeWindow(), let searchField2 = d.descendants(of: win2, role: kAXTextFieldRole as String).first else {
        throw Failure("could not re-locate filter text field in Pane Overview")
    }
    try d.clickElement(searchField2)
    usleep(150_000)
    try d.type("ov_first_pane")
    guard d.wait(for: { d.hasText(containing: "1 of 2") }, timeout: 5) else {
        throw Failure("filtering Pane Overview by 'ov_first_pane' did not narrow to '1 of 2'")
    }
    d.key(Key.returnKey)
    guard d.wait(for: { !d.hasText(containing: "Pane Overview") && (try? d.focusedPaneId()) == pane0 }, timeout: 5) else {
        throw Failure("pressing Return in Pane Overview did not close overview and jump to pane0")
    }

    try d.run("tty > \(d.path("ov_rec_tty")) && echo 'overview_select_ok' > \(d.path("ov_witness"))")
    try d.expect("ov_witness", "overview_select_ok\n", "unassisted keyboard input after Pane Overview jump")
    guard try d.file("ov_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines) == tty0 else {
        throw Failure("expected Tab 0 TTY (\(tty0)) after Pane Overview jump")
    }
}

func runAttentionJumpScenario(_ d: Driver) throws {
    let ctl = try launchCleanHumanWindow(d, size: CGSize(width: 800, height: 500))
    try d.run("tty > \(d.path("att_t0_tty"))")
    let tty0 = try d.file("att_t0_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no pane0 ID") }

    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else { throw Failure("Tab 1 did not appear") }
    usleep(800_000)
    try d.run("tty > \(d.path("att_t1_tty"))")
    let tty1 = try d.file("att_t1_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane1 = try d.focusedPaneId(), pane1 != pane0, tty1 != tty0 else { throw Failure("Tab 1 not distinct") }

    try d.clickTab(index: 0)
    guard d.wait(for: { (try? d.focusedPaneId()) == pane0 }, timeout: 5), d.menuItemEnabled("Next Attention") == false else {
        throw Failure("Next Attention menu item was unexpectedly enabled with no unseen attention")
    }

    _ = try d.exec("\(ctl) status set waiting_for_input --target \(pane1) --json")
    guard d.wait(for: { d.menuItemEnabled("Next Attention") == true }, timeout: 5),
          d.pressMenuItem(titledPrefix: "Next Attention"),
          d.wait(for: { (try? d.focusedPaneId()) == pane1 }, timeout: 5) else {
        throw Failure("Next Attention did not switch focus to pane1")
    }
    try d.run("tty > \(d.path("att_jump_tty"))")
    guard try d.file("att_jump_tty").trimmingCharacters(in: .whitespacesAndNewlines) == tty1 else {
        throw Failure("unassisted keyboard input after Next Attention did not reach Tab 1 TTY (\(tty1))")
    }

    guard d.menuItemEnabled("Go Back to Previous Pane") == true,
          d.pressMenuItem(titledPrefix: "Go Back to Previous Pane"),
          d.wait(for: { (try? d.focusedPaneId()) == pane0 }, timeout: 5) else {
        throw Failure("Go Back to Previous Pane did not return focus to pane0")
    }
    try d.run("tty > \(d.path("att_back_tty")) && echo 'attention_jump_ok' > \(d.path("att_witness"))")
    try d.expect("att_witness", "attention_jump_ok\n", "unassisted keyboard input after Go Back to Previous Pane")
    guard try d.file("att_back_tty").trimmingCharacters(in: .whitespacesAndNewlines) == tty0 else {
        throw Failure("expected Tab 0 TTY (\(tty0)) after Go Back")
    }
}

func runInputTakeoverConfirmScenario(_ d: Driver) throws {
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    try d.run("tty > \(d.path("itc_init_tty"))")
    let initTty = try d.file("itc_init_tty").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no pane0 ID") }

    _ = try d.exec("\(ctl) input lock --owner claude-agent --target \(pane0)")
    var takeOverBtn: AXUIElement?
    guard d.wait(for: { takeOverBtn = d.button(titled: "Take Over"); return takeOverBtn != nil }, timeout: 5), let takeOverBtn else {
        throw Failure("InputOwnershipHeaderView 'Take Over' button did not appear when pane was locked")
    }
    let leakFile = d.path("itc_locked_leak.txt")
    try d.run("echo 'leaked' > \(leakFile)")
    usleep(350_000)
    guard !FileManager.default.fileExists(atPath: leakFile) else {
        throw Failure("physical keyboard input leaked while pane was locked")
    }
    d.press(takeOverBtn)
    var handBackBtn: AXUIElement?
    guard d.wait(for: { handBackBtn = d.button(titled: "Hand Back"); return handBackBtn != nil }, timeout: 5), let handBackBtn else {
        throw Failure("clicking 'Take Over' did not transition header to 'Hand Back'")
    }
    try d.run("echo 'human_takeover_ok' > \(d.path("itc_takeover.txt"))")
    try d.expect("itc_takeover.txt", "human_takeover_ok\n", "human keyboard typing after clicking Take Over")
    d.press(handBackBtn)
    guard d.wait(for: { d.button(titled: "Take Over") != nil }, timeout: 5) else {
        throw Failure("clicking 'Hand Back' did not re-lock pane and restore 'Take Over' button")
    }
    let stRelocked = try d.exec("\(ctl) input status --target \(pane0) --json")
    guard stRelocked.contains("\"locked\":true") && stRelocked.contains("claude-agent") else {
        throw Failure("expected re-locked status for claude-agent after Hand Back, got: \(stRelocked)")
    }
    _ = try d.exec("\(ctl) input unlock --target \(pane0)")
    guard (try? d.exec("\(ctl) send --target \(pane0) \"echo refused\"")) == nil else {
        throw Failure("expected takoctl send without allow-automation/confirm-automation to be refused")
    }
    _ = try d.exec("\(ctl) input confirm-automation --target \(pane0)")
    _ = try d.exec("\(ctl) send --target \(pane0) \"echo onetime_ok > \(d.path("itc_onetime.txt"))\"")
    try d.expect("itc_onetime.txt", "onetime_ok\n", "one-time confirmed automation send")
    guard (try? d.exec("\(ctl) send --target \(pane0) \"echo refused_again\"")) == nil else {
        throw Failure("confirm-automation should only allow a single automated input operation")
    }
    _ = try d.exec("\(ctl) input allow-automation --target \(pane0)")
    var autoTypeBtn: AXUIElement?
    guard d.wait(for: { autoTypeBtn = d.button(titled: "Auto-type on"); return autoTypeBtn != nil }, timeout: 5), let autoTypeBtn else {
        throw Failure("'Auto-type on' button did not appear after allow-automation")
    }
    d.press(autoTypeBtn)
    guard d.wait(for: { d.button(titled: "Auto-type on") == nil }, timeout: 5) else {
        throw Failure("clicking 'Auto-type on' button did not revoke automationMayType")
    }
    usleep(200_000)
    try d.run("tty > \(d.path("itc_rec_tty")) && echo 'itc_recovered' > \(d.path("itc_recovered.txt"))")
    try d.expect("itc_recovered.txt", "itc_recovered\n", "unassisted keyboard input after takeover/confirm journey")
    guard try d.file("itc_rec_tty").trimmingCharacters(in: .whitespacesAndNewlines) == initTty else {
        throw Failure("recovered TTY did not match initial TTY (\(initTty))")
    }
}
