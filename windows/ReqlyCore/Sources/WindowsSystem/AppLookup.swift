#if os(Windows)
    import DeviceBridge
    import Foundation
    import ReqlyModel
    import Synchronization
    import WinSDK

    /// Finds which app on this computer opened a connection to Reqly, from Windows' table of TCP
    /// connections and the app's own file. An Android emulator's connections go to the emulator, as
    /// a device, as on the Mac.
    public final class AppLookup: Sendable {
        /// What a process works for. A process's ID can come back for another program, so its
        /// program is kept too.
        private struct Known {
            var path: String
            var device: Device?
        }

        /// App names by the path of their file, since reading a file's version takes a moment.
        private let names = Mutex<[String: String]>([:])
        /// The emulator each process works for, if any, by process.
        private let devices = Mutex<[UInt32: Known]>([:])

        public init() {}

        /// What opened the connection from `clientPort` to `proxyPort`: an app on this computer, or
        /// an Android emulator.
        public func origin(clientPort: Int, proxyPort: Int) -> Origin? {
            guard let id = Self.processID(clientPort: clientPort, proxyPort: proxyPort),
                let path = Self.path(of: id)
            else { return nil }
            if let device = device(of: id, path: path) {
                // An emulator's own process isn't an app: the app runs inside it, out of sight.
                return Origin(device: device)
            }
            return Origin(source: source(atPath: path))
        }

        private func source(atPath path: String) -> Source {
            if let name = names.withLock({ $0[path] }) {
                return Source(name: name, path: path)
            }
            let name = Self.name(ofApp: path)
            names.withLock { names in
                if names.count > 1_000 {
                    names.removeAll()
                }
                names[path] = name
            }
            return Source(name: name, path: path)
        }

        /// The Android emulator a process works for, if it does.
        private func device(of processID: UInt32, path: String) -> Device? {
            if let known = devices.withLock({ $0[processID] }), known.path == path {
                return known.device
            }
            let device = EmulatorProcesses.device(
                ofProgram: path, arguments: { Self.arguments(of: processID) },
                emulators: {
                    Self.processes(running: EmulatorProcesses.isEmulator).compactMap(Self.arguments(of:))
                })
            // The emulators netsimd works for come and go, so its device is found afresh each time.
            if !EmulatorProcesses.isEmulatorWiFi(path) {
                devices.withLock { devices in
                    if devices.count > 1_000 {
                        devices.removeAll()
                    }
                    devices[processID] = Known(path: path, device: device)
                }
            }
            return device
        }

        /// The process whose connection from `clientPort` goes to `proxyPort` on this computer.
        public static func processID(clientPort: Int, proxyPort: Int) -> UInt32? {
            let ipv4 = owner(MIB_TCPROW_OWNER_PID.self, family: AF_INET) {
                port($0.dwLocalPort) == clientPort && port($0.dwRemotePort) == proxyPort ? $0.dwOwningPid : nil
            }
            return ipv4
                ?? owner(MIB_TCP6ROW_OWNER_PID.self, family: AF_INET6) {
                    port($0.dwLocalPort) == clientPort && port($0.dwRemotePort) == proxyPort ? $0.dwOwningPid : nil
                }
        }

        /// Looks through one of Windows' connection tables, for IPv4 or IPv6.
        private static func owner<Row>(_ row: Row.Type, family: Int32, matching: (Row) -> UInt32?) -> UInt32? {
            var size: DWORD = 0
            var buffer: [UInt8] = []
            // The table can grow between asking its size and reading it.
            for _ in 0..<4 {
                buffer = [UInt8](repeating: 0, count: Int(size))
                let result = buffer.withUnsafeMutableBytes { bytes in
                    GetExtendedTcpTable(
                        bytes.baseAddress, &size, false, ULONG(family), TCP_TABLE_OWNER_PID_CONNECTIONS, 0)
                }
                if result == DWORD(NO_ERROR) {
                    return buffer.withUnsafeBytes { bytes in
                        // The table is a count, then that many rows. Rows hold only 4-byte numbers
                        // and bytes, so they start right after the count.
                        let count = Int(bytes.load(as: DWORD.self))
                        let rows = bytes.baseAddress!.advanced(by: MemoryLayout<DWORD>.size)
                            .assumingMemoryBound(to: Row.self)
                        for index in 0..<count {
                            if let id = matching(rows[index]) {
                                return id
                            }
                        }
                        return nil
                    }
                }
                guard result == DWORD(ERROR_INSUFFICIENT_BUFFER) else { return nil }
            }
            return nil
        }

        /// Ports are kept in network byte order, in the low 16 bits.
        static func port(_ value: DWORD) -> Int {
            Int(UInt16(truncatingIfNeeded: value).byteSwapped)
        }

        /// The full path of a process's program.
        public static func path(of processID: UInt32) -> String? {
            guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID) else {
                return nil
            }
            defer { CloseHandle(process) }
            var buffer = [WCHAR](repeating: 0, count: 32_768)
            var size = DWORD(buffer.count)
            guard QueryFullProcessImageNameW(process, 0, &buffer, &size) else { return nil }
            return String(decoding: buffer[..<Int(size)], as: UTF16.self)
        }

        /// The arguments a process was started with, read from its command line.
        public static func arguments(of processID: UInt32) -> [String]? {
            guard let query = queryInformationProcess(),
                let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
            else { return nil }
            defer { CloseHandle(process) }
            // The first call says how much room the command line takes.
            var length: ULONG = 0
            _ = query(process, processCommandLineInformation, nil, 0, &length)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(length))
            return buffer.withUnsafeMutableBytes { bytes -> [String]? in
                guard query(process, processCommandLineInformation, bytes.baseAddress, length, &length) >= 0,
                    let base = bytes.baseAddress
                else { return nil }
                // A UNICODE_STRING: the line's length in bytes, then, a pointer's size in, a pointer
                // to its characters, which Windows puts right after it, in the same buffer.
                let size = Int(bytes.load(as: UInt16.self))
                let start = bytes.load(fromByteOffset: MemoryLayout<UInt>.size, as: UInt.self)
                let end = UInt(bitPattern: base) + UInt(bytes.count)
                guard size > 0, start >= UInt(bitPattern: base), start + UInt(size) <= end,
                    let characters = UnsafePointer<UInt16>(bitPattern: start)
                else { return nil }
                let line = String(decoding: UnsafeBufferPointer(start: characters, count: size / 2), as: UTF16.self)
                return split(commandLine: line)
            }
        }

        /// A command line split into its arguments, as Windows splits a program's own.
        public static func split(commandLine: String) -> [String] {
            var count: Int32 = 0
            guard let arguments = commandLine.withCString(encodedAs: UTF16.self, { CommandLineToArgvW($0, &count) })
            else { return [] }
            defer { LocalFree(arguments) }
            return (0..<Int(count)).compactMap { index in
                arguments[index].map { String(decodingCString: $0, as: UTF16.self) }
            }
        }

        /// The processes whose program's file name passes `test`, such as `qemu-system-x86_64.exe`.
        public static func processes(running test: (String) -> Bool) -> [UInt32] {
            guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
                snapshot != INVALID_HANDLE_VALUE
            else { return [] }
            defer { CloseHandle(snapshot) }
            var entry = PROCESSENTRY32W()
            entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
            var found: [UInt32] = []
            var more = Process32FirstW(snapshot, &entry)
            while more {
                let name = withUnsafeBytes(of: entry.szExeFile) { bytes in
                    String(decodingCString: bytes.assumingMemoryBound(to: UInt16.self).baseAddress!, as: UTF16.self)
                }
                if test(name) {
                    found.append(entry.th32ProcessID)
                }
                more = Process32NextW(snapshot, &entry)
            }
            return found
        }

        /// What NtQueryInformationProcess reads for the command line, since Windows 8.1.
        private static let processCommandLineInformation: Int32 = 60

        /// The process, what to read, where to put it and how much room it has, and how much it took.
        private typealias QueryInformationProcess =
            @convention(c) (HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG

        /// ntdll's NtQueryInformationProcess, which reads another process's command line. It has no
        /// import library, so it's looked up in ntdll, which every process has loaded.
        private static func queryInformationProcess() -> QueryInformationProcess? {
            guard let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
                let address = GetProcAddress(ntdll, "NtQueryInformationProcess")
            else { return nil }
            return unsafeBitCast(address, to: QueryInformationProcess.self)
        }

        /// An app's name: the description in its file's version, as Task Manager shows it, or else
        /// the file's name.
        public static func name(ofApp path: String) -> String {
            description(ofFile: path) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }

        private static func description(ofFile path: String) -> String? {
            path.withCString(encodedAs: UTF16.self) { file -> String? in
                var ignored: DWORD = 0
                let size = GetFileVersionInfoSizeW(file, &ignored)
                guard size > 0 else { return nil }
                var version = [UInt8](repeating: 0, count: Int(size))
                return version.withUnsafeMutableBytes { block -> String? in
                    guard GetFileVersionInfoW(file, 0, size, block.baseAddress) else { return nil }
                    // The first language the file describes itself in.
                    var translation: UnsafeMutableRawPointer?
                    var length: UINT = 0
                    let found = "\\VarFileInfo\\Translation".withCString(encodedAs: UTF16.self) {
                        VerQueryValueW(block.baseAddress, $0, &translation, &length)
                    }
                    guard found, length >= 4, let translation else { return nil }
                    let language = translation.load(as: UInt16.self)
                    let codePage = translation.load(fromByteOffset: 2, as: UInt16.self)
                    let key = "\\StringFileInfo\\\(hex(language))\(hex(codePage))\\FileDescription"
                    var value: UnsafeMutableRawPointer?
                    var count: UINT = 0
                    let described = key.withCString(encodedAs: UTF16.self) {
                        VerQueryValueW(block.baseAddress, $0, &value, &count)
                    }
                    guard described, count > 1, let value else { return nil }
                    let text = String(decodingCString: value.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
                        .trimmingCharacters(in: .whitespaces)
                    return text.isEmpty ? nil : text
                }
            }
        }

        private static func hex(_ value: UInt16) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: 4 - digits.count) + digits
        }
    }
#endif
