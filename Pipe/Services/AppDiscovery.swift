import AppKit
import Foundation

/// An installed application, identified by its bundle identifier (stable), never by executable name.
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }
    var path: String { url.path }

    /// Icons are read from disk once and cached: SwiftUI re-renders rows on every animation
    /// frame, and NSWorkspace.icon(forFile:) hits the disk each call.
    var icon: NSImage { IconCache.icon(for: url) }
}

enum IconCache {
    private static var cache: [URL: NSImage] = [:]
    static func icon(for url: URL) -> NSImage {
        if let i = cache[url] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 64, height: 64)
        cache[url] = i
        return i
    }
}

enum AppDiscovery {
    static var searchDirectories: [URL] {
        let fm = FileManager.default
        var dirs = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), URL(fileURLWithPath: "/System/Applications"),
                    URL(fileURLWithPath: "/System/Applications/Utilities")]
        dirs += fm.urls(for: .applicationDirectory, in: .userDomainMask)
        if let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications") as URL?, !dirs.contains(home) { dirs.append(home) }
        return dirs
    }

    /// Scan the standard locations. Runs off the main thread; a few hundred bundles take well under a second.
    static func scan() async -> [InstalledApp] {
        await Task.detached(priority: .userInitiated) {
            var seen: [String: InstalledApp] = [:]
            let fm = FileManager.default
            for dir in searchDirectories {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for url in items where url.pathExtension == "app" {
                    if let app = load(url), seen[app.bundleID] == nil { seen[app.bundleID] = app }
                }
            }
            return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    static func load(_ url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: id, name: name, url: url.standardizedFileURL)
    }
}
