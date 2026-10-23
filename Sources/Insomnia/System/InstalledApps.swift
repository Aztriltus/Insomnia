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
/// without a disk; `scan()` reads the real folders.
enum InstalledApps {
    struct Record: Equatable, Sendable {
        var bundleID: String?
        var name: String
        var path: String
        var backgroundOnly: Bool
        /// 1 for an app directly in an Applications folder, 2 one folder
        /// below it.
        var depth: Int
        /// From the system `/Applications` rather than `~/Applications`.
        var inSystemApplications: Bool
    }

    static func filter(_ records: [Record], selfBundleID: String) -> [InstalledApp] {
        var byID: [String: Record] = [:]
        for r in records {
            guard let id = r.bundleID, !id.isEmpty else { continue }
            guard !id.hasPrefix("com.apple."), !r.path.hasPrefix("/System/") else { continue }
            guard id != selfBundleID, !r.backgroundOnly, (1...2).contains(r.depth) else { continue }
            // The copy in /Applications wins over one in ~/Applications;
            // otherwise the first one found stays.
            if let existing = byID[id], existing.inSystemApplications || !r.inSystemApplications { continue }
            byID[id] = r
        }
        return byID.values
            .map { InstalledApp(bundleID: $0.bundleID!, name: $0.name, path: $0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundles in `/Applications` and `~/Applications`, up to two folders deep.
    static func scan(selfBundleID: String = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier) -> [InstalledApp] {
        let fm = FileManager.default
        let roots: [(URL, Bool)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), true),
            (fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true), false),
        ]
        var records: [Record] = []
        for (root, system) in roots {
            records += bundles(in: root, depth: 1, system: system)
        }
        return filter(records, selfBundleID: selfBundleID)
    }

    private static func bundles(in folder: URL, depth: Int, system: Bool) -> [Record] {
        guard depth <= 2,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var out: [Record] = []
        for url in items {
            if url.pathExtension == "app" {
                let info = Bundle(url: url)?.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(Record(
                    bundleID: info["CFBundleIdentifier"] as? String,
                    name: name,
                    path: url.path,
                    backgroundOnly: (info["LSBackgroundOnly"] as? Bool) ?? false,
                    depth: depth,
                    inSystemApplications: system
                ))
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out += bundles(in: url, depth: depth + 1, system: system)
            }
        }
        return out
    }

    /// The app's icon, from its bundle on disk.
    @MainActor
    static func icon(for app: InstalledApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }
}
