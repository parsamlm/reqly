#if os(Windows)
    import Dispatch
    import NIOCore
    import NIOSSL
    import WinSDK

    /// Checks the certificates servers send the way Windows does, as Edge does: against the roots
    /// Windows trusts, including the ones it fetches when a chain needs them, and the certificates
    /// it no longer trusts. NIOSSL loads no trusted roots of its own on Windows, where it trusts
    /// nothing; on the Mac it asks macOS in the same way.
    ///
    /// The server's name isn't checked here: NIOSSL checks it once the handshake is done.
    enum WindowsTrust {
        /// What a connection's TLS handler calls with the server's certificates. `extraRoots`, in
        /// DER, are trusted as well, as tests trust the authority of their own server.
        static func callback(extraRoots: [[UInt8]]) -> NIOSSLCustomVerificationCallback {
            { certificates, promise in
                let chain = certificates.compactMap { try? $0.toDERBytes() }
                // Windows may fetch a root or an intermediate to build the chain, so the check stays
                // off the event loop.
                DispatchQueue.global(qos: .userInitiated).async {
                    promise.succeed(verify(chain, extraRoots: extraRoots) ? .certificateVerified : .failed)
                }
            }
        }

        /// Whether `chain`, the server's certificate first, in DER, leads to a root Windows trusts,
        /// or to one of `extraRoots`, and is good for a server's identity.
        static func verify(_ chain: [[UInt8]], extraRoots: [[UInt8]] = []) -> Bool {
            guard let leaf = chain.first, let server = certificate(leaf) else { return false }
            defer { CertFreeCertificateContext(server) }
            // The server's other certificates, and the extra roots, for Windows to build the chain with.
            guard let others = CertOpenStore(storeProviderMemory, 0, 0, 0, nil) else { return false }
            defer { CertCloseStore(others, 0) }
            for der in chain.dropFirst() + extraRoots {
                _ = der.withUnsafeBufferPointer {
                    CertAddEncodedCertificateToStore(
                        others, encoding, $0.baseAddress, DWORD($0.count), DWORD(CERT_STORE_ADD_USE_EXISTING), nil)
                }
            }
            return serverAuthentication.withCString { usage in
                var usages: [LPSTR?] = [UnsafeMutablePointer(mutating: usage)]
                return usages.withUnsafeMutableBufferPointer { usages in
                    var parameters = CERT_CHAIN_PARA()
                    parameters.cbSize = DWORD(MemoryLayout<CERT_CHAIN_PARA>.size)
                    parameters.RequestedUsage.dwType = DWORD(USAGE_MATCH_TYPE_AND)
                    parameters.RequestedUsage.Usage.cUsageIdentifier = 1
                    parameters.RequestedUsage.Usage.rgpszUsageIdentifier = usages.baseAddress
                    var built: PCCERT_CHAIN_CONTEXT?
                    guard CertGetCertificateChain(nil, server, nil, others, &parameters, 0, nil, &built), let built
                    else { return false }
                    defer { CertFreeCertificateChain(built) }
                    if passesPolicy(built, allowingUnknownRoot: false) {
                        return true
                    }
                    // A root Windows doesn't know, but that this connection trusts.
                    return endsAt(built, extraRoots) && passesPolicy(built, allowingUnknownRoot: true)
                }
            }
        }

        /// Windows' checks for a server's certificate chain: trust, dates and use.
        private static func passesPolicy(_ chain: PCCERT_CHAIN_CONTEXT, allowingUnknownRoot: Bool) -> Bool {
            var server = SSL_EXTRA_CERT_CHAIN_POLICY_PARA()
            server.cbSize = DWORD(MemoryLayout<SSL_EXTRA_CERT_CHAIN_POLICY_PARA>.size)
            server.dwAuthType = DWORD(AUTHTYPE_SERVER)
            return withUnsafeMutablePointer(to: &server) { server in
                var policy = CERT_CHAIN_POLICY_PARA()
                policy.cbSize = DWORD(MemoryLayout<CERT_CHAIN_POLICY_PARA>.size)
                policy.dwFlags = allowingUnknownRoot ? DWORD(CERT_CHAIN_POLICY_ALLOW_UNKNOWN_CA_FLAG) : 0
                policy.pvExtraPolicyPara = UnsafeMutableRawPointer(server)
                var status = CERT_CHAIN_POLICY_STATUS()
                status.cbSize = DWORD(MemoryLayout<CERT_CHAIN_POLICY_STATUS>.size)
                return CertVerifyCertificateChainPolicy(policySSL, chain, &policy, &status) && status.dwError == 0
            }
        }

        /// Whether the chain Windows built ends at one of `roots`.
        private static func endsAt(_ chain: PCCERT_CHAIN_CONTEXT, _ roots: [[UInt8]]) -> Bool {
            guard !roots.isEmpty, chain.pointee.cChain > 0, let simple = chain.pointee.rgpChain[0],
                simple.pointee.cElement > 0,
                let top = simple.pointee.rgpElement[Int(simple.pointee.cElement) - 1]?.pointee.pCertContext
            else { return false }
            let der = UnsafeBufferPointer(start: top.pointee.pbCertEncoded, count: Int(top.pointee.cbCertEncoded))
            return roots.contains(Array(der))
        }

        private static func certificate(_ der: [UInt8]) -> PCCERT_CONTEXT? {
            der.withUnsafeBufferPointer { CertCreateCertificateContext(encoding, $0.baseAddress, DWORD($0.count)) }
        }

        private static let encoding = DWORD(X509_ASN_ENCODING | PKCS_7_ASN_ENCODING)
        /// CERT_STORE_PROV_MEMORY and CERT_CHAIN_POLICY_SSL, macros Swift doesn't bring in.
        private static var storeProviderMemory: LPCSTR? { LPCSTR(bitPattern: 2) }
        private static var policySSL: LPCSTR? { LPCSTR(bitPattern: 4) }
        /// szOID_PKIX_KP_SERVER_AUTH: a certificate for a server's identity.
        private static let serverAuthentication = "1.3.6.1.5.5.7.3.1"
    }
#endif
