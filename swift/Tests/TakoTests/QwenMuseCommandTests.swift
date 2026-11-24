/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
@testable import Tako

struct QwenMuseCommandTests {
    private let bundled = "/opt/tools/qwen-code/node/bin/node /opt/tools/qwen-code/lib/cli-entry.js"

    @Test func interactiveAgentsKeepCanonicalProgramNames() {
        for (line, name) in [
            ("qwen", "qwen"), ("qwen --resume session", "qwen"),
            ("qwen -i 'interactive question'", "qwen"), ("qwen attach --session session", "qwen"),
            (bundled, "qwen"), ("env X=1 " + bundled + " --resume", "qwen"),
            ("muse", "muse"), ("muse resume --last", "muse"), ("muse 'initial prompt'", "muse"),
            ("/opt/bin/muse-bin-1.4.14-R7309.1", "muse"),
            ("command /opt/bin/muse-bin-1.4.14-R7309.1 resume --last", "muse"),
        ] {
            #expect(Tako.CommandKind.classify(line) == .quiet, "\(line)")
            #expect(Tako.CommandKind.describe(line).program == name, "\(line)")
        }
    }

    @Test func headlessAndUtilityCallsRemainJobs() {
        for line in ["qwen -p question", "qwen --prompt=question", "qwen 'one-shot question'",
                     bundled + " --prompt question", "qwen hooks", "qwen mcp list", "qwen --version",
                     "muse exec question", "muse plugins list", "muse skills list", "muse schema --help",
                     "muse config status", "muse --version"] {
            #expect(Tako.CommandKind.classify(line) == .batch, "\(line)")
        }
    }

    @Test func unrelatedNodeScriptsAndLookalikesAreNotAgents() {
        for (line, name) in [
            ("node /opt/tools/qwen-code/lib/cli-entry.js", "node"),
            ("/opt/tools/qwen-code/node/bin/node /other/qwen-code/lib/cli-entry.js", "node"),
            ("/opt/tools/qwen-code/node/bin/node build.js", "node"),
            ("node build.js qwen muse", "node"),
            ("muse-helper", "muse-helper"),
            ("muse-bin-1.4.14-R7309.1.bak", "muse-bin-1.4.14-R7309.1.bak"),
            ("muse-bin-1.4-R7309.1", "muse-bin-1.4-R7309.1"),
        ] {
            #expect(Tako.CommandKind.describe(line).program == name)
            #expect(Tako.CommandKind.classify(line) == .batch)
        }
        #expect(Tako.CommandKind.classify("node") == .quiet)
    }

    @Test func existingRawOverridesAndCanonicalOverridesBothApply() {
        #expect(Tako.CommandKind.classify(bundled, busy: ["node"]) == .batch)
        #expect(Tako.CommandKind.classify(bundled, quiet: ["qwen"], busy: ["node"]) == .batch)
        #expect(Tako.CommandKind.classify(bundled + " -p question", quiet: ["node"]) == .quiet)
        #expect(Tako.CommandKind.classify(bundled, busy: ["qwen"]) == .batch)
        #expect(Tako.CommandKind.classify("muse-bin-1.4.14-R7309.1", busy: ["muse"]) == .batch)
        #expect(Tako.CommandKind.classify("muse-bin-1.4.14-R7309.1 exec q", quiet: ["muse-bin-1.4.14-R7309.1"]) == .quiet)
    }
}
