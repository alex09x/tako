import Foundation

/// Anchors `Bundle(for:)` on this file's own framework, when there is one.
private final class ShaderBundleAnchor {}

/// Where the shader resources live at runtime.
///
/// One resolver for both views. They had a copy each, the copies disagreed --
/// one asked for the package bundle and the other for the class bundle -- and
/// the disagreement was invisible until a consumer launched the AppKit one
/// from a command-line SwiftPM build and got no Metal at all.
///
/// Deliberately does not use SwiftPM's generated `Bundle.module`. That
/// accessor exists only in the target it is generated for, and this file is
/// also compiled into the ported macOS application target, which flattens the
/// package sources -- `SWIFT_PACKAGE` is defined there too, so guarding on it
/// compiles a reference to a member that does not exist. Naming the locations
/// outright works in every configuration and is what `.module` would have
/// looked for anyway.
enum ShaderBundle {
    private static let packagedName = "TakoCoreUI_TakoCoreUI.bundle"

    static var resources: Bundle {
        for url in candidateURLs {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle(for: ShaderBundleAnchor.self)
    }

    /// In the order a real integration needs them.
    ///
    /// 1. `Contents/Resources`, for a signed application. SwiftPM's generated
    ///    accessor points at `Bundle.main.bundleURL`, which for an app is the
    ///    `.app` root -- `codesign` refuses that as unsealed content, and
    ///    moving the bundle after signing invalidates the executable. A
    ///    distributable app therefore carries it under `Contents/Resources`.
    /// 2. Beside the executable, which is where a raw `swift build` or
    ///    `swift run` puts it.
    private static var candidateURLs: [URL] {
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent(packagedName))
        }
        urls.append(Bundle.main.bundleURL.appendingPathComponent(packagedName))
        return urls
    }
}
