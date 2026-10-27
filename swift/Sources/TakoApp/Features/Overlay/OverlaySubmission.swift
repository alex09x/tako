/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// What a form in an overlay sent back. The page runs no script: a plain
/// `<form action="tako-submit:">` (method GET, the default) submits by
/// navigating to `tako-submit:?name=value&...`, the overlay takes that
/// navigation instead of following it, and its fields come here. Checkboxes
/// and multiple selects send a name more than once; the submitting button's
/// own name and value come with the rest.
public struct OverlaySubmission: Equatable, Sendable {
    public static let scheme = "tako-submit"
    /// Bounds on what a page may send back.
    public static let maxBytes = 64 * 1024
    public static let maxFields = 256

    /// Field names in the order the form sent them, each once.
    public let names: [String]
    /// Every value sent under each name, in order.
    public let values: [String: [String]]

    public enum Failure: Error, Equatable {
        case notASubmission
        case tooLarge
    }

    public static func parse(_ url: URL) -> Result<OverlaySubmission, Failure> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.notASubmission) }
        if url.absoluteString.utf8.count > maxBytes { return .failure(.tooLarge) }
        // `tako-submit:?a=1` has no host, which URLComponents reads fine; a
        // form that sent nothing is an empty submission, not a refusal.
        // A form encodes a space as "+", which URLComponents leaves alone.
        func decode(_ s: String) -> String {
            s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        if items.count > maxFields { return .failure(.tooLarge) }
        var names: [String] = []
        var values: [String: [String]] = [:]
        for item in items {
            let name = decode(item.name)
            if values[name] == nil { names.append(name) }
            values[name, default: []].append(decode(item.value ?? ""))
        }
        return .success(OverlaySubmission(names: names, values: values))
    }

    /// Fields as JSON: a name sent once is a string, one sent more than once an array.
    var json: [String: JSON] {
        var out: [String: JSON] = [:]
        for name in names {
            let sent = values[name] ?? []
            out[name] = sent.count == 1 ? .string(sent[0]) : .array(sent.map { .string($0) })
        }
        return out
    }
}

/// How waiting on an overlay ended.
public enum OverlayOutcome: Equatable, Sendable {
    case submitted(OverlaySubmission)
    /// Closed, replaced by another overlay, or its pane went away.
    case closed
    /// A page sent more than the bridge takes.
    case refused(String)
}
