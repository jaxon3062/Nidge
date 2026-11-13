import Foundation
import Network
import NidgeKit

/// A PTP/IP camera that serves files from memory. It follows the PTP spec and frames data the
/// way the Z5II was seen to (StartData, 65688-byte Data packets, last piece in EndData); it
/// does not prove anything about the real camera.
public actor MockCamera {
    public struct File: Sendable {
        public var name: String
        public var format: UInt16
        public var data: Data
        public var thumbnail: Data

        public init(name: String, format: UInt16, data: Data, thumbnail: Data = Data()) {
            self.name = name
            self.format = format
            self.data = data
            self.thumbnail = thumbnail
        }
    }

    public static let storageID: UInt32 = 0x0001_0001
    static let dcimHandle: UInt32 = 1
    static let folderHandle: UInt32 = 2
    static let firstFileHandle: UInt32 = 0x100

    private let files: [File]
    /// When set, the connection is dropped once this many object bytes have been sent.
    private var cutAfterObjectBytes: Int?
    private var listener: NWListener?
    private var channels: [PTPIPChannel] = []
    private var connectionCount: UInt32 = 0

    public init(files: [File], cutAfterObjectBytes: Int? = nil) {
        self.files = files
        self.cutAfterObjectBytes = cutAfterObjectBytes
    }

    /// Starts listening on localhost. Port 0 picks a free port. Returns the port in use.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            let channel = PTPIPChannel(connection: connection, readTimeout: 3600)
            Task { await self?.serve(channel) }
        }
        let resumed = Flag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.set() { continuation.resume() }
                case .failed(let error): if resumed.set() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return listener.port?.rawValue ?? port
    }

    public func stop() {
        listener?.cancel()
        channels.forEach { $0.cancel() }
        channels = []
    }

    private func serve(_ channel: PTPIPChannel) async {
        channels.append(channel)
        do {
            try await channel.start()
            switch try await channel.receive() {
            case .initCommandRequest:
                connectionCount += 1
                try await channel.send(.initCommandAck(connectionNumber: connectionCount, guid: Data(count: 16),
                                                       name: "MOCK_0000000", version: PTPIPPacket.version1))
                while true { try await handle(try await channel.receive(), on: channel) }
            case .initEventRequest:
                try await channel.send(.initEventAck)
                while true { _ = try await channel.receive() }  // hold open until the client leaves
            default:
                channel.cancel()
            }
        } catch {
            channel.cancel()
        }
    }

    private func info(_ handle: UInt32) -> ObjectInfo? {
        switch handle {
        case Self.dcimHandle, Self.folderHandle:
            var info = ObjectInfo(storageID: Self.storageID, format: PTPObjectFormat.association, size: 0,
                                  parent: handle == Self.dcimHandle ? 0 : Self.dcimHandle,
                                  filename: handle == Self.dcimHandle ? "DCIM" : "100NIDGE")
            info.associationType = 1
            return info
        default:
            guard let file = file(handle) else { return nil }
            var info = ObjectInfo(storageID: Self.storageID, format: file.format, size: UInt32(file.data.count),
                                  parent: Self.folderHandle, filename: file.name)
            info.thumbFormat = 0x3808
            info.thumbSize = UInt32(file.thumbnail.count)
            info.captureDate = "20260101T000000"
            return info
        }
    }

    private func file(_ handle: UInt32) -> File? {
        let index = Int(handle) - Int(Self.firstFileHandle)
        return files.indices.contains(index) ? files[index] : nil
    }

    private func handle(_ packet: PTPIPPacket, on channel: PTPIPChannel) async throws {
        guard case let .commandRequest(_, code, id, params) = packet else { return }
        func respond(_ code: UInt16, _ params: [UInt32] = []) async throws {
            try await channel.send(.commandResponse(code: code, transactionID: id, params: params))
        }
        func reply(_ data: Data, _ params: [UInt32] = []) async throws {
            try await sendData(data, transactionID: id, on: channel)
            try await respond(PTPResponse.ok, params)
        }
        let invalidHandle: UInt16 = 0x2009
        switch code {
        case PTPOperation.openSession, PTPOperation.closeSession:
            try await respond(PTPResponse.ok)
        case PTPOperation.getDeviceInfo:
            try await reply(deviceInfo())
        case PTPOperation.getStorageIDs:
            var d = Data(); d.appendArray([Self.storageID]); try await reply(d)
        case PTPOperation.getObjectHandles:
            let format = params.count > 1 ? UInt16(truncatingIfNeeded: params[1]) : 0
            let parent = params.count > 2 ? params[2] : 0
            let all = [Self.dcimHandle, Self.folderHandle] + files.indices.map { Self.firstFileHandle + UInt32($0) }
            let handles = all.filter { handle in
                guard let info = info(handle) else { return false }
                let parentMatches = parent == 0 || info.parent == (parent == 0xFFFF_FFFF ? 0 : parent)
                return parentMatches && (format == 0 || info.format == format)
            }
            var d = Data(); d.appendArray(handles); try await reply(d)
        case PTPOperation.getObjectInfo:
            guard let info = params.first.flatMap(info) else { return try await respond(invalidHandle) }
            try await reply(info.encoded())
        case PTPOperation.getThumb:
            guard let file = params.first.flatMap(file) else { return try await respond(invalidHandle) }
            try await reply(file.thumbnail)
        case PTPOperation.getPartialObject:
            guard params.count == 3, let file = file(params[0]), Int(params[1]) <= file.data.count else {
                return try await respond(invalidHandle)
            }
            let start = Int(params[1])
            let slice = file.data.subdata(in: start..<min(start + Int(params[2]), file.data.count))
            if let budget = cutAfterObjectBytes {
                if slice.count > budget {
                    // Send part of the chunk, then vanish like the camera's Wi-Fi does.
                    cutAfterObjectBytes = nil
                    try await channel.send(.startData(transactionID: id, totalLength: UInt64(slice.count)))
                    try await channel.send(.data(transactionID: id, payload: slice.prefix(budget)))
                    channel.cancel()
                    throw PTPError.connectionClosed
                }
                cutAfterObjectBytes = budget - slice.count
            }
            try await reply(slice, [UInt32(slice.count)])
        default:
            try await respond(0x2005)  // OperationNotSupported
        }
    }

    private func sendData(_ data: Data, transactionID id: UInt32, on channel: PTPIPChannel) async throws {
        let packetSize = 65688
        try await channel.send(.startData(transactionID: id, totalLength: UInt64(data.count)))
        var rest = data[...]
        while rest.count > packetSize {
            try await channel.send(.data(transactionID: id, payload: Data(rest.prefix(packetSize))))
            rest = rest.dropFirst(packetSize)
        }
        try await channel.send(.endData(transactionID: id, payload: Data(rest)))
    }

    private func deviceInfo() -> Data {
        var d = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func string(_ s: String) {
            d.append(UInt8(s.utf16.count + 1))
            for unit in s.utf16 { le(unit) }
            le(UInt16(0))
        }
        le(UInt16(100)); le(UInt32(0xFFFF_FFFF)); le(UInt16(110)); string("Mock"); le(UInt16(0))
        let operations: [UInt16] = [0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008, 0x100A, 0x101B]
        le(UInt32(operations.count)); operations.forEach { le($0) }
        for _ in 0..<4 { le(UInt32(0)) }  // events, properties, capture formats, image formats
        string("Nidge"); string("MOCK"); string("V0.0"); string("0000000")
        return d
    }
}

private extension Data {
    mutating func appendArray(_ values: [UInt32]) {
        for value in [UInt32(values.count)] + values {
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
