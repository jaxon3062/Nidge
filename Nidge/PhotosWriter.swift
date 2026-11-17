import Photos
import UniformTypeIdentifiers

enum PhotosWriter {
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Adds the original file to the library unchanged, so EXIF and capture date survive.
    /// `type` is for files whose extension Photos does not know (the camera's `.HIF`).
    static func save(_ file: URL, filename: String, type: UTType? = nil) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            if let type { options.uniformTypeIdentifier = type.identifier }
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
        }
    }
}
