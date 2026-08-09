import Foundation
import Testing
@testable import NextUpCore

@Test func reminderScheduleStartsImmediatelyThenDoublesFromFiveMinutes() {
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 0) == 0)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 1) == 300)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 2) == 600)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 3) == 1_200)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 4) == 2_400)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 5) == 4_800)
}

@Test func reminderScheduleClampsPersistedCountsWithoutOverflow() {
    #expect(ReminderSchedule.maximumAnnouncementCount == 20)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 20) == 157_286_400)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: 21) == 157_286_400)
    #expect(ReminderSchedule.delay(afterAnnouncementCount: .max) == 157_286_400)
    #expect(ReminderSchedule.normalizedCount(-1) == 0)
}

@Test func reminderScheduleUsesBoundaryInclusiveDueChecks() {
    let last = Date(timeIntervalSince1970: 1_000)
    #expect(!ReminderSchedule.isDue(
        announcementCount: 1, lastAnnouncedAt: last,
        at: Date(timeIntervalSince1970: 1_299.999)
    ))
    #expect(ReminderSchedule.isDue(
        announcementCount: 1, lastAnnouncedAt: last,
        at: Date(timeIntervalSince1970: 1_300)
    ))
    #expect(ReminderSchedule.isDue(
        announcementCount: 0, lastAnnouncedAt: nil,
        at: Date(timeIntervalSince1970: 1_000)
    ))
}
