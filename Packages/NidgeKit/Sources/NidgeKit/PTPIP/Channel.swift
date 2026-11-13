import Foundation
import Network

/// One TCP connection carrying PTP/IP packets. Used by the client and by the mock camera.
public final class PTPIPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "nidge.ptpip.channel")
    /// A read that gets nothing for this long fails with `.timeout`: the camera's Wi-Fi can
    /// vanish without closing the TCP connection.
    private let readTimeout: TimeInterval

    public init(connection: NWConnection, readTimeout: TimeInterval = 15) {
        self.connection = connection
        self.readTimeout = readTimeout
    }

    public convenience init(host: String, port: UInt16, readTimeout: TimeInterval = 15) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        self.init(connection: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                           using: NWParameters(tls: nil, tcp: tcp)),
                  readTimeout: readTimeout)
    }

    /// Waits until the connection is ready. Fails instead of waiting for the network to appear.
    public func start(timeout: TimeInterval = 5) async throws {
        let once = Once()
        let timer = DispatchWorkItem { [connection] in connection.cancel() }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                    connection.cancel()
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: PTPError.timeout) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ packet: PTPIPPacket) async throws {
        try await send(raw: packet.encoded())
    }

    public func send(raw data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> PTPIPPacket {
        var header = ByteReader(try await read(PTPIPPacket.headerLength))
        let length = Int(try header.u32())
        let type = try header.u32()
        guard length >= PTPIPPacket.headerLength else { throw PTPError.truncated }
        let payload = length > PTPIPPacket.headerLength ? try await read(length - PTPIPPacket.headerLength) : Data()
        return try PTPIPPacket(type: type, payload: payload)
    }

    public func cancel() {
        connection.cancel()
    }

    private func read(_ count: Int) async throws -> Data {
        let timedOut = Once()
        let timer = DispatchWorkItem { [connection] in
            _ = timedOut.claim()
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + readTimeout, execute: timer)
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if timedOut.claimed {
                    continuation.resume(throwing: PTPError.timeout)
                } else {
                    continuation.resume(throwing: error ?? PTPError.connectionClosed)
                }
            }
        }
    }
}

/// Thread-safe one-shot flag.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    var claimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }
}
