/// The desktop you're logged in to, from `XDG_CURRENT_DESKTOP`, such as `ubuntu:GNOME` or `KDE`:
/// which proxy settings Reqly sets for it. Firefox reads GNOME's even on KDE, so on KDE Reqly sets
/// both.
public struct SessionDesktop: Hashable, Sendable {
    /// Whether it's GNOME, or a desktop built on it, such as Ubuntu's.
    public var isGNOME: Bool
    /// Whether it's KDE's Plasma.
    public var isKDE: Bool

    /// The desktop that `XDG_CURRENT_DESKTOP` names, as a list split by colons.
    public init(currentDesktop: String?) {
        let names = (currentDesktop ?? "").split(separator: ":").map { $0.uppercased() }
        isGNOME = names.contains("GNOME")
        isKDE = names.contains("KDE")
    }
}
