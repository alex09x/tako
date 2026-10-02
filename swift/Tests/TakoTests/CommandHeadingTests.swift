import Foundation
import Testing
@testable import Tako

private let A = "\u{1b}]133;A\u{07}", B = "\u{1b}]133;B\u{07}", C = "\u{1b}]133;C\u{07}"

private func command(_ core: TakoCore, _ line: String, _ output: String, end: String) {
    core.feed(bytes: Data("\(A)$ \(B)\(line)\r\n\(C)\(output)\(end)".utf8))
}

@Suite
@MainActor
struct CommandHeadingTests {
    @Test func matchesCarryTheCommandThatPrintedThem() async throws {
        let core = TakoCore(cols: 60, rows: 12)
        core.feed(bytes: Data("\u{1b}]7;file://host/Users/me/src\u{07}".utf8))
        command(core, "make test", "error: one\r\n", end: "\u{1b}]133;D;2\u{07}")
        command(core, "make lint", "error: two\r\n", end: "\u{1b}]133;D;0\u{07}")
        let id = UUID()
        let target = CrossSearchTarget(surfaceID: id, core: core, place: "tab", pane: nil, currentDirectory: nil)
        let found = try #require(await CrossSessionSearch.search("error", in: [target]))
        let headings = found.results.map { $0.command }
        #expect(headings.map { $0?.title } == ["$ make lint", "$ make test"])
        #expect(headings.map { $0?.outcome } == [.succeeded, .failed(2)])
        #expect(headings[1]?.directory == "/Users/me/src")
        #expect(headings[0]?.key != headings[1]?.key)
        #expect(headings[0]?.key.surfaceID == id)
        // The prompt line is no command's output.
        let prompt = try #require(await CrossSessionSearch.search("make lint", in: [target]))
        #expect(prompt.results.first?.command == nil)
    }

    @Test func onlyReportedFactsAreShown() {
        func info(running: Bool = false, finished: Bool = false, abandoned: Bool = false,
                  exit: Int32? = nil, input: String? = nil, truncated: Bool = false,
                  started: UInt64? = nil) -> FfiCommandInfo {
            FfiCommandInfo(id: 1, epoch: 1, running: running, finished: finished, abandoned: abandoned,
                           exitCode: exit, cwd: nil, input: input, inputTruncated: truncated,
                           startedAtMs: started)
        }
        let id = UUID()
        let noStatus = CommandHeading(surfaceID: id, info: info(finished: true))
        #expect(noStatus.outcome == .endedWithoutStatus)
        #expect(noStatus.title == "Command (command line not reported)")
        #expect(noStatus.details() == "ended, no exit status")
        #expect(CommandHeading(surfaceID: id, info: info(abandoned: true)).outcome == .interrupted)
        #expect(CommandHeading(surfaceID: id, info: info(running: true)).outcome == .running)
        let multi = CommandHeading(surfaceID: id, info: info(finished: true, exit: 0, input: "for x\ndo y"))
        #expect(multi.title == "$ for x …")
        let cut = CommandHeading(surfaceID: id, info: info(finished: true, exit: 1, input: "long", truncated: true))
        #expect(cut.title == "$ long …")
        let timed = CommandHeading(surfaceID: id, info: info(finished: true, exit: 0, started: 1_000))
        #expect(timed.details().contains("started"))
    }

    @Test func theSameIdInAnotherEngineGenerationIsAnotherCommand() {
        func info(epoch: UInt64) -> FfiCommandInfo {
            FfiCommandInfo(id: 1, epoch: epoch, running: false, finished: true, abandoned: false,
                           exitCode: 0, cwd: nil, input: nil, inputTruncated: false, startedAtMs: nil)
        }
        let id = UUID()
        #expect(CommandHeading(surfaceID: id, info: info(epoch: 1)).key
            != CommandHeading(surfaceID: id, info: info(epoch: 2)).key)
    }
}
