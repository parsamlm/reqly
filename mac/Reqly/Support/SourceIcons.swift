import AppKit
import ReqlyModel

/// The icons of the apps and tools that send traffic, loaded once for each.
@MainActor
enum SourceIcons {
    private static var icons: [String: NSImage] = [:]
    /// Where the Mac keeps its own copy of an app from a phone, by the app's ID and name. `nil`
    /// when it has none.
    private static var macCopies: [String: String?] = [:]

    /// The app's icon, or the system's icon for a command-line tool. An app on a phone has no
    /// icon here, unless this Mac has the same app: then it's that one's.
    static func icon(for source: Source?) -> NSImage? {
        guard let source, let path = source.path ?? macCopy(of: source) else { return nil }
        if let icon = icons[path] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// This Mac's copy of an app from a phone: the app with the same ID, as an iPhone app
    /// installed on the Mac has, or with the same name, as Safari, Mail or Weather have.
    private static func macCopy(of source: Source) -> String? {
        let key = "\(source.bundleID ?? "")/\(source.name)"
        if let known = macCopies[key] {
            return known
        }
        var path = source.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }?
            .path(percentEncoded: false)
        if path == nil, !source.name.contains("/") {
            let folders = [
                "/Applications", "/System/Applications", "/System/Applications/Utilities",
                URL.homeDirectory.appending(path: "Applications").path(percentEncoded: false),
            ]
            path = folders.lazy.map { "\($0)/\(source.name).app" }.first { FileManager.default.fileExists(atPath: $0) }
        }
        macCopies[key] = path
        return path
    }
}
