#!/bin/bash
# tako — iOS Xcode project generation
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Generates ios/TakoCore.xcodeproj from ios/project.yml and gives it the
# package lockfile swift/Package.resolved records, so Xcode resolves tako-core
# to the same commit the direct builds use. Build it with
# `xcodebuild -onlyUsePackageVersionsFromResolvedFile`, which refuses any
# other resolution.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen -s ios/project.yml -p ios --quiet
lock=ios/TakoCore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$lock"
cp swift/Package.resolved "$lock/Package.resolved"
