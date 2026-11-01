import CGtk
import CGtkShim

// Every signal reaches Swift the same way: a GClosure whose one C marshaller (CGtkShim) calls
// `closureCall` with the closure's context, a retained Handler, and GLib's own GValues. GLib only
// emits these on the thread whose main context they belong to, the main thread here, so the
// handler runs as main-actor code: MainActor.assumeIsolated checks that, and traps if it's not so.

/// A signal's parameters as GLib passes them, the instance first, and its return value. They're
/// only valid during the call.
public struct Arguments: @unchecked Sendable {
    let result: UnsafeMutablePointer<GValue>?
    let params: UnsafePointer<GValue>?
    public let count: Int

    @inline(__always) func value(_ index: Int) -> UnsafePointer<GValue> {
        precondition(index < count, "The signal has \(count) parameters, not \(index + 1).")
        return params! + index
    }

    public func pointer(_ index: Int) -> UnsafeMutableRawPointer? { g_value_peek_pointer(value(index)) }
    public func object(_ index: Int) -> UnsafeMutableRawPointer? { g_value_get_object(value(index)) }
    public func string(_ index: Int) -> String? { GtkBinding.string(g_value_get_string(value(index))) }
    public func bool(_ index: Int) -> Bool { g_value_get_boolean(value(index)) != 0 }
    public func int(_ index: Int) -> Int32 { g_value_get_int(value(index)) }
    public func uint(_ index: Int) -> UInt32 { g_value_get_uint(value(index)) }
    public func double(_ index: Int) -> Double { g_value_get_double(value(index)) }

    /// Sets a gboolean return value, as "close-request" wants.
    public func returns(_ value: Bool) {
        if let result { g_value_set_boolean(result, cBool(value)) }
    }
}

final class Handler: Sendable {
    let body: @MainActor (Arguments) -> Void
    init(_ body: @escaping @MainActor (Arguments) -> Void) { self.body = body }
}

private let closureCall: ReqlyClosureCall = { context, result, count, params in
    let handler = Unmanaged<Handler>.fromOpaque(context!).takeUnretainedValue()
    let arguments = Arguments(result: result, params: params, count: Int(count))
    MainActor.assumeIsolated { handler.body(arguments) }
}

/// Releases a retained Swift object passed to C as a context.
public let releaseContext: GDestroyNotify = { context in
    Unmanaged<AnyObject>.fromOpaque(context!).release()
}

/// A GClosure that runs `body`. GLib owns it once it's handed over, as to g_signal_connect_closure.
public func closure(_ body: @escaping @MainActor (Arguments) -> Void) -> UnsafeMutablePointer<GClosure> {
    reqly_closure_new(Unmanaged.passRetained(Handler(body)).toOpaque(), closureCall, releaseContext)
}

/// g_signal_connect, with Swift's closure: `body` gets the signal's parameters.
@MainActor @discardableResult
public func connect(
    _ instance: UnsafeMutableRawPointer?, _ signal: String, after: Bool = false,
    _ body: @escaping @MainActor (Arguments) -> Void
) -> UInt {
    UInt(g_signal_connect_closure(instance, signal, closure(body), cBool(after)))
}

/// g_signal_connect for a handler that needs none of the parameters.
@MainActor @discardableResult
public func connect(
    _ instance: UnsafeMutableRawPointer?, _ signal: String, after: Bool = false, _ body: @escaping @MainActor () -> Void
) -> UInt {
    connect(instance, signal, after: after) { (_: Arguments) in body() }
}

@MainActor @discardableResult
public func connect(
    _ instance: OpaquePointer?, _ signal: String, after: Bool = false, _ body: @escaping @MainActor () -> Void
) -> UInt {
    connect(raw(instance), signal, after: after, body)
}

@MainActor @discardableResult
public func connect(
    _ instance: OpaquePointer?, _ signal: String, after: Bool = false, _ body: @escaping @MainActor (Arguments) -> Void
) -> UInt {
    connect(raw(instance), signal, after: after, body)
}

// MARK: - Callbacks that aren't signals

/// A pointer carried into the main actor's code and back out, which Swift can't check: GLib
/// hands it over on the main thread, and it's used there.
public struct Unchecked<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// A Swift value handed to C as a callback's context.
public final class Box<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }

    /// Retained, for GLib to release with `releaseContext`.
    public func retained() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }

    public static func from(_ context: UnsafeMutableRawPointer?) -> Value {
        Unmanaged<Box<Value>>.fromOpaque(context!).takeUnretainedValue().value
    }
}

typealias SourceBody = @MainActor () -> Bool

private let sourceCall: GSourceFunc = { context in
    let body = Box<SourceBody>.from(context)
    return cBool(MainActor.assumeIsolated { body() })
}

/// g_timeout_add_full: `body` runs every `milliseconds` until it returns false.
@MainActor @discardableResult
public func timeout(
    _ milliseconds: UInt32, priority: Int32 = G_PRIORITY_DEFAULT, _ body: @escaping @MainActor () -> Bool
) -> UInt32 {
    g_timeout_add_full(priority, milliseconds, sourceCall, Box<SourceBody>(body).retained(), releaseContext)
}

/// g_idle_add_full: `body` runs when nothing more urgent is waiting, until it returns false.
@MainActor @discardableResult
public func idle(priority: Int32 = G_PRIORITY_DEFAULT_IDLE, _ body: @escaping @MainActor () -> Bool) -> UInt32 {
    g_idle_add_full(priority, sourceCall, Box<SourceBody>(body).retained(), releaseContext)
}

private let tickCall: GtkTickCallback = { _, _, context in
    let body = Box<SourceBody>.from(context)
    return cBool(MainActor.assumeIsolated { body() })
}

/// gtk_widget_add_tick_callback: `body` runs once each frame, at the start of the frame, before
/// GTK lays out what changed since the last one, until it returns false. It runs only while
/// `widget` is realized, as it is while it shows.
@MainActor @discardableResult
public func tick(_ widget: Widget, _ body: @escaping @MainActor () -> Bool) -> UInt32 {
    gtk_widget_add_tick_callback(widget, tickCall, Box<SourceBody>(body).retained(), releaseContext)
}

/// g_unix_signal_add_full: `body` runs on the main thread each time the process gets `signal`,
/// such as SIGTERM, until it returns false. Meanwhile the signal's own action, such as ending the
/// process, doesn't happen.
@MainActor @discardableResult
public func onSignal(_ signal: Int32, _ body: @escaping @MainActor () -> Bool) -> UInt32 {
    g_unix_signal_add_full(G_PRIORITY_DEFAULT, signal, sourceCall, Box<SourceBody>(body).retained(), releaseContext)
}

typealias AsyncBody = @MainActor (UnsafeMutablePointer<GObject>?, OpaquePointer?) -> Void

private let asyncCall: GAsyncReadyCallback = { source, result, context in
    let body = Unmanaged<Box<AsyncBody>>.fromOpaque(context!).takeRetainedValue().value
    let pointers = Unchecked((source, result))
    MainActor.assumeIsolated { body(pointers.value.0, pointers.value.1) }
}

/// A GAsyncReadyCallback and its context, for GIO's _async calls, which call it once.
@MainActor
public func whenReady(
    _ body: @escaping @MainActor (UnsafeMutablePointer<GObject>?, OpaquePointer?) -> Void
) -> (GAsyncReadyCallback, UnsafeMutableRawPointer) {
    (asyncCall, Box<AsyncBody>(body).retained())
}
