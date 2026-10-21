/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

/// Every motion, effect, state and transition the design gives, with the
/// tests that hold the app to it -- or why the app does not do it. The pages
/// were read line by line for anything that moves or changes (each CSS
/// animation and keyframe, every "ms", "s", "ease", "spring", "steps",
/// "мига", "появл", "гаснут", "дышит", "один раз", "reduce motion"):
/// Terminal UI, Sessions UI (1b tabs, 4a sidebar, 4b Overview, 5a plain
/// sessions) and Mobile UI; TUI Dialogs has none. A test named here that is
/// gone fails the gate, as does an entry with neither a test nor a reason.
@Suite
struct MotionSpecLedgerTests {
    struct Item: Sendable, CustomTestStringConvertible {
        let page: String
        let says: String
        let tests: [String]
        /// Why the app does not do what the page says.
        var notBuilt: String?
        var testDescription: String { "\(page): \(says)" }
    }

    static func item(_ page: String, _ says: String, _ tests: String...) -> Item { Item(page: page, says: says, tests: tests) }
    static func notBuilt(_ page: String, _ says: String, because why: String, _ tests: String...) -> Item {
        Item(page: page, says: says, tests: tests, notBuilt: why)
    }

    static let terminal = "Terminal UI", sessions = "Sessions UI", mobile = "Mobile UI"

    static let ledger: [Item] = [
        // Terminal UI › «Вкладки: анатомия, состояния, переходы».
        item(terminal, "новая вкладка ⌘T 160ms ease-out, ширина 0 → полная, контент появляется после",
             "aNewTabGrowsFromNothingIn160msAndItsContentComesAfter", "theCurvesAreCSSs"),
        item(terminal, "закрытие ⌘W 140ms ease-in, схлопывается по ширине, соседи подъезжают",
             "aClosedTabCollapsesIn140msAndItsNeighboursCloseUp"),
        item(terminal, "переключение ⌃Tab 120ms, только полоса", "choosingATabMovesOnlyTheBarIn120ms"),
        item(terminal, "перестановка drag 120ms, соседи раздвигаются", "neighboursMakeRoomIn120msAndTheDroppedTabSpringsHome"),
        item(terminal, "отпустил — вкладка «пружинит» на позицию (spring 300/24)",
             "theDropSpringOvershootsAFewPercentAndSettles", "neighboursMakeRoomIn120msAndTheDroppedTabSpringsHome"),
        item(terminal, "drag подняли: тень 0 14px 30px rgba(0,0,0,.55), наклон −3°",
             "aDraggedTabIsLiftedAndFollowsThePointer", "aLiftedTabCastsItsShadowAndLeans"),
        item(terminal, "кнопки: ховер фон #241C16, появление 80ms", "aButtonsHoverComesInOver80ms", "aButtonsHoverFillIsTheDesigns241C16"),
        item(terminal, "тултипы через 800ms", "tooltipsShowAfter800ms"),
        item(terminal, "⌘-цифры только пока зажат ⌘ (задержка 150ms); отпустил — исчезли",
             "theTabNumbersShowAfterCommandIsHeld150ms"),
        item(terminal, "окно, которого не видно, принимает изменения сразу", "aStripNobodySeesTakesEveryChangeAtOnce",
             "aHiddenTabWindowTakesTheNewWidthAtOnceAndRunsNoFrames"),
        // Terminal UI › «Краб во вкладке: 7 состояний»: replaced by 1b. Classic tabs show the pills' ring.
        notBuilt(terminal, "краб во вкладке: семенит, подпрыгивает, дрожит, пульсирует, призрак",
                 because: "Alex, 2026-10-20: the crab is replaced by the 1b ring; classic tabs show the pills' ring, the page is out of date",
                 "theClassicStripDrawsEachTabWithTheRingAloneInItsSlot", "aClassicTabShowsItsPanesStateAndShakesWholeWhenItFails"),
        item(terminal, "классическая вкладка: кольцо 1b на месте краба, ⌘-цифра поверх, точка где нет ✕",
             "theClassicStripDrawsEachTabWithTheRingAloneInItsSlot", "theCommandBadgeCoversTheRing",
             "aBackgroundTabThatFailedShowsAClawDotWhereNoCloseIs", "aSurfaceShowsItsStateAsTheSpecDoes"),
        item(terminal, "классическая вкладка: упала — дрожит вся, как пилюля",
             "aClassicTabShowsItsPanesStateAndShakesWholeWhenItFails"),
        item(terminal, "приоритет: призрак > ошибка > работает > BEL > успех > покой", "priorityOrderMatchesDesignSpec"),
        item(terminal, "когда бежит: только если команда идёт >3s (по OSC 133 C→D)",
             "commandShorterThanThresholdEndsIdleWithoutFlashingGreen", "tickBeforeThresholdDoesNotSetElapsedOrState"),
        item(terminal, "после exit 0 в фоновой вкладке держится до переключения на неё",
             "anOutcomeInABackgroundTabHoldsUntilItIsSeen"),
        notBuilt(terminal, "41s — таймер с запуска команды, показывается при >3s",
                 because: "Alex, 2026-10-19: no ticking seconds in tabs, the sidebar or the Overview",
                 "aSidebarRowShowsTheProgramOrTheExitCodeNeverARate"),
        // Terminal UI › components and the terminal itself.
        item(terminal, "курсор: мигание 1.2s (60 % горит)", "testTheCursorIsLitFor720msThenOutFor480ms",
             "testATimerReplacedMeanwhileDoesNotBlink"),
        item(terminal, "курсор в расфокусе — контур 1px", "testBarAndUnderlineCursorsUseThinRectsAndUnfocusedDrawsAnOutline"),

        // Sessions UI › 1b, the living surface, on every surface (pill, row, pane, card).
        item(sessions, "работает: Ember-комета по рамке, один круг за 2.2s, по часовой",
             "theCometRunsClockwiseRoundTheBorderOnceIn2200ms", "aWorkingCardsCometRunsClockwiseRoundItOnceIn2200ms",
             "theSpinnerTurnsIn900msAndTheCometIn2200ms"),
        item(sessions, "кольцо работы 0.9s (.r-work spin .9s linear)", "theSpinnerTurnsClockwiseOnceIn900ms",
             "aWorkingCardsSpinnerTurnsClockwiseOnceIn900ms"),
        item(sessions, "ждёт тебя: Claw-рамка дышит 1.6s, α 0.4↔0.95, свечение 16px 30 %",
             "theWaitingBorderBreathesFromFortyToNinetyFivePercent", "theWaitingGlowSpreadsOutsideTheBorderAtTheBreathsPeak",
             "theWaitingGlowIsSixteenPixelsAtThirtyPercent", "aWaitingFrameBreathesFromFortyToNinetyFivePercent",
             "aWaitingCardsBorderBreathesAndItsGlowSpreads"),
        item(sessions, "ждёт: halo 1.6s ease-out, scale 1→2.1, opacity .75→0", "theHaloGrowsAndFadesEvery1600ms",
             "theWaitingHaloBlinkAndBreatheRepeatEvery1600ms"),
        item(sessions, "ждёт: точка мигает 1.6s до 25 %", "theDotBlinksToAQuarter"),
        item(sessions, "готово: зелёный блик «0.9s» один раз (CSS shimmer 0–30 % от 3.2s = 0.96s, его и держим), кольцо подпрыгивает",
             "theGlintCrossesLeftToRightOnceAndIsGone", "theGlintSweepsWithEaseOutIn960ms",
             "aDoneRingPopsSmallThenBigThenSettles", "thePopShrinksOvershootsAndSettlesOnTheDesignsBeats",
             "thePopAndTheGlintAreTakenOffWhenTheyHaveRun"),
        item(sessions, "увиденное впервые «готово» не вспыхивает", "aSurfaceFirstSeenDoneNeitherPopsNorGlints"),
        item(sessions, "ошибка: красная линия 2px снизу, дрожь «0.4s» один раз (CSS shake 0–14 % от 3.2s = 0.448s; 0, −2, 2, −2, 2, −1, 0)",
             "aFailedSurfaceHasARedDiscAndARedBaseline", "theShakeSwingsTwoPointsEachWayAndStops",
             "aPillThatFailsShakesOnTheDesignsCurveFromThatMoment", "aFailedRowShakesAsAWhole",
             "aFailedCardHasARedBaselineAndShakesItsRingOnTheDesignsBeats"),
        item(sessions, "прогресс: тонкая полоса Rust→Ember, кольцо-дуга", "theProgressLineRunsRustToEmberAcrossItsShare",
             "theProgressArcCoversItsShareClockwiseFromTheTop", "aCardsArcShadesRustToEmber"),
        item(sessions, "новый процент двигает дугу и полосу, ничего не перезапуская",
             "aNewPercentageMovesTheArcAndTheLineAndRebuildsNothing"),
        item(sessions, "строка сайдбара в прогрессе бежит кометой, вкладка — нет", "aRowInProgressRunsTheCometAndAPillDoesNot"),
        item(sessions, "offline: пунктирная рамка и кольцо", "anOfflineSurfaceHasADashedBorderAndADashedRing",
             "anOfflineCardHasADashedBorder"),
        item(sessions, "каждое состояние на каждой поверхности, и смена любого на любое",
             "aSurfaceShowsItsStateAsTheSpecDoes", "aChangeShowsTheNewStateAndNothingOfTheOld"),
        item(sessions, "приоритет: offline > ошибка > ждёт > работает > прогресс > готово > live > покой",
             "theRanksAreTheSpecsOrder", "aTabOfTwoPanesShowsTheOneRankedFirst", "aSessionRowOfTwoPanesShowsTheOneRankedFirst"),
        item(sessions, "на активной вкладке «готово» и «ошибка» гаснут через 2s, на фоновых держатся до фокуса",
             "aCommandsOutcomeInTheFocusedTabFadesAfterTwoSeconds", "anAgentsOutcomeInTheFocusedTabFadesAfterTwoSeconds",
             "anOutcomeInABackgroundTabHoldsUntilItIsSeen"),
        item(sessions, "только если команда идёт > 3s", "commandShorterThanThresholdEndsIdleWithoutFlashingGreen"),
        item(sessions, "reduce motion: статичная Ember-рамка; Claw-рамка и свечение 20 %; готово и ошибка — цвет",
             "underReduceMotionWorkingIsAStillEmberBorderAllRound", "underReduceMotionWaitingStandsStillWithAFaintGlow",
             "underReduceMotionDoneOnlyTurnsGreen", "underReduceMotionACardNeitherPopsNorBreathes",
             "reduceMotionAsTheSystemSetsItStopsAPillsRing",
             "turningReduceMotionOnAndOffMidStateFollowsIt"),
        item(sessions, "окно перекрыто или скрыто — анимации на паузе, статичный кадр",
             "aCoveredWindowPausesTheMotionAndUncoveredItGoesOn", "nobodySeesTakoOnlyWhenEveryWindowOnScreenIsCovered",
             "aHiddenSurfaceStandsStillAndGoesOnWhereItStopped", "aPausedPillShowsTheSameFrameWhateverTheClock",
             "aSidebarRowStandsStillWhileTheSidebarIsHidden"),
        notBuilt(sessions, "приложение неактивно дольше 30s — анимации на паузе",
                 because: "Alex, 2026-10-20: everything keeps moving without focus; only a window nobody can see pauses",
                 "takoInTheBackgroundKeepsMoving", "aCoveredWindowPausesTheMotionAndUncoveredItGoesOn"),
        item(sessions, "вкладки и строки сайдбара — только Core Animation на GPU, без перерисовки на каждый кадр (Overview рисует своими часами 30 кадров/с — решение Alex 2026-10-19)",
             "movingSidebarRowsLayNothingOutWhileTheyMove", "aRingOnASwiftUIClockLaysItsViewOutEveryFrame"),
        // 4a, the sidebar.
        item(sessions, "4a: активная сессия залита и отмечена Ember-полосой у края", "theActiveSessionIsFilledAndMarkedByAnEmberBarAtTheSidebarsEdge",
             "anotherSessionHasNoBar"),
        item(sessions, "4a: ждущая строка задаёт вопрос Claw-цветом", "aWaitingSessionAsksItsQuestionInClaw"),
        item(sessions, "точка непрочитанного Claw 5px держится до фокуса", "anUnreadSessionHasAClawDotOfFivePoints"),
        item(sessions, "чип «need you» в шапке дышит, только пока кто-то ждёт", "theNeedsYouRingPulsesOnlyWhileSomethingWaits"),
        // 4b, the Overview.
        item(sessions, "4b: выбор с клавиатуры — сплошная Ember-рамка 2px", "aSelectedCardHasASolidTwoPointEmberBorder"),
        item(sessions, "4b: выбранная ждущая карточка дышит Ember↔Claw (breatheSel 1.6s)", "aSelectedWaitingCardBreathesEmberToClaw"),
        item(sessions, "4b: карточка — тот же язык: комета, дыхание, блик, дрожь кольца",
             "aWorkingCardsCometRunsClockwiseRoundItOnceIn2200ms", "aDoneCardPopsItsRingAndGlintsOnce",
             "aCardInProgressRunsTheCometAndFillsItsArc"),
        item(sessions, "4b: 30 кадров в секунду в покое, каждый кадр на время «один раз»",
             "theOverviewTakesThirtyFramesASecondAtRest", "aOneOffTakesEveryFrameUntilItRestsThenThirtyAgain",
             "aPausedOverviewTakesNoFrames", "aCardPlayingAOneOffTakesEveryFrameUntilItRests"),
        // 5a, plain sessions: the live ring.
        item(sessions, "5a: кольцо Ember 100 % пока идут данные, 45 % в тишине",
             "aQuietLiveRingIsEmberAtFortyFivePercentOfAFlowingOne", "theRingIsDimEmberInSilenceAndFullWhileOutputArrives"),
        item(sessions, "5a: волна Claw 1→1.7, 0.95→0 за 0.3s ease-out", "aBurstRipplesTheLiveRingOutAndAway",
             "aLiveRippleGrowsAndFadesWithEaseOutIn300ms"),
        item(sessions, "5a: волна на порцию вывода, не чаще раза в секунду", "aLiveRingRipplesOncePerNewBurstWhileItFlows",
             "aRippleIsASecondOfOutputNotALine", "eachBurstRipplesOnceAndNothingElseDoes"),
        item(sessions, "5a: тихо больше 3 с — обратно в тишину", "threeSilentSecondsMakeItQuietAgain"),
        item(sessions, "5a: вывод в течение 150ms после клавиши — эхо, не считается",
             "outputJustAfterAKeystrokeIsItsEcho", "theEchoOfTypingIsNotOutput"),
        item(sessions, "5a: reduce motion — без волны", "aQuietRingOrReducedMotionNeverRipples",
             "noRippleInSilenceUnderReduceMotionOrWhileHidden"),
        item(sessions, "5a: скрытые окна не анимируются", "aPausedRingDoesNotRippleNorCatchUpAfter"),
        notBuilt(sessions, "5a: справа скорость «38/s», когда строк ≥ 2 в секунду",
                 because: "Alex, 2026-10-20: no N/s rate anywhere; the program's name stands there",
                 "denseOutputShowsTheProgramNotARate", "aSidebarRowShowsTheProgramOrTheExitCodeNeverARate"),

        // Mobile UI.
        item(mobile, "курсор блок, мигание 1.2s (60% on / 40% off)", "testItIsLit720msThenOut480msThenLitAgain",
             "testATimerReplacedMeanwhileChangesNothing", "testHeldOutputKeepsThePhaseAndTheChainGoesOn",
             "thePhonesViewBlinksOnTheSharedBlinker", "testTheIOSCursorIsLitFor720msThenOutFor480ms"),
        notBuilt(mobile, "шит «Новая сессия»: появление 300ms spring (damping 0.85)",
                 because: "the phone shows it as the system sheet, whose spring iOS sets"),
        notBuilt(mobile, "iOS: тот же краб в шапке сессии; в списке сессий — вместо цветной точки",
                 because: "Alex, 2026-10-20: the crab is replaced by the 1b ring; the page is out of date"),
    ]

    /// Every test function the package has, by name.
    static let testNames: Set<String> = {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let walk = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        let files = (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        let declaration = try! NSRegularExpression(pattern: #"func (\w+)\("#)
        var names: Set<String> = []
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
            }
        }
        return names
    }()

    @Test(arguments: ledger)
    func whatTheDesignSaysATestHolds(_ item: Item) {
        if let why = item.notBuilt {
            #expect(!why.isEmpty)
        } else {
            #expect(!item.tests.isEmpty, "nothing holds it")
        }
        for name in item.tests where !Self.testNames.contains(name) {
            Issue.record("\(name) is gone")
        }
    }

    @Test func theLedgerFindsTheTestsItLooksFor() {
        #expect(Self.testNames.count > 1_000, "only \(Self.testNames.count) tests found: the scan looks in the wrong place")
        #expect(Self.testNames.contains("whatTheDesignSaysATestHolds"))
    }
}
