import Foundation

public enum ReminderSchedule {
    public static let maximumAnnouncementCount = 20
    private static let firstRepeatDelay: TimeInterval = 300

    public static func normalizedCount(_ count: Int) -> Int {
        min(max(0, count), maximumAnnouncementCount)
    }

    public static func delay(afterAnnouncementCount count: Int) -> TimeInterval {
        let normalized = normalizedCount(count)
        guard normalized > 0 else { return 0 }
        return firstRepeatDelay * TimeInterval(1 << (normalized - 1))
    }

    public static func isDue(
        announcementCount: Int,
        lastAnnouncedAt: Date?,
        at date: Date
    ) -> Bool {
        let normalized = normalizedCount(announcementCount)
        guard normalized > 0, let lastAnnouncedAt else { return true }
        return date.timeIntervalSince(lastAnnouncedAt) >= delay(afterAnnouncementCount: normalized)
    }
}
