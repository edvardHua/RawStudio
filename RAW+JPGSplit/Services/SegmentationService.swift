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
    var cachedForegroundMask: CIImage?
    var cachedBackgroundMask: CIImage?
    private var cacheID: String = ""

    /// Maximum long-edge dimension for Vision input. Smaller = faster.
    private static let maxVisionDimension: CGFloat = 1024

    /// Generate all needed masks from a CIImage. Normalizes extent, scales down,
    /// forces 8-bit sRGB output, then runs Vision on a background thread.
    func generateMasks(for image: CIImage, identifier: String) async {
        guard cacheID != identifier else { return }
        cacheID = identifier

        // Reset masks before generating new ones
        cachedPersonMask = nil
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
    }

    /// Get the mask for a specific layer type, scaled and aligned to target image extent.
    func mask(for layer: LayerType, imageExtent: CGRect) -> CIImage? {
        let raw: CIImage?
        switch layer {
        case .global: return nil
        case .person: raw = cachedPersonMask
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
        case .foreground: return cachedForegroundMask != nil
        case .background: return cachedBackgroundMask != nil
        }
    }

    /// Clear all cached masks
    func clearCache() {
        cachedPersonMask = nil
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
