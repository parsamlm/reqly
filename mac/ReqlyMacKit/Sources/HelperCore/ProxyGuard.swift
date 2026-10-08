import Foundation
import HelperProtocol
import os

/// ReqlyHelper's work: it points the Mac's proxy at Reqly and makes sure the old settings
/// always come back.
///
/// Before it changes anything, it saves the current settings to a file. They go back when
/// Reqly asks, when the Reqly process exits for any reason, and when the helper starts and
/// finds a file whose Reqly is gone, for example after a power cut.
public final class ProxyGuard: NSObject, ReqlyHelperXPC, @unchecked Sendable {
    // Everything below is only touched on `queue`, which is why this class can be @unchecked Sendable.
    private let queue = DispatchQueue(label: "net.reqly.helper.proxy-guard")
    private let settings: any NetworkSettings
    private let stateFile: StateFile
    private let processes: any ProcessLookup
    private var watcher: (any DispatchSourceProcess)?
    private var lastRequest = Date()
    private let log = Logger(subsystem: "net.reqly.Reqly.Helper", category: "proxy")

    public init(
        settings: any NetworkSettings = SystemNetworkSettings(),
        stateFile: StateFile,
        processes: any ProcessLookup = SystemProcessLookup()
    ) {
        self.settings = settings
        self.stateFile = stateFile
        self.processes = processes
    }

    // MARK: - Requests from Reqly

    public func setProxy(port: Int, reply: @escaping @Sendable (NSError?) -> Void) {
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        queue.async {
            self.lastRequest = Date()
            reply(self.perform { try self.set(port: port, for: pid) })
        }
    }

    public func restoreProxy(reply: @escaping @Sendable (NSError?) -> Void) {
        queue.async {
            self.lastRequest = Date()
            reply(self.perform { try self.restore() })
        }
    }

    // MARK: - Life of the helper

    /// Puts back settings that a capture left behind, unless the Reqly that started it still runs.
    public func recoverAtLaunch() {
        queue.sync {
            guard let state = try? stateFile.load() else { return }
            if processes.executablePath(of: state.appPID) == state.appPath {
                watch(state.appPID)
            } else {
                log.notice("A capture was left on. Restoring the proxy settings.")
                _ = perform { try restore() }
            }
        }
    }

    /// Nothing to guard, and no request for `interval` seconds: the helper can exit.
    public func isIdle(for interval: TimeInterval) -> Bool {
        queue.sync { watcher == nil && Date().timeIntervalSince(lastRequest) > interval }
    }

    // MARK: - Work, always on `queue`

    func set(port: Int, for pid: Int32) throws {
        guard (1024...65535).contains(port) else { throw HelperError.invalidPort }
        let services = try settings.enabledServices()
        var state = try stateFile.load() ?? SavedState(port: port, appPID: pid, appPath: "", originals: [:])
        // Keep the first saved settings: later requests, such as a new port, start from them too.
        for service in services where state.originals[service.id] == nil {
            state.originals[service.id] = service.proxies
        }
        state.port = port
        state.appPID = pid
        state.appPath = processes.executablePath(of: pid) ?? ""
        do {
            try stateFile.save(state)
        } catch {
            throw HelperError.cannotSaveState
        }

        var capturing: [String: [String: Any]] = [:]
        for service in services {
            capturing[service.id] = ProxySettings.capturing(state.originals[service.id] ?? service.proxies, port: port)
        }
        do {
            try settings.apply(capturing)
        } catch {
            // Leave nothing half done.
            try? restore()
            throw error
        }
        log.notice("Pointed the proxy of \(services.count) network services at port \(port).")
        watch(pid)
    }

    func restore() throws {
        defer { stopWatching() }
        guard let state = try stateFile.load() else { return }
        try settings.apply(state.originals)
        try stateFile.remove()
        log.notice("Restored the proxy settings.")
    }

    private func watch(_ pid: Int32) {
        stopWatching()
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            log.notice("Reqly exited while capturing. Restoring the proxy settings.")
            _ = perform { try self.restore() }
        }
        source.resume()
        watcher = source
        // Reqly may have exited before the watch began.
        if processes.executablePath(of: pid) == nil {
            _ = perform { try restore() }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func perform(_ work: () throws -> Void) -> NSError? {
        do {
            try work()
            return nil
        } catch let error as HelperError {
            log.error("\(error.message, privacy: .public)")
            return error as NSError
        } catch {
            log.error("\(error.localizedDescription, privacy: .public)")
            return HelperError.cannotChangeSettings as NSError
        }
    }
}
