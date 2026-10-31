import Foundation
import Synchronization

/// The desktop entries of the apps on this computer, which name an app and its icon, found by
/// desktop ID or by the program a process runs.
///
/// It reads the folders the first time it's asked, and again when one of them has changed, which
/// it checks at most every few seconds, so newly installed apps are found.
public final class DesktopEntries: Sendable {
    /// A folder of desktop entries.
    public struct Folder: Hashable, Sendable {
        public var path: String
        /// Whether it holds autostart entries, such as `/etc/xdg/autostart`, which name what your
        /// desktop starts as you log in. They're found by desktop ID only, since an app's own
        /// entry, found by its program, is the one to show.
        public var isAutostart: Bool

        public init(path: String, isAutostart: Bool = false) {
            self.path = path
            self.isAutostart = isAutostart
        }
    }

    /// The entries, looked up each way.
    struct Index: Sendable {
        var byID: [String: DesktopEntry] = [:]
        /// Desktop IDs by each program's full path, as written and with links followed.
        var byProgram: [String: [String]] = [:]
        /// Desktop IDs by each program's file name, such as `firefox-esr`.
        var byName: [String: [String]] = [:]
        /// Desktop IDs by the folder each app is installed in, such as `/opt/google/chrome`.
        var byFolder: [String: [String]] = [:]
        var bySnap: [String: [String]] = [:]
        var byFlatpak: [String: [String]] = [:]
        /// Desktop IDs by window class, in lowercase.
        var byWindowClass: [String: [String]] = [:]
    }

    private struct State {
        var index: Index?
        /// When each folder last changed, by its path, when the index was made.
        var modified: [String: Int64?] = [:]
        var checked: ContinuousClock.Instant?
        /// Counts the times the index was made, so what was found with an older one can be told apart.
        var version = 0
    }

    public let folders: [Folder]
    private let locales: [String]
    private let searchPath: [String]
    private let interval: Duration
    private let state = Mutex(State())

    /// - Parameters:
    ///   - folders: Where entries are, the first folder's winning when two have the same ID.
    ///   - locales: Your languages, the most specific first.
    ///   - searchPath: The folders a program without a path is looked for in.
    ///   - interval: The least time between two checks of whether the folders changed.
    public init(
        folders: [Folder] = DesktopEntries.standardFolders(), locales: [String] = DesktopEntries.currentLocales(),
        searchPath: [String] = DesktopEntries.standardSearchPath(), interval: Duration = .seconds(3)
    ) {
        self.folders = folders
        self.locales = locales
        self.searchPath = searchPath
        self.interval = interval
    }

    /// The entry with this desktop ID.
    public func entry(id: String) -> DesktopEntry? {
        index().byID[id]
    }

    /// A snap's entries, the one named after the snap first, such as `firefox_firefox`.
    public func entries(ofSnap name: String) -> [DesktopEntry] {
        let index = index()
        let main = "\(name)_\(name)"
        let ids = (index.bySnap[name] ?? []).sorted { ($0 == main ? 0 : 1, $0) < ($1 == main ? 0 : 1, $1) }
        return ids.compactMap { index.byID[$0] }
    }

    /// The entry of the app a process runs: the one whose program it runs, then one of the snap
    /// or Flatpak it's in, then the one installed in the folder its program is in, then the one
    /// whose program has its name. Entries of programs that run in a terminal, such as htop, are
    /// left out: they're tools.
    /// - Parameter flatpakID: The Flatpak the process runs in, if that's known.
    public func entry(for process: RunningProcess, flatpakID: String? = nil) -> DesktopEntry? {
        let index = index()
        func best(_ ids: [String]?) -> DesktopEntry? {
            let entries = (ids ?? []).compactMap { index.byID[$0] }
            return entries.first { !$0.noDisplay } ?? entries.first
        }
        let programs = process.programs
        for program in programs {
            let ids = index.byProgram[program] ?? LinuxFile.resolved(program).flatMap { index.byProgram[$0] }
            if let found = best(ids) {
                return found
            }
        }
        for program in programs where program.hasPrefix("/snap/") {
            // /snap/<snap>/<revision>/…
            let parts = program.split(separator: "/")
            if parts.count > 1 {
                let snap = String(parts[1])
                let entries = entries(ofSnap: snap)
                if let found = entries.first(where: { $0.id == "\(snap)_\(process.name)" }) ?? entries.first {
                    return found
                }
            }
        }
        if let flatpakID, let found = best(index.byFlatpak[flatpakID]) ?? index.byID[flatpakID] {
            return found
        }
        for program in programs {
            var folder = LinuxFile.folder(program)
            while folder.count > 1 {
                if let found = best(index.byFolder[folder]) {
                    return found
                }
                folder = LinuxFile.folder(folder)
            }
        }
        for name in programs.map(LinuxFile.fileName) + [process.name] {
            if let found = best(index.byName[name]) {
                return found
            }
        }
        return best(index.byWindowClass[process.name.lowercased()])
    }

    /// A number that changes each time the entries are read again.
    public var version: Int {
        _ = index()
        return state.withLock(\.version)
    }

    /// The index, read again when a folder has changed.
    private func index() -> Index {
        let now = ContinuousClock.now
        let current = state.withLock { state -> (index: Index, modified: [String: Int64?])? in
            if let index = state.index, let checked = state.checked, now - checked < interval {
                return (index, [:])
            }
            state.checked = now
            return state.index.map { ($0, state.modified) }
        }
        if let current, current.modified.isEmpty {
            return current.index
        }
        let modified = Dictionary(folders.map { ($0.path, LinuxFile.modified($0.path)) }) { first, _ in first }
        if let current, current.modified == modified {
            return current.index
        }
        let index = read()
        state.withLock { state in
            state.index = index
            state.modified = modified
            state.version += 1
        }
        return index
    }

    /// Reads every folder's entries into an index.
    private func read() -> Index {
        var index = Index()
        // IDs a folder that comes first has, or hides.
        var taken: Set<String> = []
        for folder in folders {
            for (id, file) in Self.files(in: folder.path) where !taken.contains(id) {
                guard let contents = LinuxFile.text(file, limit: 256 * 1024),
                    let entry = DesktopEntry(
                        id: id, file: file, contents: contents, locales: locales, searchPath: searchPath)
                else { continue }
                taken.insert(id)
                guard !entry.hidden else { continue }
                index.byID[id] = entry
                if !folder.isAutostart && !entry.runsInTerminal {
                    add(entry, to: &index)
                }
            }
        }
        return index
    }

    private func add(_ entry: DesktopEntry, to index: inout Index) {
        func note(_ key: String, in table: WritableKeyPath<Index, [String: [String]]>) {
            if index[keyPath: table][key]?.contains(entry.id) != true {
                index[keyPath: table][key, default: []].append(entry.id)
            }
        }
        if let snap = entry.snapName {
            note(snap, in: \.bySnap)
        }
        if let flatpak = entry.flatpakID {
            note(flatpak, in: \.byFlatpak)
        }
        if let windowClass = entry.startupWMClass?.lowercased() {
            note(windowClass, in: \.byWindowClass)
        }
        for program in [entry.program, entry.tryExec.map { DesktopEntry.locate($0, in: searchPath) }] {
            guard let program else { continue }
            note(LinuxFile.fileName(program), in: \.byName)
            guard program.hasPrefix("/") else { continue }
            note(program, in: \.byProgram)
            // A snap's program is a link to snap itself, which every snap shares.
            guard !program.hasPrefix("/snap/bin/"), let resolved = LinuxFile.resolved(program) else { continue }
            note(resolved, in: \.byProgram)
            if let folder = Self.installFolder(of: resolved) {
                note(folder, in: \.byFolder)
            }
        }
    }

    /// The folder an app is installed in, from its program, such as `/opt/google/chrome` for
    /// `/opt/google/chrome/google-chrome`, or `/usr/share/code` for `/usr/share/code/bin/code`.
    /// `nil` when the program is in a folder many programs share, such as `/usr/bin`.
    static func installFolder(of program: String) -> String? {
        var folder = LinuxFile.folder(program)
        if ["bin", "sbin"].contains(LinuxFile.fileName(folder)) {
            folder = LinuxFile.folder(folder)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shared = [
            "/usr", "/usr/local", "/usr/lib", "/usr/lib64", "/usr/libexec", "/usr/share", "/usr/games", "/opt",
        ]
        let parent = LinuxFile.folder(folder)
        guard folder.split(separator: "/").count >= 2, !shared.contains(where: folder.hasSuffix),
            folder != home, folder != home + "/.local", !(folder + "/").contains("/exports/"),
            // Such as /usr/lib/x86_64-linux-gnu.
            !(parent.hasSuffix("/usr/lib") && LinuxFile.fileName(folder).contains("-linux-"))
        else { return nil }
        return folder
    }

    /// Each `.desktop` file in a folder and its subfolders, by desktop ID.
    static func files(in folder: String) -> [(id: String, file: String)] {
        var found: [(id: String, file: String)] = []
        var waiting = [(folder, "")]
        while let (path, prefix) = waiting.popLast() {
            let (listing, folders) = LinuxFile.entries(in: path)
            guard case .names(let names) = listing else { continue }
            for name in names.sorted() {
                if folders.contains(name) {
                    waiting.append((path + "/" + name, prefix + name + "-"))
                } else if name.hasSuffix(".desktop") {
                    found.append((prefix + name.dropLast(".desktop".count), path + "/" + name))
                }
            }
        }
        return found
    }

    /// Where desktop entries are, as the XDG Base Directory Specification and the Desktop Entry
    /// Specification say: your own, then each of `XDG_DATA_DIRS`, then Flatpak's and snapd's,
    /// which `XDG_DATA_DIRS` usually lists already, then the autostart folders.
    public static func standardFolders(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Folder] {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        let dataFolders =
            (environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share")
            .split(separator: ":").map(String.init)
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let configFolders = (environment["XDG_CONFIG_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/etc/xdg")
            .split(separator: ":").map(String.init)
        var paths = ([dataHome] + dataFolders).map { $0 + "/applications" }
        paths += [
            dataHome + "/flatpak/exports/share/applications", "/var/lib/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications",
        ]
        var seen: Set<String> = []
        var folders = paths.filter { seen.insert(Self.trimmingSlash($0)).inserted }.map { Folder(path: $0) }
        folders += ([configHome] + configFolders).map { Folder(path: $0 + "/autostart", isAutostart: true) }
        return folders
    }

    /// Your languages for entries' names, from `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG`, as
    /// GLib reads them: for `de_DE.UTF-8@euro`, `de_DE@euro`, `de_DE`, `de@euro` and `de`.
    public static func currentLocales(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let main = ["LC_ALL", "LC_MESSAGES", "LANG"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty }
        let languages =
            (environment["LANGUAGE"] ?? "").split(separator: ":").map(String.init) + [main].compactMap { $0 }
        var locales: [String] = []
        for language in languages {
            for locale in variants(of: language) where !locales.contains(locale) {
                locales.append(locale)
            }
        }
        return locales
    }

    /// The forms of a locale an entry's keys may use, the most specific first.
    static func variants(of locale: String) -> [String] {
        var rest = Substring(locale)
        var modifier: Substring?
        if let at = rest.firstIndex(of: "@") {
            modifier = rest[rest.index(after: at)...]
            rest = rest[..<at]
        }
        if let dot = rest.firstIndex(of: ".") {
            rest = rest[..<dot]
        }
        guard !rest.isEmpty, rest != "C", rest != "POSIX" else { return [] }
        var language = rest
        var country: Substring?
        if let underscore = rest.firstIndex(of: "_") {
            language = rest[..<underscore]
            country = rest[rest.index(after: underscore)...]
        }
        var variants: [String] = []
        if let country, let modifier { variants.append("\(language)_\(country)@\(modifier)") }
        if let country { variants.append("\(language)_\(country)") }
        if let modifier { variants.append("\(language)@\(modifier)") }
        variants.append(String(language))
        return variants
    }

    /// Where programs are looked for: `PATH`, then the folders desktops add, such as snapd's.
    public static func standardSearchPath(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [String]
    {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [
            "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin", "/usr/games",
            "/usr/local/games", "/snap/bin",
        ]
        return path + usual.filter { !path.contains($0) }
    }

    private static func trimmingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
