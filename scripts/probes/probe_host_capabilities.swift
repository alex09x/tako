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
import CoreGraphics
import ScreenCaptureKit
import ApplicationServices
import AppKit

let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let timestamp = isoFormatter.string(from: Date())

print("================================================================================")
print("TAKO HOST CAPABILITY & PERMISSION PROBE REPORT")
print("Timestamp: \(timestamp)")
print("================================================================================")

// -----------------------------------------------------------------------------
// 1. Process & Execution Identity
// -----------------------------------------------------------------------------
print("\n[1. Process & Execution Identity]")
let pid = ProcessInfo.processInfo.processIdentifier
let execPath = CommandLine.arguments[0]
let bundleId = Bundle.main.bundleIdentifier ?? "<unbundled-command-line-tool>"
print("PID: \(pid)")
print("Executable Path: \(execPath)")
print("Arguments: \(CommandLine.arguments)")
print("Bundle Identifier: \(bundleId)")
print("User: \(NSUserName()) (UID: \(getuid()), EUID: \(geteuid()), GID: \(getgid()))")
print("Process Name: \(ProcessInfo.processInfo.processName)")
print("macOS OS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")

if let sshClient = ProcessInfo.processInfo.environment["SSH_CLIENT"] {
    print("SSH Client: \(sshClient)")
}
if let sshConn = ProcessInfo.processInfo.environment["SSH_CONNECTION"] {
    print("SSH Connection: \(sshConn)")
}

// -----------------------------------------------------------------------------
// 2. Console Session & Display State
// -----------------------------------------------------------------------------
print("\n[2. Console Session & Display State]")
if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] {
    print("CGSessionCopyCurrentDictionary():")
    for key in sessionDict.keys.sorted() {
        print("  \(key): \(sessionDict[key] ?? "")")
    }
} else {
    print("CGSessionCopyCurrentDictionary(): <nil> (no active WindowServer session)")
}

var maxDisplays: UInt32 = 16
var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
var displayCount: UInt32 = 0
let dispErr = CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
print("Active Display Count: \(displayCount) (CGGetActiveDisplayList err: \(dispErr.rawValue))")
let mainDisplay = CGMainDisplayID()
print("Main Display ID: \(mainDisplay)")
let mainBounds = CGDisplayBounds(mainDisplay)
print("Main Display Bounds: \(mainBounds)")
print("Main Display Is Asleep: \(CGDisplayIsAsleep(mainDisplay))")
print("Main Display Is Online: \(CGDisplayIsOnline(mainDisplay))")
print("Main Display Is Active: \(CGDisplayIsActive(mainDisplay))")

// -----------------------------------------------------------------------------
// 3. Screen Recording Permissions & ScreenCaptureKit
// -----------------------------------------------------------------------------
print("\n[3. Screen Recording Permissions & ScreenCaptureKit]")
let cgPreflight = CGPreflightScreenCaptureAccess()
print("CGPreflightScreenCaptureAccess(): \(cgPreflight)")

let sckSem = DispatchSemaphore(value: 0)
if #available(macOS 12.3, *) {
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
        if let error = error as NSError? {
            print("SCShareableContent Result: FAILED")
            print("  Domain: \(error.domain)")
            print("  Code: \(error.code)")
            print("  Localized Description: \"\(error.localizedDescription)\"")
            if let reason = error.localizedFailureReason {
                print("  Failure Reason: \"\(reason)\"")
            }
            print("  UserInfo: \(error.userInfo)")
        } else if let content = content {
            print("SCShareableContent Result: SUCCESS")
            print("  Displays: \(content.displays.count)")
            print("  Windows: \(content.windows.count)")
            print("  Applications: \(content.applications.count)")
        } else {
            print("SCShareableContent Result: Unknown (nil content and nil error)")
        }
        sckSem.signal()
    }
} else {
    print("ScreenCaptureKit unavailable on this macOS version")
    sckSem.signal()
}
if sckSem.wait(timeout: .now() + 5.0) == .timedOut {
    print("SCShareableContent TIMED OUT after 5s")
}

// -----------------------------------------------------------------------------
// 4. Accessibility Trust & System UI Process Inspection
// -----------------------------------------------------------------------------
print("\n[4. Accessibility Trust & Target Process Inspection]")
let axTrusted = AXIsProcessTrusted()
print("AXIsProcessTrusted(): \(axTrusted)")

// Helper to query AXUIElement
func inspectAXApp(pid: pid_t, label: String) {
    print("Inspecting \(label) (PID: \(pid)):")
    let appElement = AXUIElementCreateApplication(pid)
    
    var roleVal: AnyObject?
    let roleErr = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &roleVal)
    print("  AXRole query err: \(roleErr.rawValue) (AXError.success=\(AXError.success.rawValue))")
    if roleErr == .success, let roleStr = roleVal as? String {
        print("  AXRole: \(roleStr)")
    }
    
    var windowsVal: AnyObject?
    let winErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal)
    print("  AXWindows query err: \(winErr.rawValue)")
    if winErr == .success, let windows = windowsVal as? [AXUIElement] {
        print("  AXWindows count: \(windows.count)")
        for (i, win) in windows.prefix(5).enumerated() {
            var titleVal: AnyObject?
            _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal)
            var subroleVal: AnyObject?
            _ = AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleVal)
            print("    Window [\(i)]: Title=\"\(titleVal as? String ?? "")\", Subrole=\"\(subroleVal as? String ?? "")\"")
        }
    }
}

// Find PIDs for notificationcenterui and usernoted
let ws = NSWorkspace.shared
let ncApps = ws.runningApplications.filter { $0.bundleIdentifier == "com.apple.notificationcenterui" }
if let ncApp = ncApps.first {
    inspectAXApp(pid: ncApp.processIdentifier, label: "com.apple.notificationcenterui")
} else {
    // Fallback: search via pgrep
    let pipe = Pipe()
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "notificationcenterui"]
    pgrep.standardOutput = pipe
    try? pgrep.run()
    pgrep.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let outStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let parsedPid = pid_t(outStr) {
        inspectAXApp(pid: parsedPid, label: "com.apple.notificationcenterui (via pgrep)")
    } else {
        print("com.apple.notificationcenterui not found in running applications")
    }
}

let unPipe = Pipe()
let unPgrep = Process()
unPgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
unPgrep.arguments = ["-x", "usernoted"]
unPgrep.standardOutput = unPipe
try? unPgrep.run()
unPgrep.waitUntilExit()
let unData = unPipe.fileHandleForReading.readDataToEndOfFile()
if let unStr = String(data: unData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
   let unPid = pid_t(unStr) {
    inspectAXApp(pid: unPid, label: "usernoted (PID \(unPid))")
} else {
    print("usernoted not found via pgrep")
}

print("\n================================================================================")
print("PROBE COMPLETE")
print("================================================================================")
