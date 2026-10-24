import AppKit
import Foundation
import Observation

/// The sudoers rule that lets the app run its four `pmset` commands without
/// a password. The app writes it at first launch (`AppSetup`); install.sh
/// writes the same lines, and a test checks the two agree.
enum SudoersRule {
    static let path = "/etc/sudoers.d/insomnia"
    static let header = "# Installed by Insomnia. Exactly four commands, nothing else."
    /// The commands, each exactly as sudo matches it.
    static let commands = [
        ["/usr/bin/pmset", "-a", "disablesleep", "1"],
        ["/usr/bin/pmset", "-a", "disablesleep", "0"],
        ["/usr/bin/pmset", "-b", "lowpowermode", "1"],
        ["/usr/bin/pmset", "-b", "lowpowermode", "0"],
    ]

    /// The file's text for `user`, or nil for a name sudoers could read as
    /// syntax (anything but letters, digits, `.`, `_` and `-`).
    static func text(user: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        let lines = commands.map { "\(user) ALL=(root) NOPASSWD: \($0.joined(separator: " "))" }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    /// Run as root: validates the file at `staged` and only then installs it,
    /// owned by root and readable by no one else.
    static func installCommand(staged: String) -> String {
        let file = shellQuoted(staged)
        return "/usr/sbin/visudo -cf \(file) && /usr/bin/install -m 0440 -o root -g wheel \(file) \(path)"
    }

    static let removeCommand = "/bin/rm -f \(path)"

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs a shell command as root behind macOS's own password dialog.
enum AdminShell {
    enum Outcome: Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// The AppleScript that runs `command` with administrator privileges,
    /// showing `prompt` in the dialog. Pure.
    static func script(command: String, prompt: String) -> String {
        "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges"
    }

    /// An AppleScript string literal.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// osascript reports a dismissed dialog as error -128.
    static func outcome(status: Int32, stderr: String) -> Outcome {
        if status == 0 { return .done }
        if stderr.contains("(-128)") { return .cancelled }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func run(_ command: String, prompt: String) async -> Outcome {
        do {
            // Long enough to type a password; the dialog is macOS's.
            let r = try await CancellableCommand().run("/usr/bin/osascript", ["-e", script(command: command, prompt: prompt)], timeout: 600)
            return outcome(status: r.status, stderr: r.stderr)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where the app runs from, and whether it has to be moved first.
enum InstallLocation {
    static let applications = URL(fileURLWithPath: "/Applications/Insomnia.app")

    /// A copy opened from the disk image (directly, or through macOS's
    /// translocation of a quarantined app) can't stay there: the image is
    /// read-only and goes away when ejected, and the recovery agent pins
    /// the path it runs from. Pure.
    static func mustMove(bundlePath: String, readOnlyVolume: Bool) -> Bool {
        readOnlyVolume || bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }

    static func isReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }
}

/// First-launch setup for a copy dragged out of the disk image: move it to
/// Applications if it runs from the image, then write the sudoers rule
/// behind macOS's password dialog. The recovery agent needs nothing here:
/// the app pins it to its own bundle whenever a session starts
/// (`LaunchdBackstop.arm`). A build run outside an app bundle (`swift run`)
/// skips setup.
@MainActor
@Observable
final class AppSetup {
    enum Step: Equatable {
        case checking
        case move
        case permission
        case done
    }

    private(set) var step: Step = .checking
    private(set) var busy = false
    /// Why the last attempt didn't work, shown under the button.
    private(set) var problem: String?

    let bundle: URL

    init(bundle: URL = Bundle.main.bundleURL) {
        self.bundle = bundle.standardizedFileURL
    }

    var applies: Bool {
        #if DEBUG
        if debugStep != nil { return true }
        #endif
        return bundle.pathExtension == "app"
    }

    #if DEBUG
    /// Debug builds only: `INSOMNIA_DEBUG_SETUP=move|permission|done` shows
    /// that step without checking, so the window can be captured. Its
    /// buttons do nothing.
    private var debugStep: Step? {
        switch ProcessInfo.processInfo.environment["INSOMNIA_DEBUG_SETUP"] {
        case "move": .move
        case "permission": .permission
        case "done": .done
        default: nil
        }
    }
    #endif
    /// Setup isn't finished: the menu shows a Finish Setup row and no grid.
    var needed: Bool { applies && (step == .move || step == .permission) }

    /// In macOS's password dialog; the window has already said why.
    static let prompt = "Insomnia wants to set up its permission to turn sleep off and on."

    func refresh() async {
        #if DEBUG
        if let debugStep { step = debugStep; return }
        #endif
        guard applies else { step = .done; return }
        if InstallLocation.mustMove(bundlePath: bundle.path, readOnlyVolume: InstallLocation.isReadOnlyVolume(bundle)) {
            step = .move
        } else {
            step = await Self.ruleWorks() ? .done : .permission
        }
    }

    /// True when sudo would run all four commands without a password.
    /// `-l` only lists, and `-k` ignores a password typed recently in
    /// Terminal, so nothing runs and a cached login doesn't pass for the rule.
    static func ruleWorks() async -> Bool {
        for command in SudoersRule.commands {
            guard let r = try? await CancellableCommand().run("/usr/bin/sudo", ["-k", "-n", "-l"] + command, timeout: 15), r.succeeded else {
                return false
            }
        }
        return true
    }

    /// Copies the app to Applications (an older copy there goes to the
    /// Trash), opens the copy and quits. Another running Insomnia is asked
    /// to quit first, which ends its session.
    func moveToApplications() async {
        #if DEBUG
        if debugStep != nil { return }
        #endif
        busy = true
        problem = nil
        defer { busy = false }
        let fm = FileManager.default
        let target = InstallLocation.applications
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            other.terminate()
            for _ in 0..<40 where !other.isTerminated {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard other.isTerminated else {
                problem = "Quit the other copy of Insomnia, then try again."
                return
            }
        }
        do {
            if fm.fileExists(atPath: target.path) {
                try fm.trashItem(at: target, resultingItemURL: nil)
            }
            let r = try await CancellableCommand().run("/usr/bin/ditto", [bundle.path, target.path], timeout: 120)
            guard r.succeeded else { throw SetupError(message: "ditto: \(r.stderr)") }
        } catch {
            Log.error("setup: could not copy the app to Applications: \(error.localizedDescription)")
            problem = "Couldn\u{2019}t move Insomnia. Drag it to Applications in the Finder."
            return
        }
        Log.info("setup: copied the app to \(target.path); opening it")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try? await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        NSApp.terminate(nil)
    }

    /// Writes the sudoers rule behind macOS's password dialog, then checks
    /// it works.
    func allowSleepControl() async {
        #if DEBUG
        if debugStep != nil { return }
        #endif
        busy = true
        problem = nil
        defer { busy = false }
        guard let text = SudoersRule.text(user: NSUserName()) else {
            problem = "Your account name can\u{2019}t be used in the rule."
            return
        }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try text.write(to: staged, atomically: true, encoding: .utf8)
        } catch {
            problem = "Couldn\u{2019}t finish setup. Try again."
            return
        }
        switch await AdminShell.run(SudoersRule.installCommand(staged: staged.path), prompt: Self.prompt) {
        case .cancelled:
            return
        case let .failed(reason):
            Log.error("setup: writing \(SudoersRule.path) failed: \(reason)")
            problem = "Couldn\u{2019}t finish setup. Try again."
            return
        case .done:
            break
        }
        if await Self.ruleWorks() {
            Log.info("setup: \(SudoersRule.path) installed and verified")
            step = .done
        } else {
            Log.error("setup: \(SudoersRule.path) installed but sudo still asks for a password")
            problem = "Couldn\u{2019}t finish setup. Try again."
        }
    }
}

/// Settings > Uninstall: ends the session, removes the sudoers rule behind
/// macOS's password dialog, the recovery agent and the login item, moves the
/// app to the Trash and quits. Settings and logs stay.
@MainActor
enum AppUninstall {
    enum Outcome: Equatable {
        case cancelled
        /// The session couldn't be fully undone; nothing was removed.
        case busy
        case failed
        /// Everything was removed and the app is quitting.
        case quitting
    }

    static let prompt = "Insomnia wants to remove its permission to turn sleep off and on."

    static func run(manager: SessionManager, loginItem: LoginItem) async -> Outcome {
        // The agent goes below, so nothing may be left for it to undo.
        guard await manager.end(reason: .quit) == .restored else { return .busy }
        switch await AdminShell.run(SudoersRule.removeCommand, prompt: prompt) {
        case .cancelled:
            return .cancelled
        case let .failed(reason):
            Log.error("uninstall: removing \(SudoersRule.path) failed: \(reason)")
            return .failed
        case .done:
            break
        }
        await LaunchdBackstop(paths: manager.paths).remove()
        var config = manager.config
        if loginItem.isRegistered { loginItem.set(false, config: &config) }
        if Bundle.main.bundleURL.pathExtension == "app" {
            do {
                try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
            } catch {
                Log.error("uninstall: could not move the app to the Trash: \(error.localizedDescription)")
            }
        }
        Log.info("uninstalled: rule, recovery agent and app removed")
        NSApp.terminate(nil)
        return .quitting
    }
}
