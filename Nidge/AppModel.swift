import NidgeKit
import Observation
import UIKit
import UniformTypeIdentifiers

import ImageIO

enum FormatChoice: String, CaseIterable {
    case processed = "JPEG / HEIF only"
    case raw = "RAW only"
    case both = "RAW + JPEG / HEIF"

    var codes: [UInt16] {
        switch self {
        case .processed: [PTPObjectFormat.jpeg, PTPObjectFormat.nikonHEIF]
        case .raw: [PTPObjectFormat.undefined]
        case .both: [PTPObjectFormat.jpeg, PTPObjectFormat.nikonHEIF, PTPObjectFormat.undefined]
        }
    }

    func includes(_ item: PhotoItem) -> Bool {
        switch self {
        case .processed: !item.isRAW
        case .raw: item.isRAW
        case .both: true
        }
    }
}

/// Connection, card contents and the import queue. One camera session is kept open while the
/// app is in the foreground: the camera was seen to drop its Wi-Fi after sessions were closed.
@MainActor
@Observable
final class AppModel {
    private(set) var isConnected = false
    /// True while photo details are being read from the card.
    private(set) var isLoadingLibrary = false
    /// True while some photos on the card have not had their details read yet.
    private(set) var hasMore = false
    /// Every file on the card in the current format, newest first. Cheap: one call per format.
    private(set) var handles: [UInt32] = []
    /// Details read so far, newest first. Only photos near what is on screen are read.
    private(set) var items: [PhotoItem] = []
    /// How far down `handles` to read details and thumbnails: what has been on screen plus
    /// two screens (36 cells on an iPhone 13 Pro).
    @ObservationIgnored private var wanted = 54
    @ObservationIgnored private var handleIndex: [UInt32: Int] = [:]
    static let lookahead = 36
    /// JPEG/HEIF handles by their low 28 bits, to find a RAW file's twin for the viewer.
    @ObservationIgnored private var companions: [UInt32: UInt32] = [:]
    @ObservationIgnored private var twins: [String: PhotoItem] = [:]
    /// Set while the viewer is open: reading the listing waits so the photo on screen loads first.
    @ObservationIgnored var viewerOpen = false

    var format = FormatChoice(rawValue: UserDefaults.standard.string(forKey: "format") ?? "") ?? .processed {
        didSet {
            UserDefaults.standard.set(format.rawValue, forKey: "format")
            selection = []
        }
    }
    /// Long side in pixels that JPEG and HEIF imports are shrunk to; 0 keeps the original. RAW is never resized.
    var maxLongSide = UserDefaults.standard.integer(forKey: "maxLongSide") {
        didSet { UserDefaults.standard.set(maxLongSide, forKey: "maxLongSide") }
    }

    /// What the grid shows. With RAW + JPEG a shot appears once, as its JPEG or HEIF; its NEF
    /// is imported along with it. A shot that only has a NEF shows the NEF.
    var visibleItems: [PhotoItem] {
        switch format {
        case .processed: return items.filter { !$0.isRAW }
        case .raw: return items.filter(\.isRAW)
        case .both:
            let processed = Set(items.lazy.filter { !$0.isRAW }.map(\.shot))
            return items.filter { !$0.isRAW || !processed.contains($0.shot) }
        }
    }
    var selection: Set<String> = []
    private(set) var ledger: ImportLedger
    /// Size of the batch being imported; 0 when idle.
    private(set) var batchTotal = 0
    private(set) var currentFile: String?
    private(set) var currentFraction = 0.0
    /// File name to reason, for files that could not be imported.
    private(set) var failures: [String: String] = [:]

    var batchDone: Int { batchTotal - ledger.pending.count }
    var isImporting: Bool { !ledger.pending.isEmpty }

    private var camera: Camera?
    private var loop: Task<Void, Never>?
    private var currentImport: Task<Void, Error>?

    // `-cameraHost 127.0.0.1 -cameraPort 15741` as launch arguments point the app at `nidge-cli mock`.
    private let host = UserDefaults.standard.string(forKey: "cameraHost") ?? "192.168.1.1"
    private let port = UInt16(exactly: UserDefaults.standard.integer(forKey: "cameraPort")).flatMap { $0 == 0 ? nil : $0 } ?? 15740

    private static let support = URL.applicationSupportDirectory
    private static let ledgerURL = support.appendingPathComponent("ledger.json")
    private static let itemsURL = URL.cachesDirectory.appendingPathComponent("items.json")
    private static let thumbnails = URL.cachesDirectory.appendingPathComponent("thumbnails")
    private static let previews = URL.cachesDirectory.appendingPathComponent("previews")
    private static let downloads = URL.cachesDirectory.appendingPathComponent("downloads")

    init() {
        for directory in [Self.support, Self.thumbnails, Self.previews, Self.downloads] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        ledger = ImportLedger(contentsOf: Self.ledgerURL)
        batchTotal = ledger.pending.count
        // The last card's details, so the grid appears at once and a reconnect only reads new shots.
        // shortcut: trusted while the handles match; a different card with identical handles would show stale entries until imported (imports re-check)
        items = (try? JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: Self.itemsURL))) ?? []
        // Partial previews from older builds.
        for file in (try? FileManager.default.contentsOfDirectory(at: Self.previews, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "part" && !file.lastPathComponent.contains("-full.") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Called as a photo appears on screen, to read details for the next two screens.
    func noteVisible(_ item: PhotoItem) {
        if let index = handleIndex[item.handle] { wanted = max(wanted, index + 1 + Self.lookahead) }
    }

    /// Called when the end of the loaded photos comes on screen.
    func noteEndVisible() {
        wanted = max(wanted, items.count + Self.lookahead)
    }

    /// Thumbnail and preview requests waiting on the camera. The card listing pauses while
    /// there are any, so what is on screen loads first.
    @ObservationIgnored private var visibleRequests = 0

    // MARK: Connection

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runSession()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        currentImport?.cancel()
        camera?.session.cancel()
    }

    /// Connects, loads the card and serves the import queue until the connection fails.
    private func runSession() async {
        do {
            let camera = try await Camera.connect(host: host, port: port, guid: Camera.persistentGUID(),
                                                  name: "Nidge", attempts: 1)
            self.camera = camera
            isConnected = true
            defer {
                camera.session.cancel()
                self.camera = nil
                isConnected = false
                isLoadingLibrary = false
                updateIdleTimer()
            }
            // Reading the card and importing share the session; transactions take turns.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.readCard(camera) }
                group.addTask { try await self.serveQueue(camera) }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            // Not connected or connection lost; start() retries.
        }
    }

    private func serveQueue(_ camera: Camera) async throws {
        var idleSeconds = 0
        while !Task.isCancelled {
            if let next = ledger.pending.first {
                try await importItem(next, from: camera)
                idleSeconds = 0
            } else {
                batchTotal = 0
                updateIdleTimer()
                try await Task.sleep(for: .seconds(1))
                idleSeconds += 1
                // A poll every 5 s kept a session alive for 60 s on the camera, and notices a lost one.
                if idleSeconds % 5 == 0 { _ = try await camera.storageIDs() }
            }
        }
    }

    /// Lists the card for the current format, then reads details and thumbnails in order,
    /// newest first, only as far as `wanted`. Pauses while anything on screen is loading.
    private func readCard(_ camera: Camera) async throws {
        var listedFormat: FormatChoice?
        var known = Set<UInt32>()
        var cursor = 0
        while !Task.isCancelled {
            if listedFormat != format {
                listedFormat = format
                isLoadingLibrary = true
                handles = try await camera.photoHandles(formats: format.codes)
                handleIndex = Dictionary(handles.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                if format != .processed {
                    let processed = try await camera.photoHandles(formats: FormatChoice.processed.codes)
                    companions = Dictionary(processed.map { ($0 & 0x0FFF_FFFF, $0) }, uniquingKeysWith: { a, _ in a })
                }
                // Drop photos no longer on the card; keep those of other formats for when they are switched back.
                items.removeAll { handleIndex[$0.handle] == nil && format.includes($0) }
                known = Set(items.map(\.handle))
                cursor = 0
                saveItems()
            }
            while cursor < handles.count, known.contains(handles[cursor]) { cursor += 1 }
            let busy = visibleRequests > 0 || viewerOpen
            let reading = cursor < min(wanted, handles.count)
            // Assigning redraws even when the value is unchanged.
            if isLoadingLibrary != reading { isLoadingLibrary = reading }
            if hasMore != (cursor < handles.count) { hasMore = cursor < handles.count }
            guard reading, !busy else {
                if !reading { saveItems() }
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            let handle = handles[cursor]
            known.insert(handle)
            let info: ObjectInfo
            do {
                info = try await camera.objectInfo(handle)
            } catch PTPError.response {
                continue  // deleted on the camera since the listing
            }
            let item = PhotoItem(handle: handle, info: info)
            // The "undefined" format can hold things other than NEF; skip those.
            guard info.format != PTPObjectFormat.undefined || item.isRAW else { continue }
            let index = items.firstIndex { PhotoItem.newestFirst(item, $0) } ?? items.endIndex
            items.insert(item, at: index)
            // Thumbnail now too, so scrolling into the next screens finds it cached.
            _ = await thumbnail(for: item, counted: false)
        }
    }

    @ObservationIgnored private var itemsSaved = 0
    private func saveItems() {
        guard items.count != itemsSaved else { return }
        itemsSaved = items.count
        try? JSONEncoder().encode(items).write(to: Self.itemsURL, options: .atomic)
    }

    // MARK: Thumbnails

    /// The camera's thumbnail, from the disk cache when possible. `counted` requests pause the
    /// card reading; the reader's own prefetch is not counted.
    func thumbnail(for item: PhotoItem, counted: Bool = true) async -> UIImage? {
        let file = Self.thumbnails.appendingPathComponent(item.key + ".jpg")
        if let cached = UIImage(contentsOfFile: file.path) { return cached }
        guard let camera else { return nil }
        if counted { visibleRequests += 1 }
        defer { if counted { visibleRequests -= 1 } }
        guard let data = try? await camera.thumbnail(item.handle), let image = UIImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// The viewer's first, quick image: the 640 px copy inside a JPEG, or the 320 px one in the
    /// first 192 KB of a HEIF or NEF. Nil when the file has none; then `preview` is next.
    func quickPreview(for item: PhotoItem) async -> UIImage? {
        let file = Self.previews.appendingPathComponent(item.key + "-small.jpg")
        if let cached = UIImage(contentsOfFile: file.path) { return cached }
        if let full = UIImage(contentsOfFile: Self.previews.appendingPathComponent(item.key + ".jpg").path) { return full }
        guard let camera else { return nil }
        visibleRequests += 1
        defer { visibleRequests -= 1 }
        do {
            let header = try await camera.read(item.handle, offset: 0, length: min(UInt32(EmbeddedPreview.headerLength), item.size))
            let image: UIImage?
            if let small = EmbeddedPreview.jpegRanges(header: header, fileSize: Int(item.size)).first {
                image = Self.oriented(try await camera.read(item.handle, offset: UInt32(small.lowerBound), length: UInt32(small.count)), like: header)
            } else {
                image = Self.embeddedThumbnail(header)
            }
            if let data = image?.jpegData(compressionQuality: 0.85) { try? data.write(to: file, options: .atomic) }
            return image
        } catch {
            return nil
        }
    }

    /// The viewer's sharp image. JPEG: the 1620 px copy inside the file (under 1 MB). HEIF:
    /// the whole original (about 2.7 MB) shrunk. RAW: nil, the quick image is all there is.
    func preview(for item: PhotoItem) async -> UIImage? {
        let file = Self.previews.appendingPathComponent(item.key + ".jpg")
        if let cached = UIImage(contentsOfFile: file.path) { return cached }
        guard let camera, !item.isRAW else { return nil }
        visibleRequests += 1
        defer { visibleRequests -= 1 }
        do {
            let image: UIImage?
            if !item.isHEIF {
                let header = try await camera.read(item.handle, offset: 0, length: min(UInt32(EmbeddedPreview.headerLength), item.size))
                guard let large = EmbeddedPreview.jpegRanges(header: header, fileSize: Int(item.size)).last else { return nil }
                image = Self.oriented(try await camera.read(item.handle, offset: UInt32(large.lowerBound), length: UInt32(large.count)), like: header)
            } else {
                // Kept: it is also the full-resolution image for zooming in.
                let original = Self.fullFile(item)
                if !FileManager.default.fileExists(atPath: original.path) {
                    try await camera.download(item.handle, size: item.size, to: original)
                }
                image = try await Task.detached {
                    let shrunk = try ImageResizer.resize(original, longSide: 2560)
                    defer { if shrunk != original { try? FileManager.default.removeItem(at: shrunk) } }
                    return UIImage(contentsOfFile: shrunk.path)
                }.value
            }
            if let data = image?.jpegData(compressionQuality: 0.85) { try? data.write(to: file, options: .atomic) }
            return image
        } catch {
            return nil
        }
    }

    /// What the viewer shows for a photo: for a RAW file, its JPEG or HEIF twin when the card
    /// has one (a fraction of the size, and decodable), else the photo itself.
    func viewable(_ item: PhotoItem) async -> PhotoItem {
        guard item.isRAW else { return item }
        if let twin = twins[item.key] ?? items.first(where: { !$0.isRAW && $0.shot == item.shot }) {
            twins[item.key] = twin
            return twin
        }
        guard let camera, let handle = companions[item.handle & 0x0FFF_FFFF] else { return item }
        visibleRequests += 1
        defer { visibleRequests -= 1 }
        guard let info = try? await camera.objectInfo(handle) else { return item }
        let twin = PhotoItem(handle: handle, info: info)
        // Shared low bits are only a pattern seen on the Z5II; trust it only when the names match.
        guard twin.shot == item.shot else { return item }
        twins[item.key] = twin
        return twin
    }

    /// The full-resolution photo, for zooming in past the 1620 px preview. Downloads the
    /// original once (about 10 MB for a JPEG, 2.7 MB for a HEIF). Not for RAW.
    // shortcut: originals stay in Caches until iOS purges it; add a size cap if that becomes a problem
    func original(for item: PhotoItem) async -> UIImage? {
        guard !item.isRAW else { return nil }
        let file = Self.fullFile(item)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let camera else { return nil }
            visibleRequests += 1
            defer { visibleRequests -= 1 }
            do {
                try await camera.download(item.handle, size: item.size, to: file)
            } catch {
                return nil  // the .part file lets the next zoom resume
            }
        }
        return UIImage(contentsOfFile: file.path)
    }

    private static func fullFile(_ item: PhotoItem) -> URL {
        previews.appendingPathComponent(item.key + "-full." + (item.isHEIF ? "heic" : "jpg"))
    }

    /// Decodes an embedded JPEG, taking the rotation from the main image when it has none of its own.
    private static func oriented(_ data: Data, like header: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        func orientation(_ source: CGImageSource?) -> UInt32? {
            source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyOrientation] as? UInt32
        }
        let raw = orientation(source) ?? orientation(CGImageSourceCreateWithData(header as CFData, nil)) ?? 1
        let map: [UInt32: UIImage.Orientation] = [1: .up, 2: .upMirrored, 3: .down, 4: .downMirrored,
                                                  5: .leftMirrored, 6: .right, 7: .rightMirrored, 8: .left]
        return UIImage(cgImage: image, scale: 1, orientation: map[raw] ?? .up)
    }

    /// The thumbnail ImageIO finds in the start of a HEIF or NEF file.
    private static func embeddedThumbnail(_ header: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(header as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1620]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    // MARK: Import queue

    func importSelection() {
        let alreadyRunning = isImporting
        var chosen = visibleItems.filter { selection.contains($0.key) }
        if format == .both {
            // Each selected shot brings its NEF along as a separate photo.
            let shots = Set(chosen.map(\.shot))
            chosen += items.filter { $0.isRAW && shots.contains($0.shot) && !selection.contains($0.key) }
        }
        let added = ledger.enqueue(chosen)
        batchTotal = (alreadyRunning ? batchTotal : 0) + added
        selection = []
        failures = [:]
        saveLedger()
        updateIdleTimer()
    }

    func cancelImport() {
        ledger.pending = []
        batchTotal = 0
        currentFile = nil
        saveLedger()
        currentImport?.cancel()
    }

    func isImported(_ item: PhotoItem) -> Bool { ledger.imported.contains(item.key) }
    func isQueued(_ item: PhotoItem) -> Bool { ledger.pending.contains { $0.key == item.key } }

    /// Imports one file. Throws only for connection problems, which end the session so the
    /// file is retried after reconnecting; anything else is recorded as a failure and skipped.
    private func importItem(_ item: PhotoItem, from camera: Camera) async throws {
        currentFile = item.filename
        currentFraction = 0
        defer { currentFile = nil }
        let directory = Self.downloads.appendingPathComponent(item.key)
        let file = directory.appendingPathComponent(item.filename)
        let task = Task {
            // The queue may be from an earlier launch: make sure the handle is still this photo.
            guard PhotoItem(handle: item.handle, info: try await camera.objectInfo(item.handle)).key == item.key else {
                throw ImportError.notOnCard
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await camera.download(item.handle, size: item.size, to: file) { bytes in
                Task { @MainActor in self.currentFraction = Double(bytes) / Double(max(item.size, 1)) }
            }
            do {
                // shortcut: uses the size chosen when the file arrives, not when it was queued; store it per item if that matters
                let limit = maxLongSide
                if limit > 0, !item.isRAW {
                    let resized = try await Task.detached { try ImageResizer.resize(file, longSide: limit) }.value
                    if resized != file {
                        let name = (item.filename as NSString).deletingPathExtension + "." + (item.isHEIF ? "HEIC" : "JPG")
                        return try await PhotosWriter.save(resized, filename: name)
                    }
                }
                // Photos does not know the camera's .HIF extension.
                try await PhotosWriter.save(file, filename: item.filename, type: item.isHEIF ? .heif : nil)
            } catch is ImageResizer.Failure {
                throw ImportError.photos("The photo could not be resized.")
            } catch {
                throw ImportError.photos(error.localizedDescription)
            }
        }
        currentImport = task
        do {
            try await task.value
            ledger.markImported(item)
        } catch is CancellationError {
            return  // cancelImport() already emptied the queue; the .part file stays for a later resume
        } catch let error as ImportError {
            fail(item, error.message)
        } catch PTPError.response(let code) {
            fail(item, "The camera refused the file (code \(String(code, radix: 16))).")
        } catch let error as CocoaError {
            fail(item, error.localizedDescription)  // disk full and the like
        } catch {
            throw error
        }
        try? FileManager.default.removeItem(at: directory)
        saveLedger()
    }

    private func fail(_ item: PhotoItem, _ reason: String) {
        failures[item.filename] = reason
        ledger.pending.removeAll { $0.key == item.key }
    }

    private func saveLedger() {
        do {
            try ledger.save(to: Self.ledgerURL)
        } catch {
            failures["Import history"] = "Could not be saved: \(error.localizedDescription)"
        }
    }

    /// A long import must not be cut off by the screen locking, also while it waits for the
    /// camera to come back (background downloads are M3).
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isImporting
    }
}

private enum ImportError: Error {
    case notOnCard
    case photos(String)

    var message: String {
        switch self {
        case .notOnCard: "No longer on the card."
        case .photos(let reason): "Photos did not accept it: \(reason)"
        }
    }
}
