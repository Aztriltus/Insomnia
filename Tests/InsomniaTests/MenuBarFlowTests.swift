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
    let templates: [TimeInterval] = [1800, 3600, 86400]

    func items(_ state: SessionMenu.State) -> [SessionMenu.Item] {
        SessionMenu.items(state: state, templates: templates, now: now, maxDuration: 30 * 86400, calendar: calendar, locale: locale)
    }

    func testIdleOffersTemplatesThenNoTimeLimitThenTheCustomField() {
        XCTAssertEqual(items(.idle), [
            .label("Keep awake for"),
            .template(1800, title: "30 minutes", mode: .start),
            .template(3600, title: "1 hour", mode: .start),
            .template(86400, title: "1 day", mode: .start),
            .noTimeLimit,
            .customField(.start),
        ])
    }

    func testStartingShowsOnlyTheHeader() {
        XCTAssertEqual(items(.starting), [.header("Starting\u{2026}")])
    }

    func testAFailedStartLeadsWithTheReasonAboveTheIdleItems() {
        let out = items(.failed(reason: "could not arm backstop: no"))
        XCTAssertEqual(out.first, .failure("Couldn\u{2019}t start: could not arm backstop: no"))
        XCTAssertEqual(Array(out.dropFirst(2)), items(.idle))
    }

    func testRunningOffersAddTimeRemoveLimitAndEnd() {
        let out = items(.running(endsAt: now.addingTimeInterval(3600)))
        XCTAssertEqual(out.last, .endSession)
        XCTAssertTrue(out.contains(.removeTimeLimit))
        XCTAssertTrue(out.contains(.customField(.add)))
        XCTAssertTrue(out.contains(.template(3600, title: "1 hour", mode: .add)))
        XCTAssertFalse(out.contains(.noTimeLimit))
    }

    func testAddingPastTheCeilingSaysItIsCapped() {
        let out = items(.running(endsAt: now.addingTimeInterval(29.5 * 86400)))
        XCTAssertTrue(out.contains(.template(86400, title: "1 day (capped at 30 days)", mode: .add)))
        XCTAssertTrue(out.contains(.template(1800, title: "30 minutes", mode: .add)))
    }

    func testOpenEndedOffersSetALimitAndEnd() {
        let out = items(.openEnded)
        XCTAssertEqual(out.first, .header("Awake with no time limit"))
        XCTAssertTrue(out.contains(.label("Set a time limit")))
        XCTAssertTrue(out.contains(.template(1800, title: "30 minutes", mode: .setLimit)))
        XCTAssertTrue(out.contains(.customField(.setLimit)))
        XCTAssertFalse(out.contains(.removeTimeLimit))
        XCTAssertEqual(out.last, .endSession)
    }

    func testHeaderNamesTodayTheWeekdayOrTheDate() {
        // 800_000_000 is a Friday evening in Los Angeles.
        let today = SessionMenu.header(endsAt: now.addingTimeInterval(3600), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(today.hasPrefix("Awake until "), today)
        XCTAssertFalse(today.contains(","), today)
        let week = SessionMenu.header(endsAt: now.addingTimeInterval(2 * 86400), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(week.hasPrefix("Awake until Sun "), week)
        let later = SessionMenu.header(endsAt: now.addingTimeInterval(20 * 86400), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(later.hasPrefix("Awake until May 28, "), later)
    }

    func testCustomFieldStatus() {
        XCTAssertEqual(SessionMenu.fieldStatus("", mode: .start), .empty)
        XCTAssertEqual(SessionMenu.fieldStatus("soon", mode: .start), .invalid)
        XCTAssertEqual(SessionMenu.fieldStatus("45", mode: .start), .valid(2700, action: "Start for 45 minutes"))
        XCTAssertEqual(SessionMenu.fieldStatus("2h", mode: .add), .valid(7200, action: "Add 2 hours"))
        XCTAssertEqual(SessionMenu.fieldStatus("1h30m", mode: .setLimit), .valid(5400, action: "End in 1 hour 30 minutes"))
    }

    func testSaveTitle() {
        XCTAssertEqual(SessionMenu.saveTitle(2700, templates: templates), "Save \u{201C}45 minutes\u{201D} as a template")
        XCTAssertNil(SessionMenu.saveTitle(3600, templates: templates))
        let full = (1...8).map { TimeInterval($0) * 3600 }
        XCTAssertEqual(SessionMenu.saveTitle(2700, templates: full), "Templates full. Remove one in Settings")
    }

    @MainActor
    func testTheCountdownWidthOnlyGrowsWithinALevel() {
        typealias C = StatusItemController
        XCTAssertEqual(C.reservedCountdownWidth(current: 0, currentLevel: nil, measured: 40.2, level: .hours)?.width, 41)
        XCTAssertNil(C.reservedCountdownWidth(current: 41, currentLevel: .hours, measured: 20, level: .hours), "never shrinks within a level")
        XCTAssertEqual(C.reservedCountdownWidth(current: 41, currentLevel: .hours, measured: 45, level: .hours)?.width, 45)
        let dropped = C.reservedCountdownWidth(current: 45, currentLevel: .hours, measured: 22, level: .minutes)
        XCTAssertEqual(dropped?.width, 22)
        XCTAssertEqual(dropped?.level, .minutes)
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
        XCTAssertEqual(rig.model.pendingCountdown, "4h")
        XCTAssertEqual(rig.controller.menuState, .starting)

        await gate.open()
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertEqual(rig.manager.countdownText, "4h")
        XCTAssertEqual(rig.controller.menuState, .running(endsAt: rig.manager.session!.endsAt))
    }

    @MainActor
    func testARefusedStartClosesTheEyeAndLeadsTheMenuWithTheReason() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true

        rig.controller.start(.timed(3600))
        let failed = await waitUntil { rig.model.phase == .idle && rig.model.startFailure != nil }
        XCTAssertTrue(failed)
        XCTAssertFalse(rig.manager.isActive)
        guard case let .failed(reason) = rig.controller.menuState else {
            return XCTFail("expected the failed menu, got \(rig.controller.menuState)")
        }
        XCTAssertTrue(reason.contains("backstop"), reason)
        // The status lines don't repeat it.
        XCTAssertFalse(StatusItemController.menuItems(manager: rig.manager, status: PlaceholderStatus()).contains { $0.title.contains("backstop") })

        // Seen once in the menu, it goes.
        rig.controller.menuDidClose(NSMenu())
        XCTAssertNil(rig.model.startFailure)
        XCTAssertEqual(rig.controller.menuState, .idle)
    }

    @MainActor
    func testARetryAfterARefusalClearsTheFailure() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.controller.start(.timed(3600))
        _ = await waitUntil { rig.model.startFailure != nil }
        rig.h.backstop.failArm = false
        rig.controller.start(.timed(3600))
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertNil(rig.model.startFailure)
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
        XCTAssertTrue(h.notifier.posts.contains { $0.body.contains("couldn't keep the session going") }, "\(h.notifier.posts)")
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
