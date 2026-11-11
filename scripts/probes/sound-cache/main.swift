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
    "mode": mode, "group": group, "name": name,
    "bundle": Bundle.main.bundleIdentifier ?? "none",
    "team": ActivitySoundCache.ownTeam() ?? "none",
    "groups": ActivitySoundCache.ownGroups(),
    "container": container?.path ?? "none",
]

if mode == "remove" {
    // Only the file this probe places: its own group, a plain sound name, a plain file whose
    // bytes are the installed system sound. Anything else is left alone and reported as a failure.
    func refuse(_ why: String) -> Never { out["removed"] = false; out["refused"] = why; emit(out); exit(4) }
    guard ActivitySoundCache.ownGroups().contains(group) else { refuse("group not in this probe's entitlement") }
    guard name.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil else { refuse("not a sound name") }
    guard let container else { refuse("no container") }
    let file = container.appendingPathComponent("Library/Sounds/\(ActivitySoundCache.filePrefix)\(name).aiff")
    out["file"] = file.path
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
          attrs[.type] as? FileAttributeType == .typeRegular else { refuse("no plain placed file") }
    guard let placed = try? Data(contentsOf: file),
          let system = try? Data(contentsOf: ActivitySoundCache.systemSounds.appendingPathComponent("\(name).aiff")),
          placed == system else { refuse("file is not the placed system sound") }
    out["sha256"] = ActivitySoundCache.sha256(placed)
    do { try FileManager.default.removeItem(at: file) } catch { refuse("remove failed") }
    out["removed"] = !FileManager.default.fileExists(atPath: file.path)
    emit(out); exit(out["removed"] as? Bool == true ? 0 : 5)
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
