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
    var isScanningMore: Bool = false
    var scanProgress: String = ""
    var albums: [Album] = []
    var selectedAlbum: Album?

    // Batch operation state
    var batchProgress: Int = 0
    var batchTotal: Int = 0
    var isBatchProcessing: Bool = false
    var batchSuccessCount: Int = 0
    var batchFailCount: Int = 0

    // Thumbnail cache (thread-safe, auto-evicts under memory pressure)
    let thumbnailCache = NSCache<NSString, UIImage>()

    private let cachingManager = PHCachingImageManager()

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

    private static let batchSize = 50

    func fetchPairedAssets() async {
        isLoading = true
        pairs = []

        let album = selectedAlbum
        let stream = Self.scanForPairsBatched(in: album)

        var isFirstBatch = true
        for await batch in stream {
            pairs.append(contentsOf: batch.pairs)
            scanProgress = batch.progress

            if isFirstBatch && !pairs.isEmpty {
                isLoading = false
                isScanningMore = true
                isFirstBatch = false
            }
        }

        isLoading = false
        isScanningMore = false
        scanProgress = ""
    }

    /// Batch result from scanning
    struct ScanBatch: Sendable {
        let pairs: [PhotoPair]
        let progress: String // e.g. "50/120"
    }

    /// Scan with batch streaming — yields results progressively from background thread
    nonisolated private static func scanForPairsBatched(in album: Album?) -> AsyncStream<ScanBatch> {
        AsyncStream(bufferingPolicy: .bufferingNewest(10)) { continuation in
            // Run the heavy scanning on a background thread
            Task.detached(priority: .userInitiated) {
                let fetchOptions = PHFetchOptions()
                fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                fetchOptions.predicate = NSPredicate(
                    format: "mediaType == %d",
                    PHAssetMediaType.image.rawValue
                )

                let result: PHFetchResult<PHAsset>
                if let album = album {
                    result = PHAsset.fetchAssets(in: album.collection, options: fetchOptions)
                } else {
                    result = PHAsset.fetchAssets(with: fetchOptions)
                }

                let totalCount = result.count
                var batchBuffer: [PhotoPair] = []
                var scannedCount = 0

                result.enumerateObjects { asset, _, _ in
                    let resources = PHAssetResource.assetResources(for: asset)
                    var jpgResource: PHAssetResource?
                    var rawResource: PHAssetResource?

                    for resource in resources {
                        if resource.type == .alternatePhoto {
                            rawResource = resource
                        } else if resource.type == .photo {
                            if Self.isRAWType(resource.uniformTypeIdentifier) {
                                rawResource = resource
                            } else {
                                jpgResource = resource
                            }
                        }
                    }

                    if jpgResource != nil || rawResource != nil {
                        let pair = PhotoPair(asset: asset, jpgResource: jpgResource, rawResource: rawResource)
                        batchBuffer.append(pair)
                    }

                    scannedCount += 1

                    // Yield batch when buffer is full
                    if batchBuffer.count >= batchSize {
                        let progress = "\(scannedCount)/\(totalCount)"
                        continuation.yield(ScanBatch(pairs: batchBuffer, progress: progress))
                        batchBuffer.removeAll(keepingCapacity: true)
                    }
                }

                // Yield remaining
                if !batchBuffer.isEmpty {
                    let progress = "\(scannedCount)/\(totalCount)"
                    continuation.yield(ScanBatch(pairs: batchBuffer, progress: progress))
                }

                continuation.finish()
            }
        }
    }

    // MARK: - Delete

    /// 通过 PHPhotoLibrary 真删除选中资产。系统会弹原生确认 alert；
    /// - 返回 .cancelled = true：用户在系统弹框选了取消（或权限不足）
    /// - 返回 .deletedCount：实际删除数量；同时本地 `pairs` 数组同步移除
    ///   （触发 @Observable 通知，订阅视图自动刷新）
    func deleteAssets(_ pairsToDelete: [PhotoPair]) async -> (deletedCount: Int, cancelled: Bool) {
        guard !pairsToDelete.isEmpty else { return (0, false) }
        let assets = pairsToDelete.map(\.asset)
        let ids = Set(pairsToDelete.map(\.id))

        let ok: Bool = await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { ok, error in
                if !ok, let error {
                    print("[PhotoLibraryManager] deleteAssets failed: \(error)")
                }
                cont.resume(returning: ok)
            }
        }

        if ok {
            pairs.removeAll { ids.contains($0.id) }
            return (pairsToDelete.count, false)
        } else {
            return (0, true)
        }
    }

    // MARK: - Thumbnails

    /// 把任意宽度向上取整到 64 的倍数，避免不同请求把缓存撑爆 N 份
    private func bucketWidth(_ w: CGFloat) -> Int {
        ((Int(w) + 63) / 64) * 64
    }

    /// 高质量两阶段缩略图加载。
    ///
    /// `size` 是**像素**单位，调用方负责乘以 `displayScale`。
    /// 使用 `.opportunistic` 交付模式：cache 命中只 yield 一次；cache 未命中可能 yield 两次
    /// （先低清后高清），以 `PHImageResultIsDegradedKey == false` 的那次作为最终图存入缓存。
    func loadThumbnailStream(for pair: PhotoPair, size: CGSize) -> AsyncStream<UIImage> {
        let key = "\(pair.id)@\(bucketWidth(size.width))x\(bucketWidth(size.height))" as NSString
        let cache = thumbnailCache
        let manager = cachingManager

        return AsyncStream { continuation in
            // Cache 命中：直接 yield 最终图后 finish
            if let cached = cache.object(forKey: key) {
                continuation.yield(cached)
                continuation.finish()
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let requestID = manager.requestImage(
                for: pair.asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil

                if let image {
                    continuation.yield(image)
                    if !isDegraded {
                        cache.setObject(image, forKey: key)
                    }
                }

                // 终止条件：拿到非 degraded 图、被取消、或出错
                if !isDegraded || isCancelled || hasError {
                    continuation.finish()
                }
            }

            // .task(id:) 切换 pair 时 stream 终止 → 取消未完成的 PHImage 请求
            continuation.onTermination = { @Sendable _ in
                manager.cancelImageRequest(requestID)
            }
        }
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
        guard let resource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
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

    /// Export Adaptive HDR HEIF from RAW data, preserving original EXIF metadata
    func exportAdaptiveHDR(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        guard let rawResource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
        let rawData = try await extractResourceData(for: rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(rawResource.originalFilename)")
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

        // Inject EXIF metadata from original RAW into the HEIF file.
        // Orientation is reset to "up" because CIRAWFilter already baked the rotation into pixels.
        let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: rawData))
        let rawHeifData = try Data(contentsOf: tempURL)
        let finalData = Self.injectMetadata(into: tempURL, properties: exifProperties) ?? rawHeifData
        try? FileManager.default.removeItem(at: tempURL)

        try await saveAsNewAsset(
            data: finalData,
            resourceType: .photo,
            originalFilename: (rawResource.originalFilename as NSString)
                .deletingPathExtension + "_HDR.heic"
        )
    }

    /// Export Ultra HDR JPEG (MPF format with gain map) from RAW data, preserving original EXIF metadata
    func exportUltraHDRJPEG(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        guard let rawResource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
        let rawData = try await extractResourceData(for: rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(rawResource.originalFilename)")
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

        // Extract EXIF from original RAW.
        // Orientation is reset to "up" because CIRAWFilter already baked the rotation into pixels.
        let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: rawData))

        // Generate Ultra HDR JPEG with EXIF
        let writer = UltraHDRWriter(ciContext: ciContext)
        let ultraHDRData = try writer.writeUltraHDRJPEG(
            sdrImage: sdrImage,
            hdrImage: hdrImage,
            exifProperties: exifProperties
        )

        // Save to photo library
        try await saveAsNewAsset(
            data: ultraHDRData,
            resourceType: .photo,
            originalFilename: (rawResource.originalFilename as NSString)
                .deletingPathExtension + "_UltraHDR.jpg"
        )
    }

    /// 判断给定的图像数据是否是 HDR（含 gain map 或 10-bit HLG 等标记）。
    /// 用于决定是否在 CompareView 上显示 HDR JPEG 导出按钮。
    static func isHDRImage(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]

        // 1. depth >= 10（Apple HDR HEIC 都是 10-bit）
        if let depth = properties?[kCGImagePropertyDepth as String] as? Int, depth >= 10 {
            return true
        }

        // 2. 含 HDR gain map auxiliary data
        let auxTypes: [CFString] = [
            "kCGImageAuxiliaryDataTypeISOGainMap" as CFString,    // iOS 18+ ISO HDR
            "kCGImageAuxiliaryDataTypeHDRGainMap" as CFString,    // Apple HDR
        ]
        for type in auxTypes {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
                return true
            }
        }
        return false
    }

    /// 把 HDR HEIC（或任何含 HDR gain map 的图）转成 Ultra HDR JPEG（Android 兼容的 MPF + gain map JPEG）。
    /// 复用 UltraHDRWriter：SDR 路径走 sRGB（clamp），HDR 路径走 HLG（保留扩展），同一 CIImage 输入两次即可。
    func exportUltraHDRJPEGFromImage(for pair: PhotoPair) async throws {
        guard let jpgResource = pair.jpgResource else {
            throw SplitError.extractionFailed("This photo has no image resource")
        }
        let data = try await extractResourceData(for: jpgResource)

        guard let ciImage = CIImage(data: data, options: [.expandToHDR: true]) else {
            throw SplitError.extractionFailed("Cannot decode image as HDR")
        }

        let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: data))

        let writer = UltraHDRWriter(ciContext: ciContext)
        let ultraHDRData = try writer.writeUltraHDRJPEG(
            sdrImage: ciImage,
            hdrImage: ciImage,
            exifProperties: exifProperties
        )

        try await saveAsNewAsset(
            data: ultraHDRData,
            resourceType: .photo,
            originalFilename: (jpgResource.originalFilename as NSString)
                .deletingPathExtension + "_UltraHDR.jpg"
        )
    }

    func performAction(_ action: SplitAction, on pair: PhotoPair) async throws {
        guard pair.kind == .rawJpgPair else {
            throw SplitError.extractionFailed("This action requires a RAW+JPG pair")
        }
        // kind == .rawJpgPair 保证两个资源都存在；下面的 force-unwrap 安全
        let jpgResource = pair.jpgResource!
        let rawResource = pair.rawResource!

        switch action {
        case .keepJPG:
            let jpgData = try await extractResourceData(for: jpgResource)
            try await saveAsNewAsset(data: jpgData, resourceType: .photo, originalFilename: jpgResource.originalFilename)

        case .keepRAW:
            let rawData = try await extractResourceData(for: rawResource)
            try await saveAsNewAsset(data: rawData, resourceType: .photo, originalFilename: rawResource.originalFilename)
        }
    }

    /// Delete the original paired asset (moves to Recently Deleted)
    /// Returns true if user allowed the deletion, false if denied.
    func deleteOriginal(for pair: PhotoPair) async -> Bool {
        await deleteAssetWithResult(pair.asset)
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

    // MARK: - EXIF Metadata

    /// Reset orientation to "up" (1) in a properties dict.
    /// CIRAWFilter.outputImage already bakes orientation into pixel data, so the EXIF
    /// orientation tag must be cleared to avoid double-rotation in the exported file.
    nonisolated static func propertiesWithNormalizedOrientation(_ properties: [String: Any]?) -> [String: Any]? {
        guard var props = properties else { return nil }
        props[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return props
    }

    /// Extract complete image properties (EXIF, TIFF, GPS, etc.) from image data
    nonisolated static func extractImageProperties(from data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }
        return properties
    }

    /// Inject metadata properties into an image file, returns new Data
    nonisolated static func injectMetadata(into fileURL: URL, properties: [String: Any]?) -> Data? {
        guard let properties else { return nil }
        guard let sourceData = try? Data(contentsOf: fileURL),
              let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return nil }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return nil }

        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    // MARK: - Private Helpers

    /// Check if a UTI represents a RAW image format
    nonisolated private static func isRAWType(_ uti: String) -> Bool {
        let rawUTIs: Set<String> = [
            "com.adobe.raw-image",
            "com.sony.arw-raw-image",
            "com.canon.cr2-raw-image",
            "com.canon.cr3-raw-image",
            "com.nikon.nrw-raw-image",
            "com.nikon.raw-image",
            "com.fuji.raw-image",
            "com.olympus.raw-image",
            "com.olympus.or-raw-image",
            "com.panasonic.raw-image",
            "com.panasonic.rw2-raw-image",
            "com.pentax.raw-image",
            "com.samsung.raw-image",
            "com.leica.raw-image",
            "com.hasselblad.raw-image",
            "com.hasselblad.fff-raw-image",
        ]

        let lowerUTI = uti.lowercased()
        if rawUTIs.contains(lowerUTI) { return true }
        if lowerUTI.contains("raw") { return true }
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

    /// Delete asset and return whether the user allowed it.
    private func deleteAssetWithResult(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }) { success, _ in
                continuation.resume(returning: success)
            }
        }
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
