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

extension ControlCommands {
    /// `takoctl config`: the user's config file, setting by setting.
    static func configCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        if let surface = try? target(request, all) {
            recordActivity(for: request, on: surface.id, action: "config \(request.args["action"]?.string ?? "list")")
        }
        return try ControlConfig(file: .shared).run(request.args)
    }
}
