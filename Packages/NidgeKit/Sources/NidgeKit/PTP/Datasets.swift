import Foundation

/// Codes observed on the Z5II; see docs/protocol/z5ii-ptpip.md.
public enum PTPOperation {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getThumb: UInt16 = 0x100A
    public static let getPartialObject: UInt16 = 0x101B
}

public enum PTPResponse {
    public static let ok: UInt16 = 0x2001
}

public enum PTPObjectFormat {
    /// What the Z5II reports for `.NEF` files.
    public static let undefined: UInt16 = 0x3000
    public static let association: UInt16 = 0x3001
    public static let jpeg: UInt16 = 0x3801
    /// What the Z5II reports for `.HIF` files. Not a standard PTP code.
    public static let nikonHEIF: UInt16 = 0xB200
}

public struct DeviceInfo: Equatable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDescription: String
    public var functionalMode: UInt16
    public var operations: [UInt16]
    public var events: [UInt16]
    public var deviceProperties: [UInt16]
    public var captureFormats: [UInt16]
    public var imageFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(data: Data) throws {
        var r = ByteReader(data)
        standardVersion = try r.u16()
        vendorExtensionID = try r.u32()
        vendorExtensionVersion = try r.u16()
        vendorExtensionDescription = try r.string()
        functionalMode = try r.u16()
        operations = try r.array()
        events = try r.array()
        deviceProperties = try r.array()
        captureFormats = try r.array()
        imageFormats = try r.array()
        manufacturer = try r.string()
        model = try r.string()
        deviceVersion = try r.string()
        serialNumber = try r.string()
    }
}

public struct ObjectInfo: Equatable, Sendable {
    public var storageID: UInt32
    public var format: UInt16
    public var protection: UInt16 = 0
    public var size: UInt32
    public var thumbFormat: UInt16 = 0
    public var thumbSize: UInt32 = 0
    public var thumbWidth: UInt32 = 0
    public var thumbHeight: UInt32 = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var bitDepth: UInt32 = 0
    public var parent: UInt32
    public var associationType: UInt16 = 0
    public var associationDescription: UInt32 = 0
    public var sequenceNumber: UInt32 = 0
    public var filename: String
    /// Camera-local time as `YYYYMMDDThhmmss`, no time zone.
    public var captureDate: String = ""
    public var modificationDate: String = ""
    public var keywords: String = ""

    public init(storageID: UInt32, format: UInt16, size: UInt32, parent: UInt32, filename: String) {
        self.storageID = storageID
        self.format = format
        self.size = size
        self.parent = parent
        self.filename = filename
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        storageID = try r.u32()
        format = try r.u16()
        protection = try r.u16()
        size = try r.u32()
        thumbFormat = try r.u16()
        thumbSize = try r.u32()
        thumbWidth = try r.u32()
        thumbHeight = try r.u32()
        width = try r.u32()
        height = try r.u32()
        bitDepth = try r.u32()
        parent = try r.u32()
        associationType = try r.u16()
        associationDescription = try r.u32()
        sequenceNumber = try r.u32()
        filename = try r.string()
        captureDate = try r.string()
        modificationDate = try r.string()
        keywords = try r.string()
    }

    public func encoded() -> Data {
        var d = Data()
        d.append(le: storageID); d.append(le: format); d.append(le: protection); d.append(le: size)
        d.append(le: thumbFormat); d.append(le: thumbSize); d.append(le: thumbWidth); d.append(le: thumbHeight)
        d.append(le: width); d.append(le: height); d.append(le: bitDepth); d.append(le: parent)
        d.append(le: associationType); d.append(le: associationDescription); d.append(le: sequenceNumber)
        d.append(ptpString: filename); d.append(ptpString: captureDate)
        d.append(ptpString: modificationDate); d.append(ptpString: keywords)
        return d
    }
}

/// Decodes the `uint32 count, uint32[count]` array returned by GetStorageIDs and GetObjectHandles.
public func decodeUInt32Array(_ data: Data) throws -> [UInt32] {
    var r = ByteReader(data)
    return try r.array()
}
