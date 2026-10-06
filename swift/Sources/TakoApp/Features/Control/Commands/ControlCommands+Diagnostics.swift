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
    static func diagnoseCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let includeTerminal = request.args["include_terminal"]?.bool == true
        let includeBenchmark = request.args["benchmark"]?.bool == true

        let report = DiagnosticsExporter.collectReport(
            allPanes: all,
            includeTerminal: includeTerminal,
            includeBenchmark: includeBenchmark
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let jsonVal = try? JSON(any: jsonObject),
              case .object(let dict) = jsonVal else {
            throw ControlError(.internalError, "Failed to encode diagnostics payload")
        }

        return dict
    }
}
