import CGtk
import CGtkShim

/// Swift's main actor on GLib's main loop.
///
/// On Linux the main actor's jobs go to libdispatch's main queue, which runs only when something
/// drains it: `dispatch_main()`, or Foundation's RunLoop, which watches the queue's eventfd and
/// drains it when it rings. GTK's main loop owns the main thread instead, so CGtkShim gives GLib
/// a source that does what RunLoop does: it watches the same eventfd and drains the queue. Then
/// `Task { @MainActor in … }`, `await` returning to the main actor, `DispatchQueue.main.async`
/// and the core's events all run inside GLib's main loop, between GTK's own work, in the order
/// they were queued, with no polling and no g_idle_add hop.
public enum MainLoop {
    /// Call once, on the main thread, before g_application_run. G_PRIORITY_DEFAULT puts Swift's
    /// work with GLib's timeouts, ahead of GTK's drawing (GDK_PRIORITY_REDRAW) and idle work.
    @MainActor
    public static func runSwiftMainQueue(priority: Int32 = G_PRIORITY_DEFAULT) {
        reqly_attach_main_queue(priority)
    }

    /// Whether the code runs on the main thread, whose thread ID is the process's.
    public static var isMainThread: Bool {
        reqly_is_main_thread() != 0
    }
}

/// g_get_monotonic_time, in microseconds.
public func monotonicMicroseconds() -> Int {
    g_get_monotonic_time()
}

/// Lines to standard output, one at a time.
public func lineBufferedOutput() {
    reqly_line_buffered_stdout()
}

/// G_OBJECT_TYPE_NAME, such as "AdwHeaderBar".
public func typeName(_ object: UnsafeMutableRawPointer?) -> String {
    String(cString: reqly_type_name(object))
}
