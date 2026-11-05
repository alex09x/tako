#!/usr/bin/env python3
# tako — macOS privacy purpose strings for user-requested capabilities
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

from pathlib import Path


ENTITLEMENTS = Path(__file__).resolve().parents[1] / "swift/Resources/Tako.entitlements"

PRIVACY_USAGE_DESCRIPTIONS = {
    "NSMicrophoneUsageDescription": "Allow microphone access for an audio feature you choose. Setup does not start a recording.",
    "NSAudioCaptureUsageDescription": "A program you run may request to record system audio. Only allow this when you intend to record.",
    "NSLocalNetworkUsageDescription": "Tako and programs you run use the local network to connect to devices and development services you choose.",
    "NSAppleEventsUsageDescription": "A program you run wants to control another app with AppleScript. Only allow this when you requested it.",
    "NSDesktopFolderUsageDescription": "A program you run wants to access files on your Desktop.",
    "NSDocumentsFolderUsageDescription": "A program you run wants to access files in Documents.",
    "NSDownloadsFolderUsageDescription": "A program you run wants to access files in Downloads.",
    "NSNetworkVolumesUsageDescription": "A program you run wants to access files on a network volume.",
    "NSRemovableVolumesUsageDescription": "A program you run wants to access files on a removable volume.",
}
