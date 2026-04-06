import Vision
import CoreImage
import UIKit

/// Generates and caches segmentation masks using Vision framework.
final class SegmentationService {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Cached masks per image (keyed by a hash or identifier)
    private var cachedPersonMask: CIImage?
    private var cachedForegroundMask: CIImage?
    private var cachedBackgroundMask: CIImage?
    private var cachedImageSize: CGSize = .zero
    private var cacheID: String = ""

    /// Generate all needed masks for the given image. Caches results.
    func generateMasks(for image: CIImage, identifier: String) async {
        guard cacheID != identifier else { return } // already cached

        let extent = image.extent
        cachedImageSize = extent.size
        cacheID = identifier

        // Generate person mask
        cachedPersonMask = await generatePersonMask(for: image)

        // Generate foreground mask
        cachedForegroundMask = await generateForegroundMask(for: image)

        // Background = inverse of foreground
        if let fg = cachedForegroundMask {
            let inverted = fg.applyingFilter("CIColorInvert")
            cachedBackgroundMask = inverted
        } else {
            cachedBackgroundMask = nil
        }
    }

    /// Get the mask for a specific layer type, scaled to target image size.
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
        return mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
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
        cachedImageSize = .zero
        cacheID = ""
    }

    // MARK: - Private

    private func generatePersonMask(for image: CIImage) async -> CIImage? {
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let maskBuffer = result.pixelBuffer
            return CIImage(cvPixelBuffer: maskBuffer)
        } catch {
            return nil
        }
    }

    private func generateForegroundMask(for image: CIImage) async -> CIImage? {
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return CIImage(cvPixelBuffer: maskBuffer)
        } catch {
            return nil
        }
    }

    /// Apply layer edits to an image using a mask
    static func applyLayerEdits(
        _ params: LayerEditParams,
        to image: CIImage,
        mask: CIImage
    ) -> CIImage {
        guard params.isModified else { return image }

        // Apply CIFilter chain to get edited version
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

        // Blend: edited where mask is white, original where mask is black
        let blend = CIFilter.blendWithMask()
        blend.inputImage = edited
        blend.backgroundImage = image
        blend.maskImage = mask

        return blend.outputImage ?? image
    }
}
