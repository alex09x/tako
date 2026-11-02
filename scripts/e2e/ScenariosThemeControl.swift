/*
 * tako — Complete CLI theme configuration against a real isolated app
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

func runThemeControlScenario(_ d: Driver) throws {
    d.quit()
    try d.launch(config: "remote-control = on\nauto-update = off\nwindow-save-state = never\nsession-persistence = false\nconfirm-close-surface = never\ncommand = /bin/sh\nshell-integration = none\ncursor-style-blink = false\n")
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    func q(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func response(_ arguments: String, refused: Bool = false) throws -> [String: Any] {
        let output = try d.exec("\(ctl) theme \(arguments) --json" + (refused ? " || true" : ""))
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              json["ok"] as? Bool == !refused else { throw Failure("unexpected theme response: \(output)") }
        return refused ? (json["error"] as? [String: Any] ?? [:]) : (json["result"] as? [String: Any] ?? [:])
    }
    func panes() throws -> [[String: Any]] {
        let raw = try d.exec("\(ctl) tree --json")
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        let result = json["result"] as? [String: Any] ?? json
        return (result["windows"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .flatMap { $0["panes"] as? [[String: Any]] ?? [] }
    }
    guard let first = try panes().first, let id = first["id"] as? String, let process = first["pid"] as? Int else { throw Failure("missing test session") }
    let list = try response("list")["themes"] as? [[String: Any]] ?? []
    let keys = try response("keys")["keys"] as? [String] ?? []
    let fonts = try response("fonts")["fonts"] as? [String] ?? []
    guard list.contains(where: { $0["name"] as? String == "TakoCore" }),
          keys.contains("palette:255"), keys.contains("font-family-bold-italic"), !keys.contains("command"), fonts.contains("Monaco") else {
        throw Failure("theme discovery is incomplete")
    }
    let source = "font-family = Monaco\nfont-size = 17\nbackground = #123456\nforeground = #c0ffee\npalette = 1=#ff1122\ntab-status-color-working = #1122ff\n"
    let imported = d.work.appendingPathComponent("theme-import")
    try source.write(to: imported, atomically: true, encoding: .utf8)
    _ = try response("create 'CLI Theme' --file \(q(imported.path))")
    _ = try response("set 'CLI Theme' font-size=19 'palette:255=#abcdef' font-feature=+liga font-feature=-dlig")
    let configured = try response("show 'CLI Theme'")["config"] as? String ?? ""
    guard configured.contains("font-size = 19"), configured.contains("255=#abcdef"),
          configured.contains("font-feature = +liga"), configured.contains("font-feature = -dlig") else { throw Failure("CLI batch configuration did not persist") }
    _ = try response("apply 'CLI Theme' --global")
    func backgroundMatches(_ expected: [Int]) -> Bool {
        let path = d.path("cli-theme.png")
        guard (try? d.exec("\(ctl) screenshot --target \(id) --out \(q(path))")) != nil,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let bitmap = NSBitmapImageRep(data: data),
              bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3 else { return false }
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&pixel, atX: bitmap.pixelsWide - 8, y: bitmap.pixelsHigh - 8)
        let channel = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        return zip(Array(pixel[channel..<(channel + 3)]), expected).allSatisfy { abs($0 - $1) <= 2 }
    }
    guard d.wait(for: { backgroundMatches([18, 52, 86]) }, timeout: 10) else { throw Failure("CLI global theme did not reach renderer pixels") }
    _ = try response("apply 'CLI Theme' --session \(id)")
    _ = try response("reset --global")
    _ = try d.exec("\(ctl) split right --target \(id)")
    guard let other = try panes().compactMap({ $0["id"] as? String }).first(where: { $0 != id }) else { throw Failure("no second test pane") }
    _ = try d.exec("\(ctl) workspace create 'CLI Workspace'")
    _ = try response("apply 'Tako Ocean' --workspace 'CLI Workspace'")
    _ = try d.exec("\(ctl) workspace assign --workspace 'CLI Workspace' --target \(other)")
    _ = try d.exec("\(ctl) workspace switch 'CLI Workspace'")
    let own = try response("current --target \(id)")
    let inherited = try response("current --target \(other)")
    guard own["theme"] as? String == "CLI Theme", (own["effective_config"] as? String)?.contains("font-size = 19") == true,
          inherited["theme"] is NSNull, (inherited["effective_config"] as? String)?.contains("font-size = 13") == true else {
        throw Failure("CLI assignment scopes were not isolated")
    }
    guard d.wait(for: {
        ((try? response("current --target \(id)")["rendered_config"] as? String) ?? "").contains("font-size = 19")
    }, timeout: 10) else { throw Failure("CLI font did not reach the live surface") }
    // The second pane still inherits Ocean from the workspace. Moving its
    // whole tab through the CLI must retain it alongside the first pane's
    // independent explicit preset.
    _ = try d.exec("\(ctl) workspace assign --workspace Default --target \(other)")
    _ = try d.exec("\(ctl) workspace switch Default")
    guard try response("current --target \(other)")["theme"] as? String == "Tako Ocean",
          try response("current --target \(id)")["theme"] as? String == "CLI Theme" else {
        throw Failure("CLI workspace move lost inherited or explicit session appearance")
    }
    _ = try d.exec("\(ctl) workspace assign --workspace 'CLI Workspace' --target \(other)")
    _ = try d.exec("\(ctl) workspace switch 'CLI Workspace'")
    _ = try response("reset --target \(other)")
    _ = try response("apply 'CLI Theme' --workspace 'CLI Workspace'")
    _ = try response("apply 'CLI Theme' --global")
    _ = try response("rename 'CLI Theme' 'Renamed CLI'")
    for scope in ["--global", "--workspace 'CLI Workspace'", "--target \(id)"] {
        guard try response("current \(scope)")["theme"] as? String == "Renamed CLI" else { throw Failure("rename left an old scope reference") }
    }
    let busy = try response("delete 'Renamed CLI'", refused: true)
    guard busy["code"] as? String == "busy" else { throw Failure("assigned theme deletion was not protected") }
    _ = try response("set 'Renamed CLI' 'command=/bin/false'", refused: true)
    _ = try response("set TakoCore font-size=19", refused: true)
    let preserved = try response("show 'Renamed CLI'")["config"] as? String ?? ""
    guard preserved == configured else { throw Failure("a refused theme mutation changed the preset") }
    // The real stdin path is exercised with a bounded pipe and imported text.
    let pipe = try d.exec("printf '%s' \(q(source)) | \(ctl) theme create Piped --stdin --json")
    guard let piped = try JSONSerialization.jsonObject(with: Data(pipe.utf8)) as? [String: Any], piped["ok"] as? Bool == true else { throw Failure("stdin import did not create a theme") }
    _ = try response("unset 'Renamed CLI' palette:255 font-feature")
    let unset = try response("show 'Renamed CLI'")["config"] as? String ?? ""
    guard !unset.contains("font-feature ="), !unset.contains("255=#abcdef") else { throw Failure("CLI unset left repeated or extended entries behind") }
    _ = try response("reset --target \(id)")
    _ = try response("reset --workspace 'CLI Workspace'")
    _ = try response("reset --global")
    let removed = try response("delete 'Renamed CLI'")
    guard let recovery = removed["recovery_path"] as? String, FileManager.default.fileExists(atPath: recovery) else { throw Failure("theme removal had no recovery copy") }
    _ = try response("create Recovered --file \(q(recovery))")
    let after = try panes().first { $0["id"] as? String == id }
    guard after?["pid"] as? Int == process, kill(Int32(process), 0) == 0 else { throw Failure("theme CLI replaced the session/process") }
}
