import Synchronization

/// Finds a cgroup's folder from its ID, which is the inode of its folder under `/sys/fs/cgroup`,
/// as the kernel gives it for a socket. cgroup2 only, which every system Reqly supports uses.
///
/// It keeps a map from walking the folders. A cgroup's ID isn't reused, so the map stays right,
/// and an ID it doesn't know means a cgroup made since, so it walks again, at most a few times a
/// second.
public final class CgroupIndex: Sendable {
    private struct State {
        /// Each cgroup's path under the root, such as `/user.slice/user-1000.slice/…`, by its ID.
        var paths: [UInt64: String] = [:]
        /// When each folder was last walked, by its path under the root.
        var walked: [String: ContinuousClock.Instant] = [:]
    }

    /// Where cgroup2 is mounted: `/sys/fs/cgroup`, or a folder laid out the same way in tests.
    public let root: String
    /// The least time between two walks of the same folder.
    private let interval: Duration
    private let state = Mutex(State())
    /// Held while a folder is walked, so a lookup that comes meanwhile waits for the walk and
    /// finds what it found, rather than going without.
    private let walking = Mutex(())

    public init(root: String = "/sys/fs/cgroup", interval: Duration = .milliseconds(250)) {
        self.root = root
        self.interval = interval
    }

    /// The path under the root of the cgroup with this ID, such as
    /// `/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-org.gnome.Calculator-7858.scope`,
    /// or `/` for the root itself. It looks first under the user's own slice, then everywhere,
    /// which covers system services.
    public func path(of id: UInt64, uid: UInt32) -> String? {
        if let known = state.withLock({ $0.paths[id] }) {
            return known
        }
        return walking.withLock { _ in
            // A walk that ended while this one waited may have found it.
            if let known = state.withLock({ $0.paths[id] }) {
                return known
            }
            for folder in ["/user.slice/user-\(uid).slice", ""] {
                guard claimWalk(of: folder) else { continue }
                let found = walk(folder)
                let path = state.withLock { state in
                    // Old cgroups' IDs are never reused, but they pile up.
                    if state.paths.count > 20_000 {
                        state.paths.removeAll()
                    }
                    state.paths.merge(found) { _, new in new }
                    return state.paths[id]
                }
                if let path {
                    return path
                }
            }
            return nil
        }
    }

    /// Walks your own slice, as the app lookup does as it's made, so the first connection finds
    /// the cgroups there known already.
    public func walkYourSlice(uid: UInt32) {
        let folder = "/user.slice/user-\(uid).slice"
        walking.withLock { _ in
            guard claimWalk(of: folder) else { return }
            let found = walk(folder)
            state.withLock { $0.paths.merge(found) { _, new in new } }
        }
    }

    /// The processes in a cgroup, from its `cgroup.procs`, which anyone may read.
    public func processes(in path: String) -> [Int32] {
        let file = (path == "/" ? root : root + path) + "/cgroup.procs"
        guard let text = LinuxFile.text(file) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// Whether a folder may be walked now, and if so, notes that it is.
    private func claimWalk(of folder: String) -> Bool {
        let now = ContinuousClock.now
        return state.withLock { state in
            if let last = state.walked[folder], now - last < interval {
                return false
            }
            state.walked[folder] = now
            return true
        }
    }

    /// Every cgroup in a folder under the root, and the folder itself, by ID.
    private func walk(_ folder: String) -> [UInt64: String] {
        var found: [UInt64: String] = [:]
        var waiting = [folder]
        while let next = waiting.popLast() {
            let full = root + next
            guard let id = LinuxFile.inode(full) else { continue }
            found[id] = next.isEmpty ? "/" : next
            for name in LinuxFile.entries(in: full).folders.sorted() {
                waiting.append(next + "/" + name)
            }
        }
        return found
    }
}
