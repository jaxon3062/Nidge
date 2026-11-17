import Foundation

/// An open PTP session over PTP/IP: the command connection, the event connection and the
/// transaction counter. Transactions run one at a time in call order.
public actor PTPSession {
    public nonisolated let cameraName: String
    private let command: PTPIPChannel
    private let events: PTPIPChannel
    private var nextTransactionID: UInt32 = 0
    private var tail: Task<Void, Never>?

    /// Connects, performs the PTP/IP init handshake on both connections and opens session 1,
    /// the sequence the Z5II accepted from gphoto2.
    public static func connect(host: String, port: UInt16 = 15740, guid: Data, name: String,
                               timeout: TimeInterval = 5) async throws -> PTPSession {
        precondition(guid.count == 16)
        let command = PTPIPChannel(host: host, port: port)
        try await command.start(timeout: timeout)
        do {
            try await command.send(.initCommandRequest(guid: guid, name: name, version: PTPIPPacket.version1))
            let connectionNumber: UInt32
            let cameraName: String
            switch try await command.receive() {
            case let .initCommandAck(number, _, name, _): (connectionNumber, cameraName) = (number, name)
            case let .initFail(reason): throw PTPError.initFailed(reason: reason)
            default: throw PTPError.unexpectedPacket
            }
            let events = PTPIPChannel(host: host, port: port)
            try await events.start(timeout: timeout)
            do {
                try await events.send(.initEventRequest(connectionNumber: connectionNumber))
                switch try await events.receive() {
                case .initEventAck: break
                case let .initFail(reason): throw PTPError.initFailed(reason: reason)
                default: throw PTPError.unexpectedPacket
                }
                let session = PTPSession(command: command, events: events, cameraName: cameraName)
                _ = try await session.transact(PTPOperation.openSession, [1])
                return session
            } catch {
                events.cancel()
                throw error
            }
        } catch {
            command.cancel()
            throw error
        }
    }

    private init(command: PTPIPChannel, events: PTPIPChannel, cameraName: String) {
        self.command = command
        self.events = events
        self.cameraName = cameraName
    }

    /// Runs one transaction with no data or data coming from the camera.
    /// Throws `PTPError.response` unless the camera answers OK.
    @discardableResult
    public func transact(_ code: UInt16, _ params: [UInt32] = []) async throws -> (params: [UInt32], data: Data) {
        let previous = tail
        let task = Task {
            await previous?.value
            // A caller that gave up while queued (a thumbnail scrolled away) costs nothing. Once
            // a transaction has started it always runs to its response, to keep the stream in step.
            try Task.checkCancellation()
            return try await self.run(code, params)
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func run(_ code: UInt16, _ params: [UInt32]) async throws -> (params: [UInt32], data: Data) {
        let id = nextTransactionID
        nextTransactionID &+= 1
        do {
            try await command.send(.commandRequest(dataPhase: 1, code: code, transactionID: id, params: params))
            var data = Data()
            while true {
                switch try await command.receive() {
                case let .startData(_, totalLength):
                    data.reserveCapacity(Int(clamping: totalLength))
                case let .data(_, payload), let .endData(_, payload):
                    data.append(payload)
                case let .commandResponse(responseCode, _, responseParams):
                    guard responseCode == PTPResponse.ok else { throw PTPError.response(code: responseCode) }
                    return (responseParams, data)
                default:
                    continue
                }
            }
        } catch let error as PTPError {
            if case .response = error { throw error }
            cancel()  // the byte stream is no longer in a known state
            throw error
        } catch {
            cancel()
            throw error
        }
    }

    /// Sends CloseSession and drops both connections.
    public func close() async {
        _ = try? await transact(PTPOperation.closeSession)
        cancel()
    }

    /// Drops both connections without telling the camera.
    public nonisolated func cancel() {
        command.cancel()
        events.cancel()
    }
}
