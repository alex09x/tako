import Foundation

/// Where the app points a user who asks it about itself.
///
/// Help, the About window, the commit rows and the release notes all link
/// somewhere; every such destination is gathered here instead of being
/// scattered through the UI layer, so none of them can point at another
/// project's pages.
///
/// Every link hangs off `homeURL`, the project's repository; a nil home
/// would hide them all (callers degrade to plain text or no button), never
/// leave them dead.
enum Brand {
    /// The name a user sees. Menu titles and window titles live in the nibs,
    /// which cannot read this, so renaming means editing both.
    static let name = "Tako"

    /// The project's public home -- a GitHub repository URL when there is
    /// one. The link helpers below all hang off it.
    static let homeURL: URL? = URL(string: "https://github.com/alex09x/tako")

    /// Documentation. The home page until there is somewhere better.
    static var docsURL: URL? { homeURL }

    /// Notes for a released version, or nil when there is no home to host
    /// them or the version is not a release (a commit-hash build has no
    /// notes to link to).
    ///
    /// The three link builders below take `home` explicitly so that a test
    /// can pin one down and check the URL it produces; leaving it out uses
    /// the real home, which is what every caller in the app does.
    static func releaseNotesURL(version: String, home: URL? = homeURL) -> URL? {
        home?.appendingPathComponent("releases/tag/v\(version)")
    }

    /// The page describing a single commit of this app.
    static func commitURL(_ hash: String, home: URL? = homeURL) -> URL? {
        home?.appendingPathComponent("commit/\(hash)")
    }

    /// The diff between the running build and one being offered.
    static func compareURL(from: String, to: String, home: URL? = homeURL) -> URL? {
        home?.appendingPathComponent("compare/\(from)...\(to)")
    }
}
