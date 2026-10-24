import Foundation
import SystemConfiguration

/// One network from a Wi-Fi scan, reduced to what matching needs.
struct ScannedNetwork: Equatable, Sendable {
    var ssid: String
    var bssid: String?
    /// A stable name for the security mode (`HotspotSecurity`).
    var security: String
    var rssi: Int
}

/// The saved hotspot, as config.json keeps it.
struct SavedHotspot: Equatable, Sendable {
    var ssid: String
    var bssids: [String]
    /// nil for a hotspot saved by an earlier build, which typed the name only.
    var security: String?
}

/// Picks the network failover joins, and keeps the saved hardware
/// addresses current (redesign spec, section 3). Pure.
enum HotspotMatcher {
    static let maxBSSIDs = 4

    /// 1. A scan result whose BSSID is saved and whose security matches.
    /// 2. Otherwise the strongest one with the saved name and security.
    /// 3. Otherwise nil.
    static func pick(saved: SavedHotspot, scan: [ScannedNetwork]) -> ScannedNetwork? {
        guard !saved.ssid.isEmpty else { return nil }
        let securityOK: (ScannedNetwork) -> Bool = { n in saved.security.map { $0 == n.security } ?? true }
        let saved = SavedHotspot(ssid: saved.ssid, bssids: saved.bssids.map { $0.lowercased() }, security: saved.security)
        let byAddress = scan.filter { n in
            guard let b = n.bssid?.lowercased() else { return false }
            return saved.bssids.contains(b) && securityOK(n)
        }
        if let best = byAddress.max(by: { $0.rssi < $1.rssi }) { return best }
        return scan.filter { $0.ssid == saved.ssid && securityOK($0) }.max(by: { $0.rssi < $1.rssi })
    }

    /// `bssid` added at the front, without duplicates, at most `maxBSSIDs`.
    static func recording(_ bssid: String?, into list: [String]) -> [String] {
        guard let b = bssid?.lowercased(), !b.isEmpty else { return list }
        return Array(([b] + list.map { $0.lowercased() }.filter { $0 != b }).prefix(maxBSSIDs))
    }

    /// One row per network name for the setup sheet: strongest signal, every
    /// BSSID seen, nameless networks dropped, strongest first.
    struct Row: Equatable, Sendable, Identifiable {
        var ssid: String
        var bssids: [String]
        var security: String
        var rssi: Int
        /// False for a network macOS has saved that isn't in the scan: an
        /// iPhone hotspot usually, which only broadcasts while its Personal
        /// Hotspot screen is open.
        var inRange = true
        var id: String { ssid }
        var isSecured: Bool { security != HotspotSecurity.open }
    }

    /// The scan's rows, then the networks macOS has saved that aren't in
    /// range, by name. Pure.
    static func addingSaved(_ rows: [Row], saved: [(ssid: String, security: String)]) -> [Row] {
        let seen = Set(rows.map(\.ssid))
        var extra: [String: Row] = [:]
        for s in saved where !s.ssid.isEmpty && !seen.contains(s.ssid) {
            extra[s.ssid] = Row(ssid: s.ssid, bssids: [], security: s.security, rssi: Int.min, inRange: false)
        }
        return rows + extra.values.sorted { $0.ssid.localizedCaseInsensitiveCompare($1.ssid) == .orderedAscending }
    }

    static func rows(_ scan: [ScannedNetwork]) -> [Row] {
        var rows: [String: Row] = [:]
        for n in scan where !n.ssid.isEmpty {
            if var r = rows[n.ssid] {
                if let b = n.bssid { r.bssids = recording(b, into: r.bssids) }
                if n.rssi > r.rssi {
                    r.rssi = n.rssi
                    r.security = n.security
                }
                rows[n.ssid] = r
            } else {
                rows[n.ssid] = Row(ssid: n.ssid, bssids: n.bssid.map { [$0.lowercased()] } ?? [], security: n.security, rssi: n.rssi)
            }
        }
        return rows.values.sorted { $0.rssi != $1.rssi ? $0.rssi > $1.rssi : $0.ssid < $1.ssid }
    }

    /// Signal bars, 0 to 3, from RSSI in dBm.
    static func bars(rssi: Int) -> Int {
        switch rssi {
        case (-60)...: return 3
        case (-70)..<(-60): return 2
        case (-80)..<(-70): return 1
        default: return 0
        }
    }
}

/// Stable names for CoreWLAN security modes, as saved in config.json.
enum HotspotSecurity {
    static let open = "open"
    static let wpaPersonal = "wpa-personal"
    static let wpa3Personal = "wpa3-personal"
    static let enterprise = "enterprise"
    static let other = "other"

    /// A WPA passphrase is 8 to 63 characters.
    static func passwordProblem(_ password: String, security: String) -> String? {
        guard security != open else { return nil }
        if password.count < 8 { return "The password is too short. Wi-Fi passwords are at least 8 characters." }
        if password.count > 63 { return "The password is too long. Wi-Fi passwords are at most 63 characters." }
        return nil
    }
}

/// macOS's own "Ask to join hotspots" setting (System Settings > Wi-Fi).
/// Only Automatically lets macOS wake and join an iPhone hotspot that isn't
/// broadcasting, which Insomnia's own join can't do.
enum HotspotAutoJoin: Equatable, Sendable {
    case automatic
    /// "Ask" or "Never", or no value (macOS's default): not automatic.
    case off(String?)
    /// macOS didn't let Insomnia read it. A normally launched app is refused
    /// this file unless it has Full Disk Access.
    case unknown

    static let preferencesFile = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist")
    static let key = "AutoHotspotMode"

    /// From the value macOS writes: "Automatic", "Ask", "Never". Pure.
    static func parse(_ value: String?) -> HotspotAutoJoin {
        value == "Automatic" ? .automatic : .off(value)
    }

    /// Reads the setting through SystemConfiguration, which owns the file,
    /// then from the file itself; `unknown` when macOS refuses both.
    static func read(from file: URL = preferencesFile) -> HotspotAutoJoin {
        if file == preferencesFile,
           let prefs = SCPreferencesCreate(nil, "Insomnia" as CFString, "com.apple.airport.preferences.plist" as CFString),
           let value = SCPreferencesGetValue(prefs, key as CFString) as? String {
            return parse(value)
        }
        do {
            let data = try Data(contentsOf: file)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            return parse(plist?[key] as? String)
        } catch {
            return .unknown
        }
    }

    /// Whether Settings shows the requirement: always when the setting is
    /// known to be off, and when it can't be read until the user says it's
    /// done. Pure.
    static func showsRequirement(_ mode: HotspotAutoJoin, confirmed: Bool) -> Bool {
        switch mode {
        case .automatic: false
        case .off: true
        case .unknown: !confirmed
        }
    }

    /// Opens System Settings at Wi-Fi.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!
}

/// "Wi-Fi is connected but has no internet": the captive-portal check failed
/// `threshold` times in a row (redesign spec, section 3). Pure.
struct InternetCheckCounter: Equatable, Sendable {
    static let threshold = 3
    static let spacing: TimeInterval = 10
    private(set) var failures = 0

    /// Records one check; returns true when failover should start now.
    mutating func record(passed: Bool) -> Bool {
        if passed {
            failures = 0
            return false
        }
        failures += 1
        return failures == Self.threshold
    }

    mutating func reset() { failures = 0 }

    /// What Apple's captive-portal page returns when the internet works.
    static func passes(body: String) -> Bool {
        body.contains("Success")
    }
}
