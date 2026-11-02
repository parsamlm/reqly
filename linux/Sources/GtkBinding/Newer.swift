import CGtk
import Glibc

/// The libraries' versions as they run, which can be newer than the floor's headers the app was
/// built against.
public struct LibraryVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: UInt32
    public let minor: UInt32
    public let micro: UInt32

    public init(major: UInt32, minor: UInt32, micro: UInt32 = 0) {
        self.major = major
        self.minor = minor
        self.micro = micro
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.micro) < (rhs.major, rhs.minor, rhs.micro)
    }

    public var description: String { "\(major).\(minor).\(micro)" }
    public var short: String { "\(major).\(minor)" }

    public static var gtk: Self {
        Self(major: gtk_get_major_version(), minor: gtk_get_minor_version(), micro: gtk_get_micro_version())
    }

    public static var adwaita: Self {
        Self(major: adw_get_major_version(), minor: adw_get_minor_version(), micro: adw_get_micro_version())
    }

    /// Whether libadwaita is 1.`minor` or newer, such as 1.6 for accent colors.
    public static func adwaita(atLeast minor: UInt32) -> Bool {
        adwaita >= Self(major: 1, minor: minor)
    }
}

/// Functions newer than the floor's headers. Swift can't call what the headers don't declare, so
/// each is looked up as the app runs, after a version check, and called through a C function
/// pointer of the type the caller gives, such as
/// `@convention(c) () -> UnsafeMutablePointer<GtkWidget>?` for `adw_spinner_new`.
public enum Newer {
    nonisolated(unsafe) private static let process = dlopen(nil, RTLD_NOW)

    public static func lookup<Function>(_ name: String, as type: Function.Type) -> Function? {
        guard let symbol = dlsym(process, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
