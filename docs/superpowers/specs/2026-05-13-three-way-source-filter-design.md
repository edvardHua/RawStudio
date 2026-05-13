# 主页面三态筛选 + 纯 JPG 入库 + 批量删除

**Date:** 2026-05-13
**Status:** Approved, ready for implementation

## 问题

主界面只有 RAW+JPG 与 RAW Only 两个筛选，且扫描器在数据层就丢弃了所有"无 RAW"的照片（包括 HEIC、纯 JPG、PNG 等）。用户希望：

1. 顶部三个筛选：**全部 / RAW+JPG / RAW**
2. "全部"包含纯 JPG / HEIC 等非 RAW 资源
3. 默认筛选改为 **全部**
4. 全部模式下选择批量项后，底部仅有 **删除** 一个按钮（真删到 Photos 库）
5. 关联页面（CompareView 等）跟随同步

## 设计原则

- **数据层最小改动**：保留 `PhotoPair` 名字，把 `rawResource` 改为可选；用 `kind: PhotoKind` 三态枚举把 jpg-only / raw-only / pair 区分开，让 Swift 编译器在 switch 里强制 exhaustive。
- **UI 文案保持"RAW+JPG"**（colloquial），实际数据接受 HEIC 等任何非 RAW 主图资源。
- **删除走系统原生确认**（PHPhotoLibrary 内置弹框），不重复造确认 alert。

## 不在范围内（YAGNI）

- 双数据模型（PhotoPair + JpgOnlyPhoto + 协议）— 改动量是当前方案 3-4 倍
- 重命名 `PhotoPair` → `PhotoItem`（git blame 噪音、文档一致性成本高）
- 全部模式下的导出/HDR 等批量操作（用户明确只要删除）
- 各 filter 模式下混合添加 Delete 按钮（仅全部模式有）
- iCloud 照片库的特殊处理（PHPhotoLibrary 一视同仁）

## 设计

### 1. 数据模型 `RawStudio/Models/PhotoPair.swift`

```swift
import Photos
import UIKit

enum PhotoKind {
    case rawJpgPair    // 同时有 raw 和 非raw 资源
    case rawOnly       // 仅 raw
    case jpgOnly       // 仅 非raw（JPG/HEIC/PNG/TIFF…）
}

final class PhotoPair: Identifiable {
    let id: String
    let asset: PHAsset
    let jpgResource: PHAssetResource?
    let rawResource: PHAssetResource?      // 改为可选
    let captureDate: Date
    let fileName: String
    let formatLabel: String                 // 改名（原 rawFormatLabel）

    var kind: PhotoKind {
        switch (jpgResource, rawResource) {
        case (.some, .some): return .rawJpgPair
        case (nil, .some):   return .rawOnly
        case (.some, nil):   return .jpgOnly
        case (nil, nil):     preconditionFailure("PhotoPair must have at least one resource")
        }
    }

    init(asset: PHAsset, jpgResource: PHAssetResource?, rawResource: PHAssetResource?) {
        precondition(jpgResource != nil || rawResource != nil,
                     "PhotoPair must have at least one resource")
        self.id = asset.localIdentifier
        self.asset = asset
        self.jpgResource = jpgResource
        self.rawResource = rawResource
        self.captureDate = asset.creationDate ?? Date.distantPast
        // fileName 优先 jpg，其次 raw（与现有 init 行为一致）
        self.fileName = (jpgResource ?? rawResource)!.originalFilename
        // formatLabel 优先 raw（pair 时仍展示 RAW 扩展名，跟今天一致），jpg-only 时用 jpg 扩展名
        self.formatLabel = Self.formatLabel(for: (rawResource ?? jpgResource)!)
    }

    private static func formatLabel(for resource: PHAssetResource) -> String {
        let ext = (resource.originalFilename as NSString).pathExtension.uppercased()
        switch ext {
        // RAW 格式（保持现有）
        case "ARW", "CR2", "CR3", "NEF", "RAF", "ORF", "RW2", "DNG", "PEF":
            return ext
        // 常见非 RAW 主图（新增）
        case "JPG", "JPEG":  return "JPG"
        case "HEIC", "HEIF": return "HEIC"
        case "PNG":          return "PNG"
        case "TIFF", "TIF":  return "TIFF"
        default:             return ext.isEmpty ? "PHOTO" : ext
        }
    }
}
```

`isRawOnly` 删除（不保留兼容 shim，所有调用点同步改）。

### 2. 扫描器 `RawStudio/Services/PhotoLibraryManager.swift`

`scanForPairsBatched` 内部循环（约 line 184-205）改：

```swift
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

    // 只要有任一主图资源就收录（之前是只有 raw 才收）
    if jpgResource != nil || rawResource != nil {
        let pair = PhotoPair(asset: asset, jpgResource: jpgResource, rawResource: rawResource)
        batchBuffer.append(pair)
    }

    scannedCount += 1
    // ... 其余 batch yield 逻辑不动
}
```

### 3. 新增 `deleteAssets`

加在 `// MARK: - Thumbnails` 之前（或 `// MARK: - Albums` 之后任一位置）：

```swift
// MARK: - Delete

/// 通过 PHPhotoLibrary 删除资源。系统会弹原生确认 alert；
/// 用户取消时返回 false（completion ok=false err=nil），按"无操作"处理。
/// 用户确认且系统删除成功后，本地从 pairs 中移除对应项。
func deleteAssets(_ pairs: [PhotoPair]) async -> (deletedCount: Int, cancelled: Bool) {
    let assets = pairs.map(\.asset)
    let ids = Set(pairs.map(\.id))

    let ok: Bool = await withCheckedContinuation { cont in
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        } completionHandler: { ok, _ in
            cont.resume(returning: ok)
        }
    }

    if ok {
        self.pairs.removeAll { ids.contains($0.id) }
        return (pairs.count, false)
    } else {
        return (0, true)
    }
}
```

### 4. 旧 `isRawOnly` 调用点适配

`PhotoLibraryManager.swift:461`（performBatchAction 里的 guard）：

```swift
// 旧：
guard !pair.isRawOnly else { ... }
// 新：
guard pair.kind == .rawJpgPair else { ... }
```

（语义等价：原来 `isRawOnly == true` 拦截，新逻辑等价于"必须是 pair 才放行"。`jpgOnly` 也会被拦下，符合 keepJPG/keepRAW 是 RAW+JPG 操作的语义。）

### 5. SourceFilter 三态 `RawStudio/Views/GalleryView.swift`

```swift
enum SourceFilter: CaseIterable {
    case all
    case rawJpgPair
    case rawOnly

    var label: String {
        switch self {
        case .all:        return String(localized: "All")
        case .rawJpgPair: return String(localized: "RAW+JPG")
        case .rawOnly:    return String(localized: "RAW")
        }
    }
}

@State private var sourceFilter: SourceFilter = .all   // 默认改为 .all

private var filteredPairs: [PhotoPair] {
    switch sourceFilter {
    case .all:        return manager.pairs
    case .rawJpgPair: return manager.pairs.filter { $0.kind == .rawJpgPair }
    case .rawOnly:    return manager.pairs.filter { $0.kind == .rawOnly }
    }
}
```

顶部 filter 胶囊（约 line 250-266 `HStack { filterCapsule(...) ... }`）扩到 3 个：

```swift
HStack(spacing: 8) {
    filterCapsule(label: String(localized: "All"),      isActive: sourceFilter == .all)        { sourceFilter = .all }
    filterCapsule(label: String(localized: "RAW+JPG"),  isActive: sourceFilter == .rawJpgPair) { sourceFilter = .rawJpgPair }
    filterCapsule(label: String(localized: "RAW"),      isActive: sourceFilter == .rawOnly)    { sourceFilter = .rawOnly }
    Spacer()
}
```

Header 内的 Menu Picker（约 line 217-222）— `ForEach(SourceFilter.allCases, ...)` 不用改（自动反映新枚举）。

### 6. 底部批量工具栏 `batchActionCapsules` 三分支

替换现有 `if sourceFilter == .rawOnly { ... } else { ... }` 为 switch：

```swift
private var batchActionCapsules: some View {
    HStack(spacing: 10) {
        switch sourceFilter {
        case .all:
            deleteCapsule { confirmBatchDelete() }
        case .rawJpgPair:
            batchCapsule(icon: "square.and.arrow.down", label: "Save JPG") { confirmBatch(.keepJPG) }
            batchCapsule(icon: "square.and.arrow.down.fill", label: "Save RAW") { confirmBatch(.keepRAW) }
            batchCapsule(icon: "sun.max.fill", label: "HDR") { confirmBatchHDR("adaptiveHDR") }
        case .rawOnly:
            batchCapsule(icon: "sun.max", label: "HDR HEIF") { confirmBatchHDR("adaptiveHDR") }
            batchCapsule(icon: "sun.max.fill", label: "HDR JPEG") { confirmBatchHDR("ultraHDR") }
        }
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
}

private func deleteCapsule(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.subheadline.weight(.medium))
            Text(String(localized: "Delete"))
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.red)                                 // destructive 强调
        .padding(.horizontal, capsulePadH)
        .padding(.vertical, capsulePadV)
        .background(.ultraThinMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
}
```

新增 `confirmBatchDelete`：

```swift
private func confirmBatchDelete() {
    let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
    guard !selected.isEmpty else { return }
    Task {
        let result = await manager.deleteAssets(selected)
        if !result.cancelled {
            // 成功：直接退出 selecting 模式（不弹结果 alert，与系统行为衔接）
            isSelecting = false
            selectedIDs.removeAll()
        }
        // cancelled = true 时什么都不做（用户在系统弹框选了取消）
    }
}
```

> 说明：不走现有的 `showBatchConfirm` alert 流程 — 因为 `PHPhotoLibrary` 自带原生删除确认 alert，再加一层会重复确认。

### 7. CompareView `RawStudio/Views/CompareView.swift`

#### `formatSwitcher`（约 line 211-244）

把 `if pair.isRawOnly { ... } else { ... }` 改为 switch：

```swift
@ViewBuilder
private var formatSwitcher: some View {
    if let pair = currentPair {
        HStack {
            switch pair.kind {
            case .rawOnly:
                Text("RAW")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, capsulePadH)
                    .padding(.vertical, capsulePadV)
                    .background(Color(red: 0.4, green: 0.8, blue: 0.5).opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 8))
            case .jpgOnly:
                Text(pair.formatLabel)            // "JPG" / "HEIC" / "PNG" 等
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, capsulePadH)
                    .padding(.vertical, capsulePadV)
                    .background(Color(.systemGray3).opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 8))
            case .rawJpgPair:
                HStack(spacing: 0) {
                    formatTab(label: "JPG", isActive: !showingRAW) {
                        zoomState = ZoomState()
                        showingRAW = false
                    }
                    formatTab(label: "RAW", isActive: showingRAW) {
                        zoomState = ZoomState()
                        showingRAW = true
                    }
                }
                // ... 现有 segmented 样式不动
            }
            // ... 现有 HStack 后续内容（Spacer 等）不动
        }
    }
}
```

#### `actionRow`（约 line 318-340）

```swift
private var actionRow: some View {
    HStack(spacing: 0) {
        if let pair = currentPair {
            switch pair.kind {
            case .rawOnly:
                actionItem(icon: "sun.max", label: "HDR HEIF") { exportHDR() }
                actionDivider
                actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDR() }
                actionDivider
                actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
            case .rawJpgPair:
                actionItem(icon: "square.and.arrow.down", label: "Save JPG") { performAction(.keepJPG) }
                actionDivider
                actionItem(icon: "square.and.arrow.down.fill", label: "Save RAW") { performAction(.keepRAW) }
                actionDivider
                actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                actionDivider
                // 现有 HDR menu 保持
            case .jpgOnly:
                actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
            }
        }
    }
}
```

`openEditor()` 对 jpg-only 已经能直接进 JPGEditorView（其内部读 `jpgResource`），无需改动。

#### CompareView 显示主图

CompareView 内部通过 `showingRAW` 标志切换显示 raw 或 jpg。jpg-only 时 `showingRAW` 必须强制保持 false（不会出现切换 UI 触发它变 true）。需要审查 `loadFullImage` / 显示主图的调用链，确保 jpg-only 走 jpg 路径（应当本来就是默认）。**Plan 阶段需要 grep `showingRAW` 全部出现位置确认无 raw-only 假设。**

### 8. 缩略图 badge

**`RawStudio/Views/PhotoCardView.swift`** 与 **`RawStudio/Views/PhotoGridItemView.swift`**：

```swift
Text(pair.rawFormatLabel)   // 旧
Text(pair.formatLabel)      // 新
```

各 1 处。

### 9. 数据流

```
[用户进入 GalleryView]
  ↓ sourceFilter = .all (默认)
  ↓ filteredPairs = manager.pairs (无过滤)
  ↓
[manager.fetchPairedAssets → scanForPairsBatched]
  ↓ 任一 jpgResource/rawResource 存在 → 构造 PhotoPair
  ↓ pairs 累积，UI 实时更新
  ↓
[用户切到 RAW+JPG / RAW]
  ↓ filter 按 kind 过滤
  ↓
[选择模式 + 全部 filter]
  ↓ batch toolbar 显示 Delete 单按钮
  ↓ 点 Delete
  ↓ manager.deleteAssets(selected)
  ↓ PHPhotoLibrary 弹系统原生确认 alert
  ↓ 用户确认 → ok=true → 本地 pairs 移除 → UI 刷新
  ↓ 用户取消 → ok=false → 维持 selecting 状态
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 用户库里大量纯 JPG 导致 pairs 数组膨胀 / scan 时间变长 | 沿用现有 batch streaming（50 张一批 yield），第一批 50 内即可显示首屏 |
| 缩略图缓存压力 | NSCache memory pressure 自动淘汰；上次优化已生效 |
| jpg-only 进 CompareView 后 `showingRAW` 状态污染 | Plan 阶段额外 grep 确认（spec section 7 已标注） |
| PHPhotoLibrary.deleteAssets 取消（用户在系统 alert 选 cancel） | `ok=false` 时不当作 error，静默退出，保留 selecting 状态 |
| `isRawOnly` 删除导致编译错 | 3 个调用点（CompareView × 2、PhotoLibraryManager × 1）同步改 |
| `rawFormatLabel` → `formatLabel` 重命名 | 2 个视图调用点（PhotoCardView、PhotoGridItemView）同步改 |

## 验证

- 真机：库里准备 RAW+JPG / RAW only / 纯 JPG / HEIC 各几张
- 启动 app → 默认看到全部，缩略图 badge 显示对应格式（ARW / DNG / JPG / HEIC）
- 切到 RAW+JPG → 只剩 pair 项；切到 RAW → 只剩 raw-only 项
- 全部模式选 N 项点 Delete → 系统弹"删除 N 项？" → 确认后照片真消失，列表立即刷新
- 全部模式选 N 项点 Delete → 系统弹框点取消 → 列表 + selection 维持原样
- 进入 jpg-only 项 Compare → 顶部灰底 HEIC/JPG badge → 底部只 Edit → 点 Edit 进 JPGEditorView 正常
- RAW+JPG / RAW 模式 batch toolbar 行为不变

## 涉及文件清单

| 文件 | 改动概述 |
|---|---|
| `RawStudio/Models/PhotoPair.swift` | rawResource 可选化、加 PhotoKind、formatLabel 扩展非 RAW 格式 |
| `RawStudio/Services/PhotoLibraryManager.swift` | scanner 放开 raw guard、新增 deleteAssets、line 461 适配 kind |
| `RawStudio/Views/GalleryView.swift` | SourceFilter 三态、默认 .all、filterCapsule 加 All、batch toolbar 三分支、加 deleteCapsule + confirmBatchDelete |
| `RawStudio/Views/CompareView.swift` | formatSwitcher / actionRow 各加 jpg-only 分支 |
| `RawStudio/Views/PhotoCardView.swift` | rawFormatLabel → formatLabel |
| `RawStudio/Views/PhotoGridItemView.swift` | 同上 |
