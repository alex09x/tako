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
import Foundation
import Testing
@testable import Tako

/// Every animation in the app, where it is, what it does and what tests it.
/// Timers count too: a crab once moved on timers no other scan saw, so each
/// timer is entered, as motion or as what it does instead.
/// The census reads the sources: a new animation that is not entered here,
/// an entry whose code -- duration, curve, values -- changed, or a test it
/// names that is gone fails the gate. "pinned" marks motion no spec gives
/// numbers for and no other test can see, held to the exact code here.
@Suite(.serialized) @MainActor
struct MotionCensusTests {
    struct Site: CustomTestStringConvertible, Sendable {
        let file: String
        /// Text the animation's line holds, parameters included.
        let code: String
        let what: String
        let coveredBy: [String]
        var testDescription: String { "\(file): \(what)" }
    }

    static let pinned = "pinned"
    /// A timer that moves nothing on screen: it polls, saves or expires.
    static let notMotion = "not motion"

    static let census: [Site] = [
        // The status layer: rings and surfaces of pills and live sidebar rows (Sessions UI 1b, 4a, 5a).
        Site(file: "Tako+TabStatusLayer.swift", code: #"let spin = CABasicAnimation(keyPath: "transform.rotation.z")"#,
             what: "spinner 0.9 s and comet 2.2 s, clockwise",
             coveredBy: ["theSpinnerTurnsClockwiseOnceIn900ms", "theCometRunsClockwiseRoundTheBorderOnceIn2200ms", "aSurfaceShowsItsStateAsTheSpecDoes"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"scaleAnim.fromValue = 1.0; scaleAnim.toValue = 2.1"#,
             what: "waiting halo grows 1 to 2.1", coveredBy: ["theHaloGrowsAndFadesEvery1600ms"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"opAnim.fromValue = 0.75; opAnim.toValue = 0.0"#,
             what: "waiting halo fades .75 to 0", coveredBy: ["theHaloGrowsAndFadesEvery1600ms"]),
        Site(file: "Tako+TabStatusLayer.swift", code: "let group = CAAnimationGroup()",
             what: "waiting halo every 1.6 s, ease-out", coveredBy: ["theHaloGrowsAndFadesEvery1600ms", "theWaitingHaloBlinkAndBreatheRepeatEvery1600ms"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"let blink = CABasicAnimation(keyPath: "opacity")"#,
             what: "waiting dot blinks to a quarter", coveredBy: ["theDotBlinksToAQuarter"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"let pop = CAKeyframeAnimation(keyPath: "transform.scale")"#,
             what: "done pop .55, 1.25 in 0.704 s", coveredBy: ["aDoneRingPopsSmallThenBigThenSettles", "thePopShrinksOvershootsAndSettlesOnTheDesignsBeats"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"let strokeAnim = CABasicAnimation(keyPath: "strokeColor")"#,
             what: "waiting border breathes 40-95 %", coveredBy: ["theWaitingBorderBreathesFromFortyToNinetyFivePercent"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")"#,
             what: "waiting glow 0-30 %", coveredBy: ["theWaitingGlowSpreadsOutsideTheBorderAtTheBreathsPeak"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"let sweep = CABasicAnimation(keyPath: "position.x")"#,
             what: "done glint left to right in 0.96 s", coveredBy: ["theGlintCrossesLeftToRightOnceAndIsGone", "thePopAndTheGlintAreTakenOffWhenTheyHaveRun"]),
        Site(file: "Tako+TabStatusLayer+Live.swift", code: #"let scale = CABasicAnimation(keyPath: "transform.scale")"#,
             what: "live ripple out to 1.7", coveredBy: ["aBurstRipplesTheLiveRingOutAndAway", "aLiveRingRipplesOncePerNewBurstWhileItFlows"]),
        Site(file: "Tako+TabStatusLayer+Live.swift", code: #"let fade = CABasicAnimation(keyPath: "opacity")"#,
             what: "live ripple fades from .95", coveredBy: ["aBurstRipplesTheLiveRingOutAndAway"]),
        Site(file: "Tako+TabStatusLayer+Live.swift", code: "let group = CAAnimationGroup()",
             what: "live ripple, 0.3 s ease-out", coveredBy: ["aLiveRingRipplesOncePerNewBurstWhileItFlows", "aLiveRippleGrowsAndFadesWithEaseOutIn300ms"]),
        // SwiftUI's side: snapshots, exports and the Overview's cards.
        Site(file: "Tako+LiveRing.swift", code: "withAnimation(.easeOut(duration: LiveRingStyle.rippleDuration)) { phase = 1 }",
             what: "SwiftUI live ripple, 0.3 s ease-out", coveredBy: ["aLiveRippleGrowsAndFadesWithEaseOutIn300ms"]),
        Site(file: "Tako+LivingSurface.swift", code: ".animation(.easeOut(duration: 0.25), value: clamped)",
             what: "a card's arc eases to a new percentage in 0.25 s (no spec; the layer's arc moves at once)",
             coveredBy: [pinned, "aCardsArcShadesRustToEmber"]),
        Site(file: "SessionSidebarRowClock.swift", code: "TimelineView(.animation(minimumInterval: LivingMotion.minimumFrameInterval(for: state), paused: paused || !moving))",
             what: "a row's clock: frames only while it moves (the failed shake, snapshots)",
             coveredBy: ["aFailedRowShakesAsAWhole", "movingSidebarRowsLayNothingOutWhileTheyMove", "aRowThatFinishesKeepsItsPopThroughTheLayoutAfter"]),
        Site(file: "PaneOverviewView.swift", code: "TimelineView(.animation(minimumInterval: Self.minimumFrameInterval(oneOffRemaining: oneOff),",
             what: "the Overview's 30 frames a second, every frame for a one-off",
             coveredBy: ["aCardPlayingAOneOffTakesEveryFrameUntilItRests", "lastingMotionsRestAndReducedMotionStayAtThirty"]),
        Site(file: "PaneOverviewView.swift", code: "withAnimation(.easeInOut(duration: 0.15)) {",
             what: "the Overview scrolls to the chosen card in 0.15 s (no design numbers; a frame of the Overview takes longer to draw off screen than the scroll does, so its code is held)",
             coveredBy: [pinned]),
        // The tab strip, drawn frame by frame (Terminal UI).
        Site(file: "Tako+TabBar.swift", code: "var motionLink: CADisplayLink?",
             what: "the strip's display link", coveredBy: ["aPillThatFailsShakesOnTheDesignsCurveFromThatMoment"]),
        Site(file: "Tako+TabBarMotion.swift", code: "let link = displayLink(target: self, selector: #selector(motionFrame(_:)))",
             what: "frames while a pill shakes, the chip slides or tabs move",
             coveredBy: ["aPillThatFailsShakesOnTheDesignsCurveFromThatMoment", "theChipSlidesToItsNewWidthInsteadOfJumping",
                         "aNewTabGrowsFromNothingIn160msAndItsContentComesAfter", "aClosedTabCollapsesIn140msAndItsNeighboursCloseUp",
                         "choosingATabMovesOnlyTheBarIn120ms", "neighboursMakeRoomIn120msAndTheDroppedTabSpringsHome",
                         "aButtonsHoverComesInOver80ms"]),
        Site(file: "Tako+TabBarMotion.swift", code: "@objc func motionFrame(_ link: CADisplayLink) {",
             what: "the strip stops its frames once nothing moves",
             coveredBy: ["aHiddenTabWindowTakesTheNewWidthAtOnceAndRunsNoFrames", "motionThatRanItsTimeEndsUndrawn"]),
        // The sidebar's edge.
        Site(file: "SessionSidebarResize.swift", code: #"let fade = CABasicAnimation(keyPath: "opacity")"#,
             what: "the resize edge lights and goes out in 0.12 s", coveredBy: ["theResizeEdgeLightsAndGoesOutIn120ms"]),
        // Overlays.
        Site(file: "BroadcastInputBannerView.swift", code: ".transition(.move(edge: .top).combined(with: .opacity))",
             what: "the broadcast banner slides in from the top", coveredBy: ["theBroadcastBannerComesInOverAMomentAndGoes"]),
        Site(file: "BroadcastInputBannerView.swift", code: ".animation(.easeInOut(duration: 0.15), value: role)",
             what: "the broadcast banner's 0.15 s, where it is put in", coveredBy: ["theBroadcastBannerComesInOverAMomentAndGoes"]),
        Site(file: "InputOwnershipHeaderView.swift", code: ".transition(.move(edge: .top).combined(with: .opacity))",
             what: "the input-ownership header slides in from the top", coveredBy: ["theInputOwnershipHeaderComesInOverAMomentAndGoes"]),
        Site(file: "InputOwnershipHeaderView.swift", code: ".animation(.easeInOut(duration: 0.15), value: barKey)",
             what: "the input-ownership header's 0.15 s, where it is put in",
             coveredBy: ["theInputOwnershipHeaderComesInOverAMomentAndGoes", "testLockAndUnlock"]),
        Site(file: "SecureInputOverlay.swift", code: "withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: false)) {",
             what: "secure input's ring turns every 2 s", coveredBy: [pinned, "rendersVisiblePixelsAndRunsItsOnAppearAnimationsWithoutCrashing"]),
        Site(file: "SecureInputOverlay.swift", code: "withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: true)) {",
             what: "secure input's glow pulses every 2 s", coveredBy: [pinned, "rendersVisiblePixelsAndRunsItsOnAppearAnimationsWithoutCrashing"]),
        Site(file: "Tako+SurfaceUI.swift", code: ".transition(.opacity)",
             what: "a pane's overlays fade in and out", coveredBy: ["aFileOverlayFadesInOverThePaneAndOut"]),
        Site(file: "Tako+SurfaceUI.swift", code: ".animation(.easeInOut(duration: 0.15), value: coveringOverlays)",
             what: "a pane's covering overlays fade over 0.15 s", coveredBy: ["aFileOverlayFadesInOverThePaneAndOut"]),
        Site(file: "CyclingIconView.swift", code: ".animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)",
             what: "About's icon changes over 0.5 s", coveredBy: [pinned, "advanceToNextIconWrapsWithinTheSingleIconOfficialSet"]),
        // The quick terminal: slides in and out on its configured time, ease-in.
        Site(file: "QuickTerminalController+Animation.swift", code: "NSAnimationContext.runAnimationGroup({ context in",
             what: "the quick terminal slides on quick-terminal-animation-duration (0.2 s), ease-in",
             coveredBy: ["initialOriginForEachPosition", "finalOriginForEachPosition", "theQuickTerminalSlidesOnItsConfiguredTimeEaseIn"]),
        Site(file: "QuickTerminalController+Animation.swift", code: "in: window.animator(),",
             what: "the quick terminal's frame, animated", coveredBy: ["setInitialMakesWindowInvisibleAndUsesConfiguredSizeWhenNoClosedFrame",
                                                                     "setFinalMakesWindowVisibleAndUsesConfiguredSizeWhenNoClosedFrame"]),
        // The terminal's own frames.
        Site(file: "TakoTerminalNSView+Presentation.swift", code: "let link = self.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))",
             what: "the terminal's frames on macOS", coveredBy: ["testPresentationPauseSuspendsAndRestoresExactlyOneBlinkTimer", "testTheCursorIsLitFor720msThenOutFor480ms"]),
        Site(file: "TakoTerminalNSView.swift", code: "var displayLink: CADisplayLink?",
             what: "the terminal's display link", coveredBy: ["testPresentationPauseSuspendsAndRestoresExactlyOneBlinkTimer"]),
        Site(file: "TakoTerminalView+Metal.swift", code: "let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))",
             what: "the terminal's frames on iOS (scripts/check.sh ios)",
             coveredBy: ["testRedrawRequestsCoalesceIntoOnePendingFrame", "testNoDuplicateTimersDisplayLinksOrLayers"]),
        Site(file: "TakoTerminalView.swift", code: "var displayLink: CADisplayLink?",
             what: "the iOS terminal's display link (scripts/check.sh ios)",
             coveredBy: ["testThemeChangeRebuildsRendererStateWithoutDuplicates", "testCPUFallbackWhenMetalIsUnavailable"]),
        Site(file: "TakoTerminalView.swift", code: "var kineticDisplayLink: CADisplayLink?",
             what: "iOS kinetic scrolling", coveredBy: ["testKineticDecelerationMonotonicDecay"]),
        Site(file: "TakoTerminalView+Gestures.swift", code: "let link = CADisplayLink(target: proxy, selector: #selector(KineticDisplayLinkProxy.tick(_:)))",
             what: "iOS kinetic scrolling decelerates", coveredBy: ["testKineticDecelerationMonotonicDecay", "testKineticDecelerationTerminalStopAndZeroResidual"]),
        Site(file: "TakoTerminalView+Gestures.swift", code: "@objc func tick(_ link: CADisplayLink) {",
             what: "iOS kinetic scrolling's frames", coveredBy: ["testKineticDecelerationCancellation"]),
        Site(file: "TakoTerminalView+Gestures.swift", code: "func kineticDisplayLinkFired(_ link: CADisplayLink) {",
             what: "iOS kinetic scrolling's step", coveredBy: ["testKineticDecelerationVelocityThreshold", "testKineticDecelerationMaxVelocityClamping"]),
        Site(file: "SshFormScreen.swift", code: "withAnimation(.easeOut(duration: 0.2)) {",
             what: "the iOS SSH form reveals its fields in 0.2 s", coveredBy: [pinned]),
        // Timers: what moves on a timer, and what a timer does instead.
        Site(file: "TakoTerminalNSView+Drawing.swift",
             code: "blinkTimer = Timer.scheduledTimer(withTimeInterval: CursorBlink.phaseDuration(lit: blinkStateVisible),",
             what: "the cursor is lit 0.72 s, out 0.48 s", coveredBy: ["testTheCursorIsLitFor720msThenOutFor480ms"]),
        Site(file: "CursorBlink.swift",
             code: "timer = Timer.scheduledTimer(withTimeInterval: CursorBlink.phaseDuration(lit: isLit), repeats: false)",
             what: "the phone's cursor blinks as the Mac's, on CursorBlinker",
             coveredBy: ["testItIsLit720msThenOut480msThenLitAgain", "testATimerReplacedMeanwhileChangesNothing",
                         "thePhonesViewBlinksOnTheSharedBlinker", "testTheIOSCursorIsLitFor720msThenOutFor480ms"]),
        Site(file: "AboutViewModel.swift", code: "timerCancellable = Timer.publish(every: 3, on: .main, in: .common)",
             what: "About's icon changes every 3 s", coveredBy: [pinned, "advanceToNextIconWrapsWithinTheSingleIconOfficialSet"]),
        Site(file: "Tako+Crab.swift", code: "ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true)",
             what: "a command shows as running once it has run 3 s",
             coveredBy: ["commandShorterThanThresholdEndsIdleWithoutFlashingGreen", "tickBeforeThresholdDoesNotSetElapsedOrState"]),
        Site(file: "Tako+Crab.swift", code: "successTimer = Timer.scheduledTimer(withTimeInterval: Self.successLinger, repeats: false)",
             what: "done and failed go out 2 s after they show in the focused tab",
             coveredBy: ["aCommandsOutcomeInTheFocusedTabFadesAfterTwoSeconds", "anAgentsOutcomeInTheFocusedTabFadesAfterTwoSeconds"]),
        Site(file: "Tako+CrabLive.swift", code: "liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true)",
             what: "a quiet program sampled once a second: a ripple at most once a second, flowing for 3 s",
             coveredBy: ["aRippleIsASecondOfOutputNotALine", "threeSilentSecondsMakeItQuietAgain"]),
        Site(file: "Tako+Crab.swift", code: "ttlTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false)",
             what: "an agent's status expires after its TTL", coveredBy: [notMotion]),
        Site(file: "Tako+SurfaceCommandStart.swift", code: "Timer.scheduledTimer(withTimeInterval: delay, repeats: false)",
             what: "asks again which command started", coveredBy: [notMotion]),
        Site(file: "GlobalEventTap.swift", code: "enableTimer = Timer.scheduledTimer(withTimeInterval: system.pollInterval, repeats: true)",
             what: "polls whether the global event tap is still on", coveredBy: [notMotion]),
        Site(file: "AppUpdater.swift", code: "let timer = Timer(timeInterval: interval, repeats: true)",
             what: "checks for updates", coveredBy: [notMotion]),
        Site(file: "LayoutRecorder.swift", code: "timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true)",
             what: "records the window layout", coveredBy: [notMotion]),
        Site(file: "SessionSnapshots.swift", code: "timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true)",
             what: "saves session snapshots", coveredBy: [notMotion]),
        Site(file: "ControlCommand.swift", code: "Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true)",
             what: "a takoctl command polls for its outcome", coveredBy: [notMotion]),
        Site(file: "PromptManager.swift", code: "let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true)",
             what: "polls for a prompt's answer", coveredBy: [notMotion]),
        Site(file: "ControlCommands+Dialog.swift", code: "Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true)",
             what: "waits for a dialog to close", coveredBy: [notMotion]),
        Site(file: "ExpiringUndoManager.swift", code: "self.timer = Timer.scheduledTimer(",
             what: "an undo expires (⌘Z within 5 s)", coveredBy: [notMotion]),
        Site(file: "TabGroupCloseCoordinator.swift", code: "debounceTimer = Timer.scheduledTimer(",
             what: "debounces closing a tab group", coveredBy: [notMotion]),
    ]

    /// What the census counts as an animation.
    static let animationAPI = try! NSRegularExpression(pattern:
        #"Timer\.scheduledTimer\(|Timer\(timeInterval|Timer\.publish\(|withAnimation\(|\.animation\(|\.transition\(|NSAnimationContext\.runAnimationGroup|\.animator\(\)|CABasicAnimation\(|CAKeyframeAnimation\(|CAAnimationGroup\(|CASpringAnimation\(|CATransition\(|TimelineView\(|repeatForever|displayLink\(|CADisplayLink|phaseAnimator|keyframeAnimator|matchedGeometryEffect"#)

    /// The package's `swift` directory, from this file's place in it.
    static var swiftRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func swiftFiles(under folder: String) -> [URL] {
        let root = swiftRoot.appendingPathComponent(folder)
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Every line of the app's sources that animates, by file name, read once.
    static func animationLines() -> [(file: String, line: String)] { scanned }

    private static let scanned: [(file: String, line: String)] = scan()

    private static func scan() -> [(file: String, line: String)] {
        swiftFiles(under: "Sources").flatMap { url -> [(String, String)] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("*") else { return nil }
                let range = NSRange(line.startIndex..., in: line)
                return animationAPI.firstMatch(in: line, range: range) == nil ? nil : (url.lastPathComponent, line)
            }
        }
    }

    @Test func everyAnimationInTheAppIsInTheCensus() {
        let lines = Self.animationLines()
        #expect(lines.count >= 40, "only \(lines.count) animation lines found: the sources are not where the census looks")
        for (file, line) in lines where !Self.census.contains(where: { $0.file == file && line.contains($0.code) }) {
            Issue.record("an animation the census does not know: \(file): \(line)")
        }
    }

    @Test(arguments: census)
    func aCensusEntryStillReadsAsItDid(_ site: Site) {
        let lines = Self.animationLines().filter { $0.file == site.file }
        #expect(lines.contains { $0.line.contains(site.code) }, "\(site.file) no longer has `\(site.code)`: what moves changed")
    }

    @Test func everyTestTheCensusNamesExists() {
        let tests = Self.swiftFiles(under: "Tests").map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined()
        for site in Self.census {
            for name in site.coveredBy where name != Self.pinned && name != Self.notMotion && !tests.contains("func \(name)(") {
                Issue.record("\(site.file): \(site.what) names a test that is gone: \(name)")
            }
        }
    }

    // MARK: - Motion with no other test

    /// The phone's view is built only for the phone, so the Mac cannot run
    /// it: it blinks on `CursorBlinker`, which the Mac does run.
    @Test func thePhonesViewBlinksOnTheSharedBlinker() throws {
        let ui = Self.swiftRoot.appendingPathComponent("Sources/TakoCoreUI")
        let view = try String(contentsOf: ui.appendingPathComponent("TakoTerminalView.swift"), encoding: .utf8)
        let display = try String(contentsOf: ui.appendingPathComponent("TakoTerminalView+Display.swift"), encoding: .utf8)
        let metal = try String(contentsOf: ui.appendingPathComponent("TakoTerminalView+Metal.swift"), encoding: .utf8)
        #expect(view.contains("lazy var blinker = CursorBlinker("))
        #expect(view.contains("var blinkStateVisible: Bool { blinker.isLit }"))
        #expect(display.contains("blinker.restart()"))
        #expect(metal.contains("cursorBlinkPhaseOn = theme.cursorBlink ? blinkStateVisible : true"), "the drawn cursor follows the blink")
        #expect(!display.contains("Timer.") && !view.contains("Timer.scheduledTimer"), "the phone's view times no blink of its own")
    }

    @Test func theResizeEdgeLightsAndGoesOutIn120ms() throws {
        let grip = SessionSidebarGripView(frame: NSRect(x: 0, y: 0, width: 12, height: 300))
        grip.layout()
        let edge = try #require(grip.layer?.sublayers?.first)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        #expect(edge.opacity == 0)
        grip.mouseEntered(with: event)
        let lighting = try #require(edge.animation(forKey: "opacity"))
        #expect(edge.opacity == 1 && abs(lighting.duration - 0.12) < 0.001)
        grip.mouseExited(with: event)
        let dimming = try #require(edge.animation(forKey: "opacity"))
        #expect(edge.opacity == 0 && abs(dimming.duration - 0.12) < 0.001)
    }

    @Test func theQuickTerminalSlidesOnItsConfiguredTimeEaseIn() throws {
        let file = Self.swiftFiles(under: "Sources").first { $0.lastPathComponent == "QuickTerminalController+Animation.swift" }
        let source = try String(contentsOf: try #require(file), encoding: .utf8)
        // Both ways, in and out: the configured duration (0.2 s by default) on ease-in.
        #expect(source.components(separatedBy: "context.duration = derivedConfig.quickTerminalAnimationDuration").count - 1 == 2)
        #expect(source.components(separatedBy: "context.timingFunction = .init(name: .easeIn)").count - 1 == 2)
        #expect(try TemporaryConfig("").quickTerminalAnimationDuration == 0.2)
    }
}
