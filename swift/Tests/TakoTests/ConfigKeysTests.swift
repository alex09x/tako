import Testing
@testable import Tako
import SwiftUI
import AppKit

/// Config keys `Tako.Config` parses but a property used to ignore, wired up
/// to actually read them. See `Tako+Config.swift`.
@Suite
struct ConfigKeysTests {
    // MARK: - quick-terminal-position

    @Test func quickTerminalPositionDefaultsToTop() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalPosition == .top)
    }

    @Test(arguments: [
        ("top", QuickTerminalPosition.top),
        ("bottom", QuickTerminalPosition.bottom),
        ("left", QuickTerminalPosition.left),
        ("right", QuickTerminalPosition.right),
        ("center", QuickTerminalPosition.center),
    ])
    func quickTerminalPositionValues(raw: String, expected: QuickTerminalPosition) throws {
        let config = try TemporaryConfig("quick-terminal-position = \(raw)")
        #expect(config.quickTerminalPosition == expected)
    }

    @Test func quickTerminalPositionInvalidFallsBackToTop() throws {
        let config = try TemporaryConfig("quick-terminal-position = sideways")
        #expect(config.quickTerminalPosition == .top)
    }

    // MARK: - quick-terminal-screen

    @Test func quickTerminalScreenDefaultsToMain() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalScreen == .main)
    }

    @Test(arguments: [
        ("main", QuickTerminalScreen.main),
        ("mouse", QuickTerminalScreen.mouse),
        ("macos-menu-bar", QuickTerminalScreen.menuBar),
    ])
    func quickTerminalScreenValues(raw: String, expected: QuickTerminalScreen) throws {
        let config = try TemporaryConfig("quick-terminal-screen = \(raw)")
        #expect(config.quickTerminalScreen == expected)
    }

    @Test func quickTerminalScreenInvalidFallsBackToMain() throws {
        let config = try TemporaryConfig("quick-terminal-screen = elsewhere")
        #expect(config.quickTerminalScreen == .main)
    }

    // MARK: - quick-terminal-animation-duration

    @Test func quickTerminalAnimationDurationDefaultsToPointTwo() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalAnimationDuration == 0.2)
    }

    @Test func quickTerminalAnimationDurationSetToCustom() throws {
        let config = try TemporaryConfig("quick-terminal-animation-duration = 0.5")
        #expect(config.quickTerminalAnimationDuration == 0.5)
    }

    @Test func quickTerminalAnimationDurationInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("quick-terminal-animation-duration = fast")
        #expect(config.quickTerminalAnimationDuration == 0.2)
    }

    // MARK: - quick-terminal-autohide

    @Test func quickTerminalAutoHideDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalAutoHide == true)
    }

    @Test func quickTerminalAutoHideSetToFalse() throws {
        let config = try TemporaryConfig("quick-terminal-autohide = false")
        #expect(config.quickTerminalAutoHide == false)
    }

    @Test func quickTerminalAutoHideInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("quick-terminal-autohide = maybe")
        #expect(config.quickTerminalAutoHide == true)
    }

    // MARK: - quick-terminal-space-behavior

    @Test func quickTerminalSpaceBehaviorDefaultsToMove() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalSpaceBehavior == .move)
    }

    @Test(arguments: [
        ("move", QuickTerminalSpaceBehavior.move),
        ("remain", QuickTerminalSpaceBehavior.remain),
    ])
    func quickTerminalSpaceBehaviorValues(raw: String, expected: QuickTerminalSpaceBehavior) throws {
        let config = try TemporaryConfig("quick-terminal-space-behavior = \(raw)")
        #expect(config.quickTerminalSpaceBehavior == expected)
    }

    @Test func quickTerminalSpaceBehaviorInvalidFallsBackToMove() throws {
        let config = try TemporaryConfig("quick-terminal-space-behavior = teleport")
        #expect(config.quickTerminalSpaceBehavior == .move)
    }

    // MARK: - unfocused-split-opacity

    @Test func unfocusedSplitOpacityDefaultsToFifteenPercentDimming() throws {
        let config = try TemporaryConfig("")
        #expect(config.unfocusedSplitOpacity == 0.15)
    }

    @Test func unfocusedSplitOpacitySetToCustom() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = 0.5")
        #expect(config.unfocusedSplitOpacity == 0.5)
    }

    @Test func unfocusedSplitOpacityClampsBelowFloor() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = 0")
        #expect(config.unfocusedSplitOpacity == 0.85)
    }

    @Test func unfocusedSplitOpacityClampsAboveCeiling() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = 2")
        #expect(config.unfocusedSplitOpacity == 0)
    }

    @Test func unfocusedSplitOpacityInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = translucent")
        #expect(config.unfocusedSplitOpacity == 0.15)
    }

    // MARK: - unfocused-split-fill

    @Test func unfocusedSplitFillDefaultsToWhite() throws {
        let config = try TemporaryConfig("")
        #expect(config.unfocusedSplitFill == .white)
    }

    @Test func unfocusedSplitFillSetToColor() throws {
        let config = try TemporaryConfig("unfocused-split-fill = #ff0000")
        let expected = try #require(TerminalTheme.parseColor("#ff0000"))
        #expect(config.unfocusedSplitFill == Color(NSColor(cgColor: expected) ?? .windowBackgroundColor))
        #expect(config.unfocusedSplitFill != .white)
    }

    @Test func unfocusedSplitFillInvalidFallsBackToWhite() throws {
        let config = try TemporaryConfig("unfocused-split-fill = not-a-color")
        #expect(config.unfocusedSplitFill == .white)
    }

    // MARK: - window-new-tab-position

    @Test func windowNewTabPositionDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowNewTabPosition == "")
    }

    @Test func windowNewTabPositionSetToEnd() throws {
        let config = try TemporaryConfig("window-new-tab-position = end")
        #expect(config.windowNewTabPosition == "end")
    }

    @Test func windowNewTabPositionSetToCurrent() throws {
        let config = try TemporaryConfig("window-new-tab-position = current")
        #expect(config.windowNewTabPosition == "current")
    }

    @Test func windowNewTabPositionInvalidFallsBackToEmpty() throws {
        let config = try TemporaryConfig("window-new-tab-position = elsewhere")
        #expect(config.windowNewTabPosition == "")
    }

    // MARK: - macos-titlebar-proxy-icon

    @Test func macosTitlebarProxyIconDefaultsToVisible() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosTitlebarProxyIcon == .visible)
    }

    @Test(arguments: [
        ("visible", Tako.MacOSTitlebarProxyIcon.visible),
        ("hidden", Tako.MacOSTitlebarProxyIcon.hidden),
    ])
    func macosTitlebarProxyIconValues(raw: String, expected: Tako.MacOSTitlebarProxyIcon) throws {
        let config = try TemporaryConfig("macos-titlebar-proxy-icon = \(raw)")
        #expect(config.macosTitlebarProxyIcon == expected)
    }

    @Test func macosTitlebarProxyIconInvalidFallsBackToVisible() throws {
        let config = try TemporaryConfig("macos-titlebar-proxy-icon = translucent")
        #expect(config.macosTitlebarProxyIcon == .visible)
    }

    // MARK: - macos-auto-secure-input

    @Test func autoSecureInputDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.autoSecureInput == true)
    }

    @Test func autoSecureInputSetToFalse() throws {
        let config = try TemporaryConfig("macos-auto-secure-input = false")
        #expect(config.autoSecureInput == false)
    }

    @Test func autoSecureInputInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("macos-auto-secure-input = nope")
        #expect(config.autoSecureInput == true)
    }

    // MARK: - macos-secure-input-indication

    @Test func secureInputIndicationDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.secureInputIndication == true)
    }

    @Test func secureInputIndicationSetToFalse() throws {
        let config = try TemporaryConfig("macos-secure-input-indication = false")
        #expect(config.secureInputIndication == false)
    }

    @Test func secureInputIndicationInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("macos-secure-input-indication = nope")
        #expect(config.secureInputIndication == true)
    }

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
