import CGtk
import Foundation
import GtkBinding
import LinuxApps
import ReqlyModel

/// An app's icon, as its desktop entry's `Icon=` names it.
enum AppIcon: Hashable, Sendable {
    /// A name in your icon theme, such as `org.gnome.Calculator`, which hicolor or your theme has.
    case themed(String)
    /// An image file, by its path, as snaps' entries name theirs.
    case file(String)
    /// A program's, for command-line tools and apps with no entry.
    case generic

    /// A program's icon, in the themes Ubuntu and Debian have, Adwaita among them.
    static let genericName = "application-x-executable"

    /// The icon `Icon=` names: a file when it's an absolute path, and otherwise a name in your icon
    /// theme, without the extension some entries add, such as `.png`.
    init(entryIcon: String) {
        if entryIcon.hasPrefix("/") {
            self = .file(entryIcon)
        } else if let dot = entryIcon.lastIndex(of: "."),
            ["png", "svg", "svgz", "xpm"].contains(entryIcon[entryIcon.index(after: dot)...].lowercased())
        {
            self = .themed(String(entryIcon[..<dot]))
        } else {
            self = .themed(entryIcon)
        }
    }

    /// The icon of the app that sent a request: its desktop entry's, found by the desktop ID the
    /// app was credited with, or a snap's by its name. An app with no entry here may still have
    /// its icon in the theme under its ID, as a Flatpak's is. A tool, which has no ID, gets a
    /// program's icon, and so does an entry whose image file is gone.
    static func find(for source: Source, in entries: DesktopEntries) -> AppIcon {
        guard let id = source.bundleID else { return .generic }
        guard let entry = entries.entry(id: id) ?? entries.entries(ofSnap: id).first else {
            return id.contains(".") ? .themed(id) : .generic
        }
        guard let icon = entry.icon.map(AppIcon.init(entryIcon:)) else { return .generic }
        if case .file(let path) = icon, !FileManager.default.fileExists(atPath: path) {
            return .generic
        }
        return icon
    }
}

/// Each app's icon for the list, found once per app: its desktop entry is looked up on a thread of
/// its own, since the first lookup reads every entry on the computer, and the list hears when it's
/// found. The icons are GIcons, which GTK draws from your icon theme, at the list's size.
@MainActor
final class AppIcons {
    /// The desktop entries on this computer: yours, the system's, and Flatpak's and snapd's, which
    /// the session's app lookup reads too.
    let entries: DesktopEntries
    /// Runs once an app's icon is found, with its key.
    var onFound: (@MainActor (String) -> Void)?
    private var found: [String: AppIcon] = [:]
    private var looking: Set<String> = []
    /// Each icon's GIcon, made once and kept for as long as Reqly runs.
    private var made: [AppIcon: OpaquePointer] = [:]

    init(entries: DesktopEntries = .shared) {
        self.entries = entries
    }

    /// What tells apps apart for their icons: the desktop ID, or a tool's program, or its name.
    static func key(of source: Source) -> String {
        source.bundleID ?? source.path ?? source.name
    }

    /// The icon to show for an app, or `nil` while it's being found, after which ``onFound`` runs.
    func icon(for source: Source) -> OpaquePointer? {
        let key = Self.key(of: source)
        if let icon = found[key] {
            return gicon(icon)
        }
        guard source.bundleID != nil else {
            found[key] = .generic
            return gicon(.generic)
        }
        guard looking.insert(key).inserted else { return nil }
        let entries = entries
        Task {
            let icon = await onOwnThread { AppIcon.find(for: source, in: entries) }
            looking.remove(key)
            found[key] = icon
            onFound?(key)
        }
        return nil
    }

    /// The GIcon that shows `icon`: a themed one falls back to a program's when your theme doesn't
    /// have it.
    func gicon(_ icon: AppIcon) -> OpaquePointer {
        if let gicon = made[icon] {
            return gicon
        }
        let gicon: OpaquePointer
        switch icon {
        case .themed(let name):
            gicon = g_themed_icon_new(name)
            g_themed_icon_append_name(cast(gicon), AppIcon.genericName)
        case .file(let path):
            let file = g_file_new_for_path(path)
            gicon = g_file_icon_new(file)
            g_object_unref(raw(file))
        case .generic:
            gicon = g_themed_icon_new(AppIcon.genericName)
        }
        made[icon] = gicon
        return gicon
    }
}
