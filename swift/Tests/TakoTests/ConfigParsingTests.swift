import Foundation
import Testing
@testable import TakoKit

/// The configuration file parser.
///
/// Values are ordinarily written bare, and quoting is how you keep leading or
/// trailing spaces or write something that would otherwise read as empty.
/// Upstream's Zig parser accepts both and its own UI tests write
/// `title = "..."`, so a quoted value has to come back out without the
/// quotes -- keeping them puts them in the window title.
struct ConfigParsingTests {
    private func parse(_ text: String) -> TakoConfigStorage {
        let storage = TakoConfigStorage()
        parseTakoConfigText(text, into: storage)
        return storage
    }

    // MARK: - Quoting

    @Test func aQuotedValueLosesItsQuotes() {
        #expect(parse(#"title = "My Terminal""#).values["title"] == "My Terminal")
        #expect(parse("title = 'My Terminal'").values["title"] == "My Terminal")
    }

    @Test func aBareValueIsUnchanged() {
        #expect(parse("title = My Terminal").values["title"] == "My Terminal")
        #expect(parse("font-size = 13").values["font-size"] == "13")
    }

    @Test func quotingPreservesSurroundingSpace() {
        #expect(parse(#"title = "  padded  ""#).values["title"] == "  padded  ")
    }

    @Test func anUnmatchedOrInteriorQuoteSurvives() {
        // A lone quote is a character in the value, not a delimiter.
        #expect(parse(#"title = it"s"#).values["title"] == #"it"s"#)
        #expect(parse(#"title = "unbalanced"#).values["title"] == #""unbalanced"#)
        #expect(parse("title = it's").values["title"] == "it's")
        // Mismatched pair: not a pair at all.
        #expect(parse("title = \"mixed'").values["title"] == "\"mixed'")
    }

    @Test func anEmptyPairOfQuotesIsAnEmptyValue() {
        #expect(parse(#"title = """#).values["title"] == "")
    }

    @Test func onlyOneLayerOfQuotesIsRemoved() {
        #expect(parse(#"title = ""nested"""#).values["title"] == #""nested""#)
    }

    // MARK: - Lines

    @Test func commentsAndBlankLinesAreIgnored() {
        let storage = parse("""
        # a comment
        title = Kept

        """)
        #expect(storage.values["title"] == "Kept")
        #expect(storage.values.count == 1)
    }

    @Test func spaceAroundTheSeparatorIsOptional() {
        #expect(parse("title=Tight").values["title"] == "Tight")
        #expect(parse("   title   =   Loose   ").values["title"] == "Loose")
    }

    @Test func aValueMayContainTheSeparator() {
        // Only the first `=` splits the line.
        #expect(parse("title = a=b").values["title"] == "a=b")
    }

    @Test func anUnknownKeyIsReportedRatherThanStored() {
        let storage = parse("not-a-real-setting = 1")
        #expect(storage.values.isEmpty)
        #expect(storage.errors.count == 1)
    }

    @Test func keybindsAreCollectedSeparatelyAndKeepTheirText() {
        let storage = parse("keybind = cmd+t=new_tab")
        #expect(storage.keybindLines == ["cmd+t=new_tab"])
        #expect(storage.values.isEmpty)
        #expect(storage.errors.isEmpty)
    }
}
