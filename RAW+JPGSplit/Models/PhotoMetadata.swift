import Foundation
import ImageIO

struct PhotoMetadata {
    let fileSize: Int64          // bytes
    let iso: Int?
    let shutterSpeed: String?    // e.g. "1/250"
    let aperture: Double?        // e.g. 2.8
    let focalLength: Double?     // e.g. 50.0
    let cameraMake: String?      // e.g. "SONY"
    let cameraModel: String?     // e.g. "ILCE-7M3"
    let dimensions: String       // e.g. "6000 × 4000"

    var fileSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    static func from(data: Data, fileSize: Int64, pixelWidth: Int, pixelHeight: Int) -> PhotoMetadata {
        var iso: Int?
        var shutterSpeed: String?
        var aperture: Double?
        var focalLength: Double?
        var cameraMake: String?
        var cameraModel: String?

        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {

            // EXIF
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
                   let firstISO = isoValues.first {
                    iso = firstISO
                }
                if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                    if exposure >= 1.0 {
                        shutterSpeed = String(format: "%.1f\"", exposure)
                    } else {
                        let denominator = Int(round(1.0 / exposure))
                        shutterSpeed = "1/\(denominator)"
                    }
                }
                if let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double {
                    aperture = fNumber
                }
                if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                    focalLength = fl
                }
            }

            // TIFF (camera make/model)
            if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
                cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
            }
        }

        let dimensions = "\(pixelWidth) × \(pixelHeight)"

        return PhotoMetadata(
            fileSize: fileSize,
            iso: iso,
            shutterSpeed: shutterSpeed,
            aperture: aperture,
            focalLength: focalLength,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            dimensions: dimensions
        )
    }
}
