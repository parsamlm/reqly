#if os(Windows)
    import CWinINet
    import WinSDK

    /// Your user's proxy settings for the local network, read and changed through WinINet. Apps
    /// hear about a change at once.
    public struct WinINetProxySettings: ProxySettingsStore {
        public init() {}

        public enum Failure: Error, Equatable {
            case cannotRead(Int32)
            case cannotChange(Int32)
        }

        public func read() throws -> ProxySettings {
            var flags: UInt32 = 0
            var server: UnsafeMutablePointer<wchar_t>?
            var bypass: UnsafeMutablePointer<wchar_t>?
            var setupScript: UnsafeMutablePointer<wchar_t>?
            let error = wininet_read_proxy(&flags, &server, &bypass, &setupScript)
            defer {
                wininet_free(server)
                wininet_free(bypass)
                wininet_free(setupScript)
            }
            guard error == 0 else { throw Failure.cannotRead(error) }
            return ProxySettings(
                flags: flags, server: Self.text(server), bypass: Self.text(bypass),
                setupScript: Self.text(setupScript))
        }

        public func write(_ settings: ProxySettings) throws {
            let error = Self.wide(settings.server) { server in
                Self.wide(settings.bypass) { bypass in
                    Self.wide(settings.setupScript) { setupScript in
                        wininet_write_proxy(settings.flags, server, bypass, setupScript)
                    }
                }
            }
            guard error == 0 else { throw Failure.cannotChange(error) }
        }

        private static func text(_ pointer: UnsafeMutablePointer<wchar_t>?) -> String? {
            guard let pointer else { return nil }
            let text = String(decodingCString: pointer, as: UTF16.self)
            return text.isEmpty ? nil : text
        }

        /// Text as a wide C string for the call, or NULL for none.
        private static func wide<Result>(_ text: String?, _ body: (UnsafePointer<wchar_t>?) -> Result) -> Result {
            guard let text else { return body(nil) }
            return text.withCString(encodedAs: UTF16.self, body)
        }
    }
#endif
