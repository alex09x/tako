#!/usr/bin/env bash
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Drive the built macOS app with real key presses and clicks, and check what
# the shell inside it received. See scripts/e2e/tako-e2e.swift.
#
#   ./scripts/e2e-macapp.sh                # every scenario
#   ./scripts/e2e-macapp.sh paste copy     # only these
#
# Needs the logged-in GUI session of the test Mac and Accessibility
# permission for the process running it. Tako is brought to the front while
# it runs, and the app that was in front gets the focus back at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

compile_only=0
if [ "${1:-}" = "--compile-only" ]; then
    # Only the runner, for scripts/prebuilt.py pack: no app, no screen.
    compile_only=1
    shift
fi

# Test apps live where scripts/app_locations.py says: off any external
# volume, where macOS would ask for access on every new build.
APP="${APP:-${TAKO_APP_DIR:-$(python3 scripts/app_locations.py dir macapp-e2e)}/Tako.app}"
fallback="$(python3 scripts/app_locations.py dir macapp)/Tako.app"
if [ ! -d "$APP" ] && [ -d "$fallback" ]; then
    APP="$fallback"
fi
if [ $compile_only -eq 0 ]; then
    [ -d "$APP" ] || { echo "no app at $APP; run scripts/build-macapp.py first" >&2; exit 1; }
    python3 scripts/app_locations.py check-app "$APP"
fi

mkdir -p target
started=$(date +%s)
sources=(scripts/e2e/DriverCore.swift scripts/e2e/DriverEvents.swift scripts/e2e/DriverAX.swift scripts/e2e/DriverAXControls.swift scripts/e2e/DriverPTY.swift scripts/e2e/ScenariosDialogsAndTabs.swift scripts/e2e/ScenariosHumanInteractions.swift scripts/e2e/ScenariosKittyGraphics.swift scripts/e2e/ScenariosSessionRecovery.swift scripts/e2e/SessionRecoveryDeferralJourney.swift scripts/e2e/ScenariosSessionCollision.swift scripts/e2e/ScenariosSidebarWorkspaceMove.swift scripts/e2e/ScenariosSidebarStyleSettings.swift scripts/e2e/ScenariosSidebarRename.swift scripts/e2e/ScenariosMovePaneToTab.swift scripts/e2e/ScenariosSidebarSwitchSpeed.swift scripts/e2e/OwnedProcesses.swift scripts/e2e/DriverLifecycleSelfTest.swift scripts/e2e/SettingsPage.swift scripts/e2e/ScenariosActivitySoundSettings.swift scripts/e2e/ScenariosRecoveryGrouping.swift scripts/e2e/ScenariosLegacyWorkspaceRecovery.swift scripts/e2e/ScenariosAppearanceSettings.swift scripts/e2e/ScenariosScopedAppearance.swift scripts/e2e/ScenariosThemePresets.swift scripts/e2e/ScenariosThemeControl.swift scripts/e2e/ScenariosThemeTypography.swift scripts/e2e/DesktopKeys.swift scripts/e2e/ScenariosDesktopSettings.swift scripts/e2e/ReflowRows.swift scripts/e2e/ScenariosPersistReflow.swift scripts/e2e/DriverFixtureTabs.swift scripts/e2e/DriverWorkspaceMenu.swift scripts/e2e/WorkspaceFrameSyncSetting.swift scripts/e2e/ScenariosWorkspaceSwitchSpeed.swift scripts/e2e/ScenariosWorkspaceVisibility.swift scripts/e2e/tako-e2e.swift)
sources+=(scripts/e2e/DriverControlRequests.swift scripts/e2e/ControlRequestSocketSelfTest.swift)
sources+=(scripts/e2e/ScenariosAppSelftestScroll.swift)
sources+=(scripts/e2e/DriverSample.swift)
# Persistence runs use this same driver with a fresh bundle for each case.
# Include the compiler and this script (its flags/source list) in the key.
# The script by its path from the repository root, not as invoked: shasum
# prints the name, and ./scripts/… and scripts/… gave two keys for one
# runner, so the shared runner was recompiled.
fingerprint=$({ swiftc --version; shasum -a 256 scripts/e2e-macapp.sh "${sources[@]}"; } | shasum -a 256 | cut -d' ' -f1)
if [ ! -x target/tako-e2e ] || [ "$(cat target/tako-e2e.inputs 2>/dev/null || true)" != "$fingerprint" ]; then
    swiftc -O -o target/tako-e2e.next "${sources[@]}"
    mv -f target/tako-e2e.next target/tako-e2e
    printf '%s\n' "$fingerprint" > target/tako-e2e.inputs
    echo "[timing] e2e runner compiled in $(( $(date +%s) - started ))s" >&2
else
    echo '[timing] e2e runner unchanged; using cached executable' >&2
fi
[ $compile_only -eq 0 ] || exit 0
exec python3 scripts/gui_lock.py -- target/tako-e2e "$APP" "$@"
