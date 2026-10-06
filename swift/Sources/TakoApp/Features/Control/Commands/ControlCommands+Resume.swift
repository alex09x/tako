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
import AppKit

extension ControlCommands {
    /// `takoctl resume`: resume agent sessions across relaunches and process boundaries (C6).
    static func handleResume(_ request: ControlRequest, all: [Pane]) throws -> ControlResponse {
        let surface = try target(request, all)
        let action: String = try {
            if let a = request.args["action"] {
                if case .string(let s) = a { return s }
                throw ControlError(.invalid, "\"action\" must be a string")
            }
            return "show"
        }()

        let isSecure = SecureInput.shared.isSecure(for: surface) || surface.isSecureInput

        switch action {
        case "set":
            guard !isSecure else {
                ResumeSessionStore.shared.clear(for: surface.id)
                throw ControlError(.disabled, "secure-input panes cannot record resume state")
            }
            let argv: [String] = try {
                guard let argVal = request.args["argv"] else {
                    throw ControlError(.invalid, "missing \"argv\" argument for resume set")
                }
                if case .array(let arr) = argVal {
                    return try arr.map {
                        if case .string(let s) = $0 { return s }
                        throw ControlError(.invalid, "argv elements must be strings")
                    }
                }
                throw ControlError(.invalid, "\"argv\" must be an array of strings")
            }()
            guard !argv.isEmpty else {
                throw ControlError(.invalid, "argv cannot be empty")
            }
            let cwd: String = {
                if let c = request.args["cwd"], case .string(let s) = c, !s.isEmpty { return s }
                return surface.pwd ?? ""
            }()
            var env: [String: String] = [:]
            if let e = request.args["env"], case .object(let dict) = e {
                for (k, v) in dict {
                    if case .string(let s) = v { env[k] = s }
                }
            }
            let record = ResumeSessionRecord(argv: argv, cwd: cwd, env: env, recordedAt: Date(), isImported: false)
            ResumeSessionStore.shared.set(record: record, for: surface.id, isSecure: isSecure)
            let isApproved = ResumeTrustStore.shared.isApproved(argv: record.argv, cwd: cwd)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "argv": .array(argv.map(JSON.string)),
                "cwd": .string(cwd),
                "approved": .bool(isApproved),
            ])

        case "show":
            if isSecure {
                ResumeSessionStore.shared.clear(for: surface.id)
                return .ok([
                    "id": .string(surface.id.uuidString.lowercased()),
                    "has_resume": .bool(false),
                ])
            }
            guard let record = ResumeSessionStore.shared.record(for: surface.id) else {
                return .ok([
                    "id": .string(surface.id.uuidString.lowercased()),
                    "has_resume": .bool(false),
                ])
            }
            let isApproved = ResumeTrustStore.shared.isApproved(argv: record.argv, cwd: record.cwd)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "has_resume": .bool(true),
                "argv": .array(record.argv.map(JSON.string)),
                "cwd": .string(record.cwd),
                "is_imported": .bool(record.isImported),
                "approved": .bool(isApproved),
                "recorded_at": .string(ISO8601DateFormatter().string(from: record.recordedAt)),
            ]
            var envJson: [String: JSON] = [:]
            for (k, v) in record.env {
                envJson[k] = .string(v)
            }
            dict["env"] = .object(envJson)
            return .ok(dict)

        case "clear":
            ResumeSessionStore.shared.clear(for: surface.id)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "cleared": .bool(true),
            ])

        case "run":
            guard !isSecure else {
                throw ControlError(.disabled, "secure-input panes cannot run resume state")
            }
            guard let record = ResumeSessionStore.shared.record(for: surface.id) else {
                throw ControlError(.notFound, "no resume session recorded for this pane")
            }
            surface.dismissResumeBanner()
            surface.executeResume(record: record)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "executed": .bool(true),
                "argv": .array(record.argv.map(JSON.string)),
            ])

        case "approve":
            let cwd: String = {
                if let c = request.args["cwd"], case .string(let s) = c, !s.isEmpty { return s }
                if let record = ResumeSessionStore.shared.record(for: surface.id), !record.cwd.isEmpty {
                    return record.cwd
                }
                return surface.pwd ?? ""
            }()
            let prefix: String = try {
                if let p = request.args["prefix"], case .string(let s) = p, !s.isEmpty {
                    return s
                }
                if let record = ResumeSessionStore.shared.record(for: surface.id), !record.argv.isEmpty {
                    return record.argv.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
                }
                throw ControlError(.invalid, "missing prefix to approve and no recorded session found")
            }()
            ResumeTrustStore.shared.approve(prefix: prefix, cwd: cwd)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "approved": .bool(true),
                "prefix": .string(prefix),
                "cwd": .string(cwd),
            ])

        default:
            throw ControlError(.invalid, "unknown resume action \"\(action)\" (expected set, show, clear, run, approve)")
        }
    }
}
