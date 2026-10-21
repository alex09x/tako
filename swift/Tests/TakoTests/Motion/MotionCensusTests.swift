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
    /// When a dialog shows or focus moves: a delay in what Tako does, not
    /// motion the design draws.
    static let delayedAction = "delayed action"
    /// The phone's app: no test target builds it.
    static let phoneApp = "phone app"

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
             what: "SwiftUI live ripple, 0.3 s ease-out", coveredBy: ["aLiveCardsRippleGrowsAndFadesOncePerBurst", "aLiveRippleGrowsAndFadesWithEaseOutIn300ms"]),
        Site(file: "Tako+LivingSurface.swift", code: ".animation(.easeOut(duration: 0.25), value: clamped)",
             what: "a card's arc eases to a new percentage in 0.25 s (no spec; the layer's arc moves at once)",
             coveredBy: ["aCardsArcEasesToItsNewShareOverAQuarterSecond", "aCardsArcShadesRustToEmber"]),
        Site(file: "SessionSidebarRowClock.swift", code: "TimelineView(.animation(minimumInterval: LivingMotion.minimumFrameInterval(for: state), paused: paused || !moving))",
             what: "a row's clock: frames only while it moves (the failed shake, snapshots)",
             coveredBy: ["aFailedRowShakesOnItsLiveClockAndStops", "aFailedRowShakesAsAWhole", "movingSidebarRowsLayNothingOutWhileTheyMove", "aRowThatFinishesKeepsItsPopThroughTheLayoutAfter"]),
        Site(file: "PaneOverviewView.swift", code: "TimelineView(.animation(minimumInterval: Self.minimumFrameInterval(oneOffRemaining: oneOff),",
             what: "the Overview's 30 frames a second, every frame for a one-off",
             coveredBy: ["aCardPlayingAOneOffTakesEveryFrameUntilItRests", "lastingMotionsRestAndReducedMotionStayAtThirty"]),
        Site(file: "PaneOverviewView.swift", code: "withAnimation(.easeInOut(duration: 0.15)) {",
             what: "the Overview scrolls to the chosen card in 0.15 s", coveredBy: ["theOverviewScrollsToItsChoiceOverAMoment"]),
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
             what: "secure input's ring turns every 2 s", coveredBy: ["secureInputsRingTurnsAndItsGlowPulses"]),
        Site(file: "SecureInputOverlay.swift", code: "withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: true)) {",
             what: "secure input's glow pulses every 2 s", coveredBy: ["secureInputsRingTurnsAndItsGlowPulses"]),
        Site(file: "Tako+SurfaceUI.swift", code: ".transition(.opacity)",
             what: "a pane's overlays fade in and out", coveredBy: ["aFileOverlayFadesInOverThePaneAndOut"]),
        Site(file: "Tako+SurfaceUI.swift", code: ".animation(.easeInOut(duration: 0.15), value: coveringOverlays)",
             what: "a pane's covering overlays fade over 0.15 s", coveredBy: ["aFileOverlayFadesInOverThePaneAndOut"]),
        Site(file: "CyclingIconView.swift", code: ".animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)",
             what: "About's icon eases 0.5 s to the next -- of a set of one (.official): it never changes", coveredBy: [notMotion]),
        // The quick terminal: slides in and out on its configured time, ease-in.
        Site(file: "QuickTerminalController+Animation.swift", code: "NSAnimationContext.runAnimationGroup({ context in",
             what: "the quick terminal slides on quick-terminal-animation-duration (0.2 s), ease-in",
             coveredBy: ["initialOriginForEachPosition", "finalOriginForEachPosition", "theQuickTerminalSlidesOnItsConfiguredTimeEaseIn"]),
        Site(file: "QuickTerminalController+Animation.swift", code: "in: window.animator(),",
             what: "the quick terminal's frame, animated", coveredBy: ["setInitialMakesWindowInvisibleAndUsesConfiguredSizeWhenNoClosedFrame",
                                                                     "setFinalMakesWindowVisibleAndUsesConfiguredSizeWhenNoClosedFrame"]),
        // The terminal's own frames.
        Site(file: "TakoTerminalNSView+Presentation.swift", code: "let link = self.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))",
             what: "the terminal's frames on macOS", coveredBy: ["testPresentationPauseTransitionsAreIdempotent"]),
        Site(file: "TakoTerminalNSView.swift", code: "var displayLink: CADisplayLink?",
             what: "the terminal's display link", coveredBy: ["testPresentationPauseTransitionsAreIdempotent"]),
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
             what: "the iOS SSH form scrolls to the passphrase in 0.2 s once a key is pasted", coveredBy: [phoneApp]),
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
             what: "About's icon cycles every 3 s -- through a set of one (.official): nothing changes on screen", coveredBy: [notMotion]),
        Site(file: "Tako+Crab.swift", code: "ticker = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true)",
             what: "a command shows as running once it has run 3 s",
             coveredBy: ["aCommandTurnsWorkingWhenItsTickerFindsItHasRun3s", "theClocksAreTheSpecs"]),
        Site(file: "Tako+Crab.swift", code: "successTimer = Timer.scheduledTimer(withTimeInterval: linger, repeats: false)",
             what: "done and failed go out 2 s after they show in the focused tab",
             coveredBy: ["anOutcomeInTheFocusedTabGoesOutWhenItsTimerFires", "theClocksAreTheSpecs",
                         "aCommandsOutcomeInTheFocusedTabFadesAfterTwoSeconds"]),
        Site(file: "Tako+CrabLive.swift", code: "liveTimer = Timer.scheduledTimer(withTimeInterval: liveSampleInterval, repeats: true)",
             what: "a quiet program sampled once a second: a ripple at most once a second, flowing for 3 s",
             coveredBy: ["aQuietProgramIsSampledByItsOwnTimer", "theClocksAreTheSpecs", "aRippleIsASecondOfOutputNotALine",
                         "threeSilentSecondsMakeItQuietAgain"]),
        Site(file: "Tako+Crab.swift", code: "ttlTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false)",
             what: "an agent's status expires after its TTL, and its ring with it", coveredBy: ["ttlExpiryRevertsStatusToUnknown"]),
        Site(file: "Tako+SurfaceCommandStart.swift", code: "Timer.scheduledTimer(withTimeInterval: delay, repeats: false)",
             what: "a command the shell did not name is looked up: a quiet one turns its ring live",
             coveredBy: ["aCommandTheShellDidNotNameGoesLiveWhenWhatRunsInFrontIsQuiet"]),
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
        // Delays and clocks: asyncAfter, Task.sleep, the display's clock, implicit animation, spinners.
        Site(file: "HostKeyPrompt.swift", code: #"try await Task.sleep(nanoseconds: 1_000_000_000)"#,
             what: "the phone: a new host key's buttons arm after 1 s", coveredBy: [phoneApp]),
        Site(file: "LaunchProbe.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {"#,
             what: "the phone's launch probe, a test harness", coveredBy: [notMotion]),
        Site(file: "LaunchProbe.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {"#,
             what: "the phone's launch probe, a test harness", coveredBy: [notMotion]),
        Site(file: "LaunchProbe.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + stepPause) {"#,
             what: "the phone's launch probe, a test harness", coveredBy: [notMotion]),
        Site(file: "SessionListScreen.swift", code: #"try? await Task.sleep(nanoseconds: 750_000_000)"#,
             what: "the phone: the host-key prompt waits 750 ms after connect", coveredBy: [phoneApp]),
        Site(file: "SessionListScreen.swift", code: #"ProgressView().tint(Brand.ember)"#,
             what: "the phone: a spinner while connecting", coveredBy: [phoneApp]),
        Site(file: "TerminalScreen.swift", code: #"ProgressView().controlSize(.small).tint(Brand.claw)"#,
             what: "the phone: a spinner while connecting", coveredBy: [phoneApp]),
        Site(file: "AppDelegate+Events.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {"#,
             what: "turns the global event tap on again", coveredBy: [notMotion]),
        Site(file: "AppDelegate+Launch.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {"#,
             what: "checks for updates after launch", coveredBy: [notMotion]),
        Site(file: "SessionSidebarRowView.swift", code: #"try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))"#,
             what: "a row rests once its one-off has played", coveredBy: ["aFailedRowTakesFramesWhileItShakesAndNoneOnceItRests"]),
        Site(file: "ConfigurationErrorsNotice.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + delay) {"#,
             what: "the config-errors dialog waits for a window", coveredBy: [delayedAction]),
        Site(file: "AppUpdater+Install.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {"#,
             what: "quits for the installer", coveredBy: [notMotion]),
        Site(file: "TerminalController+Creation.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {"#,
             what: "relabels native tabs, which Tako never shows", coveredBy: [notMotion]),
        Site(file: "TerminalRestorable.swift", code: #"DispatchQueue.main.asyncAfter(deadline: after) {"#,
             what: "restores focus once a view has its window", coveredBy: [delayedAction]),
        Site(file: "TerminalWindow.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in"#,
             what: "relabels native tabs, which Tako never shows", coveredBy: [notMotion]),
        Site(file: "TitlebarTabsVenturaTerminalWindow.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.relabelTabs() }"#,
             what: "relabels native tabs, which Tako never shows", coveredBy: [notMotion]),
        Site(file: "TransparentTitlebarTerminalWindow.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in"#,
             what: "the transparent titlebar takes its colours again", coveredBy: [delayedAction]),
        Site(file: "WhatsNewNotice.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {"#,
             what: "What's New shows 0.8 s after launch", coveredBy: [delayedAction]),
        Site(file: "SessionEnding.swift", code: #"try? await Task.sleep(nanoseconds: 300_000_000)"#,
             what: "the leftovers dialog waits for a window", coveredBy: [delayedAction]),
        Site(file: "CrossSessionSearch.swift", code: #"try? await Task.sleep(for: debounce)"#,
             what: "search across tabs waits for typing to pause", coveredBy: [delayedAction]),
        Site(file: "CrossSessionSearch.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in"#,
             what: "the chosen hit is selected once focus settles", coveredBy: [delayedAction]),
        Site(file: "InputOwnershipHeaderView.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in"#,
             what: "Copied! shows 1.5 s", coveredBy: ["copiedShowsForAMomentAndAnotherCopyKeepsItsOwn"]),
        Site(file: "AgentHooksTool.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 1.5 : 0.4)) {"#,
             what: "the agent hooks offer shows after launch", coveredBy: [delayedAction]),
        Site(file: "CommandLineTool.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {"#,
             what: "the takoctl offer shows after launch", coveredBy: [delayedAction]),
        Site(file: "ControlLayout.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }"#,
             what: "a takoctl layout question polls for its answer", coveredBy: [notMotion]),
        Site(file: "ControlLayout.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }"#,
             what: "a takoctl layout question polls for its answer", coveredBy: [notMotion]),
        Site(file: "QuickTerminalController+Animation.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {"#,
             what: "the quick terminal takes focus after it slides", coveredBy: [delayedAction]),
        Site(file: "QuickTerminalController+Animation.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {"#,
             what: "the quick terminal takes focus after it slides", coveredBy: [delayedAction]),
        Site(file: "Tako+App.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {"#,
             what: "the app's self-test starts", coveredBy: [notMotion]),
        Site(file: "Tako+AppSelfTest.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {"#,
             what: "the app's self-test reads the screen", coveredBy: [notMotion]),
        Site(file: "Tako+SurfaceFilter.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in"#,
             what: "a system notification is taken back after its time", coveredBy: [delayedAction]),
        Site(file: "Tako+SurfaceFilter.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: item)"#,
             what: "search hits are recounted after output pauses", coveredBy: [delayedAction]),
        Site(file: "Tako+SurfaceModels.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: move)"#,
             what: "focus moves to another pane after a delay", coveredBy: [delayedAction]),
        Site(file: "Tako+SurfaceWatchdog.swift", code: #"DispatchQueue.main.asyncAfter("#,
             what: "a synchronized frame left open is drawn after 200 ms", coveredBy: ["aSynchronizedFrameLeftOpenIsDrawnAfter200ms", "aSynchronizedFrameClosedInTimeIsNotForced"]),
        Site(file: "Tako+TabBarInput.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandBadgeDelay, execute: work)"#,
             what: "the tab numbers show after ⌘ is held 150 ms", coveredBy: ["theTabNumbersShowAfterCommandIsHeld150ms"]),
        Site(file: "Tako+TabBarMotion.swift", code: #"func displayedChipWidth(target: CGFloat, now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {"#,
             what: "the strip's chip slide and pill shake run on the display's clock", coveredBy: ["theChipSlidesToItsNewWidthInsteadOfJumping", "aPillThatFailsShakesOnTheDesignsCurveFromThatMoment", "motionThatRanItsTimeEndsUndrawn"]),
        Site(file: "Tako+TabBarMotion.swift", code: #"now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {"#,
             what: "the strip's chip slide and pill shake run on the display's clock", coveredBy: ["theChipSlidesToItsNewWidthInsteadOfJumping", "aPillThatFailsShakesOnTheDesignsCurveFromThatMoment", "motionThatRanItsTimeEndsUndrawn"]),
        Site(file: "Tako+TabBarMotion.swift", code: #"func expireMotion(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {"#,
             what: "the strip's chip slide and pill shake run on the display's clock", coveredBy: ["theChipSlidesToItsNewWidthInsteadOfJumping", "aPillThatFailsShakesOnTheDesignsCurveFromThatMoment", "motionThatRanItsTimeEndsUndrawn"]),
        Site(file: "Tako+TabBarWorkspace.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in"#,
             what: "the new-workspace dialog and a workspace switch wait for a menu to close", coveredBy: [delayedAction]),
        Site(file: "Tako+TabBarWorkspace.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {"#,
             what: "the new-workspace dialog and a workspace switch wait for a menu to close", coveredBy: [delayedAction]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"CATransaction.setDisableActions(!allowFrameAnimation)"#,
             what: "a dragged pill's layer follows it smoothly", coveredBy: ["aDraggedPillsLayerFollowsItSmoothlyAndOtherwiseAtOnce"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"let pausedTime = convertTime(CACurrentMediaTime(), from: nil)"#,
             what: "a paused layer holds its frame and goes on where it stopped", coveredBy: ["aPausedPillShowsTheSameFrameWhateverTheClock", "aHiddenSurfaceStandsStillAndGoesOnWhereItStopped"]),
        Site(file: "Tako+TabStatusLayer.swift", code: #"beginTime = convertTime(CACurrentMediaTime(), from: nil) - pausedTime"#,
             what: "a paused layer holds its frame and goes on where it stopped", coveredBy: ["aPausedPillShowsTheSameFrameWhateverTheClock", "aHiddenSurfaceStandsStillAndGoesOnWhereItStopped"]),
        Site(file: "Tako+TabStripTransitions.swift", code: #"static var clock: () -> CFTimeInterval = { CACurrentMediaTime() }"#,
             what: "the strip's transitions run on the display's clock", coveredBy: ["aNewTabGrowsFromNothingIn160msAndItsContentComesAfter", "theDropSpringOvershootsAFewPercentAndSettles"]),
        Site(file: "MetalTerminalRenderer.swift", code: #"var customShaderClock: () -> CFTimeInterval = { CACurrentMediaTime() }"#,
             what: "a custom shader animates on its own clock", coveredBy: ["testAlwaysAnimatesUnfocused", "testTrueAnimatesOnlyWhileFocused", "testNoShaderOrABrokenOneNeverAnimates"]),
        Site(file: "TakoTerminalNSView+Drawing.swift", code: #"DispatchQueue.main.asyncAfter("#,
             what: "the grid takes the last size once a resize settles", coveredBy: ["testTheGridTakesTheLastSizeOnceTheResizeSettles"]),
        Site(file: "TakoTerminalNSView+Presentation.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)"#,
             what: "a capped surface lets its next frame through after its throttle", coveredBy: ["testAPresentationThrottleLetsTheNextFrameThroughAfterItsDelay"]),
        Site(file: "TakoTerminalView+Display.swift", code: #"DispatchQueue.main.asyncAfter("#,
             what: "the phone's grid takes the last size once a resize settles (scripts/check.sh ios)", coveredBy: ["testThePhonesGridTakesTheLastSizeOnceTheResizeSettles"]),
        Site(file: "PaneOverviewView.swift", code: #"try? await Task.sleep(nanoseconds: UInt64(oneOff * 1_000_000_000))"#,
             what: "the Overview goes back to 30 a second once a one-off has played", coveredBy: ["aOneOffTakesEveryFrameUntilItRestsThenThirtyAgain"]),
        Site(file: "PaneOverviewView.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {"#,
             what: "the Overview's first frame is still, its clock starts 0.05 s later", coveredBy: ["theOverviewTakesThirtyFramesASecondAtRest"]),
        Site(file: "PaneOverviewView.swift", code: #"DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isSearchFieldFocused = true }"#,
             what: "the Overview's search field takes focus", coveredBy: [delayedAction]),
    ]

    /// What the census counts as an animation.
    static let animationAPI = try! NSRegularExpression(pattern:
        #"asyncAfter\(|Task\.sleep|CACurrentMediaTime\(\)|setDisableActions\(!|ProgressView\(|Timer\.scheduledTimer\(|Timer\(timeInterval|Timer\.publish\(|withAnimation\(|\.animation\(|\.transition\(|NSAnimationContext\.runAnimationGroup|\.animator\(\)|CABasicAnimation\(|CAKeyframeAnimation\(|CAAnimationGroup\(|CASpringAnimation\(|CATransition\(|TimelineView\(|repeatForever|displayLink\(|CADisplayLink|phaseAnimator|keyframeAnimator|matchedGeometryEffect"#)

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
            for name in site.coveredBy where ![Self.pinned, Self.notMotion, Self.delayedAction, Self.phoneApp].contains(name)
                && !tests.contains("func \(name)(") {
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
