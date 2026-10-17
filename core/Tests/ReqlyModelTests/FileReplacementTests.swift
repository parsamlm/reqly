import Foundation
import ReqlyModel
import Testing

#if os(Windows)
    import WinSDK
#endif

@Suite struct FileReplacementTests {
    @Test func replacesAFileAndMakesItsFolder() throws {
        let folder = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Settings").appending(path: "Rules.json")
        try FileReplacement.write(Data("old".utf8), to: file)
        try FileReplacement.write(Data("new".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }

    #if os(Windows)
        @Test func waitsWhileAnotherProgramHasTheFileOpen() throws {
            let folder = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "Rules.json")
            try FileReplacement.write(Data("old".utf8), to: file)
            // Opened as antivirus software opens a new file to read it: others may read and write
            // it, but no file may take its place.
            let handle = file.withUnsafeFileSystemRepresentation { path in
                String(cString: path!).withCString(encodedAs: UTF16.self) { name in
                    CreateFileW(
                        name, DWORD(truncatingIfNeeded: GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
                }
            }
            let held = try #require(handle == INVALID_HANDLE_VALUE ? nil : handle)
            #expect(throws: (any Error).self) { try Data("new".utf8).write(to: file, options: .atomic) }

            // The other program lets go of it a moment later.
            let raw = Int(bitPattern: held)
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.1)
                CloseHandle(HANDLE(bitPattern: raw))
            }
            try FileReplacement.write(Data("new".utf8), to: file)
            #expect(try Data(contentsOf: file) == Data("new".utf8))
        }
    #endif
}
