import Testing
import Foundation
@testable import Tako

// `Tako.SurfaceConfiguration`'s AppleScript record conversion: what a script
// gets back from `new surface configuration` and what values it can feed in.

@Suite
struct ScriptSurfaceConfigurationCoverageTests {
    @Test func aNilRecordProducesAnUntouchedDefaultConfiguration() throws {
        let config = try Tako.SurfaceConfiguration(scriptRecord: nil)
        #expect(config.fontSize == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.command == nil)
        #expect(config.initialInput == nil)
        #expect(config.waitAfterCommand == false)
        #expect(config.environmentVariables.isEmpty)
    }

    @Test func aNonDictionaryRecordIsRejected() {
        // A non-string key (`NSCopying`-conformant, unlike a bare `NSObject`,
        // so the dictionary itself can be built at all) trips the
        // `as? [String: Any]` cast that guards the whole initializer.
        let record = NSDictionary(dictionary: [NSNumber(value: 1): "value"])
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func fontSizeMustBeANumber() {
        let record: NSDictionary = ["fontSize": "not a number"]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func fontSizeMustBeFinite() {
        let record: NSDictionary = ["fontSize": Double.infinity]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func fontSizeMustNotBeNegative() {
        let record: NSDictionary = ["fontSize": -1]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func fontSizeOfZeroIsSilentlyIgnored() throws {
        // Not an error -- `if value > 0` just declines to set it, leaving
        // the default `nil` in place.
        let record: NSDictionary = ["fontSize": 0]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.fontSize == nil)
    }

    @Test func aPositiveFontSizeIsApplied() throws {
        let record: NSDictionary = ["fontSize": 18.5]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.fontSize == Float32(18.5))
    }

    @Test func workingDirectoryMustBeText() {
        let record: NSDictionary = ["workingDirectory": 42]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func anEmptyWorkingDirectoryIsIgnored() throws {
        let record: NSDictionary = ["workingDirectory": ""]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.workingDirectory == nil)
    }

    @Test func aNonEmptyWorkingDirectoryIsApplied() throws {
        let record: NSDictionary = ["workingDirectory": "/tmp"]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.workingDirectory == "/tmp")
    }

    @Test func commandMustBeText() {
        let record: NSDictionary = ["command": 42]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func anEmptyCommandIsIgnored() throws {
        let record: NSDictionary = ["command": ""]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.command == nil)
    }

    @Test func aNonEmptyCommandIsApplied() throws {
        let record: NSDictionary = ["command": "top"]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.command == "top")
    }

    @Test func initialInputMustBeText() {
        let record: NSDictionary = ["initialInput": 42]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func anEmptyInitialInputIsIgnored() throws {
        let record: NSDictionary = ["initialInput": ""]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.initialInput == nil)
    }

    @Test func aNonEmptyInitialInputIsApplied() throws {
        let record: NSDictionary = ["initialInput": "echo hi"]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.initialInput == "echo hi")
    }

    @Test func waitAfterCommandAcceptsARealBool() throws {
        let record: NSDictionary = ["waitAfterCommand": true]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.waitAfterCommand == true)
    }

    @Test func waitAfterCommandAcceptsANumericBoolean() throws {
        let record: NSDictionary = ["waitAfterCommand": NSNumber(value: 1)]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.waitAfterCommand == true)
    }

    @Test func waitAfterCommandRejectsOtherTypes() {
        let record: NSDictionary = ["waitAfterCommand": "yes"]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func environmentVariablesParseKeyValueAssignments() throws {
        let record: NSDictionary = ["environmentVariables": ["FOO=bar", "BAZ=1=2"]]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.environmentVariables["FOO"] == "bar")
        #expect(config.environmentVariables["BAZ"] == "1=2")
    }

    @Test func anEmptyEnvironmentVariablesListIsIgnored() throws {
        let record: NSDictionary = ["environmentVariables": [String]()]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        #expect(config.environmentVariables.isEmpty)
    }

    @Test func environmentVariablesWithoutAnEqualsSignAreRejected() {
        let record: NSDictionary = ["environmentVariables": ["NOVALUE"]]
        #expect(throws: RecordParseError.self) {
            _ = try Tako.SurfaceConfiguration(scriptRecord: record)
        }
    }

    @Test func dictionaryRepresentationOfADefaultConfigurationUsesPlaceholderValues() {
        let config = Tako.SurfaceConfiguration()
        let dict = config.dictionaryRepresentation

        #expect(dict["fontSize"] as? Int == 0)
        #expect(dict["workingDirectory"] as? String == "")
        #expect(dict["command"] as? String == "")
        #expect(dict["initialInput"] as? String == "")
        #expect(dict["waitAfterCommand"] as? Bool == false)
        #expect(dict["environmentVariables"] as? [String] == [])
    }

    @Test func dictionaryRepresentationRoundTripsEverySetField() throws {
        let record: NSDictionary = [
            "fontSize": 16,
            "workingDirectory": "/tmp",
            "command": "top",
            "initialInput": "echo hi",
            "waitAfterCommand": true,
            "environmentVariables": ["FOO=bar"],
        ]
        let config = try Tako.SurfaceConfiguration(scriptRecord: record)
        let dict = config.dictionaryRepresentation

        #expect(dict["fontSize"] as? Double == 16)
        #expect(dict["workingDirectory"] as? String == "/tmp")
        #expect(dict["command"] as? String == "top")
        #expect(dict["initialInput"] as? String == "echo hi")
        #expect(dict["waitAfterCommand"] as? Bool == true)
        #expect(dict["environmentVariables"] as? [String] == ["FOO=bar"])
    }
}

@Suite
struct RecordParseErrorCoverageTests {
    @Test func invalidTypeDescribesTheExpectedShape() {
        let error = RecordParseError.invalidType(parameter: "font size", expected: "a number")
        #expect(error.errorDescription == "font size must be a number.")
    }

    @Test func invalidValueDescribesTheProblem() {
        let error = RecordParseError.invalidValue(parameter: "font size", message: "must be a positive number")
        #expect(error.errorDescription == "font size must be a positive number.")
    }
}

@Suite
struct ModsAppleScriptCoverageTests {
    @Test func parsesEachRecognizedModifierName() throws {
        #expect(try #require(Tako.Input.Mods(scriptModifiers: "shift")) == .shift)
        #expect(try #require(Tako.Input.Mods(scriptModifiers: "control")) == .ctrl)
        #expect(try #require(Tako.Input.Mods(scriptModifiers: "option")) == .alt)
        #expect(try #require(Tako.Input.Mods(scriptModifiers: "command")) == .super)
    }

    @Test func combinesMultipleModifiersSeparatedByCommas() throws {
        let mods = try #require(Tako.Input.Mods(scriptModifiers: "shift,command"))
        #expect(mods.contains(.shift))
        #expect(mods.contains(.super))
        #expect(!mods.contains(.ctrl))
    }

    @Test func trimsWhitespaceAndIgnoresCase() throws {
        let mods = try #require(Tako.Input.Mods(scriptModifiers: " Shift , CONTROL "))
        #expect(mods.contains(.shift))
        #expect(mods.contains(.ctrl))
    }

    @Test func anEmptyStringProducesNoModifiers() throws {
        let mods = try #require(Tako.Input.Mods(scriptModifiers: ""))
        #expect(mods.isEmpty)
    }

    @Test func anUnrecognizedModifierNameFailsTheWholeParse() {
        #expect(Tako.Input.Mods(scriptModifiers: "shift,nonsense") == nil)
    }
}
