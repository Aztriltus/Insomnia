import SwiftUI

/// The first-launch window (`AppSetup`): one step at a time, each with one
/// button. The eye opens when setup is done.
struct SetupView: View {
    let setup: AppSetup
    /// Closes the window and opens the menu, so the user sees where Insomnia lives.
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            EyeMarkView(isRunning: setup.step == .done, reduceMotion: reduceMotion, size: 56)
                .frame(width: 56, height: 56)
                .foregroundStyle(.primary)
                .animation(Motion.blink(opening: setup.step == .done, reduceMotion: reduceMotion), value: setup.step == .done)
                .accessibilityHidden(true)
            Text(copy.title)
                .font(.title2.weight(.semibold))
            Text(copy.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if setup.step == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(copy.button, action: act)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.busy)
                }
            }
            .padding(.top, 6)
            if let problem = setup.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(width: 380)
    }

    private var copy: (title: String, message: String, button: String) {
        switch setup.step {
        case .checking: ("Setting up", "", "")
        case .move: ("Move to Applications", "Insomnia can\u{2019}t run from the disk image.", "Move to Applications")
        case .permission: ("Set up Insomnia", "It needs your password once to turn sleep off and on.", "Set Up\u{2026}")
        case .done: ("Insomnia is ready", "Click the eye in the menu bar to keep your Mac awake.", "Done")
        }
    }

    private func act() {
        switch setup.step {
        case .move: Task { await setup.moveToApplications() }
        case .permission: Task { await setup.allowSleepControl() }
        case .done: finish()
        case .checking: break
        }
    }
}
