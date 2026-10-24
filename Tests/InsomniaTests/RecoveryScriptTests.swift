import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// One backslash, for the JSON escapes in the texts below, which then read
/// as they are in the file: "\#(backslash)u0041" is a \u escape in it.
private let backslash = "\\"

/// Behavioural tests for scripts/backstop.sh and scripts/uninstall.sh.
///
/// Each test runs a private COPY of the production script against a
/// throwaway INSOMNIA_HOME. The copy has its fixed tool-path constants
/// (sudo, pmset, ps, kill, sysctl, pgrep, pkill, osascript, launchctl,
/// defaults) and its app-bundle / sudoers paths rewritten to point inside
/// the fixture, so nothing privileged runs, no real process is signaled, no
/// real app's preferences are read or written, and no real home,
/// LaunchAgent, sudoers file, or installed app is read or written. plutil
/// and lockf are the real tools, and so is date, except for the backstop's
/// moved-aside stamp, which a test can freeze. The fakes record every call.
final class RecoveryScriptTests: XCTestCase {
    private var fx: ScriptFixture!

    override func setUpWithError() throws {
        fx = try ScriptFixture()
    }

    override func tearDown() {
        fx.destroy()
        fx = nil
    }

    // MARK: - backstop.sh

    func testPrivilegedCommandFailureExitsNonzeroAndKeepsJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false,"extra":"keep"}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "sudo -n \(fx.fakePmset) -b lowpowermode 0",
        ])
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true, "a failed pmset must stay journaled")
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertEqual(s["extra"] as? String, "keep")
        XCTAssertTrue(fx.exists(fx.session), "expired session is evidence while the journal is dirty")
        let log = fx.log()
        XCTAssertTrue(log.contains("journal kept dirty"), log)
        XCTAssertFalse(log.contains("journal cleared"), log)
    }

    func testCleanIdleRunsNoCommandsAndTouchesNothing() throws {
        let clean = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"someFutureKey":[1,2]}"#
        try fx.writeState(clean)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [], "an idle run must not touch pmset, sudo, or any process")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), clean, "journal must not be rewritten")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.logFile), "an idle minute must not spam the log")
    }

    private static let compactCleanJournal = #"{"appNapOverrides":[],"dockerFrozen":false,"frozenProcesses":[],"lowPowerSetByUs":false,"savedAudioOutputs":[],"sleepDisabledByUs":false}"#

    func testValidFutureSessionIsNoOpWithoutForce() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))
    }

    func testForceEndsValidSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop, ["--force"])

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
    }

    func testExpiredSessionRestoresEverythingAndClearsJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":true,"lowPowerSetByUs":true,"dockerFrozen":true,"keepMe":{"x":1},
         "frozenProcesses":[{"pid":4242,"startedAt":\(started),"startedAtMicros":17,"bootSession":"\(fx.bootUUID)"}]}
        """)
        try fx.psTable([(4242, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "sudo -n \(fx.fakePmset) -b lowpowermode 0",
            "Insomnia --resume-frozen 2 < 4242 \(started) 17 \(fx.bootUUID)",
        ], "an entry with microseconds is resumed by the app binary, never by ps and kill")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(s["dockerFrozen"] as? Bool, false)
        XCTAssertEqual((s["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertEqual((s["keepMe"] as? [String: Any])?["x"] as? Int, 1, "unknown keys survive the rewrite")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    func testLegacyAndIdentitylessPidsAreNeverSignaledAndStayDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":false,"frozenPids":[333],"frozenProcesses":[{"pid":444}]}"#)
        // Both look stopped right now; that still proves nothing about ownership.
        try fx.psTable([(333, fx.lstart(1_700_000_000), "T", fx.uid), (444, fx.lstart(1_700_000_000), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "no ps lookup, no signal for unverifiable pids")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["frozenPids"] as? [Int], [333])
        XCTAssertEqual((s["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 444)
        XCTAssertTrue(fx.log().contains("333"), fx.log())
        XCTAssertTrue(fx.log().contains("444"), fx.log())
    }

    // MARK: App Nap

    func testMalformedJournalBlocksWithoutCommandsAndKeepsEvidence() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let broken = #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":"#
        try fx.writeState(broken)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "no privileged command without a readable journal")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), broken, "never seed a clean journal over evidence")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("malformed"), fx.log())
    }

    // MARK: - Unreadable session.json

    /// Names in APP_SUPPORT of the shape the app and backstop.sh give a
    /// moved-aside session.json.
    private func movedAsideSessions() throws -> [String] {
        try fx.contents(of: fx.home).filter { $0.hasPrefix("session.json.unreadable-") }.sorted()
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// A session.json that is not a session, with a clean journal: nothing
    /// to undo, the file is renamed to a timestamped sibling so the next run
    /// sees no session, and that next run is idle.
    func testMalformedSessionWithCleanJournalIsMovedAsideAndNextRunIsIdle() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [], "nothing journaled means nothing privileged")
        XCTAssertFalse(fx.exists(fx.session), "session.json left in place")
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        let name = try XCTUnwrap(moved.first)
        XCTAssertNotNil(name.range(of: #"^session\.json\.unreadable-[0-9]{8}T[0-9]{6}Z$"#, options: .regularExpression), name)
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(name), encoding: .utf8), "not json", "bytes kept as they were")
        XCTAssertTrue(fx.log().contains("[warn] backstop: session.json unreadable; moved to \(fx.home.appendingPathComponent(name).path)"), fx.log())

        let again = try fx.run(fx.backstop)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertEqual(try movedAsideSessions(), [name], "a second run moved something else")
    }

    /// Dates the app and both scripts must read alike. Each one is written
    /// into a session.json and read back the way each script reads it
    /// (plutil, then epoch_at and epoch_of cut from the script), and the
    /// second it gives must be the one the app's Session decoder gives, or
    /// both must refuse. Most refused ones are dates JSONDecoder's
    /// `.iso8601` took on macOS 26 while the scripts did not, so the app
    /// could keep a deadline that the backstop ended every minute. The
    /// whitespace ones check the read itself: command substitution would
    /// strip a stored trailing newline.
    func testScriptsAndAppReadTheSameSessionDates() throws {
        let cases = [
            "2027-01-15T08:00:00Z", "2027-01-15T10:00:00+02:00", "2027-01-15T02:30:00-05:30", "2027-01-15T08:00:00+00:00",
            "2027-01-15T08:00:00-00:00", "2027-01-16T07:59:00+23:59", "2028-02-29T08:00:00Z", "1970-01-01T00:30:00+01:00",
            "1970-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "9999-12-31T23:59:59-23:59",
            "1969-12-31T23:59:59Z", "1900-01-01T00:00:00Z", "2027-02-29T08:00:00Z", "2027-02-30T08:00:00Z", "2027-04-31T08:00:00Z",
            "2027-01-15T24:00:00Z", "2027-01-15T25:00:00Z", "2027-01-15T08:61:00Z", "2027-01-15T08:00:60Z", "2027-13-01T08:00:00Z",
            "2027-00-10T08:00:00Z", "2027-01-15T08:00:00+24:00", "2027-01-15T08:00:00+02:60", "2027-01-15T08:00:00+0200",
            "2027-01-15T08:00:00+02", "2027-01-15T08:00:00+2:00", "2027-01-15T08:00:00.5Z", "2027-01-15T08:00:00.123+02:00",
            "2027-01-15T08:00:00z", "2027-01-15t08:00:00Z", "2027-01-15T08:00:00GMT", "2027-01-15T08:00:00UTC",
            "2027-01-15T08:00:00Zjunk", "2027-01-15T08:00:00Z ", " 2027-01-15T08:00:00Z", "2027-01-15T08:00:00+02:00:00",
            "2027-1-5T8:0:0Z", "2027-01-15 08:00:00Z", "2027-01-15T08:00:00", "2027-01-15T08:00Z", "10000-01-01T00:00:00Z",
            "+2027-01-15T08:00:00Z", "\u{FF12}\u{FF10}\u{FF12}\u{FF17}-01-15T08:00:00Z", "2027-01-15T08:00:00\u{2212}02:00", "",
            "2027-01-15T08:00:00Z\n", "2027-01-15T08:00:00Z\n\n", "\n2027-01-15T08:00:00Z", "2027-01-15T08:00:00Z\r",
            "2027-01-15T08:00:00Z\t", "2027-01-15T08:00:00+02:00\n",
        ]
        let dir = fx.root.appendingPathComponent("dates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String] = []
        var app: [String] = []
        for (i, text) in cases.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["startedAt": "2027-01-15T08:00:00Z", "endsAt": text, "extensions": [Int]()])
            let file = dir.appendingPathComponent("\(i).json")
            try data.write(to: file)
            files.append(file.path)
            app.append((try? Store.makeDecoder().decode(Session.self, from: data)).map { String(Int($0.endsAt.timeIntervalSince1970)) } ?? "")
        }
        XCTAssertEqual(app.filter { !$0.isEmpty }.count, 11, "the app reads the first eleven: \(Array(zip(cases, app)))")
        for script in [fx.backstop, fx.uninstall] {
            let text = try String(contentsOf: script, encoding: .utf8)
            var functions = ""
            for name in ["extract", "epoch_of", "epoch_at"] {
                let start = try XCTUnwrap(text.range(of: "\n\(name)() {"), "\(name) in \(script.lastPathComponent)")
                let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
                functions += text[start.lowerBound..<end.upperBound]
            }
            let harness = fx.root.appendingPathComponent("epoch_at.\(script.lastPathComponent)")
            try ("set -euo pipefail\nPLUTIL=/usr/bin/plutil\nDATE=/bin/date" + functions
                + #"for f in "$@"; do printf '[%s]\n' "$(epoch_at "$f" endsAt)"; done"# + "\n")
                .write(to: harness, atomically: true, encoding: .utf8)

            let r = try fx.run(harness, files)

            XCTAssertEqual(r.status, 0, r.stderr)
            let shell = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { String($0.dropFirst().dropLast()) }
            XCTAssertEqual(shell.count, cases.count, r.stdout)
            for (i, text) in cases.enumerated() where i < shell.count {
                XCTAssertEqual(shell[i], app[i], "\(script.lastPathComponent) and the app read \(text.debugDescription) differently")
            }
        }
    }

    func testLockContentionFailsClosed() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 75, "lockf EX_TEMPFAIL must propagate: \(r.stderr)")
        XCTAssertEqual(fx.calls(), [], "no unlocked fallback")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("lock"), fx.log())
        XCTAssertTrue(fx.exists(fx.lock), "lock file inode is retained")
    }

    func testSecondRunAfterSuccessIsIdle() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        XCTAssertEqual(try fx.run(fx.backstop).status, 0)
        fx.clearCalls()

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "the lock file must not make later runs think something is journaled")
    }

    // MARK: - uninstall.sh

    func testUninstallAbortsWhenRestoreFailsAndKeepsEverything() throws {
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist), "LaunchAgent must keep retrying")
        XCTAssertTrue(fx.exists(fx.sudoers), "the pmset grant is still needed")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.session), "evidence is not deleted up front")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo rm") }, "\(calls)")
        XCTAssertTrue(r.stderr.contains("BEFORE removing anything"), r.stderr)
        XCTAssertTrue(r.stderr.contains("sleepDisabledByUs is still true"), r.stderr)
        XCTAssertTrue(r.stderr.contains(fx.sudoers.path), r.stderr)
    }

    /// An expired session and one frozen entry with a microsecond identity,
    /// for the uninstall tests above.
    private func writeFrozenEntryForUninstall(_ f: ScriptFixture) throws {
        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try f.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[{"pid":5311,"startedAt":1789388423,"startedAtMicros":11,"bootSession":"\(f.bootUUID)"}]}
        """)
    }

    func testUninstallSuccessRemovesMachineryAndKeepsConfig() throws {
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("launchctl bootout gui/\(fx.uid) \(fx.plist.path)"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo rm -f \(fx.sudoers.path)"), "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.state))
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.config), "config.json survives without --purge")
        XCTAssertTrue(fx.exists(fx.logFile), "logs survive without --purge")
        XCTAssertTrue(fx.exists(fx.appsDir), "only the bundle goes, not its parent")
    }

    /// Beside the installed bundle: what install.sh can leave (the
    /// set-aside previous bundle, a dead and a live run's staging
    /// directory) and names it must not touch. In the LaunchAgents
    /// directory: candidate plists of install.sh, of the app and of older
    /// builds, plus another agent's plist and a stray file.
    private func writeInstallerLeftovers() throws -> (removable: [String], keptInApps: [String], linkTarget: URL) {
        let removable = [".Insomnia.app.previous", ".Insomnia.app.staging.4242.AAAAAA"]
        let live = ".Insomnia.app.staging.4343.BBBBBB"
        let unlike = [".Insomnia.app.staging.4242", ".Insomnia.app.staging.4242.AAAAAA.old", ".Insomnia.app.staging.x4242.AAAAAA",
                      ".Insomnia.app.previous.old", "Other.app", ".Other.app.previous"]
        let link = ".Insomnia.app.staging.4242.CCCCCC"
        for name in removable + [live] + unlike {
            try fx.writeBundle(at: fx.appsDir.appendingPathComponent(name).appendingPathComponent("Insomnia.app"), marker: "left")
        }
        let elsewhere = fx.root.appendingPathComponent("elsewhere", isDirectory: true)
        try fx.writeBundle(at: elsewhere.appendingPathComponent("Insomnia.app"), marker: "not the installer's")
        try FileManager.default.createSymbolicLink(at: fx.appsDir.appendingPathComponent(link), withDestinationURL: elsewhere)

        let launchAgents = fx.plist.deletingLastPathComponent()
        let staging = launchAgents.appendingPathComponent(".com.insomnia.backstop.staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for url in [staging.appendingPathComponent("com.insomnia.backstop.candidate-4242.plist"),
                    staging.appendingPathComponent("com.insomnia.backstop.candidate-0F2C9A54-1B7E-4D7A-9C11-5E3B2A7D9F00.plist"),
                    launchAgents.appendingPathComponent("com.insomnia.backstop.candidate-0F2C9A54-1B7E-4D7A-9C11-5E3B2A7D9F01"),
                    staging.appendingPathComponent("notes.txt"),
                    launchAgents.appendingPathComponent("com.other.agent.plist")] {
            try "<plist/>".write(to: url, atomically: true, encoding: .utf8)
        }
        return (removable, ([live, link] + unlike).sorted(), elsewhere)
    }

    // MARK: - Which backstop uninstall.sh runs

    // MARK: - Owner-only files

    // MARK: - Journal shape (typed corruption)

    /// Output device entries the app's decoder refuses too (StoreTests
    /// checks that side).
    static let corruptOutputJournals = [
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":"usb-headset"}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[null]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"volume":0.3,"muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":7,"volume":0.3,"muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":"loud","muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.3,"muted":1}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.3}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","name":3,"volume":0.3,"muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.3,"muted":false,"saveID":3}]}"#,
    ]

    // MARK: Kept display records

    /// A journal with a kept display entry and the app's records about it,
    /// sleep and Low Power Mode still ours: a run that took it for clean
    /// would call pmset twice and republish it.
    static func keptDisplayJournal(_ records: String, ours: Bool = true) -> String {
        #"{"sleepDisabledByUs":\#(ours),"lowPowerSetByUs":\#(ours),"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.8,"displayRestoreRefused":true"#
            + (records.isEmpty ? "" : "," + records) + "}"
    }

    /// Records the app's decoder refuses, each with the start of the line
    /// the log gives the problem: wrong types, numbers a Float cannot hold,
    /// and numbers plutil reads otherwise than the app. plutil turns
    /// 1e-400 into 0, reads 1., .5 and +1, which are not JSON numbers, and
    /// keeps the last of two copies of a key, where the app keeps the
    /// first. A key spelled with a \u escape is that key to both. plutil
    /// also reads keys written as JSON5 or with a \x escape, and comments;
    /// the app reads none of them.
    static let malformedKeptDisplayRecords: [(problem: String, json: String)] = [
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":"0.8""#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":true"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":[0.8]"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e39"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":-1e39"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e-50"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e-400"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":-1e-400"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1."#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e-400,"keptDisplayUnderLowPower":0.8"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":"0.8""#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":false"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":{"value":0.8}"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":3.5e38"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":5e-46"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":1e-400"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":-1e-400"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":.5"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":+1"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":1e-400,"keptDisplayReadLit":0.8"#),
        ("keptDisplayReadLit is ", #""kept\u0044isplayReadLit":1e-400"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPowe\#(backslash)u0072":"0.8""#),
        ("a key in state.json has an escape JSON does not have", #""kept\#(backslash)x44isplayReadLit":0.8"#),
        ("the top level of state.json cannot be followed here", #"keptDisplayReadLit:1e-400"#),
        ("the top level of state.json cannot be followed here", #"'keptDisplayReadLit':0.8"#),
        ("the top level of state.json cannot be followed here", #"/* note */"keptDisplayReadLit":0.8"#),
        ("keptDisplayUnderLowPowerBoot is ", #""keptDisplayUnderLowPowerBoot":7"#),
        ("keptDisplayUnderLowPowerBoot is ", #""keptDisplayUnderLowPowerBoot":true"#),
        ("keptDisplayUnderLowPowerBoot is ", #""keptDisplayUnderLowPowerBoot":["boot-a"]"#),
        ("displayRestoredUnderLowPower is ", #""displayRestoredUnderLowPower":"0.75""#),
        ("displayRestoredUnderLowPower is ", #""displayRestoredUnderLowPower":false"#),
    ]

    /// Forms the app's decoder reads: null and absent are none, a number
    /// may be written as an integer, 0 in any form is 0, the ends of a
    /// Float's range hold, and so does a Float as a script republishes it,
    /// with 17 significant digits.
    static let validKeptDisplayRecords = [
        "",
        #""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"8F2C1A3E-0B6D-4C11-9E3F-2A7B5C4D1E00","keptDisplayReadLit":0.8"#,
        #""keptDisplayUnderLowPower":1,"keptDisplayReadLit":0"#,
        #""keptDisplayUnderLowPower":null,"keptDisplayUnderLowPowerBoot":null,"keptDisplayReadLit":null,"displayRestoredUnderLowPower":null"#,
        #""keptDisplayUnderLowPowerBoot":"","displayRestoredUnderLowPower":0.75"#,
        #""keptDisplayUnderLowPower":1e-45,"keptDisplayReadLit":3.4028235e38"#,
        #""keptDisplayUnderLowPower":-3.4028235e38,"keptDisplayReadLit":-1e-45"#,
        #""keptDisplayUnderLowPower":-0,"keptDisplayReadLit":0e-400"#,
        #""keptDisplayUnderLowPower":0.0,"keptDisplayReadLit":0.80000001192092896"#,
        #""keptDisplayReadL\#(backslash)u0069t":0.8,"kept\#(backslash)u0044isplayUnderLowPower":0.8"#,
        #""keptDisplayReadLit":0.8,"note":{"keptDisplayReadLit":1e-400,"keptDisplayUnderLowPower":"0.8"},"list":[{"keptDisplayReadLit":0.7},"]}{["]"#,
        #""note":"\#(backslash)"keptDisplayReadLit\#(backslash)":1e-400 \#(backslash)\#(backslash)u0041 \#(backslash)\#(backslash)","keptDisplayReadLit" : 0.8"#,
    ]

    /// Journals the app reads, taking the first copy of a key, that both
    /// scripts refuse: plutil checks the last copy, and a republished
    /// journal would keep only that one.
    static let duplicatedKeptDisplayRecords: [(problem: String, json: String)] = [
        ("keptDisplayReadLit is in the top level of state.json 2 times; the app reads the first and plutil the last", #""keptDisplayReadLit":0.8,"keptDisplayReadLit":0.7"#),
        ("keptDisplayReadLit is in the top level of state.json 2 times", #""keptDisplayReadLit":0.8,"keptDisplayReadL\#(backslash)u0069t":0.7"#),
        ("keptDisplayUnderLowPower is in the top level of state.json 3 times", #""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPower":0.8"#),
        ("keptDisplayUnderLowPowerBoot is in the top level of state.json 2 times", #""keptDisplayUnderLowPowerBoot":"boot A","keptDisplayUnderLowPowerBoot":"boot B""#),
    ]

    static let keptDisplayRecordKeys = [
        "keptDisplayUnderLowPower", "keptDisplayUnderLowPowerBoot", "keptDisplayReadLit", "displayRestoredUnderLowPower",
    ]

    /// record_text_problems as it is in each script, run on its own over
    /// exact bytes: what it prints, or nothing.
    private func recordTextProblems(_ inputs: [(label: String, bytes: Data)], script: String = "backstop.sh") throws -> [String: String] {
        let f = try ScriptFixture()
        defer { f.destroy() }
        let runner = f.root.appendingPathComponent("record-text-problems.sh")
        try ("set -euo pipefail\n" + Self.recordTextProblemsSource(script) + "\nrecord_text_problems \"$1\"\n")
            .write(to: runner, atomically: true, encoding: .utf8)
        var printed: [String: String] = [:]
        for (i, input) in inputs.enumerated() {
            let file = f.root.appendingPathComponent("input.\(i)")
            try input.bytes.write(to: file)
            let r = try f.run(runner, [file.path])
            XCTAssertEqual(r.status, 0, "\(input.label): \(r.stderr)")
            XCTAssertEqual(r.stderr, "", input.label)
            printed[input.label] = r.stdout
        }
        return printed
    }

    private static func recordTextProblemsSource(_ script: String) throws -> String {
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(script), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "record_text_problems() { # file"), script)
        let end = try XCTUnwrap(lines[start...].firstIndex(of: "}"), script)
        return lines[start...end].joined(separator: "\n")
    }

    // MARK: - Process observation failures (entries without microseconds)

    // MARK: - Microsecond identity through the app binary

    private func writeMicrosecondEntry(pid: Int, started: Int, micros: Int, boot: String? = nil, extra: String = "") throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":\(pid),"startedAt":\(started),"startedAtMicros":\(micros),"bootSession":"\(boot ?? fx.bootUUID)"\(extra)}]}
        """)
    }

    private func onlyFrozenEntry() throws -> [String: Any]? {
        (try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first
    }

    /// Polls `condition` every 0.05 s; false if it does not hold within
    /// `seconds`.
    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    // MARK: - Uninstall locking and interleaving

    // MARK: - Final integration checks

    func testHungPowerCommandTimesOutReleasesLockAndKeepsJournalDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "hang")
        let started = Date()

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "two 1 s timeouts, not two hung commands")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true, "ownership is preserved on timeout")
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(try fx.lockIsFree(), "a timed-out child must not keep the recovery lock")
        let log = fx.log()
        XCTAssertTrue(log.contains("did not finish within 1s; terminated with SIGTERM"), log)
        XCTAssertTrue(log.contains("journal kept dirty"), log)
    }

    func testCommandThatIgnoresSigtermIsNeverKilledAndKeepsTheLock() throws {
        // A "terminated" signal is not a dead child. The fake ignores TERM and
        // lives until this test releases it; the script must return while it
        // is still alive, leave the lock held until the command really ends,
        // and must not SIGKILL it (that would orphan a root pmset outside the
        // transaction).
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "ignore-term")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertNil(fx.commandEnded(), "the script returned while the command was still alive (it has not been released)")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "ownership retained")
        XCTAssertFalse(try fx.lockIsFree(), "the command survived SIGTERM, so it was not killed and still holds the lock")
        let log = fx.log()
        XCTAssertTrue(log.contains("did not finish within 1s"), log)
        XCTAssertTrue(log.contains("keeps the recovery lock"), log)
        XCTAssertTrue(log.contains("recovery stopped"), "the transaction ends right there: \(log)")
        XCTAssertFalse(log.contains("SIGKILL"), log)
        fx.setMode("sudo", "ok")
        fx.clearCalls()
        let blocked = try fx.run(fx.backstop)
        XCTAssertEqual(blocked.status, 75, "no new transaction while the command lives: \(blocked.stderr)")
        XCTAssertEqual(fx.calls(), [], "no mutation outside the lock")
        XCTAssertNil(fx.commandEnded(), "still alive before the release")
        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree(), "the lock is released only when the command exits")
        XCTAssertEqual(fx.commandEnded(), "released", "the command ended because of the release, not the watchdog")
        let after = try fx.run(fx.backstop)
        XCTAssertEqual(after.status, 0, after.stderr + fx.log())
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    /// A copy of the fixture's backstop with COMMAND_TIMEOUT_SECONDS set to
    /// `seconds`.
    private func backstop(commandTimeout seconds: Int) throws -> URL {
        let url = fx.root.appendingPathComponent("backstop-\(seconds)s.sh")
        try ScriptFixture.patch(try String(contentsOf: fx.backstop, encoding: .utf8), ["COMMAND_TIMEOUT_SECONDS": String(seconds)])
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The lines in the bounded calls' .rc status files, in file name order.
    private func statusLines() -> [String] {
        let names = ((try? fx.backstopFiles()) ?? []).filter { $0.hasSuffix(".rc") }
        return names.compactMap { try? String(contentsOf: fx.home.appendingPathComponent($0), encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - install.sh (fully redirected: fake build, signing, sudo, launchctl)

    /// The indented line an install.sh message gives the user to paste.
    private func printedCommand(in output: String, containing marker: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("  ") && $0.contains(marker) }, output)
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// The words bash and zsh (the default login shell) read from a pasted
    /// command line; set -- only assigns them, nothing runs.
    private func pastedWords(of line: String) throws -> [String] {
        var read: [[String]] = []
        for shell in [["/bin/bash"], ["/bin/zsh", "-f"]] {
            let r = try fx.runTool(shell[0], Array(shell.dropFirst()) + ["-c", #"eval "set -- $1" && printf '%s\n' "$@""#, "sh", line])
            XCTAssertEqual(r.status, 0, "\(shell[0]): \(r.output)")
            read.append(r.output.split(separator: "\n").map(String.init))
        }
        XCTAssertEqual(read[0], read[1], "bash and zsh read the same words from \(line)")
        return read[0]
    }

    // MARK: - install.sh --app (a prebuilt bundle, as from a release zip)

    /// The private copy install.sh --app checks and installs, read from the
    /// first deep verify in the recorded calls. Never the path passed in.
    /// A prebuilt bundle in a directory whose name has a space, double quotes
    /// and a `$`, all of which a command printed for pasting has to keep.
    private func writePrebuiltAppAtAnAwkwardPath() throws -> URL {
        let dir = fx.root.appendingPathComponent(#"My "dl" $HOME"#, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appendingPathComponent("Insomnia.app", isDirectory: true)
        try FileManager.default.moveItem(at: try fx.writePrebuiltApp(), to: app)
        return app
    }

    private func checkedCopy(of prebuilt: URL) throws -> String {
        let prefix = "codesign --verify --strict --deep "
        let call = try XCTUnwrap(fx.calls().first { $0.hasPrefix(prefix) }, "\(fx.calls())")
        let path = String(call.dropFirst(prefix.count))
        XCTAssertNotEqual(path, prebuilt.path, "checked at the path passed in")
        XCTAssertTrue(path.hasSuffix("/Insomnia.app"), path)
        return path
    }

    /// Every path in `bundle`, itself included.
    private func bundlePaths(_ bundle: URL) throws -> [String] {
        let walk = try XCTUnwrap(FileManager.default.enumerator(atPath: bundle.path))
        var paths = [bundle.path]
        while let relative = walk.nextObject() as? String {
            paths.append(bundle.appendingPathComponent(relative).path)
        }
        return paths
    }

    /// The paths in `bundle` (symbolic links aside) that group or other may write.
    private func writableByOthers(_ bundle: URL) throws -> [String] {
        try bundlePaths(bundle).filter { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return mode & 0o022 != 0
        }
    }

    /// The ACL entries `ls -led` prints for the paths in `bundle`, such as
    /// " 0: group:everyone allow write,append".
    private func aclEntries(_ bundle: URL) throws -> [String] {
        try bundlePaths(bundle).flatMap { path in
            let ls = try fx.runTool("/bin/ls", ["-led", path])
            XCTAssertEqual(ls.status, 0, ls.output)
            return ls.output.split(separator: "\n").map(String.init).filter { $0.range(of: #"^ \d+: "#, options: .regularExpression) != nil }
        }
    }

    /// The state an install killed after the second rename of its swap
    /// leaves: its build at $APP (marker "interrupted"), the previous one set
    /// aside, and the plist on disk pinning only the previous one.
    @discardableResult
    private func writeInterruptedSwap() throws -> URL {
        try fx.prepareInstall()
        let previous = fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true)
        try fx.writeBundle(at: previous, marker: "previous")
        try fx.writeBundle(at: fx.app, marker: "interrupted")
        try fx.writeAgentPlist()
        try fx.rejectSignature(of: fx.app)
        return previous
    }

    // A rename of the swap or of its undo that fails. Each one is handled:
    // the previous app goes back to $APP and its job is loaded again, and
    // when the previous app cannot go back, no bundle is deleted and the
    // message says how to put it back. Before, set -e exited at the failed
    // rename with the previous job unloaded, and cleanup deleted the
    // staged build.

    /// The previous pair of an earlier install: its app at $APP, the
    /// trusted plist, a clean journal, and its job loaded.
    private func writePreviousPair() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
    }

    private var stagedBuildPattern: String { fx.appsDir.path + "/.Insomnia.app.staging.*/Insomnia.app" }
    private var setAside: URL { fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true) }

    /// The staging directories left in $APP_DIR.
    private func stagingDirs() throws -> [URL] {
        try fx.contents(of: fx.appsDir).filter { $0.hasPrefix(".Insomnia.app.staging.") }.map { fx.appsDir.appendingPathComponent($0) }
    }

    /// Starts `script`, waits for its `launchctl bootout` to hang, and kills
    /// the script with SIGKILL; returns the hung bootout's pid. The only
    /// process signaled is the script shell, posix_spawned and reaped only
    /// after the signal, so its pid cannot have been reused. Throws if the
    /// bootout never starts or the script ends before it can be killed.
    func killDuringHungBootout(_ script: URL, extraEnvironment: [String: String] = [:]) throws -> pid_t {
        let shell = try fx.spawn(script, extraEnvironment: extraEnvironment)
        defer { shell.wait() }
        guard let pid = fx.hungPid("launchctl", within: 60) else {
            _ = shell.signal(SIGKILL)
            throw FixtureError("the bootout never started: \(fx.calls())")
        }
        guard !shell.hasExited else {
            throw FixtureError("the script ended before the test could kill it (wait status \(shell.wait())), so it was not signaled: \(fx.calls())")
        }
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the script did not end by SIGKILL (wait status \(status))")
        return pid
    }

    /// Samples the lock until it is free: whenever it is, the hung fake
    /// `pid` must be gone already. Fails if the lock is not free within
    /// `seconds`.
    func assertLockHeldUntilGone(_ pid: pid_t, within seconds: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try fx.lockIsFree() {
                XCTAssertFalse(kill(pid, 0) == 0, "the lock was free while pid \(pid) still ran", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("the lock was not free within \(seconds) s; pid \(pid) running: \(kill(pid, 0) == 0)", file: file, line: line)
    }

}

// MARK: - Fixture

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// A throwaway tree:
///   root/home              INSOMNIA_HOME (session.json, state.json, Logs/, LaunchAgents/)
///   root/bin               recording fakes
///   root/repo/scripts      patched copies of backstop.sh and uninstall.sh
///   root/Applications      fake Insomnia.app bundle
///   root/etc/sudoers.d     fake sudoers rule
/// The child gets no HOME at all: every $HOME-derived constant is patched in
/// the copy, and a stray $HOME would fail under `set -u` instead of reaching
/// the real home directory.
private final class ScriptFixture {
    let root: URL
    let home: URL
    let bin: URL
    let repoScripts: URL
    let appsDir: URL
    let app: URL
    let sudoers: URL
    let callsLog: URL
    let bootUUID = "0F0F0F0F-1111-2222-3333-444444444444"
    let uid = String(getuid())

    var backstop: URL { repoScripts.appendingPathComponent("backstop.sh") }
    var uninstall: URL { repoScripts.appendingPathComponent("uninstall.sh") }
    var install: URL { repoScripts.appendingPathComponent("install.sh") }
    var installRedirected: URL { repoScripts.appendingPathComponent("install.redirected.sh") }
    /// installRedirected with a 1 s limit for each bounded call.
    var session: URL { home.appendingPathComponent("session.json") }
    var state: URL { home.appendingPathComponent("state.json") }
    var config: URL { home.appendingPathComponent("config.json") }
    var lock: URL { home.appendingPathComponent(".recovery.lock") }
    /// backstop.sh as install.sh seals it into the bundle.
    var installedBackstop: URL { app.appendingPathComponent("Contents/Resources/backstop.sh") }
    /// The writable copy installs before the sealed layout left here.
    var legacyBackstop: URL { home.appendingPathComponent("backstop.sh") }
    /// What the fake codesign prints as the bundle's designated requirement.
    let requirement = "cdhash H\"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c\""
    var logFile: URL { home.appendingPathComponent("Logs/insomnia.log") }
    var plist: URL { home.appendingPathComponent("LaunchAgents/com.insomnia.backstop.plist") }
    var fakePmset: String { bin.appendingPathComponent("pmset").path }
    /// The fake app binary backstop.sh calls for `--resume-frozen`.
    var fakeInsomnia: URL { bin.appendingPathComponent("Insomnia") }
    /// The installed bundle's Info.plist. As in production, both scripts
    /// read this one file: uninstall.sh to pick a backstop, and the
    /// backstop copies before they run the fake binary. writeFakes makes it
    /// declare InsomniaResumeFrozenVersion 1. The fake binary itself stays
    /// in `bin`, so installMachinery and install.sh can put their own
    /// Contents/MacOS/Insomnia in the bundle.
    var appInfo: URL { app.appendingPathComponent("Contents/Info.plist") }

    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("insomnia-script-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        repoScripts = root.appendingPathComponent("repo/scripts", isDirectory: true)
        appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        app = appsDir.appendingPathComponent("Insomnia.app", isDirectory: true)
        sudoers = root.appendingPathComponent("etc/sudoers.d/insomnia")
        callsLog = root.appendingPathComponent("calls.log")
        for dir in [home, bin, repoScripts, appsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // repo/ is a source checkout to install.sh and uninstall.sh: their
        // folder is scripts/, with Package.swift one level up.
        try "// swift-tools-version: 6.2\n".write(to: root.appendingPathComponent("repo/Package.swift"), atomically: true, encoding: .utf8)
        try writeFakes()
        try writeScriptCopies()
        try bootUUID.write(to: root.appendingPathComponent("boot.uuid"), atomically: true, encoding: .utf8)
    }

    func destroy() {
        releaseCommand()
        // A supervisor still waiting to write its status into a FIFO would
        // wait forever once the FIFO is gone.
        drainStatusFIFOs(within: 1)
        try? fm.removeItem(at: root)
    }

    /// The backstop's files in INSOMNIA_HOME: each bounded call's .pid and
    /// .rc status files, and the app binary's input and answer directory.
    func backstopFiles() throws -> [String] {
        try contents(of: home).filter { $0.hasPrefix(".backstop") }
    }

    /// Opens each FIFO among the backstop's files for reading, without
    /// waiting for a writer, so a supervisor blocked on writing its status
    /// there (see the fake sudo's "status-delayed") can go on. Returns what
    /// was written to each, by file name, once its writer has closed it or
    /// after `seconds`.
    @discardableResult
    func drainStatusFIFOs(within seconds: Double) -> [String: String] {
        var written: [String: String] = [:]
        for name in (try? backstopFiles()) ?? [] {
            let path = home.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { continue }
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    data.append(contentsOf: buffer[0..<n])
                } else if n == 0 && !data.isEmpty {
                    break   // the writer has closed it
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            written[name] = String(decoding: data, as: UTF8.self)
        }
        return written
    }

    /// Lets a fake command in mode "ignore-term" / "closes-fd9" finish.
    func releaseCommand() {
        fm.createFile(atPath: root.appendingPathComponent("release").path, contents: nil)
    }

    /// nil while a release-controlled fake command is still running;
    /// "released" or "watchdog" once it has ended, saying what ended it.
    func commandEnded() -> String? {
        (try? String(contentsOf: root.appendingPathComponent("command.ended"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polls until the recovery lock is free; false after `seconds`.
    func waitUntilLockIsFree(_ seconds: Double = 15) throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if try lockIsFree() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return try lockIsFree()
    }

    /// What install.sh's build and bundle steps need from the "repo":
    /// Resources/Info.plist, Resources/AppIcon.icns and a binary at the fake
    /// swift's bin path.
    func prepareInstall() throws {
        // An install test starts with nothing at $APP unless it writes a
        // bundle there: the Info.plist written for the backstop's binary
        // check would otherwise leave a bundle with no binary at $APP.
        try fm.removeItem(at: app)
        let resources = repoScripts.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zacheryng.insomnia</string></dict></plist>
        """.write(to: resources.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try "icns".write(to: resources.appendingPathComponent("AppIcon.icns"), atomically: true, encoding: .utf8)
        let binroot = root.appendingPathComponent("binroot", isDirectory: true)
        try fm.createDirectory(at: binroot, withIntermediateDirectories: true)
        let binary = binroot.appendingPathComponent("Insomnia")
        try TestScripts.write("#!/bin/bash\nexit 0\n", to: binary)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// A bundle from an earlier install at $APP, with a binary whose first
    /// line ("previous") tells it apart from the fake build's ("#!/bin/bash").
    func writePreviousApp(at url: URL? = nil) throws {
        let bundle = url ?? app
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "previous\n".write(to: bundle.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
    }

    /// First line of the binary installed at $APP.
    func installedBinaryFirstLine() throws -> String {
        let text = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8)
        return String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// A stand-in backstop that records which copy ran and claims success.
    func writeMarkerBackstop(at url: URL, name: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestScripts.write("#!/bin/bash\nprintf 'backstop \(name) %s\\n' \"$*\" >> \"\(callsLog.path)\"\nexit 0\n", to: url, executable: false)
    }

    func plistOnDisk() throws -> [String: Any] {
        let data = try Data(contentsOf: plist)
        guard let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FixtureError("the LaunchAgent plist is not a dictionary")
        }
        return obj
    }

    func contents(of dir: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: Scripts

    static var productionScripts: URL {
        // .../Tests/InsomniaTests/RecoveryScriptTests.swift -> .../scripts
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts", isDirectory: true)
    }

    private func writeScriptCopies() throws {
        let src = Self.productionScripts
        let backstopText = try String(contentsOf: src.appendingPathComponent("backstop.sh"), encoding: .utf8)
        try Self.patch(backstopText, [
            "PMSET": fakePmset,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "PS": bin.appendingPathComponent("ps").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "SYSCTL": bin.appendingPathComponent("sysctl").path,
            "CHMOD": bin.appendingPathComponent("chmod").path,
            "INSOMNIA_BIN": fakeInsomnia.path,
            "INSOMNIA_INFO": appInfo.path,
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
            "DATE": bin.appendingPathComponent("date").path,
            "MV": bin.appendingPathComponent("mv").path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "COMMAND_TIMEOUT_SECONDS": "1",
            "KILL_GRACE_SECONDS": "1",
        ]).write(to: backstop, atomically: true, encoding: .utf8)

        let uninstallText = try String(contentsOf: src.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        try Self.patch(uninstallText, [
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "OSASCRIPT": bin.appendingPathComponent("osascript").path,
            "LAUNCHCTL": bin.appendingPathComponent("launchctl").path,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "APP": app.path,
            "SUDOERS": sudoers.path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "QUIT_WAIT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "5",
        ]).write(to: uninstall, atomically: true, encoding: .utf8)

        // build-app.sh (run by install.sh from $ROOT/scripts): build and
        // signing go to the fakes.
        let buildText = try String(contentsOf: src.appendingPathComponent("build-app.sh"), encoding: .utf8)
        let buildApp = repoScripts.appendingPathComponent("build-app.sh")
        try Self.patch(buildText, [
            "SWIFT": bin.appendingPathComponent("swift").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
        ]).write(to: buildApp, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: buildApp.path)

        try writeInstallCopies(extraConstants: [:])
    }

    /// install.sh: every $HOME-derived path and every tool is redirected
    /// into the fixture (signing, sudo, launchctl included; the build goes
    /// through the patched build-app.sh above). Tests that need another
    /// constant (the real CODESIGN) rewrite both copies with it.
    func writeInstallCopies(extraConstants: [String: String]) throws {
        let installText = try String(contentsOf: Self.productionScripts.appendingPathComponent("install.sh"), encoding: .utf8)
        let patchedInstall = try Self.patch(installText, [
            "QUIT_WAIT_SECONDS": "1",
            "APP_DIR": appsDir.path,
            "APP_SUPPORT": home.path,
            "LOG_DIR": home.appendingPathComponent("Logs").path,
            "LAUNCH_AGENTS": home.appendingPathComponent("LaunchAgents").path,
            "SUDOERS": sudoers.path,
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "OSASCRIPT": bin.appendingPathComponent("osascript").path,
            "LAUNCHCTL": bin.appendingPathComponent("launchctl").path,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
            "SYSCTL": bin.appendingPathComponent("sysctl").path,
            "MV": bin.appendingPathComponent("mv").path,
            "RM": bin.appendingPathComponent("rm").path,
            "RMDIR": bin.appendingPathComponent("rmdir").path,
            "MKTEMP": bin.appendingPathComponent("mktemp").path,
            "MKDIR": bin.appendingPathComponent("mkdir").path,
            "CHMOD": bin.appendingPathComponent("chmod").path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "5",
        ].merging(extraConstants) { $1 })
        try patchedInstall.write(to: install, atomically: true, encoding: .utf8)
        // The redirected copy runs past the INSOMNIA_HOME refusal: that
        // variable is what makes the backstop copy it installs act on the
        // fixture instead of ~/Library. The plain copy keeps the refusal.
        let redirected = try Self.replaceOnce(patchedInstall, #"if [[ -n "${INSOMNIA_HOME:-}" ]]; then"#, with: "if false; then")
        try redirected.write(to: installRedirected, atomically: true, encoding: .utf8)
    }

    /// A bundle the way a release zip carries it: Info.plist, a marker
    /// executable (or a real Mach-O, a copy of /usr/bin/true, when `machO`
    /// is set so the real codesign can sign the bundle) and the sealed
    /// backstop (the fixture's patched copy, so install.sh's recovery step
    /// acts on the fixture). What the fake codesign says about its signature
    /// is set with `setMode("codesign", ...)` and `setSigning(...)`.
    func writePrebuiltApp(bundleID: String = "com.zacheryng.insomnia", version: String = "0.1.0", withBackstop: Bool = true, machO: Bool = false) throws -> URL {
        let app = root.appendingPathComponent("dist/Insomnia.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Insomnia</string>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        </dict></plist>
        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        if machO {
            try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Insomnia").path)
        } else {
            try "prebuilt".write(to: app.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
        }
        if withBackstop {
            try fm.copyItem(at: backstop, to: app.appendingPathComponent("Contents/Resources/backstop.sh"))
        }
        return app
    }

    /// What the fake codesign reports for `-dvv`: "adhoc", or
    /// "developer-id:<team>" for a Developer ID Application signature.
    func setSigning(_ value: String) {
        try? value.write(to: root.appendingPathComponent("codesign.signing"), atomically: true, encoding: .utf8)
    }

    /// Rewrites `NAME=...` constant lines. Every name must match exactly one
    /// line, so a renamed constant in the script fails loudly here instead of
    /// letting a test run the real tool.
    static func patch(_ text: String, _ constants: [String: String]) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for (name, value) in constants {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            guard hits.count == 1 else {
                throw FixtureError("expected exactly one '\(name)=' line, found \(hits.count)")
            }
            guard !value.contains("'") else { throw FixtureError("fixture path contains a quote: \(value)") }
            lines[hits[0]] = "\(name)='\(value)'"
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces one exact line; fails loudly if the script no longer has it.
    static func replaceOnce(_ text: String, _ exact: String, with replacement: String) throws -> String {
        guard text.components(separatedBy: exact).count == 2 else {
            throw FixtureError("expected exactly one occurrence of '\(exact)'")
        }
        return text.replacingOccurrences(of: exact, with: replacement)
    }

    // MARK: Fakes

    /// An app bundle's Info.plist, with InsomniaResumeFrozenVersion set to
    /// `resumeFrozenVersion` as an integer, or without the key when nil.
    static func infoPlist(resumeFrozenVersion: String?) -> String {
        let key = resumeFrozenVersion.map { "<key>InsomniaResumeFrozenVersion</key><integer>\($0)</integer>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>Insomnia</string>\(key)</dict></plist>

        """
    }

    private func writeFake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try TestScripts.write("#!/bin/bash\n" + body, to: url)
    }

    private func writeFakes() throws {
        let calls = callsLog.path
        let r = root.path
        // sudo: `-n <cmd>` is the pmset path and succeeds or fails by mode
        // without running anything. `rm`/`test` run unprivileged, and only
        // on a path inside the fixture.
        // Mode "hang" behaves like a pmset that never returns.
        // Mode "auth-fail": every form that would prompt (visudo, install)
        // fails like a wrong password, and `-n` forms fail as unpermitted.
        // Mode "rule-not-effective": authentication passes and the rule is
        // installed, but `sudo -n -l <pmset ...>` still says no. Mode
        // "rule-gone-under-lock": `sudo -n -l` says yes while nobody holds
        // the recovery lock and no while someone does, the way a rule removed
        // by an uninstall.sh that held the lock first answers to a run that
        // then takes it. In mode "rule-check-hangs" `sudo -n -l` never
        // answers and ignores SIGTERM; in "rule-check-hangs-under-lock" it
        // never answers while the lock is held and stops on SIGTERM; in
        // "rule-check-ignores-term-under-lock" it never answers while the
        // lock is held and ignores SIGTERM (see sudoHangHere).
        // visudo checks the candidate file exists, is non-empty and grants
        // pmset, so an installer that validated the wrong path or an empty
        // heredoc cannot pass here.
        try writeFake("sudo", """
        printf 'sudo %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/sudo.mode" 2>/dev/null || echo ok)"
        \(sudoHangHere())
        \(lockHeldHere())
        # "ignore-term" and "closes-fd9" behave like a pmset that ignores
        # SIGTERM: they live until the test creates the release file (or the
        # fixture is destroyed, or a 60 s wall-clock watchdog), so a test decides when
        # the command ends instead of racing a wall-clock sleep. On exit they
        # write command.ended = released | watchdog, so a test can tell a
        # command that is still alive (no file) from one that ended, and why.
        case "${1:-}" in
          -n) if [[ "${2:-}" == -l ]]; then
                case "$mode" in
                  auth-fail|rule-not-effective) exit 1 ;;
                  rule-gone-under-lock) if lock_held; then exit 1; fi; exit 0 ;;
                  rule-check-hangs) hang_on_term ignore ;;
                  rule-check-hangs-under-lock) if lock_held; then hang_on_term stop; fi; exit 0 ;;
                  rule-check-ignores-term-under-lock) if lock_held; then hang_on_term ignore; fi; exit 0 ;;
                  *) exit 0 ;;
                esac
              fi
              case "$mode" in
                ok) exit 0 ;;
                hang) exec /bin/sleep 60 ;;
                ignore-term) trap '' TERM; deadline=$(( $(date +%s) + 60 ))
                  while [[ ! -e "\(r)/release" && -d "\(r)" && $(date +%s) -lt $deadline ]]; do /bin/sleep 0.1; done
                  if [[ -e "\(r)/release" ]]; then echo released > "\(r)/command.ended"
                  elif [[ -d "\(r)" ]]; then echo watchdog > "\(r)/command.ended"; fi
                  exit 0 ;;
                closes-fd9) exec 9<&-; trap '' TERM; deadline=$(( $(date +%s) + 60 ))
                  while [[ ! -e "\(r)/release" && -d "\(r)" && $(date +%s) -lt $deadline ]]; do /bin/sleep 0.1; done
                  if [[ -e "\(r)/release" ]]; then echo released > "\(r)/command.ended"
                  elif [[ -d "\(r)" ]]; then echo watchdog > "\(r)/command.ended"; fi
                  exit 0 ;;
                # "logs-term": like "ignore-term", and every SIGTERM it gets
                # is logged as "sudo SIGTERM" (see sudoHangHere).
                logs-term) hang_on_term ignore ;;
                # "drops-fd9-logs-signals": like "logs-term", after closing
                # its fd 9 the way sudo does, and every SIGHUP it gets is
                # logged as "sudo SIGHUP".
                drops-fd9-logs-signals) exec 9<&-; trap 'echo "sudo SIGHUP" >> "\(calls)"' HUP; hang_on_term ignore ;;
                # "signals-self": for SIGTERM and then SIGHUP, a shell that
                # inherits this command's signal actions sends itself the
                # signal and, if it is still there afterwards, logs "sudo
                # SURVIVED <signal>". Then it exits 0.
                signals-self) for s in TERM HUP; do /bin/bash -c "kill -$s \\$\\$; echo 'sudo SURVIVED $s' >> '\(calls)'"; done
                  printf 'sudo SIGNALS-CHECKED\\n' >> "\(calls)"; exit 0 ;;
                # "status-delayed": finds the status files of the backstop
                # call that runs it (the .pid file holding its own pid),
                # changes two of them and exits 0. The .pid file then names
                # the process in sentinel.pid, the way a pid the kernel gave
                # to another process after this one was reaped would, and a
                # FIFO stands where the call's status goes, so the
                # supervisor's status write waits until the test opens the
                # FIFO to read it (see drainStatusFIFOs).
                status-delayed) base=""
                  for (( i = 0; i < 50; i++ )); do
                    for f in "\(home.path)"/.backstop.*.pid; do
                      if [[ "$(cat "$f" 2>/dev/null)" == "$$" ]]; then base="${f%.pid}"; break 2; fi
                    done
                    /bin/sleep 0.1
                  done
                  [[ -n "$base" ]] || exit 0
                  cat "\(r)/sentinel.pid" > "$base.pid"
                  /usr/bin/mkfifo "$base.rc"
                  printf 'sudo STATUS-DELAYED\\n' >> "\(calls)"
                  exit 0 ;;
                *) exit 1 ;;
              esac ;;
          visudo)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            # "swap-prebuilt": someone replaces the --app bundle at its path
            # (writePrebuiltApp's dist/Insomnia.app) while the password prompt waits.
            if [[ "$mode" == swap-prebuilt ]]; then printf 'swapped' > "\(r)/dist/Insomnia.app/Contents/MacOS/Insomnia"; fi
            f=""; for a in "$@"; do f="$a"; done
            # Rejects unless the file is non-empty and has the rule.
            # shellcheck disable=SC2015
            [[ -s "$f" ]] && grep -q 'NOPASSWD: /usr/bin/pmset' "$f" || { printf 'sudo VISUDO-REJECTED %s\\n' "$*" >> "\(calls)"; exit 1; }
            exit 0 ;;
          install)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            src=""; dst=""
            for a in "$@"; do src="$dst"; dst="$a"; done
            case "$dst" in "\(r)"/*) /bin/mkdir -p "$(dirname "$dst")"; /bin/cp "$src" "$dst"; exit 0 ;; esac
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          rm|test)
            for a in "$@"; do
              case "$a" in "\(r)"/*) exec "$@" ;; esac
            done
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          *) exit 1 ;;
        esac
        """)
        try writeFake("pmset", """
        printf 'pmset DIRECT %s\\n' "$*" >> "\(calls)"
        exit 99
        """)
        // swift / codesign: install.sh's build and signing steps, redirected
        // to a fake binary inside the fixture.
        try writeFake("swift", """
        printf 'swift %s\\n' "$*" >> "\(calls)"
        for a in "$@"; do [[ "$a" == --show-bin-path ]] && { echo "\(r)/binroot"; exit 0; }; done
        exit 0
        """)
        // mv: install.sh's and backstop.sh's MV. Runs /bin/mv unless a line
        // of mv.fail, "<from pattern>|<to pattern>" (bash globs), matches the
        // move; then it logs "mv FAILED <from> <to>" and exits 1 like a
        // refused rename, and both paths stay as they were.
        try writeFake("mv", """
        args=(); for a in "$@"; do [[ "$a" == -* ]] || args+=("$a"); done
        from="${args[0]:-}"; to="${args[1]:-}"
        if [[ -f "\(r)/mv.fail" ]]; then
          while IFS='|' read -r f t; do
            # The patterns are globs, so they stay unquoted.
            # shellcheck disable=SC2053
            if [[ -n "$f" && "$from" == $f && "$to" == $t ]]; then
              printf 'mv FAILED %s %s\\n' "$from" "$to" >> "\(calls)"
              echo "mv: rename $from to $to: Permission denied" >&2
              exit 1
            fi
          done < "\(r)/mv.fail"
        fi
        exec /bin/mv "$@"
        """)
        // rm, rmdir, mktemp, mkdir: install.sh's RM, RMDIR, MKTEMP and MKDIR.
        // Each call is logged and then made by the real tool, so a test can
        // tell a file removed or created through the fixed-path variable from
        // one handled by a bare name. (Its CHMOD is the chmod fake below.)
        for (tool, real) in [("rm", "/bin/rm"), ("rmdir", "/bin/rmdir"), ("mktemp", "/usr/bin/mktemp"), ("mkdir", "/bin/mkdir")] {
            try writeFake(tool, """
            printf '\(tool)%s\\n' "${*:+ $*}" >> "\(calls)"
            exec \(real) "$@"
            """)
        }
        // codesign: signing is recorded and succeeds. `-d -r-` prints a
        // fixed designated requirement the way codesign does (on stderr,
        // with the "# " an implicit requirement carries). `-dvv` describes
        // the signature per codesign.signing (adhoc | developer-id:<team>).
        // `--verify` passes unless mode "verify-fails"; mode
        // "deep-verify-fails" fails only the `--deep` form install.sh runs
        // on a prebuilt bundle, and "requirement-verify-fails" only the
        // `-R=` form (the agent's pinned check). A path listed in
        // codesign.rejects (see `rejectSignature(of:)`) fails every form.
        // Mode "verify-hangs": `--verify` never answers (see hangHere);
        // "verify-hangs-under-lock": only while someone holds the recovery
        // lock.
        try writeFake("codesign", """
        printf 'codesign %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/codesign.mode" 2>/dev/null || echo ok)"
        \(hangHere("codesign"))
        \(lockHeldHere())
        signing="$(cat "\(r)/codesign.signing" 2>/dev/null || echo adhoc)"
        last=""; deep=0; pinned=0; for a in "$@"; do last="$a"; [[ "$a" == --deep ]] && deep=1; [[ "$a" == -R=* ]] && pinned=1; done
        for a in "$@"; do
          case "$a" in
            -r-) echo "Executable=$last/Contents/MacOS/Insomnia" >&2; echo '# designated => \(requirement)' >&2; exit 0 ;;
            -dvv) echo "Executable=$last/Contents/MacOS/Insomnia" >&2; echo "Identifier=com.zacheryng.insomnia" >&2
                  case "$signing" in
                    developer-id:*) echo "Authority=Developer ID Application: Tester (${signing#developer-id:})" >&2
                                    echo "Authority=Developer ID Certification Authority" >&2
                                    echo "Authority=Apple Root CA" >&2
                                    echo "TeamIdentifier=${signing#developer-id:}" >&2 ;;
                    *) echo "Signature=adhoc" >&2; echo "TeamIdentifier=not set" >&2 ;;
                  esac
                  exit 0 ;;
            --verify)
              if [[ "$mode" == verify-hangs ]]; then hang_here; fi
              if [[ "$mode" == verify-hangs-under-lock ]] && lock_held; then hang_here; fi
              if [[ -f "\(r)/codesign.rejects" ]] && grep -qxF -- "$last" "\(r)/codesign.rejects"; then echo "$last: does not satisfy its designated Requirement" >&2; exit 3; fi
              if [[ "$mode" == verify-fails || ( "$mode" == deep-verify-fails && $deep == 1 ) || ( "$mode" == requirement-verify-fails && $pinned == 1 ) ]]; then echo "$last: a sealed resource is missing or invalid" >&2; exit 1; fi
              exit 0 ;;
          esac
        done
        exit 0
        """)
        // ps: answers from ps.table. Modes: "fail" (exit 2 with an error
        // line, like a broken ps) and "garbage" (exit 0 with nonsense).
        try writeFake("ps", """
        printf 'ps %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/ps.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == fail ]]; then echo "ps: cannot read process table" >&2; exit 2; fi
        if [[ "$mode" == garbage ]]; then echo "not a process line"; exit 0; fi
        pid=""; for a in "$@"; do pid="$a"; done
        [[ -f "\(r)/ps.table" ]] || exit 1
        while IFS='|' read -r p lstart stat uid; do
          if [[ "$p" == "$pid" ]]; then printf '%s %s %s\\n' "$lstart" "$stat" "$uid"; exit 0; fi
        done < "\(r)/ps.table"
        exit 1
        """)
        try writeFake("kill", """
        printf 'kill %s\\n' "$*" >> "\(calls)"
        fail="$(cat "\(r)/kill.fail.mode" 2>/dev/null || true)"
        for f in $fail; do [[ "$f" == "${2:-}" ]] && exit 1; done
        exit 0
        """)
        // sysctl: `-n kern.bootsessionuuid` reads boot.uuid and is not
        // logged (backstop.sh asks on every run; it changes nothing).
        // `-n hw.optional.arm64` is logged and reads 1, an Apple Silicon Mac
        // (also what a shell under Rosetta reads there). Mode "intel-0"
        // reads 0; "intel-missing" fails the way sysctl does for a key the
        // Mac lacks.
        try writeFake("sysctl", """
        if [[ "$*" == "-n hw.optional.arm64" ]]; then
          printf 'sysctl %s\\n' "$*" >> "\(calls)"
          case "$(cat "\(r)/sysctl.mode" 2>/dev/null || echo ok)" in
            intel-0) echo 0 ;;
            intel-missing) echo "sysctl: unknown oid 'hw.optional.arm64'" >&2; exit 1 ;;
            *) echo 1 ;;
          esac
          exit 0
        fi
        cat "\(r)/boot.uuid"
        """)
        // chmod: recorded in chmod.calls, apart from calls.log, then run for
        // real so the modes still change. A path listed in chmod.fail fails
        // the way an immutable file does.
        try writeFake("chmod", """
        printf 'chmod %s\\n' "$*" >> "\(r)/chmod.calls"
        if [[ -f "\(r)/chmod.fail" ]] && grep -qxF -- "${2:-}" "\(r)/chmod.fail"; then
          echo "chmod: ${2:-}: Operation not permitted" >&2
          exit 1
        fi
        exec /bin/chmod "$@"
        """)
        // Insomnia --resume-frozen: reads its entries from standard input,
        // one "<pid> <startedAt> <micros> <boot>" line each, and records the
        // call as "Insomnia <arguments> < <line>; <line>; ...". Answers one
        // "<pid> <word>" line per entry, the word from insomnia.table
        // (pid|word) or "resumed" for a pid without a row; exit 0 when every
        // word is resumed or gone, 1 otherwise. Writes its parent's pid to
        // insomnia.ppid, and the inode of the file open on its fd 9 to
        // insomnia.fd9 (empty without an fd 9). Modes: "raw" prints insomnia.output verbatim and
        // exits with insomnia.status. "hang" prints its answer and then
        // sleeps for 300 s, so only a signal ends it in time. "hold" waits
        // until insomnia.release exists (30 s at most), records "Insomnia
        // released", and then answers as usual. A test that
        // needs SIGTERM ignored runs the backstop with it ignored (see
        // ScriptFixture.run): the fake inherits that from its first
        // instruction, so no trap has to be in place before the signal.
        try fm.createDirectory(at: appInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.infoPlist(resumeFrozenVersion: "1").write(to: appInfo, atomically: true, encoding: .utf8)
        try writeFake("Insomnia", """
        input=()
        while IFS= read -r line || [[ -n "$line" ]]; do input+=("$line"); done
        joined=""
        for line in "${input[@]}"; do joined="${joined:+$joined; }$line"; done
        printf 'Insomnia %s < %s\\n' "$*" "$joined" >> "\(calls)"
        echo "$PPID" > "\(r)/insomnia.ppid"
        if [[ -e /dev/fd/9 ]]; then stat -f %i /dev/fd/9 > "\(r)/insomnia.fd9"; else : > "\(r)/insomnia.fd9"; fi
        mode="$(cat "\(r)/insomnia.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == hold ]]; then
          for (( i = 0; i < 300; i++ )); do
            [[ -f "\(r)/insomnia.release" ]] && break
            /bin/sleep 0.1
          done
          printf 'Insomnia released\\n' >> "\(calls)"
        fi
        if [[ "$mode" == raw ]]; then
          cat "\(r)/insomnia.output"
          exit "$(cat "\(r)/insomnia.status")"
        fi
        status=0
        for line in "${input[@]}"; do
          pid="${line%% *}"
          word=resumed
          if [[ -f "\(r)/insomnia.table" ]]; then
            while IFS='|' read -r p w; do [[ "$p" == "$pid" ]] && word="$w"; done < "\(r)/insomnia.table"
          fi
          printf '%s %s\\n' "$pid" "$word"
          case "$word" in resumed|gone) ;; *) status=1 ;; esac
        done
        [[ "$mode" == hang ]] && exec /bin/sleep 300
        exit "$status"
        """)
        // date: the real tool, except that with date.mode present the stamp
        // a moved-aside session.json is named after (`-u +%Y%m%dT%H%M%SZ`)
        // is the mode's text, so a test can take that exact name first.
        // Not logged: it changes nothing.
        try writeFake("date", """
        if [[ "$*" == "-u +%Y%m%dT%H%M%SZ" && -f "\(r)/date.mode" ]]; then
          cat "\(r)/date.mode"; echo; exit 0
        fi
        exec /bin/date "$@"
        """)
        // defaults: an NSAppSleepDisabled table per domain (defaults.table,
        // `domain|value` with the value as `defaults read` prints a bool: 1
        // or 0). `read` prints it or fails like the real tool when absent;
        // `write -bool` and `delete` edit the table, and `delete` of an
        // absent key fails like the real tool. Mode "fail" makes every
        // write and delete fail; "fail:<domain>" only that domain's. Mode
        // "unreachable" (or "unreachable:<domain>") fails every command,
        // read included, the way a cfprefsd that does not answer would:
        // non-zero without any absent-key message. Mode "hang" (or
        // "hang:<domain>") never answers; see hangHere. defaults.wording
        // picks the message for an absent key: macOS 26's "does not exist"
        // by default, "27-key" for macOS 27's "Could not find key" (a
        // domain that exists) and "27-domain" for its "Domain ... not
        // found" (a domain with no preferences at all).
        try writeFake("defaults", """
        printf 'defaults %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/defaults.mode" 2>/dev/null || echo ok)"
        table="\(r)/defaults.table"
        cmd="${1:-}"; domain="${2:-}"; key="${3:-}"
        [[ "$key" == NSAppSleepDisabled ]] || { echo "fake defaults: unexpected key '$key'" >&2; exit 2; }
        lookup() {
          [[ -f "$table" ]] || return 1
          local d v
          while IFS='|' read -r d v; do
            if [[ "$d" == "$domain" ]]; then echo "$v"; return 0; fi
          done < "$table"
          return 1
        }
        drop() {
          [[ -f "$table" ]] || return 0
          awk -F'|' -v d="$domain" '$1 != d' "$table" > "$table.next" && mv "$table.next" "$table"
        }
        failing() { [[ "$mode" == fail || "$mode" == "fail:$domain" ]]; }
        absent() {
          case "$(cat "\(r)/defaults.wording" 2>/dev/null)" in
            27-key) echo "Error: Could not find key '$key' in domain '$domain'." >&2 ;;
            27-domain) echo "Error: Domain '$domain' not found." >&2 ;;
            ""|26) echo "The domain/default pair of ($domain, $key) does not exist" >&2 ;;
            *) echo "fake defaults: unknown wording" >&2; exit 2 ;;
          esac
          exit 1
        }
        \(hangHere("defaults"))
        if [[ "$mode" == hang || "$mode" == "hang:$domain" ]]; then hang_here; fi
        if [[ "$mode" == unreachable || "$mode" == "unreachable:$domain" ]]; then
          echo "fake defaults: cfprefsd did not answer for $domain" >&2; exit 1
        fi
        case "$cmd" in
          read)
            v="$(lookup)" || absent
            echo "$v"; exit 0 ;;
          write)
            failing && exit 1
            [[ "${4:-}" == -bool ]] || { echo "fake defaults: expected -bool" >&2; exit 2; }
            case "${5:-}" in true|TRUE|yes|YES|1) v=1 ;; false|FALSE|no|NO|0) v=0 ;; *) echo "fake defaults: bad bool" >&2; exit 2 ;; esac
            drop; echo "$domain|$v" >> "$table"; exit 0 ;;
          delete)
            failing && exit 1
            lookup >/dev/null || { echo "Domain ($domain) not found." >&2; exit 1; }
            drop; exit 0 ;;
          *) echo "fake defaults: unexpected command '$cmd'" >&2; exit 2 ;;
        esac
        """)
        // pgrep: pgrep.mode holds one exit status per line, consumed in
        // order; the last line repeats. Default 1 (not running).
        try writeFake("pgrep", """
        printf 'pgrep %s\\n' "$*" >> "\(calls)"
        f="\(r)/pgrep.mode"
        [[ -f "$f" ]] || exit 1
        first="$(head -n 1 "$f")"
        if (( $(wc -l < "$f") > 1 )); then tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"; fi
        \(hangHere("pgrep"))
        if [[ "$first" == hang ]]; then hang_here; fi
        exit "${first:-1}"
        """)
        for tool in ["pkill", "osascript"] {
            try writeFake(tool, """
            printf '\(tool) %s\\n' "$*" >> "\(calls)"
            exit 0
            """)
        }
        // launchctl: bootout/bootstrap succeed and `print` reports "not
        // loaded" (113) by default. Whatever the mode, a path argument is
        // only accepted when it ends in `.plist` and exists (real launchctl
        // fails with EIO otherwise, for bootstrap and bootout alike); bootout
        // also takes a service target `gui/<uid>/<label>` with no path.
        // Every bootstrap also records whether the recovery lock was held at
        // that moment (LOCK-HELD / LOCK-FREE), to prove the installer keeps
        // its transaction open across the agent replacement.
        // Modes that keep state like launchd: the job starts loaded, bootout
        // unloads it, bootstrap loads it (and fails with 37 while it is
        // loaded), and print reports which.
        //   "loaded": just that.
        //   "loaded-bootstrap-fails-once": the first bootstrap fails (5).
        //   "loaded-unload-fails-after-bootstrap": a bootout after a
        //     bootstrap fails (5) and the job stays loaded.
        //   "loaded-print-fails-once-after-bootstrap": the first print after
        //     a bootstrap fails with an error (1), later ones report state.
        //   "loaded-print-fails-after-bootstrap": every print after a
        //     bootstrap fails with an error.
        //   "loaded-reload-fails-yet-listed": the first bootstrap fails (5);
        //     the second fails (5) too, but leaves a job listed.
        // Fixed answers:
        //   "bootout-fails-still-loaded": bootout exits 5 and print always
        //     lists the job. "ambiguous": bootout and print fail with errors.
        //   "loaded-then-lost": print says loaded once, then not loaded;
        //     bootstrap always fails. "no-then-error": print says not loaded
        //     once, then fails with an error; bootstrap fails.
        //   "bootstrap-fails": nothing is loaded and every bootstrap fails.
        //   "print-hangs": print never answers (see hangHere); bootout succeeds.
        //   "bootout-hangs": bootout never answers (see hangHere); print
        //     lists the job.
        try writeFake("launchctl", """
        printf 'launchctl %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/launchctl.mode" 2>/dev/null || echo ok)"
        if [[ "${1:-}" == bootstrap ]]; then
          [[ "${3:-}" == *.plist && -f "${3:-}" ]] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
        elif [[ "${1:-}" == bootout && $# -ge 3 ]]; then
          [[ "${3:-}" == *.plist && -f "${3:-}" ]] || { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
        elif [[ "${1:-}" == bootout ]]; then
          [[ "${2:-}" == gui/\(uid)/com.insomnia.backstop ]] || { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
        fi
        if [[ "${1:-}" == bootstrap ]]; then
          if /usr/bin/lockf -k -s -t 0 "\(r)/home/.recovery.lock" /usr/bin/true 2>/dev/null; then
            echo 'launchctl LOCK-FREE during bootstrap' >> "\(calls)"
          else
            echo 'launchctl LOCK-HELD during bootstrap' >> "\(calls)"
          fi
          if [[ -f "\(app.path)/Contents/MacOS/Insomnia" ]]; then
            echo "launchctl APP-BINARY=$(head -n 1 "\(app.path)/Contents/MacOS/Insomnia") during bootstrap" >> "\(calls)"
          else
            echo 'launchctl APP-ABSENT during bootstrap' >> "\(calls)"
          fi
        fi
        \(hangHere("launchctl"))
        if [[ "${1:-}:$mode" == print:print-hangs ]]; then hang_here; fi
        if [[ "${1:-}:$mode" == bootout:bootout-hangs ]]; then hang_here; fi
        prints=0
        if [[ "${1:-}" == print ]]; then
          prints=$(( $(cat "\(r)/print.count" 2>/dev/null || echo 0) + 1 )); echo "$prints" > "\(r)/print.count"
        fi
        case "$mode" in
          loaded|loaded-bootstrap-fails-once|loaded-unload-fails-after-bootstrap|loaded-print-fails-once-after-bootstrap|loaded-print-fails-after-bootstrap|loaded-reload-fails-yet-listed)
            unloaded="\(r)/launchctl.unloaded"; bootstrapped="\(r)/launchctl.bootstrapped"
            case "${1:-}" in
              bootout)
                if [[ "$mode" == loaded-unload-fails-after-bootstrap && -e "$bootstrapped" ]]; then
                  echo "Boot-out failed: 5: Input/output error" >&2; exit 5
                fi
                : > "$unloaded"; exit 0 ;;
              bootstrap)
                [[ -e "$unloaded" ]] || { echo "Bootstrap failed: 37: Operation already in progress" >&2; exit 37; }
                if [[ "$mode" == loaded-bootstrap-fails-once || "$mode" == loaded-reload-fails-yet-listed ]] && [[ ! -e "\(r)/bootstrap.failed" ]]; then
                  : > "\(r)/bootstrap.failed"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
                fi
                if [[ "$mode" == loaded-reload-fails-yet-listed ]]; then
                  rm -f "$unloaded"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
                fi
                rm -f "$unloaded"; : > "$bootstrapped"; exit 0 ;;
              print)
                if [[ -e "$bootstrapped" ]] && { [[ "$mode" == loaded-print-fails-after-bootstrap ]] \
                    || { [[ "$mode" == loaded-print-fails-once-after-bootstrap ]] && [[ ! -e "\(r)/print.failed" ]]; }; }; then
                  : > "\(r)/print.failed"; echo "Could not print domain: 1: Operation not permitted" >&2; exit 1
                fi
                if [[ -e "$unloaded" ]]; then exit 113; fi; exit 0 ;;
            esac ;;
        esac
        case "${1:-}:$mode" in
          bootout:print-hangs) exit 0 ;;
          bootout:ok|bootout:loaded-then-lost|bootout:no-then-error|bootout:bootstrap-fails) exit 0 ;;
          bootstrap:ok) exit 0 ;;
          bootstrap:loaded-then-lost|bootstrap:no-then-error|bootstrap:bootstrap-fails) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
          print:loaded-then-lost) if (( prints == 1 )); then exit 0; fi; exit 113 ;;
          print:no-then-error) if (( prints == 1 )); then exit 113; fi; echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          print:ok|print:bootstrap-fails) exit 113 ;;
          bootout:ambiguous) echo "Boot-out failed: 1: Operation not permitted" >&2; exit 1 ;;
          print:ambiguous) echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          bootout:*) exit 5 ;;
          print:*) exit 0 ;;
          *) exit 1 ;;
        esac
        """)
    }

    /// True when nobody holds the recovery lock right now.
    func lockIsFree() throws -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        let probeExit = ProcessExit(probe)
        try probe.run()
        probeExit.wait()
        return probe.terminationStatus == 0
    }

    /// Makes the fake codesign's `--verify` fail for the bundle at `url`
    /// only, the way a bundle that is not the build a requirement pins does.
    func rejectSignature(of url: URL) throws {
        let list = root.appendingPathComponent("codesign.rejects")
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try (existing + url.path + "\n").write(to: list, atomically: true, encoding: .utf8)
    }

    /// A bundle at `url` whose binary's first line is `marker`.
    func writeBundle(at url: URL, marker: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "\(marker)\n".write(to: url.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
    }

    /// The agent plist an install writes for the bundle at $APP, pinning
    /// the fake codesign's requirement.
    func writeAgentPlist() throws {
        let dict = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", target: BackstopTarget(bundle: app, requirement: requirement))
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist)
    }

    /// Makes the fake mv refuse every move whose source and destination
    /// match one of these bash glob patterns.
    func failMoves(_ rules: [(from: String, to: String)]) throws {
        try rules.map { "\($0.from)|\($0.to)\n" }.joined()
            .write(to: root.appendingPathComponent("mv.fail"), atomically: true, encoding: .utf8)
    }

    func setMode(_ name: String, _ value: String) {
        try? value.write(to: root.appendingPathComponent("\(name).mode"), atomically: true, encoding: .utf8)
    }

    /// Which message the fake `defaults` prints for an absent key (see its
    /// comment): "27-key", "27-domain", or "26" (the default) for macOS
    /// 26's. Any other wording makes the fake fail, so a typo cannot pass
    /// for macOS 26.
    func setDefaultsWording(_ wording: String) throws {
        try wording.write(to: root.appendingPathComponent("defaults.wording"), atomically: true, encoding: .utf8)
    }

    /// The word the fake app binary answers per pid; the exit status follows
    /// from the words.
    func insomniaTable(_ rows: [(pid: Int, word: String)]) throws {
        let text = rows.map { "\($0.pid)|\($0.word)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("insomnia.table"), atomically: true, encoding: .utf8)
    }

    /// Makes the fake app binary print exactly `output` and exit `status`,
    /// whatever it is asked.
    func insomniaRaw(_ output: String, status: Int) throws {
        setMode("insomnia", "raw")
        try output.write(to: root.appendingPathComponent("insomnia.output"), atomically: true, encoding: .utf8)
        try String(status).write(to: root.appendingPathComponent("insomnia.status"), atomically: true, encoding: .utf8)
    }

    func psTable(_ rows: [(pid: Int, lstart: String, stat: String, uid: String)]) throws {
        let text = rows.map { "\($0.pid)|\($0.lstart)|\($0.stat)|\($0.uid)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("ps.table"), atomically: true, encoding: .utf8)
    }

    /// What `TZ=UTC LC_ALL=C ps -o lstart=` prints for a start second.
    func lstart(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// Shell function for a fake: a call that never answers. It notes in
    /// the call log if it inherited fd 9 (the recovery lock), records its
    /// pid in `<tool>.hung.pid`, ignores SIGTERM and sleeps 60 s, so only a
    /// SIGKILL ends it before then.
    func hangHere(_ tool: String) -> String {
        """
        hang_here() {
          if { : >&9; } 2>/dev/null; then echo '\(tool) FD9-OPEN' >> "\(callsLog.path)"; fi
          echo $$ > "\(root.path)/\(tool).hung.pid"
          trap '' TERM
          exec /bin/sleep 60
        }
        """
    }

    /// Shell function for the fake sudo: a `sudo -n -l` that never answers.
    /// sudo is never sent SIGKILL, so unlike hangHere this one does not
    /// wait for it. `hang_on_term stop` logs "sudo SIGTERM" and exits on
    /// SIGTERM, the way sudo ends a policy check. `hang_on_term ignore` logs
    /// it and keeps running until the test calls releaseCommand (or the
    /// fixture goes, or a 60 s watchdog), then writes command.ended. Both
    /// note an inherited fd 9 and record the pid in `sudo.hung.pid`, once
    /// the SIGTERM trap and the watchdog's deadline are in place. The
    /// watchdog runs on bash's SECONDS, so the fake forks nothing but
    /// /bin/sleep while it waits. A test may signal the fake's process
    /// group as soon as the pid appears, and a signal that killed a `date`
    /// setting the deadline would leave it at 60, ending the fake at once.
    /// A command substitution would also log one signal twice. Bash 3.2
    /// starts it with the shell's pending traps and trap commands, so a
    /// SIGTERM that lands just before the fork runs the trap in both.
    func sudoHangHere() -> String {
        """
        hang_on_term() {
          calls_log="\(callsLog.path)"
          if { : >&9; } 2>/dev/null; then echo 'sudo FD9-OPEN' >> "$calls_log"; fi
          if [[ "$1" == stop ]]; then
            trap 'echo "sudo SIGTERM" >> "$calls_log"; exit 143' TERM
          else
            trap 'echo "sudo SIGTERM" >> "$calls_log"' TERM
          fi
          deadline=$(( SECONDS + 60 ))
          echo $$ > "\(root.path)/sudo.hung.pid"
          while [[ ! -e "\(root.path)/release" && -d "\(root.path)" && $SECONDS -lt $deadline ]]; do /bin/sleep 0.1; done
          if [[ -e "\(root.path)/release" ]]; then echo released > "\(root.path)/command.ended"
          elif [[ -d "\(root.path)" ]]; then echo watchdog > "\(root.path)/command.ended"; fi
          exit 0
        }
        """
    }

    /// Shell function for a fake: `lock_held` succeeds while someone holds
    /// the recovery lock. It asks lockf for the lock without waiting and
    /// without creating the file, the way lockIsFree does from the test.
    func lockHeldHere() -> String {
        """
        lock_held() {
          [[ -e "\(lock.path)" ]] && ! /usr/bin/lockf -k -s -t 0 "\(lock.path)" /usr/bin/true 2>/dev/null
        }
        """
    }

    /// A TMPDIR inside the fixture for one run, so a test can check that
    /// the script leaves no scratch files behind.
    func privateTmp() throws -> URL {
        let dir = root.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether the hung fake of `tool` ran and has since exited.
    func hungProcessGone(_ tool: String, within seconds: Double = 5) -> Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("\(tool).hung.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// What the fake `defaults` holds: one NSAppSleepDisabled value per
    /// domain, as `defaults read` prints a bool (1 or 0).
    func defaultsTable(_ rows: [(domain: String, value: String)]) throws {
        let text = rows.map { "\($0.domain)|\($0.value)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("defaults.table"), atomically: true, encoding: .utf8)
    }

    /// The fake's table after a run: domain to value; absent means no key.
    func defaultsValues() -> [String: String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("defaults.table"), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    // MARK: State

    func writeState(_ json: String) throws {
        try json.write(to: state, atomically: true, encoding: .utf8)
    }

    func writeConfig(_ json: String) throws {
        try json.write(to: config, atomically: true, encoding: .utf8)
    }

    func writeSession(endsAt: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let json = #"{"startedAt":"\#(f.string(from: endsAt.addingTimeInterval(-3600)))","endsAt":"\#(f.string(from: endsAt))","extensions":[]}"#
        try json.write(to: session, atomically: true, encoding: .utf8)
    }

    func stateJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: state)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError("state.json is not a JSON object")
        }
        return obj
    }

    /// Everything uninstall.sh would remove on success.
    func installMachinery() throws {
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "binary".write(to: app.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
        try Self.infoPlist(resumeFrozenVersion: "1").write(to: appInfo, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: sudoers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "rule".write(to: sudoers, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plist".write(to: plist, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "log\n".write(to: logFile, atomically: true, encoding: .utf8)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: installedBackstop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: backstop, to: installedBackstop)
    }

    // MARK: Running

    /// Decoded lossily: the fake launchctl copies the first line of the
    /// installed binary into the log, which is Mach-O bytes, not text, for
    /// the fixture the real codesign signs.
    func calls() -> [String] {
        guard let data = try? Data(contentsOf: callsLog) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The calls besides those to the logging mktemp, rm, rmdir and mkdir,
    /// which every install run makes for its own scratch files (see
    /// bounded()) and the folders it installs into.
    func callsBesideScratchFiles() -> [String] {
        calls().filter { call in !["mktemp", "rm", "rmdir", "mkdir"].contains { call == $0 || call.hasPrefix($0 + " ") } }
    }

    func chmodCalls() -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("chmod.calls"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func clearCalls() {
        try? fm.removeItem(at: callsLog)
    }

    func log() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    /// Environment for the child: no inheritance, so neither the real HOME
    /// nor a TempHome's INSOMNIA_HOME can leak in. HOME is deliberately
    /// unset (see the class comment).
    private var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "INSOMNIA_HOME": home.path,
        ]
    }

    /// POSIX mode bits of a file or directory.
    func mode(_ url: URL) throws -> Int {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let m = attrs[.posixPermissions] as? Int else { throw FixtureError("no mode for \(url.path)") }
        return m
    }

    /// Inode of a file, to prove the lock file was retained rather than replaced.
    func inode(_ url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// Runs a script copy. `fd9` opens that file on descriptor 9 of the child
    /// first, the way uninstall.sh hands its lock handle to the backstop.
    /// `ignoringTerm` starts the script with SIGTERM ignored, which every
    /// process it starts inherits (not combined with `fd9`).
    /// `extraEnvironment` is for install.sh's refusal test and for a
    /// private TMPDIR (see privateTmp). `lastPid` is the script's pid
    /// afterwards: the wrappers exec it, so it is the pid of the process
    /// started here.
    private(set) var lastPid: Int32 = 0

    func run(_ script: URL, _ args: [String] = [], fd9: URL? = nil, ignoringTerm: Bool = false, extraEnvironment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        precondition(fd9 == nil || !ignoringTerm, "fd9 and ignoringTerm are not combined")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        if let fd9 {
            p.arguments = ["-c", #"exec 9<>"$0" && exec /bin/bash "$@""#, fd9.path, script.path] + args
        } else if ignoringTerm {
            p.arguments = ["-c", #"trap '' TERM && exec /bin/bash "$@""#, "bash", script.path] + args
        } else {
            p.arguments = [script.path] + args
        }
        p.environment = childEnvironment.merging(extraEnvironment) { $1 }
        p.currentDirectoryURL = root
        // Capture to files rather than pipes: nothing to drain, nothing to deadlock.
        let outURL = root.appendingPathComponent("stdout.\(UUID().uuidString)")
        let errURL = root.appendingPathComponent("stderr.\(UUID().uuidString)")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        p.standardOutput = out
        p.standardError = err
        let childExit = ProcessExit(p)
        try p.run()
        lastPid = p.processIdentifier
        childExit.wait()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// The pid a hung fake of `tool` recorded (see hangHere), once it has
    /// started; nil if it has not within `seconds`.
    func hungPid(_ tool: String, within seconds: Double) -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let text = try? String(contentsOf: root.appendingPathComponent("\(tool).hung.pid"), encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    /// A PATH whose `sleep` waits a quarter second before the sleep it was
    /// asked for, so every poll install.sh and uninstall.sh make is slow, as
    /// on a loaded machine where each fork takes long. The scripts call sleep
    /// by name; the fakes call /bin/sleep. Each call is counted (slowPolls()).
    func slowPollingPath() throws -> String {
        let dir = root.appendingPathComponent("slow-poll", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("sleep")
        try TestScripts.write("""
        #!/bin/bash
        echo "$*" >> "\(root.path)/slow-poll.log"
        /bin/sleep 0.25
        exec /bin/sleep "$@"

        """, to: stub)
        return "\(dir.path):/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// How many times the scripts called the slow `sleep`.
    func slowPolls() -> Int {
        let text = (try? String(contentsOf: root.appendingPathComponent("slow-poll.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    /// Runs a real tool (not a script) with the fixture's environment: the
    /// real codesign for the one test that signs its fixture, and the shells
    /// that read back a command install.sh prints for pasting.
    func runTool(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = childEnvironment
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let toolExit = ProcessExit(p)
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        toolExit.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A script started in the background by `spawn`. Nothing in the test
    /// process reaps it but `wait`: Foundation reaps only the Processes it
    /// started, and nothing else here calls waitpid. Until `wait`, its pid
    /// stays its own even after it exits (as a zombie), so `signal` reaches
    /// this child or nothing, never a process that reused the pid.
    final class Spawned {
        let pid: pid_t
        /// Started as the leader of a process group of its own (see spawn).
        let leadsGroup: Bool
        private(set) var status: Int32?

        init(pid: pid_t, leadsGroup: Bool) {
            self.pid = pid
            self.leadsGroup = leadsGroup
        }

        /// Whether the child has exited, checked without reaping it.
        var hasExited: Bool {
            guard status == nil else { return true }
            var info = siginfo_t()
            return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
        }

        /// Sends `sig` to the child. Refuses with -1 once `wait` has reaped
        /// it, since the pid may then belong to another process.
        func signal(_ sig: Int32) -> Int32 {
            guard status == nil else { return -1 }
            return kill(pid, sig)
        }

        /// Sends `sig` to every process in the group the child leads, the
        /// way launchd signals what is left of a job's process group once
        /// its main process has exited. Only for a child spawned with
        /// `ownProcessGroup`, so the group holds nothing but the child and
        /// what it started. Refuses with -1 once `wait` has reaped the
        /// child: until then its pid, the group's id, cannot name another
        /// process or group.
        func signalGroup(_ sig: Int32) -> Int32 {
            guard leadsGroup, status == nil else { return -1 }
            return killpg(pid, sig)
        }

        /// Waits for the child to exit, reaps it, and returns its wait
        /// status (-1 if waitpid failed).
        @discardableResult
        func wait() -> Int32 {
            if let status { return status }
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
            let result = reaped == pid ? raw : -1
            status = result
            return result
        }
    }

    /// Starts `script` under /bin/bash with the same environment (plus
    /// `extraEnvironment`) and working directory as `run`, standard input and output on /dev/null,
    /// and returns without waiting for it. Like a Process, the child gets
    /// no other descriptor of the test process, an empty signal mask and
    /// default signal actions. With `ownProcessGroup` it leads a new process
    /// group, as launchd starts a job, instead of joining the test's.
    func spawn(_ script: URL, extraEnvironment: [String: String] = [:], ownProcessGroup: Bool = false) throws -> Spawned {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, root.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var mask = sigset_t()
        sigemptyset(&mask)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        if ownProcessGroup {
            posix_spawnattr_setpgroup(&attr, 0)
            flags |= POSIX_SPAWN_SETPGROUP
        }
        posix_spawnattr_setflags(&attr, Int16(flags))

        let arguments = ["/bin/bash", script.path]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let environment = childEnvironment.merging(extraEnvironment) { $1 }.map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/bash", &actions, &attr, argv, envp)
        guard spawned == 0, pid > 0 else { throw FixtureError("posix_spawn /bin/bash \(script.path) failed: \(spawned)") }
        return Spawned(pid: pid, leadsGroup: ownProcessGroup)
    }

    /// A lockf process that holds the recovery lock.
    struct LockHolder {
        let process: Process
        let exit: ProcessExit

        /// Terminates the holder and returns once it has exited.
        func stop() {
            process.terminate()
            exit.wait()
        }
    }

    /// Holds the recovery lock from another process, the way a running app
    /// or a concurrent backstop would, until stopped.
    func holdLock() throws -> LockHolder {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        // The holder waits (not -t 0): a probe below may briefly own the lock
        // at the same instant, and the holder must outlast that, not give up.
        p.arguments = ["-k", "-t", "10", lock.path, "/bin/sleep", "30"]
        let diagURL = root.appendingPathComponent("lock-holder.log")
        fm.createFile(atPath: diagURL.path, contents: nil)
        let diag = try FileHandle(forWritingTo: diagURL)
        defer { try? diag.close() }
        p.standardOutput = diag
        p.standardError = diag
        let holder = LockHolder(process: p, exit: ProcessExit(p))
        try p.run()
        // Wait until the holder really owns the lock.
        var probes: [Int32] = []
        for _ in 0..<50 {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
            probe.standardOutput = diag
            probe.standardError = diag
            let probeExit = ProcessExit(probe)
            try probe.run()
            probeExit.wait()
            probes.append(probe.terminationStatus)
            if probe.terminationStatus == 75 { return holder }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.terminate()
        let text = (try? String(contentsOf: diagURL, encoding: .utf8)) ?? ""
        throw FixtureError("could not take the recovery lock for the contention test; holder running=\(p.isRunning) probes=\(probes) output=\(text)")
    }
}

/// The app and the production copy of backstop.sh across restarts, with
/// fake devices and a temporary home: what the agent publishes is what the
/// next launch reads.
@MainActor
final class AgentModeExitInANewBootTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy(); h = nil }

    private func lidActions(_ m: SessionManager, sampler: BrightnessSampler) -> LidActions {
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        m.config.darkenDisplayOnLidClose = true
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        return LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { true }), audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: sampler)
    }

    private func follow(_ m: SessionManager) -> BrightnessSampler {
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        return sampler
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    /// The same journal from boot A. In boot B the user or another tool
    /// switches Low Power Mode off a moment before the app launches: with
    /// no agent run before it, or after the agent could not publish this
    /// boot and so left the mode on. The app reads the mode off, which
    /// does not show the panel is back: 0.4 is not taken as the user's
    /// level, nothing is sampled, and a close and an open leave the
    /// user's 0.6 as set and never write 0.4. A launch in boot C decides
    /// on 0.6.
    private func checkARecentSwitchOffByHandIsNotTakenAsTheUsersLevel(failedPreparation: Bool) async throws {
        var seeded = RuntimeState()
        seeded.savedDisplayBrightness = 0.8
        seeded.displayRestoreRefused = true
        seeded.lowPowerSetByUs = true
        seeded.keptDisplayUnderLowPower = 0.8
        seeded.keptDisplayUnderLowPowerBoot = "boot A"
        seeded.keptDisplayReadLit = 0.8
        let original = try Store.makeEncoder().encode(seeded)
        let f = try ScriptFixture()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)
            f.destroy()
        }
        if failedPreparation {
            try original.write(to: f.state)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.state.path)
            let r = try f.run(f.backstop)
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)
            XCTAssertNotEqual(r.status, 0)
            XCTAssertFalse(f.calls().contains { $0.contains("lowpowermode") }, "\(f.calls())")
            XCTAssertEqual(try Data(contentsOf: f.state), original)
        }
        try original.write(to: h.home.paths.stateFile)
        try h.store.saveSession(Session(startedAt: h.clock.now.addingTimeInterval(-7200), endsAt: h.clock.now.addingTimeInterval(-60)))
        // Switched off by hand a moment ago: the panel is on its way back
        // to the user's 0.6.
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4

        let m = h.makeManager(bootSession: f.bootUUID)
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8, "a mode off a moment ago does not show the panel is back")
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, f.bootUUID)
        XCTAssertNil(sampler.last?.display, "0.4 is not the user's sample")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertTrue(logText().contains("low power mode, journaled as ours before the Mac last started, reads off; it may have gone off only a moment ago, with the panel still on its way back, so it is switched off as ours in this boot"), logText())

        await m.start(duration: 3600)
        h.display.brightness = 0.6
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.4), "the next close and open do not write over the user's 0.6: \(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(sampler.last?.display)
        _ = await m.end(reason: .user)

        let later = h.makeManager(bootSession: "boot C")
        let laterSampler = follow(later)
        await later.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(laterSampler.last?.display, 0.6)
        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
    }

}

/// Journals the app writes itself, through LidActions and the Store, over
/// an output device whose name or UID holds a backslash with "u0041" after
/// it. The app's encoder writes that backslash as \\, so the text holds
/// "\\u0041": a string with a backslash in it, not a \u escape. The
/// scripts read it as the app does and undo the rest of the journal, and
/// the app then restores the device.
@MainActor
final class AppEncodedJournalScriptTests: XCTestCase {
    private static let escapedName = "Headset \(backslash)u0041"
    private static let escapedUID = "Device-\(backslash)u0041"

    /// The journal the app writes as the lid closes with muting on, with
    /// sleep, Low Power Mode and a frozen process journaled beside it,
    /// and, with `record`, a kept display entry and its records from boot
    /// A. `legacy` drops the save ID, as builds before it wrote the entry.
    private func appJournal(uid: String, name: String, record: Bool, legacy: Bool, boot: String) async throws -> Data {
        let h = Harness()
        defer { h.home.destroy() }
        h.audio.connect(uid, name: name, volume: 0.6)
        let m = h.makeManager(bootSession: boot)
        m.config.muteOnLidClose = true
        m.config.darkenDisplayOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        await m.start(duration: 3600)
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let actions = LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { true }), audio: h.audio, display: h.display, keyboard: h.keyboard)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 1)
        var s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedAudioOutputs.map(\.deviceUID), [uid])
        XCTAssertEqual(s.savedAudioOutputs.map(\.name), [name])
        if legacy {
            s.savedAudioOutputs = s.savedAudioOutputs.map { SavedAudioOutput(deviceUID: $0.deviceUID, name: $0.name, volume: $0.volume, muted: $0.muted, saveID: nil) }
        }
        s.sleepDisabledByUs = true
        s.lowPowerSetByUs = true
        s.frozenProcesses = [FrozenProcess(pid: 4242, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: boot))]
        if record {
            s.savedDisplayBrightness = 0.8
            s.displayRestoreRefused = true
            s.keptDisplayUnderLowPower = 0.8
            s.keptDisplayUnderLowPowerBoot = "boot A"
            s.keptDisplayReadLit = 0.8
        }
        try h.store.saveState(s)
        let data = try Data(contentsOf: h.home.paths.stateFile)
        XCTAssertEqual(try Store.makeDecoder().decode(RuntimeState.self, from: data), s)
        return data
    }

    private static func variants() -> [(label: String, uid: String, name: String)] {
        [("name", "Device-A", escapedName), ("uid", escapedUID, "Headset A"), ("plain", "Device-A", "Headset A")]
    }

    /// Sleep, Low Power Mode and the frozen process are undone, the session
    /// goes, and the saved output stays in the journal as the app wrote it.
    private func checkUndone(_ f: ScriptFixture, before: Data, _ label: String) throws {
        XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), "\(label): \(f.calls())")
        XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(label): \(f.calls())")
        XCTAssertTrue(f.calls().contains { $0.hasPrefix("Insomnia --resume-frozen") && $0.contains("4242 1789388423 17") }, "\(label): \(f.calls())")
        XCTAssertFalse(f.log().contains("malformed"), "\(label): \(f.log())")
        let wrote = try Store.makeDecoder().decode(RuntimeState.self, from: before)
        let after = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: f.state))
        XCTAssertFalse(after.sleepDisabledByUs, label)
        XCTAssertFalse(after.lowPowerSetByUs, label)
        XCTAssertEqual(after.frozenProcesses, [], label)
        XCTAssertEqual(after.savedAudioOutputs, wrote.savedAudioOutputs, label)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, wrote.keptDisplayUnderLowPower == nil ? nil : f.bootUUID, label)
    }

}
