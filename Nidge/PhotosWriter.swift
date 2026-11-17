import Photos
import UniformTypeIdentifiers

enum PhotosWriter {
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Adds the original file to the library unchanged, so EXIF and capture date survive.
    static func save(_ file: URL, filename: String, isHEIF: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            // Photos does not know the camera's .HIF extension.
            if isHEIF { options.uniformTypeIdentifier = UTType.heif.identifier }
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
        }
    }
}
