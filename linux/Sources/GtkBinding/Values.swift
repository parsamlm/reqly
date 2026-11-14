import CGtk
import CGtkShim

// GObject properties by name, for the few that have no setter of their own, and GValues, which
// g_object_set would hide behind its variadic arguments, which Swift can't call.

/// A GValue holding a Swift value, for as long as `body` runs.
public enum Value {
    case bool(Bool)
    case int(Int32)
    case uint(UInt32)
    case int64(Int64)
    case double(Double)
    case string(String)
    /// An object, or none, held as its own type, so a property of any type it is takes it, such
    /// as a widget for a property that wants a GtkWidget.
    case object(UnsafeMutableRawPointer?)
    /// A GVariant, which the value takes if it's floating, and holds a reference to otherwise.
    case variant(OpaquePointer?)

    public func with<R>(_ body: (UnsafeMutablePointer<GValue>) -> R) -> R {
        var value = GValue()
        switch self {
        case .bool(let bool):
            g_value_init(&value, reqly_type_boolean())
            g_value_set_boolean(&value, cBool(bool))
        case .int(let int):
            g_value_init(&value, reqly_type_int())
            g_value_set_int(&value, int)
        case .uint(let uint):
            g_value_init(&value, reqly_type_uint())
            g_value_set_uint(&value, uint)
        case .int64(let int64):
            g_value_init(&value, reqly_type_int64())
            g_value_set_int64(&value, gint64(int64))
        case .double(let double):
            g_value_init(&value, reqly_type_double())
            g_value_set_double(&value, double)
        case .string(let string):
            g_value_init(&value, reqly_type_string())
            g_value_set_string(&value, string)
        case .object(let object):
            g_value_init(&value, object.map { reqly_object_type($0) } ?? reqly_type_object())
            g_value_set_object(&value, object)
        case .variant(let variant):
            g_value_init(&value, reqly_type_variant())
            g_value_set_variant(&value, variant)
        }
        defer { g_value_unset(&value) }
        return body(&value)
    }
}

/// g_object_set for one property.
@MainActor
public func set(_ object: UnsafeMutableRawPointer?, _ property: String, _ value: Value) {
    value.with { g_object_set_property(cast(object), property, $0) }
}

@MainActor
public func set(_ object: OpaquePointer?, _ property: String, _ value: Value) {
    set(raw(object), property, value)
}

/// g_object_get for one boolean property, such as a split view's `show-sidebar`.
@MainActor
public func boolProperty(_ object: UnsafeMutableRawPointer?, _ property: String) -> Bool {
    var value = GValue()
    g_value_init(&value, reqly_type_boolean())
    defer { g_value_unset(&value) }
    g_object_get_property(cast(object), property, &value)
    return g_value_get_boolean(&value) != 0
}

/// g_object_bind_property, starting from the source's value: the target's property follows the
/// source's, and with `bothWays`, the source's follows the target's too, such as a split view's
/// `show-sidebar` and its toggle's `active`. The binding goes when either object does, or with
/// g_binding_unbind on the binding it gives.
@MainActor @discardableResult
public func bind(
    _ source: UnsafeMutableRawPointer?, _ property: String, to target: UnsafeMutableRawPointer?,
    _ targetProperty: String, bothWays: Bool = true
) -> OpaquePointer? {
    var flags = G_BINDING_SYNC_CREATE.rawValue
    if bothWays {
        flags |= G_BINDING_BIDIRECTIONAL.rawValue
    }
    return g_object_bind_property(source, property, target, targetProperty, GBindingFlags(rawValue: flags))
}

/// Emits a signal that has no parameters and returns nothing, such as a button's "clicked", as a
/// click would.
@MainActor
public func emit(_ instance: UnsafeMutableRawPointer?, _ signal: String) {
    reqly_emit(instance, signal)
}

@MainActor
public func emit(_ instance: OpaquePointer?, _ signal: String) {
    emit(raw(instance), signal)
}

/// g_object_get for one string property, such as GtkSettings' `gtk-icon-theme-name`.
@MainActor
public func stringProperty(_ object: UnsafeMutableRawPointer?, _ property: String) -> String? {
    var value = GValue()
    g_value_init(&value, reqly_type_string())
    defer { g_value_unset(&value) }
    g_object_get_property(cast(object), property, &value)
    return string(g_value_get_string(&value))
}

/// A GError's message, freeing it.
public func message(_ error: UnsafeMutablePointer<GError>?) -> String {
    guard let error else { return "no error" }
    defer { g_error_free(error) }
    return String(cString: error.pointee.message)
}
