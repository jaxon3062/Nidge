import NidgeKit
import Observation
import UIKit
import UniformTypeIdentifiers

enum FormatChoice: String, CaseIterable {
    case processed = "JPEG / HEIF only"
    case raw = "RAW only"
    case both = "RAW + JPEG / HEIF"
}

/// Connection, card contents and the import queue. One camera session is kept open while the
/// app is in the foreground: the camera was seen to drop its Wi-Fi after sessions were closed.
@MainActor
@Observable
final class AppModel {
    private(set) var isConnected = false
    private(set) var isLoadingLibrary = false
    /// Everything loaded from the card, newest first. NEF files are only loaded when asked for.
    private(set) var items: [PhotoItem] = []
    private var loadedRAW = false

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
    private static let thumbnails = URL.cachesDirectory.appendingPathComponent("thumbnails")
    private static let downloads = URL.cachesDirectory.appendingPathComponent("downloads")

    init() {
        for directory in [Self.support, Self.thumbnails, Self.downloads] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        ledger = ImportLedger(contentsOf: Self.ledgerURL)
        batchTotal = ledger.pending.count
    }

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
            try await loadLibrary(camera)
            var idleSeconds = 0
            while !Task.isCancelled {
                if let next = ledger.pending.first {
                    try await importItem(next, from: camera)
                    idleSeconds = 0
                } else if format != .processed, !loadedRAW {
                    try await loadLibrary(camera)  // RAW was switched on after the card was read
                } else {
                    batchTotal = 0
                    updateIdleTimer()
                    try await Task.sleep(for: .seconds(1))
                    idleSeconds += 1
                    // A poll every 5 s kept a session alive for 60 s on the camera, and notices a lost one.
                    if idleSeconds % 5 == 0 { _ = try await camera.storageIDs() }
                }
            }
        } catch {
            // Not connected or connection lost; start() retries.
        }
    }

    private func loadLibrary(_ camera: Camera) async throws {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        let includeRAW = format != .processed
        let handles = try await camera.photoHandles(includeRAW: includeRAW)
        // After a reconnect only new shots need their details fetched.
        let present = Set(handles)
        items.removeAll { !present.contains($0.handle) }
        let known = Set(items.map(\.handle))
        var fresh: [PhotoItem] = []
        for handle in handles where !known.contains(handle) {
            let info = try await camera.objectInfo(handle)
            let item = PhotoItem(handle: handle, info: info)
            // The "undefined" format can hold things other than NEF; skip those.
            if info.format != PTPObjectFormat.undefined || item.isRAW { fresh.append(item) }
            if fresh.count == 24 { merge(&fresh) }  // show progress while a full card loads
        }
        merge(&fresh)
        loadedRAW = includeRAW
    }

    private func merge(_ fresh: inout [PhotoItem]) {
        items = (items + fresh).sorted(by: PhotoItem.newestFirst)
        fresh = []
    }

    // MARK: Thumbnails

    /// The camera's thumbnail, from the disk cache when possible.
    func thumbnail(for item: PhotoItem) async -> UIImage? {
        let file = Self.thumbnails.appendingPathComponent(item.key + ".jpg")
        if let cached = UIImage(contentsOfFile: file.path) { return cached }
        guard let camera, let data = try? await camera.thumbnail(item.handle), let image = UIImage(data: data) else {
            return nil
        }
        try? data.write(to: file, options: .atomic)
        return image
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
