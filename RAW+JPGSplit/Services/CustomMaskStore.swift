import Foundation
import CoreImage
import UIKit

/// Manages persistence of custom user-drawn masks.
/// Masks are stored as grayscale PNG files in the app's documents directory.
final class CustomMaskStore {

    private let fileManager = FileManager.default

    private var masksDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CustomMasks", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func maskURL(for assetID: String, layer: LayerType) -> URL {
        let safeName = assetID.replacingOccurrences(of: "/", with: "_")
        return masksDirectory.appendingPathComponent("\(safeName)_\(layer.rawValue).png")
    }

    /// Save a grayscale mask image for a specific asset and layer.
    func saveMask(_ maskImage: CGImage, for assetID: String, layer: LayerType) {
        let url = maskURL(for: assetID, layer: layer)
        let uiImage = UIImage(cgImage: maskImage)
        if let data = uiImage.pngData() {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Load a mask as CIImage for a specific asset and layer.
    func loadMask(for assetID: String, layer: LayerType) -> CIImage? {
        let url = maskURL(for: assetID, layer: layer)
        guard let data = try? Data(contentsOf: url),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Check if a mask exists for a specific asset and layer.
    func hasMask(for assetID: String, layer: LayerType) -> Bool {
        fileManager.fileExists(atPath: maskURL(for: assetID, layer: layer).path)
    }

    /// Delete a mask for a specific asset and layer.
    func deleteMask(for assetID: String, layer: LayerType) {
        let url = maskURL(for: assetID, layer: layer)
        try? fileManager.removeItem(at: url)
    }

    /// Get all custom layers that have masks for an asset.
    func existingCustomLayers(for assetID: String) -> [LayerType] {
        LayerType.customLayers.filter { hasMask(for: assetID, layer: $0) }
    }

    /// Get the next available custom layer slot.
    func nextAvailableCustomLayer(for assetID: String) -> LayerType? {
        LayerType.customLayers.first { !hasMask(for: assetID, layer: $0) }
    }
}
