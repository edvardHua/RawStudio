import Foundation
import CoreImage
import ImageIO
import UIKit
import Accelerate

/// Assembles an Ultra HDR JPEG (MPF format with gain map) from SDR + HDR CIImages.
final class UltraHDRWriter {

    struct GainMapParams {
        var gainMapMin: Float = 0.0
        var gainMapMax: Float = 0.0
        var gamma: Float = 1.0
        var offsetSDR: Float = 0.015625   // 1/64
        var offsetHDR: Float = 0.015625
        var hdrCapacityMin: Float = 0.0
        var hdrCapacityMax: Float = 0.0

        // All stored as log2 in XMP
        var gainMapMinLog2: Float { gainMapMin }
        var gainMapMaxLog2: Float { gainMapMax }
        var hdrCapacityMinLog2: Float { hdrCapacityMin }
        var hdrCapacityMaxLog2: Float { hdrCapacityMax }
    }

    private let ciContext: CIContext

    init(ciContext: CIContext = CIContext()) {
        self.ciContext = ciContext
    }

    // MARK: - Public API

    /// Generate Ultra HDR JPEG data from SDR and HDR CIImages.
    func writeUltraHDRJPEG(
        sdrImage: CIImage,
        hdrImage: CIImage,
        jpegQuality: Float = 0.92,
        gainMapScale: Int = 2
    ) throws -> Data {
        let width = Int(sdrImage.extent.width)
        let height = Int(sdrImage.extent.height)
        let gmWidth = width / gainMapScale
        let gmHeight = height / gainMapScale

        // 1. Render SDR pixels (sRGB, 8-bit)
        let sdrPixels = try renderToRGBA8(sdrImage, width: width, height: height)

        // 2. Render HDR pixels (Display P3 HLG, 16-bit float)
        let hdrPixels = try renderToRGBAF16(hdrImage, width: width, height: height)

        // 3. Compute gain map
        let (gainMapPixels, params) = computeGainMap(
            sdrPixels: sdrPixels,
            hdrPixels: hdrPixels,
            width: width,
            height: height,
            gmWidth: gmWidth,
            gmHeight: gmHeight
        )

        // 4. Compress SDR as JPEG
        let sdrJPEGData = try compressJPEG(
            pixels: sdrPixels,
            width: width,
            height: height,
            quality: jpegQuality,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )

        // 5. Compress gain map as grayscale JPEG
        let gainMapJPEGData = try compressGrayscaleJPEG(
            pixels: gainMapPixels,
            width: gmWidth,
            height: gmHeight,
            quality: 0.85
        )

        // 6. Assemble Ultra HDR JPEG
        return assembleUltraHDRJPEG(
            primaryJPEG: sdrJPEGData,
            gainMapJPEG: gainMapJPEGData,
            gainMapSize: gainMapJPEGData.count,
            params: params
        )
    }

    // MARK: - Pixel Rendering

    private func renderToRGBA8(_ image: CIImage, width: Int, height: Int) throws -> Data {
        let bytesPerRow = width * 4
        var pixelData = Data(count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        try pixelData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                throw UltraHDRError.renderFailed("Cannot get pixel buffer address")
            }
            ciContext.render(
                image,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return pixelData
    }

    private func renderToRGBAF16(_ image: CIImage, width: Int, height: Int) throws -> Data {
        let bytesPerRow = width * 8 // 4 channels * 2 bytes (float16)
        var pixelData = Data(count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.displayP3)!

        try pixelData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                throw UltraHDRError.renderFailed("Cannot get pixel buffer address")
            }
            ciContext.render(
                image,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAh,
                colorSpace: colorSpace
            )
        }
        return pixelData
    }

    // MARK: - Gain Map Computation

    private func computeGainMap(
        sdrPixels: Data,
        hdrPixels: Data,
        width: Int,
        height: Int,
        gmWidth: Int,
        gmHeight: Int
    ) -> (Data, GainMapParams) {
        let scaleX = Float(width) / Float(gmWidth)
        let scaleY = Float(height) / Float(gmHeight)
        let sdrWhiteNits: Float = 203.0
        let hdrWhiteNits: Float = 1000.0  // HLG peak

        var gains = [Float](repeating: 0, count: gmWidth * gmHeight)
        var globalMin: Float = .greatestFiniteMagnitude
        var globalMax: Float = -.greatestFiniteMagnitude

        sdrPixels.withUnsafeBytes { sdrPtr in
            hdrPixels.withUnsafeBytes { hdrPtr in
                let sdrBytes = sdrPtr.bindMemory(to: UInt8.self)
                let hdrHalfs = hdrPtr.bindMemory(to: UInt16.self)

                for gy in 0..<gmHeight {
                    for gx in 0..<gmWidth {
                        let sx = Int(Float(gx) * scaleX + scaleX * 0.5)
                        let sy = Int(Float(gy) * scaleY + scaleY * 0.5)
                        let clampedSX = min(sx, width - 1)
                        let clampedSY = min(sy, height - 1)

                        let sdrIdx = (clampedSY * width + clampedSX) * 4
                        let sdrR = sRGBToLinear(Float(sdrBytes[sdrIdx]) / 255.0)
                        let sdrG = sRGBToLinear(Float(sdrBytes[sdrIdx + 1]) / 255.0)
                        let sdrB = sRGBToLinear(Float(sdrBytes[sdrIdx + 2]) / 255.0)
                        let sdrLum = max(sdrR, sdrG, sdrB)

                        let hdrIdx = (clampedSY * width + clampedSX) * 4
                        let hdrR = float16ToFloat(hdrHalfs[hdrIdx])
                        let hdrG = float16ToFloat(hdrHalfs[hdrIdx + 1])
                        let hdrB = float16ToFloat(hdrHalfs[hdrIdx + 2])
                        // HLG OOTF: approximate, the values from CIRAWFilter HLG
                        // are already scene-referred, apply gamma 1.2 OOTF
                        let hdrLum = max(hdrR, hdrG, hdrB)

                        let sdrNits = sdrLum * sdrWhiteNits
                        let hdrNits = hdrLum * hdrWhiteNits

                        var gain = log2f((hdrNits + 1e-7) / (sdrNits + 1e-7))

                        // Clamp dark pixels
                        if sdrLum < 2.0 / 255.0 {
                            gain = min(gain, 2.3)
                        }

                        gains[gy * gmWidth + gx] = gain
                        globalMin = min(globalMin, gain)
                        globalMax = max(globalMax, gain)
                    }
                }
            }
        }

        // Ensure a reasonable range
        if globalMin >= globalMax {
            globalMax = globalMin + 1.0
        }

        // Encode gain map to 8-bit
        var pixelData = Data(count: gmWidth * gmHeight)
        pixelData.withUnsafeMutableBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in 0..<gains.count {
                var normalized = (gains[i] - globalMin) / (globalMax - globalMin)
                normalized = max(0, min(1, normalized))
                bytes[i] = UInt8(clamping: Int(normalized * 255.0 + 0.5))
            }
        }

        let maxContentBoost = hdrWhiteNits / sdrWhiteNits
        let params = GainMapParams(
            gainMapMin: globalMin,
            gainMapMax: globalMax,
            gamma: 1.0,
            offsetSDR: 1.0 / 64.0,
            offsetHDR: 1.0 / 64.0,
            hdrCapacityMin: 0.0,
            hdrCapacityMax: log2f(maxContentBoost)
        )

        return (pixelData, params)
    }

    // MARK: - sRGB Helpers

    private func sRGBToLinear(_ v: Float) -> Float {
        if v <= 0.04045 {
            return v / 12.92
        }
        return powf((v + 0.055) / 1.055, 2.4)
    }

    private func float16ToFloat(_ h: UInt16) -> Float {
        var input = h
        var output: Float = 0
        var bufferIn = vImage_Buffer(data: &input, height: 1, width: 1, rowBytes: 2)
        var bufferOut = vImage_Buffer(data: &output, height: 1, width: 1, rowBytes: 4)
        vImageConvert_Planar16FtoPlanarF(&bufferIn, &bufferOut, 0)
        return output
    }

    // MARK: - JPEG Compression

    private func compressJPEG(pixels: Data, width: Int, height: Int, quality: Float, colorSpace: CGColorSpace) throws -> Data {
        let bytesPerRow = width * 4
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let provider = CGDataProvider(data: pixels as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw UltraHDRError.renderFailed("Cannot create CGImage for JPEG compression")
        }

        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            throw UltraHDRError.renderFailed("Cannot create JPEG destination")
        }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw UltraHDRError.renderFailed("Cannot finalize JPEG")
        }

        return mutableData as Data
    }

    private func compressGrayscaleJPEG(pixels: Data, width: Int, height: Int, quality: Float) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        guard let provider = CGDataProvider(data: pixels as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw UltraHDRError.renderFailed("Cannot create grayscale CGImage")
        }

        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            throw UltraHDRError.renderFailed("Cannot create JPEG destination")
        }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw UltraHDRError.renderFailed("Cannot finalize grayscale JPEG")
        }

        return mutableData as Data
    }

    // MARK: - Ultra HDR Assembly

    private func assembleUltraHDRJPEG(
        primaryJPEG: Data,
        gainMapJPEG: Data,
        gainMapSize: Int,
        params: GainMapParams
    ) -> Data {
        // Build XMP for primary image
        let primaryXMP = buildPrimaryXMP(gainMapSize: gainMapSize, params: params)
        // Build XMP for gain map
        let gainMapXMP = buildGainMapXMP(params: params)
        // Build ISO 21496-1 version marker
        let isoVersionPayload = buildISOVersionPayload()
        // Build ISO 21496-1 gain map metadata
        let isoGainMapMetadata = buildISOGainMapMetadata(params: params)

        // Calculate sizes for MPF
        // Primary image: SOI + EXIF(from original) + primary XMP APP1 + ISO version APP2 + MPF APP2 + rest of primary JPEG
        // We need to figure out what "rest of primary JPEG" is (everything after SOI)

        let primaryAfterSOI = primaryJPEG.dropFirst(2) // skip FF D8

        let xmpNamespace = "http://ns.adobe.com/xap/1.0/\0".data(using: .utf8)!
        let isoNamespace = "urn:iso:std:iso:ts:21496:-1\0".data(using: .utf8)!
        let mpfSignature = Data([0x4D, 0x50, 0x46, 0x00]) // "MPF\0"

        // APP1 XMP: FF E1 + 2-byte length + namespace + xmp data
        let primaryXMPData = primaryXMP.data(using: .utf8)!
        let primaryXMPMarker = buildAPP1Marker(namespace: xmpNamespace, payload: primaryXMPData)

        // APP2 ISO version: FF E2 + 2-byte length + namespace + payload
        let isoVersionMarker = buildAPP2Marker(namespace: isoNamespace, payload: isoVersionPayload)

        // MPF: need to calculate after knowing total primary size
        // Placeholder for now, we'll calculate offsets after
        let mpfPayloadSize = buildMPFPayload(primarySize: 0, secondarySize: 0, secondaryOffset: 0).count
        let mpfMarkerOverhead = 2 + 2 // FF E2 + length field
        let mpfTotalSize = mpfMarkerOverhead + mpfPayloadSize

        // Total primary image size
        let primaryImageSize = 2 + // SOI
            primaryXMPMarker.count +
            isoVersionMarker.count +
            mpfTotalSize +
            primaryAfterSOI.count

        // Build secondary image
        let gainMapAfterSOI = gainMapJPEG.dropFirst(2) // skip FF D8
        let gainMapXMPData = gainMapXMP.data(using: .utf8)!
        let gainMapXMPMarker = buildAPP1Marker(namespace: xmpNamespace, payload: gainMapXMPData)
        let gainMapISOMarker = buildAPP2Marker(namespace: isoNamespace, payload: isoGainMapMetadata)

        let secondaryImageSize = 2 + // SOI
            gainMapXMPMarker.count +
            gainMapISOMarker.count +
            gainMapAfterSOI.count

        // Secondary offset is from start of MPF APP2 payload (from "MPF\0")
        // But per spec, it's from the start of the file for the MP entry
        // Actually, per MPF spec, offsets are relative to the start of the MPF APP2 marker body (after FF E2 + length)
        // However, in libultrahdr, the offset in MP Entry is absolute from start of file
        let secondaryOffset = UInt32(primaryImageSize)

        // Now build the real MPF
        let mpfPayload = buildMPFPayload(
            primarySize: UInt32(primaryImageSize),
            secondarySize: UInt32(secondaryImageSize),
            secondaryOffset: secondaryOffset
        )
        let mpfMarker = buildAPP2Marker(namespace: mpfSignature, payload: mpfPayload)

        // Recalculate primary size with correct MPF
        // (should be same since mpfPayload size is fixed)

        // Assemble output
        var output = Data()
        output.reserveCapacity(primaryImageSize + secondaryImageSize)

        // Primary image
        output.append(contentsOf: [0xFF, 0xD8]) // SOI
        output.append(primaryXMPMarker)
        output.append(isoVersionMarker)
        output.append(mpfMarker)
        output.append(primaryAfterSOI)

        // Secondary image
        output.append(contentsOf: [0xFF, 0xD8]) // SOI
        output.append(gainMapXMPMarker)
        output.append(gainMapISOMarker)
        output.append(gainMapAfterSOI)

        return output
    }

    // MARK: - APP Marker Builders

    private func buildAPP1Marker(namespace: Data, payload: Data) -> Data {
        var marker = Data()
        marker.append(contentsOf: [0xFF, 0xE1])
        let length = UInt16(2 + namespace.count + payload.count)
        marker.appendUInt16BE(length)
        marker.append(namespace)
        marker.append(payload)
        return marker
    }

    private func buildAPP2Marker(namespace: Data, payload: Data) -> Data {
        var marker = Data()
        marker.append(contentsOf: [0xFF, 0xE2])
        let length = UInt16(2 + namespace.count + payload.count)
        marker.appendUInt16BE(length)
        marker.append(namespace)
        marker.append(payload)
        return marker
    }

    // MARK: - ISO 21496-1

    private func buildISOVersionPayload() -> Data {
        var data = Data()
        data.appendUInt16BE(0) // minimum_version
        data.appendUInt16BE(0) // writer_version
        return data
    }

    private func buildISOGainMapMetadata(params: GainMapParams) -> Data {
        var data = Data()
        data.appendUInt16BE(0) // minimum_version
        data.appendUInt16BE(0) // writer_version

        // flags: single channel, no useBaseColorSpace, no backwardDirection, useCommonDenominator
        let flags: UInt8 = 0b00001000 // bit 3 = useCommonDenominator
        data.append(flags)

        let denom: UInt32 = 10000

        // commonDenominator
        data.appendUInt32BE(denom)

        // baseHdrHeadroomN (= hdrCapacityMin in log2, as fraction of denom)
        let baseHeadroomN = Int32(params.hdrCapacityMin * Float(denom))
        data.appendInt32BE(baseHeadroomN)

        // alternateHdrHeadroomN (= hdrCapacityMax)
        let altHeadroomN = Int32(params.hdrCapacityMax * Float(denom))
        data.appendInt32BE(altHeadroomN)

        // Per-channel (1 channel): gainMapMin, gainMapMax, gamma, offsetSDR, offsetHDR
        data.appendInt32BE(Int32(params.gainMapMin * Float(denom)))
        data.appendInt32BE(Int32(params.gainMapMax * Float(denom)))
        data.appendUInt32BE(UInt32(params.gamma * Float(denom)))
        data.appendInt32BE(Int32(params.offsetSDR * Float(denom)))
        data.appendInt32BE(Int32(params.offsetHDR * Float(denom)))

        return data
    }

    // MARK: - MPF

    private func buildMPFPayload(primarySize: UInt32, secondarySize: UInt32, secondaryOffset: UInt32) -> Data {
        var data = Data()

        // Big Endian marker
        data.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])

        // Index IFD offset (from start of endian marker = offset 0)
        data.appendUInt32BE(8)

        // IFD tag count = 3
        data.appendUInt16BE(3)

        // Tag 1: Version (0xB000), type UNDEFINED (7), count 4, value "0100"
        data.appendUInt16BE(0xB000)
        data.appendUInt16BE(0x0007)
        data.appendUInt32BE(4)
        data.append(contentsOf: [0x30, 0x31, 0x30, 0x30]) // "0100"

        // Tag 2: NumberOfImages (0xB001), type LONG (4), count 1, value 2
        data.appendUInt16BE(0xB001)
        data.appendUInt16BE(0x0004)
        data.appendUInt32BE(1)
        data.appendUInt32BE(2)

        // Tag 3: MPEntry (0xB002), type UNDEFINED (7), count 32, offset to entries
        data.appendUInt16BE(0xB002)
        data.appendUInt16BE(0x0007)
        data.appendUInt32BE(32) // 2 entries * 16 bytes

        // Offset to MP entries from endian marker start
        // Current position after all 3 tags = 8 (endian+IFD offset) + 2 (count) + 36 (3*12) = 46
        // Then + 4 for next IFD offset = 50
        let mpEntryOffset: UInt32 = 50
        data.appendUInt32BE(mpEntryOffset)

        // Next IFD offset = 0 (no attribute IFD)
        data.appendUInt32BE(0)

        // MP Entry 1: Primary image
        data.appendUInt32BE(0x020030_00) // Dependent child + JPEG + representative
        data.appendUInt32BE(primarySize)
        data.appendUInt32BE(0) // offset 0 for primary
        data.appendUInt16BE(0)
        data.appendUInt16BE(0)

        // MP Entry 2: Secondary image (gain map)
        data.appendUInt32BE(0x000000)
        data.appendUInt32BE(secondarySize)
        data.appendUInt32BE(secondaryOffset)
        data.appendUInt16BE(0)
        data.appendUInt16BE(0)

        return data
    }

    // MARK: - XMP Builders

    private func buildPrimaryXMP(gainMapSize: Int, params: GainMapParams) -> String {
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>\
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP">\
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description \
        xmlns:Container="http://ns.google.com/photos/1.0/container/" \
        xmlns:Item="http://ns.google.com/photos/1.0/container/item/" \
        xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" \
        hdrgm:Version="1.0">\
        <Container:Directory><rdf:Seq>\
        <rdf:li rdf:parseType="Resource">\
        <Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/>\
        </rdf:li>\
        <rdf:li rdf:parseType="Resource">\
        <Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="\(gainMapSize)"/>\
        </rdf:li>\
        </rdf:Seq></Container:Directory>\
        </rdf:Description>\
        </rdf:RDF>\
        </x:xmpmeta>\
        <?xpacket end="w"?>
        """
    }

    private func buildGainMapXMP(params: GainMapParams) -> String {
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>\
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP">\
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description \
        xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" \
        hdrgm:Version="1.0" \
        hdrgm:BaseRenditionIsHDR="False" \
        hdrgm:GainMapMin="\(String(format: "%.6f", params.gainMapMinLog2))" \
        hdrgm:GainMapMax="\(String(format: "%.6f", params.gainMapMaxLog2))" \
        hdrgm:Gamma="\(String(format: "%.1f", params.gamma))" \
        hdrgm:OffsetSDR="\(String(format: "%.6f", params.offsetSDR))" \
        hdrgm:OffsetHDR="\(String(format: "%.6f", params.offsetHDR))" \
        hdrgm:HDRCapacityMin="\(String(format: "%.6f", params.hdrCapacityMinLog2))" \
        hdrgm:HDRCapacityMax="\(String(format: "%.6f", params.hdrCapacityMaxLog2))"/>\
        </rdf:RDF>\
        </x:xmpmeta>\
        <?xpacket end="w"?>
        """
    }
}

// MARK: - Error

enum UltraHDRError: LocalizedError {
    case renderFailed(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let detail): return "Ultra HDR render failed: \(detail)"
        case .encodingFailed(let detail): return "Ultra HDR encoding failed: \(detail)"
        }
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 2))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 4))
    }

    mutating func appendInt32BE(_ value: Int32) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 4))
    }
}
