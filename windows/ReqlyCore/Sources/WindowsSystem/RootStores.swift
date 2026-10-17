import CertificateAuthority
import Foundation
import ReqlyModel

#if os(Windows)
    import WinSDK
#endif

/// A root in a plain file, for test runs, made there the first time HTTPS is set up. It counts as
/// trusted, so a test run decrypts with it, while the computer itself never trusts it: it never
/// goes near Windows' certificate stores.
public struct FileRootStore: RootStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() throws -> RootIdentity? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try RootIdentity(serialized: data)
    }

    public func save(_ root: RootIdentity) throws {
        try FileReplacement.write(root.serialized(), to: file)
    }

    public func isTrusted(_ root: RootIdentity) -> Bool { true }

    public func trust(_ root: RootIdentity) throws {}

    public func remove(_ root: RootIdentity) throws {
        try? FileManager.default.removeItem(at: file)
    }
}

#if os(Windows)
    /// Reqly's root on Windows. Its certificate and key stay in a file that Windows encrypts for
    /// your user account (DPAPI), and the certificate goes in your user's Trusted Root
    /// Certification Authorities while you trust it. Windows asks you before it trusts the
    /// certificate, and before it lets go of it.
    public struct WindowsRootStore: RootStore {
        public let file: URL

        public init(file: URL) {
            self.file = file
        }

        public func load() throws -> RootIdentity? {
            guard let protected = try? Data(contentsOf: file) else { return nil }
            return try RootIdentity(serialized: try Self.unprotect(protected))
        }

        public func save(_ root: RootIdentity) throws {
            try FileReplacement.write(Self.protect(try root.serialized()), to: file)
        }

        public func isTrusted(_ root: RootIdentity) -> Bool {
            guard let certificate = try? root.certificateDER else { return false }
            let found = try? Self.withTrustedRoots { store -> Bool in
                guard let context = Self.find(certificate, in: store) else { return false }
                CertFreeCertificateContext(context)
                return true
            }
            return found ?? false
        }

        public func trust(_ root: RootIdentity) throws {
            let certificate = try root.certificateDER
            try Self.withTrustedRoots { store in
                // Windows shows its own warning here, and asks you to confirm.
                let added = certificate.withUnsafeBufferPointer { bytes in
                    CertAddEncodedCertificateToStore(
                        store, DWORD(X509_ASN_ENCODING), bytes.baseAddress, DWORD(bytes.count),
                        DWORD(CERT_STORE_ADD_REPLACE_EXISTING), nil)
                }
                guard added else { throw Self.failure(GetLastError(), doing: "trust") }
            }
        }

        public func remove(_ root: RootIdentity) throws {
            let certificate = try root.certificateDER
            try Self.withTrustedRoots { store in
                guard let context = Self.find(certificate, in: store) else { return }
                // Windows asks you to confirm. Deleting frees the context too.
                guard CertDeleteCertificateFromStore(context) else {
                    throw Self.failure(GetLastError(), doing: "remove")
                }
            }
            try? FileManager.default.removeItem(at: file)
        }

        // MARK: -

        /// Your user's Trusted Root Certification Authorities.
        private static func withTrustedRoots<Result>(_ body: (HCERTSTORE) throws -> Result) throws -> Result {
            let opened = "ROOT".withCString(encodedAs: UTF16.self) { CertOpenSystemStoreW(0, $0) }
            guard let store = opened else { throw failure(GetLastError(), doing: "open") }
            defer { CertCloseStore(store, 0) }
            return try body(store)
        }

        /// The store's copy of a certificate, which the caller frees or deletes.
        private static func find(_ certificate: [UInt8], in store: HCERTSTORE) -> PCCERT_CONTEXT? {
            var context: PCCERT_CONTEXT? = nil
            // Each step frees the context before it.
            while let next = CertEnumCertificatesInStore(store, context) {
                let encoded = UnsafeBufferPointer(
                    start: next.pointee.pbCertEncoded, count: Int(next.pointee.cbCertEncoded))
                if encoded.elementsEqual(certificate) {
                    return next
                }
                context = next
            }
            return nil
        }

        private static func protect(_ data: Data) throws -> Data {
            do {
                return try DataProtection.protect(data)
            } catch {
                throw failure(error.code, doing: "protect")
            }
        }

        private static func unprotect(_ data: Data) throws -> Data {
            do {
                return try DataProtection.unprotect(data)
            } catch {
                throw failure(error.code, doing: "read")
            }
        }

        private static func failure(_ code: DWORD, doing action: String) -> CertificateStoreError {
            if code == DWORD(ERROR_CANCELLED) {
                return .cancelled
            }
            return .failed("Windows couldn't \(action) Reqly's certificate (error \(code)).")
        }
    }
#endif

#if os(Windows)
    /// Data only your user account can read, with Windows' data protection (DPAPI). It never asks
    /// you anything.
    enum DataProtection {
        /// Why Windows couldn't protect the data, or read it back: its error code.
        struct Failure: Error {
            let code: DWORD
        }

        static func protect(_ data: Data) throws(Failure) -> Data {
            try transform(data) { input, output in
                CryptProtectData(input, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), output)
            }
        }

        static func unprotect(_ data: Data) throws(Failure) -> Data {
            try transform(data) { input, output in
                CryptUnprotectData(input, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), output)
            }
        }

        private static func transform(
            _ data: Data, _ body: (UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>) -> Bool
        ) throws(Failure) -> Data {
            var bytes = [UInt8](data)
            let result: Result<Data, Failure> = bytes.withUnsafeMutableBufferPointer { buffer in
                var input = DATA_BLOB(cbData: DWORD(buffer.count), pbData: buffer.baseAddress)
                var output = DATA_BLOB()
                guard body(&input, &output), let result = output.pbData else {
                    return .failure(Failure(code: GetLastError()))
                }
                defer { LocalFree(UnsafeMutableRawPointer(result)) }
                return .success(Data(bytes: result, count: Int(output.cbData)))
            }
            return try result.get()
        }
    }
#endif
