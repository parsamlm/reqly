import CGtk
import GtkBinding
import ReqlyModel

/// The list's colors, on top of libadwaita's: the status dots, in the design guidelines' colors
/// for each class, Reqly teal for 2xx, and red with the warning for a request that failed; and a
/// color mark, a stripe at the row's leading edge and a tint behind it. Each has a light and a
/// dark version, and a version of each for high contrast. libadwaita 1.5 has no CSS media query
/// for either, so each set is a provider of its own, swapped in as the style manager changes.
@MainActor
enum ListStyles {
    /// One set of colors: the dots' by status class, a failure's, the marks' and how strong a
    /// mark's tint is.
    struct Palette {
        var statuses: [StatusClass: String]
        var failed: String
        var marks: [MarkColor: String]
        var tint: Double
    }

    static let light = Palette(
        statuses: [
            .informational: "#77767b", .success: "#0B9A83", .redirection: "#1c71d8", .clientError: "#e66100",
            .serverError: "#c01c28",
        ], failed: "#c01c28",
        marks: [
            .red: "#e01b24", .orange: "#ff7800", .yellow: "#f5c211", .green: "#2ec27e", .blue: "#3584e4",
            .purple: "#9141ac", .gray: "#77767b",
        ], tint: 0.10)
    static let dark = Palette(
        statuses: [
            .informational: "#9a9996", .success: "#3FDDC0", .redirection: "#62a0ea", .clientError: "#ffa348",
            .serverError: "#f66151",
        ], failed: "#ff7b63",
        marks: [
            .red: "#f66151", .orange: "#ffa348", .yellow: "#f8e45c", .green: "#57e389", .blue: "#62a0ea",
            .purple: "#c061cb", .gray: "#9a9996",
        ], tint: 0.14)
    static let lightContrast = Palette(
        statuses: [
            .informational: "#5e5c64", .success: "#056B5A", .redirection: "#1a5fb4", .clientError: "#c64600",
            .serverError: "#a51d2d",
        ], failed: "#a51d2d",
        marks: [
            .red: "#a51d2d", .orange: "#c64600", .yellow: "#e5a50a", .green: "#26a269", .blue: "#1a5fb4",
            .purple: "#613583", .gray: "#5e5c64",
        ], tint: 0.16)
    static let darkContrast = Palette(
        statuses: [
            .informational: "#deddda", .success: "#71F2D8", .redirection: "#99c1f1", .clientError: "#ffbe6f",
            .serverError: "#ff938a",
        ], failed: "#ff938a",
        marks: [
            .red: "#ff938a", .orange: "#ffbe6f", .yellow: "#f9f06b", .green: "#8ff0a4", .blue: "#99c1f1",
            .purple: "#dc8add", .gray: "#deddda",
        ], tint: 0.18)

    /// The style class a row has while it's marked with `color`, beside `marked`.
    static func markClass(_ color: MarkColor) -> String {
        "mark-\(color.rawValue)"
    }

    private static let shared = """
        .request-dot { min-width: 8px; min-height: 8px; margin: 0 4px; border-radius: 4px; }
        .request-dot.waiting { min-width: 6px; min-height: 6px; margin: 0 4px; border: 1px dotted alpha(currentColor, 0.55); }
        .request-symbol.paused { color: @accent_color; }
        columnview.requests > listview > row.marked:selected { background-image: none; }
        """

    /// The colors of `palette`, as CSS.
    static func css(_ palette: Palette) -> String {
        var css = ""
        for (status, color) in palette.statuses.sorted(by: { $0.key.styleClass < $1.key.styleClass }) {
            // The dot's color is its text's too, which the self-check reads.
            css += ".request-dot.\(status.styleClass) { background-color: \(color); color: \(color); }\n"
        }
        css += ".request-symbol.failed { color: \(palette.failed); }\n"
        for color in MarkColor.allCases {
            let value = palette.marks[color] ?? "#77767b"
            let row = "columnview.requests > listview > row.marked.\(markClass(color))"
            let tint = "alpha(\(value), \(palette.tint))"
            css += "\(row) { background-image: linear-gradient(\(tint), \(tint)); }\n"
            css += "\(row):dir(ltr) { box-shadow: inset 4px 0 \(value); }\n"
            css += "\(row):dir(rtl) { box-shadow: inset -4px 0 \(value); }\n"
        }
        return css
    }

    private static var isInstalled = false

    /// Adds the list's styles to the display, once, and follows the style manager's dark and
    /// high-contrast styles.
    static func install() {
        guard !isInstalled, let display = gdk_display_get_default() else { return }
        isInstalled = true
        func provider(_ css: String) -> UnsafeMutablePointer<GtkCssProvider> {
            let provider = gtk_css_provider_new()!
            gtk_css_provider_load_from_string(provider, css)
            return provider
        }
        let priority = UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        gtk_style_context_add_provider_for_display(display, cast(provider(shared)), priority)
        let sets = [light, dark, lightContrast, darkContrast].map { provider(css($0)) }
        let manager = adw_style_manager_get_default()
        var current: UnsafeMutablePointer<GtkCssProvider>?
        let follow: @MainActor () -> Void = {
            let isDark = adw_style_manager_get_dark(manager) != 0
            let isContrast = adw_style_manager_get_high_contrast(manager) != 0
            let wanted = sets[(isContrast ? 2 : 0) + (isDark ? 1 : 0)]
            guard wanted != current else { return }
            if let current {
                gtk_style_context_remove_provider_for_display(display, cast(current))
            }
            gtk_style_context_add_provider_for_display(display, cast(wanted), priority)
            current = wanted
        }
        follow()
        connect(manager, "notify::dark", follow)
        connect(manager, "notify::high-contrast", follow)
    }
}
