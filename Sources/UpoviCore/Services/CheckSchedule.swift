import Foundation

public enum CheckSchedule {
    public static func isDue(enabled: Bool, online: Bool, busy: Bool, lastAttempt: Date?,
                             intervalMinutes: Int, now: Date = Date()) -> Bool {
        guard enabled, online, !busy else { return false }
        guard let lastAttempt else { return true }
        // Clock rollback must not suppress checks until the old wall clock catches up.
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= Double(max(15, intervalMinutes)) * 60
    }
}
