import Testing
import SwiftUI
@testable import Tako

@MainActor
struct ErrorViewCoverageTests {
    @Test func bodyBuildsWithoutCrashing() {
        let view = ErrorView()
        // Force SwiftUI to build the view's body so every line in it runs.
        _ = view.body
    }

    @Test func previewsBuildsWithoutCrashing() {
        _ = ErrorView_Previews.previews
    }
}
