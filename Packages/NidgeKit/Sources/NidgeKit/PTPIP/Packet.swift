import Foundation

/// One PTP/IP packet. On the wire: 4-byte length (including this header), 4-byte type, payload.
public enum PTPIPPacket: Equatable, Sendable {
    case initCommandRequest(guid: Data, name: String, version: UInt32)
    case initCommandAck(connectionNumber: UInt32, guid: Data, name: String, version: UInt32)
    case initEventRequest(connectionNumber: UInt32)
    case initEventAck
    case initFail(reason: UInt32)
    case commandRequest(dataPhase: UInt32, code: UInt16, transactionID: UInt32, params: [UInt32])
    case commandResponse(code: UInt16, transactionID: UInt32, params: [UInt32])
    case event(code: UInt16, transactionID: UInt32, params: [UInt32])
    case startData(transactionID: UInt32, totalLength: UInt64)
    case data(transactionID: UInt32, payload: Data)
    case cancel(transactionID: UInt32)
    case endData(transactionID: UInt32, payload: Data)
    case ping
    case pong

    public static let version1: UInt32 = 0x0001_0000
    static let headerLength = 8

    public func encoded() -> Data {
        var body = Data()
        let type: UInt32
        switch self {
        case let .initCommandRequest(guid, name, version):
            type = 1
            body.append(guid); body.append(utf16: name); body.append(le: version)
        case let .initCommandAck(connectionNumber, guid, name, version):
            type = 2
            body.append(le: connectionNumber); body.append(guid); body.append(utf16: name); body.append(le: version)
        case let .initEventRequest(connectionNumber):
            type = 3
            body.append(le: connectionNumber)
        case .initEventAck:
            type = 4
        case let .initFail(reason):
            type = 5
            body.append(le: reason)
        case let .commandRequest(dataPhase, code, transactionID, params):
            type = 6
            body.append(le: dataPhase); body.append(le: code); body.append(le: transactionID)
            for param in params { body.append(le: param) }
        case let .commandResponse(code, transactionID, params):
            type = 7
            body.append(le: code); body.append(le: transactionID)
            for param in params { body.append(le: param) }
        case let .event(code, transactionID, params):
            type = 8
            body.append(le: code); body.append(le: transactionID)
            for param in params { body.append(le: param) }
        case let .startData(transactionID, totalLength):
            type = 9
            body.append(le: transactionID); body.append(le: totalLength)
        case let .data(transactionID, payload):
            type = 10
            body.append(le: transactionID); body.append(payload)
        case let .cancel(transactionID):
            type = 11
            body.append(le: transactionID)
        case let .endData(transactionID, payload):
            type = 12
            body.append(le: transactionID); body.append(payload)
        case .ping:
            type = 13
        case .pong:
            type = 14
        }
        var packet = Data(capacity: Self.headerLength + body.count)
        packet.append(le: UInt32(Self.headerLength + body.count))
        packet.append(le: type)
        packet.append(body)
        return packet
    }

    /// Decodes a packet from its type and payload (the bytes after the 8-byte header).
    public init(type: UInt32, payload: Data) throws {
        var r = ByteReader(payload)
        switch type {
        case 1:
            let guid = try r.bytes(16)
            let tail = r.rest()
            guard tail.count >= 4 else { throw PTPError.truncated }
            var version = ByteReader(tail.suffix(4))
            self = .initCommandRequest(guid: guid, name: ByteReader.utf16(tail.dropLast(4)), version: try version.u32())
        case 2:
            let number = try r.u32()
            let guid = try r.bytes(16)
            let tail = r.rest()
            guard tail.count >= 4 else { throw PTPError.truncated }
            var version = ByteReader(tail.suffix(4))
            self = .initCommandAck(connectionNumber: number, guid: guid,
                                   name: ByteReader.utf16(tail.dropLast(4)), version: try version.u32())
        case 3: self = .initEventRequest(connectionNumber: try r.u32())
        case 4: self = .initEventAck
        case 5: self = .initFail(reason: try r.u32())
        case 6:
            self = .commandRequest(dataPhase: try r.u32(), code: try r.u16(), transactionID: try r.u32(),
                                   params: try r.u32sToEnd())
        case 7: self = .commandResponse(code: try r.u16(), transactionID: try r.u32(), params: try r.u32sToEnd())
        case 8: self = .event(code: try r.u16(), transactionID: try r.u32(), params: try r.u32sToEnd())
        case 9: self = .startData(transactionID: try r.u32(), totalLength: try r.u64())
        case 10: self = .data(transactionID: try r.u32(), payload: r.rest())
        case 11: self = .cancel(transactionID: try r.u32())
        case 12: self = .endData(transactionID: try r.u32(), payload: r.rest())
        case 13: self = .ping
        case 14: self = .pong
        default: throw PTPError.unknownPacketType(type)
        }
    }

    /// Decodes one whole packet including its header.
    public init(encoded: Data) throws {
        var r = ByteReader(encoded)
        let length = Int(try r.u32())
        let type = try r.u32()
        guard length >= Self.headerLength, length == encoded.count else { throw PTPError.truncated }
        try self.init(type: type, payload: r.rest())
    }
}
