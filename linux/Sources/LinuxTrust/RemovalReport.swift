import CertificateAuthority
import Foundation

/// How removing Reqly's certificate went, place by place, as `reqly --remove-certificate` says
/// it: your browsers, Firefox and the computer's list, and the key.
public struct RemovalReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case removed
        /// There was no certificate to remove.
        case nothing
        /// You closed the password dialog, so the computer's list still trusts the certificate,
        /// and Reqly keeps its key, to finish the next time.
        case declined
        /// Why the certificate couldn't be removed from everywhere, or read.
        case failed(String)
    }

    public var outcome: Outcome
    /// Each place before the removal, and after it. Empty when there was no certificate to read.
    public var before: [TrustPlace]
    public var after: [TrustPlace]
    /// Where the key was kept, and where it's kept now: nil once it's gone.
    public var keyBefore: KeyPlace?
    public var keyAfter: KeyPlace?
    /// The key's file, used when the keyring isn't.
    public var keyFile: URL
    /// Whether the key had gone from your keyring already, so the certificate went by its record.
    public var keyWasGone = false

    public init(
        outcome: Outcome, before: [TrustPlace] = [], after: [TrustPlace] = [], keyBefore: KeyPlace? = nil,
        keyAfter: KeyPlace? = nil, keyFile: URL
    ) {
        self.outcome = outcome
        self.before = before
        self.after = after
        self.keyBefore = keyBefore
        self.keyAfter = keyAfter
        self.keyFile = keyFile
    }

    /// Removes the certificate `store` keeps from every place, then its key, as
    /// ``LinuxRootStore/remove(_:)`` does, and reads each place before and after. It may wait for
    /// the keyring and a password dialog, so call it off the main thread.
    public static func remove(from store: LinuxRootStore) -> RemovalReport {
        let root: RootIdentity?
        do {
            root = try store.load()
        } catch is LinuxRootStore.KeyGone {
            return removeWithoutKey(from: store)
        } catch {
            return RemovalReport(
                outcome: .failed("Reqly couldn't read its certificate, so it can't remove it. \(Self.explain(error))"),
                keyFile: store.file)
        }
        guard let root else { return RemovalReport(outcome: .nothing, keyFile: store.file) }
        let before = store.places(for: root)
        let keyBefore = store.keyPlace
        let outcome: Outcome
        do {
            try store.remove(root)
            outcome = .removed
        } catch CertificateStoreError.cancelled {
            outcome = .declined
        } catch CertificateStoreError.failed(let reasons) {
            outcome = .failed("Reqly couldn't remove its certificate from everywhere. \(reasons)")
        } catch {
            outcome = .failed("Reqly couldn't remove its certificate. \(Self.explain(error))")
        }
        return RemovalReport(
            outcome: outcome, before: before, after: store.places(for: root), keyBefore: keyBefore,
            keyAfter: store.keyPlace, keyFile: store.file)
    }

    /// Removes the certificate whose key has gone, by what its record says, as
    /// ``LinuxRootStore/removeWithoutKey(cancellation:)`` does.
    private static func removeWithoutKey(from store: LinuxRootStore) -> RemovalReport {
        let outcome: Outcome
        do {
            outcome = try store.removeWithoutKey() ? .removed : .nothing
        } catch CertificateStoreError.cancelled {
            outcome = .declined
        } catch CertificateStoreError.failed(let reasons) {
            outcome = .failed("Reqly couldn't remove its certificate from everywhere. \(reasons)")
        } catch {
            outcome = .failed("Reqly couldn't remove its certificate. \(Self.explain(error))")
        }
        var report = RemovalReport(outcome: outcome, keyFile: store.file)
        report.keyWasGone = true
        return report
    }

    /// Whether nothing of the certificate is left for your account.
    public var isComplete: Bool { outcome == .removed || outcome == .nothing }

    /// What to say: a line for each place, one for the key, and how it went.
    public var lines: [String] {
        var lines = zip(before, after).map { before, after in "\(after.name): \(Self.outcome(before, after, outcome))" }
        if !before.isEmpty {
            lines.append("Its key: \(keyOutcome)")
        } else if keyWasGone {
            lines.append("Its key: already gone from your keyring, so Reqly went by its record of the places.")
        }
        switch outcome {
        case .removed: lines.append("Removed Reqly's certificate.")
        case .nothing: lines.append("There's no certificate to remove.")
        case .declined:
            lines.append("Reqly's certificate stays where it's still trusted: you closed the password dialog.")
        case .failed(let reason): lines.append(reason)
        }
        return lines
    }

    private static func outcome(_ before: TrustPlace, _ after: TrustPlace, _ outcome: Outcome) -> String {
        if after.status == .trusted {
            return outcome == .declined && after.needsPassword
                ? "still trusts it. You closed the password dialog." : "still trusts it."
        }
        if before.status == .trusted { return "removed." }
        switch after.status {
        case .notFound:
            return "nothing to remove."
        // The computer's list is unavailable only when the certificate isn't in it.
        case .unavailable(let reason) where after.kind != .computer:
            return "couldn't check. \(reason)"
        default:
            return "didn't trust it."
        }
    }

    private var keyOutcome: String {
        switch (keyBefore, keyAfter) {
        case (_, .keyring?): "still in your keyring."
        case (_, .file?): "still in \(keyFile.path)."
        case (.keyring?, nil): "removed from your keyring."
        case (.file?, nil): "deleted from \(keyFile.path)."
        case (nil, nil): "removed."
        }
    }

    private static func explain(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
