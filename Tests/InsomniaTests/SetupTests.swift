import XCTest
@testable import Insomnia

/// First-launch setup and Uninstall: the sudoers text the app writes, the
/// commands and AppleScript that write it as root, and when the app must
/// move itself out of the disk image.
final class SetupTests: XCTestCase {
    func testRuleIsExactlyTheFourCommands() throws {
        let text = try XCTUnwrap(SudoersRule.text(user: "alex"))
        XCTAssertEqual(text, """
        # Installed by Insomnia. Exactly four commands, nothing else.
        alex ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        alex ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
        alex ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
        alex ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0

        """)
    }

    /// install.sh writes the same rule, so a Mac set up either way matches.
    func testRuleMatchesInstallScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/install.sh")
        let source = try String(contentsOf: script, encoding: .utf8)
        let body = try XCTUnwrap(source.components(separatedBy: "<<SUDO\n").dropFirst().first?.components(separatedBy: "\nSUDO\n").first)
        XCTAssertEqual(body.replacingOccurrences(of: "$USER", with: "alex") + "\n", SudoersRule.text(user: "alex"))
    }

    func testAccountNamesThatSudoersCouldReadAsSyntaxAreRefused() {
        for name in ["", "-k", "a b", "a,b", "a:b", "root ALL", "a\nb", "ålex", "%admin", "a#b"] {
            XCTAssertNil(SudoersRule.text(user: name), name)
        }
        for name in ["alex", "alex.ng", "a_b-c", "user1"] {
            XCTAssertNotNil(SudoersRule.text(user: name), name)
        }
    }

    func testInstallValidatesBeforeInstallingAndQuotesThePath() {
        XCTAssertEqual(
            SudoersRule.installCommand(staged: "/tmp/it's here"),
            "/usr/sbin/visudo -cf '/tmp/it'\\''s here' && /usr/bin/install -m 0440 -o root -g wheel '/tmp/it'\\''s here' /etc/sudoers.d/insomnia"
        )
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            AdminShell.script(command: #"echo "a\b""#, prompt: "Say \"hi\""),
            #"do shell script "echo \"a\\b\"" with prompt "Say \"hi\"" with administrator privileges"#
        )
    }

    func testDismissedPasswordDialogIsACancelNotAFailure() {
        XCTAssertEqual(AdminShell.outcome(status: 0, stderr: ""), .done)
        XCTAssertEqual(AdminShell.outcome(status: 1, stderr: "0:120: execution error: User canceled. (-128)\n"), .cancelled)
        XCTAssertEqual(AdminShell.outcome(status: 1, stderr: "visudo: parse error\n"), .failed("visudo: parse error"))
    }

    func testCopiesOnTheDiskImageMustMove() {
        XCTAssertTrue(InstallLocation.mustMove(bundlePath: "/Volumes/Insomnia 0.3.0/Insomnia.app", readOnlyVolume: false))
        XCTAssertTrue(InstallLocation.mustMove(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Insomnia.app", readOnlyVolume: false))
        XCTAssertTrue(InstallLocation.mustMove(bundlePath: "/Users/alex/Desktop/Insomnia.app", readOnlyVolume: true))
        XCTAssertFalse(InstallLocation.mustMove(bundlePath: "/Applications/Insomnia.app", readOnlyVolume: false))
        XCTAssertFalse(InstallLocation.mustMove(bundlePath: "/Users/alex/Applications/Insomnia.app", readOnlyVolume: false))
    }
}
