import Foundation

/// Finds the reduced copies a camera JPEG carries in its Multi-Picture (MPF) index, so a
/// viewer can read just those bytes instead of the whole file. A Z5II JPEG has a 640x424 and
/// a 1620x1080 copy at the end of the file, listed in the first ~100 KB.
public enum EmbeddedPreview {
    /// Enough of the start of the file to reach the MPF index on a Z5II JPEG (seen at ~99 KB).
    public static let headerLength = 192 * 1024

    /// Absolute byte ranges of the embedded images other than the primary one, smallest first.
    /// Empty when the header has no MPF index. Ranges outside `fileSize` are dropped.
    public static func jpegRanges(header: Data, fileSize: Int) -> [Range<Int>] {
        let d = [UInt8](header)
        func be16(_ i: Int) -> Int? { i + 2 <= d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : nil }
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return [] }
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA, let length = be16(i + 2) {
            let body = i + 4
            if d[i + 1] == 0xE2, body + 4 <= d.count, Array(d[body..<body + 4]) == Array("MPF\0".utf8) {
                return mpfRanges(d, base: body + 4, fileSize: fileSize)
            }
            i += 2 + length
        }
        return []
    }

    private static func mpfRanges(_ d: [UInt8], base: Int, fileSize: Int) -> [Range<Int>] {
        guard base + 8 <= d.count else { return [] }
        let little = d[base] == 0x49  // "II"
        func u(_ offset: Int, _ size: Int) -> Int? {
            let i = base + offset
            guard offset >= 0, i + size <= d.count else { return nil }
            let bytes = d[i..<i + size]
            return (little ? bytes.reversed() : Array(bytes)).reduce(0) { $0 << 8 | Int($1) }
        }
        guard let ifd = u(4, 4), let count = u(ifd, 2) else { return [] }
        for tag in 0..<count {
            let entry = ifd + 2 + 12 * tag
            guard u(entry, 2) == 0xB002, let bytes = u(entry + 4, 4), let table = u(entry + 8, 4) else { continue }
            var ranges: [Range<Int>] = []
            for image in 0..<bytes / 16 {
                guard let size = u(table + 16 * image + 4, 4), let offset = u(table + 16 * image + 8, 4),
                      offset != 0, size > 0  // offset 0 is the primary image
                else { continue }
                let start = base + offset
                if start + size <= fileSize { ranges.append(start..<start + size) }
            }
            return ranges.sorted { $0.count < $1.count }
        }
        return []
    }
}
