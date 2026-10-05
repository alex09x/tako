/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation
import Security

/// A server-side capability authorization grant issued to a client (Track G1).
struct ControlGrant: Sendable, Codable, Equatable {
    let id: UUID
    let token: String
    let client: String
    let scopes: Set<ControlScope>
    let createdAt: Date
    let description: String?

    init(
        id: UUID = UUID(),
        token: String = ControlGrantStore.generateToken(),
        client: String,
        scopes: Set<ControlScope>,
        createdAt: Date = Date(),
        description: String? = nil
    ) {
        self.id = id
        self.token = token
        self.client = client
        self.scopes = scopes
        self.createdAt = createdAt
        self.description = description
    }
}

/// Server-side registry of authorization grants and tokens for control socket clients (Track G1).
///
/// Grants are never self-asserted by socket callers: every client presenting a token
/// is bounded strictly by the server-side grant. Unauthenticated callers or invalid
/// tokens fail closed for all scoped commands.
final class ControlGrantStore: @unchecked Sendable {
    static let shared = ControlGrantStore()

    private let lock = NSLock()
    private var grants: [String: ControlGrant] = [:]
    let primaryToken: String

    init() {
        let token = Self.generateToken()
        self.primaryToken = token
        let primaryGrant = ControlGrant(
            token: token,
            client: "local",
            scopes: Set(ControlScope.allCases),
            description: "Primary local user session grant"
        )
        self.grants[token] = primaryGrant
    }

    /// Generates a cryptographically secure 64-character random hex token.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Looks up a grant by its secret token.
    func grant(for token: String) -> ControlGrant? {
        lock.withLock { grants[token] }
    }

    /// Issues and registers a new capability grant for a client.
    @discardableResult
    func issueGrant(client: String, scopes: Set<ControlScope>, description: String? = nil) -> ControlGrant {
        let grant = ControlGrant(client: client, scopes: scopes, description: description)
        lock.withLock {
            grants[grant.token] = grant
        }
        return grant
    }

    /// Revokes an existing grant. The primary grant cannot be revoked.
    @discardableResult
    func revokeGrant(token: String) -> Bool {
        lock.withLock {
            if token == primaryToken {
                return false
            }
            return grants.removeValue(forKey: token) != nil
        }
    }

    /// Lists all registered grants.
    func listGrants() -> [ControlGrant] {
        lock.withLock {
            Array(grants.values).sorted(by: { $0.createdAt < $1.createdAt })
        }
    }


    /// Resets the grant store to initial state for testing.
    func resetForTesting() {
        lock.withLock {
            grants.removeAll()
            let primaryGrant = ControlGrant(
                token: primaryToken,
                client: "local",
                scopes: Set(ControlScope.allCases),
                description: "Primary local user session grant"
            )
            grants[primaryToken] = primaryGrant
        }
    }
}
