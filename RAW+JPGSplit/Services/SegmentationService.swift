import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Generates and caches segmentation masks using Vision framework.
@Observable
final class SegmentationService {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Cached masks — @Observable tracks changes, triggers UI updates
    var cachedPersonMask: CIImage?
    var cachedSkinMask: CIImage?
    var cachedForegroundMask: CIImage?
    var cachedBackgroundMask: CIImage?
    private var cacheID: String = ""
    private var sourceImageForSkin: CIImage?  // Keep source for skin detection

    /// Maximum long-edge dimension for Vision input. Smaller = faster.
    private static let maxVisionDimension: CGFloat = 1024

    /// Generate all needed masks from a CIImage. Normalizes extent, scales down,
    /// forces 8-bit sRGB output, then runs Vision on a background thread.
    func generateMasks(for image: CIImage, identifier: String) async {
        guard cacheID != identifier else { return }
        cacheID = identifier

        // Reset masks before generating new ones
        cachedPersonMask = nil
        cachedSkinMask = nil
        cachedForegroundMask = nil
        cachedBackgroundMask = nil

        // 1. Normalize extent origin to (0,0)
        let normalized: CIImage
        if image.extent.origin != .zero {
            normalized = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        } else {
            normalized = image
        }

        // 2. Scale down for performance
        let longEdge = max(normalized.extent.width, normalized.extent.height)
        let scaled: CIImage
        if longEdge > Self.maxVisionDimension {
            let s = Self.maxVisionDimension / longEdge
            scaled = normalized.transformed(by: CGAffineTransform(scaleX: s, y: s))
        } else {
            scaled = normalized
        }

        // 3. Force 8-bit sRGB CGImage for Vision compatibility
        //    CIRAWFilter may produce HDR/float16 CGImages that Vision doesn't support
        guard let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = ciContext.createCGImage(
                  scaled,
                  from: scaled.extent,
                  format: .RGBA8,
                  colorSpace: srgbColorSpace
              ) else {
            return
        }

        // 4. Run Vision on background thread
        let results = await Task.detached(priority: .userInitiated) {
            Self.runVisionRequests(on: cgImage)
        }.value

        cachedPersonMask = results.personMask
        cachedForegroundMask = results.foregroundMask

        if let fg = cachedForegroundMask {
            cachedBackgroundMask = fg.applyingFilter("CIColorInvert")
        } else {
            cachedBackgroundMask = nil
        }

        // Generate skin mask: person mask AND YCbCr skin color detection
        if let personMask = cachedPersonMask {
            cachedSkinMask = Self.generateSkinMask(
                from: scaled,
                personMask: personMask,
                ciContext: ciContext
            )
        } else {
            cachedSkinMask = nil
        }
    }

    /// Get the mask for a specific layer type, scaled and aligned to target image extent.
    func mask(for layer: LayerType, imageExtent: CGRect) -> CIImage? {
        let raw: CIImage?
        switch layer {
        case .global: return nil
        case .person: raw = cachedPersonMask
        case .skin: raw = cachedSkinMask
        case .foreground: raw = cachedForegroundMask
        case .background: raw = cachedBackgroundMask
        }

        guard let mask = raw else { return nil }

        // Scale mask to match image dimensions
        let scaleX = imageExtent.width / mask.extent.width
        let scaleY = imageExtent.height / mask.extent.height
        var scaled = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Align mask origin to match the image extent origin
        let offsetX = imageExtent.origin.x - scaled.extent.origin.x
        let offsetY = imageExtent.origin.y - scaled.extent.origin.y
        if offsetX != 0 || offsetY != 0 {
            scaled = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        }

        return scaled
    }

    /// Check if a specific layer has detectable content
    func hasContent(for layer: LayerType) -> Bool {
        switch layer {
        case .global: return true
        case .person: return cachedPersonMask != nil
        case .skin: return cachedSkinMask != nil
        case .foreground: return cachedForegroundMask != nil
        case .background: return cachedBackgroundMask != nil
        }
    }

    /// Clear all cached masks
    func clearCache() {
        cachedPersonMask = nil
        cachedSkinMask = nil
        cachedForegroundMask = nil
        cachedBackgroundMask = nil
        cacheID = ""
    }

    // MARK: - Private: Vision (runs off main thread)

    private struct VisionResults: Sendable {
        let personMask: CIImage?
        let foregroundMask: CIImage?
    }

    nonisolated private static func runVisionRequests(on cgImage: CGImage) -> VisionResults {
        let personMask = generatePersonMask(from: cgImage)
        let foregroundMask = generateForegroundMask(from: cgImage)
        return VisionResults(personMask: personMask, foregroundMask: foregroundMask)
    }

    nonisolated private static func generatePersonMask(from cgImage: CGImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else {
                print("[SegmentationService] Person segmentation: no results")
                return nil
            }
            return CIImage(cvPixelBuffer: result.pixelBuffer)
        } catch {
            print("[SegmentationService] Person segmentation error: \(error)")
            return nil
        }
    }

    nonisolated private static func generateForegroundMask(from cgImage: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else {
                print("[SegmentationService] Foreground segmentation: no results")
                return nil
            }
            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
            return CIImage(cvPixelBuffer: maskBuffer)
        } catch {
            print("[SegmentationService] Foreground segmentation error: \(error)")
            return nil
        }
    }

    // MARK: - Skin Mask Generation

    /// Generate skin mask by intersecting person mask with YCbCr skin color detection.
    /// Detects all visible skin (face, hands, arms, legs) while excluding clothing.
    nonisolated private static func generateSkinMask(
        from image: CIImage,
        personMask: CIImage,
        ciContext: CIContext
    ) -> CIImage? {
        // 1. Detect skin-colored pixels using YCbCr thresholding
        //    Skin tones in YCbCr: Y > 80/255, Cb in [77,127]/255, Cr in [133,173]/255
        let skinColorMask = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),  // Y
            "inputGVector": CIVector(x: -0.169, y: -0.331, z: 0.500, w: 0), // Cb (offset separately)
            "inputBVector": CIVector(x: 0.500, y: -0.419, z: -0.081, w: 0), // Cr (offset separately)
            "inputBiasVector": CIVector(x: 0, y: 0.5, z: 0.5, w: 0)
        ])

        // Use CIColorClamp + threshold approach:
        // We need to create a binary mask from YCbCr ranges.
        // Simpler approach: render to CGImage, threshold in CPU, create mask CIImage.
        guard let skinCGImage = ciContext.createCGImage(image, from: image.extent,
                                                         format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            return nil
        }

        let width = skinCGImage.width
        let height = skinCGImage.height
        let bytesPerRow = width * 4

        guard let imageData = skinCGImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(imageData) else { return nil }

        // Create grayscale mask buffer
        var maskData = Data(count: width * height)
        maskData.withUnsafeMutableBytes { maskPtr in
            guard let maskBytes = maskPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let r = Float(ptr[offset]) / 255.0
                    let g = Float(ptr[offset + 1]) / 255.0
                    let b = Float(ptr[offset + 2]) / 255.0

                    // RGB to YCbCr
                    let yLuma = 0.299 * r + 0.587 * g + 0.114 * b
                    let cb = 0.5 + (-0.169 * r - 0.331 * g + 0.500 * b)
                    let cr = 0.5 + (0.500 * r - 0.419 * g - 0.081 * b)

                    // Skin tone thresholds (normalized 0-1)
                    let isSkin = yLuma > 0.31 &&
                                 cb > 0.30 && cb < 0.53 &&
                                 cr > 0.52 && cr < 0.72

                    maskBytes[y * width + x] = isSkin ? 255 : 0
                }
            }
        }

        // Create CIImage from grayscale mask
        guard let provider = CGDataProvider(data: maskData as CFData),
              let grayCGImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpace(name: CGColorSpace.linearGray)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }

        let colorSkinMask = CIImage(cgImage: grayCGImage)

        // 2. Scale person mask to match color skin mask dimensions
        let scaleX = colorSkinMask.extent.width / personMask.extent.width
        let scaleY = colorSkinMask.extent.height / personMask.extent.height
        let scaledPersonMask = personMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // 3. Intersect: skinMask = personMask AND colorSkinMask
        //    Use CIMultiplyCompositing to combine (both are grayscale, multiply = AND)
        let intersected = colorSkinMask.applyingFilter("CIMultiplyCompositing", parameters: [
            "inputBackgroundImage": scaledPersonMask
        ])

        // 4. Soften edges with Gaussian blur
        let softened = intersected.applyingFilter("CIGaussianBlur", parameters: [
            "inputRadius": 2.0
        ])

        // Clamp to remove infinite extent from blur
        return softened.cropped(to: colorSkinMask.extent)
    }

    // MARK: - Static: Apply Layer Edits

    /// Apply layer edits to an image using a mask
    static func applyLayerEdits(
        _ params: LayerEditParams,
        to image: CIImage,
        mask: CIImage
    ) -> CIImage {
        guard params.isModified else { return image }

        var edited = image

        if params.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = edited
            filter.ev = params.exposure
            if let output = filter.outputImage { edited = output }
        }

        if params.brightness != 0 || params.contrast != 1.0 || params.saturation != 1.0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = edited
            filter.brightness = params.brightness
            filter.contrast = params.contrast
            filter.saturation = params.saturation
            if let output = filter.outputImage { edited = output }
        }

        if params.temperature != 6500 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = edited
            filter.neutral = CIVector(x: CGFloat(params.temperature), y: 0)
            if let output = filter.outputImage { edited = output }
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = edited
        blend.backgroundImage = image
        blend.maskImage = mask

        return blend.outputImage ?? image
    }
}
