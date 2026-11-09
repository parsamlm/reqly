import CGtk
import GtkBinding

/// The details' styles on top of libadwaita's: the rows in their cards, the status dot, which has
/// the list's colors (``ListStyles``), the color marks, the timing bars in the accent color, and
/// the Raw page's text on the Mac's code background. A failed step's red and the code background
/// have light, dark and high-contrast versions, a provider each, swapped in as the style manager
/// changes, since libadwaita 1.5 has no CSS media queries.
@MainActor
enum DetailsStyles {
    private static let shared = """
        .details-heading { padding: 12px 12px 10px 12px; }
        .details-method { font-family: monospace; }
        .details-rows { padding: 0; }
        .details-row { padding: 7px 12px; }
        .details-row button.flat { min-height: 0; padding: 0 8px; }
        .details-rows > .details-row:not(:first-child) { border-top: 1px solid @card_shade_color; }
        .details-name { min-width: 0; }
        .details-dot { min-width: 8px; min-height: 8px; border-radius: 4px; background-color: alpha(currentColor, 0.3); }
        .details-dot.request-dot { margin: 0; }
        .details-mark { min-width: 12px; min-height: 12px; border-radius: 6px;
            box-shadow: inset 0 0 0 1.5px alpha(currentColor, 0.55); }
        .details-mark.red { background-color: @red_3; box-shadow: none; }
        .details-mark.orange { background-color: @orange_3; box-shadow: none; }
        .details-mark.yellow { background-color: @yellow_4; box-shadow: none; }
        .details-mark.green { background-color: @green_4; box-shadow: none; }
        .details-mark.blue { background-color: @blue_3; box-shadow: none; }
        .details-mark.purple { background-color: @purple_3; box-shadow: none; }
        .details-mark.gray { background-color: @light_5; box-shadow: none; }
        .details-url { padding: 10px 12px; font-family: monospace; }
        .details-note { padding: 12px; }
        .details-bar { color: alpha(currentColor, 0.3); }
        .details-bar.accent { color: @accent_bg_color; }
        .details-bar.half-accent { color: alpha(@accent_bg_color, 0.5); }
        .details-step { padding: 6px 12px; }
        .details-total { font-weight: bold; }
        textview.details-raw { font-family: monospace; border-radius: 10px; }
        textview.details-raw > text { background-color: transparent; }
        """

    /// A failed step's red, and the code background, per style.
    private static let light = colors(red: "#e01b24", code: "#F6F7F7")
    private static let dark = colors(red: "#f66151", code: "#242528")
    private static let highContrast = colors(red: "#a51d2d", code: "#FFFFFF")
    private static let darkHighContrast = colors(red: "#ff7b63", code: "#161618")

    private static func colors(red: String, code: String) -> String {
        """
        .details-bar.failed { color: \(red); }
        textview.details-raw { background-color: \(code); }
        """
    }

    private static var isInstalled = false

    /// Adds the styles to the display, once.
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
        let styles = [light, dark, highContrast, darkHighContrast].map(provider)
        let manager = adw_style_manager_get_default()
        var current: UnsafeMutablePointer<GtkCssProvider>?
        let follow: @MainActor () -> Void = {
            let isDark = adw_style_manager_get_dark(manager) != 0
            let isHigh = adw_style_manager_get_high_contrast(manager) != 0
            let wanted = styles[(isHigh ? 2 : 0) + (isDark ? 1 : 0)]
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
