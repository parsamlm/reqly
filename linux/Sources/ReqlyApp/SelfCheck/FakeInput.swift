import CGtk
import Foundation
import GtkBinding

/// Keys and clicks that the X server makes as a keyboard's and a mouse's, with its XTEST
/// extension, which Xvfb has, so they reach the window as yours do: through its focus, its
/// shortcuts and its gestures. Xlib's and libXtst's calls are found as the self-check runs, as
/// the app links neither; GTK's X11 backend brings Xlib, and at-spi2-core libXtst.
@MainActor
enum FakeInput {
    /// Presses `keys` together, in order, then lets go of them the other way round, in `window`,
    /// which gets X's focus first: X's names for keys, such as `"Control_L", "1"` or `"Escape"`.
    static func press(_ keys: String..., in window: Widget) throws {
        let x = try X.shared()
        let codes = try keys.map { name in
            let code = name.withCString { x.keycode(x.display, x.keysym($0)) }
            guard code != 0 else { throw SelfCheck.Failure("X has no key called \(name)") }
            return UInt32(code)
        }
        _ = x.setFocus(x.display, try x.window(of: window), 2, 0)
        for code in codes {
            _ = x.fakeKey(x.display, code, 1, 0)
        }
        for code in codes.reversed() {
            _ = x.fakeKey(x.display, code, 0, 0)
        }
        _ = x.flush(x.display)
    }

    /// Clicks the left button in the middle of `widget`, which shows, or `button`, such as 3 for
    /// the right one, and gives where on the screen. With `movingDown`, the pointer moves that many
    /// pixels down while the button's down, and it's let go there, as a hand that moves on toward
    /// a menu does. Otherwise it's let go `holding` milliseconds after it went down.
    @discardableResult
    static func click(
        _ widget: Widget, button: UInt32 = 1, movingDown move: Int32 = 0, holding: UInt = 50
    ) throws -> (x: Int32, y: Int32) {
        let x = try X.shared()
        let (rootX, rootY) = try middle(of: widget, x)
        // A moment apart, as a hand would, so GTK sees a click rather than a press and a release.
        _ = x.fakeMotion(x.display, -1, rootX, rootY, 0)
        _ = x.fakeButton(x.display, button, 1, 20)
        if move != 0 {
            _ = x.fakeMotion(x.display, -1, rootX, rootY + move, 25)
        }
        _ = x.fakeButton(x.display, button, 0, move != 0 ? 25 : holding)
        _ = x.flush(x.display)
        return (rootX, rootY)
    }

    /// Moves the pointer to the middle of `widget`, which shows, with no button down.
    static func hover(_ widget: Widget) throws {
        let x = try X.shared()
        let (rootX, rootY) = try middle(of: widget, x)
        _ = x.fakeMotion(x.display, -1, rootX, rootY, 0)
        _ = x.flush(x.display)
    }

    /// Turns the wheel up `notches` over the middle of `widget`, which shows, at once: X's button
    /// 4, pressed and let go each notch.
    static func scrollUp(_ widget: Widget, notches: Int) throws {
        let x = try X.shared()
        let (rootX, rootY) = try middle(of: widget, x)
        _ = x.fakeMotion(x.display, -1, rootX, rootY, 0)
        for _ in 0..<notches {
            _ = x.fakeButton(x.display, 4, 1, 0)
            _ = x.fakeButton(x.display, 4, 0, 0)
        }
        _ = x.flush(x.display)
    }

    /// The middle of `widget`, which shows, on the screen.
    private static func middle(of widget: Widget, _ x: X) throws -> (x: Int32, y: Int32) {
        guard let native = gtk_widget_get_native(widget), let surface = gtk_native_get_surface(native) else {
            throw SelfCheck.Failure("\(typeName(raw(widget))) doesn't show, so it can't be clicked")
        }
        var middle = graphene_point_t(
            x: Float(gtk_widget_get_width(widget)) / 2, y: Float(gtk_widget_get_height(widget)) / 2)
        var inWindow = graphene_point_t()
        guard gtk_widget_compute_point(widget, cast(native), &middle, &inWindow) != 0 else {
            throw SelfCheck.Failure("\(typeName(raw(widget))) isn't in its window")
        }
        // The window's own coordinates start inside its surface, past the shadow GTK draws.
        var left = 0.0
        var top = 0.0
        gtk_native_get_surface_transform(native, &left, &top)
        let scale = Double(gdk_surface_get_scale_factor(surface))
        var rootX: Int32 = 0
        var rootY: Int32 = 0
        var child: UInt = 0
        _ = x.translate(
            x.display, try x.window(of: cast(native)), x.root(x.display), Int32((Double(inWindow.x) + left) * scale),
            Int32((Double(inWindow.y) + top) * scale), &rootX, &rootY, &child)
        return (rootX, rootY)
    }
}

/// Xlib's and libXtst's calls, and the self-check's own connection to the X server.
@MainActor
private final class X {
    typealias OpenDisplay = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    typealias StringToKeysym = @convention(c) (UnsafePointer<CChar>?) -> UInt
    typealias KeysymToKeycode = @convention(c) (OpaquePointer?, UInt) -> UInt8
    typealias Flush = @convention(c) (OpaquePointer?) -> Int32
    typealias DefaultRoot = @convention(c) (OpaquePointer?) -> UInt
    typealias SetInputFocus = @convention(c) (OpaquePointer?, UInt, Int32, UInt) -> Int32
    typealias Translate =
        @convention(c) (
            OpaquePointer?, UInt, UInt, Int32, Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
            UnsafeMutablePointer<UInt>?
        ) -> Int32
    typealias FakeKey = @convention(c) (OpaquePointer?, UInt32, Int32, UInt) -> Int32
    typealias FakeButton = @convention(c) (OpaquePointer?, UInt32, Int32, UInt) -> Int32
    typealias FakeMotion = @convention(c) (OpaquePointer?, Int32, Int32, Int32, UInt) -> Int32
    typealias SurfaceXID = @convention(c) (OpaquePointer?) -> UInt

    let display: OpaquePointer
    let keysym: StringToKeysym
    let keycode: KeysymToKeycode
    let flush: Flush
    let root: DefaultRoot
    let setFocus: SetInputFocus
    let translate: Translate
    let fakeKey: FakeKey
    let fakeButton: FakeButton
    let fakeMotion: FakeMotion
    let surfaceXID: SurfaceXID

    private static var made: X?

    static func shared() throws -> X {
        if let made {
            return made
        }
        let x = try X()
        made = x
        return x
    }

    private init() throws {
        guard let xlib = dlopen("libX11.so.6", RTLD_NOW), let xtest = dlopen("libXtst.so.6", RTLD_NOW) else {
            throw SelfCheck.Failure("there's no Xlib or libXtst to press keys with")
        }
        func find<Function>(_ library: UnsafeMutableRawPointer?, _ name: String, as type: Function.Type) throws
            -> Function
        {
            guard let symbol = dlsym(library, name) else { throw SelfCheck.Failure("there's no \(name)") }
            return unsafeBitCast(symbol, to: type)
        }
        let open = try find(xlib, "XOpenDisplay", as: OpenDisplay.self)
        guard let display = open(nil) else {
            let name = ProcessInfo.processInfo.environment["DISPLAY"] ?? "none"
            throw SelfCheck.Failure("the X server, \(name), wouldn't connect")
        }
        self.display = display
        keysym = try find(xlib, "XStringToKeysym", as: StringToKeysym.self)
        keycode = try find(xlib, "XKeysymToKeycode", as: KeysymToKeycode.self)
        flush = try find(xlib, "XFlush", as: Flush.self)
        root = try find(xlib, "XDefaultRootWindow", as: DefaultRoot.self)
        setFocus = try find(xlib, "XSetInputFocus", as: SetInputFocus.self)
        translate = try find(xlib, "XTranslateCoordinates", as: Translate.self)
        fakeKey = try find(xtest, "XTestFakeKeyEvent", as: FakeKey.self)
        fakeButton = try find(xtest, "XTestFakeButtonEvent", as: FakeButton.self)
        fakeMotion = try find(xtest, "XTestFakeMotionEvent", as: FakeMotion.self)
        // GDK's X11 backend's own, which isn't in the headers the app is built against.
        guard let xid = Newer.lookup("gdk_x11_surface_get_xid", as: SurfaceXID.self) else {
            throw SelfCheck.Failure("GDK has no gdk_x11_surface_get_xid")
        }
        surfaceXID = xid
    }

    /// The X window of `window`'s surface.
    func window(of window: Widget) throws -> UInt {
        guard let native = gtk_widget_get_native(window), let surface = gtk_native_get_surface(native),
            typeName(raw(surface)).hasPrefix("GdkX11")
        else { throw SelfCheck.Failure("\(typeName(raw(window))) has no X window") }
        return surfaceXID(surface)
    }
}
