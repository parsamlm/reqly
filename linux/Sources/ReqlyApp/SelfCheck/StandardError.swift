import Foundation

extension SelfCheck {
    /// Runs `body`, and gives what this process wrote to its standard error meanwhile, a line at a
    /// time, such as GTK's warnings, which reach the standard error after too, as ever.
    func standardError<Result>(during body: () async throws -> Result) async throws -> (
        result: Result, lines: [String]
    ) {
        let file = scratch.appending(path: "standard-error-\(UUID().uuidString).txt")
        let capture = open(file.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard capture >= 0 else { throw Failure("couldn't make \(file.path) for the standard error") }
        let saved = dup(STDERR_FILENO)
        dup2(capture, STDERR_FILENO)
        close(capture)
        func restore() -> [String] {
            dup2(saved, STDERR_FILENO)
            close(saved)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: file)
            FileHandle.standardError.write(Data(text.utf8))
            return text.split(separator: "\n").map(String.init)
        }
        let result: Result
        do {
            result = try await body()
        } catch {
            _ = restore()
            throw error
        }
        return (result, restore())
    }
}
