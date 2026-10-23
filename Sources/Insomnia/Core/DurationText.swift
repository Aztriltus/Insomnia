import Foundation

/// The menu bar countdown: one or two units, never seconds (redesign spec,
/// section 1). Pure.
enum CountdownFormat {
    /// What the countdown is showing, coarsest first. The status item's
    /// reserved width is reset when this drops a level.
    enum Level: Int, Comparable, Sendable {
        case minutes
        case hours
        case days

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Whole minutes left, rounded up, so a running session never reads 0.
    static func minutesLeft(_ remaining: TimeInterval) -> Int {
        let r = max(remaining, 0)
        guard r > 0 else { return 0 }
        return Int((r / 60).rounded(.up))
    }

    static func level(remaining: TimeInterval) -> Level {
        let minutes = minutesLeft(remaining)
        if minutes >= 24 * 60 { return .days }
        if minutes >= 60 { return .hours }
        return .minutes
    }

    /// `3d 4h`, `3d`, `5h 12m`, `5h`, `43m`, `1m`. Zero time reads `0m`.
    static func text(remaining: TimeInterval) -> String {
        let total = minutesLeft(remaining)
        let days = total / (24 * 60)
        let hours = (total % (24 * 60)) / 60
        let minutes = total % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// The same value for VoiceOver: "5 hours 12 minutes".
    static func spoken(remaining: TimeInterval) -> String {
        let total = minutesLeft(remaining)
        let days = total / (24 * 60)
        let hours = (total % (24 * 60)) / 60
        let minutes = total % 60
        if days > 0 {
            return [DurationLabel.unit(days, "day"), hours > 0 ? DurationLabel.unit(hours, "hour") : nil]
                .compactMap { $0 }.joined(separator: " ")
        }
        if hours > 0 {
            return [DurationLabel.unit(hours, "hour"), minutes > 0 ? DurationLabel.unit(minutes, "minute") : nil]
                .compactMap { $0 }.joined(separator: " ")
        }
        return DurationLabel.unit(minutes, "minute")
    }

    /// What a session with no time limit shows in place of a countdown.
    static let openEnded = "\u{221E}"
}

/// Labels for a duration, in the menu and in Settings.
enum DurationLabel {
    static func unit(_ n: Int, _ singular: String) -> String {
        "\(n) \(singular)\(n == 1 ? "" : "s")"
    }

    private static func parts(_ duration: TimeInterval) -> (days: Int, hours: Int, minutes: Int) {
        let total = Int((max(duration, 0) / 60).rounded())
        return (total / (24 * 60), (total % (24 * 60)) / 60, total % 60)
    }

    /// `30 minutes`, `1 hour`, `1 hour 30 minutes`, `2 days`, `1 day 4 hours`.
    /// At most two units; days drop minutes.
    static func long(_ duration: TimeInterval) -> String {
        let p = parts(duration)
        if p.days > 0 {
            return [unit(p.days, "day"), p.hours > 0 ? unit(p.hours, "hour") : nil].compactMap { $0 }.joined(separator: " ")
        }
        if p.hours > 0 {
            return [unit(p.hours, "hour"), p.minutes > 0 ? unit(p.minutes, "minute") : nil].compactMap { $0 }.joined(separator: " ")
        }
        return unit(p.minutes, "minute")
    }

    /// `30m`, `1h`, `1h 30m`, `2d`, `1d 4h`, for the Settings chips.
    static func short(_ duration: TimeInterval) -> String {
        let p = parts(duration)
        if p.days > 0 { return p.hours > 0 ? "\(p.days)d \(p.hours)h" : "\(p.days)d" }
        if p.hours > 0 { return p.minutes > 0 ? "\(p.hours)h \(p.minutes)m" : "\(p.hours)h" }
        return "\(p.minutes)m"
    }
}

/// Reads a typed duration: `45`, `45m`, `45 min`, `2h`, `1.5h`, `1h30m`,
/// `1h 30m`, `1:30`, `3d`, `2d4h`, `2 hours`. A bare number is minutes.
/// Returns nil for anything unreadable, zero, negative, under a minute or
/// over 30 days.
enum DurationParser {
    static let minimum: TimeInterval = 60
    static let maximum: TimeInterval = 30 * 24 * 3600

    static func parse(_ text: String) -> TimeInterval? {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let seconds: TimeInterval?
        if s.contains(":") {
            seconds = parseClock(s)
        } else if let bare = Double(s) {
            seconds = bare * 60
        } else {
            seconds = parseUnits(s)
        }
        guard let seconds, seconds.isFinite, seconds >= minimum, seconds <= maximum else { return nil }
        return seconds
    }

    /// `1:30` is 1 hour 30 minutes.
    private static func parseClock(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let h = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let m = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              h >= 0, (0..<60).contains(m), parts[1].trimmingCharacters(in: .whitespaces).count == 2
        else { return nil }
        return TimeInterval(h * 3600 + m * 60)
    }

    private static let unitSeconds: [(names: [String], seconds: TimeInterval)] = [
        (["d", "day", "days"], 86400),
        (["h", "hr", "hrs", "hour", "hours"], 3600),
        (["m", "min", "mins", "minute", "minutes"], 60),
    ]

    /// A run of number-unit pairs, each unit used once, largest first.
    private static func parseUnits(_ s: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var lastRank = -1
        var i = s.startIndex
        var sawPair = false
        func skipSpaces() { while i < s.endIndex, s[i] == " " { i = s.index(after: i) } }
        while true {
            skipSpaces()
            guard i < s.endIndex else { break }
            let numStart = i
            while i < s.endIndex, s[i].isNumber || s[i] == "." { i = s.index(after: i) }
            guard numStart < i, let value = Double(s[numStart..<i]), value >= 0 else { return nil }
            skipSpaces()
            let unitStart = i
            while i < s.endIndex, s[i].isLetter { i = s.index(after: i) }
            let name = String(s[unitStart..<i])
            guard let rank = unitSeconds.firstIndex(where: { $0.names.contains(name) }), rank > lastRank else { return nil }
            lastRank = rank
            total += value * unitSeconds[rank].seconds
            sawPair = true
        }
        return sawPair ? total : nil
    }
}
