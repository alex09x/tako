import Foundation
import Testing
@testable import Tako

/// Where the app's own links go. The home pointed at the frozen repository
/// the project moved out of, whose commits and tags are not this app's.
struct BrandTests {
    private let home = URL(string: "https://example.test/project")!

    @Test func theHomeIsThisProjectsRepository() {
        #expect(Brand.homeURL?.absoluteString == "https://github.com/alex09x/tako")
        #expect(Brand.docsURL == Brand.homeURL)
        #expect(Brand.name == "Tako")
    }

    @Test func releaseCommitAndCompareLinksHangOffTheHome() {
        #expect(Brand.releaseNotesURL(version: "1.2.3", home: home)?.absoluteString
                == "https://example.test/project/releases/tag/v1.2.3")
        #expect(Brand.commitURL("abc1234", home: home)?.absoluteString
                == "https://example.test/project/commit/abc1234")
        #expect(Brand.compareURL(from: "abc", to: "def", home: home)?.absoluteString
                == "https://example.test/project/compare/abc...def")
    }

    @Test func withoutAHomeThereAreNoLinks() {
        #expect(Brand.releaseNotesURL(version: "1.2.3", home: nil) == nil)
        #expect(Brand.commitURL("abc1234", home: nil) == nil)
        #expect(Brand.compareURL(from: "abc", to: "def", home: nil) == nil)
    }

    @Test func theDefaultsUseTheRealHome() {
        #expect(Brand.releaseNotesURL(version: "0.1.0")?.absoluteString
                == "https://github.com/alex09x/tako/releases/tag/v0.1.0")
        #expect(Brand.commitURL("abc1234")?.absoluteString
                == "https://github.com/alex09x/tako/commit/abc1234")
        #expect(Brand.compareURL(from: "a", to: "b")?.absoluteString
                == "https://github.com/alex09x/tako/compare/a...b")
    }
}
