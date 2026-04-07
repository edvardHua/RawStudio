import Photos
import UIKit

final class PhotoPair: Identifiable {
    let id: String
    let asset: PHAsset
    let jpgResource: PHAssetResource?
    let rawResource: PHAssetResource
    let captureDate: Date
    let fileName: String
    let rawFormatLabel: String

    /// True when this asset has only RAW, no JPG pair
    var isRawOnly: Bool { jpgResource == nil }

    init(asset: PHAsset, jpgResource: PHAssetResource?, rawResource: PHAssetResource) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.jpgResource = jpgResource
        self.rawResource = rawResource
        self.captureDate = asset.creationDate ?? Date.distantPast
        self.fileName = (jpgResource ?? rawResource).originalFilename
        self.rawFormatLabel = Self.formatLabel(for: rawResource)
    }

    private static func formatLabel(for resource: PHAssetResource) -> String {
        let ext = (resource.originalFilename as NSString).pathExtension.uppercased()
        switch ext {
        case "ARW": return "ARW"
        case "CR2", "CR3": return ext
        case "NEF": return "NEF"
        case "RAF": return "RAF"
        case "ORF": return "ORF"
        case "RW2": return "RW2"
        case "DNG": return "DNG"
        case "PEF": return "PEF"
        default: return "RAW"
        }
    }
}
