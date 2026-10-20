#!/bin/bash
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# The motion gate: every test that holds Tako's animations, effects, states
# and transitions to the design (Sessions UI 1b/4a/4b/5a, Terminal UI), in one
# run on the test Mac -- the status layer's states and changes on every
# surface, frames of each drawn by Core Animation and by SwiftUI, the tab
# strip's shake and slide, a classic tab's ring, priorities, the rules behind
# the states, the cost of moving, the cursor's blink, and the ledger that
# ties every line of the design to its tests. scripts/motion-mutants.py proves it fails
# when any of that is broken.
#
#   export TAKO_MAC=user@test-mac.local
#   scripts/motion-gate.sh            # run it
#   scripts/motion-gate.sh --filter   # print the test filter only
set -euo pipefail
cd "$(dirname "$0")/.."

SUITES=(
    Motion                      # the spec matrices, frames, cards, priorities, cost, tab strip
    DoneGlintRenderingTests
    OverviewFrameRateTests
    LivingSurface               # 1b spec rules and the frame export
    LiveSpec5aTests
    CrabLiveTests
    LiveActivityLabelTests
    OverviewLiveTests
    OutputActivityMeterTests
    SidebarLiveRowTests
    PaneStatusTests
    TabStatusLifecycleTests
    CrabTrackerCoverageTests    # the crab's states, priority, the 3 s and 2 s rules
    CrabTabBindingCoverageTests
    QuietSinceTests
    QuietChromeTests
    NoTimerTests
    UnreportedCommandTests
    CursorBlinkCadenceTests
    CursorBlinkerTests          # the phone's blink, run on the Mac
    UnfocusedDrawsAnOutline     # the unfocused cursor's 1 pt outline
    TabBar                      # the strip's states and drawing (pill, classic, controller)
    QuickTerminalPositionTests  # where the quick terminal slides from and to
    SecureInputOverlayTests
    AboutCoverageTests
    InputOwnershipTests
    TerminalTouchScrollTests    # kinetic scrolling (iOS)
    TabBarClose                 # closing from the strip's ✕
    clickingTheTabBarCloseButton
)
FILTER=$(IFS='|'; echo "${SUITES[*]}")

if [ "${1:-}" = "--filter" ]; then
    echo "$FILTER"
    exit 0
fi
python3 scripts/motion-mutants.py --check
exec scripts/check.sh "swift:$FILTER"
