import CGtk
import GtkBinding

/// A window that belongs to the live window, such as Rules, Devices, a composer or the script
/// editor: over it, never blocking it, and closed as it hides. ``App/addSecondary(_:over:)`` keeps
/// it until then, or until it closes itself, so the self-check can reach it, by its type, through
/// ``App/secondaries``.
@MainActor
protocol SecondaryWindow: AnyObject {
    /// Its GtkWindow, an AdwApplicationWindow or an AdwWindow.
    var window: Widget { get }
}

extension App {
    /// Keeps `secondary` over `parent`, the live window unless it says another, such as the Rules
    /// window for the script editor, without blocking it, until the live window hides, which closes
    /// it, or it closes itself. Ctrl+W closes it, unless a dialog shows over it.
    func addSecondary(_ secondary: any SecondaryWindow, over parent: Widget? = nil) {
        let window = secondary.window
        if let parent = parent ?? liveWindow?.window {
            gtk_window_set_transient_for(cast(window), cast(parent))
        }
        keepSecondary(secondary)
        addKeys("<Control>w", to: window) {
            guard !showsDialog(window) else { return false }
            gtk_window_close(cast(window))
            return true
        }
    }
}

/// Whether an AdwDialog shows over `window`, an AdwApplicationWindow or an AdwWindow, while which
/// the window's own keys wait.
@MainActor
func showsDialog(_ window: Widget) -> Bool {
    if g_type_check_instance_is_a(cast(window), adw_application_window_get_type()) != 0 {
        return adw_application_window_get_visible_dialog(cast(window)) != nil
    }
    if g_type_check_instance_is_a(cast(window), adw_window_get_type()) != 0 {
        return adw_window_get_visible_dialog(cast(window)) != nil
    }
    return false
}

/// Gives `widget` the keyboard shortcut `keys`, such as `<Control>w`, which runs `body` while the
/// keyboard's focus is in it, or in its window for a window. `body` says whether it took the keys,
/// or let them go on to the widgets under it.
@MainActor
func addKeys(_ keys: String, to widget: Widget, _ body: @escaping @MainActor () -> Bool) {
    let shortcuts = gtk_shortcut_controller_new()!
    let trigger = gtk_shortcut_trigger_parse_string(keys)
    let action = gtk_callback_action_new(runKeys, Box<@MainActor () -> Bool>(body).retained(), releaseContext)
    gtk_shortcut_controller_add_shortcut(cast(shortcuts), gtk_shortcut_new(trigger, action))
    gtk_widget_add_controller(widget, shortcuts)
}

private let runKeys: GtkShortcutFunc = { _, _, context in
    let body = Box<@MainActor () -> Bool>.from(context)
    return MainActor.assumeIsolated { cBool(body()) }
}
