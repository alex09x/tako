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
import Testing
@testable import Tako

@Suite
struct SessionProtocolTests {
    private func helper(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tako-proto-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url
    }

    @Test func conditionalKillAndAttachOnlyArgumentsPinGeneration() {
        #expect(
            RuntimeCommand.killIfGenerationArguments(name: "abc", generation: "gen1")
                == ["kill", "--if-label", "tako-gen=gen1", "abc"]
        )
        #expect(
            RuntimeCommand.attachOnlyIfGenerationArguments(name: "abc", generation: "gen1")
                == ["attach", "--attach-only", "--if-label", "tako-gen=gen1", "abc"]
        )
        #expect(
            RuntimeCommand.attachOnlyIfGenerationArguments(name: "abc", generation: "gen1", attempt: "att1")
                == ["attach", "--attach-only", "--if-label", "tako-gen=gen1", "--labels", "tako-attempt=att1", "abc"]
        )
        #expect(
            RuntimeCommand.createOnlyWithGenerationArguments(
                name: "abc",
                generation: "gen1",
                attempt: "att1",
                command: ["/bin/sh"]
            ) == ["attach", "--create-only", "--labels", "tako-gen=gen1 tako-attempt=att1", "abc", "/bin/sh"]
        )
    }

    @Test func killIfGenerationFailsClosedOnEmptyIdentityOrRefusedHelper() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tako-kill-marker-\(UUID().uuidString)")
        let script = try helper("""
        printf '%s\\n' "$*" > "\(marker.path)"
        if [ "$1" = "kill" ] && [ "$2" = "--if-label" ] && [ "$3" = "tako-gen=gen1" ] && [ "$4" = "abc" ]; then
            printf 'killed session abc\\n'
            exit 0
        fi
        exit 1
        """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: marker)
        }

        // Empty name or generation never invokes the helper.
        #expect(RuntimeCommand.killIfGeneration(script, name: "", generation: "gen1", environment: [:]) == .refused(status: -1))
        #expect(RuntimeCommand.killIfGeneration(script, name: "abc", generation: "", environment: [:]) == .refused(status: -1))
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // Mismatched generation is refused.
        #expect(RuntimeCommand.killIfGeneration(script, name: "abc", generation: "gen2", environment: [:]) == .refused(status: 1))

        // Exact matching generation succeeds.
        #expect(RuntimeCommand.killIfGeneration(script, name: "abc", generation: "gen1", environment: [:]) == .killed)
    }

}
