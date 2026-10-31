import AppSetup
import CGtk
import GtkBinding

/// The app's few styles on top of libadwaita's: the status line, and its dot, which is Reqly teal
/// while Reqly captures, as the design guidelines color success. libadwaita 1.5 has no CSS media
/// query for the dark style, so the dark colors are a provider of their own, swapped in when the
/// style manager turns dark.
@MainActor
enum Styles {
    private static let shared = """
        .status-line { padding: 4px 12px; }
        .status-line label { font-size: smaller; }
        .status-dot { min-width: 8px; min-height: 8px; border-radius: 4px; background-color: alpha(currentColor, 0.3); }
        """
    private static let light = ".status-dot.capturing { background-color: #0B9A83; }"
    private static let dark = ".status-dot.capturing { background-color: #3FDDC0; }"

    /// Forces light or dark, when `theme` asks, and adds the app's styles to the display.
    static func install(theme: Options.Theme?) {
        let manager = adw_style_manager_get_default()
        switch theme {
        case .light: adw_style_manager_set_color_scheme(manager, ADW_COLOR_SCHEME_FORCE_LIGHT)
        case .dark: adw_style_manager_set_color_scheme(manager, ADW_COLOR_SCHEME_FORCE_DARK)
        case nil: break
        }
        guard let display = gdk_display_get_default() else { return }
        func provider(_ css: String) -> UnsafeMutablePointer<GtkCssProvider> {
            let provider = gtk_css_provider_new()!
            gtk_css_provider_load_from_string(provider, css)
            return provider
        }
        let priority = UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        gtk_style_context_add_provider_for_display(display, cast(provider(shared)), priority)
        let lightColors = provider(light)
        let darkColors = provider(dark)
        var current: UnsafeMutablePointer<GtkCssProvider>?
        let follow: @MainActor () -> Void = {
            let wanted = adw_style_manager_get_dark(manager) != 0 ? darkColors : lightColors
            guard wanted != current else { return }
            if let current {
                gtk_style_context_remove_provider_for_display(display, cast(current))
            }
            gtk_style_context_add_provider_for_display(display, cast(wanted), priority)
            current = wanted
        }
        follow()
        connect(manager, "notify::dark", follow)
    }
}
