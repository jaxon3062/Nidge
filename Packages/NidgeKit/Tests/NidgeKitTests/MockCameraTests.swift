import Foundation
import Testing
import NidgeKit
import NidgeMock

@Suite struct MockCameraTests {
    static func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    // Bigger than two chunks and not a multiple of the chunk or packet size.
    static let jpeg = bytes(2_500_123, seed: 1)
    static let heif = bytes(700_001, seed: 2)
    static let files = [
        MockCamera.File(name: "DSC_0001.JPG", format: PTPObjectFormat.jpeg, data: jpeg, thumbnail: bytes(9558, seed: 3)),
        MockCamera.File(name: "DSC_0001.NEF", format: 0x3000, data: bytes(1000, seed: 4)),
        MockCamera.File(name: "DSC_0002.HIF", format: PTPObjectFormat.nikonHEIF, data: heif),
    ]

    func connect(_ port: UInt16) async throws -> Camera {
        try await Camera.connect(host: "127.0.0.1", port: port, guid: Data(0..<16), name: "test", attempts: 1)
    }

    func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nidge-test-\(UUID().uuidString).bin")
    }

    @Test func listsThumbnailsAndDownloads() async throws {
        let mock = MockCamera(files: Self.files)
        let port = try await mock.start()
        defer { Task { await mock.stop() } }
        let camera = try await connect(port)

        #expect(try await camera.deviceInfo().model == "MOCK")
        let storage = try await camera.storageIDs()
        #expect(storage == [MockCamera.storageID])

        // Walk root > DCIM > folder, as gphoto2 did on the camera.
        let root = try await camera.objectHandles(storage: storage[0])
        #expect(root.count == 1)
        let folders = try await camera.objectHandles(storage: storage[0], parent: root[0])
        let handles = try await camera.objectHandles(storage: storage[0], parent: folders[0])
        #expect(handles.count == 3)
        let jpegs = try await camera.objectHandles(storage: storage[0], format: PTPObjectFormat.jpeg, parent: 0)
        #expect(jpegs == [handles[0]])

        let info = try await camera.objectInfo(handles[0])
        #expect(info.filename == "DSC_0001.JPG")
        #expect(info.size == UInt32(Self.jpeg.count))
        #expect(try await camera.thumbnail(handles[0]) == Self.files[0].thumbnail)

        let destination = temporaryFile()
        defer { try? FileManager.default.removeItem(at: destination) }
        try await camera.download(handles[0], size: info.size, to: destination)
        #expect(try Data(contentsOf: destination) == Self.jpeg)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))

        await #expect(throws: PTPError.response(code: 0x2009)) { try await camera.objectInfo(0xDEAD) }
        // A refused command leaves the session usable.
        #expect(try await camera.objectInfo(handles[2]).format == PTPObjectFormat.nikonHEIF)
        await camera.close()
    }

    @Test func resumesAfterConnectionIsCutMidFile() async throws {
        // Cut inside the second chunk.
        let mock = MockCamera(files: Self.files, cutAfterObjectBytes: 1_300_000)
        let port = try await mock.start()
        defer { Task { await mock.stop() } }
        let destination = temporaryFile()
        let part = destination.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: part) }
        let handle: UInt32 = 0x100
        let size = UInt32(Self.jpeg.count)

        let first = try await connect(port)
        await #expect(throws: (any Error).self) { try await first.download(handle, size: size, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // Only the whole first chunk was kept.
        #expect(try Data(contentsOf: part) == Self.jpeg.prefix(Int(Camera.chunkSize)))

        let second = try await connect(port)
        let progress = Progress()
        try await second.download(handle, size: size, to: destination) { progress.record($0) }
        #expect(try Data(contentsOf: destination) == Self.jpeg)
        #expect(progress.first == 2 * Camera.chunkSize)  // resumed, did not start over
        await second.close()
    }

    @Test func concurrentTransactionsDoNotInterleave() async throws {
        let mock = MockCamera(files: Self.files)
        let port = try await mock.start()
        defer { Task { await mock.stop() } }
        let camera = try await connect(port)
        async let jpeg = camera.read(0x100, offset: 0, length: 1 << 20)
        async let heif = camera.read(0x102, offset: 0, length: 1 << 20)
        async let name = camera.objectInfo(0x101).filename
        #expect(try await jpeg == Self.jpeg.prefix(1 << 20))
        #expect(try await heif == Self.heif)
        #expect(try await name == "DSC_0001.NEF")
        await camera.close()
    }

    @Test func connectFailsWhenNothingListens() async {
        await #expect(throws: (any Error).self) { try await connect(1) }
    }
}

final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32] = []
    func record(_ value: UInt32) { lock.withLock { values.append(value) } }
    var first: UInt32? { lock.withLock { values.first } }
}
