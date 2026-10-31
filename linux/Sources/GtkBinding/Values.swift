import CGtk
import CGtkShim

// GObject properties by name, for the few that have no setter of their own, and GValues, which
// g_object_set would hide behind its variadic arguments, which Swift can't call.

/// A GValue holding a Swift value, for as long as `body` runs.
public enum Value {
    case bool(Bool)
    case int(Int32)
    case uint(UInt32)
    case double(Double)
    case string(String)

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
        case .double(let double):
            g_value_init(&value, reqly_type_double())
            g_value_set_double(&value, double)
        case .string(let string):
            g_value_init(&value, reqly_type_string())
            g_value_set_string(&value, string)
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

/// A GError's message, freeing it.
public func message(_ error: UnsafeMutablePointer<GError>?) -> String {
    guard let error else { return "no error" }
    defer { g_error_free(error) }
    return String(cString: error.pointee.message)
}

/// A widget's accessible label, as screen readers say it.
@MainActor
public func setAccessibleLabel(_ widget: Widget, _ label: String) {
    reqly_accessible_set_label(widget, label)
}
