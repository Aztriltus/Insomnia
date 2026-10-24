import XCTest
@testable import Insomnia

/// The redesign's pure rules (docs/redesign-spec.md): countdown text, typed
/// durations, templates, the rolling deadline, installed apps, hotspot
/// matching and the internet check.
final class CountdownFormatTests: XCTestCase {
    func testSpecTable() {
        let rows: [(TimeInterval, String)] = [
            (3 * 86400 + 4 * 3600 + 20 * 60, "3d 4h"),
            (3 * 86400 + 20 * 60, "3d"),
            (5 * 3600 + 12 * 60, "5h 12m"),
            (5 * 3600, "5h"),
            (42 * 60 + 10, "43m"),
            (20, "1m"),
        ]
        for (remaining, text) in rows {
            XCTAssertEqual(CountdownFormat.text(remaining: remaining), text, "\(remaining)s")
        }
    }

    func testEdges() {
        XCTAssertEqual(CountdownFormat.text(remaining: 59), "1m")
        XCTAssertEqual(CountdownFormat.text(remaining: 60), "1m")
        XCTAssertEqual(CountdownFormat.text(remaining: 61), "2m")
        XCTAssertEqual(CountdownFormat.text(remaining: 23 * 3600 + 59 * 60 + 30), "1d")
        XCTAssertEqual(CountdownFormat.text(remaining: 86400), "1d")
        XCTAssertEqual(CountdownFormat.text(remaining: 0), "0m")
        XCTAssertEqual(CountdownFormat.text(remaining: -5), "0m")
    }

    func testLevels() {
        XCTAssertEqual(CountdownFormat.level(remaining: 59 * 60), .minutes)
        XCTAssertEqual(CountdownFormat.level(remaining: 59 * 60 + 1), .hours)
        XCTAssertEqual(CountdownFormat.level(remaining: 86400), .days)
        XCTAssertEqual(CountdownFormat.level(remaining: 86400 - 60), .hours)
    }

    func testSpoken() {
        XCTAssertEqual(CountdownFormat.spoken(remaining: 5 * 3600 + 12 * 60), "5 hours 12 minutes")
        XCTAssertEqual(CountdownFormat.spoken(remaining: 86400 + 3600), "1 day 1 hour")
        XCTAssertEqual(CountdownFormat.spoken(remaining: 30), "1 minute")
    }

    /// The text changes once a minute, at the deadline's own minute marks.
    func testNextChangeIsAlignedToTheDeadline() {
        let end = Date(timeIntervalSinceReferenceDate: 10_000)
        let now = end.addingTimeInterval(-(5 * 60 + 17))
        let next = SessionMath.nextCountdownChange(endsAt: end, now: now)
        XCTAssertEqual(next, end.addingTimeInterval(-5 * 60))
        XCTAssertEqual(CountdownFormat.text(remaining: end.timeIntervalSince(now)), "6m")
        XCTAssertEqual(CountdownFormat.text(remaining: end.timeIntervalSince(next)), "5m")
        // Exactly on a mark: the next change is a full minute away.
        let onMark = end.addingTimeInterval(-120)
        XCTAssertEqual(SessionMath.nextCountdownChange(endsAt: end, now: onMark), end.addingTimeInterval(-60))
    }
}

final class DurationParserTests: XCTestCase {
    func testAccepted() {
        let rows: [(String, TimeInterval)] = [
            ("45", 45 * 60),
            ("45m", 45 * 60),
            ("45 min", 45 * 60),
            ("45 minutes", 45 * 60),
            ("2h", 2 * 3600),
            ("2 hr", 2 * 3600),
            ("2 hours", 2 * 3600),
            ("1.5h", 90 * 60),
            ("1h30m", 90 * 60),
            ("1h 30m", 90 * 60),
            ("1:30", 90 * 60),
            ("3d", 3 * 86400),
            ("3 days", 3 * 86400),
            ("2d4h", 2 * 86400 + 4 * 3600),
            ("  2H  ", 2 * 3600),
            ("30d", 30 * 86400),
            ("1", 60),
            ("1.5", 90),
        ]
        for (text, seconds) in rows {
            XCTAssertEqual(DurationParser.parse(text), seconds, text)
        }
    }

    func testRejected() {
        for text in ["", "   ", "0", "-5", "31d", "abc", "2x", "1m2h", "1h1h", "1:3", "1:75", "h", "0.5m"] {
            XCTAssertNil(DurationParser.parse(text), text)
        }
    }

    func testLabels() {
        XCTAssertEqual(DurationLabel.long(30 * 60), "30 minutes")
        XCTAssertEqual(DurationLabel.long(3600), "1 hour")
        XCTAssertEqual(DurationLabel.long(90 * 60), "1 hour 30 minutes")
        XCTAssertEqual(DurationLabel.long(2 * 86400), "2 days")
        XCTAssertEqual(DurationLabel.long(86400 + 4 * 3600), "1 day 4 hours")
        XCTAssertEqual(DurationLabel.short(90 * 60), "1h 30m")
        XCTAssertEqual(DurationLabel.short(86400 + 4 * 3600), "1d 4h")
        XCTAssertEqual(DurationLabel.short(30 * 60), "30m")
    }
}

final class TemplateListTests: XCTestCase {
    func testNormalizedSortsDedupesAndCaps() {
        let list: [TimeInterval] = [3600, 60, 3600, 7200, 30, 999 * 86400]
        XCTAssertEqual(TemplateList.normalized(list), [60, 3600, 7200])
        let ten = (1...10).map { TimeInterval($0) * 3600 }
        XCTAssertEqual(TemplateList.normalized(ten), Array(ten.prefix(7)))
        XCTAssertEqual(TemplateList.overflow(ten), [8 * 3600, 9 * 3600, 10 * 3600])
    }

    func testAdding() {
        XCTAssertEqual(TemplateList.adding(45 * 60, to: [3600, 1800]), .added([1800, 45 * 60, 3600]))
        XCTAssertEqual(TemplateList.adding(3600, to: [3600]), .duplicate)
        XCTAssertEqual(TemplateList.adding(30, to: []), .outOfRange)
        let full = (1...7).map { TimeInterval($0) * 3600 }
        XCTAssertEqual(TemplateList.adding(30 * 60, to: full), .full)
    }

    func testRemovingTheLastLeavesAnEmptyList() {
        XCTAssertEqual(TemplateList.removing(3600, from: [3600]), [])
    }
}

final class OpenEndedLeaseTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testNewSessionIsAnHourAheadAndOpenEnded() {
        let s = OpenEndedLease.newSession(now: now)
        XCTAssertTrue(s.openEnded)
        XCTAssertEqual(s.endsAt, now.addingTimeInterval(3600))
    }

    func testRenewalMovesTheDeadlineAndNeverBack() {
        let s = OpenEndedLease.newSession(now: now)
        let later = now.addingTimeInterval(15 * 60)
        XCTAssertEqual(OpenEndedLease.renewed(s, now: later).endsAt, later.addingTimeInterval(3600))
        var far = s
        far.endsAt = now.addingTimeInterval(5 * 3600)
        XCTAssertEqual(OpenEndedLease.renewed(far, now: now).endsAt, far.endsAt)
    }

    func testRenewalsFitFourTimesInOneDeadline() {
        XCTAssertEqual(OpenEndedLease.lease / OpenEndedLease.renewEvery, 4)
    }

    func testSettingALimitCountsFromNowAndCaps() {
        let s = OpenEndedLease.newSession(now: now)
        let later = now.addingTimeInterval(7200)
        let limited = OpenEndedLease.settingLimit(s, duration: 45 * 60, now: later, maxDuration: 30 * 86400)
        XCTAssertFalse(limited.openEnded)
        XCTAssertEqual(limited.endsAt, later.addingTimeInterval(45 * 60))
        let capped = OpenEndedLease.settingLimit(s, duration: 99 * 86400, now: later, maxDuration: 30 * 86400)
        XCTAssertEqual(capped.endsAt, later.addingTimeInterval(30 * 86400))
    }

    func testRemovingTheLimit() {
        let timed = Session(startedAt: now, endsAt: now.addingTimeInterval(10 * 86400))
        let open = OpenEndedLease.removingLimit(timed, now: now)
        XCTAssertTrue(open.openEnded)
        XCTAssertEqual(open.endsAt, now.addingTimeInterval(3600))
    }

    /// A timed session.json reads and writes exactly as earlier builds did;
    /// only an open-ended one carries the key.
    func testSessionJSONCompatibility() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let timed = Session(startedAt: now, endsAt: now.addingTimeInterval(60))
        let timedJSON = String(decoding: try enc.encode(timed), as: UTF8.self)
        XCTAssertFalse(timedJSON.contains("openEnded"))
        XCTAssertEqual(try dec.decode(Session.self, from: Data(timedJSON.utf8)), timed)
        let open = OpenEndedLease.newSession(now: now)
        let openJSON = try enc.encode(open)
        XCTAssertTrue(String(decoding: openJSON, as: UTF8.self).contains("\"openEnded\":true"))
        XCTAssertEqual(try dec.decode(Session.self, from: openJSON), open)
    }
}

final class InstalledAppsTests: XCTestCase {
    func record(_ id: String?, _ name: String, path: String? = nil, background: Bool = false, depth: Int = 1, system: Bool = true) -> InstalledApps.Record {
        InstalledApps.Record(bundleID: id, name: name, path: path ?? "/Applications/\(name).app", backgroundOnly: background, depth: depth, inSystemApplications: system)
    }

    func testFilter() {
        let apps = InstalledApps.filter([
            record("com.tinyspeck.slackmacgap", "Slack"),
            record("com.apple.Safari", "Safari"),
            record("com.example.sys", "Sys", path: "/System/Applications/Sys.app"),
            record("com.kgarg.insomnia", "Insomnia"),
            record(nil, "NoID"),
            record("com.example.helper", "Helper", background: true),
            record("com.example.deep", "Deep", depth: 3),
            record("com.setapp.tool", "Tool", depth: 2),
            record("io.tailscale.ipn.macsys", "Tailscale"),
            record("com.example.discord", "discord"),
        ], selfBundleID: "com.kgarg.insomnia")
        XCTAssertEqual(apps.map(\.name), ["discord", "Slack", "Tailscale", "Tool"])
    }

    func testDuplicatePrefersApplications() {
        let apps = InstalledApps.filter([
            record("com.example.app", "App", path: "/Users/me/Applications/App.app", system: false),
            record("com.example.app", "App", path: "/Applications/App.app", system: true),
            record("com.example.app", "App", path: "/Users/me/Applications/Other/App.app", depth: 2, system: false),
        ], selfBundleID: "self")
        XCTAssertEqual(apps.map(\.path), ["/Applications/App.app"])
    }

    func testListsAreExclusive() {
        var c = Config()
        c.freezeList = ["a"]
        c.agentList = ["b"]
        c.add("a", to: .fullSpeed)
        XCTAssertEqual(c.freezeList, [])
        XCTAssertEqual(c.agentList, ["b", "a"])
        c.add("b", to: .pause)
        XCTAssertEqual(c.freezeList, ["b"])
        XCTAssertEqual(c.agentList, ["a"])
        c.remove("b", from: .pause)
        XCTAssertEqual(c.freezeList, [])
    }
}

final class HotspotMatcherTests: XCTestCase {
    let wpa = HotspotSecurity.wpaPersonal

    func net(_ ssid: String, _ bssid: String?, _ rssi: Int, security: String = HotspotSecurity.wpaPersonal) -> ScannedNetwork {
        ScannedNetwork(ssid: ssid, bssid: bssid, security: security, rssi: rssi)
    }

    func testAddressMatchBeatsAStrongerNameMatch() {
        let saved = SavedHotspot(ssid: "Phone", bssids: ["aa:aa"], security: wpa)
        let pick = HotspotMatcher.pick(saved: saved, scan: [net("Phone", "bb:bb", -40), net("Phone", "AA:AA", -75)])
        XCTAssertEqual(pick?.bssid, "AA:AA")
    }

    func testSecurityMismatchIsRejected() {
        let saved = SavedHotspot(ssid: "Phone", bssids: ["aa:aa"], security: wpa)
        XCTAssertNil(HotspotMatcher.pick(saved: saved, scan: [net("Phone", "aa:aa", -40, security: HotspotSecurity.open)]))
    }

    func testNameMatchTakesTheStrongest() {
        let saved = SavedHotspot(ssid: "Phone", bssids: [], security: wpa)
        let pick = HotspotMatcher.pick(saved: saved, scan: [net("Phone", "1", -80), net("Phone", "2", -50), net("Other", "3", -30)])
        XCTAssertEqual(pick?.bssid, "2")
    }

    func testLegacyNameOnlyIgnoresSecurity() {
        let saved = SavedHotspot(ssid: "Phone", bssids: [], security: nil)
        XCTAssertNotNil(HotspotMatcher.pick(saved: saved, scan: [net("Phone", nil, -50, security: HotspotSecurity.open)]))
    }

    func testEmptyScanAndEmptyName() {
        XCTAssertNil(HotspotMatcher.pick(saved: SavedHotspot(ssid: "Phone", bssids: [], security: wpa), scan: []))
        XCTAssertNil(HotspotMatcher.pick(saved: SavedHotspot(ssid: "", bssids: [], security: wpa), scan: [net("", "1", -40)]))
    }

    func testRecordingKeepsFourNewestFirst() {
        XCTAssertEqual(HotspotMatcher.recording("E", into: ["a", "b", "c", "d"]), ["e", "a", "b", "c"])
        XCTAssertEqual(HotspotMatcher.recording("b", into: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(HotspotMatcher.recording(nil, into: ["a"]), ["a"])
    }

    func testRowsGroupByName() {
        let rows = HotspotMatcher.rows([net("A", "1", -70), net("A", "2", -50), net("", "3", -20), net("B", "4", -60)])
        XCTAssertEqual(rows.map(\.ssid), ["A", "B"])
        XCTAssertEqual(rows[0].rssi, -50)
        XCTAssertEqual(Set(rows[0].bssids), ["1", "2"])
    }

    func testPasswordLength() {
        XCTAssertNotNil(HotspotSecurity.passwordProblem(String(repeating: "x", count: 7), security: wpa))
        XCTAssertNil(HotspotSecurity.passwordProblem(String(repeating: "x", count: 8), security: wpa))
        XCTAssertNil(HotspotSecurity.passwordProblem(String(repeating: "x", count: 63), security: wpa))
        XCTAssertNotNil(HotspotSecurity.passwordProblem(String(repeating: "x", count: 64), security: wpa))
        XCTAssertNil(HotspotSecurity.passwordProblem("", security: HotspotSecurity.open))
    }

    func testInternetCheckCounter() {
        var c = InternetCheckCounter()
        XCTAssertFalse(c.record(passed: false))
        XCTAssertFalse(c.record(passed: false))
        XCTAssertTrue(c.record(passed: false))
        XCTAssertFalse(c.record(passed: false), "starts failover once, not on every later failure")
        XCTAssertFalse(c.record(passed: true))
        XCTAssertFalse(c.record(passed: false))
        XCTAssertFalse(c.record(passed: false))
        XCTAssertTrue(c.record(passed: false))
        XCTAssertTrue(InternetCheckCounter.passes(body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"))
        XCTAssertFalse(InternetCheckCounter.passes(body: "<html>Log in to the hotel Wi-Fi</html>"))
    }
}

final class ConfigMigrationTests: XCTestCase {
    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testFreshConfigHasTheGridDefaults() throws {
        XCTAssertEqual(try decode("{}").durations, [600, 1800, 3600, 7200, 14400, 28800, 43200])
    }

    /// The grid starts from its own defaults: earlier builds' presets and
    /// templates are not carried over.
    func testEarlierDurationKeysAreNotCarriedOver() throws {
        XCTAssertEqual(try decode("{\"presets\": [2592000], \"templates\": [2592000]}").durations, TemplateList.freshDefaults)
    }

    func testSavedDurationsAreNormalized() throws {
        XCTAssertEqual(try decode("{\"durations\": [3600, 60, 3600]}").durations, [60, 3600])
    }

    func testAnAppOnBothListsStaysAtFullSpeed() throws {
        let c = try decode("{\"freezeList\": [\"a\", \"b\"], \"agentList\": [\"b\"]}")
        XCTAssertEqual(c.freezeList, ["a"])
        XCTAssertEqual(c.agentList, ["b"])
    }

    func testHotspotFieldsRoundTrip() throws {
        var c = Config()
        c.hotspotSSID = "Phone"
        c.hotspotBSSIDs = ["aa:bb"]
        c.hotspotSecurity = HotspotSecurity.wpaPersonal
        c.hotspotLastJoin = HotspotJoinRecord(result: .rejected, at: Date(timeIntervalSinceReferenceDate: 0))
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        let legacy = try decode("{\"hotspotSSID\": \"Phone\"}")
        XCTAssertEqual(legacy.savedHotspot, SavedHotspot(ssid: "Phone", bssids: [], security: nil))
    }

    func testUnknownLegacyKeysAreIgnored() throws {
        XCTAssertNoThrow(try decode("{\"defaultPreset\": 14400, \"defaultFocusField\": 9}"))
    }
}

final class HotspotSetupTests: XCTestCase {
    func testAutoJoinIsOnOnlyForAutomatic() {
        XCTAssertEqual(HotspotAutoJoin.parse("Automatic"), .automatic)
        XCTAssertEqual(HotspotAutoJoin.parse("Ask"), .off("Ask"))
        XCTAssertEqual(HotspotAutoJoin.parse("Never"), .off("Never"))
        XCTAssertEqual(HotspotAutoJoin.parse(nil), .off(nil), "no value is macOS's default, which asks")
    }

    func testAutoJoinIsReadFromTheAirportPreferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("com.apple.airport.preferences.plist")
        for (value, expected) in [("Automatic", HotspotAutoJoin.automatic), ("Never", .off("Never"))] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["AutoHotspotMode": value, "Version": 7200], format: .binary, options: 0)
            try data.write(to: file)
            XCTAssertEqual(HotspotAutoJoin.read(from: file), expected)
        }
        try PropertyListSerialization.data(fromPropertyList: ["Version": 7200], format: .xml, options: 0).write(to: file)
        XCTAssertEqual(HotspotAutoJoin.read(from: file), .off(nil))
        XCTAssertEqual(HotspotAutoJoin.read(from: dir.appendingPathComponent("missing.plist")), .off(nil))
    }

    func testTheTipSaysWhyForEachValue() {
        XCTAssertTrue(SettingsView.autoJoinTip("Never").contains("set to Never"))
        XCTAssertTrue(SettingsView.autoJoinTip("Ask").contains("needs someone at the Mac"))
        XCTAssertTrue(SettingsView.autoJoinTip(nil).contains("needs someone at the Mac"))
        for mode in ["Never", "Ask"] {
            XCTAssertTrue(SettingsView.autoJoinTip(mode).hasPrefix("Set Ask to join hotspots to Automatically."))
        }
    }

    func testSavedNetworksOutOfRangeFollowTheScan() {
        let scan = HotspotMatcher.rows([ScannedNetwork(ssid: "Home", bssid: "1", security: HotspotSecurity.wpaPersonal, rssi: -50)])
        let rows = HotspotMatcher.addingSaved(scan, saved: [
            ("Home", HotspotSecurity.wpaPersonal),
            ("zara's iPhone", HotspotSecurity.wpaPersonal),
            ("Cafe", HotspotSecurity.open),
            ("", HotspotSecurity.open),
        ])
        XCTAssertEqual(rows.map(\.ssid), ["Home", "Cafe", "zara's iPhone"])
        XCTAssertEqual(rows.map(\.inRange), [true, false, false])
        XCTAssertEqual(rows[2].bssids, [])
    }

    /// A saved profile and a scan must name the same security, or a hotspot
    /// saved out of range would never match when it appears.
    func testSavedProfileSecurityNamesMatchTheScansNames() {
        XCTAssertEqual(WiFiScanner.security(of: .wpa2Personal), HotspotSecurity.wpaPersonal)
        XCTAssertEqual(WiFiScanner.security(of: .wpa3Transition), HotspotSecurity.wpaPersonal, "a transition network also supports WPA2, which the scan names first")
        XCTAssertEqual(WiFiScanner.security(of: .personal), HotspotSecurity.wpaPersonal)
        XCTAssertEqual(WiFiScanner.security(of: .wpa3Personal), HotspotSecurity.wpa3Personal)
        XCTAssertEqual(WiFiScanner.security(of: .none), HotspotSecurity.open)
        XCTAssertEqual(WiFiScanner.security(of: .wpa2Enterprise), HotspotSecurity.enterprise)
    }
}
