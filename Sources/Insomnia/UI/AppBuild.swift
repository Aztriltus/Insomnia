import Foundation

/// The version this build carries in its Info.plist:
/// `CFBundleShortVersionString` and `CFBundleVersion`. A binary run from
/// `swift run` has no Info.plist, so it has neither.
///
/// A nightly carries the version Info.plist has on main at that commit,
/// the same string as the stable release it follows or the one it
/// precedes, so the version alone does not tell a nightly apart. The
/// nightly's tag and zip name do (docs/releasing.md).
struct AppBuild: Equatable, Sendable {
    var version: String?
    var build: String?

    static let current = AppBuild(info: Bundle.main.infoDictionary ?? [:])

    init(version: String?, build: String?) {
        self.version = version
        self.build = build
    }

    init(info: [String: Any]) {
        version = Self.nonEmpty(info["CFBundleShortVersionString"])
        build = Self.nonEmpty(info["CFBundleVersion"])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// For Settings and the launch log: "0.1.0 (1)", or what is missing.
    var label: String {
        switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case (nil, _): "no version: this build has no Info.plist"
        }
    }
}

/// `major.minor.patch`, the form a stable tag `v<version>` and
/// `CFBundleShortVersionString` take. Anything else does not parse.
