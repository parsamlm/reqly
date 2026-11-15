import CGtk
import GtkBinding
import ReqlyModel

/// The Rules menu, on its button at the end of the live window's list header bar, as the Mac's
/// Rules menu has it: Breakpoints and Continue All Paused Requests; Map Local, Map Remote,
/// Rewrite, Block and Scripts; Slow Network; and Show Rules. Each kind is a switch, `app.<name>`,
/// so its shortcut and its entry work from any window. The button's icon and its name say when a
/// kind is on.
enum RulesMenu {
    /// The button's icons, while no kind is on, and while one is.
    static let icon = "reqly-rules-symbolic"
    static let onIcon = "reqly-rules-on-symbolic"

    /// The button, with the menu, named as when no kind is on.
    @MainActor
    static func button() -> Widget {
        let button = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(button), icon)
        gtk_widget_set_tooltip_text(button, name(kindsOn: []))
        setAccessibleLabel(button, name(kindsOn: []))
        let menu = menu()
        gtk_menu_button_set_menu_model(cast(button), cast(menu))
        g_object_unref(raw(menu))
        return button
    }

    /// The menu, in sections.
    @MainActor
    static func menu() -> OpaquePointer {
        let menu = g_menu_new()!
        let breakpoints = g_menu_new()!
        g_menu_append(breakpoints, RuleKind.breakpoint.title, "app.\(RuleKind.breakpoint.actionName)")
        g_menu_append(breakpoints, "Continue All Paused Requests", "app.continue-all")
        let changes = g_menu_new()!
        for kind in [RuleKind.mapLocal, .mapRemote, .rewrite, .block, .script] {
            g_menu_append(changes, kind.title, "app.\(kind.actionName)")
        }
        let network = g_menu_new()!
        g_menu_append(network, RuleKind.slowNetwork.title, "app.\(RuleKind.slowNetwork.actionName)")
        let window = g_menu_new()!
        g_menu_append(window, "Show Rules", "app.show-rules")
        for section in [breakpoints, changes, network, window] {
            g_menu_append_section(menu, nil, cast(section))
            g_object_unref(raw(section))
        }
        return menu
    }

    /// The button's name and tooltip: "Rules", or with the kinds that are on, in the menu's order,
    /// such as "Rules, Breakpoints and Slow Network on".
    static func name(kindsOn: Set<RuleKind>) -> String {
        let on = RuleKind.allCases.filter(kindsOn.contains).map(\.title)
        guard let last = on.last else { return "Rules" }
        let list = on.count == 1 ? last : on.dropLast().joined(separator: ", ") + " and " + last
        return "Rules, \(list) on"
    }
}
