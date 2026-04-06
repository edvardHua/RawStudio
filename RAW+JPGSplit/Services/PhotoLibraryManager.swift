import Photos
import UIKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

enum PhotoPermissionStatus {
    case notDetermined
    case authorized
    case denied
}

enum SplitAction {
    case keepJPG
    case keepRAW
    case split
}

enum SplitError: LocalizedError {
    case extractionFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let detail):
            return "Failed to extract photo data: \(detail)"
        case .writeFailed(let detail):
            return "Failed to save photo: \(detail)"
        }
    }
}

@Observable
final class PhotoLibraryManager {
    var permissionStatus: PhotoPermissionStatus = .notDetermined
    var pairs: [PhotoPair] = []
    var isLoading: Bool = false
    var albums: [Album] = []
    var selectedAlbum: Album?

    // Batch operation state
    var batchProgress: Int = 0
    var batchTotal: Int = 0
    var isBatchProcessing: Bool = false
    var batchSuccessCount: Int = 0
    var batchFailCount: Int = 0

    private let cachingManager = PHCachingImageManager()
    private let thumbnailSize = CGSize(width: 160, height: 160)

    // MARK: - Permissions

    func checkPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            permissionStatus = .authorized
        case .denied, .restricted:
            permissionStatus = .denied
        case .notDetermined:
            permissionStatus = .notDetermined
        @unknown default:
            permissionStatus = .denied
        }
    }

    func requestPermission() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited:
            permissionStatus = .authorized
        default:
            permissionStatus = .denied
        }
    }

    // MARK: - Albums

    func fetchAlbums() {
        var smartAlbumList: [Album] = []
        var userAlbumList: [Album] = []

        // Smart albums in system-like order
        let preferredSmartAlbumOrder: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary,    // Recents / All Photos
            .smartAlbumFavorites,      // Favorites
            .smartAlbumRecentlyAdded,  // Recently Added
            .smartAlbumSelfPortraits,  // Selfies
            .smartAlbumDepthEffect,    // Portrait
            .smartAlbumLivePhotos,     // Live Photos
            .smartAlbumPanoramas,      // Panoramas
            .smartAlbumVideos,         // Videos
            .smartAlbumScreenshots,    // Screenshots
            .smartAlbumBursts,         // Bursts
            .smartAlbumSlomoVideos,    // Slo-mo
            .smartAlbumTimelapses,     // Time-lapse
            .smartAlbumAnimated,       // Animated
            .smartAlbumLongExposures,  // Long Exposure
        ]

        for subtype in preferredSmartAlbumOrder {
            let fetched = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            fetched.enumerateObjects { collection, _, _ in
                if collection.localizedTitle != nil {
                    smartAlbumList.append(Album(collection: collection))
                }
            }
        }

        // User-created albums (keep original order)
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            userAlbumList.append(Album(collection: collection))
        }

        albums = smartAlbumList + userAlbumList
    }

    func selectAlbum(_ album: Album?) async {
        selectedAlbum = album
        await fetchPairedAssets()
    }

    // MARK: - Fetch Paired Assets

    func fetchPairedAssets() async {
        isLoading = true
        defer { isLoading = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result: PHFetchResult<PHAsset>
        if let album = selectedAlbum {
            result = PHAsset.fetchAssets(in: album.collection, options: fetchOptions)
        } else {
            result = PHAsset.fetchAssets(with: fetchOptions)
        }
        var foundPairs: [PhotoPair] = []

        result.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            var jpgResource: PHAssetResource?
            var rawResource: PHAssetResource?

            for resource in resources {
                if resource.type == .alternatePhoto {
                    // In a RAW+JPG pair, the alternate is always the RAW
                    rawResource = resource
                } else if resource.type == .photo {
                    // Check if this "photo" is actually a RAW file
                    if Self.isRAWType(resource.uniformTypeIdentifier) {
                        rawResource = resource
                    } else {
                        jpgResource = resource
                    }
                }
            }

            // RAW+JPG pair or RAW-only
            if let raw = rawResource {
                let pair = PhotoPair(asset: asset, jpgResource: jpgResource, rawResource: raw)
                foundPairs.append(pair)
            }
        }

        self.pairs = foundPairs
    }

    // MARK: - Thumbnails

    func loadThumbnail(for pair: PhotoPair) async {
        guard pair.thumbnail == nil else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            cachingManager.requestImage(
                for: pair.asset,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        pair.thumbnail = image
    }

    // MARK: - Load Full Images for Compare

    private let ciContext = CIContext()

    /// Load JPG image and metadata from resource data
    func loadJPGImageWithMetadata(for pair: PhotoPair) async throws -> (UIImage, PhotoMetadata)? {
        guard let resource = pair.jpgResource else { return nil }
        let data = try await extractResourceData(for: resource)
        guard let image = UIImage(data: data) else {
            throw SplitError.extractionFailed("Cannot decode image data for \(resource.originalFilename)")
        }
        let fileSize = (try? resource.value(forKey: "fileSize") as? Int64) ?? Int64(data.count)
        let metadata = PhotoMetadata.from(
            data: data,
            fileSize: fileSize,
            pixelWidth: pair.asset.pixelWidth,
            pixelHeight: pair.asset.pixelHeight
        )
        return (image, metadata)
    }

    /// Load RAW image and metadata using CIRAWFilter, optionally applying edit params
    func loadRAWImageWithMetadata(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws -> (UIImage, PhotoMetadata) {
        let resource = pair.rawResource
        let data = try await extractResourceData(for: resource)
        let fileSize = (try? resource.value(forKey: "fileSize") as? Int64) ?? Int64(data.count)

        // Extract metadata from raw data before rendering
        let metadata = PhotoMetadata.from(
            data: data,
            fileSize: fileSize,
            pixelWidth: pair.asset.pixelWidth,
            pixelHeight: pair.asset.pixelHeight
        )

        // Try CIRAWFilter first (iOS 15+) for proper RAW rendering
        if let rawFilter = CIRAWFilter(imageData: data, identifierHint: resource.uniformTypeIdentifier) {
            // Apply edit params
            if editParams.isModified {
                RAWEditorView.applyParams(editParams, to: rawFilter)
            }
            if let outputImage = rawFilter.outputImage {
                let extent = outputImage.extent
                if let cgImage = ciContext.createCGImage(outputImage, from: extent) {
                    return (UIImage(cgImage: cgImage), metadata)
                }
            }
        }

        // Fallback: try CIImage
        if let ciImage = CIImage(data: data),
           let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            return (UIImage(cgImage: cgImage), metadata)
        }

        // Last resort
        guard let image = UIImage(data: data) else {
            throw SplitError.extractionFailed("Cannot decode RAW image data for \(resource.originalFilename)")
        }
        return (image, metadata)
    }

    /// Expose raw data extraction for the editor
    func extractRawData(for resource: PHAssetResource) async throws -> Data {
        try await extractResourceData(for: resource)
    }

    // MARK: - Core Operations

    /// Export Adaptive HDR HEIF from RAW data
    func exportAdaptiveHDR(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        let rawData = try await extractResourceData(for: pair.rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: pair.rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(pair.rawResource.originalFilename)")
        }

        // Apply edit params
        if editParams.isModified {
            RAWEditorView.applyParams(editParams, to: rawFilter)
        }

        // Render SDR version
        rawFilter.extendedDynamicRangeAmount = 0.0
        guard let sdrImage = rawFilter.outputImage else {
            throw SplitError.extractionFailed("Cannot render SDR image from RAW")
        }

        // Render HDR version
        rawFilter.extendedDynamicRangeAmount = 1.0
        guard let hdrImage = rawFilter.outputImage else {
            throw SplitError.extractionFailed("Cannot render HDR image from RAW")
        }

        // Write Adaptive HDR HEIF to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")

        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw SplitError.writeFailed("Cannot create Display P3 color space")
        }

        try ciContext.writeHEIFRepresentation(
            of: sdrImage,
            to: tempURL,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: [.hdrImage: hdrImage]
        )

        // Read the HEIF data and save to photo library
        let heifData = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        try await saveAsNewAsset(
            data: heifData,
            resourceType: .photo,
            originalFilename: (pair.rawResource.originalFilename as NSString)
                .deletingPathExtension + "_HDR.heic"
        )
    }

    /// Export Ultra HDR JPEG (MPF format with gain map) from RAW data
    func exportUltraHDRJPEG(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        let rawData = try await extractResourceData(for: pair.rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: pair.rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(pair.rawResource.originalFilename)")
        }

        // Apply edit params
        if editParams.isModified {
            RAWEditorView.applyParams(editParams, to: rawFilter)
        }

        // Render SDR version
        rawFilter.extendedDynamicRangeAmount = 0.0
        guard let sdrImage = rawFilter.outputImage else {
            throw SplitError.extractionFailed("Cannot render SDR image from RAW")
        }

        // Render HDR version
        rawFilter.extendedDynamicRangeAmount = 1.0
        guard let hdrImage = rawFilter.outputImage else {
            throw SplitError.extractionFailed("Cannot render HDR image from RAW")
        }

        // Generate Ultra HDR JPEG
        let writer = UltraHDRWriter(ciContext: ciContext)
        let ultraHDRData = try writer.writeUltraHDRJPEG(sdrImage: sdrImage, hdrImage: hdrImage)

        // Save to photo library
        try await saveAsNewAsset(
            data: ultraHDRData,
            resourceType: .photo,
            originalFilename: (pair.rawResource.originalFilename as NSString)
                .deletingPathExtension + "_UltraHDR.jpg"
        )
    }

    func performAction(_ action: SplitAction, on pair: PhotoPair) async throws {
        guard !pair.isRawOnly else {
            throw SplitError.extractionFailed("Cannot perform this action on RAW-only photos")
        }
        guard let jpgResource = pair.jpgResource else {
            throw SplitError.extractionFailed("No JPG resource found")
        }

        switch action {
        case .keepJPG:
            let jpgData = try await extractResourceData(for: jpgResource)
            try await saveAsNewAsset(data: jpgData, resourceType: .photo, originalFilename: jpgResource.originalFilename)
            await deleteAssetSilently(pair.asset)
            pair.processResult = .keptJPG

        case .keepRAW:
            let rawData = try await extractResourceData(for: pair.rawResource)
            try await saveAsNewAsset(data: rawData, resourceType: .photo, originalFilename: pair.rawResource.originalFilename)
            await deleteAssetSilently(pair.asset)
            pair.processResult = .keptRAW

        case .split:
            let jpgData = try await extractResourceData(for: jpgResource)
            let rawData = try await extractResourceData(for: pair.rawResource)
            try await saveAsNewAsset(data: jpgData, resourceType: .photo, originalFilename: jpgResource.originalFilename)
            try await saveAsNewAsset(data: rawData, resourceType: .photo, originalFilename: pair.rawResource.originalFilename)
            await deleteAssetSilently(pair.asset)
            pair.processResult = .split
        }
    }

    func performBatchAction(_ action: SplitAction, on selectedPairs: [PhotoPair]) async -> (success: Int, failed: Int) {
        isBatchProcessing = true
        batchTotal = selectedPairs.count
        batchProgress = 0
        batchSuccessCount = 0
        batchFailCount = 0

        for pair in selectedPairs {
            do {
                try await performAction(action, on: pair)
                batchSuccessCount += 1
            } catch {
                batchFailCount += 1
            }
            batchProgress += 1
        }

        isBatchProcessing = false
        return (batchSuccessCount, batchFailCount)
    }

    // MARK: - Private Helpers

    /// Check if a UTI represents a RAW image format
    private static func isRAWType(_ uti: String) -> Bool {
        let rawUTIs: Set<String> = [
            "com.adobe.raw-image",          // DNG
            "com.sony.arw-raw-image",       // ARW
            "com.canon.cr2-raw-image",      // CR2
            "com.canon.cr3-raw-image",      // CR3
            "com.nikon.nrw-raw-image",      // NRW
            "com.nikon.raw-image",          // NEF
            "com.fuji.raw-image",           // RAF
            "com.olympus.raw-image",        // ORF
            "com.olympus.or-raw-image",     // ORF variant
            "com.panasonic.raw-image",      // RW2
            "com.panasonic.rw2-raw-image",  // RW2 variant
            "com.pentax.raw-image",         // PEF
            "com.samsung.raw-image",        // SRW
            "com.leica.raw-image",          // RWL
            "com.hasselblad.raw-image",     // 3FR
            "com.hasselblad.fff-raw-image", // FFF
            "com.apple.proraw",             // Apple ProRAW (old?)
        ]

        let lowerUTI = uti.lowercased()

        // Direct match
        if rawUTIs.contains(lowerUTI) { return true }

        // Check if it conforms to the generic "com.adobe.raw-image" base type
        // or contains "raw" in the UTI
        if lowerUTI.contains("raw") { return true }

        // Check by file extension in the UTI
        if lowerUTI.hasSuffix(".dng") || lowerUTI.hasSuffix(".arw") ||
           lowerUTI.hasSuffix(".cr2") || lowerUTI.hasSuffix(".cr3") ||
           lowerUTI.hasSuffix(".nef") || lowerUTI.hasSuffix(".raf") ||
           lowerUTI.hasSuffix(".orf") || lowerUTI.hasSuffix(".rw2") ||
           lowerUTI.hasSuffix(".pef") { return true }

        return false
    }

    private func extractResourceData(for resource: PHAssetResource) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var accumulatedData = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    accumulatedData.append(chunk)
                },
                completionHandler: { error in
                    if let error = error {
                        continuation.resume(throwing: SplitError.extractionFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: accumulatedData)
                    }
                }
            )
        }
    }

    private func saveAsNewAsset(data: Data, resourceType: PHAssetResourceType, originalFilename: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = originalFilename
                request.addResource(with: resourceType, data: data, options: options)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SplitError.writeFailed(error?.localizedDescription ?? "Unknown error"))
                }
            }
        }
    }

    private func deleteAssetSilently(_ asset: PHAsset) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }) { _, _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Filtered access

    var unprocessedPairs: [PhotoPair] {
        pairs.filter { !$0.isProcessed }
    }

    var processedPairs: [PhotoPair] {
        pairs.filter { $0.isProcessed }
    }

    /// Groups pairs by date for section headers
    private static let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    func groupedByDate(_ pairsToGroup: [PhotoPair]) -> [(date: String, pairs: [PhotoPair])] {
        let formatter = Self.groupDateFormatter

        let grouped = Dictionary(grouping: pairsToGroup) { pair in
            formatter.string(from: pair.captureDate)
        }

        return grouped.sorted { lhs, rhs in
            guard let lDate = lhs.value.first?.captureDate,
                  let rDate = rhs.value.first?.captureDate else { return false }
            return lDate > rDate
        }.map { (date: $0.key, pairs: $0.value) }
    }
}
