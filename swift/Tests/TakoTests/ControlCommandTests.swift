import Foundation
import Testing
@testable import Tako

/// What `takoctl last` and `wait` report about a pane's commands: what the
/// shell marked (OSC 133), as JSON.
struct ControlCommandTests {
    private func run(_ core: TakoCore, _ line: String, _ output: String, exit code: Int32) {
        core.feed(bytes: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}\(line)\r\n\u{1b}]133;C\u{07}\(output)\u{1b}]133;D;\(code)\u{07}".utf8))
    }

    @Test func theLastCommandIsReportedWithItsStatusDirectoryAndOutput() {
        let core = TakoCore(cols: 60, rows: 12)
        core.feed(bytes: Data("\u{1b}]7;file://host/tmp/work\u{07}".utf8))
        run(core, "echo one", "one\r\n", exit: 0)
        run(core, "make", "compiling\r\nerror: nope\r\n", exit: 2)
        let result = ControlCommand.describe(core, lines: 50)
        guard case .object(let command)? = result["command"] else { Issue.record("no command"); return }
        #expect(command["input"] == .string("make"))
        #expect(command["cwd"] == .string("/tmp/work"))
        #expect(command["exitCode"] == .number(2))
        #expect(command["finished"] == .bool(true))
        #expect(result["output"] == .string("compiling\nerror: nope"))
    }

    @Test func withoutMarksThereIsNoCommand() {
        let core = TakoCore(cols: 40, rows: 6)
        core.feed(bytes: Data("plain\r\n".utf8))
        #expect(ControlCommand.describe(core, lines: 10)["command"] == .null)
    }

    @Test func aReportedDirectoryBecomesAPath() {
        #expect(ControlCommand.path(fromReported: "file://host/Users/a%20b") == "/Users/a b")
        #expect(ControlCommand.path(fromReported: "/already/a/path") == "/already/a/path")
    }
}
