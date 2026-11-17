import Foundation
import Testing
import NidgeKit
import NidgeMock

@Suite struct LibraryTests {
    static func item(_ name: String, _ date: String, handle: UInt32 = 1) -> PhotoItem {
        var info = ObjectInfo(storageID: 1, format: name.hasSuffix("HIF") ? PTPObjectFormat.nikonHEIF : PTPObjectFormat.jpeg,
                              size: 10, parent: 0, filename: name)
        info.captureDate = date
        return PhotoItem(handle: handle, info: info)
    }

    @Test func sortsNewestFirstAndGroupsByDay() {
        let items = [
            Self.item("DSC_0001.JPG", "20261112T090000"), Self.item("DSC_0003.HIF", "20261113T175126"),
            Self.item("DSC_0002.JPG", "20261112T235959"), Self.item("DSC_0004.JPG", "20261113T175126"),
        ].sorted(by: PhotoItem.newestFirst)
        #expect(items.map(\.filename) == ["DSC_0004.JPG", "DSC_0003.HIF", "DSC_0002.JPG", "DSC_0001.JPG"])
        let groups = groupByDay(items)
        #expect(groups.map(\.day) == ["20261113", "20261112"])
        #expect(groups.map(\.items.count) == [2, 2])
        #expect(items[1].isHEIF && !items[0].isHEIF)
        #expect(groupByDay([]).isEmpty)
    }

    @Test func ledgerSkipsDuplicatesAndSurvivesReload() throws {
        let a = Self.item("A.JPG", "20261113T000001"), b = Self.item("B.JPG", "20261113T000002")
        var ledger = ImportLedger()
        #expect(ledger.enqueue([a, b]) == 2)
        #expect(ledger.enqueue([a]) == 0)  // already queued
        ledger.markImported(a)
        #expect(ledger.pending == [b])
        #expect(ledger.enqueue([a, b]) == 0)  // imported or queued
        // Same name, different shot: not a duplicate.
        #expect(ledger.enqueue([Self.item("A.JPG", "20270101T000000")]) == 1)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ledger.save(to: url)
        #expect(ImportLedger(contentsOf: url) == ledger)
        try Data("not json".utf8).write(to: url)
        #expect(ImportLedger(contentsOf: url) == ImportLedger())  // a corrupt file starts clean
    }

    @Test func photoHandlesSkipsRawFiles() async throws {
        let mock = MockCamera(files: MockCameraTests.files)  // JPG, NEF, HIF
        let port = try await mock.start()
        defer { Task { await mock.stop() } }
        let camera = try await Camera.connect(host: "127.0.0.1", port: port, guid: Data(0..<16), name: "test", attempts: 1)
        let handles = try await camera.photoHandles()
        #expect(handles == [0x102, 0x100])
        var names: [String] = []
        for handle in handles { names.append(PhotoItem(handle: handle, info: try await camera.objectInfo(handle)).filename) }
        #expect(names == ["DSC_0002.HIF", "DSC_0001.JPG"])
        await camera.close()
    }

    @Test func cancelledDownloadStopsAndKeepsPartFile() async throws {
        let mock = MockCamera(files: MockCameraTests.files)
        let port = try await mock.start()
        defer { Task { await mock.stop() } }
        let camera = try await Camera.connect(host: "127.0.0.1", port: port, guid: Data(0..<16), name: "test", attempts: 1)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination.appendingPathExtension("part")) }
        let task = Task {
            try await camera.download(0x100, size: UInt32(MockCameraTests.jpeg.count), to: destination) { _ in
                withUnsafeCurrentTask { $0?.cancel() }  // cancel after the first chunk
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination.appendingPathExtension("part")).count == Int(Camera.chunkSize))
        await camera.close()
    }

    @Test func cancelledQueuedTransactionIsSkippedAndSessionSurvives() async throws {
        let mock = MockCamera(files: MockCameraTests.files)
        let port = try await mock.start()
        defer { Task { await mock.stop() } }
        let camera = try await Camera.connect(host: "127.0.0.1", port: port, guid: Data(0..<16), name: "test", attempts: 1)
        // Queue a slow read, then a thumbnail behind it that is cancelled while it waits.
        async let big = camera.read(0x100, offset: 0, length: 1 << 20)
        let thumbnail = Task { try await camera.thumbnail(0x100) }
        thumbnail.cancel()
        await #expect(throws: CancellationError.self) { try await thumbnail.value }
        #expect(try await big.count == 1 << 20)
        #expect(try await camera.objectInfo(0x100).filename == "DSC_0001.JPG")
        await camera.close()
    }
}
