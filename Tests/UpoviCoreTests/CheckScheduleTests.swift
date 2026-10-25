import XCTest
@testable import UpoviCore

final class CheckScheduleTests: XCTestCase {
    func testOfflineAndBusyNeverRunScheduledWork() {
        XCTAssertFalse(CheckSchedule.isDue(enabled: true, online: false, busy: false, lastAttempt: nil, intervalMinutes: 15))
        XCTAssertFalse(CheckSchedule.isDue(enabled: true, online: true, busy: true, lastAttempt: nil, intervalMinutes: 15))
        XCTAssertFalse(CheckSchedule.isDue(enabled: false, online: true, busy: false, lastAttempt: nil, intervalMinutes: 15))
        XCTAssertTrue(CheckSchedule.isDue(enabled: true, online: true, busy: false, lastAttempt: nil, intervalMinutes: 15))
    }
    func testIntervalsAndClockRollback() {
        let attempt = Date(timeIntervalSince1970: 10000)
        XCTAssertFalse(CheckSchedule.isDue(enabled: true, online: true, busy: false, lastAttempt: attempt, intervalMinutes: 0, now: attempt.addingTimeInterval(899)))
        XCTAssertTrue(CheckSchedule.isDue(enabled: true, online: true, busy: false, lastAttempt: attempt, intervalMinutes: 15, now: attempt.addingTimeInterval(900)))
        XCTAssertTrue(CheckSchedule.isDue(enabled: true, online: true, busy: false, lastAttempt: attempt, intervalMinutes: 60, now: attempt.addingTimeInterval(-1)))
    }
}
