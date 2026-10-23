import SwiftUI

/// The status item: the eye and nothing else, so its width never changes.
/// Closed while idle, open while a session runs or starts; an orange dot
/// when something needs attention. Clicks go to the hosting view, which
/// opens the menu.
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onWidthChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    private var eyeOpen: Bool { manager.isActive || model.phase == .starting }

    var body: some View {
        EyeMarkView(isRunning: eyeOpen, reduceMotion: reduceMotion)
            .frame(width: 20, height: 20)
            .overlay(alignment: .topTrailing) {
                if model.needsAttention || model.startFailure {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: -1)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: NSStatusBar.system.thickness)
            .fixedSize()
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onWidthChange($0) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
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
        if model.needsAttention || model.startFailure { text += ", needs attention" }
        return text
    }
}
