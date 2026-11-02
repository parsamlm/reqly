import CGtk
import Foundation
import GtkBinding

/// The few symbolic icons Reqly shows that not every icon theme has: the lock in the list's
/// Status column and on Settings › HTTPS, the arrows of the list's empty page, and Settings ›
/// General's gear. Debian's Cinnamon uses the `gnome` theme, which has none of them, so GTK would
/// draw its broken-image picture. Reqly writes its own, simple ones to a folder of its own, which
/// GTK looks in after every theme, so your theme's own still come first.
enum Icons {
    /// Each icon's name and its SVG, drawn on a 16-pixel grid in one color, which GTK paints in
    /// the text's color, as with any symbolic icon.
    static let symbolic: [(name: String, svg: String)] = [
        (
            "channel-secure-symbolic",
            svg(
                #"<path d="M8 1a4 4 0 0 0-4 4v2H3v8h10V7h-1V5a4 4 0 0 0-4-4zm0 2a2 2 0 0 1 2 2v2H6V5a2 2 0 0 1 2-2z"/>"#
            )
        ),
        ("network-transmit-receive-symbolic", svg(#"<path d="M4 1 .5 5H3v10h2V5h2.5zm8 14 3.5-4H13V1h-2v10H8.5z"/>"#)),
        (
            "preferences-system-symbolic",
            svg(
                #"<path fill-rule="evenodd" d="M8 3a5 5 0 1 0 0 10A5 5 0 0 0 8 3zm0 3a2 2 0 1 1 0 4 2 2 0 0 1 0-4z"/>"#
                    + [0, 45, 90, 135].map {
                        #"<path transform="rotate(\#($0) 8 8)" d="M6.75 1h2.5v3h-2.5zm0 11h2.5v3h-2.5z"/>"#
                    }.joined())
        ),
    ]

    /// Writes the icons to their folder and adds it to the icon theme's search path. Without a
    /// display, or a folder to write in, the theme's own icons are all there is.
    @MainActor
    static func install(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let display = gdk_display_get_default(), let theme = gtk_icon_theme_get_for_display(display),
            let folder = folder(environment: environment)
        else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for icon in symbolic {
                let file = folder.appending(path: "\(icon.name).svg")
                let data = Data(icon.svg.utf8)
                // Another Reqly, such as a test run, may be reading them.
                if (try? Data(contentsOf: file)) != data {
                    try data.write(to: file, options: .atomic)
                }
            }
        } catch {
            AppLog.write("couldn't write Reqly's icons to \(folder.path): \(error.localizedDescription)")
            return
        }
        // Icons right in a folder on the search path, in no theme, come after every theme.
        gtk_icon_theme_add_search_path(theme, folder.path)
    }

    /// The icons' folder: Reqly's in `XDG_RUNTIME_DIR`, which only you can open, or in your cache
    /// folder.
    static func folder(environment: [String: String]) -> URL? {
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            return URL(filePath: runtime, directoryHint: .isDirectory).appending(path: "net.reqly.Reqly/icons")
        }
        let cache =
            environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? environment["HOME"].map { $0 + "/.cache" }
        return cache.map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: "reqly/icons") }
    }

    private static func svg(_ shapes: String) -> String {
        ##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><g fill="#222222">"##
            + shapes + "</g></svg>\n"
    }
}
