import Foundation

/// One day's usage (providers-wake-onboarding §5): what the in-app settings show as
/// "today", and what counts toward the false-wake backoff. Numbers only — never text.
public struct UsageDay: Codable, Sendable, Equatable {
    /// Seconds of microphone audio that left the phone (uplink open).
    public var streamedSeconds: Double = 0
    /// Responses Dee produced (replies, initiatives, greetings).
    public var responses: Int = 0
    /// Windows that closed with no accepted turn (likely false wakes).
    public var falseWakes: Int = 0
    /// Conversation windows opened.
    public var windows: Int = 0

    public init(streamedSeconds: Double = 0, responses: Int = 0, falseWakes: Int = 0, windows: Int = 0) {
        self.streamedSeconds = streamedSeconds
        self.responses = responses
        self.falseWakes = falseWakes
        self.windows = windows
    }

    static func + (a: UsageDay, b: UsageDay) -> UsageDay {
        UsageDay(streamedSeconds: a.streamedSeconds + b.streamedSeconds, responses: a.responses + b.responses,
                 falseWakes: a.falseWakes + b.falseWakes, windows: a.windows + b.windows)
    }
}

/// Local, per-day, per-mode usage counters. Pure value; the app persists it as JSON
/// (`UsageCounter.defaultsKey`). Mode is `ProviderMode.rawValue` ("openAI",
/// "lanBrainOpenAIVoice", "lanEverything") so DeeCore stays dependency-free.
public struct UsageCounter: Sendable, Equatable, Codable {
    public static let defaultsKey = "usage.v1"

    /// "yyyy-MM-dd" (in the given calendar's time zone) → mode → totals.
    public private(set) var days: [String: [String: UsageDay]] = [:]

    public init() {}

    public mutating func addStreamed(_ seconds: Double, mode: String, at now: Date, calendar: Calendar = .current) {
        guard seconds.isFinite, seconds > 0 else { return }
        update(mode, now, calendar) { $0.streamedSeconds += seconds }
    }

    public mutating func addResponse(mode: String, at now: Date, calendar: Calendar = .current) {
        update(mode, now, calendar) { $0.responses += 1 }
    }

    public mutating func addFalseWake(mode: String, at now: Date, calendar: Calendar = .current) {
        update(mode, now, calendar) { $0.falseWakes += 1 }
    }

    public mutating func addWindow(mode: String, at now: Date, calendar: Calendar = .current) {
        update(mode, now, calendar) { $0.windows += 1 }
    }

    /// All modes summed for the day of `now`.
    public func today(at now: Date, calendar: Calendar = .current) -> UsageDay {
        (days[Self.key(now, calendar)] ?? [:]).values.reduce(UsageDay(), +)
    }

    public func day(_ at: Date, mode: String, calendar: Calendar = .current) -> UsageDay {
        days[Self.key(at, calendar)]?[mode] ?? UsageDay()
    }

    /// Drops days older than `keepingDays` before `now`.
    public mutating func prune(keepingDays: Int = 31, at now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: now) else { return }
        let keep = Self.key(cutoff, calendar)
        days = days.filter { $0.key >= keep }
    }

    /// The privacy-safe line logged when a window closes (numbers and the mode only).
    public static func windowLog(openSeconds: Double, streamedSeconds: Double, responses: Int, mode: String) -> String {
        let open = Int(openSeconds.rounded())
        let streamed = String(format: "%.1f", max(0, streamedSeconds))
        return "window closed: open \(open) s, streamed \(streamed) s, \(responses) response\(responses == 1 ? "" : "s"), mode \(mode)"
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decoded(_ data: Data?) -> UsageCounter {
        data.flatMap { try? JSONDecoder().decode(UsageCounter.self, from: $0) } ?? UsageCounter()
    }

    // MARK: -

    private mutating func update(_ mode: String, _ now: Date, _ calendar: Calendar, _ f: (inout UsageDay) -> Void) {
        let k = Self.key(now, calendar)
        var d = days[k]?[mode] ?? UsageDay()
        f(&d)
        days[k, default: [:]][mode] = d
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
