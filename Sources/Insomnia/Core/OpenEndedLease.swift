import Foundation

/// A session with no time limit is a timed session on a rolling deadline:
/// the end time is kept `lease` ahead and renewed every `renewEvery` while
/// the app runs. If the app dies, renewals stop and the recovery agent puts
/// sleep back once the last deadline passes (redesign spec, "Sessions with
/// no time limit"). Pure.
enum OpenEndedLease {
    static let lease: TimeInterval = 60 * 60
    static let renewEvery: TimeInterval = 15 * 60

    /// A new open-ended session starting at `now`.
    static func newSession(now: Date) -> Session {
        Session(startedAt: now, endsAt: now.addingTimeInterval(lease), openEnded: true)
    }

    /// The session with its deadline moved to `lease` from `now`. Never
    /// moves the deadline earlier.
    static func renewed(_ session: Session, now: Date) -> Session {
        var s = session
        s.openEnded = true
        s.endsAt = max(session.endsAt, now.addingTimeInterval(lease))
        return s
    }

    /// "Remove time limit": open-ended from now on.
    static func removingLimit(_ session: Session, now: Date) -> Session {
        var s = session
        s.openEnded = true
        s.choice = nil
        s.endsAt = now.addingTimeInterval(lease)
        return s
    }

    /// Switching to a grid duration: the session ends `duration` from now
    /// (not from its start), capped at `maxDuration`, whether it had a time
    /// limit or not.
    static func settingLimit(_ session: Session, duration: TimeInterval, now: Date, maxDuration: TimeInterval) -> Session {
        var s = session
        s.openEnded = false
        s.choice = duration
        s.endsAt = SessionMath.endsAt(start: now, duration: duration, maxDuration: maxDuration)
        return s
    }
}
