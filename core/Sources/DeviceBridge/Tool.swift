import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif os(Windows)
    import WinSDK
#endif

/// Runs a command-line tool, such as `adb` or Xcode's `simctl`, and collects what it prints.
public enum Tool {
    public struct Failure: Error, LocalizedError {
        public var tool: String
        public var message: String

        public var errorDescription: String? {
            message.isEmpty ? "\(tool) didn't finish." : message
        }
    }

    /// Runs the tool and returns what it printed. A tool that fails throws what it said about it.
    public static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) async throws -> String {
        let (status, text, errorText) = try await launch(
            executable, arguments, environment: environment, timeout: timeout)
        let name = executable.lastPathComponent
        guard status == 0 else {
            let message = (errorText.isEmpty ? text : errorText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(tool: name, message: message)
        }
        return text
    }

    #if os(Windows)
        /// Runs the tool until it ends, or for `timeout`, and returns its status and what it printed
        /// to its output and errors.
        private static func launch(
            _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration
        ) async throws -> (status: Int32, output: String, errors: String) {
            let tool = try WindowsTool(executable, arguments, environment: environment)
            let deadline = Task {
                try await Task.sleep(for: timeout)
                tool.stop()
            }
            defer { deadline.cancel() }
            // Both pipes are read as they fill, or a tool that prints a lot would wait for room.
            async let printed = tool.readOutput()
            async let complaints = tool.readErrors()
            let (text, errorText) = await (printed, complaints)
            return (await tool.status(), text, errorText)
        }
    #else
        /// Runs the tool until it ends, or for `timeout`, and returns its status and what it printed
        /// to its output and errors.
        private static func launch(
            _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration
        ) async throws -> (status: Int32, output: String, errors: String) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = { process in
                exited.yield(process.terminationStatus)
                exited.finish()
            }
            try process.run()
            let running = Running(process)
            let deadline = Task {
                try await Task.sleep(for: timeout)
                running.stop()
            }
            defer { deadline.cancel() }
            // Both pipes are read as they fill, or a tool that prints a lot would wait for room.
            async let printed = readAll(output.fileHandleForReading)
            async let complaints = readAll(errors.fileHandleForReading)
            let (text, errorText) = await (printed, complaints)
            var status: Int32 = -1
            for await code in exits {
                status = code
            }
            return (status, text, errorText)
        }

        private static func readAll(_ handle: FileHandle) async -> String {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = handle.readDataToEndOfFile()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        }

        /// A running tool, to stop once it takes too long.
        private final class Running: @unchecked Sendable {
            // Process is safe to stop from any thread.
            private let process: Process

            init(_ process: Process) {
                self.process = process
            }

            func stop() {
                guard process.isRunning else { return }
                #if os(Linux)
                    // A tool started from a thread that blocks signals, as the cooperative pool's do
                    // on Linux, starts with them blocked too, so it would never get SIGTERM.
                    // SIGKILL can't be blocked.
                    kill(process.processIdentifier, SIGKILL)
                #else
                    process.terminate()
                #endif
            }
        }
    #endif
}

#if os(Windows)
    /// A tool started on Windows with nothing to inherit but its input and its two pipes. Windows
    /// otherwise hands a new process every handle that can be inherited, Reqly's sockets among them,
    /// and a tool that kept them, as the adb server that adb starts and leaves running does, would
    /// keep Reqly's port taken after Reqly lets go of it.
    final class WindowsTool: @unchecked Sendable {
        // The handles are this object's own. Windows lets any thread use them, and they close once,
        // when it goes.
        private let process: HANDLE
        private let output: HANDLE
        private let errors: HANDLE

        init(_ executable: URL, _ arguments: [String], environment: [String: String]) throws {
            let name = executable.lastPathComponent
            func failure() -> Tool.Failure {
                Tool.Failure(tool: name, message: "Windows couldn't start \(name) (error \(GetLastError())).")
            }
            var inheritable = SECURITY_ATTRIBUTES(
                nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
            var outputRead: HANDLE?
            var outputWrite: HANDLE?
            var errorsRead: HANDLE?
            var errorsWrite: HANDLE?
            guard CreatePipe(&outputRead, &outputWrite, &inheritable, 0) else { throw failure() }
            guard CreatePipe(&errorsRead, &errorsWrite, &inheritable, 0) else {
                CloseHandle(outputRead)
                CloseHandle(outputWrite)
                throw failure()
            }
            let input = "NUL".withCString(encodedAs: UTF16.self) {
                CreateFileW(
                    $0, DWORD(truncatingIfNeeded: GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                    &inheritable, DWORD(OPEN_EXISTING), 0, nil)
            }
            // The tool's ends close here once it has its own copies, so the pipes end when it does.
            defer {
                CloseHandle(outputWrite)
                CloseHandle(errorsWrite)
                if input != INVALID_HANDLE_VALUE {
                    CloseHandle(input)
                }
            }
            // Reqly's ends stay out of the tool's reach.
            SetHandleInformation(outputRead, DWORD(HANDLE_FLAG_INHERIT), 0)
            SetHandleInformation(errorsRead, DWORD(HANDLE_FLAG_INHERIT), 0)
            var created = PROCESS_INFORMATION()
            let started = Self.create(
                executable, arguments, environment: environment,
                handles: [input == INVALID_HANDLE_VALUE ? nil : input, outputWrite, errorsWrite], into: &created)
            guard started, let process = created.hProcess, let outputRead, let errorsRead else {
                let problem = failure()
                CloseHandle(outputRead)
                CloseHandle(errorsRead)
                throw problem
            }
            CloseHandle(created.hThread)
            self.process = process
            output = outputRead
            errors = errorsRead
        }

        deinit {
            CloseHandle(process)
            CloseHandle(output)
            CloseHandle(errors)
        }

        func readOutput() async -> String { await read { $0.output } }

        func readErrors() async -> String { await read { $0.errors } }

        /// Reads a pipe until the tool's end of it closes.
        private func read(_ pipe: @escaping @Sendable (WindowsTool) -> HANDLE) async -> String {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = pipe(self)
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    var count: DWORD = 0
                    while ReadFile(handle, &buffer, DWORD(buffer.count), &count, nil), count > 0 {
                        data.append(buffer, count: Int(count))
                    }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        }

        /// The tool's exit code, once it ends.
        func status() async -> Int32 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    WaitForSingleObject(self.process, DWORD.max)
                    var code: DWORD = 0
                    GetExitCodeProcess(self.process, &code)
                    continuation.resume(returning: Int32(bitPattern: code))
                }
            }
        }

        func stop() {
            TerminateProcess(process, 1)
        }

        /// What `UpdateProcThreadAttribute` takes for the handles a new process may inherit,
        /// PROC_THREAD_ATTRIBUTE_HANDLE_LIST, a macro Swift doesn't bring in.
        private static let handleList: DWORD_PTR = 0x0002_0002

        /// Starts the program, letting it inherit `handles` and nothing else, with no console
        /// window of its own.
        private static func create(
            _ executable: URL, _ arguments: [String], environment: [String: String], handles: [HANDLE?],
            into created: inout PROCESS_INFORMATION
        ) -> Bool {
            // Windows reads the list when the program starts, so it lasts until then.
            let inherited = handles.compactMap { $0 }
            let list = UnsafeMutablePointer<HANDLE>.allocate(capacity: inherited.count)
            list.initialize(from: inherited, count: inherited.count)
            defer { list.deallocate() }
            var size: SIZE_T = 0
            _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { storage.deallocate() }
            let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(storage)
            guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else { return false }
            defer { DeleteProcThreadAttributeList(attributes) }
            let listSize = SIZE_T(MemoryLayout<HANDLE>.stride * inherited.count)
            guard UpdateProcThreadAttribute(attributes, 0, handleList, list, listSize, nil, nil) else { return false }
            var startup = STARTUPINFOEXW()
            startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
            startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.StartupInfo.hStdInput = handles[0]
            startup.StartupInfo.hStdOutput = handles[1]
            startup.StartupInfo.hStdError = handles[2]
            startup.lpAttributeList = attributes
            let program = executable.withUnsafeFileSystemRepresentation { String(cString: $0!) }
            var line = Array((["\"\(program)\""] + arguments.map(quoted)).joined(separator: " ").utf16) + [0]
            var block = environmentBlock(environment) ?? []
            var flags = DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW)
            if !block.isEmpty {
                flags |= DWORD(CREATE_UNICODE_ENVIRONMENT)
            }
            return program.withCString(encodedAs: UTF16.self) { program in
                line.withUnsafeMutableBufferPointer { line in
                    block.withUnsafeMutableBufferPointer { block in
                        withUnsafeMutablePointer(to: &startup) { startup in
                            startup.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                                CreateProcessW(
                                    program, line.baseAddress, nil, nil, true, flags,
                                    block.isEmpty ? nil : UnsafeMutableRawPointer(block.baseAddress), nil, startup,
                                    &created)
                            }
                        }
                    }
                }
            }
        }

        /// An argument quoted the way Windows programs split their command lines, so it arrives as
        /// it is.
        static func quoted(_ argument: String) -> String {
            guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else {
                return argument
            }
            var quoted = "\""
            var backslashes = 0
            for character in argument {
                if character == "\\" {
                    backslashes += 1
                    continue
                }
                // Backslashes count only before a quote, where each one needs another.
                let escapes = character == "\"" ? backslashes * 2 + 1 : backslashes
                quoted += String(repeating: "\\", count: escapes) + String(character)
                backslashes = 0
            }
            return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
        }

        /// Reqly's environment with `changes`, as Windows takes one: `NAME=value` pieces, each
        /// ending in a zero, sorted by name, then one more zero. `nil` keeps Reqly's as it is.
        private static func environmentBlock(_ changes: [String: String]) -> [UInt16]? {
            guard !changes.isEmpty else { return nil }
            var variables = ProcessInfo.processInfo.environment
            for (name, value) in changes {
                // Windows doesn't tell names apart by case.
                for existing in Array(variables.keys) where existing.caseInsensitiveCompare(name) == .orderedSame {
                    variables.removeValue(forKey: existing)
                }
                variables[name] = value
            }
            let sorted = variables.sorted { $0.key.uppercased() < $1.key.uppercased() }
            return sorted.flatMap { Array("\($0.key)=\($0.value)".utf16) + [0] } + [0]
        }
    }
#endif

extension Data {
    /// The certificate in PEM, the text form many tools take.
    public var pemCertificate: String {
        let lines = base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(lines)\n-----END CERTIFICATE-----\n"
    }
}
