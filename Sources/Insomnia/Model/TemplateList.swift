import Foundation

/// The saved durations shown in the menu ("templates"). Pure list rules:
/// at most `capacity`, shortest first, no duplicates.
enum TemplateList {
    static let capacity = 8

    /// What a fresh install offers.
    static let freshDefaults: [TimeInterval] = [
        30 * 60,
        1 * 3600,
        2 * 3600,
        4 * 3600,
        8 * 3600,
        24 * 3600,
    ]

    enum AddResult: Equatable {
        case added([TimeInterval])
        case duplicate
        case full
        case outOfRange
    }

    /// Sorted, de-duplicated, in range, and the `capacity` shortest kept.
    static func normalized(_ list: [TimeInterval]) -> [TimeInterval] {
        let valid = list.filter { $0 >= DurationParser.minimum && $0 <= DurationParser.maximum }
        return Array(Set(valid).sorted().prefix(capacity))
    }

    /// The entries `normalized` drops for being over capacity, for the log.
    static func overflow(_ list: [TimeInterval]) -> [TimeInterval] {
        let valid = Set(list.filter { $0 >= DurationParser.minimum && $0 <= DurationParser.maximum }).sorted()
        return Array(valid.dropFirst(capacity))
    }

    static func adding(_ duration: TimeInterval, to list: [TimeInterval]) -> AddResult {
        guard duration >= DurationParser.minimum, duration <= DurationParser.maximum else { return .outOfRange }
        let current = normalized(list)
        if current.contains(duration) { return .duplicate }
        if current.count >= capacity { return .full }
        return .added(normalized(current + [duration]))
    }

    static func removing(_ duration: TimeInterval, from list: [TimeInterval]) -> [TimeInterval] {
        normalized(list).filter { $0 != duration }
    }
}
