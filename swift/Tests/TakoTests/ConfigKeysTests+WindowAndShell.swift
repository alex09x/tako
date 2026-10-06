/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
@testable import Tako
import SwiftUI
import AppKit

extension ConfigKeysTests {
    // MARK: - macos-hidden

    @Test func macosHiddenDefaultsToNever() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosHidden == .never)
    }

    @Test(arguments: [
        ("never", Tako.Config.MacHidden.never),
        ("always", Tako.Config.MacHidden.always),
    ])
    func macosHiddenValues(raw: String, expected: Tako.Config.MacHidden) throws {
        let config = try TemporaryConfig("macos-hidden = \(raw)")
        #expect(config.macosHidden == expected)
    }

    @Test func macosHiddenInvalidFallsBackToNever() throws {
        let config = try TemporaryConfig("macos-hidden = sometimes")
        #expect(config.macosHidden == .never)
    }

    // MARK: - macos-option-as-alt

    @Test func macosOptionAsAltDefaultsToOff() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosOptionAsAlt == .off)
    }

    @Test(arguments: [
        ("false", OptionAsAlt.off),
        ("true", OptionAsAlt.on),
        ("left", OptionAsAlt.left),
        ("right", OptionAsAlt.right),
    ])
    func macosOptionAsAltValues(raw: String, expected: OptionAsAlt) throws {
        let config = try TemporaryConfig("macos-option-as-alt = \(raw)")
        #expect(config.macosOptionAsAlt == expected)
    }

    @Test func macosOptionAsAltInvalidFallsBackToOff() throws {
        let config = try TemporaryConfig("macos-option-as-alt = sideways")
        #expect(config.macosOptionAsAlt == .off)
    }

    // MARK: - window-width / window-height

    @Test func windowSizeInCellsDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowSizeInCells == nil)
    }

    @Test func windowSizeInCellsNeedsBothKeys() throws {
        #expect(try TemporaryConfig("window-width = 120").windowSizeInCells == nil)
        #expect(try TemporaryConfig("window-height = 40").windowSizeInCells == nil)
    }

    @Test func windowSizeInCellsSetToCustom() throws {
        let config = try TemporaryConfig("window-width = 120\nwindow-height = 40")
        let grid = try #require(config.windowSizeInCells)
        #expect(grid.columns == 120)
        #expect(grid.rows == 40)
    }

    @Test func windowSizeInCellsClampsToUpstreamsMinimum() throws {
        let config = try TemporaryConfig("window-width = 2\nwindow-height = 1")
        let grid = try #require(config.windowSizeInCells)
        #expect(grid.columns == 10)
        #expect(grid.rows == 4)
    }

    // MARK: - working-directory

    @Test func workingDirectorySetToCustomPath() throws {
        let config = try TemporaryConfig("working-directory = /tmp")
        #expect(config.workingDirectory == .path("/tmp"))
    }

    @Test func workingDirectorySetToHome() throws {
        let config = try TemporaryConfig("working-directory = home")
        #expect(config.workingDirectory == .home)
    }

    @Test func workingDirectorySetToInherit() throws {
        let config = try TemporaryConfig("working-directory = inherit")
        #expect(config.workingDirectory == .inherit)
    }

    @Test func workingDirectoryUnsetDefaultsFromWhetherLaunchedFromAShell() throws {
        let config = try TemporaryConfig("")
        let expected: Tako.Config.WorkingDirectory =
            ProcessInfo.processInfo.environment["TERM"] != nil ? .inherit : .home
        #expect(config.workingDirectory == expected)
    }

    // MARK: - window-inherit-working-directory

    @Test func windowInheritWorkingDirectoryDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowInheritWorkingDirectory == true)
    }

    @Test func windowInheritWorkingDirectorySetToFalse() throws {
        let config = try TemporaryConfig("window-inherit-working-directory = false")
        #expect(config.windowInheritWorkingDirectory == false)
    }

    @Test func windowInheritWorkingDirectoryInvalidFallsBackToTrue() throws {
        let config = try TemporaryConfig("window-inherit-working-directory = maybe")
        #expect(config.windowInheritWorkingDirectory == true)
    }

    // MARK: - window-inherit-font-size

    @Test func windowInheritFontSizeDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowInheritFontSize == true)
    }

    @Test func windowInheritFontSizeSetToFalse() throws {
        let config = try TemporaryConfig("window-inherit-font-size = false")
        #expect(config.windowInheritFontSize == false)
    }

    @Test func windowInheritFontSizeInvalidFallsBackToTrue() throws {
        let config = try TemporaryConfig("window-inherit-font-size = maybe")
        #expect(config.windowInheritFontSize == true)
    }

    // MARK: - shell-integration

    @Test func shellIntegrationDefaultsToDetect() throws {
        let config = try TemporaryConfig("")
        #expect(config.shellIntegration == .detect)
    }

    @Test(arguments: [
        ("none", Tako.Config.ShellIntegration.none),
        ("detect", .detect),
        ("bash", .bash),
        ("elvish", .elvish),
        ("fish", .fish),
        ("zsh", .zsh),
    ])
    func shellIntegrationValues(raw: String, expected: Tako.Config.ShellIntegration) throws {
        let config = try TemporaryConfig("shell-integration = \(raw)")
        #expect(config.shellIntegration == expected)
    }

    @Test func shellIntegrationInvalidFallsBackToDetect() throws {
        let config = try TemporaryConfig("shell-integration = tcsh")
        #expect(config.shellIntegration == .detect)
    }

    // MARK: - shell-integration-features

    @Test func shellIntegrationFeaturesDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.shellIntegrationFeatures == nil)
    }

    @Test func shellIntegrationFeaturesSetToCustom() throws {
        let config = try TemporaryConfig("shell-integration-features = cursor,no-sudo")
        #expect(config.shellIntegrationFeatures == "cursor,no-sudo")
    }

    // MARK: - macos-icon-ghost-color / macos-icon-screen-color

    @Test func macosIconGhostColorDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosIconGhostColor == nil)
    }

    @Test func macosIconGhostColorParsesUpstreamsSyntax() throws {
        let config = try TemporaryConfig("macos-icon-ghost-color = #ff0000")
        let color = try #require(config.macosIconGhostColor)
        let expected = try #require(TerminalTheme.parseColor("#ff0000").flatMap { NSColor(cgColor: $0) })
        #expect(Color(color) == Color(expected))
    }

    @Test func macosIconGhostColorInvalidFallsBackToNil() throws {
        let config = try TemporaryConfig("macos-icon-ghost-color = notacolor")
        #expect(config.macosIconGhostColor == nil)
    }

    @Test func macosIconScreenColorDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosIconScreenColor == nil)
    }

    @Test func macosIconScreenColorParsesACommaListAsAGradient() throws {
        let config = try TemporaryConfig("macos-icon-screen-color = #ff0000,#0000ff")
        let colors = try #require(config.macosIconScreenColor)
        #expect(colors.count == 2)
        let red = try #require(TerminalTheme.parseColor("#ff0000").flatMap { NSColor(cgColor: $0) })
        let blue = try #require(TerminalTheme.parseColor("#0000ff").flatMap { NSColor(cgColor: $0) })
        #expect(Color(colors[0]) == Color(red))
        #expect(Color(colors[1]) == Color(blue))
    }

    @Test func macosIconScreenColorInvalidFallsBackToNil() throws {
        let config = try TemporaryConfig("macos-icon-screen-color = notacolor")
        #expect(config.macosIconScreenColor == nil)
    }
}

}
