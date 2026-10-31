import LinuxDesktop

/// What Reqly notes as it runs, such as why something failed, on its standard error, which
/// `--log-file` sends to a file, as the watcher's notes go.
enum AppLog {
    static func write(_ message: String) {
        StandardError.write("Reqly: \(message)\n")
    }
}
