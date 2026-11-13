import Foundation
import Testing
@testable import NidgeKit

@Suite struct CodecTests {
    @Test func decodesRecordedInitCommandAck() throws {
        let packet = try PTPIPPacket(encoded: Fixtures.initCommandAck)
        #expect(packet == .initCommandAck(connectionNumber: 7, guid: Data(count: 16), name: "Z5_2_0000000",
                                          version: 0x0001_0000))
        #expect(packet.encoded() == Fixtures.initCommandAck)
    }

    @Test func encodesInitCommandRequestLikeGphoto2() throws {
        let packet = PTPIPPacket.initCommandRequest(guid: Data(0..<16), name: "nidge-test", version: PTPIPPacket.version1)
        #expect(packet.encoded() == Fixtures.initCommandRequest)
        #expect(try PTPIPPacket(encoded: Fixtures.initCommandRequest) == packet)
    }

    @Test func encodesGetObjectInfoRequestLikeGphoto2() throws {
        guard case let .commandRequest(dataPhase, code, id, params) = try PTPIPPacket(encoded: Fixtures.getObjectInfoRequest)
        else { Issue.record("not a command request"); return }
        #expect(code == PTPOperation.getObjectInfo)
        #expect(params == [0x6919_09B8])
        #expect(PTPIPPacket.commandRequest(dataPhase: dataPhase, code: code, transactionID: id, params: params).encoded()
            == Fixtures.getObjectInfoRequest)
    }

    @Test func decodesRecordedReplyStream() throws {
        // Split the camera's byte stream into packets the way the channel does.
        var packets: [PTPIPPacket] = []
        var rest = Fixtures.getObjectInfoReply
        while !rest.isEmpty {
            var header = ByteReader(rest)
            let length = Int(try header.u32())
            packets.append(try PTPIPPacket(encoded: Data(rest.prefix(length))))
            rest = Data(rest.dropFirst(length))
        }
        guard packets.count == 3, case let .startData(_, total) = packets[0], case let .endData(_, payload) = packets[1],
              case let .commandResponse(code, _, params) = packets[2]
        else { Issue.record("unexpected packets \(packets)"); return }
        #expect(total == 146)
        #expect(payload == Fixtures.objectInfoHIF)
        #expect(code == PTPResponse.ok)
        #expect(params.isEmpty)
    }

    @Test func decodesRecordedEvent() throws {
        #expect(try PTPIPPacket(encoded: Fixtures.event)
            == .event(code: 0x4006, transactionID: 0xFFFF_FFFF, params: [0x5007]))
    }

    @Test func decodesRecordedHEIFObjectInfo() throws {
        let info = try ObjectInfo(data: Fixtures.objectInfoHIF)
        #expect(info.filename == "DSC_2488.HIF")
        #expect(info.format == PTPObjectFormat.nikonHEIF)
        #expect(info.size == 2_762_328)
        #expect(info.thumbFormat == 0x3808)
        #expect(info.thumbSize == 7986)
        #expect([info.thumbWidth, info.thumbHeight, info.width, info.height] == [160, 120, 6048, 4032])
        #expect(info.parent == 0x1119_0000)
        #expect(info.storageID == 0x0001_0001)
        #expect(info.captureDate == "20261113T175126")
        #expect(info.encoded() == Fixtures.objectInfoHIF)
    }

    @Test func decodesRecordedDeviceInfo() throws {
        let info = try DeviceInfo(data: Fixtures.deviceInfo)
        #expect(info.standardVersion == 100)
        #expect(info.vendorExtensionID == 0xFFFF_FFFF)
        #expect(info.manufacturer == "Nikon Corporation")
        #expect(info.model == "Z5_2")
        #expect(info.deviceVersion == "V1.20")
        #expect(info.operations.count == 130)
        #expect(info.operations.contains(PTPOperation.getPartialObject))
        #expect(info.events.count == 26)
        #expect(info.imageFormats == [0x3801, 0x3000, 0x3001, 0x3008, 0x380D, 0x3002, 0x300D, 0xB200, 0xB201, 0xB982])
        #expect(Set(info.serialNumber) == ["0"])
    }

    @Test func decodesRecordedStorageIDs() throws {
        #expect(try decodeUInt32Array(Fixtures.storageIDs) == [0x0001_0001, 0x0002_0000])
    }

    @Test func roundTripsEveryPacketType() throws {
        let packets: [PTPIPPacket] = [
            .initEventRequest(connectionNumber: 3), .initEventAck, .initFail(reason: 1),
            .commandResponse(code: 0x2001, transactionID: 9, params: [0x10_0000]),
            .startData(transactionID: 9, totalLength: 1 << 33), .data(transactionID: 9, payload: Data([1, 2, 3])),
            .cancel(transactionID: 9), .endData(transactionID: 9, payload: Data()), .ping, .pong,
        ]
        for packet in packets {
            #expect(try PTPIPPacket(encoded: packet.encoded()) == packet)
        }
    }

    @Test func rejectsTruncatedAndUnknownPackets() {
        #expect(throws: PTPError.truncated) { try PTPIPPacket(encoded: Fixtures.initCommandAck.dropLast(1)) }
        #expect(throws: PTPError.truncated) { try ObjectInfo(data: Fixtures.objectInfoHIF.prefix(60)) }
        #expect(throws: PTPError.unknownPacketType(99)) { try PTPIPPacket(type: 99, payload: Data()) }
    }
}
