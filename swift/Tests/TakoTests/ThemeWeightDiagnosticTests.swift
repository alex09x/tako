/*
 * tako — Theme typography is accepted by main configuration diagnostics
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
@testable import Tako
@testable import TakoKit

@MainActor @Suite(.serialized) struct ThemeWeightDiagnosticTests {
    @Test func allVisualKeysAreRecognizedInTheMainConfiguration() {
        let keys = ThemePresetConfig.controlKeys.filter { !$0.hasPrefix("palette:") }
        #expect(Set(keys).subtracting(knownTakoConfigKeys).isEmpty)
    }

    @Test func fourGlobalWeightSettingsDoNotProduceConfigurationErrors() {
        let storage = TakoConfigStorage()
        let keys = ["font-weight", "font-weight-bold", "font-weight-italic", "font-weight-bold-italic"]
        parseTakoConfigText(keys.map { "\($0) = 550" }.joined(separator: "\n"), into: storage)
        #expect(storage.errors.isEmpty)
        for key in keys { #expect(storage.values[key] == "550") }
        parseTakoConfigText("definitely-not-a-setting = 1", into: storage)
        #expect(storage.errors == ["unknown configuration key: definitely-not-a-setting"])
    }
}
