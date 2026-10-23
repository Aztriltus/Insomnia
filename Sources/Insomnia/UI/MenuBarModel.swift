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
    /// The last start was refused. Shown as a badge on the eye and a line in
    /// the menu until the next start succeeds, or the menu has been opened
    /// and closed once.
    var startFailure = false
    /// Something in the menu needs attention (an error, a recovery problem).
    var needsAttention = false
}
