import Foundation

/// The session part of the status item's menu (redesign spec, section 1):
/// what to start, add or end. Pure, so the layout of each state can be
/// tested without AppKit; `StatusItemController` turns it into an NSMenu
/// and appends the status lines, Settings and Quit (`StatusMenu`).
enum SessionMenu {
    enum State: Equatable, Sendable {
        case idle
        case starting
        /// The last start was refused; `reason` is the manager's error.
        case failed(reason: String)
        case running(endsAt: Date)
        case openEnded
    }

    /// What the custom field and the templates do in this state.
    enum Mode: Equatable, Sendable {
        case start
        case add
        case setLimit

        /// The row the custom field shows for a valid time.
        func actionTitle(_ duration: TimeInterval) -> String {
            switch self {
            case .start: "Start for \(DurationLabel.long(duration))"
            case .add: "Add \(DurationLabel.long(duration))"
            case .setLimit: "End in \(DurationLabel.long(duration))"
            }
        }
    }

    enum Item: Equatable, Sendable {
        /// A disabled line at the top: "Awake until 6:40 PM", "Starting…".
        case header(String)
        /// "Couldn't start: …", drawn as a warning.
        case failure(String)
        /// A disabled label over the templates: "Keep awake for".
        case label(String)
        case template(TimeInterval, title: String, mode: Mode)
        case noTimeLimit
        case customField(Mode)
        case removeTimeLimit
        case endSession
        case separator
    }

    static let startingTitle = "Starting\u{2026}"
    static let openEndedHeader = "Awake with no time limit"
    static let noTimeLimitTitle = "No time limit"
    static let removeTimeLimitTitle = "Remove time limit"
    static let endSessionTitle = "End session"
    static let customHint = "Try 45m, 2h or 1d"
    static let customPlaceholder = "Custom: 45m, 2h, 1d"

    static func items(
        state: State,
        templates: [TimeInterval],
        now: Date,
        maxDuration: TimeInterval,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [Item] {
        switch state {
        case .starting:
            return [.header(startingTitle)]
        case .idle:
            return idleItems(templates)
        case let .failed(reason):
            return [.failure(failureLine(reason)), .separator] + idleItems(templates)
        case let .running(endsAt):
            var out: [Item] = [.header(header(endsAt: endsAt, now: now, calendar: calendar, locale: locale)), .separator, .label("Add time")]
            let ceiling = now.addingTimeInterval(maxDuration)
            for t in templates {
                let capped = endsAt.addingTimeInterval(t) > ceiling
                let title = capped ? "\(DurationLabel.long(t)) (capped at \(DurationLabel.long(maxDuration)))" : DurationLabel.long(t)
                out.append(.template(t, title: title, mode: .add))
            }
            out += [.customField(.add), .removeTimeLimit, .endSession]
            return out
        case .openEnded:
            var out: [Item] = [.header(openEndedHeader), .separator, .label("Set a time limit")]
            out += templates.map { .template($0, title: DurationLabel.long($0), mode: .setLimit) }
            out += [.customField(.setLimit), .endSession]
            return out
        }
    }

    private static func idleItems(_ templates: [TimeInterval]) -> [Item] {
        [.label("Keep awake for")]
            + templates.map { .template($0, title: DurationLabel.long($0), mode: .start) }
            + [.noTimeLimit, .customField(.start)]
    }

    static func failureLine(_ reason: String) -> String {
        "Couldn\u{2019}t start: \(reason)"
    }

    /// "Awake until 6:40 PM" today, "Awake until Sat 6:40 PM" within the
    /// week, "Awake until Oct 30, 6:40 PM" after that.
    static func header(endsAt: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = calendar.timeZone
        let clock = endsAt.formatted(time)
        if calendar.isDate(endsAt, inSameDayAs: now) {
            return "Awake until \(clock)"
        }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: endsAt)).day ?? 0
        if days < 7 {
            var weekday = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated)
            weekday.timeZone = calendar.timeZone
            return "Awake until \(endsAt.formatted(weekday)) \(clock)"
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        return "Awake until \(endsAt.formatted(day)), \(clock)"
    }

    /// What the custom field's second line says for `text`: the action for
    /// a valid time, the hint for text it can't read, nothing when empty.
    enum FieldStatus: Equatable, Sendable {
        case empty
        case valid(TimeInterval, action: String)
        case invalid
    }

    static func fieldStatus(_ text: String, mode: Mode) -> FieldStatus {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        guard let d = DurationParser.parse(text) else { return .invalid }
        return .valid(d, action: mode.actionTitle(d))
    }

    /// What "Save as template" says, or nil when there is nothing to save.
    static func saveTitle(_ duration: TimeInterval, templates: [TimeInterval]) -> String? {
        switch TemplateList.adding(duration, to: templates) {
        case .added: "Save \u{201C}\(DurationLabel.long(duration))\u{201D} as a template"
        case .duplicate, .outOfRange: nil
        case .full: "Templates full. Remove one in Settings"
        }
    }
}
