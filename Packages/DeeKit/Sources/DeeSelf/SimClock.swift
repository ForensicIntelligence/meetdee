import Foundation

/// A deterministic clock for tests and scenarios (SELF.md §3, §12.4). DeeSelf has one
/// clock — `Date` — and pure code never reads the wall clock; tests drive time with this.
public struct SimClock: Sendable, Equatable {
    /// Monday 21 September 2026 00:00:00 UTC.
    public static let epoch = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 86_400))

    public private(set) var now: Date

    public init(_ start: Date = SimClock.epoch) { now = start }

    @discardableResult
    public mutating func advance(_ seconds: TimeInterval) -> Date {
        now = now.addingTimeInterval(max(0, seconds))
        return now
    }

    /// Jumps forward to `date` (never backward).
    @discardableResult
    public mutating func set(_ date: Date) -> Date {
        if date > now { now = date }
        return now
    }

    /// "Mon 18:00", "Thu 19:30", optionally with a week offset: a time in the week of
    /// `epoch` (UTC), plus `week` weeks.
    public static func at(_ spec: String, week: Int = 0) -> Date? {
        let parts = spec.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        guard let d = days.firstIndex(of: parts[0].lowercased().prefix(3).description) else { return nil }
        let hm = parts[1].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return nil }
        let seconds = Double(week * 7 + d) * 86_400 + Double(hm[0] * 3600 + hm[1] * 60)
        return epoch.addingTimeInterval(seconds)
    }
}
