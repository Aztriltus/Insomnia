import SwiftUI

/// Everything drawn inside the status item: the eye, and the countdown (or
/// `∞`) while a session runs or starts. Clicks go to the hosting view,
/// which opens the menu.
///
/// The controller writes the status item's length once per width change
/// (`StatusWidthWriter`); the countdown keeps a minimum width that only
/// grows during a session, so that happens a handful of times per session.
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onWidthChange: (CGFloat) -> Void
    let onCountdownWidth: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    private var isRunning: Bool { manager.isActive }
    private var eyeOpen: Bool { isRunning || model.phase == .starting }

    private var countdownText: String {
        if model.phase == .starting { return model.pendingCountdown ?? "" }
        return isRunning ? manager.countdownText : ""
    }

    var body: some View {
        HStack(spacing: 5) {
            icon
            if !countdownText.isEmpty {
                Text(countdownText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    // No content transition and no animation: animating the
                    // digits cost about 46% of a core (engineering.md).
                    .animation(Motion.countdownTick, value: countdownText)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onCountdownWidth($0) }
                    .frame(minWidth: model.countdownMinWidth, alignment: .leading)
                    .transition(Motion.countdownTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onWidthChange($0) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        EyeMarkView(isRunning: eyeOpen, reduceMotion: reduceMotion)
            .frame(width: 20, height: 20)
            .overlay(alignment: .topTrailing) {
                if model.needsAttention || model.startFailure != nil {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: -1)
                }
            }
    }

    /// "Insomnia", "Insomnia, starting", "Insomnia, 5 hours 12 minutes left",
    /// "Insomnia, awake with no time limit"; a warning adds ", needs attention".
    private var accessibilityText: String {
        var text = "Insomnia"
        if model.phase == .starting {
            text += ", starting"
        } else if let s = manager.session {
            text += s.openEnded ? ", awake with no time limit" : ", \(CountdownFormat.spoken(remaining: s.remaining(at: Date()))) left"
        }
        if model.needsAttention || model.startFailure != nil { text += ", needs attention" }
        return text
    }
}
