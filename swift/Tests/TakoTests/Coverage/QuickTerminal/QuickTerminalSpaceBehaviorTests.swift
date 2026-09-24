import Testing
import AppKit
@testable import Tako

private func isMove(_ behavior: QuickTerminalSpaceBehavior?) -> Bool {
    if case .move = behavior { return true }
    return false
}
private func isRemain(_ behavior: QuickTerminalSpaceBehavior?) -> Bool {
    if case .remain = behavior { return true }
    return false
}

struct QuickTerminalSpaceBehaviorTests {
    @Test func fromTakoConfigParsesKnownStrings() {
        #expect(isMove(QuickTerminalSpaceBehavior(fromTakoConfig: "move")))
        #expect(isRemain(QuickTerminalSpaceBehavior(fromTakoConfig: "remain")))
    }

    @Test func fromTakoConfigRejectsUnknownStrings() {
        #expect(QuickTerminalSpaceBehavior(fromTakoConfig: "bogus") == nil)
        #expect(QuickTerminalSpaceBehavior(fromTakoConfig: "") == nil)
    }

    @Test func moveCanJoinAllSpacesAndIgnoresCycle() {
        let behavior = QuickTerminalSpaceBehavior.move.collectionBehavior
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.ignoresCycle))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(!behavior.contains(.moveToActiveSpace))
    }

    @Test func remainMovesToActiveSpaceAndIgnoresCycle() {
        let behavior = QuickTerminalSpaceBehavior.remain.collectionBehavior
        #expect(behavior.contains(.moveToActiveSpace))
        #expect(behavior.contains(.ignoresCycle))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(!behavior.contains(.canJoinAllSpaces))
    }
}
