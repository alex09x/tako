/*
 * tako — Every visual CLI key and numeric font weights in a real app
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

func runThemeTypographyScenario(_ d: Driver) throws {
    d.quit()
    try d.launch(config: "remote-control = on\nwindow-save-state = never\nsession-persistence = false\nconfirm-close-surface = never\ncommand = /bin/sh\nshell-integration = none\ncursor-style-blink = false\n")
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    let configFile = d.work.appendingPathComponent("config")
    func q(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func response(_ arguments: String, refused: Bool = false) throws -> [String: Any] {
        let output = try d.exec("\(ctl) theme \(arguments) --json" + (refused ? " || true" : ""))
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              json["ok"] as? Bool == !refused else { throw Failure("unexpected typography response: \(output)") }
        return (json[refused ? "error" : "result"] as? [String: Any]) ?? [:]
    }
    func treePane() throws -> [String: Any] {
        let raw = try d.exec("\(ctl) tree --json")
        let tree = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        let result = tree["result"] as? [String: Any] ?? tree
        return (result["windows"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .flatMap { $0["panes"] as? [[String: Any]] ?? [] }.first ?? [:]
    }
    let original = try treePane()
    guard let id = original["id"] as? String, let process = original["pid"] as? Int else { throw Failure("missing isolated pane") }
    let configBefore = try String(contentsOf: configFile, encoding: .utf8)
    let inventory = try response("fonts")
    guard let variable = (inventory["font_details"] as? [[String: Any]])?.first(where: { $0["family"] as? String == "Fira Code" }),
          variable["variable_weight"] as? Bool == true,
          (variable["minimum_weight"] as? Double ?? 999) <= 550,
          (variable["maximum_weight"] as? Double ?? 0) >= 600 else { throw Failure("bundled variable font missing from CLI discovery") }
    let templates = try response("list")["themes"] as? [[String: Any]] ?? []
    let names = templates.filter { $0["is_user"] as? Bool == false }.compactMap { $0["name"] as? String }
    guard names.count >= 5 else { throw Failure("missing built-in templates") }
    var created: [String] = []
    for (index, source) in names.enumerated() {
        let name = "CLI " + source
        let weight = 400 + index * 50
        _ = try response("create \(q(name)) --from \(q(source))")
        _ = try response("set \(q(name)) 'font-family=Fira Code' font-size=24 font-weight=\(weight) font-weight-bold=700 font-weight-italic=450 font-weight-bold-italic=650 cursor-style-blink=false")
        _ = try response("apply \(q(name)) --session \(id)")
        let current = try response("current --session \(id)")["rendered_config"] as? String ?? ""
        guard current.contains("font-weight = \(weight)"), current.contains("font-weight-bold-italic = 650"),
              current.contains("font-family = Fira Code"), try treePane()["pid"] as? Int == process else {
            throw Failure("created preset did not reach existing live pane: \(source)")
        }
        created.append(name)
    }
    let active = created.last!
    _ = try response("set \(q(active)) 'background=#101010' 'foreground=#ffffff' font-weight=400")
    func raster(_ label: String) throws -> Data {
        let path = d.path("weight-\(label).png")
        _ = try d.exec("\(ctl) screenshot --target \(id) --out \(q(path))")
        guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { throw Failure("no font raster") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: data, count: image.width * image.height * 4)
    }
    let weight400 = try raster("400")
    guard try raster("400-control") == weight400 else { throw Failure("font witness is not stable before weight change") }
    _ = try response("set \(q(active)) font-weight=550")
    let weight550 = try raster("550")
    _ = try response("set \(q(active)) font-weight=600")
    let weight600 = try raster("600")
    guard weight400 != weight550, weight550 != weight600 else { throw Failure("numeric CLI weights changed config but not rendered glyphs") }
    let before = try response("show \(q(active))")["config"] as? String
    _ = try response("set \(q(active)) font-size=32 font-weight=950", refused: true)
    guard try response("show \(q(active))")["config"] as? String == before else { throw Failure("invalid weight partially changed a theme") }

    let samples = themeVisualCliSamples(shader: d.path("unused.glsl"))
    let keys = try response("keys")["keys"] as? [String] ?? []
    guard Set(keys) == Set(samples.keys) else { throw Failure("a discoverable visual key lacks a real CLI fixture") }
    _ = try response("create 'Every Visual Parameter' --from TakoCore")
    let assignments = keys.map { q($0 + "=" + samples[$0]!) }.joined(separator: " ")
    _ = try response("set 'Every Visual Parameter' \(assignments)")
    let all = try response("show 'Every Visual Parameter'")["config"] as? String ?? ""
    guard all.contains("255=#123456"), all.contains("font-weight = 550"), all.contains("font-weight-bold-italic = 550"),
          all.contains("adjust-cell-height = 1") else { throw Failure("full CLI visual configuration was not persisted") }
    _ = try response("copy \(q(active)) Copied")
    _ = try response("rename Copied Renamed")
    _ = try response("unset Renamed font-weight font-weight-bold-italic")
    let reset = try response("show Renamed")["config"] as? String ?? ""
    guard !reset.contains("font-weight ="), !reset.contains("font-weight-bold-italic =") else { throw Failure("weight unset failed") }
    _ = try response("delete Renamed")
    _ = try response("reset --session \(id)")
    for name in created + ["Every Visual Parameter"] { _ = try response("delete \(q(name))") }
    guard try String(contentsOf: configFile, encoding: .utf8) == configBefore,
          try treePane()["id"] as? String == id, try treePane()["pid"] as? Int == process else { throw Failure("CLI typography recreated the session or changed global config") }
}

private func themeVisualCliSamples(shader: String) -> [String: String] {
    var values: [String: String] = [
        "font-size": "18", "font-synthetic-style": "true", "font-feature": "+liga",
        "cursor-opacity": "0.8", "background-opacity": "0.9", "cursor-thickness": "2",
        "background-blur": "3", "background-blur-radius": "3", "cell-width": "11", "cell_width": "11",
        "cell-height": "24", "cell_height": "24", "window-padding-x": "8,12", "window-padding-y": "6,10",
        "window-padding-balance": "true", "selection-invert-fg-bg": "false", "cursor-style-blink": "false",
        "window-padding-color": "background", "window-colorspace": "srgb", "cursor-style": "bar",
        "custom-shader": shader, "custom-shader-animation": "false", "palette": "17=#123456"
    ]
    for key in ["background", "foreground", "cursor-color", "selection-background", "selection-foreground",
                "tab-status-color-working", "tab-status-color-waiting", "tab-status-color-done", "tab-status-color-error", "tab-status-color-idle"] { values[key] = "#123456" }
    for key in ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"] { values[key] = "Menlo" }
    for key in ["font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic"] { values[key] = "Regular" }
    for key in ["font-weight", "font-weight-bold", "font-weight-italic", "font-weight-bold-italic"] { values[key] = "550" }
    for key in ["adjust-cell-width", "adjust-cell-height", "adjust-font-baseline", "adjust-underline-position", "adjust-underline-thickness"] { values[key] = "1" }
    for index in 0...255 { values["palette:\(index)"] = "#123456" }
    return values
}
