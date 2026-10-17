/// What messages call the computer Reqly runs on: "Mac" on a Mac, and "PC" on Windows, as
/// Windows itself says.
public enum ThisComputer {
    #if os(macOS)
        public static let name = "Mac"
    #elseif os(Windows)
        public static let name = "PC"
    #else
        public static let name = "computer"
    #endif
}
