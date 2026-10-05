import Foundation
import Testing
@testable import Tako

/// What `takoctl last` and `wait` report about a pane's commands: what the
/// shell marked (OSC 133), as JSON.
@MainActor
struct ControlCommandTests {
    private func run(_ core: TakoCore, _ line: String, _ output: String, exit code: Int32) {
        core.feed(bytes: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}\(line)\r\n\u{1b}]133;C\u{07}\(output)\u{1b}]133;D;\(code)\u{07}".utf8))
    }

    @Test func theLastCommandIsReportedWithItsStatusDirectoryAndOutput() {
        let core = TakoCore(cols: 60, rows: 12)
        core.feed(bytes: Data("\u{1b}]7;file://host/tmp/work\u{07}".utf8))
        run(core, "echo one", "one\r\n", exit: 0)
        run(core, "make", "compiling\r\nerror: nope\r\n", exit: 2)
        let result = ControlCommand.describe(core.lastCommand(maxLines: 50, maxBytes: 10_000))
        guard case .object(let command)? = result["command"] else { Issue.record("no command"); return }
        #expect(command["input"] == .string("make"))
        #expect(command["cwd"] == .string("/tmp/work"))
        #expect(command["exitCode"] == .number(2))
        #expect(command["finished"] == .bool(true))
        #expect(result["output"] == .string("compiling\nerror: nope"))
        // A ref to wait on exactly this command.
        guard case .string(let ref)? = command["ref"] else { Issue.record("no ref"); return }
        let parts = ref.split(separator: "@").compactMap { UInt64($0) }
        #expect(parts.count == 2)
        let same = core.commandOutput(id: parts[0], epoch: parts[1], maxLines: 10, maxBytes: 1000)
        #expect(same?.command.input == "make")
        // Another generation's id names nothing.
        #expect(core.commandOutput(id: parts[0], epoch: parts[1] + 1, maxLines: 10, maxBytes: 1000) == nil)
    }

    @Test func numbersOutOfRangeAreRefusedBeforeAnythingRuns() {
        #expect(throws: ControlError.self) { try ControlCommand.lines(["lines": .number(1e300)]) }
        #expect(throws: ControlError.self) { try ControlCommand.timeout(["timeout": .number(1e300)]) }
        #expect(throws: ControlError.self) { try ControlCommand.timeout(["timeout": .number(-1)]) }
        #expect(throws: ControlError.self) { try ControlCommand.ref(["command": .string("x@1")]) }
        #expect((try? ControlCommand.timeout(["timeout": .number(30)])) == 30)
    }

    @Test func withoutMarksThereIsNoCommand() {
        let core = TakoCore(cols: 40, rows: 6)
        core.feed(bytes: Data("plain\r\n".utf8))
        #expect(ControlCommand.describe(core.lastCommand(maxLines: 10, maxBytes: 1000))["command"] == .null)
    }

    @Test func aReportedDirectoryBecomesAPath() {
        #expect(ControlCommand.path(fromReported: "file://host/Users/a%20b") == "/Users/a b")
        #expect(ControlCommand.path(fromReported: "/already/a/path") == "/already/a/path")
    }

    @Test func aFindLimitOutsideItsRangeIsRefused() {
        for bad: JSON in [.number(1.8446744073709552e19), .number(0), .number(1.5), .number(-3), .string("9")] {
            #expect(throws: ControlError.self) { try ControlCommands.findLimit(["limit": bad]) }
        }
        #expect((try? ControlCommands.findLimit([:])) == 50)
        #expect((try? ControlCommands.findLimit(["limit": .number(7)])) == 7)
    }

    @Test func aHistoryLimitOutsideItsRangeIsRefused() {
        for bad: JSON in [.number(1.8446744073709552e19), .number(-1), .number(-100), .number(1.5), .number(5001), .number(1e300), .string("20")] {
            #expect(throws: ControlError.self) { try ControlCommands.historyLimit(["limit": bad]) }
        }
        #expect((try? ControlCommands.historyLimit([:])) == 100)
        #expect((try? ControlCommands.historyLimit(["limit": .null])) == 100)
        #expect((try? ControlCommands.historyLimit(["limit": .number(0)])) == 0)
        #expect((try? ControlCommands.historyLimit(["limit": .number(50)])) == 50)
        #expect((try? ControlCommands.historyLimit(["limit": .number(5000)])) == 5000)
    }

    @Test func aReplyGoesOutOnceWhoeverIsFirst() {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let once = ControlCommands.OnceReply { _ in count.n += 1 }
        #expect(!once.done)
        once.answer(.failure(ControlError(.timeout, "deadline")))
        once.answer(.ok([:]))
        #expect(once.done)
        #expect(count.n == 1)

        // A cancel wins only before the action claims it...
        let cancelled = ControlCommands.OnceReply { _ in }
        #expect(cancelled.cancel(.failure(ControlError(.timeout, "gone"))))
        #expect(!cancelled.claim())
        // ...and after a claim, a cancel is refused and the action answers.
        let acting = ControlCommands.OnceReply { _ in count.n += 1 }
        #expect(acting.claim())
        #expect(!acting.cancel(.failure(ControlError(.timeout, "late"))))
        #expect(!acting.done)
        acting.answer(.ok([:]))
        #expect(acting.done)
        #expect(count.n == 2)
    }
}

