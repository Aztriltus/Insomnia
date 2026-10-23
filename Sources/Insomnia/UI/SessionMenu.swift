import Foundation

/// The session part of the status item's menu: a line that says whether
/// Insomnia is active, then a grid of ∞ and the saved durations. Clicking a
/// cell starts that session, or switches the running one to it; clicking the
/// highlighted cell ends the session. Pure, so each state can be tested
/// without AppKit; `StatusItemController` builds the NSMenu.
enum SessionMenu {
    enum State: Equatable, Sendable {
        case idle
        case starting
        /// The last start was refused.
        case failed
        /// `choice` is the grid duration it was started with or switched
        /// to, nil when not known (a session an earlier build started).
        case running(endsAt: Date, choice: TimeInterval?)
        case openEnded
    }

    /// One cell of the grid.
    enum Cell: Equatable, Hashable, Sendable {
        case openEnded
        case duration(TimeInterval)

        var title: String {
            switch self {
            case .openEnded: CountdownFormat.openEnded
            case let .duration(d): DurationLabel.short(d)
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .openEnded: "No time limit"
            case let .duration(d): DurationLabel.long(d)
            }
        }
    }

    /// What clicking a cell does.
    enum Action: Equatable, Sendable {
        case start(Cell)
        case switchTo(Cell)
        case end
        case none
    }

    enum Item: Equatable, Sendable {
        /// The first line: "Inactive", "Active until 6:40 PM", …
        case status(String, active: Bool)
        /// "Couldn't start. Try again.", drawn as a warning.
        case failure(String)
        case grid(cells: [Cell], selected: Cell?, enabled: Bool)
        /// Only when a session runs and no cell is highlighted, so there is
        /// always a way to end it.
        case endSession
    }

    static let inactiveTitle = "Inactive"
    static let startingTitle = "Starting\u{2026}"
    static let endSessionTitle = "End session"

    static func cells(_ durations: [TimeInterval]) -> [Cell] {
        [.openEnded] + TemplateList.normalized(durations).map { .duration($0) }
    }

    static func selected(_ state: State) -> Cell? {
        switch state {
        case .openEnded: .openEnded
        case let .running(_, choice): choice.map { .duration($0) }
        case .idle, .starting, .failed: nil
        }
    }

    static func items(
        state: State,
        durations: [TimeInterval],
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [Item] {
        let cells = cells(durations)
        switch state {
        case .idle:
            return [.status(inactiveTitle, active: false), .grid(cells: cells, selected: nil, enabled: true)]
        case .starting:
            return [.status(startingTitle, active: true), .grid(cells: cells, selected: nil, enabled: false)]
        case .failed:
            return [.status(inactiveTitle, active: false), .failure(failureLine), .grid(cells: cells, selected: nil, enabled: true)]
        case .openEnded:
            return [.status("Active, no time limit", active: true), .grid(cells: cells, selected: .openEnded, enabled: true)]
        case let .running(endsAt, _):
            let selected = selected(state).flatMap { cells.contains($0) ? $0 : nil }
            var out: [Item] = [
                .status("Active " + untilPhrase(endsAt: endsAt, now: now, calendar: calendar, locale: locale), active: true),
                .grid(cells: cells, selected: selected, enabled: true),
            ]
            if selected == nil { out.append(.endSession) }
            return out
        }
    }

    /// What clicking `cell` does in `state`.
    static func action(for cell: Cell, in state: State) -> Action {
        switch state {
        case .starting:
            return .none
        case .idle, .failed:
            return .start(cell)
        case .openEnded, .running:
            return selected(state) == cell ? .end : .switchTo(cell)
        }
    }

    /// The reason is in the log; the menu says what happened and what to do.
    static let failureLine = "Couldn\u{2019}t start. Try again."

    /// "until 6:40 PM" today, "until Sat 6:40 PM" within the week,
    /// "until Oct 30, 6:40 PM" after that.
    static func untilPhrase(endsAt: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = calendar.timeZone
        let clock = endsAt.formatted(time)
        if calendar.isDate(endsAt, inSameDayAs: now) {
            return "until \(clock)"
        }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: endsAt)).day ?? 0
        if days < 7 {
            var weekday = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated)
            weekday.timeZone = calendar.timeZone
            return "until \(endsAt.formatted(weekday)) \(clock)"
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        return "until \(endsAt.formatted(day)), \(clock)"
    }
}
