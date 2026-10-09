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
set -euo pipefail

echo "================================================================================"
echo "TAKO CODESIGN & TCC IDENTITY PROBE REPORT"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "================================================================================"

echo -e "\n[1. Host & Shell Session Details]"
echo "Host: $(hostname)"
echo "Kernel: $(uname -a)"
echo "UID/GID: $(id)"
echo "Login Shell: $SHELL"
echo "Parent PID: $PPID"
echo "Process Tree:"
ps -p $$ -o pid,ppid,user,command
ps -p $PPID -o pid,ppid,user,command || true

echo -e "\n[2. Code Signing: Tako.app (E2E Test Bundle: com.tako-core.terminal.e2e)]"
E2E_APP="target/macapp-e2e/Tako.app"
if [ -d "$E2E_APP" ]; then
    codesign -dvvv "$E2E_APP" 2>&1
    echo "Entitlements:"
    codesign -d --entitlements - "$E2E_APP" 2>&1 || true
else
    echo "App not found at $E2E_APP"
fi

echo -e "\n[3. Code Signing: Tako.app (Default Bundle: com.tako-core.terminal)]"
STD_APP="target/macapp/Tako.app"
if [ -d "$STD_APP" ]; then
    codesign -dvvv "$STD_APP" 2>&1
    echo "Entitlements:"
    codesign -d --entitlements - "$STD_APP" 2>&1 || true
else
    echo "App not found at $STD_APP"
fi

echo -e "\n[4. Code Signing: TakoUITests-Runner.app]"
RUNNER_APP="/Users/alex09x/Library/Developer/Xcode/DerivedData/TakoUITests-bzbaotmnrtkwhjdseafbsjothsms/Build/Products/Debug/TakoUITests-Runner.app"
if [ -d "$RUNNER_APP" ]; then
    codesign -dvvv "$RUNNER_APP" 2>&1
    echo "Entitlements:"
    codesign -d --entitlements - "$RUNNER_APP" 2>&1 || true
else
    echo "App not found at $RUNNER_APP"
fi

echo -e "\n[5. Code Signing: Host Test Tooling]"
echo "Swift binary: $(which swift)"
codesign -dvvv "$(which swift)" 2>&1 || true
echo "Xcode testmanagerd binary:"
codesign -dvvv /usr/libexec/testmanagerd 2>&1 || true

echo -e "\n================================================================================"
echo "CODESIGN PROBE COMPLETE"
echo "================================================================================"
