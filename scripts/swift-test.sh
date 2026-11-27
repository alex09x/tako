#!/bin/bash
# tako — Swift package tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# `swift test` for the app layer, against the tako-core release that
# swift/Package.swift pins, exactly as Package.resolved records it.
#
# Several AppKit tests synchronously talk to NSPasteboard and WindowServer.
# Swift Testing's parallel scheduling can leave those calls mutually blocked,
# so the repository-wide entry point deliberately runs them serially.
set -e
cd "$(dirname "$0")/../swift"
exec swift test --force-resolved-versions "$@"
