import Photos
import UIKit
import SwiftUI

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
    case deletionDenied

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let detail):
            return "Failed to extract photo data: \(detail)"
        case .writeFailed(let detail):
            return "Failed to save photo: \(detail)"
        case .deletionDenied:
            return "Photos were saved but the original could not be deleted. You can delete it manually from Photos."
        }
    }
}

@Observable
final class PhotoLibraryManager {
    var permissionStatus: PhotoPermissionStatus = .notDetermined
    var pairs: [PhotoPair] = []
    var isLoading: Bool = false

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

    // MARK: - Fetch Paired Assets

    func fetchPairedAssets() async {
        isLoading = true
        defer { isLoading = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: fetchOptions)
        var foundPairs: [PhotoPair] = []

        result.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            var jpgResource: PHAssetResource?
            var rawResource: PHAssetResource?

            for resource in resources {
                if resource.type == .photo {
                    jpgResource = resource
                } else if resource.type == .alternatePhoto {
                    rawResource = resource
                }
            }

            if let jpg = jpgResource, let raw = rawResource {
                let pair = PhotoPair(asset: asset, jpgResource: jpg, rawResource: raw)
                foundPairs.append(pair)
            }
        }

        self.pairs = foundPairs
        await loadThumbnails()
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        for pair in pairs where pair.thumbnail == nil {
            let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                cachingManager.requestImage(
                    for: pair.asset,
                    targetSize: thumbnailSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded {
                        continuation.resume(returning: image)
                    }
                }
            }
            pair.thumbnail = image
        }
    }

    // MARK: - Load Full Images for Compare

    func loadFullImage(for resource: PHAssetResource) async throws -> UIImage {
        let data = try await extractResourceData(for: resource)
        guard let image = UIImage(data: data) else {
            throw SplitError.extractionFailed("Cannot decode image data for \(resource.originalFilename)")
        }
        return image
    }

    // MARK: - Core Operations

    func performAction(_ action: SplitAction, on pair: PhotoPair) async throws {
        switch action {
        case .keepJPG:
            let jpgData = try await extractResourceData(for: pair.jpgResource)
            try await saveAsNewAsset(data: jpgData, resourceType: .photo, originalFilename: pair.jpgResource.originalFilename)
            try await deleteAsset(pair.asset)
            pair.processResult = .keptJPG

        case .keepRAW:
            let rawData = try await extractResourceData(for: pair.rawResource)
            try await saveAsNewAsset(data: rawData, resourceType: .photo, originalFilename: pair.rawResource.originalFilename)
            try await deleteAsset(pair.asset)
            pair.processResult = .keptRAW

        case .split:
            let jpgData = try await extractResourceData(for: pair.jpgResource)
            let rawData = try await extractResourceData(for: pair.rawResource)
            try await saveAsNewAsset(data: jpgData, resourceType: .photo, originalFilename: pair.jpgResource.originalFilename)
            try await saveAsNewAsset(data: rawData, resourceType: .photo, originalFilename: pair.rawResource.originalFilename)
            try await deleteAsset(pair.asset)
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

    private func deleteAsset(_ asset: PHAsset) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                }) { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: SplitError.deletionDenied)
                    }
                }
            }
        } catch is SplitError {
            throw SplitError.deletionDenied
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
    func groupedByDate(_ pairsToGroup: [PhotoPair]) -> [(date: String, pairs: [PhotoPair])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none

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
