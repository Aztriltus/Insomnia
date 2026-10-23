import Foundation
import Observation

/// UI state for the status item. The controller mutates it; the view only
/// reads it.
@MainActor
@Observable
final class MenuBarModel {
    enum Phase: Equatable, Sendable {
        case idle
        /// A start was chosen and the manager has not confirmed it yet (the
        /// recovery agent and `pmset` can take seconds, or refuse).
        case starting
        case running
    }

    var phase: Phase = .idle
    /// The manager's reason for the last refused start. Shown as a badge on
    /// the eye and as the menu's first line until the next start succeeds,
    /// or the menu has been opened and closed once.
    var startFailure: String?
    /// What the countdown reads while a start is pending: the time the
    /// session will have.
    var pendingCountdown: String?
    /// Something in the menu needs attention (an error, a recovery problem).
    var needsAttention = false
    /// The widest the countdown text has been at its current level, so the
    /// status item only grows during a session (redesign spec, "Keeping the
    /// width steady"). Reset when the session ends or the level drops.
    var countdownMinWidth: CGFloat = 0
    var countdownLevel: CountdownFormat.Level?
}
