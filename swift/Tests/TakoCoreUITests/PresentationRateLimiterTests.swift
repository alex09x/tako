import Foundation
import XCTest
@testable import TakoCoreUI

final class PresentationRateLimiterTests: XCTestCase {
    func testFiveFPSCoalescesRapidDamageAndAllowsFinalFrameAtDeadline() {
        var now: TimeInterval = 10
        let limiter = PresentationRateLimiter(maximumFramesPerSecond: 5, clock: { now })

        XCTAssertTrue(limiter.claimPermit())
        XCTAssertFalse(limiter.claimPermit(), "rapid damage must retain one debt")
        XCTAssertEqual(limiter.delayUntilPermit ?? -1, 0.2, accuracy: 0.000_001)

        now += 0.199
        XCTAssertFalse(limiter.claimPermit())
        now += 0.001
        XCTAssertTrue(limiter.claimPermit(), "the final coalesced frame is due without new input")
    }

    func testInvalidAndExtremeRatesAreUnlimited() {
        var now: TimeInterval = 1
        let limiter = PresentationRateLimiter(clock: { now })
        for rate: Double? in [nil, 0, -1, .infinity, .nan, Double.greatestFiniteMagnitude, 1e-100, Double.leastNonzeroMagnitude] {
            limiter.maximumFramesPerSecond = rate
            XCTAssertNil(limiter.maximumFramesPerSecond)
            XCTAssertTrue(limiter.claimPermit())
            XCTAssertTrue(limiter.claimPermit())
            now += 0.001
        }
    }

    func testClearingCapImmediatelyReleasesExistingDebt() {
        let now: TimeInterval = 4
        let limiter = PresentationRateLimiter(maximumFramesPerSecond: 5, clock: { now })
        XCTAssertTrue(limiter.claimPermit())
        XCTAssertFalse(limiter.claimPermit())
        limiter.maximumFramesPerSecond = nil
        XCTAssertTrue(limiter.claimPermit())
    }
}
