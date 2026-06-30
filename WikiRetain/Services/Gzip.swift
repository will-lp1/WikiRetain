import Foundation
import Compression

/// Minimal, dependency-free gunzip built on Apple's `Compression` framework.
///
/// The corpus ships inside the app bundle as `corpus.db.gz` (small enough to live
/// in the GitHub repo) and is inflated to `corpus.db` on first launch — so the app
/// is fully offline with no download step.
///
/// `Compression`'s `COMPRESSION_ZLIB` codec decodes a *raw DEFLATE* stream, so we
/// parse and strip the gzip header/trailer ourselves (RFC 1952) and read the
/// uncompressed size from the trailer's ISIZE field to size the output buffer.
enum Gzip {

    enum GzipError: LocalizedError {
        case notGzip
        case unsupportedMethod
        case truncated
        case inflateFailed
        var errorDescription: String? {
            switch self {
            case .notGzip:            return "File is not in gzip format."
            case .unsupportedMethod:  return "Unsupported gzip compression method."
            case .truncated:          return "Gzip data is truncated."
            case .inflateFailed:      return "Failed to inflate gzip data."
            }
        }
    }

    // gzip header flag bits (RFC 1952 §2.3.1)
    private static let FHCRC: UInt8    = 0x02
    private static let FEXTRA: UInt8   = 0x04
    private static let FNAME: UInt8    = 0x08
    private static let FCOMMENT: UInt8 = 0x10

    /// Inflate a gzip-compressed buffer to its original bytes.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18 else { throw GzipError.truncated }               // 10 header + 8 trailer min
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { throw GzipError.notGzip }
        guard bytes[2] == 0x08 else { throw GzipError.unsupportedMethod }        // DEFLATE only

        let flags = bytes[3]
        var idx = 10  // fixed header: magic(2) method(1) flags(1) mtime(4) xfl(1) os(1)

        if flags & FEXTRA != 0 {
            guard idx + 2 <= bytes.count else { throw GzipError.truncated }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flags & FNAME != 0    { idx = try skipCString(bytes, from: idx) }
        if flags & FCOMMENT != 0 { idx = try skipCString(bytes, from: idx) }
        if flags & FHCRC != 0    { idx += 2 }

        guard idx <= bytes.count - 8 else { throw GzipError.truncated }

        // Trailer: CRC32(4) + ISIZE(4), little-endian. ISIZE = original size mod 2^32.
        let n = bytes.count
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8)
            | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)

        let deflateRange = idx..<(n - 8)
        guard !deflateRange.isEmpty else { throw GzipError.truncated }

        // ISIZE is the expected output size; allocate it (fall back to a generous
        // estimate if the trailer reports an implausible value).
        var capacity = isize > 0 ? isize : deflateRange.count * 8
        var attempt = 0
        while true {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = bytes.withUnsafeBufferPointer { buf -> Int in
                compression_decode_buffer(
                    dst, capacity,
                    buf.baseAddress!.advanced(by: deflateRange.lowerBound), deflateRange.count,
                    nil, COMPRESSION_ZLIB
                )
            }
            if written > 0 && (written < capacity || written == isize) {
                return Data(bytes: dst, count: written)
            }
            // Output filled the buffer exactly but ISIZE didn't confirm it — grow and retry.
            attempt += 1
            if attempt > 4 { throw GzipError.inflateFailed }
            capacity *= 2
        }
    }

    private static func skipCString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var i = start
        while i < bytes.count && bytes[i] != 0 { i += 1 }
        guard i < bytes.count else { throw GzipError.truncated }
        return i + 1  // skip the terminating NUL
    }
}
