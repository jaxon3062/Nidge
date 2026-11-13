import Foundation

public enum PTPError: Error, Equatable {
    case truncated
    case unknownPacketType(UInt32)
    case initFailed(reason: UInt32)
    case unexpectedPacket
    case connectionClosed
    case timeout
    /// The camera answered a command with a response code other than OK (0x2001).
    case response(code: UInt16)
}

/// Little-endian reader for PTP/IP packets and PTP datasets.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw PTPError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }

    mutating func integer<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        try bytes(MemoryLayout<T>.size).reversed().reduce(0) { $0 << 8 | T(truncatingIfNeeded: $1) }
    }

    mutating func u8() throws -> UInt8 { try integer() }
    mutating func u16() throws -> UInt16 { try integer() }
    mutating func u32() throws -> UInt32 { try integer() }
    mutating func u64() throws -> UInt64 { try integer() }

    /// PTP string: one length byte counting UTF-16 code units including the terminating null.
    mutating func string() throws -> String {
        let count = Int(try u8())
        return Self.utf16(try bytes(count * 2))
    }

    mutating func array<T: FixedWidthInteger>(of _: T.Type = T.self) throws -> [T] {
        let count = Int(try u32())
        guard remaining >= count * MemoryLayout<T>.size else { throw PTPError.truncated }
        return try (0..<count).map { _ in try integer() }
    }

    mutating func u32sToEnd() throws -> [UInt32] {
        try (0..<remaining / 4).map { _ in try u32() }
    }

    /// UTF-16LE text up to the first null.
    static func utf16(_ data: Data) -> String {
        var units: [UInt16] = []
        var reader = ByteReader(data)
        while let unit = try? reader.u16(), unit != 0 { units.append(unit) }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Null-terminated UTF-16LE, as used for names in the PTP/IP init packets.
    mutating func append(utf16 string: String) {
        for unit in string.utf16 { append(le: unit) }
        append(le: UInt16(0))
    }

    /// PTP string with its length byte. Empty strings are a single zero byte.
    mutating func append(ptpString string: String) {
        guard !string.isEmpty else { return append(0) }
        append(UInt8(string.utf16.count + 1))
        append(utf16: string)
    }

    mutating func append<T: FixedWidthInteger>(ptpArray values: [T]) {
        append(le: UInt32(values.count))
        for value in values { append(le: value) }
    }
}
