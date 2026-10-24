import AppKit
import Observation
import Sparkle

/// Over-the-air updates with Sparkle. The feed is an appcast on the fork's
/// GitHub Releases (`SUFeedURL` in Info.plist), and each update is signed
/// with the EdDSA key whose public half is `SUPublicEDKey`. Sparkle checks
/// once a day on its own and replaces the bundle in place; with a Developer
/// ID build the recovery agent's pinned requirement still matches the new
/// bundle, so no reinstall is needed.
///
/// Off outside an app bundle (tests, `swift run`) and when the bundle has no
/// feed: there is nothing to check against then.
@MainActor
@Observable
final class AppUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        let bundled = bundle.bundleURL.pathExtension == "app"
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        controller = bundled && !(feed ?? "").isEmpty
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// Whether this build can update itself.
    var isAvailable: Bool { controller != nil }

    /// "Check for Updates…": Sparkle's own window says what it found and
    /// installs on the user's say-so.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
