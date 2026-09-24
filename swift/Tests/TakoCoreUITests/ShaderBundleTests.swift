import XCTest
@testable import TakoCoreUI

#if canImport(AppKit)
private typealias TerminalHostView = TakoTerminalNSView
#else
private typealias TerminalHostView = TakoTerminalView
#endif

/// Where the views look for their Metal shaders.
final class ShaderBundleTests: XCTestCase {
    /// Under `swift test` the main bundle is the XCTest runner, which carries
    /// no packaged TakoCoreUI resource bundle, so the resolver must fall back
    /// to the bundle holding TakoCoreUI's own code rather than return the
    /// runner's.
    func testWithoutAPackagedBundleItFallsBackToTheCodeBundle() {
        let packaged = Bundle.main.bundleURL.appendingPathComponent("TakoCoreUI_TakoCoreUI.bundle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: packaged.path))

        let resolved = ShaderBundle.resources
        XCTAssertEqual(resolved.bundleURL, Bundle(for: TerminalHostView.self).bundleURL)
        #if os(macOS)
        // The iOS surface tests link TakoCoreUI into the runner itself, so
        // there the code bundle is the main bundle.
        XCTAssertNotEqual(resolved.bundleURL, Bundle.main.bundleURL)
        #endif
    }
}
