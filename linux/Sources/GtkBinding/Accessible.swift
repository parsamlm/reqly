import CGtk
import CGtkShim

// What screen readers such as Orca hear of a widget, beyond its role: GtkAccessible's states,
// properties and relations. C sets them with variadic arguments, which Swift can't call, so these
// use the calls that take GValues instead.

/// A widget's accessible label, as screen readers say it.
@MainActor
public func setAccessibleLabel(_ widget: Widget, _ label: String) {
    reqly_accessible_set_label(widget, label)
}

/// A widget's accessible description, which screen readers say after its label, such as a row's
/// "Request 3 of 10,000".
@MainActor
public func setAccessibleDescription(_ widget: Widget, _ description: String) {
    setAccessibleProperty(widget, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, .string(description))
}

/// Whether screen readers skip a widget, such as an icon whose meaning a label beside it says.
/// GTK 4.14 puts the state back as the widget shows, so it's set again each time the widget has
/// shown, once GTK's done with it. For an icon that's never read, a role of
/// GTK_ACCESSIBLE_ROLE_NONE, given as the widget's made, does the same.
@MainActor
public func setAccessibleHidden(_ widget: Widget, _ isHidden: Bool) {
    let isFirst = g_object_get_data(cast(widget), hiddenKey) == nil
    // The choice stays with the widget, as 1 for no and 2 for yes, since GLib keeps a pointer.
    g_object_set_data(cast(widget), hiddenKey, UnsafeMutableRawPointer(bitPattern: isHidden ? 2 : 1))
    setAccessibleState(widget, GTK_ACCESSIBLE_STATE_HIDDEN, .bool(isHidden))
    guard isFirst else { return }
    connect(raw(widget), "map", after: true) {
        // Held until the idle runs, which is after the frame that showed it.
        g_object_ref(raw(widget))
        idle {
            defer { g_object_unref(raw(widget)) }
            if gtk_widget_get_mapped(widget) != 0 {
                let isHidden = g_object_get_data(cast(widget), hiddenKey) == UnsafeMutableRawPointer(bitPattern: 2)
                setAccessibleState(widget, GTK_ACCESSIBLE_STATE_HIDDEN, .bool(isHidden))
            }
            return false
        }
    }
}

private let hiddenKey = "reqly-accessible-hidden"

/// gtk_accessible_update_property for one property, with a value of the property's type:
/// `.string` for a text, `.int` for a number, `.bool` for a yes or no.
@MainActor
public func setAccessibleProperty(_ widget: Widget, _ property: GtkAccessibleProperty, _ value: Value) {
    var property = property
    value.with { gtk_accessible_update_property_value(cast(widget), 1, &property, $0) }
}

/// gtk_accessible_update_state for one state, such as `.bool` for GTK_ACCESSIBLE_STATE_HIDDEN.
@MainActor
public func setAccessibleState(_ widget: Widget, _ state: GtkAccessibleState, _ value: Value) {
    var state = state
    value.with { gtk_accessible_update_state_value(cast(widget), 1, &state, $0) }
}

/// A relation that takes a number, such as a cell's GTK_ACCESSIBLE_RELATION_ROW_INDEX or a
/// table's GTK_ACCESSIBLE_RELATION_ROW_COUNT, counted from 1 as screen readers say them.
@MainActor
public func setAccessibleRelation(_ widget: Widget, _ relation: GtkAccessibleRelation, _ number: Int32) {
    var relation = relation
    Value.int(number).with { gtk_accessible_update_relation_value(cast(widget), 1, &relation, $0) }
}

/// A relation that names other widgets, in order, such as GTK_ACCESSIBLE_RELATION_LABELLED_BY,
/// whose widgets' words make a row's label, or GTK_ACCESSIBLE_RELATION_DESCRIBED_BY. The widget
/// doesn't keep them alive: one that goes leaves the relation.
@MainActor
public func setAccessibleRelation(_ widget: Widget, _ relation: GtkAccessibleRelation, _ widgets: [Widget]) {
    let widgets: [Widget?] = widgets
    widgets.withUnsafeBufferPointer {
        reqly_accessible_set_relation_list(widget, relation, $0.baseAddress, UInt32($0.count))
    }
}

/// gtk_accessible_announce, GTK 4.14's: screen readers say `message` now, such as which page a
/// shortcut chose, without moving the focus. A medium priority waits for what they're saying; a
/// high one may cut it short.
@MainActor
public func announce(
    _ widget: Widget, _ message: String,
    priority: GtkAccessibleAnnouncementPriority = GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM
) {
    gtk_accessible_announce(cast(widget), message, priority)
}

/// A new widget of `type` with the accessible role `role`, which GTK sets only as a widget is
/// made, such as GTK_ACCESSIBLE_ROLE_NONE for an icon screen readers skip, as the words beside it
/// say what it means. Floating, as any new widget is.
@MainActor
public func makeWidget(_ type: GType, role: GtkAccessibleRole) -> Widget {
    var value = GValue()
    g_value_init(&value, gtk_accessible_role_get_type())
    g_value_set_enum(&value, Int32(role.rawValue))
    defer { g_value_unset(&value) }
    let made = withCStrings(["accessible-role"]) {
        g_object_new_with_properties(type, 1, UnsafeMutablePointer(mutating: $0), &value)
    }
    return cast(UnsafeMutableRawPointer(made))
}

/// A new scrolled window that screen readers call `name`, such as a page's title. GTK 4.14 gives
/// a scrolled window a role that takes no name, so screen readers heard an unnamed "scroll pane";
/// this one's role is a group's, which AT-SPI still calls a scroll pane, with its name.
@MainActor
public func namedScroller(_ name: String) -> Widget {
    let scroller = makeWidget(gtk_scrolled_window_get_type(), role: GTK_ACCESSIBLE_ROLE_GROUP)
    setAccessibleLabel(scroller, name)
    return scroller
}
