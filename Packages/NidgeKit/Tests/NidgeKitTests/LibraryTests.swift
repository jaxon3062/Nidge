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

    @Test func ledgerSkipsQueuedAndSurvivesReload() throws {
        let a = Self.item("A.JPG", "20261113T000001"), b = Self.item("B.JPG", "20261113T000002")
        var ledger = ImportLedger()
        #expect(ledger.enqueue([a, b]) == 2)
        #expect(ledger.enqueue([a]) == 0)  // already queued
        ledger.markImported(a)
        #expect(ledger.pending == [b])
        #expect(ledger.enqueue([a, b]) == 1)  // a again (another size or format); b is still queued
        #expect(ledger.pending == [b, a])
        #expect(ledger.imported.contains(a.key))  // still marked as imported
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
        let withRAW = try await camera.photoHandles(formats: [PTPObjectFormat.jpeg, PTPObjectFormat.nikonHEIF, PTPObjectFormat.undefined])
        #expect(withRAW == [0x102, 0x101, 0x100])
        let raw = PhotoItem(handle: 0x101, info: try await camera.objectInfo(0x101))
        let jpeg = PhotoItem(handle: 0x100, info: try await camera.objectInfo(0x100))
        #expect(raw.isRAW && !jpeg.isRAW)
        #expect(raw.shot == jpeg.shot)  // DSC_0001.NEF and DSC_0001.JPG in the same folder
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

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Suite struct ImageResizerTests {
    /// A 3000x2000 JPEG stored sideways (orientation 6) with a capture date.
    static func makeJPEG() throws -> URL {
        let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resize-\(UUID().uuidString).jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:12 16:33:59"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TEST CAMERA"],
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
    }

    @Test func shrinksToTargetKeepingMetadataAndUprightPixels() throws {
        let original = try Self.makeJPEG()
        let resized = try ImageResizer.resize(original, longSide: 1500)
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: resized) }
        #expect(resized != original)
        let properties = Self.properties(resized)
        let width = properties[kCGImagePropertyPixelWidth] as! Int, height = properties[kCGImagePropertyPixelHeight] as! Int
        // Rotated upright: now portrait, 2:3, long side as asked.
        #expect(width == 1000)
        #expect(height == 1500)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:12 16:33:59")
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "TEST CAMERA")
    }

    @Test func leavesSmallImagesAndRejectsNonImages() throws {
        let original = try Self.makeJPEG()  // 3000x2000
        defer { try? FileManager.default.removeItem(at: original) }
        #expect(try ImageResizer.resize(original, longSide: 4528) == original)
        #expect(try ImageResizer.resize(original, longSide: 3000) == original)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(throws: ImageResizer.Failure.self) { try ImageResizer.resize(junk, longSide: 3024) }
    }
}

@Suite struct EmbeddedPreviewTests {
    /// A JPEG header with an MPF index like the Z5II's: primary, then two previews.
    static func header(little: Bool) -> Data {
        func u16(_ v: Int) -> [UInt8] { little ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { little ? (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } : (0..<4).reversed().map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var tiff: [UInt8] = little ? [0x49, 0x49, 0x2A, 0x00] : [0x4D, 0x4D, 0x00, 0x2A]
        tiff += u32(8) + u16(2)                              // IFD at 8, two tags
        tiff += u16(0xB000) + u16(7) + u32(4) + [0x30, 0x31, 0x30, 0x30]  // version, ignored
        tiff += u16(0xB002) + u16(7) + u32(48) + u32(38)     // 3 entries at 38
        tiff += u32(0)
        tiff += u32(0x20030000) + u32(5000) + u32(0) + u32(0)        // primary
        tiff += u32(0x00010001) + u32(900) + u32(9000) + u32(0)      // big preview
        tiff += u32(0x00010001) + u32(200) + u32(6000) + u32(0)      // small preview
        let app1: [UInt8] = [0xFF, 0xE1, 0x00, 0x08] + Array("Exif\0\0".utf8)
        let app2: [UInt8] = [0xFF, 0xE2] + [UInt8((tiff.count + 6) >> 8), UInt8((tiff.count + 6) & 0xFF)] + Array("MPF\0".utf8) + tiff
        return Data([0xFF, 0xD8] + app1 + app2 + [0xFF, 0xDA, 0x00, 0x02])
    }

    @Test(arguments: [true, false]) func findsPreviewRangesSmallestFirst(little: Bool) {
        let header = Self.header(little: little)
        let base = 2 + 10 + 8  // SOI, APP1 (marker + 8), APP2 marker, length and "MPF\0"
        #expect(EmbeddedPreview.jpegRanges(header: header, fileSize: 20000) == [base + 6000..<base + 6200, base + 9000..<base + 9900])
        // A range past the end of the file is dropped.
        #expect(EmbeddedPreview.jpegRanges(header: header, fileSize: base + 9000) == [base + 6000..<base + 6200])
    }

    @Test func ignoresFilesWithoutIndexAndCutHeaders() {
        #expect(EmbeddedPreview.jpegRanges(header: Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2]), fileSize: 100).isEmpty)
        #expect(EmbeddedPreview.jpegRanges(header: Data("not a jpeg".utf8), fileSize: 100).isEmpty)
        let header = Self.header(little: true)
        for cut in stride(from: 0, to: header.count, by: 7) {
            _ = EmbeddedPreview.jpegRanges(header: header.prefix(cut), fileSize: 20000)  // must not crash
        }
    }

    /// Set NIDGE_SAMPLE_JPEG to a Z5II JPEG to check against the real camera layout.
    @Test func realZ5IIJPEGIfGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["NIDGE_SAMPLE_JPEG"] else { return }
        let file = try Data(contentsOf: URL(fileURLWithPath: path))
        let ranges = EmbeddedPreview.jpegRanges(header: file.prefix(EmbeddedPreview.headerLength), fileSize: file.count)
        #expect(ranges.count == 2)
        for range in ranges { #expect(file[range].prefix(2) == Data([0xFF, 0xD8])) }
    }
}
