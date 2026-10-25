import AppKit
import Foundation

/// An app the user installed, as Settings shows it: icon and name.
struct InstalledApp: Equatable, Hashable, Sendable, Identifiable {
    let bundleID: String
    let name: String
    let path: String
    var id: String { bundleID }
}

/// Which app bundles count as "installed by the user" (redesign spec,
/// section 2). The filter is pure over `Record`s so it can be tested
/// without a disk; `scan()` reads the real folders and running apps.
enum InstalledApps {
    /// Where a bundle was found. When two copies share a bundle id, the
    /// earlier source wins.
    enum Source: Int, Comparable, Sendable {
        /// The system `/Applications`.
        case systemApplications
        /// `~/Applications`.
        case userApplications
        /// Where Unity Hub and the Epic Games Launcher put their editors.
        case editorFolder
        /// Where macOS last saw an app that's already in one of the lists.
        case saved
        /// A Dock app that's running now, wherever it lives.
        case running

        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    struct Record: Equatable, Sendable {
        var bundleID: String?
        var name: String
        var path: String
        var backgroundOnly: Bool
        var source: Source
        /// For the Applications folders: 1 for an app directly in one, 2 one
        /// folder below it. Other sources don't limit it.
        var depth: Int = 1
    }

    /// Editor folders, relative to `/Applications` and `/Users/Shared`.
    /// Unity Hub: `Unity/Hub/Editor/<version>/Unity.app`. Epic Games
    /// Launcher: `Epic Games/UE_<version>/Engine/Binaries/Mac/`.
    static let unityEditors = "Unity/Hub/Editor"
    static let unrealEngines = "Epic Games"
    static let unrealEditorNames: Set<String> = ["UnrealEditor.app", "UE4Editor.app"]

    static func filter(_ records: [Record], selfBundleID: String) -> [InstalledApp] {
        var byID: [String: Record] = [:]
        for r in records {
            guard let id = r.bundleID, !id.isEmpty else { continue }
            guard !id.hasPrefix("com.apple."), !r.path.hasPrefix("/System/") else { continue }
            guard id != selfBundleID, !r.backgroundOnly else { continue }
            if r.source <= .userApplications, !(1...2).contains(r.depth) { continue }
            // Helpers inside another app, and copies macOS runs from a
            // temporary folder (an app opened from Downloads).
            guard !isNested(r.path), !isTemporary(r.path) else { continue }
            if let existing = byID[id], existing.source <= r.source { continue }
            byID[id] = r
        }
        return byID.values
            .map { InstalledApp(bundleID: $0.bundleID!, name: $0.name, path: $0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A bundle inside another bundle, such as `Claude.app/Contents/Frameworks/Claude Helper.app`.
    static func isNested(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.contains(".app/") || parent.hasSuffix(".app")
    }

    static func isTemporary(_ path: String) -> Bool {
        path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
    }

    /// Bundles in `/Applications` and `~/Applications` up to two folders
    /// deep, the Unity and Unreal editors, the saved ids macOS can find,
    /// and the Dock apps running now.
    @MainActor
    static func scan(saved: [String] = [], selfBundleID: String = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier) -> [InstalledApp] {
        let fm = FileManager.default
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var records = bundles(in: applications, depth: 1, source: .systemApplications)
        records += bundles(in: fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true), depth: 1, source: .userApplications)
        records += editors(applications: applications, shared: URL(fileURLWithPath: "/Users/Shared", isDirectory: true))
        for id in saved {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                records += [record(at: url, source: .saved)]
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL, url.pathExtension == "app" {
                records += [record(at: url, source: .running)]
            }
        }
        return filter(records, selfBundleID: selfBundleID)
    }

    private static func editors(applications: URL, shared: URL) -> [Record] {
        var out: [Record] = []
        // Newest version first, so its copy is the one shown.
        for version in subfolders(of: applications.appendingPathComponent(unityEditors)).reversed() {
            let app = version.appendingPathComponent("Unity.app")
            if FileManager.default.fileExists(atPath: app.path) {
                out.append(record(at: app, source: .editorFolder))
            }
        }
        for engine in subfolders(of: shared.appendingPathComponent(unrealEngines)).reversed() {
            let binaries = engine.appendingPathComponent("Engine/Binaries/Mac", isDirectory: true)
            for name in unrealEditorNames.sorted() {
                let app = binaries.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: app.path) {
                    out.append(record(at: app, source: .editorFolder))
                }
            }
        }
        return out
    }

    /// Folders in `folder`, sorted by name the way Finder sorts versions.
    private static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func bundles(in folder: URL, depth: Int, source: Source) -> [Record] {
        guard depth <= 2,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var out: [Record] = []
        for url in items {
            if url.pathExtension == "app" {
                out.append(record(at: url, source: source, depth: depth))
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out += bundles(in: url, depth: depth + 1, source: source)
            }
        }
        return out
    }

    private static func record(at url: URL, source: Source, depth: Int = 1) -> Record {
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return Record(
            bundleID: info["CFBundleIdentifier"] as? String,
            name: name,
            path: url.path,
            backgroundOnly: (info["LSBackgroundOnly"] as? Bool) ?? false,
            source: source,
            depth: depth
        )
    }

    /// The app's icon, from its bundle on disk.
    @MainActor
    static func icon(for app: InstalledApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }
}
