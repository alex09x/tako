#!/usr/bin/env python3
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Proves the motion gate catches broken motion.

Each mutant breaks one thing the design asks of Tako's animations, effects,
states or transitions -- a duration, a direction, a colour, a one-off, a
priority, a rule -- in a scratch worktree of HEAD, and runs
scripts/motion-gate.sh there. A mutant the gate passes is a hole in it.

    export TAKO_MAC=user@test-mac.local
    scripts/motion-mutants.py              # every mutant
    scripts/motion-mutants.py --list       # what they break
    scripts/motion-mutants.py --notify     # and say how it went in a notification
    scripts/motion-mutants.py spinner-slow comet-backwards

The worktree builds in a directory of its own on the test Mac
(TAKO_MAC_DIR, ci/tako-mutants by default), so a run does not hold up
checks of the main checkout. Its first build is a cold one.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

LAYER = "swift/Sources/TakoApp/_TakoShim/Tako+TabStatusLayer.swift"
SURFACE = "swift/Sources/TakoApp/_TakoShim/Tako+LivingSurface.swift"
EFFECTS = "swift/Sources/TakoApp/_TakoShim/Tako+LivingSurfaceEffects.swift"
ROW = "swift/Sources/TakoApp/Features/Sidebar/SessionSidebarRowView.swift"
STRIP = "swift/Sources/TakoApp/_TakoShim/Tako+TabStripTransitions.swift"
CRAB = "swift/Sources/TakoApp/_TakoShim/Tako+CrabLayer.swift"
PAINTER = "swift/Sources/TakoApp/_TakoShim/Tako+CrabPainter.swift"

# name, what the design asks, file, text, replacement
MUTANTS = [
    ("spinner-slow", "the spinner turns once in 0.9 s", LAYER,
     "makeSpinAnimation(duration: 0.9)", "makeSpinAnimation(duration: 1.3)"),
    ("comet-slow", "the comet goes round once in 2.2 s", LAYER,
     "makeSpinAnimation(duration: 2.2)", "makeSpinAnimation(duration: 3.0)"),
    ("layer-spin-backwards", "the spinner and comet turn clockwise", LAYER,
     "spin.toValue = -Double.pi * 2.0", "spin.toValue = Double.pi * 2.0"),
    ("breathe-shallow", "the waiting border breathes from 40 %", LAYER,
     "fromValue = T.claw.withAlphaComponent(0.40)", "fromValue = T.claw.withAlphaComponent(0.80)"),
    ("no-glow", "the waiting glow grows to 30 %", LAYER,
     "shadowAnim.toValue = 0.30", "shadowAnim.toValue = 0.0"),
    ("halo-stuck", "the halo grows to 2.1", LAYER,
     "scaleAnim.toValue = 2.1", "scaleAnim.toValue = 1.0"),
    ("no-blink", "the waiting dot blinks to a quarter", LAYER,
     "blink.toValue = 0.25", "blink.toValue = 1.0"),
    ("no-pop", "a done ring pops to .55 and 1.25", LAYER,
     "pop.values = [1.0, 0.55, 1.25, 1.0]", "pop.values = [1.0, 1.0, 1.0, 1.0]"),
    ("no-glint", "a done surface glints once", LAYER,
     'flashLayer.add(sweep, forKey: "doneFlash")', "_ = sweep"),
    ("no-failed-line", "a failed surface has a red baseline", LAYER,
     "failedLineLayer.isHidden = (state != .failed)", "failedLineLayer.isHidden = true"),
    ("reduce-motion-stub", "Reduce Motion: a still Ember border all round", LAYER,
     "cometGradient.colors = reduceMotion ? Self.stillBorderColors : Self.cometColors",
     "cometGradient.colors = Self.cometColors"),
    ("progress-rebuilds", "a new percentage moves the arc and rebuilds nothing", LAYER,
     "if case .progress = previousState, case .progress = state { return true }", ""),
    ("arc-one-colour", "the progress arc shades Rust to Ember", LAYER,
     "shade.colors = [T.ember.cgColor, T.ember.cgColor, T.rust.cgColor]",
     "shade.colors = [T.ember.cgColor, T.ember.cgColor, T.ember.cgColor]"),
    ("offline-solid", "the offline border is dashed", LAYER,
     "lineDashPattern = [3, 3]", "lineDashPattern = nil"),
    ("reduced-glow-off", "Reduce Motion keeps a 20 % glow", LAYER,
     "breatheGlowLayer.shadowOpacity = 0.20", "breatheGlowLayer.shadowOpacity = 0.0"),
    ("no-progress-line", "progress runs a line along the bottom", LAYER,
     "progressLineLayer.isHidden = false", "progressLineLayer.isHidden = true"),
    ("quiet-ring-bright", "a quiet live ring is Ember at 45 %", "swift/Sources/TakoApp/_TakoShim/Tako+LiveRing.swift",
     "quietOpacity: Double = 0.45", "quietOpacity: Double = 1.0"),
    ("no-ripple", "a burst ripples the live ring out to 1.7", "swift/Sources/TakoApp/_TakoShim/Tako+LiveRing.swift",
     "rippleScale: CGFloat = 1.7", "rippleScale: CGFloat = 1.0"),
    ("sidebar-on-swiftui-clock", "live sidebar rows run on Core Animation", ROW,
     "private var layered: Bool { now == nil }", "private var layered: Bool { false }"),
    ("pane-rows-waiting-border", "pane rows draw only working and failed", ROW,
     "let paneEffectState: Tako.SurfaceState = (state == .working || state == .failed) ? state : .idle",
     "let paneEffectState: Tako.SurfaceState = (state == .working || state == .failed || state == .waiting) ? state : .idle"),
    ("progress-outranks-working", "a pane at work outranks another's progress",
     "swift/Sources/TakoApp/_TakoShim/Tako+TabBarResolution.swift",
     "guard !all.isEmpty, !all.contains(where: worksWithoutProgress) else { return nil }",
     "guard !all.isEmpty else { return nil }"),
    ("ranks-tied", "every state has a rank of its own", "swift/Sources/TakoApp/_TakoShim/Tako+PaneStatus.swift",
     "case .progress: return 3", "case .progress: return 4"),
    ("cursor-half-lit", "the cursor is lit 60 % of its 1.2 s blink", "swift/Sources/TakoCoreUI/CursorBlink.swift",
     "public static let litShare = 0.6", "public static let litShare = 0.5"),
    ("strip-no-shake", "a failed pill shakes for 0.448 s", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarMotion.swift",
     "static let shakeDuration: CFTimeInterval = 0.448", "static let shakeDuration: CFTimeInterval = 0"),
    ("chip-jumps", "the workspace chip slides over 150 ms", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarMotion.swift",
     "static let chipSlideDuration: CFTimeInterval = 0.15", "static let chipSlideDuration: CFTimeInterval = 0"),
    ("echo-counts", "output within 150 ms of a key is its echo", "swift/Sources/TakoApp/_TakoShim/Tako+LiveActivity.swift",
     "static let echoWindow: TimeInterval = 0.15", "static let echoWindow: TimeInterval = 0"),
    ("working-at-once", "working shows after 3 s", "swift/Sources/TakoApp/_TakoShim/Tako+Crab.swift",
     "static let minimumVisibleDuration: TimeInterval = 3", "static let minimumVisibleDuration: TimeInterval = 0"),
    ("done-lingers", "a focused tab's done fades after 2 s", "swift/Sources/TakoApp/_TakoShim/Tako+Crab.swift",
     "static let successLinger: TimeInterval = 2", "static let successLinger: TimeInterval = 6"),
    ("swiftui-comet-backwards", "the cards' comet turns clockwise", SURFACE,
     "return (ms / 2200.0) * 360.0", "return -(ms / 2200.0) * 360.0"),
    ("swiftui-spinner-slow", "the cards' spinner turns once in 0.9 s", SURFACE,
     "let ms = CSSTiming.positiveMod(t * 1000.0, 900.0)\n        return (ms / 900.0) * 360.0",
     "let ms = CSSTiming.positiveMod(t * 1000.0, 1300.0)\n        return (ms / 1300.0) * 360.0"),
    ("swiftui-arc-one-colour", "the cards' progress arc shades Rust to Ember", SURFACE,
     "stops: [.init(color: Color(nsColor: T.rust), location: 0),",
     "stops: [.init(color: Color(nsColor: T.ember), location: 0),"),
    ("swiftui-shake-flat", "a failed card's ring shakes on the design's beats", SURFACE,
     "[(0, 0), (64, -2), (128, 2), (192, -2), (256, 2), (320, -1), (448, 0)]",
     "[(0, 0), (64, 0), (128, 0), (192, 0), (256, 0), (320, 0), (448, 0)]"),
    ("swiftui-pop-flat", "a done card's ring pops", SURFACE,
     "[(0, 1.0), (192, 0.55), (448, 1.25), (704, 1.0)]", "[(0, 1.0), (192, 1.0), (448, 1.0), (704, 1.0)]"),
    ("selected-card-thin", "a selected card has a 2 pt Ember border", EFFECTS,
     ".strokeBorder(borderColor, lineWidth: 2.0)", ".strokeBorder(borderColor, lineWidth: 1.0)"),
    ("swiftui-breathe-shallow", "the cards' waiting border breathes from 40 %", EFFECTS,
     "let alpha = reduceMotion ? 0.90 : (0.40 + 0.55 * s)", "let alpha = reduceMotion ? 0.90 : (0.80 + 0.15 * s)"),
    ("halo-slow", "the halo comes round every 1.6 s", LAYER,
     "group.duration = 1.6", "group.duration = 3.0"),
    ("blink-slow", "the waiting dot blinks over 1.6 s", LAYER,
     "blink.duration = 0.8", "blink.duration = 1.6"),
    ("breathe-slow", "the waiting border breathes over 1.6 s", LAYER,
     "strokeAnim.duration = 0.8", "strokeAnim.duration = 1.6"),
    ("pop-slow", "the done pop takes 0.704 s", LAYER,
     "pop.duration = 0.704", "pop.duration = 1.4"),
    ("glint-slow", "the done glint takes 0.96 s", LAYER,
     "sweep.duration = 0.96", "sweep.duration = 2.0"),
    ("glint-backwards", "the done glint crosses left to right", LAYER,
     "sweep.fromValue = flashLayer.x(at: 0); sweep.toValue = flashLayer.x(at: 1)",
     "sweep.fromValue = flashLayer.x(at: 1); sweep.toValue = flashLayer.x(at: 0)"),
    ("comet-invisible", "the comet is Claw into Rust", LAYER,
     "private static let cometColors = [NSColor.clear.cgColor, T.claw.cgColor, T.rust.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]",
     "private static let cometColors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]"),
    ("ripple-slow", "a ripple takes 0.3 s", "swift/Sources/TakoApp/_TakoShim/Tako+LiveRing.swift",
     "rippleDuration: TimeInterval = 0.3", "rippleDuration: TimeInterval = 1.0"),
    ("ripple-clear", "a ripple starts at 95 %", "swift/Sources/TakoApp/_TakoShim/Tako+LiveRing.swift",
     "rippleOpacity: Double = 0.95", "rippleOpacity: Double = 0.0"),
    ("live-window-long", "output flows for 3 s after it arrives", "swift/Sources/TakoApp/_TakoShim/Tako+CrabLive.swift",
     "static let liveWindow = 3", "static let liveWindow = 10"),
    ("badges-early", "the tab numbers show after ⌘ is held 150 ms", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarInput.swift",
     "static let commandBadgeDelay: TimeInterval = 0.15", "static let commandBadgeDelay: TimeInterval = 0.05"),
    ("header-ring-never-rests", "the Needs-you ring rests when nothing waits",
     "swift/Sources/TakoApp/Features/Sidebar/SessionSidebarView.swift",
     "let ringRests = animState.reduceMotion || attentionCount == 0", "let ringRests = animState.reduceMotion"),
    ("pill-deaf-to-bursts", "the tab bar hands a pill's layer its bursts",
     "swift/Sources/TakoApp/_TakoShim/Tako+TabBarWorkspace.swift",
     "pulses: liveActivity(for: window)?.pulses ?? 0", "pulses: 0"),
    ("row-never-pauses", "a row stands still while the sidebar is hidden", ROW,
     "                        paused: motionPaused,\n                        pulses: item.live?.pulses ?? 0,",
     "                        paused: false,\n                        pulses: item.live?.pulses ?? 0,"),
    ("question-dim", "a waiting row asks its question in Claw", ROW,
     "return (prompt, Color(nsColor: T.claw), .tail)", "return (prompt, Color(nsColor: T.dim), .tail)"),
    ("active-bar-inside", "the active row's bar is at the sidebar's edge", ROW,
     ".offset(x: -8)", ".offset(x: 0)"),
    ("row-progress-no-comet", "a row in progress runs the comet", ROW,
     "cometForProgress: true", "cometForProgress: false"),
    ("row-line-at-edge", "a row's progress line starts 8 pt in", ROW,
     "progressInset: hasBorderBox1px ? 9 : 8", "progressInset: 0"),
    ("overview-sixty", "the Overview takes 30 frames a second at rest", "swift/Sources/TakoApp/Features/Overview/PaneOverviewMotion.swift",
     "oneOffRemaining == nil ? 1.0 / 30.0 : nil", "oneOffRemaining == nil ? 1.0 / 60.0 : nil"),
    ("done-moves-briefly", "done moves for its glint and pop, a second", "swift/Sources/TakoApp/_TakoShim/Tako+LivingMotion.swift",
     "case .done: return 1.0", "case .done: return 0.2"),
    ("failed-over-offline", "offline outranks failed", "swift/Sources/TakoApp/_TakoShim/Tako+PaneStatus.swift",
     "case .failed: return 6", "case .failed: return 8"),
    ("cursor-outline-thick", "an unfocused cursor is a 1 pt outline", "swift/Sources/TakoCoreUI/TerminalMetalFramePlanner+Overlays.swift",
     "?? max(1, Float(metrics.scale).rounded())", "?? max(1, (2 * Float(metrics.scale)).rounded())"),
    ("strip-appear-slow", "a new tab grows in over 160 ms", STRIP,
     "static let appearDuration: CFTimeInterval = 0.16", "static let appearDuration: CFTimeInterval = 0.3"),
    ("strip-close-slow", "a closed tab collapses over 140 ms", STRIP,
     "static let closeDuration: CFTimeInterval = 0.14", "static let closeDuration: CFTimeInterval = 0.3"),
    ("strip-close-ease-out", "a closed tab collapses ease-in", STRIP,
     "static let easeIn: (Double) -> Double = CSSTiming.cubicBezier(0.42, 0, 1, 1)",
     "static let easeIn: (Double) -> Double = CSSTiming.cubicBezier(0, 0, 0.58, 1)"),
    ("strip-bar-slow", "the active bar travels in 120 ms", STRIP,
     "static let barDuration: CFTimeInterval = 0.12", "static let barDuration: CFTimeInterval = 0.3"),
    ("strip-reorder-slow", "neighbours make room in 120 ms", STRIP,
     "static let reorderDuration: CFTimeInterval = 0.12", "static let reorderDuration: CFTimeInterval = 0.3"),
    ("strip-neighbours-jump", "neighbours move, they do not jump", STRIP,
     "out[i].frame.origin.x = from.minX + (out[i].frame.minX - from.minX) * k", "_ = (from, k)"),
    ("strip-hover-slow", "a button's hover comes in over 80 ms", STRIP,
     "static let hoverDuration: CFTimeInterval = 0.08", "static let hoverDuration: CFTimeInterval = 0.3"),
    ("strip-spring-loose", "a dropped tab springs at 300/24", STRIP,
     "static let springDamping = 24.0", "static let springDamping = 8.0"),
    ("strip-no-spring", "a dropped tab springs, it does not jump", STRIP,
     "guard elapsed > 0 else { return x0 }", "guard elapsed > 1e9 else { return 0 }"),
    ("strip-no-tilt", "a lifted tab is tilted 3°", STRIP,
     "static let liftTiltDegrees: CGFloat = -3", "static let liftTiltDegrees: CGFloat = 0"),
    ("strip-content-early", "a new tab's content comes after it has grown", STRIP,
     "moved.showsContent = factor >= 1", "moved.showsContent = true"),
    ("strip-hidden-animates", "a strip nobody sees takes changes at once", STRIP,
     "LivingAnimationState.shared.reduceMotion || window?.isVisible != true", "LivingAnimationState.shared.reduceMotion"),
    ("tooltip-slow", "tooltips show after 800 ms", STRIP,
     "static let tooltipDelayMilliseconds = 800", "static let tooltipDelayMilliseconds = 1500"),
    ("drag-does-not-follow", "a lifted tab follows the pointer", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarInput.swift",
     "dragPointX = currentPoint.x", "dragPointX = nil"),
    ("clicks-on-drawn-tabs", "clicks aim where a tab lies at rest", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarInput.swift",
     "return laid.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX }",
     "return tabs.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX }"),
    ("banner-slower", "the broadcast banner moves in 0.15 s", "swift/Sources/TakoApp/Features/BroadcastInput/BroadcastInputBannerView.swift",
     ".animation(.easeInOut(duration: 0.15), value: isLeader)", ".animation(.easeInOut(duration: 0.4), value: isLeader)"),
    ("overview-scroll-slow", "the Overview scrolls to its choice in 0.15 s", "swift/Sources/TakoApp/Features/Overview/PaneOverviewView.swift",
     "withAnimation(.easeInOut(duration: 0.15)) {", "withAnimation(.easeInOut(duration: 0.4)) {"),
    ("grip-fade-slow", "the resize edge lights in 0.12 s", "swift/Sources/TakoApp/Features/Sidebar/SessionSidebarResize.swift",
     "fade.duration = 0.12", "fade.duration = 0.5"),
    ("quick-terminal-ease-out", "the quick terminal slides ease-in",
     "swift/Sources/TakoApp/Features/QuickTerminal/QuickTerminalController+Animation.swift",
     "context.timingFunction = .init(name: .easeIn)\n            position.setFinal(",
     "context.timingFunction = .init(name: .easeOut)\n            position.setFinal("),
    ("animation-not-in-census", "every animation is in the census", "swift/Sources/TakoApp/Features/About/CyclingIconView.swift",
     ".animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)",
     ".animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)\n            .transition(.scale)"),
    ("classic-ring-with-surface", "a classic tab shows the ring alone", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarWorkspace.swift",
     "statusLayer.drawsSurface = ringOrigin == nil", "statusLayer.drawsSurface = true"),
    ("classic-ring-off-slot", "a classic tab's ring sits in its slot", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarDrawing.swift",
     "let ring = CGPoint(x: slot.midX - 7 - tab.frame.minX,", "let ring = CGPoint(x: slot.midX - tab.frame.minX,"),
    ("classic-no-ring", "a classic tab shows the 1b ring", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarDrawing.swift",
     "updateStatusLayer(for: tab.window, rect: tab.frame, state: state, hideRing: showsBadge, ringAt: ring)", "_ = ring"),
    ("classic-badge-beside-ring", "the ⌘ badge covers a classic tab's ring", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarDrawing.swift",
     "hideRing: showsBadge, ringAt: ring)", "hideRing: false, ringAt: ring)"),
    ("classic-ring-still", "a failed classic tab's ring shakes with it", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarDrawing.swift",
     "statusLayers[key]?.setPose(dx: shakeDX, tiltDegrees: liftTilt(for: tab))", "statusLayers[key]?.setPose(dx: 0, tiltDegrees: liftTilt(for: tab))"),
    ("classic-no-unread-dot", "a classic tab with something unseen carries the Claw dot", "swift/Sources/TakoApp/_TakoShim/Tako+TabBarDrawing.swift",
     "let showsUnreadDot = !showsClose && (", "let showsUnreadDot = false && ("),
    ("banner-pops-in", "the broadcast banner comes in over 0.15 s", "swift/Sources/TakoApp/Features/BroadcastInput/BroadcastInputBannerView.swift",
     ".animation(.easeInOut(duration: 0.15), value: role)", ".animation(nil, value: role)"),
    ("banner-slow", "the broadcast banner takes 0.15 s", "swift/Sources/TakoApp/Features/BroadcastInput/BroadcastInputBannerView.swift",
     ".animation(.easeInOut(duration: 0.15), value: role)", ".animation(.easeInOut(duration: 0.6), value: role)"),
    ("ownership-header-pops-in", "the input-ownership header comes in over 0.15 s", "swift/Sources/TakoApp/Features/InputOwnership/InputOwnershipHeaderView.swift",
     ".animation(.easeInOut(duration: 0.15), value: barKey)", ".animation(nil, value: barKey)"),
    ("overlay-pops-in", "a pane's covering overlay fades in", "swift/Sources/TakoApp/_TakoShim/Tako+SurfaceUI.swift",
     ".animation(.easeInOut(duration: 0.15), value: coveringOverlays)", ".animation(nil, value: coveringOverlays)"),
    ("phone-blink-even", "the phone's cursor blinks as the Mac's", "swift/Sources/TakoCoreUI/CursorBlink.swift",
     "withTimeInterval: CursorBlink.phaseDuration(lit: isLit), repeats: false", "withTimeInterval: 0.5, repeats: false"),
    ("phone-blink-never-toggles", "the phone's cursor goes out between its lit phases", "swift/Sources/TakoCoreUI/CursorBlink.swift",
     "                    self.isLit.toggle()\n", ""),
    ("phone-view-own-blink", "the phone's view blinks on the shared blinker", "swift/Sources/TakoCoreUI/TakoTerminalView+Display.swift",
     "        blinker.restart()\n", "        blinker.stop()\n"),
    ("timer-not-in-census", "every timer is in the census", "swift/Sources/TakoApp/Features/Terminal/LayoutRecorder.swift",
     "timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true)",
     "timer = Timer.scheduledTimer(withTimeInterval: interval * 2, repeats: true)"),
    ("done-not-green", "done is #7BD88F", SURFACE,
     "static let ok = NSColor(srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1)",
     "static let ok = NSColor(srgbRed: 0x7B / 255, green: 0xB8 / 255, blue: 0x8F / 255, alpha: 1)"),
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEP_LIMIT = int(os.environ.get("MOTION_MUTANT_TIMEOUT", "240"))
BASELINE_LIMIT = int(os.environ.get("MOTION_BASELINE_TIMEOUT", "1200"))


def gate(worktree, limit):
    """Runs the gate in `worktree`; returns (verdict, seconds, tail of output)."""
    env = dict(os.environ)
    env.setdefault("TAKO_MAC_DIR", "ci/tako-mutants")
    started = time.monotonic()
    try:
        done = subprocess.run(["scripts/motion-gate.sh"], cwd=worktree, env=env, capture_output=True,
                              text=True, timeout=limit)
        out = done.stdout + done.stderr
        if "build failed" in out:
            verdict = "build failed"
        elif done.returncode == 0:
            verdict = "passed"
        else:
            verdict = "failed"
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        verdict = "timed out"
    return verdict, time.monotonic() - started, out


def main(argv):
    names = [a for a in argv if not a.startswith("--")]
    if "--list" in argv:
        for name, what, path, _, _ in MUTANTS:
            print(f"{name:28} {what}  ({os.path.basename(path)})")
        return 0
    if not os.environ.get("TAKO_MAC"):
        print("set TAKO_MAC to user@host of the test Mac", file=sys.stderr)
        return 2
    chosen = [m for m in MUTANTS if not names or m[0] in names]
    unknown = set(names) - {m[0] for m in MUTANTS}
    if unknown:
        print(f"no such mutant: {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2

    worktree = tempfile.mkdtemp(prefix="tako-mutants-")
    os.rmdir(worktree)
    subprocess.run(["git", "worktree", "add", "--detach", worktree, "HEAD"], cwd=ROOT, check=True,
                   capture_output=True)
    results = []
    try:
        verdict, took, out = gate(worktree, BASELINE_LIMIT)
        print(f"baseline: {verdict} in {took:.0f} s", flush=True)
        if verdict != "passed":
            print(out[-3000:])
            return 1
        for name, what, path, text, replacement in chosen:
            file = os.path.join(worktree, path)
            original = open(file, encoding="utf-8").read()
            if original.count(text) != 1:
                results.append((name, what, f"invalid: found {original.count(text)} times", 0))
                continue
            open(file, "w", encoding="utf-8").write(original.replace(text, replacement))
            try:
                verdict, took, out = gate(worktree, STEP_LIMIT)
            finally:
                open(file, "w", encoding="utf-8").write(original)
            outcome = {"failed": "caught", "passed": "MISSED"}.get(verdict, f"invalid: {verdict}")
            results.append((name, what, outcome, took))
            print(f"{name:28} {outcome:10} {took:4.0f} s  {what}", flush=True)
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", worktree], cwd=ROOT, capture_output=True)
        shutil.rmtree(worktree, ignore_errors=True)

    caught = sum(1 for r in results if r[2] == "caught")
    print(f"\n{caught} of {len(results)} mutants caught")
    holes = [f"{name} ({outcome})" for name, _, outcome, _ in results if outcome != "caught"]
    for name, what, outcome, _ in results:
        if outcome != "caught":
            print(f"  {outcome}: {name} -- {what}")
    if "--notify" in argv:
        notify(f"{caught} of {len(results)} broken spec items caught" + (f"; holes: {', '.join(holes)}" if holes else ""))
    return 0 if caught == len(results) else 1


def notify(text):
    """A notification on this Mac, for a run nobody is watching."""
    script = f'display notification {applescript_string(text)} with title "Tako motion mutants"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


def applescript_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
