#!/usr/bin/env bash
#
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Runs the phone app's hosted unit tests (ios/UnitTests) on the simulator.
#   scripts/mac-remote.sh scripts/ios-unit-test.sh [TestClass ...]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${TAKO_SIM_DEVICE:-iPhone 17 Pro}"
ONLY=()
for name in "$@"; do ONLY+=("-only-testing:TakoCoreUnitTests/$name"); done
xcodegen -s ios/project.yml -p ios --quiet
xcodebuild -project ios/TakoCore.xcodeproj -scheme TakoCore -configuration Debug \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath target/ios-sim-derived \
    ${ONLY[@]+"${ONLY[@]}"} test 2>&1 | grep -E "error:|Test Case|Executed|TEST (SUCCEEDED|FAILED)|XCTAssert" | tail -60
exit "${PIPESTATUS[0]}"
