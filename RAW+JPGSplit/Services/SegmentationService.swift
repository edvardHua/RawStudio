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
    var cachedCustom1Mask: CIImage?
    var cachedCustom2Mask: CIImage?
    var cachedCustom3Mask: CIImage?
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
                from: cgImage,
                personMask: personMask,
                targetWidth: cgImage.width,
                targetHeight: cgImage.height,
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
        case .custom1: raw = cachedCustom1Mask
        case .custom2: raw = cachedCustom2Mask
        case .custom3: raw = cachedCustom3Mask
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
        case .custom1: return cachedCustom1Mask != nil
        case .custom2: return cachedCustom2Mask != nil
        case .custom3: return cachedCustom3Mask != nil
        }
    }

    /// Clear all cached masks
    func clearCache() {
        cachedPersonMask = nil
        cachedSkinMask = nil
        cachedForegroundMask = nil
        cachedBackgroundMask = nil
        cachedCustom1Mask = nil
        cachedCustom2Mask = nil
        cachedCustom3Mask = nil
        cacheID = ""
    }

    /// Inject a custom mask for a specific custom layer
    func setCustomMask(_ mask: CIImage?, for layer: LayerType) {
        switch layer {
        case .custom1: cachedCustom1Mask = mask
        case .custom2: cachedCustom2Mask = mask
        case .custom3: cachedCustom3Mask = mask
        default: break
        }
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

    /// Generate skin mask in a single CPU pass: for each pixel, check if it's
    /// inside the person mask AND has skin-tone color in YCbCr space.
    nonisolated private static func generateSkinMask(
        from cgImage: CGImage,
        personMask: CIImage,
        targetWidth: Int,
        targetHeight: Int,
        ciContext: CIContext
    ) -> CIImage? {
        let width = targetWidth
        let height = targetHeight

        // 1. Render person mask to same-size grayscale CGImage
        let personMaskScaled = personMask.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / personMask.extent.width,
            y: CGFloat(height) / personMask.extent.height
        ))

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let gray = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }

        // Render person mask to grayscale pixel buffer
        let personExtent = CGRect(x: 0, y: 0, width: width, height: height)
        var personPixels = Data(count: width * height)
        personPixels.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            ciContext.render(
                personMaskScaled,
                toBitmap: base,
                rowBytes: width,
                bounds: personExtent,
                format: .L8,
                colorSpace: gray
            )
        }

        // 2. Get image pixel data (already sRGB 8-bit from cgImage)
        let imgBytesPerRow = cgImage.bytesPerRow
        guard let imgDataProvider = cgImage.dataProvider,
              let imgData = imgDataProvider.data,
              let imgPtr = CFDataGetBytePtr(imgData) else { return nil }

        let imgBitsPerPixel = cgImage.bitsPerPixel / 8 // bytes per pixel (3 or 4)

        // 3. Single-pass: check person mask + YCbCr skin color for each pixel
        var maskData = Data(count: width * height)
        maskData.withUnsafeMutableBytes { maskPtr in
            personPixels.withUnsafeBytes { personPtr in
                guard let maskBytes = maskPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let personBytes = personPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                for y in 0..<height {
                    for x in 0..<width {
                        let pixelIdx = y * width + x

                        // Check person mask first (fast reject)
                        let personVal = personBytes[pixelIdx]
                        if personVal < 128 {
                            maskBytes[pixelIdx] = 0
                            continue
                        }

                        // Read RGB from source image
                        let imgOffset = y * imgBytesPerRow + x * imgBitsPerPixel
                        let r = Float(imgPtr[imgOffset]) / 255.0
                        let g = Float(imgPtr[imgOffset + 1]) / 255.0
                        let b = Float(imgPtr[imgOffset + 2]) / 255.0

                        // RGB to YCbCr
                        let yLuma = 0.299 * r + 0.587 * g + 0.114 * b
                        let cb = 0.5 + (-0.169 * r - 0.331 * g + 0.500 * b)
                        let cr = 0.5 + (0.500 * r - 0.419 * g - 0.081 * b)

                        // Skin tone thresholds (wide range for diverse skin tones)
                        let isSkin = yLuma > 0.2 &&
                                     cb > 0.28 && cb < 0.55 &&
                                     cr > 0.50 && cr < 0.75

                        maskBytes[pixelIdx] = isSkin ? 255 : 0
                    }
                }
            }
        }

        // 4. Create grayscale CIImage from mask
        guard let provider = CGDataProvider(data: maskData as CFData),
              let grayCGImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width,
                space: gray,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }

        let skinMask = CIImage(cgImage: grayCGImage)

        // 5. Soften edges with Gaussian blur
        let softened = skinMask.applyingFilter("CIGaussianBlur", parameters: [
            "inputRadius": 3.0
        ])

        return softened.cropped(to: skinMask.extent)
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
