import CCrashStack
import CoreInterface
import Foundation
import TrafficStore
import WindowsSystem

// The C functions of ReqlyCore.dll. ReqlyCore.h says what each one does and how to call it.

/// Receives an event or a reply: UTF-8 JSON, valid only during the call, and the context the
/// app passed in.
public typealias ReqlyCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

@_cdecl("reqly_open")
public func reqlyOpen(
    _ options: UnsafePointer<CChar>?, _ events: ReqlyCallback?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let options, let events else { return nil }
    let context = Context(pointer: context)
    guard let decoded = try? JSONDecoder().decode(OpenOptions.self, from: Data(String(cString: options).utf8)) else {
        deliver(
            openFailed(Problem(.badRequest, "The options aren't JSON with a \"sessionsFolder\".")), to: events,
            context)
        return nil
    }
    let send: @Sendable (Data) -> Void = { deliver($0, to: events, context) }
    let opened = wait { () async -> Result<SessionHost, Problem> in
        do throws(Problem) {
            return .success(try await SessionHost.open(decoded, send: send))
        } catch {
            return .failure(error)
        }
    }
    switch opened {
    case .success(let host):
        return Unmanaged.passRetained(Session(host)).toOpaque()
    case .failure(let problem):
        deliver(openFailed(problem), to: events, context)
        return nil
    }
}

@_cdecl("reqly_call")
public func reqlyCall(
    _ session: UnsafeMutableRawPointer?, _ request: UnsafePointer<CChar>?, _ done: ReqlyCallback?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let session, let request, let done else { return }
    let host = Unmanaged<Session>.fromOpaque(session).takeUnretainedValue().host
    let json = Data(String(cString: request).utf8)
    let context = Context(pointer: context)
    Task.detached {
        deliver(await host.reply(to: json), to: done, context)
    }
}

@_cdecl("reqly_body")
public func reqlyBody(
    _ session: UnsafeMutableRawPointer?, _ exchange: UInt64, _ part: Int32, _ offset: Int64, _ limit: Int64,
    _ length: UnsafeMutablePointer<Int64>?
) -> UnsafeMutableRawPointer? {
    length?.pointee = 0
    guard let session, (0...3).contains(part) else { return nil }
    let host = Unmanaged<Session>.fromOpaque(session).takeUnretainedValue().host
    let bodyPart: BodyPart = part % 2 == 0 ? .request : .response
    let unpacked = part >= 2
    guard
        let data = wait({
            await host.body(exchange, part: bodyPart, offset: Int(offset), limit: Int(limit), unpacked: unpacked)
        }),
        let bytes = malloc(max(data.count, 1))
    else { return nil }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    length?.pointee = Int64(data.count)
    return bytes
}

@_cdecl("reqly_free")
public func reqlyFree(_ pointer: UnsafeMutableRawPointer?) {
    free(pointer)
}

@_cdecl("reqly_restore_proxy")
public func reqlyRestoreProxy(_ restoreFile: UnsafePointer<CChar>?) -> Int32 {
    #if os(Windows)
        guard let restoreFile else { return -1 }
        let file = URL(fileURLWithPath: String(cString: restoreFile))
        do {
            return try UserProxySwitch.restoreLeftBehind(settings: WinINetProxySettings(), restoreFile: file) ? 1 : 0
        } catch {
            return -1
        }
    #else
        return 0
    #endif
}

@_cdecl("reqly_remove_root")
public func reqlyRemoveRoot(_ rootFile: UnsafePointer<CChar>?, _ standIn: Int32) -> Int32 {
    guard let rootFile else { return RootRemoval.failed.rawValue }
    return RootRemoval.remove(rootFile: String(cString: rootFile), standIn: standIn != 0).rawValue
}

@_cdecl("reqly_close")
public func reqlyClose(_ session: UnsafeMutableRawPointer?) {
    guard let session else { return }
    let host = Unmanaged<Session>.fromOpaque(session).takeRetainedValue().host
    wait { await host.close() }
}

@_cdecl("reqly_catch_crashes")
public func reqlyCatchCrashes(_ then: (@convention(c) () -> Void)?) {
    crashstack_install(then)
}

@_cdecl("reqly_crash_for_test")
public func reqlyCrashForTest(_ message: UnsafePointer<CChar>?) {
    let text = message.map { String(cString: $0) } ?? "Reqly crashed for a test."
    // On one of the core's own threads, where its work runs, rather than the app's.
    Task.detached { fatalError(text) }
}

@_cdecl("reqly_crash_here_for_test")
public func reqlyCrashHereForTest(_ message: UnsafePointer<CChar>?) {
    fatalError(message.map { String(cString: $0) } ?? "Reqly crashed for a test.")
}

// MARK: -

/// What a session handle points to.
private final class Session: Sendable {
    let host: SessionHost

    init(_ host: SessionHost) {
        self.host = host
    }
}

/// The app's context pointer, which the core only hands back.
private struct Context: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
}

private func openFailed(_ problem: Problem) -> Data {
    struct OpenFailed: Encodable {
        var event = "openFailed"
        var problem: Problem
    }
    return (try? JSONEncoder().encode(OpenFailed(problem: problem))) ?? Data()
}

/// Hands JSON to the app as a C string, which lasts only for the call.
private func deliver(_ json: Data, to callback: ReqlyCallback, _ context: Context) {
    var text = json
    text.append(0)
    text.withUnsafeBytes { bytes in
        callback(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), context.pointer)
    }
}

/// Runs async work to the end, for a C function that returns its result. The app calls these
/// from its own threads, never from inside a callback, so no thread of Swift's is held up.
private func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value!
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}
