import DeviceBridge
import Glibc
import ReqlyModel
import Synchronization

/// Finds which app on this computer opened a connection to Reqly, with no privileges: the kernel
/// says which user, socket and cgroup it belongs to, the cgroup's unit names the app, and the
/// process that has the socket open says which program, or which Android emulator, it is. Its
/// name comes from the app's desktop entry.
///
/// Ask while the connection is open, as the core does as it accepts one: a closed socket has no
/// owner. A lookup takes a fraction of a millisecond once the desktop entries are read.
public final class AppLookup: Sendable {
    /// A connection, by its two ports.
    private struct Connection: Hashable {
        var clientPort: Int
        var proxyPort: Int
    }

    /// A process in a cgroup, which a later process can't be mistaken for, since it started at
    /// another time, with the desktop entries it was credited with.
    private struct Credited: Hashable {
        var cgroup: UInt64
        var pid: Int32
        var started: UInt64
        var entries: Int
    }

    private struct State {
        /// What each open connection was credited to, with its socket's inode, which tells it from
        /// a later connection on the same ports.
        var connections: [Connection: (inode: UInt64, origin: Origin?)] = [:]
        var credits: [Credited: Origin?] = [:]
        /// The process that had the last socket found in each cgroup, which is likely to have the
        /// next, as Firefox's main process has them all.
        var holders: [UInt64: Int32] = [:]
    }

    public let entries: DesktopEntries
    public let cgroups: CgroupIndex
    /// Where processes are described: `/proc`.
    private let proc: String
    private let state = Mutex(State())

    public init(
        entries: DesktopEntries = DesktopEntries(), cgroups: CgroupIndex = CgroupIndex(), proc: String = "/proc"
    ) {
        self.entries = entries
        self.cgroups = cgroups
        self.proc = proc
        // Reads the desktop entries now, so the first connection doesn't wait for them.
        Task.detached(priority: .utility) { [entries] in
            _ = entries.version
        }
    }

    /// What opened the connection from `clientPort` to `proxyPort` on this computer: an app, a
    /// command-line tool, or an Android emulator. `nil` when the connection has closed, or
    /// nothing says what opened it.
    public func origin(clientPort: Int, proxyPort: Int) -> Origin? {
        guard let owner = SocketOwner.ofConnection(clientPort: clientPort, proxyPort: proxyPort), owner.inode != 0
        else { return nil }
        let connection = Connection(clientPort: clientPort, proxyPort: proxyPort)
        if let known = state.withLock({ $0.connections[connection] }), known.inode == owner.inode {
            return known.origin
        }
        let origin = origin(of: owner)
        state.withLock { state in
            if state.connections.count > 512 {
                state.connections.removeAll()
            }
            state.connections[connection] = (owner.inode, origin)
        }
        return origin
    }

    /// What opened the socket the kernel says `owner` owns.
    public func origin(of owner: SocketOwner) -> Origin? {
        let path = owner.cgroupID.flatMap { cgroups.path(of: $0, uid: owner.uid) }
        let unit = path.map(SystemdUnit.init(cgroupPath:)) ?? SystemdUnit(name: "", kind: .other)
        let members = path.map(cgroups.processes(in:)) ?? []

        // The process that has the socket: the cgroup's, the likeliest first, then any.
        let likely = owner.cgroupID.flatMap { id in state.withLock { $0.holders[id] } }
        var order: [Int32] = []
        for pid in [likely, unit.pid].compactMap({ $0 }) + members.sorted() where !order.contains(pid) {
            order.append(pid)
        }
        var (holder, hidden) = Processes.holder(ofSocket: owner.inode, among: order, in: proc)
        // A socket keeps the cgroup it was made in, so its process may have moved since, as a
        // command started as a GNOME Terminal window opens does. Another user's processes can't
        // be read.
        if holder == nil, hidden.isEmpty, owner.uid == getuid() || getuid() == 0 {
            let tried = Set(order)
            let rest = Processes.all(in: proc).filter { !tried.contains($0) }
            holder = Processes.holder(ofSocket: owner.inode, among: rest, in: proc).pid
        }
        if let holder, let id = owner.cgroupID {
            state.withLock { state in
                if state.holders.count > 1_000 {
                    state.holders.removeAll()
                }
                state.holders[id] = holder
            }
        }
        // A process that hides its open files, such as ssh-agent, still shows its name. When it's
        // the only one in the cgroup that does, it's the one.
        let pid = holder ?? (hidden.count == 1 ? hidden[0] : nil)

        let credited = pid.flatMap { pid in
            Processes.startTime(of: pid, in: proc).map {
                // Found again once its cgroup's folder is known, if it wasn't this time.
                Credited(cgroup: path == nil ? 0 : owner.cgroupID ?? 0, pid: pid, started: $0, entries: entries.version)
            }
        }
        if let credited, let known = state.withLock({ $0.credits[credited] }) {
            return known
        }
        let process = pid.flatMap { Processes.read($0, in: proc) }
        let origin = origin(of: process, unit: unit, members: members)
        if let credited, !(process?.path.map(EmulatorProcesses.isEmulatorWiFi) ?? false) {
            // The emulators netsimd works for come and go, so its device is found afresh each time.
            state.withLock { state in
                if state.credits.count > 1_000 {
                    state.credits.removeAll()
                }
                state.credits[credited] = origin
            }
        }
        return origin
    }

    private func origin(of process: RunningProcess?, unit: SystemdUnit, members: [Int32]) -> Origin? {
        if let process,
            let device = Crediting.device(of: process, emulators: { [proc] in Self.emulators(in: proc) })
        {
            // An emulator's own process isn't an app: the app runs inside it, out of sight.
            return Origin(device: device)
        }
        let leader = (unit.pid.flatMap { members.contains($0) ? $0 : nil } ?? members.min()).flatMap {
            Processes.program(of: $0, in: proc)
        }
        var flatpakID: String?
        if case .flatpak(let id) = unit.kind {
            flatpakID = id
        } else if let process, process.path?.hasPrefix("/app/") == true {
            flatpakID = Processes.flatpakID(of: process.pid, in: proc)
        }
        let source = Crediting.source(
            unit: unit, process: process, leader: leader, entries: entries, flatpakID: flatpakID)
        return source.map { Origin(source: $0) }
    }

    /// The arguments of each Android emulator that's running.
    private static func emulators(in proc: String) -> [[String]] {
        Processes.all(in: proc).compactMap { pid in
            guard let arguments = Processes.arguments(of: pid, in: proc), let program = arguments.first,
                EmulatorProcesses.isEmulator(program)
            else { return nil }
            return arguments
        }
    }
}
