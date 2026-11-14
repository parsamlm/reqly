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

    /// The font libadwaita's `monospace` style class gives `widget`'s text: from libadwaita 1.7,
    /// the family and size of the desktop's monospace font, as its CSS takes them; before, the
    /// widget's own font in a monospace family. Free it with `pango_font_description_free`.
    static func monospaceFont(for widget: Widget) -> OpaquePointer {
        let own = pango_context_get_font_description(gtk_widget_get_pango_context(widget))
        let font = pango_font_description_copy(own)!
        typealias Name = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
        guard LibraryVersion.adwaita(atLeast: 7),
            let name = Newer.lookup("adw_style_manager_get_monospace_font_name", as: Name.self),
            let words = name(raw(adw_style_manager_get_default())),
            let desktop = pango_font_description_from_string(words)
        else {
            pango_font_description_set_family(font, "monospace")
            return font
        }
        defer { pango_font_description_free(desktop) }
        if let family = pango_font_description_get_family(desktop) {
            pango_font_description_set_family(font, family)
        } else {
            pango_font_description_set_family(font, "monospace")
        }
        let size = pango_font_description_get_size(desktop)
        if size > 0, pango_font_description_get_size_is_absolute(desktop) != 0 {
            pango_font_description_set_absolute_size(font, Double(size))
        } else if size > 0 {
            pango_font_description_set_size(font, size)
        }
        return font
    }

    /// Runs `body` as the desktop's monospace font changes, which libadwaita's `monospace` style
    /// class follows from 1.7, while `object` is alive.
    static func whenMonospaceFontChanges(
        whileAlive object: UnsafeMutableRawPointer?, _ body: @escaping @MainActor () -> Void
    ) {
        guard LibraryVersion.adwaita(atLeast: 7) else { return }
        connect(raw(adw_style_manager_get_default()), "notify::monospace-font-name", whileAlive: object, body)
    }
}
