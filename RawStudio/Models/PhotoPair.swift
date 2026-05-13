import Photos
import UIKit

enum PhotoKind {
    case rawJpgPair    // 同时有 raw 和 非 raw 资源
    case rawOnly       // 仅 raw
    case jpgOnly       // 仅 非 raw（JPG / HEIC / PNG / TIFF…）
}

final class PhotoPair: Identifiable {
    let id: String
    let asset: PHAsset
    let jpgResource: PHAssetResource?
    let rawResource: PHAssetResource?
    let captureDate: Date
    let fileName: String
    let formatLabel: String

    var kind: PhotoKind {
        switch (jpgResource, rawResource) {
        case (.some, .some): return .rawJpgPair
        case (nil, .some):   return .rawOnly
        case (.some, nil):   return .jpgOnly
        case (nil, nil):     preconditionFailure("PhotoPair must have at least one resource")
        }
    }

    init(asset: PHAsset, jpgResource: PHAssetResource?, rawResource: PHAssetResource?) {
        precondition(jpgResource != nil || rawResource != nil,
                     "PhotoPair must have at least one resource")
        self.id = asset.localIdentifier
        self.asset = asset
        self.jpgResource = jpgResource
        self.rawResource = rawResource
        self.captureDate = asset.creationDate ?? Date.distantPast
        self.fileName = (jpgResource ?? rawResource)!.originalFilename
        // formatLabel 优先 raw（pair / raw-only 都展示 RAW 扩展名，与今天一致）；
        // jpg-only 时用 jpg 扩展名（HEIC/JPG/PNG…）
        self.formatLabel = Self.formatLabel(for: (rawResource ?? jpgResource)!)
    }

    private static func formatLabel(for resource: PHAssetResource) -> String {
        let ext = (resource.originalFilename as NSString).pathExtension.uppercased()
        switch ext {
        // RAW 格式
        case "ARW", "CR2", "CR3", "NEF", "RAF", "ORF", "RW2", "DNG", "PEF":
            return ext
        // 常见非 RAW 主图
        case "JPG", "JPEG":  return "JPG"
        case "HEIC", "HEIF": return "HEIC"
        case "PNG":          return "PNG"
        case "TIFF", "TIF":  return "TIFF"
        default:             return ext.isEmpty ? "PHOTO" : ext
        }
    }
}
