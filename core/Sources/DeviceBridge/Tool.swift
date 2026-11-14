import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif os(Windows)
    import WinSDK
#endif

#if os(Linux)
    import Synchronization
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
    #elseif os(Linux)
        /// Runs the tool until it ends, or for `timeout`, and returns its status and what it printed
        /// to its output and errors before it ended.
        private static func launch(
            _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration
        ) async throws -> (status: Int32, output: String, errors: String) {
            let tool = try LinuxTool(executable, arguments, environment: environment)
            let deadline = Task {
                try await Task.sleep(for: timeout)
                tool.stop()
            }
            defer { deadline.cancel() }
            let ended = await tool.finish()
            let text = String(decoding: ended.output, as: UTF8.self)
            return (ended.status, text, String(decoding: ended.errors, as: UTF8.self))
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
                process.terminate()
            }
        }
    #endif
}

#if os(Linux)
    /// A tool started on Linux with nothing of Reqly's but its two pipes, input from /dev/null, and
    /// every signal as a new program has it. Foundation's `Process` would hand it a socket of its
    /// own, and report the end only once every copy of that socket closed, so a program the tool
    /// leaves running, as adb leaves its server, would hold up the call until it quit. Here, the
    /// call ends with the tool: a thread of its own waits for the tool's end, another reads both
    /// pipes as they fill, and once the tool has ended, what's left in them is read without
    /// waiting, since a program it left running may keep them open. Neither thread is one of
    /// Swift's, which a wait would hold up.
    final class LinuxTool: @unchecked Sendable {
        private struct State {
            var hasEnded = false
            var status: Int32 = -1
        }

        // The descriptors are this object's own: the pipes' ends are read and closed by `finish`,
        // the end's pipe closes when it goes.
        private let pid: pid_t
        private let output: Int32
        private let errors: Int32
        /// Turns readable once the tool has ended.
        private let ended: (read: Int32, write: Int32)
        private let state = Mutex(State())

        init(_ executable: URL, _ arguments: [String], environment: [String: String]) throws {
            let name = executable.lastPathComponent
            func failure(_ error: Int32) -> Tool.Failure {
                let reason = String(cString: strerror(error))
                return Tool.Failure(tool: name, message: "Linux couldn't start \(name) (\(reason)).")
            }
            var pipes: [(read: Int32, write: Int32)] = []
            for _ in 0..<3 {
                guard let pipe = Self.makePipe() else {
                    let error = errno
                    for pipe in pipes {
                        close(pipe.read)
                        close(pipe.write)
                    }
                    throw failure(error)
                }
                pipes.append(pipe)
            }
            let path = executable.path(percentEncoded: false)
            let variables = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            var pid: pid_t = 0
            let error = Self.spawn(
                path, [path] + arguments, variables.map { "\($0.key)=\($0.value)" }, output: pipes[0].write,
                errors: pipes[1].write, into: &pid)
            // The tool's ends close here once it has its own copies, so the pipes end when it does.
            close(pipes[0].write)
            close(pipes[1].write)
            guard error == 0 else {
                close(pipes[0].read)
                close(pipes[1].read)
                close(pipes[2].read)
                close(pipes[2].write)
                throw failure(error)
            }
            self.pid = pid
            output = pipes[0].read
            errors = pipes[1].read
            ended = pipes[2]
        }

        deinit {
            close(ended.read)
            close(ended.write)
        }

        /// Waits for the tool to end, and gives its status, as its exit code or 128 and the signal
        /// that ended it, and what it printed to its output and errors until then.
        func finish() async -> (status: Int32, output: Data, errors: Data) {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread { self.waitForEnd() }
                Thread.detachNewThread {
                    let (output, errors) = self.collect()
                    continuation.resume(returning: (self.state.withLock { $0.status }, output, errors))
                }
            }
        }

        /// Ends the tool, unless it has ended. SIGKILL ends it even if it ignores other signals.
        func stop() {
            state.withLock { state in
                if !state.hasEnded {
                    kill(pid, SIGKILL)
                }
            }
        }

        /// Waits for the tool to end, then reaps it and keeps its status. It's reaped only while
        /// `state` is locked, so `stop` never signals another process given the same ID later.
        private func waitForEnd() {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            state.withLock { state in
                var status: Int32 = 0
                var reaped = waitpid(pid, &status, 0)
                while reaped < 0 && errno == EINTR {
                    reaped = waitpid(pid, &status, 0)
                }
                state.hasEnded = true
                // A status is a signal's number in its low 7 bits, or 0 and the exit code above.
                if reaped == pid {
                    state.status = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
                }
            }
            var byte: UInt8 = 1
            _ = write(ended.write, &byte, 1)
        }

        /// Reads both pipes until the tool ends, then what's left in them, and closes them.
        private func collect() -> (output: Data, errors: Data) {
            var open = [output, errors]
            var collected = [Data(), Data()]
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var hasEnded = false
            while !hasEnded {
                // poll leaves out a pipe that's closed, whose place holds -1.
                var polled = (open + [ended.read]).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                guard poll(&polled, nfds_t(polled.count), -1) >= 0 || errno == EINTR else { break }
                for index in open.indices where open[index] >= 0 && polled[index].revents != 0 {
                    let count = read(open[index], &buffer, buffer.count)
                    if count > 0 {
                        collected[index].append(contentsOf: buffer[..<count])
                    } else if count == 0 || errno != EINTR {
                        close(open[index])
                        open[index] = -1
                    }
                }
                hasEnded = polled[2].revents != 0
            }
            if !hasEnded {
                // poll failed, which it shouldn't: wait for the end all the same.
                var byte: UInt8 = 0
                while read(ended.read, &byte, 1) < 0 && errno == EINTR {}
            }
            // Everything the tool wrote before it ended is in the pipes by now.
            for index in open.indices where open[index] >= 0 {
                _ = fcntl(open[index], F_SETFL, fcntl(open[index], F_GETFL) | O_NONBLOCK)
                while true {
                    let count = read(open[index], &buffer, buffer.count)
                    if count > 0 {
                        collected[index].append(contentsOf: buffer[..<count])
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
                close(open[index])
            }
            return (collected[0], collected[1])
        }

        /// A pipe whose ends close on exec, so no other program Reqly starts gets them, and are
        /// above standard error, so the tool's own can take their places. Swift's Glibc has no
        /// pipe2, so the ends are moved to such copies at once. Every program Reqly starts closes
        /// what it would inherit above standard error anyway.
        private static func makePipe() -> (read: Int32, write: Int32)? {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { return nil }
            let moved = ends.map { fcntl($0, F_DUPFD_CLOEXEC, 3) }
            let error = errno
            for end in ends {
                close(end)
            }
            guard moved[0] >= 0, moved[1] >= 0 else {
                for end in moved where end >= 0 {
                    close(end)
                }
                errno = error
                return nil
            }
            return (moved[0], moved[1])
        }

        /// Starts the program with its output and errors to the descriptors given, input from
        /// /dev/null, every other descriptor closed, no signal blocked and every signal's action
        /// the default one, as Reqly may block or ignore some. Returns 0, or an errno.
        private static func spawn(
            _ path: String, _ arguments: [String], _ environment: [String], output: Int32, errors: Int32,
            into pid: inout pid_t
        ) -> Int32 {
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
            guard posix_spawn_file_actions_init(&actions) == 0 else { return ENOMEM }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { return ENOMEM }
            defer { posix_spawnattr_destroy(&attributes) }
            var error = posix_spawn_file_actions_adddup2(&actions, output, 1)
            if error == 0 {
                error = posix_spawn_file_actions_adddup2(&actions, errors, 2)
            }
            if error == 0 {
                error = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            }
            if error == 0 {
                error = posix_spawn_file_actions_addclosefrom_np(&actions, 3)
            }
            var none = sigset_t()
            var all = sigset_t()
            sigemptyset(&none)
            sigfillset(&all)
            if error == 0 {
                error = posix_spawnattr_setsigmask(&attributes, &none)
            }
            if error == 0 {
                error = posix_spawnattr_setsigdefault(&attributes, &all)
            }
            if error == 0 {
                error = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
            }
            guard error == 0 else { return error }
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup($0) } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            return posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        }
    }
#endif

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
