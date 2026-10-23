import Foundation

/// An active keep-awake session. `endsAt` is the only thing that keeps sleep
/// disabled; everything else is bookkeeping.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date
    /// Every extension applied, in order, in seconds.
    var extensions: [TimeInterval]
    /// A session with no time limit: `endsAt` is a rolling deadline the app
    /// renews (`OpenEndedLease`). Absent in a session.json from an earlier
    /// build, which reads as timed; the recovery agent ignores the key and
    /// honours `endsAt` either way.
    var openEnded: Bool

    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = [], openEnded: Bool = false) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.openEnded = openEnded
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, endsAt, extensions, openEnded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        extensions = try c.decode([TimeInterval].self, forKey: .extensions)
        openEnded = try c.decodeIfPresent(Bool.self, forKey: .openEnded) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endsAt, forKey: .endsAt)
        try c.encode(extensions, forKey: .extensions)
        // Written only when set, so a timed session.json reads exactly as
        // earlier builds wrote it.
        if openEnded { try c.encode(true, forKey: .openEnded) }
    }

    /// Seconds left until `endsAt`, never negative.
    func remaining(at now: Date) -> TimeInterval {
        SessionMath.remaining(until: endsAt, at: now)
    }

    /// True once `now` reaches `endsAt`.
    func isExpired(at now: Date) -> Bool {
        SessionMath.isExpired(endsAt: endsAt, at: now)
    }
}
