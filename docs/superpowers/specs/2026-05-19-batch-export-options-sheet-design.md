# Batch Export Options Sheet

**Date:** 2026-05-19
**Status:** Approved, ready for implementation

## 问题

当前 RAW+JPG / RAW Only 筛选下的 batch toolbar 散开 5 个固定按钮（Save JPG / Save RAW / HDR；HDR HEIF / HDR JPEG），表达力受限：用户没法选格式（JPG vs HEIC）、没法控 HDR 开关、没法把这批导出直接送进一个新相册。同时这两个筛选下也没有 Delete（虽然 All 模式有了）。

用户希望：

1. **两个筛选都加 Delete 按钮**（与 All 模式一致）
2. **5 个导出按钮合并为单一 "Export" 按钮**
3. 点 Export → 弹**导出选项 sheet**：
   - **源**：保留原图 / 从 RAW 渲染
   - **格式**：JPG / HEIC
   - **HDR**：开关
   - **保存到新相册**：开关 + 名称输入
4. 弹窗 UI 风格**与现有 app 一致**（`.ultraThinMaterial` 胶囊、NavigationStack sheet 模板与 `AlbumPickerView` 同款）

## 设计原则

- **YAGNI 严格剪裁**：仅 RAW+JPG / RAW 两个筛选；All 维持现状（Delete only）
- **选项可正交组合**：`Source × Format × HDR` 8 种组合都合法（已分析过，每种都有对应处理路径，详见 § 4）
- **HDR best-effort**：HDR 开 + 源不是 HDR HEIC → 静默退化为 SDR；不弹 warning
- **新相册可选**：默认关；开后输入框预填 `Export YYYY-MM-DD HH:mm`
- **进度复用**：现有 `BatchProgressView` 已在 `manager.isBatchProcessing` 上覆盖全屏，无需重复造

## 不在范围内（YAGNI）

- "添加到已有相册" 选项（仅"新建"）
- 自定义 JPEG 质量 / HDR headroom / 输出尺寸
- 批量过程中取消 / 重试单张失败的
- 导出预览（dry-run）
- 跨筛选模式记忆上次选项（每次默认）
- 单元测试（与项目其他功能一致，靠手动验证）

## 设计

### 1. Batch toolbar 重构（GalleryView）

```
All        →  [ Delete ]                          （不变）
RAW+JPG    →  [ Export ]  [ Delete ]              （旧 3 按钮合并 + 加 Delete）
RAW Only   →  [ Export ]  [ Delete ]              （旧 2 按钮合并 + 加 Delete）
```

`batchActionCapsules` switch 改写：

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

> 旧 `confirmBatch(.keepJPG)` / `confirmBatch(.keepRAW)` / `confirmBatchHDR(_:)` callbacks 都不再被 batch toolbar 使用 — 但 CompareView 单图模式还可能调用 keepJPG/keepRAW，所以保留这些函数定义（仅 batch toolbar 不再触发）。

`@State private var showExportSheet = false` + sheet：

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

### 2. 弹窗 UI — `ExportOptionsSheet`

**布局风格基准**：与 `AlbumPickerView`（同文件 line 544+）保持一致：
- 外层 `NavigationStack`
- 标题用 `.navigationTitle("Export Options")` + `.navigationBarTitleDisplayMode(.inline)`
- 左上 Cancel toolbar item，右上隐藏（主按钮在 sheet 底部）
- 内容用 `ScrollView { VStack(spacing: 20) { sections... } }`

**每个 section 的样式**（"liquid glass" 风格，与现有 filterCapsule / batchCapsule 呼应）：

```swift
private func sectionHeader(_ text: String) -> some View {
    Text(text)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
}

private func sectionContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
}
```

**整体 sheet 结构**：

```swift
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
                    // 源 (仅 RAW+JPG 筛选下显示)
                    if filter == .rawJPGPairs {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader(String(localized: "Source"))
                            sectionContainer {
                                Picker("", selection: $source) {
                                    Text("Keep Original").tag(ExportOptions.Source.original)
                                    Text("Render from RAW").tag(ExportOptions.Source.fromRaw)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }

                    // 格式
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(String(localized: "Format"))
                        sectionContainer {
                            Picker("", selection: $format) {
                                Text("JPG").tag(ExportOptions.Format.jpg)
                                Text("HEIC").tag(ExportOptions.Format.heic)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    // HDR
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(String(localized: "HDR"))
                        sectionContainer {
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
                    }

                    // 保存到
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(String(localized: "Save To"))
                        sectionContainer {
                            VStack(spacing: 12) {
                                Toggle(String(localized: "Save to New Album"), isOn: $saveToNewAlbum)
                                if saveToNewAlbum {
                                    TextField(String(localized: "Album Name"), text: $albumName)
                                        .textFieldStyle(.roundedBorder)
                                        .submitLabel(.done)
                                }
                            }
                        }
                    }

                    // 主按钮
                    Button {
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            newAlbumName: saveToNewAlbum
                                ? (albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   ? Self.defaultAlbumName() : albumName.trimmingCharacters(in: .whitespacesAndNewlines))
                                : nil
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

    private static func defaultAlbumName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Export \(formatter.string(from: Date()))"
    }
}
```

> **RAW Only 模式：** `if filter == .rawJPGPairs` 守卫使"源"section 不显示，弹窗只 3 个 section + 主按钮。`source` state 仍持有默认 `.original` 但提交时被强制改为 `.fromRaw`（看 onConfirm 里的三元）。

### 3. 模型 — `ExportOptions`

新文件 `RawStudio/Models/ExportOptions.swift`：

```swift
import Foundation

struct ExportOptions: Equatable {
    enum Source: Equatable { case original, fromRaw }
    enum Format: Equatable { case jpg, heic }

    var source: Source
    var format: Format
    var useHDR: Bool
    var newAlbumName: String?    // nil = 不创建相册
}
```

### 4. 导出路由 — 8 种组合

| Source | Format | HDR | 处理路径 | 现有/新增 |
|---|---|---|---|---|
| Original | JPG | OFF | 若原是 JPG → 直接 save；若原是 HEIC → CIImage 转码到 JPEG | **新** |
| Original | JPG | ON | 原是 HDR HEIC → `exportUltraHDRJPEGFromImage`；原是 SDR → fallback 同上行 | 复用+新 |
| Original | HEIC | OFF | 若原是 HEIC → 直接 save；若原是 JPG → CIImage 转码到 HEIC | **新** |
| Original | HEIC | ON | 原是 HDR HEIC → 直接 save（HDR baked）；原是 SDR → fallback 同上行 | **新** |
| From RAW | JPG | OFF | CIRAWFilter 渲染 → SDR JPEG | **新** |
| From RAW | JPG | ON | `exportUltraHDRJPEG`（已有 Ultra HDR JPEG） | 复用 |
| From RAW | HEIC | OFF | CIRAWFilter 渲染 → SDR HEIC | **新** |
| From RAW | HEIC | ON | `exportAdaptiveHDR`（已有 Adaptive HDR HEIC） | 复用 |

**新增 manager 方法（统一签名带 `addToAlbum:` 参数）：**

```swift
/// 路由所有 export 路径的单一入口；内部按 options 派发
func exportOne(_ pair: PhotoPair, options: ExportOptions, addToAlbum album: PHAssetCollection?) async throws

/// 从 RAW 渲染 SDR JPEG/HEIC（无 HDR）
private func exportRAWAsSDR(for pair: PhotoPair, format: ExportOptions.Format, addToAlbum: PHAssetCollection?) async throws

/// 保留原图路径：转码 / fallback / save as-is 矩阵
private func exportOriginal(for pair: PhotoPair, format: ExportOptions.Format, useHDR: Bool, addToAlbum: PHAssetCollection?) async throws
```

> `exportOne` 是给 `performExportBatch` 用的总入口；内部 switch on (source, format, useHDR) 派发。

### 5. 相册创建 + `saveAsNewAsset` 改造

**新增**：

```swift
/// 创建一个新 user album，返回 PHAssetCollection。
/// 失败抛 SplitError.writeFailed。
func createAlbum(name: String) async throws -> PHAssetCollection {
    var placeholder: PHObjectPlaceholder?
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        } completionHandler: { ok, err in
            if ok { cont.resume() }
            else { cont.resume(throwing: SplitError.writeFailed(err?.localizedDescription ?? "Create album failed")) }
        }
    }
    guard let id = placeholder?.localIdentifier,
          let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
        throw SplitError.writeFailed("Created album not found")
    }
    return collection
}
```

**改造既有 `saveAsNewAsset`** — 加可选 `addToAlbum`：

```swift
private func saveAsNewAsset(
    data: Data,
    resourceType: PHAssetResourceType,
    originalFilename: String,
    addToAlbum album: PHAssetCollection? = nil
) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
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
                cont.resume()
            } else {
                cont.resume(throwing: SplitError.writeFailed(error?.localizedDescription ?? "Unknown error"))
            }
        }
    }
}
```

> **既有的所有 saveAsNewAsset 调用方**（`exportAdaptiveHDR`, `exportUltraHDRJPEG`, `exportUltraHDRJPEGFromImage`, `performAction`）都保留默认 `addToAlbum = nil`，行为不变。新增的 `exportRAWAsSDR` / `exportOriginal` 透传该参数。

### 6. 批量执行 — `performExportBatch`

```swift
func performExportBatch(
    _ pairs: [PhotoPair],
    options: ExportOptions
) async -> (success: Int, failed: Int, albumError: String?) {
    isBatchProcessing = true
    batchTotal = pairs.count
    batchProgress = 0

    var album: PHAssetCollection? = nil
    var albumError: String? = nil
    if let name = options.newAlbumName {
        do {
            album = try await createAlbum(name: name)
        } catch {
            albumError = error.localizedDescription
            // 不中止导出，照样导出，只是不加入相册
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
    isBatchProcessing = false
    return (success, failed, albumError)
}
```

### 7. GalleryView 接线 — `executeExport`

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

(复用现有 `batchResultMessage` / `showBatchResult` 状态)

成功后退出 selecting：在现有 `.alert("Done", isPresented: $showBatchResult)` 的 `Button("OK")` 回调里已经 `isSelecting = false; selectedIDs.removeAll()`，无需新增。

## 数据流

```
[All filter 选中 N 张]               → [Delete 胶囊]  → PHPhotoLibrary 原生确认 → 真删
[RAW+JPG / RAW filter 选中 N 张]     → [Export 胶囊]  → 弹 ExportOptionsSheet
                                     → 用户选 source/format/HDR/album → [Export N Photos]
                                     → executeExport(options)
                                     → manager.performExportBatch:
                                       ├ optional: createAlbum(name)
                                       ├ for each pair:
                                       │   exportOne(pair, options, addToAlbum: album)
                                       │     → 路由到对应 RAW/Original/HDR/SDR/transcode 函数
                                       │     → 内部 saveAsNewAsset(... addToAlbum: album)
                                       └ 返回 (success, failed, albumError)
                                     → toast 结果，退出 selecting
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 转码 HEIC↔JPG 损失质量 | 默认 0.92 JPEG quality（与 UltraHDRWriter 一致）；HEIC 自动；告知"保留原图 + 不同格式 = 转码" |
| HDR ON + 原图 SDR：用户期望不一致 | best-effort fallback，silent；说明文字 "Ultra HDR JPEG / Adaptive HEIC" 暗示需源支持 |
| 相册名重名 | PhotoKit 允许重名；不去重 |
| 创建相册失败但导出成功 | `albumError` 非 nil 时附加错误到 toast 信息，导出照样跑完（不挂在相册上） |
| 批量过程中无法取消 | 与现有 batch 行为一致；不引入新交互 |
| Sheet 在 iPad 上要全屏 vs 居中 | 用 `.presentationDetents([.medium, .large])` 让用户上拉 |
| HDR 渲染长（10+ 张 RAW 可能数十秒） | 已有 `BatchProgressView` 中央覆盖；不另加 |
| TextField 输入键盘遮挡内容 | ScrollView 自动避让；toggle off 时 TextField 不显示 |

## 涉及文件清单

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/ExportOptions.swift` | **新文件**：ExportOptions struct + Source/Format enum |
| `RawStudio/Views/ExportOptionsSheet.swift` | **新文件**：sheet UI（与 AlbumPickerView 同款 NavigationStack + 自定义 `.ultraThinMaterial` 容器） |
| `RawStudio/Services/PhotoLibraryManager.swift` | 新增 `createAlbum`、`exportOne`、`exportRAWAsSDR`、`exportOriginal`、`performExportBatch`；改造 `saveAsNewAsset` 加 `addToAlbum` 参数 |
| `RawStudio/Views/GalleryView.swift` | batch toolbar switch 改写；加 `showExportSheet` state、`.sheet` modifier、`executeExport` 函数；保留 `confirmBatch`/`executeBatch` 等旧函数（CompareView 仍可能用） |

## 验证

- 真机：找几张 RAW+JPG 配对（HEIC+DNG 之类）和几张纯 RAW
- **RAW+JPG 筛选下**：
  - 选 3 张点 Export → 弹窗 → 验全部 8 组合：
    - 保留原图 + JPG + SDR（原是 HEIC）→ 出 JPEG（转码）
    - 保留原图 + JPG + HDR（原是 HDR HEIC）→ 出 Ultra HDR JPEG
    - 保留原图 + HEIC + SDR → 直接存
    - 保留原图 + HEIC + HDR（原是 HDR HEIC）→ 直接存（HDR 已 baked）
    - 从 RAW + JPG + SDR → CIRAWFilter SDR JPEG
    - 从 RAW + JPG + HDR → Ultra HDR JPEG
    - 从 RAW + HEIC + SDR → CIRAWFilter SDR HEIC
    - 从 RAW + HEIC + HDR → Adaptive HDR HEIC
  - Delete 按钮也存在，行为与 All 模式一致
- **RAW Only 筛选下**：
  - 弹窗只 3 个 section（无"源"）
  - 验 4 组合：format × HDR
- 新建相册开关：开 + 输 "测试" → 导出后 Photos 库里出现 "测试" user album，里面是导出的图
- 取消按钮：弹窗 dismiss，不导出
- 选择空集（理论上 Export 按钮在 `!selectedIDs.isEmpty` 时才显示）— 边界值
