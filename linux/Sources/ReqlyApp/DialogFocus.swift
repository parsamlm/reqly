import CGtk
import GtkBinding

// The keyboard's focus in the dialogs over the window. Two things leave it on nothing while a
// dialog shows, so Escape doesn't close the dialog, Tab has to bring the focus in first, and F10
// opens the main menu over it, where Enter makes GTK log a critical:
//
// - libadwaita 1.7 and later never focus a dialog that opens again once it has been closed with
//   adw_dialog_close, as Set Up's Cancel and Done close it, and as the window's close closes the
//   dialog that's open. Settings and Set Up HTTPS… are kept, and open again.
// - GTK gives the focus to nothing when the widget that has it turns insensitive, as Continue and
//   Remove Certificate… do while Reqly works.

/// Presents a dialog the window keeps, over `window`, and gives it the keyboard's focus once it
/// shows, if libadwaita didn't: in the second frame, as libadwaita does, to its first widget that
/// takes the focus, as on its first opening.
@MainActor
func presentKept(_ dialog: Widget, over window: Widget) {
    // The widget the last opening focused may have gone with its page, or may not take the focus
    // now, as Continue doesn't until the places are read.
    if gtk_widget_get_mapped(dialog) == 0 {
        adw_dialog_set_focus(cast(dialog), nil)
    }
    adw_dialog_present(cast(dialog), window)
    // Added after libadwaita's own as the dialog showed, so it runs after it in each frame.
    var frames = 0
    tick(dialog) {
        frames += 1
        guard frames >= 2 else { return true }
        if isVisibleDialog(dialog), !hasFocus(inside: dialog) {
            gtk_widget_grab_focus(dialog)
        }
        return false
    }
}

/// Gives `widget` the keyboard's focus, while `dialog` is the dialog that shows and the focus is
/// in it or on nothing, as when the button that had it turned insensitive. Not while `dialog`
/// closes, or has a dialog over it, which has the focus.
@MainActor
func refocus(_ widget: Widget, in dialog: Widget) {
    guard isVisibleDialog(dialog) else { return }
    if let focus = shownFocus(of: dialog), !isInside(focus, dialog) {
        return
    }
    gtk_widget_grab_focus(widget)
}

/// The dialog that shows over `window`, on top of any others, unless one is closing.
@MainActor
func visibleDialog(over window: Widget) -> Widget? {
    adw_application_window_get_visible_dialog(cast(window)).map { cast($0) as Widget }
}

/// Whether `dialog` is the one that shows over its window: presented, on top, and not closing.
@MainActor
private func isVisibleDialog(_ dialog: Widget) -> Bool {
    guard let root = gtk_widget_get_root(dialog) else { return false }
    return visibleDialog(over: cast(root)) == dialog
}

/// Whether the keyboard's focus is on a widget that shows in `dialog`.
@MainActor
func hasFocus(inside dialog: Widget) -> Bool {
    shownFocus(of: dialog).map { isInside($0, dialog) } ?? false
}

/// The widget with the keyboard's focus in `dialog`'s window, unless it doesn't show: libadwaita
/// gives the focus back to the widget that had it before a dialog went over, even once it's
/// hidden, as Settings' Set Up HTTPS… is once Set Up HTTPS… has set it up.
@MainActor
private func shownFocus(of dialog: Widget) -> Widget? {
    guard let root = gtk_widget_get_root(dialog), let focus = gtk_root_get_focus(root),
        gtk_widget_get_mapped(focus) != 0
    else { return nil }
    return focus
}

@MainActor
private func isInside(_ widget: Widget, _ dialog: Widget) -> Bool {
    widget == dialog || gtk_widget_is_ancestor(widget, dialog) != 0
}
