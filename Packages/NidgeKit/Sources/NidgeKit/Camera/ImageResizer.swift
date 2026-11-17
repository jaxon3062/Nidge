import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageResizer {
    public struct Failure: Error {}

    /// The camera's own Medium and Small image sizes, as long side and label. Large is the
    /// original. From the Z5II's image-size property (0x5003): 6048x4032, 4528x3024, 3024x2016.
    /// shortcut: fixed to the Z5II's FX sizes; read property 0x5003 when other bodies are supported
    public static let cameraSizes = [(longSide: 4528, name: "Medium (4528 × 3024)"), (longSide: 3024, name: "Small (3024 × 2016)")]

    /// Writes a copy of the image scaled down so its long side is `longSide` pixels, keeping
    /// its metadata (capture date, camera, lens), next to the original, and returns it. Returns
    /// `file` itself when the image is already that small. JPEG stays JPEG; anything else becomes HEIC.
    public static func resize(_ file: URL, longSide: Int) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw Failure() }
        guard max(width, height) > longSide else { return file }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // bake in the rotation
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure() }

        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        let output = file.deletingPathExtension().appendingPathExtension(isJPEG ? "resized.jpg" : "resized.heic")
        // The pixels are upright now, so the old orientation and size tags would be wrong.
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, (isJPEG ? UTType.jpeg : UTType.heic).identifier as CFString, 1, nil)
        else { throw Failure() }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
        return output
    }
}
