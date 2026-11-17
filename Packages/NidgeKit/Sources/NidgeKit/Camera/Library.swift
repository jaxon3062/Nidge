import Foundation

/// One downloadable photo (JPEG, HEIF or NEF) on the card.
public struct PhotoItem: Identifiable, Hashable, Codable, Sendable {
    public var handle: UInt32
    public var filename: String
    public var size: UInt32
    /// Camera-local time as `YYYYMMDDThhmmss`.
    public var captureDate: String
    public var isHEIF: Bool
    /// The Z5II reports NEF as format 0x3000 ("undefined"), so the extension decides.
    public var isRAW: Bool
    /// Handle of the folder the file is in.
    public var folder: UInt32

    public init(handle: UInt32, info: ObjectInfo) {
        self.handle = handle
        filename = info.filename
        size = info.size
        captureDate = info.captureDate
        isHEIF = info.format == PTPObjectFormat.nikonHEIF
        isRAW = info.format == PTPObjectFormat.undefined && info.filename.uppercased().hasSuffix(".NEF")
        folder = info.parent
    }

    /// Same for the JPEG/HEIF and the NEF of one shot: folder plus file name without extension.
    public var shot: String { "\(folder)/\((filename as NSString).deletingPathExtension)" }

    /// Identifies the same shot across sessions and cards; handles are not assumed stable.
    /// Also the thumbnail cache key.
    public var key: String { "\(filename)-\(size)-\(captureDate)" }
    public var id: String { key }
    /// `YYYYMMDD`.
    public var day: String { String(captureDate.prefix(8)) }

    /// Newest first; file name breaks ties within the same second.
    public static func newestFirst(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        (a.captureDate, a.filename) > (b.captureDate, b.filename)
    }
}

/// Splits items already sorted newest first into runs of the same shooting day.
public func groupByDay(_ items: [PhotoItem]) -> [(day: String, items: [PhotoItem])] {
    var groups: [(day: String, items: [PhotoItem])] = []
    for item in items {
        if groups.last?.day == item.day {
            groups[groups.count - 1].items.append(item)
        } else {
            groups.append((item.day, [item]))
        }
    }
    return groups
}

/// What has been imported and what is still queued. Saved as JSON after every change so an
/// import survives the app being killed.
public struct ImportLedger: Codable, Equatable, Sendable {
    public var imported: Set<String> = []
    public var pending: [PhotoItem] = []

    public init() {}

    public init(contentsOf url: URL) {
        self = (try? JSONDecoder().decode(ImportLedger.self, from: Data(contentsOf: url))) ?? ImportLedger()
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Queues items that are not already queued. Imported items can be queued again, for
    /// another size or format. Returns how many were added.
    @discardableResult
    public mutating func enqueue(_ items: [PhotoItem]) -> Int {
        let queued = Set(pending.map(\.key))
        let fresh = items.filter { !queued.contains($0.key) }
        pending += fresh
        return fresh.count
    }

    public mutating func markImported(_ item: PhotoItem) {
        pending.removeAll { $0.key == item.key }
        imported.insert(item.key)
    }
}

extension Camera {
    /// Handles of every JPEG and HEIF on every card, using the format filter the Z5II honours
    /// (one call per format per card, no video). `includeRAW` adds the "undefined" format,
    /// which is where NEF files are. The order is only a fetch-order hint, newest first on the
    /// Z5II; sort by capture date for display.
    public func photoHandles(includeRAW: Bool = false) async throws -> [UInt32] {
        var handles: [UInt32] = []
        // A storage ID whose low 16 bits are zero has no card (seen for the empty slot 2).
        for storage in try await storageIDs() where storage & 0xFFFF != 0 {
            for format in [PTPObjectFormat.jpeg, PTPObjectFormat.nikonHEIF] + (includeRAW ? [PTPObjectFormat.undefined] : []) {
                handles += try await objectHandles(storage: storage, format: format, parent: 0)
            }
        }
        return handles.sorted { $0 & 0x0FFF_FFFF > $1 & 0x0FFF_FFFF }
    }

    /// A client GUID kept between launches, like gphoto2 does. The Z5II accepted a new one
    /// without a prompt; whether it remembers them is unknown.
    public static func persistentGUID(defaults: UserDefaults = .standard) -> Data {
        if let saved = defaults.data(forKey: "guid"), saved.count == 16 { return saved }
        let fresh = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        defaults.set(fresh, forKey: "guid")
        return fresh
    }
}
