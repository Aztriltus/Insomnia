import AppKit
import XCTest
@testable import Insomnia

final class UIStatusTests: XCTestCase {
    /// The status item uses macOS's standard square slot and an icon of a
    /// fixed size, open or closed, with or without the attention dot.
    @MainActor
    func testTheStatusItemIsTheStandardSquareInEveryState() {
        _ = NSApplication.shared
        let harness = Harness()
        defer { harness.home.destroy() }
        let controller = StatusItemController(manager: harness.makeManager(), status: PlaceholderStatus(), showSettings: {})
        XCTAssertEqual(controller.statusItemLength, NSStatusItem.squareLength)
        for (open, attention) in [(false, false), (true, false), (false, true), (true, true)] {
            XCTAssertEqual(StatusIcon.image(open: open, attention: attention).size, StatusIcon.size)
        }
        XCTAssertTrue(StatusIcon.image(open: true, attention: false).isTemplate, "follows the menu bar's light or dark look")
    }

    /// The blink was over in a handful of frames and barely read. It has to
    /// be slower than the baseline spring so the lid lift and the lash
    /// hand-over are seen, and slower than the Reduce Motion crossfade too.
    @MainActor
    func testTheBlinkIsSlowerThanTheBaseSpring() {
        XCTAssertGreaterThan(Motion.blinkResponse, Motion.baseResponse)
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), .spring(response: 0.95, dampingFraction: 0.9))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: false), .spring(response: 0.8, dampingFraction: 0.95))
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), Motion.blink)
        XCTAssertNotEqual(Motion.blink, Motion.base)
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertGreaterThan(Motion.reducedBlinkDuration, 0.15)
    }

    func testSleepHeldLine() {
        // The normal case says nothing; the first line already says Active.
        XCTAssertNil(SleepHeldLine.line(sessionActive: true, sleepHeld: true))
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: false),
            SleepHeldLine.Line(text: "Not keeping the Mac awake", isWarning: true)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: false, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep is still turned off", isWarning: true)
        )
        XCTAssertNil(SleepHeldLine.line(sessionActive: false, sleepHeld: false))
    }

    @MainActor
    func testPlaceholderReportsNothing() {
        let s = PlaceholderStatus()
        XCTAssertFalse(s.lidClosed)
        XCTAssertNil(s.batteryPercent)
        XCTAssertFalse(s.isCharging)
        XCTAssertNil(s.wifiSSID)
        XCTAssertNil(s.lastGap)
        XCTAssertEqual(s.frozenCount, 0)
        XCTAssertFalse(s.dockerPaused)
        XCTAssertTrue(s.throttledBrowsers.isEmpty)
        XCTAssertNil(s.hotspotPasswordReport)
        XCTAssertNil(s.instantWatts())
        s.refreshInstant()
        s.refreshOnDemand()
        s.relaunchUnthrottled(ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome"))
    }

    func testMachineLine() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: true, watts: 4.12, wifiSSID: "iPhone", batteryPercent: nil, isCharging: false),
            "Lid: closed \u{00B7} 4.1 W \u{00B7} Wi-Fi: iPhone"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false),
            "Lid: open"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: "", batteryPercent: 82, isCharging: true),
            "Lid: open \u{00B7} 82% charging"
        )
    }

    func testActionsLine() {
        XCTAssertNil(StatusLines.actions(frozenCount: 0, dockerPaused: false, lastGap: nil))
        XCTAssertEqual(StatusLines.actions(frozenCount: 3, dockerPaused: true, lastGap: nil), "3 apps frozen \u{00B7} Docker paused")
        XCTAssertEqual(StatusLines.actions(frozenCount: 1, dockerPaused: false, lastGap: 12.4), "1 app frozen \u{00B7} last gap 12s")
        XCTAssertEqual(StatusLines.actions(frozenCount: 0, dockerPaused: true, lastGap: 0), "Docker paused")
    }

    func testThrottleWarning() {
        XCTAssertNil(StatusLines.throttleWarning([]))
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome"]), "\u{26A0} Chrome is throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc"]), "\u{26A0} Chrome and Arc are throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc", "Chromium"]), "\u{26A0} Chrome, Arc, and Chromium are throttled")
    }

    func testMenuListsStatusThenSettingsAndQuit() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: "Lid: closed \u{00B7} 82%",
            actions: "3 apps frozen",
            throttledBrowsers: [Self.chrome],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Lid: closed \u{00B7} 82%", kind: .info),
            StatusMenu.Item(title: "3 apps frozen", kind: .info),
            StatusMenu.Item(title: "Throttled", kind: .throttled([Self.chrome])),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    func testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: ""
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
        XCTAssertFalse(items.contains { $0.kind == .separator })
    }

    func testMenuShowsTheLastErrorAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "sudo: a password is required"
        )
        XCTAssertEqual(items.first, StatusMenu.Item(title: "sudo: a password is required", kind: .warning))
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
    }

    /// A hotspot join skipped for want of a password is a warning line in
    /// the menu, between the browser items and the session error, so the
    /// failure is never silent.
    func testMenuShowsTheHotspotPasswordProblemAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: [Self.chrome],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required"
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.throttled([Self.chrome]), .warning, .warning, .separator, .settings, .quit]
        )
        XCTAssertEqual(items[1], StatusMenu.Item(
            title: "Hotspot password needs re-entering",
            kind: .warning
        ))
        XCTAssertEqual(
            StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], hotspotWarning: nil, error: nil).map(\.kind),
            [.settings, .quit]
        )
    }

    /// Each problem has a menu line, a sentence for the notification, and a
    /// Settings notice except for a missing item, where the empty field is
    /// the notice.
    func testHotspotPasswordProblemCopy() {
        XCTAssertEqual(HotspotPasswordProblem.missing.menuLine, "Hotspot password missing")
        XCTAssertNil(HotspotPasswordProblem.missing.settingsNotice)
        XCTAssertEqual(HotspotPasswordProblem.unreadable.settingsNotice, "Can\u{2019}t read the saved password. Choose the network again.")
        XCTAssertTrue(HotspotPasswordProblem.unreadable.explanation.hasSuffix("Enter it again in Settings."))
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").menuLine, "Hotspot password needs re-entering", "the raw error stays out of the menu")
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").settingsNotice, "Can\u{2019}t read the saved password. Choose the network again.", "the raw error stays out of Settings")
        XCTAssertEqual(KeychainError(status: errSecAuthFailed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInteractionNotAllowed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInvalidOwnerEdit).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecParam).problem, .error("keychain: \(securityMessage(errSecParam))"))
    }

    /// The relaunch item asks first, since the browser is quit and its
    /// windows come back only through its own session restore. Cancel
    /// hands nothing on; confirming hands on the bundle id and name the
    /// item carried, even when a scan emptied the list during the alert.
    @MainActor
    func testRelaunchAsksBeforeQuittingAndCancelDoesNothing() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = RecordingStatusSource()
        source.throttledBrowsers = [Self.chrome, Self.arc]
        let asked = Locked<[String]>([])
        let answer = Locked(false)
        let controller = StatusItemController(
            manager: h.makeManager(),
            status: source,
            showSettings: {},
            confirmRelaunch: { name in
                asked.value.append(name)
                source.throttledBrowsers = []
                return answer.value
            }
        )

        controller.relaunchBrowser(Self.chrome)
        XCTAssertEqual(asked.value, ["Chrome"])
        XCTAssertEqual(source.relaunched, [])

        answer.value = true
        controller.relaunchBrowser(Self.arc)
        XCTAssertEqual(asked.value, ["Chrome", "Arc"])
        XCTAssertEqual(source.relaunched, [Self.arc])
    }

    private static let chrome = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")
    private static let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")

    /// The prompt names the browser, says the windows depend on the
    /// browser's own startup setting, and gives the 10 s rule.
    func testRelaunchPromptCopy() {
        let prompt = RelaunchPrompt(browser: "Chrome")
        XCTAssertEqual(prompt.title, "Quit and relaunch Chrome?")
        XCTAssertEqual(
            prompt.message,
            "Insomnia quits Chrome and opens it again with the two flags that stop it throttling hidden windows. Your windows and tabs come back only if Chrome is set to reopen them on startup. If Chrome has not quit after 10 s, nothing is relaunched."
        )
        XCTAssertEqual(RelaunchPrompt.confirmTitle, "Quit and relaunch")
        XCTAssertEqual(RelaunchPrompt.cancelTitle, "Cancel")
    }

    /// Greptile caught this as a regression: replacing the popover with a
    /// menu left the throttle warning with no way to act on it. Every
    /// throttled browser is in the group, and its icon offers the relaunch.
    func testEveryThrottledBrowserIsInTheThrottledGroup() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: [Self.chrome, Self.arc],
            error: nil
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.throttled([Self.chrome, Self.arc]), .separator, .settings, .quit]
        )
    }
}

/// A status source that records relaunch requests and reports nothing else.
@MainActor
@Observable
final class RecordingStatusSource: StatusSource {
    var lidClosed = false
    var batteryPercent: Int? = nil
    var isCharging = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount = 0
    var dockerPaused = false
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil
    private(set) var relaunched: [ThrottledBrowser] = []

    func refreshOnDemand() {}
    func refreshInstant() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) { relaunched.append(browser) }
}
