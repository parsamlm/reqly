#if os(macOS)
    import Darwin
    import Foundation

    /// Reads the Mac's process table: which process holds which connection, where its program
    /// lives, and which app it works for. Processes of other users can't be read.
    enum ProcessTable {
        /// One connection to the proxy, by its two ports.
        struct Endpoint: Hashable, Sendable {
            /// The connection's port on the app's side.
            var clientPort: Int
            var proxyPort: Int
        }

        /// The processes holding connections to any of `proxyPorts`, by connection.
        static func owners(ofConnectionsTo proxyPorts: Set<Int>) -> [Endpoint: pid_t] {
            var owners: [Endpoint: pid_t] = [:]
            for pid in allProcesses() {
                for descriptor in socketDescriptors(of: pid) {
                    guard let ports = tcpPorts(of: pid, descriptor: descriptor), proxyPorts.contains(ports.remote)
                    else { continue }
                    owners[Endpoint(clientPort: ports.local, proxyPort: ports.remote)] = pid
                }
            }
            return owners
        }

        /// The path of the program a process runs.
        static func path(of pid: pid_t) -> String? {
            var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        }

        /// The process macOS holds responsible for `pid`: for an XPC service, usually the app it
        /// works for, such as Safari for WebKit's networking process.
        static func responsibleProcess(for pid: pid_t) -> pid_t? {
            guard let responsible = responsibleFunction?(pid), responsible > 0 else { return nil }
            return responsible
        }

        private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

        /// macOS's private `responsibility_get_pid_responsible_for_pid`. If a future macOS drops
        /// it, services are credited by their own names instead.
        private static let responsibleFunction: ResponsibleFunction? = {
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else {
                return nil
            }
            return unsafeBitCast(symbol, to: ResponsibleFunction.self)
        }()

        /// The arguments a process started with. macOS shows them for your own processes, but
        /// keeps every other process's environment to itself.
        static func arguments(of pid: pid_t) -> [String]? {
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            var limit: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctl(&mib, 2, &limit, &size, nil, 0) == 0, limit > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(limit))
            size = buffer.count
            mib = [CTL_KERN, KERN_PROCARGS2, pid]
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
            return parseArguments(buffer.prefix(size))
        }

        /// Reads the arguments from what `KERN_PROCARGS2` gives: their number, the program's path,
        /// then the arguments, each ending in a zero byte.
        static func parseArguments(_ bytes: some Collection<UInt8>) -> [String]? {
            let bytes = Array(bytes)
            guard bytes.count >= 4 else { return nil }
            let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            var index = 4
            // The program's path, then zero bytes up to the first argument.
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            while index < bytes.count, bytes[index] == 0 { index += 1 }
            var arguments: [String] = []
            while index < bytes.count, arguments.count < count {
                let start = index
                while index < bytes.count, bytes[index] != 0 { index += 1 }
                arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
                index += 1
            }
            return arguments
        }

        /// The process that started `pid`, unless that's launchd.
        static func parent(of pid: pid_t) -> pid_t? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let parent = pid_t(info.pbi_ppid)
            return parent > 1 ? parent : nil
        }

        /// The processes whose programs `program` says yes to, such as every Android emulator.
        static func processes(running program: (String) -> Bool) -> [pid_t] {
            allProcesses().filter { path(of: $0).map(program) ?? false }
        }

        private static func allProcesses() -> [pid_t] {
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return [] }
            // Room for processes that start meanwhile.
            var pids = [pid_t](repeating: 0, count: Int(count) + 64)
            let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            return pids.prefix(Int(max(listed, 0))).filter { $0 > 0 }
        }

        private static func socketDescriptors(of pid: pid_t) -> [Int32] {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { return [] }
            let stride = MemoryLayout<proc_fdinfo>.stride
            // Room for files opened meanwhile.
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
            guard used > 0 else { return [] }
            return descriptors.prefix(Int(used) / stride)
                .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
                .map(\.proc_fd)
        }

        /// A TCP socket's local and remote ports.
        private static func tcpPorts(of pid: pid_t, descriptor: Int32) -> (local: Int, remote: Int)? {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size,
                info.psi.soi_kind == Int32(SOCKINFO_TCP)
            else { return nil }
            let addresses = info.psi.soi_proto.pri_tcp.tcpsi_ini
            // The kernel keeps ports in network byte order.
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: addresses.insi_lport)))
            let remote = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: addresses.insi_fport)))
            return (local, remote)
        }
    }

#endif
