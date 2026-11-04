import CGtk
import GtkBinding

/// The body views' colors and styles: code in the Mac's Key, String, Number, Literal and
/// Punctuation colors, for light, dark and high contrast, as its assets have them, the tree's
/// values in the same, and the checkerboard behind pictures. libadwaita 1.5 has no CSS media
/// queries, so each style is a provider of its own, swapped in as the style manager changes, as
/// Styles.swift does.
@MainActor
enum BodyStyles {
    /// How code looks now.
    struct Look: Hashable {
        var isDark: Bool
        var isHighContrast: Bool

        static var now: Look {
            let manager = adw_style_manager_get_default()
            return Look(
                isDark: adw_style_manager_get_dark(manager) != 0,
                isHighContrast: adw_style_manager_get_high_contrast(manager) != 0)
        }
    }

    /// A color of code, as CSS writes it: the Mac's asset's, in light, dark, light with high
    /// contrast and dark with high contrast. Comments are the text's own color, faded, as the
    /// Mac's are its tertiary label, but no fainter than 4.5:1 on code's background.
    static func css(_ color: CodeText.Color?, _ look: Look) -> String {
        let colors: (light: String, dark: String, lightHigh: String, darkHigh: String) =
            switch color {
            case .key: ("#1D1D1F", "#F5F5F7", "#000000", "#FFFFFF")
            case .string: ("#AE4F18", "#FFA36E", "#843300", "#FFC6A1")
            case .number: ("#1F5FD1", "#72AAFF", "#0A44AE", "#A9CBFF")
            case .literal: ("#8E3BB5", "#D59CFF", "#6A1A93", "#E3BFFF")
            case .comment: ("rgba(0,0,0,0.55)", "rgba(255,255,255,0.5)", "rgba(0,0,0,0.7)", "rgba(255,255,255,0.7)")
            // Punctuation, which is code that has no token.
            case nil: ("#6C6C71", "#9A9AA1", "#4B4B50", "#BDBDC3")
            }
        switch (look.isDark, look.isHighContrast) {
        case (false, false): return colors.light
        case (true, false): return colors.dark
        case (false, true): return colors.lightHigh
        case (true, true): return colors.darkHigh
        }
    }

    /// The checkerboard's two squares, as the Mac's: white and a pale gray, or two dark grays.
    static func checkerboard(_ look: Look) -> (light: Double, dark: (Double, Double, Double)) {
        look.isDark ? (0.17, (0.21, 0.21, 0.21)) : (1, (0.93, 0.94, 0.94))
    }

    private static var isInstalled = false

    /// Adds the styles to the display, once, the first time a body shows.
    static func install() {
        guard !isInstalled, let display = gdk_display_get_default() else { return }
        isInstalled = true
        let manager = adw_style_manager_get_default()
        let priority = UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        let shared = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(
            shared,
            """
            .body-line { min-height: 34px; }
            .tree-row .key { font-weight: 500; }
            .path-bar { padding: 6px 6px 6px 12px; }
            """)
        gtk_style_context_add_provider_for_display(display, cast(shared), priority)
        var providers: [Look: UnsafeMutablePointer<GtkCssProvider>] = [:]
        var current: UnsafeMutablePointer<GtkCssProvider>?
        let follow: @MainActor () -> Void = {
            let look = Look.now
            let wanted =
                providers[look]
                ?? {
                    let provider = gtk_css_provider_new()!
                    gtk_css_provider_load_from_string(provider, colors(look))
                    providers[look] = provider
                    return provider
                }()
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

    /// The tree's values in code's colors.
    private static func colors(_ look: Look) -> String {
        """
        .tree-row .string { color: \(css(.string, look)); }
        .tree-row .number { color: \(css(.number, look)); }
        .tree-row .literal { color: \(css(.literal, look)); }
        """
    }
}
