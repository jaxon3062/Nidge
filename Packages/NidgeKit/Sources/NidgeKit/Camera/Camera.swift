import Foundation

/// High-level, download-only view of the camera.
public struct Camera: Sendable {
    public let session: PTPSession

    /// Bytes requested per GetPartialObject call. gphoto2 used 1 MiB against the Z5II.
    public static let chunkSize: UInt32 = 1 << 20

    public init(session: PTPSession) {
        self.session = session
    }

    /// Connects with retries: the Z5II's access point was seen to refuse or ignore the first
    /// attempts right after the network is joined.
    public static func connect(host: String = "192.168.1.1", port: UInt16 = 15740, guid: Data, name: String,
                               attempts: Int = 3) async throws -> Camera {
        var lastError: Error = PTPError.connectionClosed
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            do {
                return Camera(session: try await PTPSession.connect(host: host, port: port, guid: guid, name: name))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func close() async {
        await session.close()
    }

    public func deviceInfo() async throws -> DeviceInfo {
        try DeviceInfo(data: try await session.transact(PTPOperation.getDeviceInfo).data)
    }

    public func storageIDs() async throws -> [UInt32] {
        try decodeUInt32Array(try await session.transact(PTPOperation.getStorageIDs).data)
    }

    /// Handles of the children of `parent`. `0xFFFFFFFF` means the storage root, which is how
    /// the Z5II was walked in M0. `format` 0 means any format.
    public func objectHandles(storage: UInt32, format: UInt16 = 0, parent: UInt32 = 0xFFFF_FFFF) async throws -> [UInt32] {
        try decodeUInt32Array(
            try await session.transact(PTPOperation.getObjectHandles, [storage, UInt32(format), parent]).data)
    }

    /// Handles of every file on a card, in card order (oldest first on the Z5II), using the DCF
    /// layout seen there: root > `DCIM` > one level of folders > files. Costs one ObjectInfo
    /// call per root entry and no per-file calls.
    public func fileHandles(storage: UInt32) async throws -> [UInt32] {
        var files: [UInt32] = []
        for entry in try await objectHandles(storage: storage) where try await objectInfo(entry).filename == "DCIM" {
            for folder in try await objectHandles(storage: storage, parent: entry) {
                files += try await objectHandles(storage: storage, parent: folder)
            }
        }
        return files
    }

    public func objectInfo(_ handle: UInt32) async throws -> ObjectInfo {
        try ObjectInfo(data: try await session.transact(PTPOperation.getObjectInfo, [handle]).data)
    }

    /// The camera's embedded thumbnail (a 160x120 JPEG on the Z5II).
    public func thumbnail(_ handle: UInt32) async throws -> Data {
        try await session.transact(PTPOperation.getThumb, [handle]).data
    }

    /// Nikon's larger preview image (GetLargeThumb). Untested on the Z5II: callers must cope
    /// with a refusal or with data that is not an image.
    public func largeThumbnail(_ handle: UInt32) async throws -> Data {
        try await session.transact(PTPOperation.nikonGetLargeThumb, [handle]).data
    }

    public func read(_ handle: UInt32, offset: UInt32, length: UInt32) async throws -> Data {
        try await session.transact(PTPOperation.getPartialObject, [handle, offset, length]).data
    }

    /// Downloads an object to `destination`, resuming from `<destination>.part` if a previous
    /// attempt left one. Only whole chunks are ever appended to the part file, so after a
    /// dropped connection the caller reconnects and calls this again.
    public func download(_ handle: UInt32, size: UInt32, to destination: URL,
                         progress: (@Sendable (UInt32) -> Void)? = nil) async throws {
        let part = destination.appendingPathExtension("part")
        let fm = FileManager.default
        var offset = (try? fm.attributesOfItem(atPath: part.path)[.size] as? UInt64).flatMap { UInt32(exactly: $0) } ?? 0
        if offset > size || !fm.fileExists(atPath: part.path) {
            guard fm.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            offset = 0
        }
        let file = try FileHandle(forWritingTo: part)
        defer { try? file.close() }
        try file.seekToEnd()
        while offset < size {
            try Task.checkCancellation()
            let chunk = try await read(handle, offset: offset, length: min(Self.chunkSize, size - offset))
            guard !chunk.isEmpty, UInt64(offset) + UInt64(chunk.count) <= UInt64(size) else { throw PTPError.truncated }
            try file.write(contentsOf: chunk)
            offset += UInt32(chunk.count)
            progress?(offset)
        }
        try file.close()
        _ = try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
    }
}
