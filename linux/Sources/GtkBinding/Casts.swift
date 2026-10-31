import CGtk

// GTK's types come to Swift two ways: a type whose struct C can see, such as GtkWidget, as a
// typed pointer, and a final type, such as GtkStringList, as an OpaquePointer. C converts between
// them with GObject's casting macros (GTK_WINDOW and the like); Swift converts with these, which
// check nothing, as the macros don't in a release build.

public typealias Widget = UnsafeMutablePointer<GtkWidget>

@inline(__always)
public func cast<T>(_ pointer: UnsafeMutablePointer<some Any>?) -> UnsafeMutablePointer<T>! {
    pointer.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: T.self) }
}

@inline(__always)
public func cast<T>(_ pointer: OpaquePointer?) -> UnsafeMutablePointer<T>! {
    pointer.map { UnsafeMutablePointer<T>($0) }
}

@inline(__always)
public func cast<T>(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T>! {
    pointer?.assumingMemoryBound(to: T.self)
}

@inline(__always)
public func cast(_ pointer: UnsafeMutablePointer<some Any>?) -> OpaquePointer! {
    pointer.map { OpaquePointer($0) }
}

@inline(__always)
public func cast(_ pointer: UnsafeMutableRawPointer?) -> OpaquePointer! {
    pointer.map { OpaquePointer($0) }
}

/// One opaque type as another, as a GListStore as the GListModel it implements.
@inline(__always)
public func cast(_ pointer: OpaquePointer?) -> OpaquePointer! {
    pointer
}

/// An opaque pointer as GLib's gpointer, which typed pointers become on their own.
@inline(__always)
public func raw(_ pointer: OpaquePointer?) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(pointer)
}

/// A typed pointer as GLib's gpointer, where Swift wants it spelled out.
@inline(__always)
public func raw(_ pointer: UnsafeMutablePointer<some Any>?) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(pointer)
}

/// A widget, from anything that is one.
@inline(__always)
public func widget(_ pointer: OpaquePointer?) -> Widget! { cast(pointer) }

/// The C strings of `strings`, NULL-terminated, for the length of `body`.
public func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    var pointers = strings.map { UnsafePointer(strdup($0)) }
    pointers.append(nil)
    defer { pointers.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// A Swift string from a C one GLib owns, or nil.
@inline(__always)
public func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

/// A Swift string from a C one to free with g_free.
public func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { g_free(pointer) }
    return String(cString: pointer)
}

/// A Swift Bool as GLib's gboolean.
@inline(__always)
public func cBool(_ value: Bool) -> gboolean { value ? 1 : 0 }
