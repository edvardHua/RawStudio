# Batch Export Options Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RAW+JPG / RAW 筛选下把 5 个固定按钮合并成 Export + Delete，点 Export 弹一个 sheet，让用户选 source × format × HDR + 可选新相册。

**Architecture:** 新增 `ExportOptions` model + `ExportOptionsSheet` view（NavigationStack + `.ultraThinMaterial` 容器，与 `AlbumPickerView` 同款）+ PhotoLibraryManager 加 `createAlbum`、`exportOne` 路由、`performExportBatch`、改造 `saveAsNewAsset` 加 `addToAlbum` 参数。8 个 source × format × HDR 组合按矩阵派发到已有/新增方法。

**Tech Stack:** Swift 5 / SwiftUI / Photos.framework / CoreImage / ImageIO / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-19-batch-export-options-sheet-design.md`

**项目背景：**
- 类 `@Observable final class PhotoLibraryManager`，MainActor 默认隔离
- 真机：iPhone 15 Pro Max (`E71BC21F-DC20-5570-9A10-6F3CF3CA5B28`)
- 模拟器：iPhone 17 Pro (`DFABFFCE-4305-46F5-B38B-35BFCD1EB986`)
- LSP/SourceKit 在 PBXFileSystemSynchronizedRootGroup 项目里有恼人误报，**只信 xcodebuild 输出**
- 已有可复用方法：`exportAdaptiveHDR(for:)`、`exportUltraHDRJPEG(for:)`、`exportUltraHDRJPEGFromImage(for:)`、`isHDRImage(data:)`、`extractResourceData(for:)`、`extractImageProperties(from:)`、`propertiesWithNormalizedOrientation(_:)`、`injectMetadata(into:properties:)`

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/ExportOptions.swift` | **新文件**：ExportOptions struct + Source/Format enum |
| `RawStudio/Views/ExportOptionsSheet.swift` | **新文件**：sheet UI |
| `RawStudio/Services/PhotoLibraryManager.swift` | 加 `createAlbum`、`exportOne`、`exportRAWAsSDR`、`exportOriginal`、`performExportBatch`；改造 `saveAsNewAsset` 加可选 `addToAlbum` 参数 |
| `RawStudio/Views/GalleryView.swift` | batch toolbar switch 改写；加 `showExportSheet` state + `.sheet` modifier + `executeExport`；删 `confirmBatch`/`confirmBatchHDR`/`executeBatch`/`pendingBatchAction`/`pendingBatchHDRType`（dead code） |

---

## Task 1: `ExportOptions` model

**Files:**
- Create: `RawStudio/Models/ExportOptions.swift`

- [ ] **Step 1: 创建新文件**

```swift
import Foundation

struct ExportOptions: Equatable {
    enum Source: Equatable {
        case original    // 保留原图
        case fromRaw     // 从 RAW 渲染
    }

    enum Format: Equatable {
        case jpg
        case heic
    }

    var source: Source
    var format: Format
    var useHDR: Bool
    var newAlbumName: String?    // nil = 不创建相册
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Models/ExportOptions.swift
git commit -m "$(cat <<'EOF'
feat(model): add ExportOptions struct for batch export sheet

Carries user choices from the new ExportOptionsSheet to
performExportBatch: source (original/fromRaw), format (jpg/heic),
HDR toggle, and optional new album name.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `PhotoLibraryManager` — `createAlbum` + `saveAsNewAsset` 加 `addToAlbum`

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift`（改造 saveAsNewAsset；在 Delete 区附近加 createAlbum）

- [ ] **Step 1: 改造 `saveAsNewAsset` 加可选 `addToAlbum`**

Grep 定位：

```bash
grep -n "private func saveAsNewAsset" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Services/PhotoLibraryManager.swift
```

预期看到 1 个 hit（约 line 688）。当前函数：

```swift
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
```

整段替换为：

```swift
    private func saveAsNewAsset(
        data: Data,
        resourceType: PHAssetResourceType,
        originalFilename: String,
        addToAlbum album: PHAssetCollection? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = originalFilename
                creationRequest.addResource(with: resourceType, data: data, options: options)

                if let album, let placeholder = creationRequest.placeholderForCreatedAsset {
                    let albumChange = PHAssetCollectionChangeRequest(for: album)
                    albumChange?.addAssets([placeholder] as NSArray)
                }
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SplitError.writeFailed(error?.localizedDescription ?? "Unknown error"))
                }
            }
        }
    }
```

> 既有调用方都没传 `addToAlbum`，默认 nil → 行为不变。

- [ ] **Step 2: 新增 `createAlbum` 方法**

在 PhotoLibraryManager 类的 `// MARK: - Delete` 区附近（或紧贴 `deleteAssets(_:)` 函数下方）插入：

```bash
grep -n "// MARK: - Delete" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Services/PhotoLibraryManager.swift
```

预期约 line 227。在 `deleteAssets(_:)` 函数的右大括号 `}` 下面（在下一个 `// MARK:` 前）插入：

```swift

    /// 新建一个 user album。失败抛 SplitError.writeFailed。
    func createAlbum(name: String) async throws -> PHAssetCollection {
        var placeholder: PHObjectPlaceholder?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                placeholder = request.placeholderForCreatedAssetCollection
            } completionHandler: { ok, err in
                if ok {
                    cont.resume()
                } else {
                    cont.resume(throwing: SplitError.writeFailed(err?.localizedDescription ?? "Create album failed"))
                }
            }
        }
        guard let id = placeholder?.localIdentifier,
              let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw SplitError.writeFailed("Created album not found after change")
        }
        return collection
    }
```

- [ ] **Step 3: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
feat(library): saveAsNewAsset gains addToAlbum + new createAlbum

- saveAsNewAsset(... addToAlbum: PHAssetCollection? = nil)
  Default nil keeps all existing callers unchanged. When non-nil,
  the new asset is added to the album in the same performChanges
  block via placeholderForCreatedAsset.
- createAlbum(name:) async throws -> PHAssetCollection
  Wraps creationRequestForAssetCollection + fetches the resulting
  PHAssetCollection by localIdentifier.

Both consumed by performExportBatch in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `PhotoLibraryManager` — SDR render + transcode + 路由 + 批量

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift`（在 exportUltraHDRJPEGFromImage 函数下方追加 4 个新方法）

- [ ] **Step 1: 定位插入点**

```bash
grep -n "func exportUltraHDRJPEGFromImage\|func performAction" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Services/PhotoLibraryManager.swift
```

预期 `exportUltraHDRJPEGFromImage(for:)` 约 line 524、`performAction` 约 line 551。新代码插在 `exportUltraHDRJPEGFromImage` 的 `}` 下面、`performAction` 上面。

- [ ] **Step 2: 插入 SDR RAW 渲染 + 原图转码 + 路由 + 批量**

在 Step 1 定位的插入点（`exportUltraHDRJPEGFromImage` 函数 `}` 之后）插入下面整段：

```swift

    // MARK: - Batch Export Router

    /// 从 RAW 渲染 SDR JPEG 或 HEIC（不带 HDR），保留原始 EXIF。
    private func exportRAWAsSDR(
        for pair: PhotoPair,
        format: ExportOptions.Format,
        addToAlbum album: PHAssetCollection?
    ) async throws {
        guard let rawResource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
        let rawData = try await extractResourceData(for: rawResource)
        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(rawResource.originalFilename)")
        }
        // SDR: extendedDynamicRangeAmount 默认为 0
        guard let sdrImage = rawFilter.outputImage else {
            throw SplitError.extractionFailed("Cannot render SDR image from RAW")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format == .jpg ? "jpg" : "heic")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let opts: [CIImageRepresentationOption: Any] = [qualityKey: 0.92]

        switch format {
        case .jpg:
            try ciContext.writeJPEGRepresentation(of: sdrImage, to: tempURL, colorSpace: colorSpace, options: opts)
        case .heic:
            try ciContext.writeHEIFRepresentation(of: sdrImage, to: tempURL, format: .RGBA8, colorSpace: colorSpace, options: opts)
        }

        // 注入原 EXIF
        let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: rawData))
        let rawFileData = try Data(contentsOf: tempURL)
        let finalData = Self.injectMetadata(into: tempURL, properties: exifProperties) ?? rawFileData

        let baseName = (rawResource.originalFilename as NSString).deletingPathExtension
        let outName = baseName + "." + (format == .jpg ? "jpg" : "heic")
        try await saveAsNewAsset(data: finalData, resourceType: .photo, originalFilename: outName, addToAlbum: album)
    }

    /// 保留原图路径：根据 (format, useHDR) 与原图实际格式/HDR 状态决定 save-as-is / 转码 / HDR fallback。
    private func exportOriginal(
        for pair: PhotoPair,
        format: ExportOptions.Format,
        useHDR: Bool,
        addToAlbum album: PHAssetCollection?
    ) async throws {
        guard let jpgResource = pair.jpgResource else {
            throw SplitError.extractionFailed("No original image")
        }
        let data = try await extractResourceData(for: jpgResource)
        let sourceUTI = jpgResource.uniformTypeIdentifier.lowercased()
        let sourceIsHEIC = sourceUTI.contains("heic") || sourceUTI.contains("heif")
        let sourceIsJPEG = sourceUTI.contains("jpeg") || sourceUTI.contains("jpg")
        let sourceIsHDR = Self.isHDRImage(data: data)

        // 路径 A：HDR ON + 原图 HDR + 目标 JPG → Ultra HDR JPEG
        if useHDR && sourceIsHDR && format == .jpg {
            let baseName = (jpgResource.originalFilename as NSString).deletingPathExtension
            let outName = baseName + "_UltraHDR.jpg"
            let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: data))
            guard let ciImage = CIImage(data: data, options: [.expandToHDR: true]) else {
                throw SplitError.extractionFailed("Cannot decode image as HDR")
            }
            let writer = UltraHDRWriter(ciContext: ciContext)
            let ultraHDRData = try writer.writeUltraHDRJPEG(
                sdrImage: ciImage,
                hdrImage: ciImage,
                exifProperties: exifProperties
            )
            try await saveAsNewAsset(data: ultraHDRData, resourceType: .photo, originalFilename: outName, addToAlbum: album)
            return
        }

        // 路径 B：HDR ON + 原图 HDR + 目标 HEIC → save as-is（HDR 已 baked in）
        if useHDR && sourceIsHDR && format == .heic && sourceIsHEIC {
            try await saveAsNewAsset(data: data, resourceType: .photo, originalFilename: jpgResource.originalFilename, addToAlbum: album)
            return
        }

        // 路径 C：格式与原图一致 → save as-is（fastest）
        if (format == .jpg && sourceIsJPEG) || (format == .heic && sourceIsHEIC) {
            try await saveAsNewAsset(data: data, resourceType: .photo, originalFilename: jpgResource.originalFilename, addToAlbum: album)
            return
        }

        // 路径 D：需要转码（HEIC↔JPG），HDR fallback 到 SDR
        guard let ciImage = CIImage(data: data) else {
            throw SplitError.extractionFailed("Cannot decode source image")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format == .jpg ? "jpg" : "heic")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let opts: [CIImageRepresentationOption: Any] = [qualityKey: 0.92]

        switch format {
        case .jpg:
            try ciContext.writeJPEGRepresentation(of: ciImage, to: tempURL, colorSpace: colorSpace, options: opts)
        case .heic:
            try ciContext.writeHEIFRepresentation(of: ciImage, to: tempURL, format: .RGBA8, colorSpace: colorSpace, options: opts)
        }

        let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: data))
        let fileData = try Data(contentsOf: tempURL)
        let finalData = Self.injectMetadata(into: tempURL, properties: exifProperties) ?? fileData

        let baseName = (jpgResource.originalFilename as NSString).deletingPathExtension
        let outName = baseName + "." + (format == .jpg ? "jpg" : "heic")
        try await saveAsNewAsset(data: finalData, resourceType: .photo, originalFilename: outName, addToAlbum: album)
    }

    /// 单张导出总入口；按 options 派发到具体路径。
    func exportOne(
        _ pair: PhotoPair,
        options: ExportOptions,
        addToAlbum album: PHAssetCollection?
    ) async throws {
        switch (options.source, options.format, options.useHDR) {
        case (.fromRaw, .jpg, true):
            try await exportUltraHDRJPEG(for: pair)
            // 注：exportUltraHDRJPEG 当前不带 addToAlbum；下一 step 会补
            if let album { try await addLastSavedAssetToAlbum(album) }
            // 上一行有问题：PhotoKit 没有"上次保存的资产"概念。
            // 真正的解法：见 Step 3 — 先把 exportUltraHDRJPEG / exportAdaptiveHDR /
            // exportUltraHDRJPEGFromImage 三个 HDR 函数也加 addToAlbum 参数

        case (.fromRaw, .heic, true):
            try await exportAdaptiveHDR(for: pair)
            if let album { try await addLastSavedAssetToAlbum(album) }

        case (.fromRaw, _, false):
            try await exportRAWAsSDR(for: pair, format: options.format, addToAlbum: album)

        case (.original, _, _):
            try await exportOriginal(for: pair, format: options.format, useHDR: options.useHDR, addToAlbum: album)
        }
    }

    /// 批量导出。返回 (成功数, 失败数, 创建相册的错误信息)。
    /// 即使相册创建失败也会继续导出（不加入相册）。
    func performExportBatch(
        _ pairs: [PhotoPair],
        options: ExportOptions
    ) async -> (success: Int, failed: Int, albumError: String?) {
        isBatchProcessing = true
        batchTotal = pairs.count
        batchProgress = 0
        defer { isBatchProcessing = false }

        var album: PHAssetCollection? = nil
        var albumError: String? = nil
        if let name = options.newAlbumName, !name.isEmpty {
            do {
                album = try await createAlbum(name: name)
            } catch {
                albumError = error.localizedDescription
                // 不中止；继续导出但不加入相册
            }
        }

        var success = 0
        var failed = 0
        for pair in pairs {
            do {
                try await exportOne(pair, options: options, addToAlbum: album)
                success += 1
            } catch {
                failed += 1
            }
            batchProgress += 1
        }
        return (success, failed, albumError)
    }
```

⚠️ **上面的 `exportOne` 代码有问题** — `addLastSavedAssetToAlbum` 是占位（PhotoKit 没有此概念）。Step 3 修复这个：把三个 HDR 函数（`exportAdaptiveHDR` / `exportUltraHDRJPEG` / `exportUltraHDRJPEGFromImage`）也加 `addToAlbum` 参数透传。

- [ ] **Step 3: 给三个 HDR 函数加 `addToAlbum` 参数 + 简化 `exportOne`**

定位三个函数：

```bash
grep -n "func exportAdaptiveHDR\|func exportUltraHDRJPEG(\|func exportUltraHDRJPEGFromImage" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Services/PhotoLibraryManager.swift
```

**`exportAdaptiveHDR`** — 当前签名：
```swift
func exportAdaptiveHDR(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
```
改为：
```swift
func exportAdaptiveHDR(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams(), addToAlbum album: PHAssetCollection? = nil) async throws {
```
找到函数末尾的 `saveAsNewAsset(data: finalData, resourceType: .photo, originalFilename: ...)` 调用，加 `addToAlbum: album` 参数。

**`exportUltraHDRJPEG`** — 当前签名：
```swift
func exportUltraHDRJPEG(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
```
改为：
```swift
func exportUltraHDRJPEG(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams(), addToAlbum album: PHAssetCollection? = nil) async throws {
```
函数末尾 `saveAsNewAsset` 调用加 `addToAlbum: album`。

**`exportUltraHDRJPEGFromImage`** — 当前签名：
```swift
func exportUltraHDRJPEGFromImage(for pair: PhotoPair) async throws {
```
改为：
```swift
func exportUltraHDRJPEGFromImage(for pair: PhotoPair, addToAlbum album: PHAssetCollection? = nil) async throws {
```
函数末尾 `saveAsNewAsset` 调用加 `addToAlbum: album`。

> 三个函数都用 default `nil`，旧调用方零改。

现在修复 `exportOne`：

```bash
grep -n "func exportOne\|addLastSavedAssetToAlbum" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Services/PhotoLibraryManager.swift
```

把 Step 2 写的 `exportOne` 整段替换为：

```swift
    /// 单张导出总入口；按 options 派发到具体路径。
    func exportOne(
        _ pair: PhotoPair,
        options: ExportOptions,
        addToAlbum album: PHAssetCollection?
    ) async throws {
        switch (options.source, options.format, options.useHDR) {
        case (.fromRaw, .jpg, true):
            try await exportUltraHDRJPEG(for: pair, addToAlbum: album)

        case (.fromRaw, .heic, true):
            try await exportAdaptiveHDR(for: pair, addToAlbum: album)

        case (.fromRaw, _, false):
            try await exportRAWAsSDR(for: pair, format: options.format, addToAlbum: album)

        case (.original, _, _):
            try await exportOriginal(for: pair, format: options.format, useHDR: options.useHDR, addToAlbum: album)
        }
    }
```

也删掉 `exportOriginal` 内部对 `exportUltraHDRJPEGFromImage` 的复制粘贴代码（路径 A），改用直接调函数：

把 Step 2 写的 `exportOriginal` 函数的"路径 A"块（约 18 行，从 `if useHDR && sourceIsHDR && format == .jpg {` 到下个 `// 路径 B`）：

```swift
        // 路径 A：HDR ON + 原图 HDR + 目标 JPG → Ultra HDR JPEG
        if useHDR && sourceIsHDR && format == .jpg {
            let baseName = (jpgResource.originalFilename as NSString).deletingPathExtension
            let outName = baseName + "_UltraHDR.jpg"
            let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: data))
            guard let ciImage = CIImage(data: data, options: [.expandToHDR: true]) else {
                throw SplitError.extractionFailed("Cannot decode image as HDR")
            }
            let writer = UltraHDRWriter(ciContext: ciContext)
            let ultraHDRData = try writer.writeUltraHDRJPEG(
                sdrImage: ciImage,
                hdrImage: ciImage,
                exifProperties: exifProperties
            )
            try await saveAsNewAsset(data: ultraHDRData, resourceType: .photo, originalFilename: outName, addToAlbum: album)
            return
        }
```

整段替换为：

```swift
        // 路径 A：HDR ON + 原图 HDR + 目标 JPG → 直接复用 exportUltraHDRJPEGFromImage
        if useHDR && sourceIsHDR && format == .jpg {
            try await exportUltraHDRJPEGFromImage(for: pair, addToAlbum: album)
            return
        }
```

- [ ] **Step 4: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

如果遇到 `CIImageRepresentationOption' has no member 'init(rawValue:)'` — Swift 5 该 API 应可用；报 BLOCKED。

- [ ] **Step 5: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
feat(library): batch export router + SDR/transcode paths

- exportRAWAsSDR(for:format:addToAlbum:) — CIRAWFilter render to
  SDR JPEG/HEIC (EXIF preserved via injectMetadata)
- exportOriginal(for:format:useHDR:addToAlbum:) — handles 4 paths:
  Ultra HDR JPEG (delegate), save HDR HEIC as-is, save as-is when
  format matches, transcode HEIC↔JPG via CIImage
- exportOne(_,options:,addToAlbum:) — switch dispatch on
  source × format × HDR (8 combinations)
- performExportBatch(_,options:) — creates album (best-effort),
  iterates with progress, returns (success, failed, albumError)
- Three existing HDR exports gain optional addToAlbum param (default
  nil keeps callers intact)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `ExportOptionsSheet` view

**Files:**
- Create: `RawStudio/Views/ExportOptionsSheet.swift`

- [ ] **Step 1: 创建新文件**

```swift
import SwiftUI

struct ExportOptionsSheet: View {
    let selectedCount: Int
    let filter: SourceFilter
    let onCancel: () -> Void
    let onConfirm: (ExportOptions) -> Void

    @State private var source: ExportOptions.Source = .original
    @State private var format: ExportOptions.Format = .jpg
    @State private var useHDR: Bool = false
    @State private var saveToNewAlbum: Bool = false
    @State private var albumName: String = ExportOptionsSheet.defaultAlbumName()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Source — 仅 RAW+JPG 筛选显示
                    if filter == .rawJPGPairs {
                        sectionGroup(title: String(localized: "Source")) {
                            Picker("", selection: $source) {
                                Text("Keep Original").tag(ExportOptions.Source.original)
                                Text("Render from RAW").tag(ExportOptions.Source.fromRaw)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    // Format
                    sectionGroup(title: String(localized: "Format")) {
                        Picker("", selection: $format) {
                            Text("JPG").tag(ExportOptions.Format.jpg)
                            Text("HEIC").tag(ExportOptions.Format.heic)
                        }
                        .pickerStyle(.segmented)
                    }

                    // HDR
                    sectionGroup(title: String(localized: "HDR")) {
                        Toggle(isOn: $useHDR) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Export as HDR")
                                    .font(.body)
                                Text("Ultra HDR JPEG / Adaptive HEIC")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Save To
                    sectionGroup(title: String(localized: "Save To")) {
                        VStack(spacing: 12) {
                            Toggle(String(localized: "Save to New Album"), isOn: $saveToNewAlbum)
                            if saveToNewAlbum {
                                TextField(String(localized: "Album Name"), text: $albumName)
                                    .textFieldStyle(.roundedBorder)
                                    .submitLabel(.done)
                            }
                        }
                    }

                    // Primary button
                    Button {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalAlbumName: String? = saveToNewAlbum
                            ? (trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
                            : nil
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            newAlbumName: finalAlbumName
                        ))
                    } label: {
                        Text("Export \(selectedCount) Photos")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle(String(localized: "Export Options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func sectionGroup<Content: View>(
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        }
    }

    private static func defaultAlbumName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Export \(formatter.string(from: Date()))"
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

注：SwiftUI 会警告 `Picker("",...)` 空字符串 — 那是 a11y label，pickerStyle segmented 时不显示，可以接受。如果 Swift 编译器抱怨，用 `String(localized: "Source") as String` 等命名 label。

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Views/ExportOptionsSheet.swift
git commit -m "$(cat <<'EOF'
feat(view): ExportOptionsSheet UI for batch export

NavigationStack + ScrollView sheet matching AlbumPickerView's
template. Custom sectionGroup helper renders header + .ultraThinMaterial
rounded container per section, matching the app's liquid-glass
vocabulary. Source row hidden in RAW Only mode. Primary action
returns ExportOptions to caller via onConfirm.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `GalleryView` — toolbar + sheet + executeExport + 清理 dead code

**Files:**
- Modify: `RawStudio/Views/GalleryView.swift`

- [ ] **Step 1: 添加 `showExportSheet` state**

定位现有 batch state 声明：

```bash
grep -n "@State private var showBatchConfirm\|@State private var pendingBatchAction\|@State private var pendingBatchHDRType" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

预期看到 3 行。在 `@State private var showBatchConfirm = false` **下面**追加一行：

```swift
    @State private var showExportSheet = false
```

- [ ] **Step 2: 重写 `batchActionCapsules`**

定位：

```bash
grep -n "private var batchActionCapsules" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

整个 `private var batchActionCapsules: some View { ... }` 函数（约 14 行体）替换为：

```swift
    private var batchActionCapsules: some View {
        HStack(spacing: 10) {
            switch sourceFilter {
            case .all:
                deleteCapsule { confirmBatchDelete() }
            case .rawJPGPairs, .rawOnly:
                batchCapsule(icon: "square.and.arrow.up", label: "Export") {
                    showExportSheet = true
                }
                deleteCapsule { confirmBatchDelete() }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
```

- [ ] **Step 3: 加 `.sheet` modifier 到 NavigationStack 体**

定位 alert/sheet modifier 群（与 `.alert("Confirm", isPresented: $showBatchConfirm)` 同区）：

```bash
grep -n ".alert(\"Confirm\", isPresented" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

在该 `.alert("Confirm",...)` modifier **下面**插入：

```swift
            .sheet(isPresented: $showExportSheet) {
                ExportOptionsSheet(
                    selectedCount: selectedIDs.count,
                    filter: sourceFilter,
                    onCancel: { showExportSheet = false },
                    onConfirm: { options in
                        showExportSheet = false
                        executeExport(options: options)
                    }
                )
            }
```

- [ ] **Step 4: 新增 `executeExport` 函数**

定位现有 `confirmBatchDelete`：

```bash
grep -n "private func confirmBatchDelete" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

在该函数的 `}` 下面插入：

```swift

    private func executeExport(options: ExportOptions) {
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task {
            let result = await manager.performExportBatch(selected, options: options)
            var msg = String(localized: "Successfully exported \(result.success), failed \(result.failed).")
            if let err = result.albumError {
                msg += "\n" + String(localized: "Album creation failed: \(err)")
            }
            batchResultMessage = msg
            showBatchResult = true
        }
    }
```

- [ ] **Step 5: 删除 dead code — `confirmBatch`/`confirmBatchHDR`/`executeBatch`/相关 state**

新 toolbar 完全不调用旧函数。删除：

a. **State 变量**：删除 `@State private var pendingBatchAction: SplitAction?` 和 `@State private var pendingBatchHDRType: String?`（grep 确认无其它使用）：

```bash
grep -n "pendingBatchAction\|pendingBatchHDRType" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

预期：删除 2 个 `@State` 声明、删除 `.alert("Confirm", isPresented: $showBatchConfirm)` 整段（依赖这些 state）、删除 `confirmBatch`、`confirmBatchHDR`、`executeBatch`、`batchConfirmMessage` 整段。

b. **删除 `.alert("Confirm", isPresented: $showBatchConfirm)` modifier 整段**（含 `Button("Confirm")` `Button("Cancel")` 和 `message: Text(batchConfirmMessage)`）—— 这套用户确认 alert 仅服务于旧的 confirmBatch/confirmBatchHDR；新 export 用 sheet，新 delete 用系统原生 alert，都不用这套。

c. **删除 `@State private var showBatchConfirm = false`**（grep 确认不再被引用后）。

d. **删除 `private var batchConfirmMessage: String { ... }` 计算属性**（依赖 pendingBatchAction/HDR）。

e. **删除 `private func confirmBatch(_:)`、`confirmBatchHDR(_:)`、`executeBatch()`** 三个函数。

最终 grep 验证无遗留：

```bash
grep -n "pendingBatchAction\|pendingBatchHDRType\|confirmBatch\b\|confirmBatchHDR\|executeBatch\|showBatchConfirm\|batchConfirmMessage" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

预期：仅剩 `confirmBatchDelete`（含 "confirmBatch" 子串）。其它全删。

- [ ] **Step 6: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

如果 dead code 删多了某个外部仍引用的标识，会报 undefined。grep 一遍源码确认。

- [ ] **Step 7: Commit**

```bash
git add RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(gallery): replace 5 batch buttons with Export + Delete, wire sheet

- RAW+JPG / RAW filters now show [Export] [Delete] (was Save JPG /
  Save RAW / HDR / HDR HEIF / HDR JPEG depending on filter)
- Tap Export → ExportOptionsSheet (presentationDetents medium/large)
- onConfirm dispatches manager.performExportBatch
- Removed dead code: confirmBatch, confirmBatchHDR, executeBatch,
  pendingBatchAction, pendingBatchHDRType, showBatchConfirm,
  batchConfirmMessage, and the .alert("Confirm") modifier — all
  superseded by the sheet + native PHPhotoLibrary delete alert.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 真机肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: Build for device + 装机**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/RawStudio-device-export \
  -allowProvisioningUpdates build 2>&1 | tail -5

xcrun devicectl list devices 2>&1 | grep "Edvardzeng"

# 如果 connected：
xcrun devicectl device install app --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 \
  /tmp/RawStudio-device-export/Build/Products/Debug-iphoneos/RawStudio.app
xcrun devicectl device process launch --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 com.edz.RawStudio
```

> 设备 unavailable 时让用户解锁/插紧 USB；或者 Xcode → Window → Devices and Simulators → 选设备 → "+" 装 `.app`

- [ ] **Step 2: 验证项**

**A. Toolbar 状态：**
- All 筛选选 N 张 → 底部只 Delete（不变）
- RAW+JPG 筛选选 N 张 → 底部 **Export + Delete** 两个胶囊
- RAW 筛选选 N 张 → 底部 **Export + Delete**

**B. ExportOptionsSheet UI：**
- 标题 "Export Options"，左上 Cancel
- RAW+JPG：4 个 section（Source / Format / HDR / Save To）+ 底部主按钮 "Export N Photos"
- RAW：3 个 section（缺 Source 行）
- Save to New Album toggle 打开 → 显示输入框，预填 `Export YYYY-MM-DD HH:mm`

**C. 8 组合（RAW+JPG 模式选 3 张测）：**

| Source | Format | HDR | 预期 |
|---|---|---|---|
| Original | JPG | OFF | 出 .jpg（HEIC 源转码、JPG 源原存） |
| Original | JPG | ON | 出 Ultra HDR JPEG（_UltraHDR.jpg）— 需源是 HDR HEIC |
| Original | HEIC | OFF | 出 .heic（JPG 源转码、HEIC 源原存） |
| Original | HEIC | ON | 出 .heic（HDR HEIC 直接 save，HDR baked） |
| From RAW | JPG | OFF | 出 .jpg（CIRAWFilter SDR 渲染） |
| From RAW | JPG | ON | 出 _UltraHDR.jpg（Ultra HDR JPEG） |
| From RAW | HEIC | OFF | 出 .heic（CIRAWFilter SDR 渲染） |
| From RAW | HEIC | ON | 出 _HDR.heic（Adaptive HDR HEIC） |

**D. 新相册：**
- 开 Save to New Album + 输入 "Test1" → Export → Photos 库出现名为 "Test1" 的 user album，导出图都在里面
- 关 Save to New Album → 导出图进 "All Photos"，无新相册

**E. RAW 筛选 4 组合：**
- format × HDR 的 4 种 — 都从 RAW 渲染

**F. Delete 在 RAW+JPG / RAW 也工作：**
- 选 1 张点 Delete → 系统弹原生确认 → 真删

**G. 取消：**
- 点 Cancel → sheet 关，不导出

- [ ] **Step 3: 没问题就完成**

如果一切 OK 不需额外提交。如有问题报回主会话。

---

## 自检清单

- ✅ Spec § 1 (toolbar 重构) → Task 5 Step 2
- ✅ Spec § 2 (ExportOptionsSheet UI 与 AlbumPickerView 同款风格) → Task 4 Step 1
- ✅ Spec § 3 (ExportOptions struct) → Task 1
- ✅ Spec § 4 (8 组合矩阵路由) → Task 3 Step 2-3
- ✅ Spec § 5 (createAlbum + saveAsNewAsset addToAlbum) → Task 2
- ✅ Spec § 6 (performExportBatch) → Task 3 Step 2
- ✅ Spec § 7 (executeExport 复用 batchResultMessage/showBatchResult) → Task 5 Step 4
- ✅ 类型一致：`ExportOptions`、`ExportOptions.Source`、`ExportOptions.Format` 全程同名；`addToAlbum:` 参数命名一致
- ✅ 无 placeholder
