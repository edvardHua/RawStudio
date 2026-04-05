# RAW+JPG Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an iOS app that identifies RAW+JPG paired photos in the user's photo library, provides side-by-side comparison, and allows keeping one format or splitting into two independent photos.

**Architecture:** SwiftUI views backed by an `@Observable` PhotoLibraryManager that wraps PhotoKit. The manager handles asset fetching, filtering, thumbnail caching, resource extraction, and write/delete operations. Views are decomposed into Gallery (list), Compare (detail), and shared components. No external dependencies.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, PhotoKit, iOS 17+, Xcode 26.2

**Important build notes:**
- The project uses `PBXFileSystemSynchronizedRootGroup` — files placed in `RAW+JPGSplit/` are auto-synced to the Xcode project. No manual pbxproj edits needed.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is enabled. All types are `@MainActor` by default. Use `nonisolated` explicitly where needed.
- Build with: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## File Structure

```
RAW+JPGSplit/
├── RAW_JPGSplitApp.swift          (modify — add permission request on launch)
├── ContentView.swift              (modify — replace with root navigation)
├── Models/
│   └── PhotoPair.swift            (create — data model for a RAW+JPG pair)
├── Services/
│   └── PhotoLibraryManager.swift  (create — PhotoKit wrapper, @Observable)
├── Views/
│   ├── GalleryView.swift          (create — main card list)
│   ├── PhotoCardView.swift        (create — single card in gallery)
│   ├── CompareView.swift          (create — full-screen RAW vs JPG comparison)
│   ├── ZoomableImageView.swift    (create — pinch-to-zoom image with UIKit)
│   ├── ActionBarView.swift        (create — bottom action buttons)
│   ├── BatchProgressView.swift    (create — batch operation overlay)
│   ├── ToastView.swift            (create — lightweight top toast)
│   ├── EmptyStateView.swift       (create — empty library state)
│   └── PermissionDeniedView.swift (create — permission guidance)
├── Info.plist                     (create — photo library usage description)
```

---

### Task 1: Info.plist and Photo Library Permission

**Files:**
- Create: `RAW+JPGSplit/Info.plist`
- Modify: `RAW+JPGSplit/RAW_JPGSplitApp.swift`

This task adds the required `NSPhotoLibraryUsageDescription` and sets up permission request on app launch.

- [ ] **Step 1: Create Info.plist with photo library usage description**

Create `RAW+JPGSplit/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>RAW+JPG Split needs access to your photo library to find RAW+JPG paired photos, compare them, and save separated versions.</string>
</dict>
</plist>
```

- [ ] **Step 2: Update RAW_JPGSplitApp.swift to request permission on launch**

Replace the content of `RAW+JPGSplit/RAW_JPGSplitApp.swift` with:

```swift
import SwiftUI
import Photos

@main
struct RAW_JPGSplitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Note: Permission request will be triggered by `PhotoLibraryManager` when it initializes (Task 3). The app entry point stays simple.

- [ ] **Step 3: Build to verify Info.plist is picked up**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RAW+JPGSplit/Info.plist RAW+JPGSplit/RAW_JPGSplitApp.swift
git commit -m "feat: add Info.plist with photo library usage description"
```

---

### Task 2: PhotoPair Data Model

**Files:**
- Create: `RAW+JPGSplit/Models/PhotoPair.swift`

A lightweight model representing a single RAW+JPG paired asset.

- [ ] **Step 1: Create the Models directory and PhotoPair.swift**

Create `RAW+JPGSplit/Models/PhotoPair.swift`:

```swift
import Photos
import UIKit

enum ProcessResult: Equatable {
    case keptJPG
    case keptRAW
    case split
}

@Observable
final class PhotoPair: Identifiable {
    let id: String
    let asset: PHAsset
    let jpgResource: PHAssetResource
    let rawResource: PHAssetResource
    let captureDate: Date
    let fileName: String
    let rawFormatLabel: String

    var thumbnail: UIImage?
    var processResult: ProcessResult?

    var isProcessed: Bool { processResult != nil }

    init(asset: PHAsset, jpgResource: PHAssetResource, rawResource: PHAssetResource) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.jpgResource = jpgResource
        self.rawResource = rawResource
        self.captureDate = asset.creationDate ?? Date.distantPast
        self.fileName = jpgResource.originalFilename
        self.rawFormatLabel = Self.formatLabel(for: rawResource)
        self.thumbnail = nil
        self.processResult = nil
    }

    private static func formatLabel(for resource: PHAssetResource) -> String {
        let ext = (resource.originalFilename as NSString).pathExtension.uppercased()
        switch ext {
        case "ARW": return "ARW"
        case "CR2", "CR3": return ext
        case "NEF": return "NEF"
        case "RAF": return "RAF"
        case "ORF": return "ORF"
        case "RW2": return "RW2"
        case "DNG": return "DNG"
        case "PEF": return "PEF"
        default: return "RAW"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Models/PhotoPair.swift
git commit -m "feat: add PhotoPair data model for RAW+JPG paired assets"
```

---

### Task 3: PhotoLibraryManager Service

**Files:**
- Create: `RAW+JPGSplit/Services/PhotoLibraryManager.swift`

The core service: handles permissions, fetching paired assets, thumbnail caching, resource extraction, and write/delete operations.

- [ ] **Step 1: Create the Services directory and PhotoLibraryManager.swift**

Create `RAW+JPGSplit/Services/PhotoLibraryManager.swift`:

```swift
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
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Services/PhotoLibraryManager.swift
git commit -m "feat: add PhotoLibraryManager with PhotoKit integration"
```

---

### Task 4: Permission Denied & Empty State Views

**Files:**
- Create: `RAW+JPGSplit/Views/PermissionDeniedView.swift`
- Create: `RAW+JPGSplit/Views/EmptyStateView.swift`

- [ ] **Step 1: Create PermissionDeniedView.swift**

Create `RAW+JPGSplit/Views/PermissionDeniedView.swift`:

```swift
import SwiftUI

struct PermissionDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Photo Access Required", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("RAW+JPG Split needs full access to your photo library to find and process paired photos.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    PermissionDeniedView()
}
```

- [ ] **Step 2: Create EmptyStateView.swift**

Create `RAW+JPGSplit/Views/EmptyStateView.swift`:

```swift
import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Paired Photos", systemImage: "photo.stack")
        } description: {
            Text("No RAW+JPG paired photos found. Import camera photos to your library and paired photos will appear here automatically.")
        }
    }
}

#Preview {
    EmptyStateView()
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RAW+JPGSplit/Views/PermissionDeniedView.swift RAW+JPGSplit/Views/EmptyStateView.swift
git commit -m "feat: add PermissionDeniedView and EmptyStateView"
```

---

### Task 5: Toast View

**Files:**
- Create: `RAW+JPGSplit/Views/ToastView.swift`

- [ ] **Step 1: Create ToastView.swift**

Create `RAW+JPGSplit/Views/ToastView.swift`:

```swift
import SwiftUI

struct ToastView: View {
    let message: String
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            VStack {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.top, 8)

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct ToastModifier: ViewModifier {
    let message: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ToastView(message: message, isPresented: $isPresented)
                .animation(.spring(duration: 0.4), value: isPresented)
        }
    }
}

extension View {
    func toast(message: String, isPresented: Binding<Bool>) -> some View {
        modifier(ToastModifier(message: message, isPresented: isPresented))
    }
}

#Preview {
    Text("Content")
        .toast(message: "Kept JPG · Original can be recovered from Recently Deleted", isPresented: .constant(true))
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/ToastView.swift
git commit -m "feat: add ToastView with auto-dismiss modifier"
```

---

### Task 6: Action Bar View

**Files:**
- Create: `RAW+JPGSplit/Views/ActionBarView.swift`

- [ ] **Step 1: Create ActionBarView.swift**

Create `RAW+JPGSplit/Views/ActionBarView.swift`:

```swift
import SwiftUI

struct ActionBarView: View {
    let onKeepJPG: () -> Void
    let onKeepRAW: () -> Void
    let onSplit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            actionButton(title: "Keep JPG", icon: "photo", action: onKeepJPG)
            Divider()
                .frame(height: 30)
            actionButton(title: "Keep RAW", icon: "camera.filters", action: onKeepRAW)
            Divider()
                .frame(height: 30)
            actionButton(title: "Split", icon: "rectangle.split.2x1", action: onSplit)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack {
        Spacer()
        ActionBarView(
            onKeepJPG: {},
            onKeepRAW: {},
            onSplit: {}
        )
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/ActionBarView.swift
git commit -m "feat: add ActionBarView with keep/split buttons"
```

---

### Task 7: Batch Progress View

**Files:**
- Create: `RAW+JPGSplit/Views/BatchProgressView.swift`

- [ ] **Step 1: Create BatchProgressView.swift**

Create `RAW+JPGSplit/Views/BatchProgressView.swift`:

```swift
import SwiftUI

struct BatchProgressView: View {
    let current: Int
    let total: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)

                Text("Processing \(current)/\(total)...")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    BatchProgressView(current: 3, total: 12)
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/BatchProgressView.swift
git commit -m "feat: add BatchProgressView overlay"
```

---

### Task 8: Photo Card View (Gallery List Item)

**Files:**
- Create: `RAW+JPGSplit/Views/PhotoCardView.swift`

- [ ] **Step 1: Create PhotoCardView.swift**

Create `RAW+JPGSplit/Views/PhotoCardView.swift`:

```swift
import SwiftUI

struct PhotoCardView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Thumbnail
            Group {
                if let thumbnail = pair.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(pair.fileName)
                    .font(.body)
                    .lineLimit(1)

                Text(Self.dateFormatter.string(from: pair.captureDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(pair.rawFormatLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill, in: Capsule())

                    if let result = pair.processResult {
                        Text(resultLabel(result))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(pair.isProcessed ? 0.5 : 1.0)
    }

    private func resultLabel(_ result: ProcessResult) -> String {
        switch result {
        case .keptJPG: return "Kept JPG"
        case .keptRAW: return "Kept RAW"
        case .split: return "Split"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/PhotoCardView.swift
git commit -m "feat: add PhotoCardView for gallery list items"
```

---

### Task 9: Gallery View (Main List with Batch Selection)

**Files:**
- Create: `RAW+JPGSplit/Views/GalleryView.swift`

- [ ] **Step 1: Create GalleryView.swift**

Create `RAW+JPGSplit/Views/GalleryView.swift`:

```swift
import SwiftUI

enum GalleryFilter: String, CaseIterable {
    case all = "All"
    case unprocessed = "Unprocessed"
    case processed = "Processed"
}

struct GalleryView: View {
    @Bindable var manager: PhotoLibraryManager
    @State private var filter: GalleryFilter = .unprocessed
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchConfirm = false
    @State private var pendingBatchAction: SplitAction?
    @State private var showBatchResult = false
    @State private var batchResultMessage = ""
    @State private var navigateToCompareIndex: Int?

    private var filteredPairs: [PhotoPair] {
        switch filter {
        case .all: return manager.pairs
        case .unprocessed: return manager.unprocessedPairs
        case .processed: return manager.processedPairs
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if manager.isLoading {
                    ProgressView("Scanning library...")
                } else if manager.pairs.isEmpty {
                    EmptyStateView()
                } else {
                    listContent
                }

                if manager.isBatchProcessing {
                    BatchProgressView(current: manager.batchProgress, total: manager.batchTotal)
                }
            }
            .navigationTitle("RAW+JPG")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button(selectedIDs.count == filteredPairs.count ? "Deselect All" : "Select All") {
                            if selectedIDs.count == filteredPairs.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(filteredPairs.map(\.id))
                            }
                        }
                    } else {
                        Menu {
                            Picker("Filter", selection: $filter) {
                                ForEach(GalleryFilter.allCases, id: \.self) { f in
                                    Text(f.rawValue).tag(f)
                                }
                            }
                        } label: {
                            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedIDs.removeAll()
                        }
                    }
                    .disabled(manager.pairs.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selectedIDs.isEmpty {
                    ActionBarView(
                        onKeepJPG: { confirmBatch(.keepJPG) },
                        onKeepRAW: { confirmBatch(.keepRAW) },
                        onSplit: { confirmBatch(.split) }
                    )
                }
            }
            .alert("Confirm", isPresented: $showBatchConfirm) {
                Button("Confirm", role: .destructive) {
                    executeBatch()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(batchConfirmMessage)
            }
            .alert("Done", isPresented: $showBatchResult) {
                Button("OK") {
                    isSelecting = false
                    selectedIDs.removeAll()
                }
            } message: {
                Text(batchResultMessage)
            }
            .navigationDestination(item: $navigateToCompareIndex) { index in
                CompareView(
                    manager: manager,
                    pairs: filteredPairs.filter { !$0.isProcessed },
                    startIndex: index
                )
            }
        }
    }

    private var listContent: some View {
        let grouped = manager.groupedByDate(filteredPairs)
        return List {
            ForEach(grouped, id: \.date) { section in
                Section(header: Text(section.date)) {
                    ForEach(section.pairs) { pair in
                        PhotoCardView(
                            pair: pair,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(pair.id),
                            onToggleSelect: {
                                if selectedIDs.contains(pair.id) {
                                    selectedIDs.remove(pair.id)
                                } else {
                                    selectedIDs.insert(pair.id)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                if selectedIDs.contains(pair.id) {
                                    selectedIDs.remove(pair.id)
                                } else {
                                    selectedIDs.insert(pair.id)
                                }
                            } else if !pair.isProcessed {
                                let unprocessed = filteredPairs.filter { !$0.isProcessed }
                                if let idx = unprocessed.firstIndex(where: { $0.id == pair.id }) {
                                    navigateToCompareIndex = idx
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var batchConfirmMessage: String {
        guard let action = pendingBatchAction else { return "" }
        let count = selectedIDs.count
        let actionName: String
        switch action {
        case .keepJPG: actionName = "Keep JPG for"
        case .keepRAW: actionName = "Keep RAW for"
        case .split: actionName = "Split"
        }
        return "\(actionName) \(count) photos. Original RAW+JPG paired photos will be deleted. They can be recovered from Recently Deleted."
    }

    private func confirmBatch(_ action: SplitAction) {
        pendingBatchAction = action
        showBatchConfirm = true
    }

    private func executeBatch() {
        guard let action = pendingBatchAction else { return }
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
        Task {
            let result = await manager.performBatchAction(action, on: selected)
            batchResultMessage = "Successfully processed \(result.success), failed \(result.failed)."
            showBatchResult = true
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Note: This will fail to build until CompareView is created in Task 11. Proceed to Task 10 and 11, then build all three together.

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/GalleryView.swift
git commit -m "feat: add GalleryView with list, filtering, and batch selection"
```

---

### Task 10: Zoomable Image View (UIKit-backed synchronized zoom)

**Files:**
- Create: `RAW+JPGSplit/Views/ZoomableImageView.swift`

This uses a `UIViewRepresentable` wrapping `UIScrollView` for proper pinch-to-zoom with synchronized state.

- [ ] **Step 1: Create ZoomableImageView.swift**

Create `RAW+JPGSplit/Views/ZoomableImageView.swift`:

```swift
import SwiftUI
import UIKit

struct ZoomState: Equatable {
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomState: ZoomState

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // Double tap to reset
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)

        // Sync from binding (driven by the other image's zoom)
        if !context.coordinator.isUserDriving {
            scrollView.zoomScale = zoomState.scale
            scrollView.contentOffset = zoomState.offset
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomState: $zoomState)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var zoomState: ZoomState
        var isUserDriving = false

        init(zoomState: Binding<ZoomState>) {
            _zoomState = zoomState
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isUserDriving = true
            zoomState = ZoomState(scale: scrollView.zoomScale, offset: scrollView.contentOffset)
            DispatchQueue.main.async { self.isUserDriving = false }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.isDragging || scrollView.isDecelerating else { return }
            isUserDriving = true
            zoomState = ZoomState(scale: scrollView.zoomScale, offset: scrollView.contentOffset)
            DispatchQueue.main.async { self.isUserDriving = false }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: scrollView.viewWithTag(100))
                let size = CGSize(
                    width: scrollView.bounds.width / 3.0,
                    height: scrollView.bounds.height / 3.0
                )
                let rect = CGRect(
                    origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                    size: size
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/ZoomableImageView.swift
git commit -m "feat: add ZoomableImageView with synchronized pinch-to-zoom"
```

---

### Task 11: Compare View (Full-screen RAW vs JPG Comparison)

**Files:**
- Create: `RAW+JPGSplit/Views/CompareView.swift`

- [ ] **Step 1: Create CompareView.swift**

Create `RAW+JPGSplit/Views/CompareView.swift`:

```swift
import SwiftUI

struct CompareView: View {
    @Bindable var manager: PhotoLibraryManager
    let pairs: [PhotoPair]
    let startIndex: Int

    @State private var currentIndex: Int
    @State private var jpgImage: UIImage?
    @State private var rawImage: UIImage?
    @State private var isLoadingImages = true
    @State private var zoomState = ZoomState()
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var errorMessage: String?
    @State private var showError = false
    @Environment(\.dismiss) private var dismiss

    init(manager: PhotoLibraryManager, pairs: [PhotoPair], startIndex: Int) {
        self.manager = manager
        self.pairs = pairs
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
    }

    private var currentPair: PhotoPair? {
        guard currentIndex >= 0 && currentIndex < pairs.count else { return nil }
        return pairs[currentIndex]
    }

    private var isLandscape: Bool {
        guard let pair = currentPair else { return false }
        let w = CGFloat(pair.asset.pixelWidth)
        let h = CGFloat(pair.asset.pixelHeight)
        return w > h
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoadingImages {
                ProgressView("Loading images...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let jpg = jpgImage, let raw = rawImage {
                compareContent(jpg: jpg, raw: raw)
            }
        }
        .navigationTitle("\(currentIndex + 1) / \(pairs.count)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if currentPair != nil && !isLoadingImages {
                ActionBarView(
                    onKeepJPG: { performAction(.keepJPG) },
                    onKeepRAW: { performAction(.keepRAW) },
                    onSplit: { performAction(.split) }
                )
            }
        }
        .toast(message: toastMessage, isPresented: $showToast)
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .gesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    if zoomState.scale <= 1.0 {
                        if value.translation.width < -50 && currentIndex < pairs.count - 1 {
                            navigateTo(currentIndex + 1)
                        } else if value.translation.width > 50 && currentIndex > 0 {
                            navigateTo(currentIndex - 1)
                        }
                    }
                }
        )
        .task {
            await loadImages()
        }
    }

    @ViewBuilder
    private func compareContent(jpg: UIImage, raw: UIImage) -> some View {
        if isLandscape {
            // Landscape: vertical stack (top/bottom)
            VStack(spacing: 1) {
                imagePanel(image: raw, label: "RAW")
                imagePanel(image: jpg, label: "JPG")
            }
        } else {
            // Portrait: horizontal stack (left/right)
            HStack(spacing: 1) {
                imagePanel(image: raw, label: "RAW")
                imagePanel(image: jpg, label: "JPG")
            }
        }
    }

    private func imagePanel(image: UIImage, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            ZoomableImageView(image: image, zoomState: $zoomState)

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(8)
        }
    }

    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        do {
            async let jpgLoad = manager.loadFullImage(for: pair.jpgResource)
            async let rawLoad = manager.loadFullImage(for: pair.rawResource)
            let (jpg, raw) = try await (jpgLoad, rawLoad)
            jpgImage = jpg
            rawImage = raw
            zoomState = ZoomState()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isLoadingImages = false
    }

    private func performAction(_ action: SplitAction) {
        guard let pair = currentPair else { return }
        Task {
            do {
                try await manager.performAction(action, on: pair)
                let actionLabel: String
                switch action {
                case .keepJPG: actionLabel = "Kept JPG"
                case .keepRAW: actionLabel = "Kept RAW"
                case .split: actionLabel = "Split into two photos"
                }
                toastMessage = "\(actionLabel) · Original can be recovered from Recently Deleted"
                withAnimation { showToast = true }

                // Move to next unprocessed or dismiss
                try? await Task.sleep(for: .seconds(1.5))
                moveToNextOrDismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func moveToNextOrDismiss() {
        let remaining = pairs.filter { !$0.isProcessed }
        if remaining.isEmpty {
            dismiss()
            return
        }
        // Try to stay at same index or go to next valid one
        let nextIndex = min(currentIndex, remaining.count - 1)
        navigateTo(nextIndex)
    }

    private func navigateTo(_ index: Int) {
        currentIndex = index
        Task {
            await loadImages()
        }
    }
}
```

- [ ] **Step 2: Build the full project (Tasks 9, 10, 11 together)**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/Views/CompareView.swift
git commit -m "feat: add CompareView with adaptive layout and synchronized zoom"
```

---

### Task 12: Wire Up ContentView and App Root

**Files:**
- Modify: `RAW+JPGSplit/ContentView.swift`

- [ ] **Step 1: Replace ContentView with root routing logic**

Replace the content of `RAW+JPGSplit/ContentView.swift` with:

```swift
import SwiftUI

struct ContentView: View {
    @State private var manager = PhotoLibraryManager()

    var body: some View {
        Group {
            switch manager.permissionStatus {
            case .notDetermined:
                ProgressView("Requesting access...")
                    .task {
                        await manager.requestPermission()
                    }
            case .authorized:
                GalleryView(manager: manager)
                    .task {
                        await manager.fetchPairedAssets()
                    }
            case .denied:
                PermissionDeniedView()
            }
        }
        .onAppear {
            manager.checkPermission()
        }
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: Build the full project**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RAW+JPGSplit/ContentView.swift
git commit -m "feat: wire up ContentView with permission flow and gallery"
```

---

### Task 13: Final Build Verification & Cleanup

**Files:**
- All files from previous tasks

- [ ] **Step 1: Full clean build**

Run: `xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 16' clean build 2>&1 | tail -10`

Expected: BUILD SUCCEEDED with 0 warnings (or only non-critical warnings)

- [ ] **Step 2: Fix any build errors or warnings**

Address any compiler errors or warnings found in step 1. Common issues to watch for:
- Swift 6 strict concurrency warnings (add `@Sendable`, `nonisolated`, or `sending` as needed)
- Missing `@preconcurrency import` for PhotoKit types

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve build warnings and strict concurrency issues"
```
