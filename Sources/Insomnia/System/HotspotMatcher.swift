import Foundation

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
        var id: String { ssid }
        var isSecured: Bool { security != HotspotSecurity.open }
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
