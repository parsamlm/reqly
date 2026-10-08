import Foundation

/// Runs a command-line tool, such as `adb` or Xcode's `simctl`, and collects what it prints.
enum Tool {
    struct Failure: Error, LocalizedError {
        var tool: String
        var message: String

        var errorDescription: String? {
            message.isEmpty ? "\(tool) didn't finish." : message
        }
    }

    /// Runs the tool and returns what it printed. A tool that fails throws what it said about it.
    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) async throws -> String {
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
        let name = executable.lastPathComponent
        guard status == 0 else {
            let message = (errorText.isEmpty ? text : errorText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(tool: name, message: message)
        }
        return text
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
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

extension Data {
    /// The certificate in PEM, the text form many tools take.
    var pemCertificate: String {
        let lines = base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(lines)\n-----END CERTIFICATE-----\n"
    }
}
