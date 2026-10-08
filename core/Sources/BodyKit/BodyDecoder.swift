import CZlib
import Foundation

#if canImport(Compression)
    import Compression
#endif

/// Unpacks bodies the way the app that received them does, so Reqly can show them. Reqly keeps
/// the bytes exactly as they came over the wire and unpacks them only to show, search or export.
///
/// gzip and deflate go through zlib, which every platform has. Brotli goes through Apple's
/// Compression framework, so only the Mac unpacks it for now.
public enum BodyDecoder {
    /// Unpacked bodies stop growing here, so a tiny malicious body can't fill the memory.
    public static let sizeLimit = 64 * 1024 * 1024

    /// The encodings Reqly can unpack, by their `Content-Encoding` names.
    public static func canDecode(_ contentEncoding: String) -> Bool {
        decodableEncodings.contains(contentEncoding.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static let decodableEncodings: Set<String> = {
        var names: Set<String> = ["gzip", "x-gzip", "deflate", "identity"]
        #if canImport(Compression)
            names.insert("br")
        #endif
        return names
    }()

    /// `data` unpacked according to `contentEncoding`, or `nil` when the encoding isn't supported
    /// or the data is damaged. Stacked encodings, such as `gzip, br`, are unpacked in reverse order.
    public static func decode(_ data: Data, contentEncoding: String?) -> Data? {
        guard let contentEncoding else { return data }
        var body = data
        let encodings = contentEncoding.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        for encoding in encodings.reversed() {
            switch encoding {
            case "identity", "":
                continue
            case "gzip", "x-gzip":
                guard let unpacked = inflateWhole(body, format: .gzip) else { return nil }
                body = unpacked
            case "deflate":
                // HTTP's deflate is supposed to be zlib data, but some servers send raw deflate.
                guard let unpacked = inflateWhole(body, format: hasZlibHeader(body) ? .zlib : .raw) else { return nil }
                body = unpacked
            case "br":
                #if canImport(Compression)
                    guard let unpacked = brotli(body) else { return nil }
                    body = unpacked
                #else
                    return nil
                #endif
            default:
                return nil
            }
        }
        return body
    }

    /// Whether data starts with a zlib header (RFC 1950).
    static func hasZlibHeader(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(2))
        return bytes.count == 2 && bytes[0] & 0x0f == 8 && (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
    }

    /// Data unpacked in one go. Data without its end is cut short, so it doesn't count.
    private static func inflateWhole(_ data: Data, format: Inflater.Format) -> Data? {
        guard !data.isEmpty else { return Data() }
        guard let inflater = Inflater(format), let result = inflater.inflate(data, limit: sizeLimit), result.ended
        else { return nil }
        return result.output
    }

    #if canImport(Compression)
        private static func brotli(_ data: Data) -> Data? {
            guard !data.isEmpty else { return Data() }
            let chunk = 64 * 1024
            var stream = compression_stream(
                dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
            guard
                compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK
            else { return nil }
            defer { compression_stream_destroy(&stream) }
            var output = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { buffer.deallocate() }
            return data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
                stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = input.count
                while true {
                    stream.dst_ptr = buffer
                    stream.dst_size = chunk
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    output.append(buffer, count: chunk - stream.dst_size)
                    guard output.count <= sizeLimit else { return nil }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        // Out of input without an end marker: the body is cut short.
                        if stream.src_size == 0, stream.dst_size == chunk { return nil }
                    case COMPRESSION_STATUS_END:
                        return output
                    default:
                        return nil
                    }
                }
            }
        }
    #endif
}

/// Unpacks raw deflate data that arrives in pieces, keeping what came before: WebSocket's
/// permessage-deflate compresses each message against the ones sent earlier on the connection.
public final class DeflateStream {
    private let inflater = Inflater(.raw)

    public init() {}

    /// The next piece unpacked, or `nil` when the data is damaged or unpacks past `limit`.
    public func decompress(_ data: Data, limit: Int = BodyDecoder.sizeLimit) -> Data? {
        guard let inflater else { return nil }
        guard !data.isEmpty else { return Data() }
        guard let result = inflater.inflate(data, limit: limit) else { return nil }
        if result.ended {
            // A message that ends the stream leaves nothing to refer back to.
            inflater.reset()
        }
        return result.output
    }
}

/// zlib's inflate, fed one piece of data at a time.
final class Inflater {
    enum Format {
        case zlib, raw, gzip

        /// The window size zlib takes for each: its sign and offset pick the wrapper.
        var windowBits: Int32 {
            switch self {
            case .zlib: 15
            case .raw: -15
            case .gzip: 15 + 16
            }
        }
    }

    private let stream: UnsafeMutablePointer<z_stream>

    init?(_ format: Format) {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        guard inflateInit2_(stream, format.windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else {
            stream.deallocate()
            return nil
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    func reset() {
        inflateReset(stream)
    }

    /// What `data` unpacks to, and whether the stream ended with it. `nil` when the data is
    /// damaged, or unpacks past `limit`.
    func inflate(_ data: Data, limit: Int) -> (output: Data, ended: Bool)? {
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> (Data, Bool)? in
            // zlib takes a mutable pointer to its input, but never writes through it.
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            defer {
                stream.pointee.next_in = nil
                stream.pointee.avail_in = 0
            }
            while true {
                stream.pointee.next_out = buffer
                stream.pointee.avail_out = uInt(chunk)
                let status = CZlib.inflate(stream, Z_NO_FLUSH)
                output.append(buffer, count: chunk - Int(stream.pointee.avail_out))
                guard output.count <= limit else { return nil }
                switch status {
                case Z_STREAM_END:
                    return (output, true)
                case Z_OK where stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0,
                    Z_BUF_ERROR where stream.pointee.avail_in == 0:
                    // All of it is in, and more may follow.
                    return (output, false)
                case Z_OK:
                    continue
                default:
                    return nil
                }
            }
        }
    }
}
