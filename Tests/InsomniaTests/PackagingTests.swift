import AppKit
import Foundation
import ImageIO
import XCTest
@testable import Insomnia

/// The checked-in icon artifacts and the bundle wiring that points at them,
/// and the recovery agent's verify-then-exec command line run against a
/// scratch signed bundle with the real codesign. These read the real files
/// and decode them; nothing here greps sources.
final class PackagingTests: XCTestCase {
    fileprivate static var repoRoot: URL {
        // .../Tests/InsomniaTests/PackagingTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var resources: URL { Self.repoRoot.appendingPathComponent("Resources", isDirectory: true) }

    // MARK: - The recovery agent's command line (real codesign, scratch bundle)

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-packaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A throwaway bundle laid out the way install.sh lays out Insomnia.app
    /// (Mach-O main executable, Info.plist, backstop.sh under
    /// Contents/Resources), ad-hoc signed afterwards so the resource seal
    /// covers the script. The executable is a copy of /usr/bin/true. Nothing
    /// here touches an installed app, a LaunchAgent or a keychain.
    private func makeSignedBundle(named name: String = "Insomnia") throws -> URL {
        let fm = FileManager.default
        let bundle = scratch.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: bundle.appendingPathComponent("Contents/MacOS/\(name)").path)
        let info: [String: Any] = [
            "CFBundleExecutable": name, "CFBundleIdentifier": "com.kgarg.insomnia.packaging-test",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let script = Paths.backstopScript(inBundle: bundle)
        try TestScripts.write("#!/bin/bash\nprintf 'ran %s\\n' \"$*\" >> \"$HOME/backstop.ran\"\n", to: script)
        let sign = try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        XCTAssertEqual(sign.status, 0, sign.output)
        return bundle
    }

    /// Runs the agent's command line exactly as launchd would, with HOME in
    /// the scratch tree so the refusal log lands there.
    private func runAgent(requirement: String, bundle: URL, home: URL) throws -> (status: Int32, output: String) {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return try run("/bin/sh", ["-c", LaunchdBackstop.agentProgram, "sh", requirement, bundle.path], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    }

    private func run(_ exe: String, _ args: [String], environment: [String: String]? = nil, currentDirectory: URL? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let childExit = ProcessExit(p)
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        childExit.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// What install.sh reads: the `designated =>` line of `codesign -d -r-`,
    /// without the "# " an implicit requirement carries.
    private func codesignDesignatedRequirement(of path: String) throws -> String {
        let r = try run("/usr/bin/codesign", ["-d", "-r-", path])
        let line = try XCTUnwrap(r.output.components(separatedBy: "\n").first { $0.contains("designated => ") }, r.output)
        return String(line[line.range(of: "designated => ")!.upperBound...])
    }

    /// The command line the LaunchAgent runs: an intact bundle runs its
    /// sealed backstop.sh; a bundle whose sealed script was edited, or one
    /// that is not the build the plist pins, runs nothing and logs why.
    func testAgentProgramRunsTheSealedBackstopOnlyWhileTheBundleSatisfiesItsRequirement() throws {
        let bundle = try makeSignedBundle()
        let requirement = try CodeRequirement.designated(ofCodeAt: bundle)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let ran = home.appendingPathComponent("backstop.ran")
        let log = home.appendingPathComponent("Library/Logs/Insomnia/insomnia.log")

        let intact = try runAgent(requirement: requirement, bundle: bundle, home: home)
        XCTAssertEqual(intact.status, 0, intact.output)
        XCTAssertEqual(try String(contentsOf: ran, encoding: .utf8), "ran \n", "the sealed script ran, with no arguments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "nothing to log while the bundle verifies")

        try FileManager.default.removeItem(at: ran)
        let script = Paths.backstopScript(inBundle: bundle)
        try (String(contentsOf: script, encoding: .utf8) + "echo tampered\n").write(to: script, atomically: true, encoding: .utf8)
        let edited = try runAgent(requirement: requirement, bundle: bundle, home: home)
        XCTAssertEqual(edited.status, 1, edited.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "an edited sealed script must not run")
        var logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains("[error] backstop agent: \(bundle.path) does not satisfy the pinned code requirement"), logged)
        XCTAssertTrue(logged.contains("sealed resource"), "codesign's reason is kept: \(logged)")
        XCTAssertEqual(logged.components(separatedBy: "\n").count, 2, "one line per refusal: \(logged)")

        // Another build: a fresh, intact bundle that the pinned requirement
        // (the first bundle's cdhash) does not describe.
        let other = try makeSignedBundle(named: "Other")
        XCTAssertNotEqual(try CodeRequirement.designated(ofCodeAt: other), requirement)
        let wrongBuild = try runAgent(requirement: requirement, bundle: other, home: home)
        XCTAssertEqual(wrongBuild.status, 1, wrongBuild.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path))
        logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains("\(other.path) does not satisfy"), logged)
        XCTAssertTrue(logged.contains("failed to satisfy specified code requirement"), logged)

        // Its own requirement still runs it.
        let own = try runAgent(requirement: try CodeRequirement.designated(ofCodeAt: other), bundle: other, home: home)
        XCTAssertEqual(own.status, 0, own.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran.path))
    }

    // MARK: - What arm() pins (CodeRequirement.pin, real codesign)

    /// Reading a requirement does not validate the bundle: a sealed script
    /// edited after signing still reads its old requirement, and an agent
    /// pinned to it refuses every run. pin() runs the agent's check as well
    /// and refuses the bundle, so arm() fails with the reason.
    func testPinRefusesABundleWhoseSealedScriptWasEditedAfterSigning() throws {
        let bundle = try makeSignedBundle()
        let requirement = try CodeRequirement.designated(ofCodeAt: bundle)
        // The test host is not an app bundle, so pin() takes the development
        // path: the requirement comes from the bundle on disk.
        XCTAssertEqual(try CodeRequirement.pin(bundle: bundle), requirement)

        let script = Paths.backstopScript(inBundle: bundle)
        try (String(contentsOf: script, encoding: .utf8) + "echo tampered\n").write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(try CodeRequirement.designated(ofCodeAt: bundle), requirement, "the requirement alone still reads")
        XCTAssertThrowsError(try CodeRequirement.verify(codeAt: bundle, satisfies: requirement)) { error in
            XCTAssertTrue(error.localizedDescription.contains(securityMessage(errSecCSBadResource)), error.localizedDescription)
        }
        XCTAssertThrowsError(try CodeRequirement.pin(bundle: bundle)) { error in
            XCTAssertTrue(error.localizedDescription.contains(bundle.path), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(securityMessage(errSecCSBadResource)), error.localizedDescription)
        }
    }

    // MARK: - scripts/build-app.sh (patched copy: fake swift, real or recording codesign)

    /// A private copy of build-app.sh whose `swift` is a fake that reports a
    /// prepared binary directory (a copy of /usr/bin/true, so the real
    /// codesign can sign the result) and whose `codesign` is either the real
    /// tool or a recorder. Its `rm`, `mkdir`, `cp` and `chmod` record each
    /// call and then run the real tool. ROOT is a scratch checkout with the
    /// real Info.plist, icon and backstop.sh copied in. The fake's `build`
    /// exits with the status in `swiftBuildStatus` (0 when there is none),
    /// and `-print-target-info` reports `fakeToolchainLib` as its resources.
    private func patchedBuildApp(recordingCodesign: Bool) throws -> (script: URL, calls: URL) {
        let fm = FileManager.default
        let checkout = scratch.appendingPathComponent("checkout", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        let binroot = scratch.appendingPathComponent("binroot", isDirectory: true)
        let calls = scratch.appendingPathComponent("calls.log")
        for dir in [checkout.appendingPathComponent("scripts"), checkout.appendingPathComponent("Resources"), bin, binroot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for name in ["Info.plist", "AppIcon.icns"] {
            try fm.copyItem(at: Self.repoRoot.appendingPathComponent("Resources/\(name)"), to: checkout.appendingPathComponent("Resources/\(name)"))
        }
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("scripts/backstop.sh"), to: checkout.appendingPathComponent("scripts/backstop.sh"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: binroot.appendingPathComponent("Insomnia").path)

        func fake(_ name: String, _ body: String) throws -> URL {
            let url = bin.appendingPathComponent(name)
            try TestScripts.write("#!/bin/bash\n" + body, to: url)
            return url
        }
        let swift = try fake("swift", """
        printf 'swift %s\\n' "$*" >> "\(calls.path)"
        for a in "$@"; do [[ "$a" == --show-bin-path ]] && { echo "\(binroot.path)"; exit 0; }; done
        if [[ "${1:-}" == -print-target-info ]]; then
          printf '{\\n  "paths": {\\n    "runtimeResourcePath": "%s"\\n  }\\n}\\n' "\(fakeToolchainLib.path)"
          exit 0
        fi
        status="$(cat "\(swiftBuildStatus.path)" 2>/dev/null || echo 0)"
        if [[ "$status" != 0 ]]; then
          echo "error: 'checkout': Invalid manifest" >&2
          echo "Package.swift:7:17: error: reference to member 'v26' cannot be resolved without a contextual type" >&2
        fi
        exit "$status"
        """)
        let codesign = recordingCodesign
            ? try fake("codesign", """
              printf 'codesign %s\\n' "$*" >> "\(calls.path)"
              exit 0
              """)
            : URL(fileURLWithPath: "/usr/bin/codesign")

        var tools = ["SWIFT": swift.path, "CODESIGN": codesign.path]
        for (name, real) in ["RM": "/bin/rm", "MKDIR": "/bin/mkdir", "CP": "/bin/cp", "CHMOD": "/bin/chmod"] {
            tools[name] = try fake("recorded-\(name.lowercased())", """
            printf '\(name.lowercased()) %s\\n' "$*" >> "\(calls.path)"
            exec \(real) "$@"
            """).path
        }

        var lines = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8).components(separatedBy: "\n")
        for (name, value) in tools {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            XCTAssertEqual(hits.count, 1, "build-app.sh must have exactly one \(name)= line")
            lines[hits[0]] = "\(name)='\(value)'"
        }
        let script = checkout.appendingPathComponent("scripts/build-app.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, calls)
    }

    // MARK: build-app.sh after a failed build: package interfaces an older Swift left behind

    /// The fake swift's resource folder. The space stands in for a toolchain
    /// in an app such as "Xcode-beta 2.app" and checks the quoting of the
    /// printed command.
    private var fakeToolchainLib: URL { scratch.appendingPathComponent("Xcode beta.app/usr/lib/swift", isDirectory: true) }
    private var swiftBuildStatus: URL { scratch.appendingPathComponent("swift-build.status") }
    private static let currentSwift = "Apple Swift version 6.3.3 effective-5.10 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"
    private static let olderSwift = "Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)"

    /// One interface file of a SwiftPM module in the fake toolchain, such
    /// as `writeInterface("ManifestAPI/PackageDescription", private: true,
    /// writer: olderSwift)`, with the header the compiler writes.
    @discardableResult
    private func writeInterface(_ module: String, private isPrivate: Bool, writer: String) throws -> URL {
        let dir = fakeToolchainLib.appendingPathComponent("pm/\(module).swiftmodule", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("arm64-apple-macos\(isPrivate ? ".private" : "").swiftinterface")
        try "// swift-interface-format-version: 1.0\n// swift-compiler-version: \(writer)\nimport Swift\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Regeneration

    // MARK: - Helpers

    private func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func elementPayload(_ data: Data, type wanted: String) -> Data? {
        var cursor = 8
        while cursor + 8 <= data.count {
            let type = String(decoding: data[cursor..<cursor + 4], as: UTF8.self)
            let length = Int(bigEndian32(data, at: cursor + 4))
            guard length >= 8, length <= data.count - cursor else { return nil }
            if type == wanted { return data[(cursor + 8)..<(cursor + length)] }
            cursor += length
        }
        return nil
    }

    /// Straight RGBA at integer pixels, (0,0) top-left.
    private struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init(_ image: CGImage) {
            let w = image.width
            let h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(
                    data: buffer.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            data = bytes
        }

        func alpha(_ x: Int, _ y: Int) -> Double {
            Double(data[(y * width + x) * 4 + 3]) / 255
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let o = (y * width + x) * 4
            let a = max(Double(data[o + 3]), 1)
            let r = Double(data[o]) / a, g = Double(data[o + 1]) / a, b = Double(data[o + 2]) / a
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
    }
}

/// A throwaway tree for scripts/generate-app-icon.sh:
///   root/scripts/generate-app-icon.sh   copy with SWIFTC, ICONUTIL and MV patched to the fakes
///   root/Resources, root/docs/assets    the three assets, holding "old ..."
///   root/bin                            fake swiftc, iconutil and mv
///   root/tmp                            TMPDIR for the script's mktemp
/// The fake swiftc writes a fake generator that writes "new png", one
/// iconset member, and "new svg" through a file beside the target the way
/// the real generator's atomic String write does; the fake iconutil writes
/// "new icns", or fails while root/iconutil-fails exists. The fake mv runs
/// /bin/mv unless an argument matches a pattern in root/mv-fails.
private struct IconScriptFixture {
    let root: URL
    var script: URL { root.appendingPathComponent("scripts/generate-app-icon.sh") }
    var resources: URL { root.appendingPathComponent("Resources", isDirectory: true) }
    var assets: URL { root.appendingPathComponent("docs/assets", isDirectory: true) }
    var png: URL { resources.appendingPathComponent("AppIcon-1024.png") }
    var icns: URL { resources.appendingPathComponent("AppIcon.icns") }
    var svg: URL { assets.appendingPathComponent("eye-open.svg") }
    private var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    private var assetFiles: [URL] { [png, icns, svg] }
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-script-\(UUID().uuidString)", isDirectory: true)
        for dir in ["scripts", "Resources", "docs/assets", "bin", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        for (file, text) in zip(assetFiles, ["old png", "old icns", "old svg"]) {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let source = PackagingTests.repoRoot.appendingPathComponent("scripts/generate-app-icon.sh")
        var text = try String(contentsOf: source, encoding: .utf8)
        for (name, tool) in [("SWIFTC", "/usr/bin/swiftc"), ("ICONUTIL", "/usr/bin/iconutil"), ("MV", "/bin/mv")] {
            let line = "\(name)=\(tool)"
            guard text.components(separatedBy: "\n").filter({ $0 == line }).count == 1 else {
                throw NSError(domain: "IconScriptFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected one '\(line)' line"])
            }
            let fake = bin.appendingPathComponent(URL(fileURLWithPath: tool).lastPathComponent)
            text = text.replacingOccurrences(of: line, with: "\(name)='\(fake.path)'")
        }
        try text.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // The generator the fake swiftc "compiles": its own file, so it is
        // linted like the fakes, copied to swiftc's -o path.
        let generator = root.appendingPathComponent("icon-generator")
        try TestScripts.write(#"""
        #!/bin/bash
        set -e
        while [ $# -gt 0 ]; do
          case "$1" in
            --png) printf 'new png' > "$2" ;;
            --iconset) mkdir -p "$2"; printf 'member' > "$2/icon_16x16.png" ;;
            --svg) printf 'new svg' > "$2.tmp.$$" || exit 1; mv -f "$2.tmp.$$" "$2" ;;
            *) exit 2 ;;
          esac
          shift 2
        done

        """#, to: generator, executable: false)
        try writeFake("swiftc", """
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift; fi
          shift
        done
        cat '\(generator.path)' > "$out"
        chmod +x "$out"
        """)
        try writeFake("iconutil", """
        [ -e '\(root.appendingPathComponent("iconutil-fails").path)' ] && exit 1
        [ "$1" = -c ] && [ "$2" = icns ] && [ -d "$3" ] && [ "$4" = -o ] || exit 2
        printf 'new icns' > "$5"
        """)
        try writeFake("mv", """
        flag='\(root.appendingPathComponent("mv-fails").path)'
        if [ -e "$flag" ]; then
          while IFS= read -r pattern; do
            for arg in "$@"; do
              # The patterns are globs, so they stay unquoted.
              # shellcheck disable=SC2254
              case "$arg" in $pattern) echo "mv: refusing $arg" >&2; exit 1 ;; esac
            done
          done < "$flag"
        fi
        exec /bin/mv "$@"
        """)
    }

    private func writeFake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try TestScripts.write("#!/bin/bash\n" + body + "\n", to: url)
    }

    func setWritable(_ dir: URL, _ writable: Bool) throws {
        try fm.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: dir.path)
    }

    func failIconutil(_ fail: Bool) {
        let flag = root.appendingPathComponent("iconutil-fails")
        if fail { fm.createFile(atPath: flag.path, contents: Data()) } else { try? fm.removeItem(at: flag) }
    }

    /// Makes the fake mv fail when an argument matches the shell `pattern`,
    /// or run /bin/mv for every call when `pattern` is nil.
    func failMoves(from pattern: String?) throws {
        let flag = root.appendingPathComponent("mv-fails")
        if let pattern {
            try (pattern + "\n").write(to: flag, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: flag.path) {
            try fm.removeItem(at: flag)
        }
    }

    /// Sets or clears the immutable flag that Finder's Locked checkbox sets.
    /// Renaming another file over a locked one fails with EPERM.
    func lock(_ file: URL, _ locked: Bool) throws {
        try fm.setAttributes([.immutable: locked], ofItemAtPath: file.path)
    }

    /// The PNG, ICNS and SVG, in that order, with "missing" for one that
    /// does not exist.
    func contents() throws -> [String] {
        try assetFiles.map { fm.fileExists(atPath: $0.path) ? try String(contentsOf: $0, encoding: .utf8) : "missing" }
    }

    /// Anything in the two asset folders besides the three assets.
    func leftovers() throws -> [String] {
        let names = Set(assetFiles.map(\.lastPathComponent))
        return try [resources, assets].flatMap { try fm.contentsOfDirectory(atPath: $0.path) }.filter { !names.contains($0) }.sorted()
    }

    func run() throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.appendingPathComponent("tmp").path]
        p.currentDirectoryURL = root
        let errURL = root.appendingPathComponent("stderr.\(UUID().uuidString)")
        fm.createFile(atPath: errURL.path, contents: nil)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return (p.terminationStatus, (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    func remove() {
        try? setWritable(assets, true)
        for dir in [resources, assets] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try? lock(dir.appendingPathComponent(name), false)
            }
        }
        try? fm.removeItem(at: root)
    }
}
