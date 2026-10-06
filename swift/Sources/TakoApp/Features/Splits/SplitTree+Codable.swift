/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

// MARK: SplitTree Codable

private enum CodingKeys: String, CodingKey {
    case version
    case root
    case zoomed

    static let currentVersion: Int = 1
}

extension SplitTree: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Check version
        let version = try container.decode(Int.self, forKey: .version)
        guard version == CodingKeys.currentVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported SplitTree version: \(version)"
                )
            )
        }

        // Decode root
        self.root = try container.decodeIfPresent(Node.self, forKey: .root)

        // Zoomed is encoded as its path. Get the path and then find it.
        if let zoomedPath = try container.decodeIfPresent(Path.self, forKey: .zoomed),
           let root = self.root {
            self.zoomed = root.node(at: zoomedPath)
        } else {
            self.zoomed = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode version
        try container.encode(CodingKeys.currentVersion, forKey: .version)

        // Encode root
        try container.encodeIfPresent(root, forKey: .root)

        // Zoomed is encoded as its path since its a reference type. This lets us
        // map it on decode back to the correct node in root.
        if let zoomed, let path = root?.path(to: zoomed) {
            try container.encode(path, forKey: .zoomed)
        }
    }
}

