import CGio
import CSecret
import Dispatch
import Foundation
import Synchronization

/// A place for one secret in your keyring, such as Reqly's certificate and its key.
public protocol Keyring: Sendable {
    /// Whether saving can go ahead without a question, which the app explains before the first
    /// save.
    func state() -> KeyringState
    /// The secret saved earlier, or `nil` when there's none.
    func load() throws(KeyringProblem) -> Data?
    /// Whether the secret is in a keyring, locked or not, which asks you nothing, not even to
    /// unlock it.
    func isKept() throws(KeyringProblem) -> Bool
    func save(_ secret: Data) throws(KeyringProblem)
    func remove() throws(KeyringProblem)
}

/// What saving in your keyring involves, before anything's saved.
public enum KeyringState: Sendable, Equatable {
    /// Your default keyring is open, so saving asks nothing.
    case ready
    /// Your default keyring is locked, so saving asks for its password.
    case locked
    /// There's no default keyring yet, as after an automatic login, so saving asks you to choose a
    /// password for a new one.
    case needsNewKeyring
    /// There's no keyring to save in, such as when no Secret Service runs.
    case unavailable(String)
}

/// Why the keyring couldn't save or read a secret. Reqly then keeps the key in a file instead.
public enum KeyringProblem: Error, Sendable, Equatable, LocalizedError {
    case unavailable(String)
    /// You closed the keyring's question without answering.
    case dismissed
    /// The keyring didn't answer in time.
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "There's no keyring to keep the key in. \(reason)"
        case .dismissed: "The keyring's question was closed without an answer."
        case .timedOut: "The keyring didn't answer."
        case .failed(let reason): "The keyring couldn't keep the key. \(reason)"
        }
    }
}

/// One of Reqly's secrets in your keyring, through the Secret Service, which GNOME Keyring
/// provides on GNOME and Plasma alike: by default its certificate and key, "Reqly Certificate
/// Authority". Each is one item in your default keyring, as the Mac keeps them in your login
/// keychain.
///
/// Each call runs on a thread of its own and waits at most `timeLimit` seconds, since keyrings
/// can hang and their questions can wait for you. When the time runs out, the question goes away.
/// Call them off the main thread.
public struct SecretServiceKeyring: Keyring {
    /// Which item a keyring keeps, as the Secret Service tells items apart.
    public struct Item: Sendable, Equatable {
        /// What kind of secret it is, which the Secret Service keeps beside it.
        public var schema: String
        /// The item's one attribute, which names it.
        public var attribute: String
        public var value: String
        /// The name the keyring's own app shows, such as Passwords and Keys.
        public var label: String

        public init(schema: String, attribute: String, value: String, label: String) {
            self.schema = schema
            self.attribute = attribute
            self.value = value
            self.label = label
        }

        /// Reqly's certificate and its key.
        public static let certificate = Item(
            schema: "net.reqly.Reqly.Certificate", attribute: "certificate", value: "root",
            label: "Reqly Certificate Authority")
        /// The upstream proxy's password and client certificates' private keys, together.
        public static let secrets = Item(
            schema: "net.reqly.Reqly.Secrets", attribute: "secrets", value: "connections", label: "Reqly Secrets")
    }

    /// The certificate's item's schema and label.
    public static let schemaName = Item.certificate.schema
    public static let label = Item.certificate.label

    /// The item this keyring keeps.
    public var item: Item
    /// How long a call may take, in seconds, questions included; saving may take three times as
    /// long.
    public var timeLimit: TimeInterval

    public init(item: Item = .certificate, timeLimit: TimeInterval = 60) {
        self.item = item
        self.timeLimit = timeLimit
    }

    public func state() -> KeyringState {
        let result = Self.call(timeLimit: min(timeLimit, 10)) { cancellable -> Result<KeyringState, KeyringProblem> in
            var error: UnsafeMutablePointer<GError>?
            guard let service = secret_service_get_sync(SECRET_SERVICE_NONE, cancellable, &error) else {
                return .success(.unavailable(Self.take(error)))
            }
            defer { g_object_unref(service) }
            guard
                let collection = secret_collection_for_alias_sync(
                    service, "default", SECRET_COLLECTION_NONE, cancellable, &error)
            else {
                // No error means there's no such alias.
                return .success(error == nil ? .needsNewKeyring : .unavailable(Self.take(error)))
            }
            defer { g_object_unref(collection) }
            return .success(secret_collection_get_locked(collection) != 0 ? .locked : .ready)
        }
        switch result {
        case .success(let state): return state
        case .failure(let problem): return .unavailable(problem.errorDescription ?? "")
        }
    }

    public func load() throws(KeyringProblem) -> Data? {
        try Self.call(timeLimit: timeLimit) { [item] cancellable -> Result<Data?, KeyringProblem> in
            Self.withSchema(item) { schema, attributes in
                var error: UnsafeMutablePointer<GError>?
                guard let found = secret_password_lookupv_sync(schema, attributes, cancellable, &error) else {
                    if error != nil { return .failure(Self.problem(error)) }
                    // A closed unlock question looks like no item at all, so look again without
                    // unlocking.
                    return Self.isKept(schema, attributes, cancellable).flatMap {
                        $0 ? .failure(.dismissed) : .success(nil)
                    }
                }
                defer { secret_password_free(found) }
                guard let secret = Data(base64Encoded: String(cString: found)) else {
                    return .failure(.failed("Its item, \(item.label), isn't one Reqly can read."))
                }
                return .success(secret)
            }
        }.get()
    }

    public func isKept() throws(KeyringProblem) -> Bool {
        try Self.call(timeLimit: min(timeLimit, 10)) { [item] cancellable -> Result<Bool, KeyringProblem> in
            Self.withSchema(item) { schema, attributes in Self.isKept(schema, attributes, cancellable) }
        }.get()
    }

    /// Saving may ask you to choose a password for a new keyring, and to type it twice, so it
    /// waits three times as long as the other calls.
    public func save(_ secret: Data) throws(KeyringProblem) {
        try Self.call(timeLimit: timeLimit * 3) { [item] cancellable -> Result<Void, KeyringProblem> in
            Self.withSchema(item) { schema, attributes in
                var error: UnsafeMutablePointer<GError>?
                if let problem = Self.makeDefaultKeyring(cancellable) { return .failure(problem) }
                let saved = secret_password_storev_sync(
                    schema, attributes, "default", item.label, secret.base64EncodedString(), cancellable, &error)
                guard saved != 0 else { return .failure(error == nil ? .dismissed : Self.problem(error)) }
                // A dismissed question can still come back as saved, with nothing kept.
                guard let found = secret_password_lookupv_sync(schema, attributes, cancellable, &error) else {
                    return .failure(error == nil ? .dismissed : Self.problem(error))
                }
                secret_password_free(found)
                return .success(())
            }
        }.get()
    }

    public func remove() throws(KeyringProblem) {
        try Self.call(timeLimit: timeLimit) { [item] cancellable -> Result<Void, KeyringProblem> in
            Self.withSchema(item) { schema, attributes in
                var error: UnsafeMutablePointer<GError>?
                guard secret_password_clearv_sync(schema, attributes, cancellable, &error) == 0 else {
                    return .success(())
                }
                if error != nil { return .failure(Self.problem(error)) }
                // False with no error means there was nothing to remove, or that you closed the
                // question that would unlock it.
                return Self.isKept(schema, attributes, cancellable).flatMap { $0 ? .failure(.dismissed) : .success(()) }
            }
        }.get()
    }

    // MARK: -

    /// Makes your default keyring when there's none, as after an automatic login, which asks you
    /// to choose its password. Saving to the default keyring alone doesn't make one. Returns
    /// what went wrong, or `nil` when there's a default keyring.
    private static func makeDefaultKeyring(_ cancellable: UnsafeMutablePointer<GCancellable>) -> KeyringProblem? {
        var error: UnsafeMutablePointer<GError>?
        guard let service = secret_service_get_sync(SECRET_SERVICE_NONE, cancellable, &error) else {
            return .unavailable(take(error))
        }
        defer { g_object_unref(service) }
        if let collection = secret_collection_for_alias_sync(
            service, "default", SECRET_COLLECTION_NONE, cancellable, &error)
        {
            g_object_unref(collection)
            return nil
        }
        if error != nil { return problem(error) }
        // The label libsecret gives the one it makes, so the question names it as other apps' do.
        guard
            let made = secret_collection_create_sync(
                service, "Default keyring", "default", SECRET_COLLECTION_CREATE_NONE, cancellable, &error)
        else {
            // A closed question makes nothing, which the Secret Service calls "/", and libsecret
            // then finds no keyring there.
            if let error,
                g_error_matches(error, g_dbus_error_quark(), gint(G_DBUS_ERROR_UNKNOWN_METHOD.rawValue)) != 0
                    || g_error_matches(error, secret_error_get_quark(), gint(SECRET_ERROR_NO_SUCH_OBJECT.rawValue)) != 0
            {
                g_error_free(error)
                return .dismissed
            }
            return error == nil ? .dismissed : problem(error)
        }
        g_object_unref(made)
        return nil
    }

    /// Whether the item is in a keyring, locked or not, without asking to unlock it.
    private static func isKept(
        _ schema: UnsafePointer<SecretSchema>, _ attributes: OpaquePointer,
        _ cancellable: UnsafeMutablePointer<GCancellable>
    ) -> Result<Bool, KeyringProblem> {
        var error: UnsafeMutablePointer<GError>?
        guard let service = secret_service_get_sync(SECRET_SERVICE_NONE, cancellable, &error) else {
            return .failure(problem(error))
        }
        defer { g_object_unref(service) }
        let items = secret_service_search_sync(service, schema, attributes, SECRET_SEARCH_ALL, cancellable, &error)
        if error != nil { return .failure(problem(error)) }
        defer { g_list_free_full(items, g_object_unref) }
        return .success(items != nil)
    }

    /// A GCancellable that another thread may cancel.
    private struct Cancellable: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<GCancellable>
    }

    /// Runs `work` on a thread of its own and waits for it for up to `timeLimit` seconds. When
    /// the time runs out, it cancels the call, which closes any question it asked, and the
    /// thread finishes on its own.
    private static func call<Value: Sendable>(
        timeLimit: TimeInterval,
        _ work: @escaping @Sendable (UnsafeMutablePointer<GCancellable>) -> Result<Value, KeyringProblem>
    ) -> Result<Value, KeyringProblem> {
        let cancellable = Cancellable(pointer: g_cancellable_new())
        // One reference for each side, so whichever finishes last frees it.
        g_object_ref(cancellable.pointer)
        defer { g_object_unref(cancellable.pointer) }
        let outcome = Mutex<Result<Value, KeyringProblem>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let result = work(cancellable.pointer)
            outcome.withLock { $0 = result }
            g_object_unref(cancellable.pointer)
            finished.signal()
        }
        thread.start()
        guard finished.wait(timeout: .now() + timeLimit) == .success else {
            g_cancellable_cancel(cancellable.pointer)
            return .failure(.timedOut)
        }
        return outcome.withLock { $0 } ?? .failure(.timedOut)
    }

    /// Calls `body` with the item's schema and attributes, which libsecret's calls take.
    private static func withSchema<Result>(
        _ item: Item, _ body: (UnsafePointer<SecretSchema>, OpaquePointer) -> Result
    ) -> Result {
        let types = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, nil)!
        // A string attribute, SECRET_SCHEMA_ATTRIBUTE_STRING, is 0, so its value is a null pointer.
        g_hash_table_insert(types, g_strdup(item.attribute), nil)
        let schema = secret_schema_newv(item.schema, SECRET_SCHEMA_NONE, types)!
        g_hash_table_unref(types)
        defer { secret_schema_unref(schema) }
        let attributes = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free)!
        g_hash_table_insert(attributes, g_strdup(item.attribute), g_strdup(item.value))
        defer { g_hash_table_unref(attributes) }
        return body(schema, attributes)
    }

    private static func problem(_ error: UnsafeMutablePointer<GError>?) -> KeyringProblem {
        if let error, g_error_matches(error, g_io_error_quark(), gint(G_IO_ERROR_CANCELLED.rawValue)) != 0 {
            g_error_free(error)
            return .dismissed
        }
        return .failed(take(error))
    }

    /// The error's message, and frees it.
    private static func take(_ error: UnsafeMutablePointer<GError>?) -> String {
        guard let error else { return "" }
        defer { g_error_free(error) }
        return String(cString: error.pointee.message)
    }
}
