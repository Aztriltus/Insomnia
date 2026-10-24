import AppKit
import XCTest
@testable import Insomnia

/// The status item's menu (redesign spec, section 1): what each state
/// offers, and starting from it, through the manager's answer.
final class SessionMenuTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }
    let locale = Locale(identifier: "en_US")
    let durations = TemplateList.freshDefaults
    var cells: [SessionMenu.Cell] { SessionMenu.cells(durations) }

    func items(_ state: SessionMenu.State) -> [SessionMenu.Item] {
        SessionMenu.items(state: state, durations: durations, now: now, calendar: calendar, locale: locale)
    }

    func testTheGridIsInfinityThenTheSevenDurations() {
        XCTAssertEqual(cells.map(\.title), ["\u{221E}", "10m", "30m", "1h", "2h", "4h", "8h", "12h"])
    }

    let section = SessionMenu.Item.section("Keep awake for")

    func testIdleIsAClosedEyeInactiveAndTheGridWithNothingHighlighted() {
        XCTAssertEqual(items(.idle), [
            .header(title: "Inactive", value: nil, eyeOpen: false),
            section,
            .grid(cells: cells, selected: nil, selectedTitle: nil, enabled: true),
        ])
    }

    func testStartingOpensTheEyeAndDisablesTheGrid() {
        XCTAssertEqual(items(.starting), [
            .header(title: "Starting\u{2026}", value: nil, eyeOpen: true),
            section,
            .grid(cells: cells, selected: nil, selectedTitle: nil, enabled: false),
        ])
    }

    func testAFailedStartSaysSoUnderTheHeader() {
        XCTAssertEqual(items(.failed), [
            .header(title: "Inactive", value: nil, eyeOpen: false),
            .failure("Couldn\u{2019}t start. Try again."),
            section,
            .grid(cells: cells, selected: nil, selectedTitle: nil, enabled: true),
        ])
    }

    /// The header says until when; the running cell says how long, so the
    /// time left isn't shown twice.
    func testRunningHighlightsTheChosenCellAndTheHeaderSaysUntilWhen() {
        let out = items(.running(endsAt: now.addingTimeInterval(3600), choice: 3600))
        XCTAssertEqual(out.count, 3)
        guard case let .header(title, value, eyeOpen) = out[0] else { return XCTFail("\(out)") }
        XCTAssertEqual(title, "Active")
        XCTAssertTrue(eyeOpen)
        XCTAssertTrue(value?.hasPrefix("until ") ?? false, "\(String(describing: value))")
        XCTAssertEqual(out[2], .grid(cells: cells, selected: .duration(3600), selectedTitle: "1h", enabled: true))
    }

    /// The running cell counts down from its own label, and goes back to it
    /// once the session ends.
    func testTheRunningCellCountsDown() {
        let later = items(.running(endsAt: now.addingTimeInterval(43 * 60 + 5), choice: 3600))
        XCTAssertEqual(later[2], .grid(cells: cells, selected: .duration(3600), selectedTitle: "44m", enabled: true))
        XCTAssertEqual(items(.idle)[2], .grid(cells: cells, selected: nil, selectedTitle: nil, enabled: true))
        XCTAssertEqual(cells.first { $0 == .duration(3600) }?.title, "1h")
    }

    func testANoTimeLimitSessionHighlightsInfinity() {
        XCTAssertEqual(items(.openEnded), [
            .header(title: "Active", value: "No time limit", eyeOpen: true),
            section,
            .grid(cells: cells, selected: .openEnded, selectedTitle: "\u{221E}", enabled: true),
        ])
    }

    /// With nothing highlighted, clicking can't end it, so End session shows.
    func testARunningSessionWithNoKnownCellOffersEndSession() {
        XCTAssertEqual(items(.running(endsAt: now.addingTimeInterval(3600), choice: nil)).last, .endSession)
        XCTAssertEqual(items(.running(endsAt: now.addingTimeInterval(3600), choice: 999)).last, .endSession)
    }

    func testClicking() {
        XCTAssertEqual(SessionMenu.action(for: .duration(600), in: .idle), .start(.duration(600)))
        XCTAssertEqual(SessionMenu.action(for: .openEnded, in: .failed), .start(.openEnded))
        XCTAssertEqual(SessionMenu.action(for: .duration(600), in: .starting), .none)
        let running = SessionMenu.State.running(endsAt: now, choice: 3600)
        XCTAssertEqual(SessionMenu.action(for: .duration(3600), in: running), .end, "the highlighted cell ends it")
        XCTAssertEqual(SessionMenu.action(for: .duration(7200), in: running), .switchTo(.duration(7200)))
        XCTAssertEqual(SessionMenu.action(for: .openEnded, in: running), .switchTo(.openEnded))
        XCTAssertEqual(SessionMenu.action(for: .openEnded, in: .openEnded), .end)
        XCTAssertEqual(SessionMenu.action(for: .duration(600), in: .openEnded), .switchTo(.duration(600)))
    }

    func testUntilNamesTodayTheWeekdayOrTheDate() {
        // 800_000_000 is a Friday evening in Los Angeles.
        let today = SessionMenu.untilPhrase(endsAt: now.addingTimeInterval(3600), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(today.hasPrefix("until "), today)
        XCTAssertFalse(today.contains(","), today)
        let week = SessionMenu.untilPhrase(endsAt: now.addingTimeInterval(2 * 86400), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(week.hasPrefix("until Sun "), week)
        let later = SessionMenu.untilPhrase(endsAt: now.addingTimeInterval(20 * 86400), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(later.hasPrefix("until May 28, "), later)
    }

}

/// Starting from the menu, through the manager's answer, with the
/// recovery agent a fake that can hold or refuse.
final class MenuBarFlowTests: XCTestCase {
    @MainActor
    private struct Rig {
        let h: Harness
        let manager: SessionManager
        let controller: StatusItemController

        init() {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            let clock = h.clock
            controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now })
        }

        var model: MenuBarModel { controller.model }
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    func testAStartShowsStartingWithItsCountdownUntilTheManagerConfirms() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate

        rig.controller.start(.timed(4 * 3600))
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertEqual(rig.controller.menuState, .starting)

        await gate.open()
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.manager.countdownText, "4h")
        XCTAssertEqual(rig.controller.menuState, .running(endsAt: rig.manager.session!.endsAt, choice: 4 * 3600))
    }

    @MainActor
    func testARefusedStartClosesTheEyeAndLeadsTheMenuWithTheReason() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true

        rig.controller.start(.timed(3600))
        let failed = await waitUntil { rig.model.phase == .idle && rig.model.startFailure }
        XCTAssertTrue(failed)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.controller.menuState, .failed)
        // The raw reason goes to the log, not the menu.
        // The status lines don't repeat it.
        XCTAssertFalse(StatusItemController.menuItems(manager: rig.manager, status: PlaceholderStatus()).contains { $0.title.contains("backstop") })

        // Seen once in the menu, it goes.
        rig.controller.menuDidClose(NSMenu())
        XCTAssertFalse(rig.model.startFailure)
        XCTAssertEqual(rig.controller.menuState, .idle)
    }

    @MainActor
    func testARetryAfterARefusalClearsTheFailure() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.controller.start(.timed(3600))
        _ = await waitUntil { rig.model.startFailure }
        rig.h.backstop.failArm = false
        rig.controller.start(.timed(3600))
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertFalse(rig.model.startFailure)
    }

    @MainActor
    func testNoTimeLimitShowsInfinityRenewsAndSkipsTheReminder() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.controller.start(.openEnded)
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        let s = try! XCTUnwrap(rig.manager.session)
        XCTAssertTrue(s.openEnded)
        XCTAssertEqual(rig.manager.countdownText, "\u{221E}")
        XCTAssertEqual(rig.controller.menuState, .openEnded)
        XCTAssertTrue(rig.manager.leaseTimerArmed)
        XCTAssertFalse(rig.manager.countdownTimerArmed, "nothing to redraw")
        XCTAssertNil(rig.controller.reminder.scheduledFor, "no 5-minutes-left reminder")

        // A renewal moves the deadline an hour from now.
        rig.h.clock.advance(15 * 60)
        await rig.manager.renewLease()
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(try rig.manager.store.loadSession()?.endsAt, rig.h.clock.now.addingTimeInterval(3600))

        // Set a time limit: timed again, counted from now.
        await rig.manager.setTimeLimit(45 * 60)
        XCTAssertEqual(rig.manager.session?.openEnded, false)
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(45 * 60))
        XCTAssertEqual(rig.manager.countdownText, "45m")
        XCTAssertFalse(rig.manager.leaseTimerArmed)

        // And back.
        await rig.manager.removeTimeLimit()
        XCTAssertEqual(rig.manager.session?.openEnded, true)
        XCTAssertTrue(rig.manager.leaseTimerArmed)
    }

    @MainActor
    func testALapsedOpenEndedSessionFoundAtLaunchEndsWithItsOwnReason() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let first = h.makeManager()
        await first.startOpenEnded()
        XCTAssertTrue(first.isActive)
        // The app dies; nothing renews. An hour and a bit later it launches.
        h.clock.advance(OpenEndedLease.lease + 60)
        let second = h.makeManager()
        await second.reconcile()
        XCTAssertFalse(second.isActive)
        XCTAssertTrue(h.notifier.posts.contains { $0.body == "Insomnia stopped running." }, "\(h.notifier.posts)")
    }

    @MainActor
    func testTheCountdownRedrawsOnceAMinuteAtTheDeadlinesMinuteMarks() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        h.clock.advance(17)
        await manager.start(duration: 2 * 3600)
        XCTAssertEqual(manager.countdownText, "2h")
        XCTAssertTrue(manager.countdownTimerArmed)
        h.clock.advance(59)
        manager.refreshCountdown()
        XCTAssertEqual(manager.countdownText, "2h")
        h.clock.advance(1)
        manager.refreshCountdown()
        XCTAssertEqual(manager.countdownText, "1h 59m")
    }
}
