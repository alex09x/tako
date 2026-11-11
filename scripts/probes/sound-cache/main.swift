/*
 * tako — Probe: can a Developer-ID-signed process place a system sound in its app group?
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// Built with swift/Sources/TakoApp/Features/Notifications/ActivitySoundCache.swift, the code the app runs.
//   probe place <group> <Sound>    -> JSON: signature, container, placement, re-read bytes
//   probe remove <group> <Sound>   -> removes only Library/Sounds/tako-<Sound>.aiff
// No notification request, no authorization request, no UI.
import Foundation

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

let args = CommandLine.arguments
guard args.count == 4, ["place", "remove"].contains(args[1]) else {
    FileHandle.standardError.write(Data("usage: probe place|remove <group> <Sound>\n".utf8)); exit(64)
}
let (mode, group, name) = (args[1], args[2], args[3])
let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
var out: [String: Any] = [
    "bundle": Bundle.main.bundleIdentifier ?? "none",
    "team": ActivitySoundCache.ownTeam() ?? "none",
    "groups": ActivitySoundCache.ownGroups(),
    "container": container?.path ?? "none",
]

if mode == "remove" {
    guard let container else { out["removed"] = false; emit(out); exit(1) }
    let file = container.appendingPathComponent("Library/Sounds/\(ActivitySoundCache.filePrefix)\(name).aiff")
    let existed = FileManager.default.fileExists(atPath: file.path)
    if existed { try? FileManager.default.removeItem(at: file) }
    out["removed"] = existed && !FileManager.default.fileExists(atPath: file.path)
    out["file"] = file.path
    emit(out); exit(0)
}

let sounds = container?.appendingPathComponent("Library/Sounds")
out["soundsFolderExistedBefore"] = sounds.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
switch ActivitySoundCache.place(name, known: [name], group: group) {
case .success(let placed):
    let source = try Data(contentsOf: ActivitySoundCache.systemSounds.appendingPathComponent("\(name).aiff"))
    let copy = try Data(contentsOf: placed.url)
    out["placed"] = placed.fileName
    out["file"] = placed.url.path
    out["sha256"] = placed.sha256
    out["bytes"] = copy.count
    out["matchesSystemSound"] = copy == source && ActivitySoundCache.sha256(copy) == placed.sha256
    emit(out); exit(copy == source ? 0 : 2)
case .failure(let why):
    out["failure"] = "\(why)"
    emit(out); exit(3)
}
