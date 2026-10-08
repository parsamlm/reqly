// ReqlyHelper: the privileged helper inside Reqly. launchd runs it as root once the user allows
// it in System Settings. It points the Mac's proxy at Reqly and always puts the settings back.
// See ARCHITECTURE.md › Processes.

import Foundation
import HelperCore
import HelperProtocol
import os

let log = Logger(subsystem: "net.reqly.Reqly.Helper", category: "helper")

// Accept requests only from the Reqly app signed by the same team as this helper.
guard let signing = CodeSigningInfo.current(),
    let team = signing.teamIdentifier,
    let appIdentifier = HelperNames.appIdentifier(forHelper: signing.identifier)
else {
    log.error("ReqlyHelper isn't signed by a team, so it can't tell which app to trust. Exiting.")
    // A successful exit, so launchd doesn't keep starting it again.
    exit(0)
}

/// Hands each accepted connection to the proxy guard.
final class ConnectionAcceptor: NSObject, NSXPCListenerDelegate {
    let proxyGuard: ProxyGuard

    init(proxyGuard: ProxyGuard) {
        self.proxyGuard = proxyGuard
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ReqlyHelperXPC.self)
        connection.exportedObject = proxyGuard
        connection.resume()
        return true
    }
}

let proxyGuard = ProxyGuard(stateFile: .standard(helperIdentifier: signing.identifier))
proxyGuard.recoverAtLaunch()

let acceptor = ConnectionAcceptor(proxyGuard: proxyGuard)
let listener = NSXPCListener(machServiceName: signing.identifier)
listener.setConnectionCodeSigningRequirement(CodeSigningInfo.requirement(identifier: appIdentifier, team: team))
listener.delegate = acceptor
listener.resume()

// With nothing to guard, exit after a quiet minute. launchd starts the helper again when Reqly asks.
// The timer fires on the main queue, which dispatchMain() serves. Code at the top of main.swift
// belongs to the main actor, and Swift 6 stops the process when such a closure runs elsewhere:
// on a global queue, the helper crashed 30 seconds after every launch, and KeepAlive restarted it.
let idleCheck = DispatchSource.makeTimerSource(queue: .main)
idleCheck.schedule(deadline: .now() + 30, repeating: 30)
idleCheck.setEventHandler { [proxyGuard] in
    if proxyGuard.isIdle(for: 60) {
        exit(0)
    }
}
idleCheck.resume()

dispatchMain()
