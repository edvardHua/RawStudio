# 三态筛选 + 纯 JPG 入库 + 批量删除 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把主页面筛选改成 全部 / RAW+JPG / RAW 三档，扫描器不再丢弃纯 JPG/HEIC 等非 RAW 资源，"全部"模式下批量动作仅 Delete（真删）。

**Architecture:** `PhotoPair.rawResource` 改为可选 + 引入 `PhotoKind` 三态枚举，让 Swift switch exhaustive 强制覆盖三种情况。扫描器从"必须有 raw"放宽为"任一资源即可"。`SourceFilter` 加 `.all` 默认，`PhotoLibraryManager` 新增 `deleteAssets(_:)` 调用 PHPhotoLibrary 真删。

**Tech Stack:** Swift 5 / SwiftUI / Photos.framework / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-13-three-way-source-filter-design.md`

**项目背景：**
- 类 `PhotoLibraryManager` 标注 `@Observable`，`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- 项目无单元测试套件，验证 = `xcodebuild ... build` 编译通过 + 真机肉眼测
- 真机：`Edvardzeng` (iPhone 15 Pro Max, ID `E71BC21F-DC20-5570-9A10-6F3CF3CA5B28`)
- 模拟器：`iPhone 17 Pro` (DFABFFCE-4305-46F5-B38B-35BFCD1EB986)
- LSP 在该项目里对 UIKit / 项目内类型有 SourceKit 误报，**只信 xcodebuild 输出**

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/PhotoPair.swift` | 整体重写：加 `PhotoKind`、rawResource 可选、`rawFormatLabel` → `formatLabel` |
| `RawStudio/Services/PhotoLibraryManager.swift` | RAW 函数加 guard、line 461 改 kind 判断、scanner 放开 raw guard、新增 `deleteAssets(_:)` |
| `RawStudio/Views/GalleryView.swift` | filter 逻辑用 kind、SourceFilter 三态、默认 `.all`、filterCapsule 加 All、batch toolbar 三分支、加 `deleteCapsule` + `confirmBatchDelete` |
| `RawStudio/Views/CompareView.swift` | rawResource 解包、formatSwitcher / actionRow 各加 jpg-only 分支、`loadImages` 按 kind 跳过 RAW |
| `RawStudio/Views/PhotoCardView.swift` | `rawFormatLabel` → `formatLabel` |
| `RawStudio/Views/PhotoGridItemView.swift` | 同上 |

---

## Task 1: 数据模型迁移 — PhotoKind + rawResource 可选 + 全部 reader 适配

**目标：项目仍能编译，行为完全不变**（scanner 还在丢 jpg-only，UI 看不出差别）。这是数据基础。

**Files:**
- Modify: `RawStudio/Models/PhotoPair.swift`（整体重写）
- Modify: `RawStudio/Services/PhotoLibraryManager.swift:309-348` (`loadRAWImageWithMetadata`), `:357-412` (`exportAdaptiveHDR`), `:414-458` (`exportUltraHDRJPEG`), `:460-477` (`performAction`)
- Modify: `RawStudio/Views/GalleryView.swift:49-54` (`filteredPairs`)
- Modify: `RawStudio/Views/CompareView.swift:175`, `:215`, `:321`, `:394`
- Modify: `RawStudio/Views/PhotoCardView.swift:46`（`rawFormatLabel` → `formatLabel`）
- Modify: `RawStudio/Views/PhotoGridItemView.swift:23`（同上）

- [ ] **Step 1: 重写 `RawStudio/Models/PhotoPair.swift`**

整个文件替换为：

```swift
import Photos
import UIKit

enum PhotoKind {
    case rawJpgPair    // 同时有 raw 和 非 raw 资源
    case rawOnly       // 仅 raw
    case jpgOnly       // 仅 非 raw（JPG / HEIC / PNG / TIFF…）
}

final class PhotoPair: Identifiable {
    let id: String
    let asset: PHAsset
    let jpgResource: PHAssetResource?
    let rawResource: PHAssetResource?
    let captureDate: Date
    let fileName: String
    let formatLabel: String

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
        self.fileName = (jpgResource ?? rawResource)!.originalFilename
        // formatLabel 优先 raw（pair / raw-only 都展示 RAW 扩展名，与今天一致）；
        // jpg-only 时用 jpg 扩展名（HEIC/JPG/PNG…）
        self.formatLabel = Self.formatLabel(for: (rawResource ?? jpgResource)!)
    }

    private static func formatLabel(for resource: PHAssetResource) -> String {
        let ext = (resource.originalFilename as NSString).pathExtension.uppercased()
        switch ext {
        // RAW 格式
        case "ARW", "CR2", "CR3", "NEF", "RAF", "ORF", "RW2", "DNG", "PEF":
            return ext
        // 常见非 RAW 主图
        case "JPG", "JPEG":  return "JPG"
        case "HEIC", "HEIF": return "HEIC"
        case "PNG":          return "PNG"
        case "TIFF", "TIF":  return "TIFF"
        default:             return ext.isEmpty ? "PHOTO" : ext
        }
    }
}
```

> 旧的 `isRawOnly` 与 `rawFormatLabel` 都已删除。后续 step 同步更新所有 reader。

- [ ] **Step 2: 更新 `RawStudio/Services/PhotoLibraryManager.swift` 的 `loadRAWImageWithMetadata`**

找到 line 309-348（`func loadRAWImageWithMetadata(...)`），把方法体最开头：

```swift
        let resource = pair.rawResource
        let data = try await extractResourceData(for: resource)
```

改为：

```swift
        guard let resource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
        let data = try await extractResourceData(for: resource)
```

（其它代码不动 — 函数体内后续都用 local `resource`，与改前一致）。

- [ ] **Step 3: 更新 `exportAdaptiveHDR`**

找到 line 357-412。把开头：

```swift
    func exportAdaptiveHDR(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        let rawData = try await extractResourceData(for: pair.rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: pair.rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(pair.rawResource.originalFilename)")
        }
```

改为：

```swift
    func exportAdaptiveHDR(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        guard let rawResource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
        let rawData = try await extractResourceData(for: rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(rawResource.originalFilename)")
        }
```

并在最后 line 405-411（`saveAsNewAsset` 调用）把：

```swift
            originalFilename: (pair.rawResource.originalFilename as NSString)
                .deletingPathExtension + "_HDR.heic"
```

改为：

```swift
            originalFilename: (rawResource.originalFilename as NSString)
                .deletingPathExtension + "_HDR.heic"
```

- [ ] **Step 4: 更新 `exportUltraHDRJPEG`**

找到 line 414-458。把开头：

```swift
    func exportUltraHDRJPEG(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        let rawData = try await extractResourceData(for: pair.rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: pair.rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(pair.rawResource.originalFilename)")
        }
```

改为：

```swift
    func exportUltraHDRJPEG(for pair: PhotoPair, editParams: RAWEditParams = RAWEditParams()) async throws {
        guard let rawResource = pair.rawResource else {
            throw SplitError.extractionFailed("This photo has no RAW resource")
        }
        let rawData = try await extractResourceData(for: rawResource)

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: rawResource.uniformTypeIdentifier) else {
            throw SplitError.extractionFailed("Cannot create RAW filter for \(rawResource.originalFilename)")
        }
```

并在最后 line 451-457 把：

```swift
            originalFilename: (pair.rawResource.originalFilename as NSString)
                .deletingPathExtension + "_UltraHDR.jpg"
```

改为：

```swift
            originalFilename: (rawResource.originalFilename as NSString)
                .deletingPathExtension + "_UltraHDR.jpg"
```

- [ ] **Step 5: 更新 `performAction`**

找到 line 460-477。把：

```swift
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

        case .keepRAW:
            let rawData = try await extractResourceData(for: pair.rawResource)
            try await saveAsNewAsset(data: rawData, resourceType: .photo, originalFilename: pair.rawResource.originalFilename)
        }
    }
```

整段替换为：

```swift
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
```

- [ ] **Step 6: 更新 `RawStudio/Views/GalleryView.swift` 的 `filteredPairs`**

找到 line 49-54：

```swift
    private var filteredPairs: [PhotoPair] {
        switch sourceFilter {
        case .rawJPGPairs: return manager.pairs.filter { !$0.isRawOnly }
        case .rawOnly: return manager.pairs.filter { $0.isRawOnly }
        }
    }
```

改为（注意：用**严格** `kind == .rawJpgPair`，不是"非 raw-only"，这样 Task 3 放开 scanner 后 jpg-only 不会污染 RAW+JPG 筛选）：

```swift
    private var filteredPairs: [PhotoPair] {
        switch sourceFilter {
        case .rawJPGPairs: return manager.pairs.filter { $0.kind == .rawJpgPair }
        case .rawOnly:     return manager.pairs.filter { $0.kind == .rawOnly }
        }
    }
```

- [ ] **Step 7: 更新 `RawStudio/Views/CompareView.swift` 的 `pair.rawResource` 直接访问**

找到 line 175：

```swift
                    resourceHint: pair.rawResource.uniformTypeIdentifier,
```

改为：

```swift
                    resourceHint: pair.rawResource?.uniformTypeIdentifier ?? "",
```

> 该 fullScreenCover 仅在 `cachedRawData != nil` 时 present，所以 jpg-only 不会进来。`?? ""` 只是让编译通过。

找到 line 394：

```swift
            let rawData = try await manager.extractRawData(for: pair.rawResource)
            cachedRawData = rawData
```

改为（用 `if let` 守卫，防 jpg-only 崩溃；jpg-only 在 Task 2 才会有 jpg-only 专属流程）：

```swift
            if let raw = pair.rawResource {
                let rawData = try await manager.extractRawData(for: raw)
                cachedRawData = rawData
            } else {
                cachedRawData = nil
            }
```

> 注意：line 409 的 `manager.loadRAWImageWithMetadata(for: pair, ...)` 调用本身不动 — 它内部已经在 Step 2 加了 guard，会 throw "no RAW resource"。Task 2 会在调用处也加 kind 判断。

找到 line 215：

```swift
                if pair.isRawOnly {
```

改为：

```swift
                if pair.kind == .rawOnly {
```

找到 line 321：

```swift
                if pair.isRawOnly {
```

改为：

```swift
                if pair.kind == .rawOnly {
```

- [ ] **Step 8: 更新 `RawStudio/Views/PhotoCardView.swift`**

找到 line 46（在 `HStack(spacing: 6) { Text(...) ... }` 里）：

```swift
                    Text(pair.rawFormatLabel)
```

改为：

```swift
                    Text(pair.formatLabel)
```

- [ ] **Step 9: 更新 `RawStudio/Views/PhotoGridItemView.swift`**

找到 line 23（badge 里）：

```swift
                    Text(pair.rawFormatLabel)
```

改为：

```swift
                    Text(pair.formatLabel)
```

- [ ] **Step 10: Build 验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`，无 error。
（SourceKit 的 `Cannot find type 'PhotoPair'` / `'UIImage'` 等 LSP 误报忽略。）

如果出现 "Value of optional type 'PHAssetResource?' must be unwrapped" 之类错误，说明遗漏了某处 `pair.rawResource` reader。grep 找：
```bash
grep -rn '\.rawResource' /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio/ --include="*.swift"
```
对每个 hit 决定加 `if let` 或 guard。

- [ ] **Step 11: Commit**

```bash
git add RawStudio/Models/PhotoPair.swift RawStudio/Services/PhotoLibraryManager.swift RawStudio/Views/GalleryView.swift RawStudio/Views/CompareView.swift RawStudio/Views/PhotoCardView.swift RawStudio/Views/PhotoGridItemView.swift
git commit -m "$(cat <<'EOF'
refactor(model): make PhotoPair.rawResource optional + add PhotoKind

- rawResource: PHAssetResource? (was non-optional)
- new PhotoKind enum: rawJpgPair / rawOnly / jpgOnly
- rename rawFormatLabel -> formatLabel; recognize HEIC/JPG/PNG/TIFF
- guard all RAW-bearing manager functions on optional unwrap
- callers switched from isRawOnly to kind == .rawOnly (strict)

No behavior change yet — scanner still filters jpg-only assets out.
Subsequent tasks will relax the scanner and wire up jpg-only UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: CompareView 的 jpg-only 分支 + showingRAW 状态防护

**目标：CompareView 在拿到 jpg-only 项时不崩溃、UI 合理。** Scanner 还没放开（Task 3 才开），所以这是"提前布雷"。

**Files:**
- Modify: `RawStudio/Views/CompareView.swift`（line 18 默认值; line 211-244 `formatSwitcher`; line 318-340 `actionRow`; line 388-428 `loadImages`）

- [ ] **Step 1: `showingRAW` 默认值改为 false**

找到 line 18：

```swift
    @State private var showingRAW = true
```

改为：

```swift
    @State private var showingRAW = false
```

> 原默认 true 是因为只有 raw-only / pair 两种 kind，pair 模式 RAW 渲染更代表"原图"。但 jpg-only 没有 RAW，true 会让 currentDisplayImage 取 nil rawImage。改为 false 后，pair 模式默认显示 JPG（与缩略图一致），jpg-only / raw-only 各自由 loadImages 强制设定。

- [ ] **Step 2: `loadImages` 按 kind 分支**

找到 line 388-428（整个 `func loadImages() async`），整段替换为：

```swift
    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        defer { isLoadingImages = false }
        do {
            currentEditParams = presetStore.loadParams(for: pair.id)
            currentJPGEditParams = presetStore.loadJPGParams(for: pair.id)
            currentLayerEdits = presetStore.loadLayerEdits(for: pair.id)
            currentJPGLayerEdits = presetStore.loadJPGLayerEdits(for: pair.id)

            // 加载 RAW（如有）
            if let rawResource = pair.rawResource {
                let rawData = try await manager.extractRawData(for: rawResource)
                cachedRawData = rawData
                let rawResult = try await manager.loadRAWImageWithMetadata(for: pair, editParams: currentEditParams)
                rawImage = rawResult.0
                rawMetadata = rawResult.1
            } else {
                cachedRawData = nil
                rawImage = nil
                rawMetadata = nil
            }

            // 加载 JPG（如有）
            if let jpgResource = pair.jpgResource {
                let jpgData = try await manager.extractRawData(for: jpgResource)
                cachedJPGData = jpgData
                if let jpgResult = try await manager.loadJPGImageWithMetadata(for: pair) {
                    jpgImage = jpgResult.0
                    jpgMetadata = jpgResult.1
                } else {
                    jpgImage = nil
                    jpgMetadata = nil
                }
            } else {
                cachedJPGData = nil
                jpgImage = nil
                jpgMetadata = nil
            }

            // 按 kind 设定显示哪一面
            switch pair.kind {
            case .rawOnly:    showingRAW = true
            case .rawJpgPair: showingRAW = true     // 维持原默认行为（以前总是设 true）
            case .jpgOnly:    showingRAW = false
            }
            zoomState = ZoomState()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
```

> 注意：这里把 `showingRAW` 在 pair 模式下仍设为 true，保持你之前的行为。Step 1 的默认 false 仅作为 jpg-only 的安全态（loadImages 跑完前可能短暂展示）。

- [ ] **Step 3: `formatSwitcher` 改 switch on kind**

找到 `formatSwitcher`（约 line 211-241）。当前内容（Task 1 Step 7 后）：

```swift
    @ViewBuilder
    private var formatSwitcher: some View {
        if let pair = currentPair {
            HStack {
                if pair.kind == .rawOnly {
                    // Static RAW badge
                    Text("RAW")
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, capsulePadH)
                        .padding(.vertical, capsulePadV)
                        .background(Color(red: 0.4, green: 0.8, blue: 0.5).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))
                } else {
                    // Segmented control for JPG/RAW
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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
        }
    }
```

整段替换为：

```swift
    @ViewBuilder
    private var formatSwitcher: some View {
        if let pair = currentPair {
            HStack {
                switch pair.kind {
                case .rawOnly:
                    // Static RAW badge（绿底）
                    Text("RAW")
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, capsulePadH)
                        .padding(.vertical, capsulePadV)
                        .background(Color(red: 0.4, green: 0.8, blue: 0.5).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))

                case .jpgOnly:
                    // Static format badge（灰底；显示实际格式名 HEIC/JPG/PNG…）
                    Text(pair.formatLabel)
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, capsulePadH)
                        .padding(.vertical, capsulePadV)
                        .background(Color(.systemGray3).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))

                case .rawJpgPair:
                    // Segmented control for JPG/RAW
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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
        }
    }
```

- [ ] **Step 4: `actionRow` 改 switch on kind**

找到 `actionRow`（约 line 318-345）。当前内容（Task 1 Step 7 后）：

```swift
    private var actionRow: some View {
        HStack(spacing: 0) {
            if let pair = currentPair {
                if pair.kind == .rawOnly {
                    // RAW-only: HDR exports + Edit
                    actionItem(icon: "sun.max", label: "HDR HEIF") { exportHDR() }
                    actionDivider
                    actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDR() }
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                } else {
                    // RAW+JPG pair
                    actionItem(icon: "square.and.arrow.down", label: "Save JPG") { performAction(.keepJPG) }
                    actionDivider
                    actionItem(icon: "square.and.arrow.down.fill", label: "Save RAW") { performAction(.keepRAW) }
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                    actionDivider
                    // HDR menu
                    hdrMenuButton
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
```

整段替换为：

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
                    // HDR menu
                    hdrMenuButton

                case .jpgOnly:
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
```

- [ ] **Step 5: 验证 `showingRAW` 别处用法不会被 jpg-only 触发**

```bash
grep -n "showingRAW" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio/Views/CompareView.swift
```

预期会看到 line 18, 54, 58, 227, 229, 231, 233, 543（具体行号可能因前面 step 略变）。逐个 `Read` 检查：
- line 54 / 58：`showingRAW ? rawImage : jpgImage` — jpg-only 时 showingRAW=false（Step 2 设定），返回 jpgImage（非 nil） ✅ 安全
- line 227 / 229 / 231 / 233：segmented control 内的写入；现在仅在 `.rawJpgPair` 分支可达 ✅ 安全
- line 543：`if showingRAW { ... }` —— `Read` 上下文 5 行，确认这个分支若 jpg-only 走 false 没问题；若该分支假设有 rawData / rawImage，需要补 jpg-only guard。如果发现需要修复，**stop 并 escalate**（这不在原 task 范围）

- [ ] **Step 6: Build 验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add RawStudio/Views/CompareView.swift
git commit -m "$(cat <<'EOF'
refactor(CompareView): handle jpg-only items in formatSwitcher / actionRow

- showingRAW default flipped to false (safer when item has no RAW)
- loadImages branches on kind, skips RAW load for jpg-only
- formatSwitcher: gray-bg JPG/HEIC/PNG badge for jpg-only
- actionRow: jpg-only shows only Edit

Dead-code path until Task 3 relaxes the scanner; this commit just
gets CompareView ready.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 扫描器放开非 RAW 资源

**目标：** 让扫描器收录 jpg-only 资源；CompareView (Task 2) 已 ready，主页面 (Task 5) 还没加 .all filter，但 RAW+JPG 默认 filter 用了 `kind == .rawJpgPair` 严格判断，jpg-only 不会污染。

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift:201-205`（scanner 内部循环的 raw guard）

- [ ] **Step 1: 移除 raw guard，改为"任一资源即可"**

找到 line 201-205：

```swift
                    if let raw = rawResource {
                        let pair = PhotoPair(asset: asset, jpgResource: jpgResource, rawResource: raw)
                        batchBuffer.append(pair)
                    }
```

改为：

```swift
                    if jpgResource != nil || rawResource != nil {
                        let pair = PhotoPair(asset: asset, jpgResource: jpgResource, rawResource: rawResource)
                        batchBuffer.append(pair)
                    }
```

> 注意 init 第 3 个参数 `rawResource` 现在是可选传可选，无需 `if let` 解包。

- [ ] **Step 2: Build 验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -5
```

**Expected:** `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
feat(scanner): include non-RAW assets (HEIC/JPG/PNG/TIFF…)

Scanner no longer drops assets without a RAW resource. JPG-only items
now appear in manager.pairs with kind == .jpgOnly. RAW+JPG / RAW
filters in GalleryView use strict kind matching, so they're not
polluted. CompareView already handles jpg-only from Task 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 新增 `deleteAssets` API

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift`（在 `// MARK: - Thumbnails` 之前插入新 MARK）

- [ ] **Step 1: 插入 deleteAssets 方法**

找到 `// MARK: - Thumbnails` 这一行（约 line 230 附近，Task 1 之后行号可能略动；用 grep 定位）：

```bash
grep -n "// MARK: - Thumbnails" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio/Services/PhotoLibraryManager.swift
```

在该 MARK **上方**插入：

```swift
    // MARK: - Delete

    /// 通过 PHPhotoLibrary 真删除选中资产。系统会弹原生确认 alert；
    /// - 返回 .cancelled = true：用户在系统弹框选了取消（或权限不足）
    /// - 返回 .deletedCount：实际删除数量；同时本地 `pairs` 数组同步移除
    func deleteAssets(_ pairs: [PhotoPair]) async -> (deletedCount: Int, cancelled: Bool) {
        guard !pairs.isEmpty else { return (0, false) }
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

> 注：`self.pairs` 是 `@Observable` 的 `var pairs: [PhotoPair]`（`PhotoLibraryManager.swift:35`），写入会自动触发 SwiftUI 刷新。

- [ ] **Step 2: Build 验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -5
```

**Expected:** `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
feat(library): add deleteAssets(_:) for batch deletion via PHPhotoLibrary

Wraps PHAssetChangeRequest.deleteAssets in performChanges. System shows
the native confirm alert; on success removes the IDs from the local
`pairs` array so SwiftUI refreshes immediately. Returns whether the
user cancelled.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 三态 SourceFilter + 默认 .all + filter UI + Delete 按钮

**Files:**
- Modify: `RawStudio/Views/GalleryView.swift`（SourceFilter enum line 3-13、default sourceFilter line 23、filteredPairs switch、filterCapsule HStack、batchActionCapsules switch、新增 deleteCapsule + confirmBatchDelete）

- [ ] **Step 1: 扩展 `SourceFilter` 到三态**

找到 line 3-13：

```swift
enum SourceFilter: CaseIterable {
    case rawJPGPairs
    case rawOnly

    var label: String {
        switch self {
        case .rawJPGPairs: return String(localized: "RAW+JPG")
        case .rawOnly: return String(localized: "RAW Only")
        }
    }
}
```

整段替换为：

```swift
enum SourceFilter: CaseIterable {
    case all
    case rawJPGPairs
    case rawOnly

    var label: String {
        switch self {
        case .all:         return String(localized: "All")
        case .rawJPGPairs: return String(localized: "RAW+JPG")
        case .rawOnly:     return String(localized: "RAW")
        }
    }
}
```

> 注意：原 `.rawOnly` label 是 `"RAW Only"`，spec 要求改成 `"RAW"`。

- [ ] **Step 2: 默认筛选改 `.all`**

找到 line 23（约）：

```swift
    @State private var sourceFilter: SourceFilter = .rawJPGPairs
```

改为：

```swift
    @State private var sourceFilter: SourceFilter = .all
```

- [ ] **Step 3: 更新 `filteredPairs` switch**

找到 Task 1 Step 6 已经改过的 `filteredPairs`：

```swift
    private var filteredPairs: [PhotoPair] {
        switch sourceFilter {
        case .rawJPGPairs: return manager.pairs.filter { $0.kind == .rawJpgPair }
        case .rawOnly:     return manager.pairs.filter { $0.kind == .rawOnly }
        }
    }
```

加 `.all` 分支：

```swift
    private var filteredPairs: [PhotoPair] {
        switch sourceFilter {
        case .all:         return manager.pairs
        case .rawJPGPairs: return manager.pairs.filter { $0.kind == .rawJpgPair }
        case .rawOnly:     return manager.pairs.filter { $0.kind == .rawOnly }
        }
    }
```

- [ ] **Step 4: 顶部 filter 胶囊加 All**

找到 line 250-266 附近的：

```swift
            // Source filter pills (always visible)
            HStack(spacing: 8) {
                filterCapsule(
                    label: String(localized: "RAW+JPG"),
                    isActive: sourceFilter == .rawJPGPairs
                ) { sourceFilter = .rawJPGPairs }

                filterCapsule(
                    label: String(localized: "RAW Only"),
                    isActive: sourceFilter == .rawOnly
                ) { sourceFilter = .rawOnly }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
```

整段替换为：

```swift
            // Source filter pills (always visible)
            HStack(spacing: 8) {
                filterCapsule(
                    label: String(localized: "All"),
                    isActive: sourceFilter == .all
                ) { sourceFilter = .all }

                filterCapsule(
                    label: String(localized: "RAW+JPG"),
                    isActive: sourceFilter == .rawJPGPairs
                ) { sourceFilter = .rawJPGPairs }

                filterCapsule(
                    label: String(localized: "RAW"),
                    isActive: sourceFilter == .rawOnly
                ) { sourceFilter = .rawOnly }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
```

- [ ] **Step 5: 重构 `batchActionCapsules` 为三分支 + Delete**

找到 `batchActionCapsules`（约 line 290-314）：

```swift
    private var batchActionCapsules: some View {
        HStack(spacing: 10) {
            if sourceFilter == .rawOnly {
                batchCapsule(icon: "sun.max", label: "HDR HEIF") {
                    confirmBatchHDR("adaptiveHDR")
                }
                batchCapsule(icon: "sun.max.fill", label: "HDR JPEG") {
                    confirmBatchHDR("ultraHDR")
                }
            } else {
                batchCapsule(icon: "square.and.arrow.down", label: "Save JPG") {
                    confirmBatch(.keepJPG)
                }
                batchCapsule(icon: "square.and.arrow.down.fill", label: "Save RAW") {
                    confirmBatch(.keepRAW)
                }
                batchCapsule(icon: "sun.max.fill", label: "HDR") {
                    confirmBatchHDR("adaptiveHDR")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
```

整段替换为：

```swift
    private var batchActionCapsules: some View {
        HStack(spacing: 10) {
            switch sourceFilter {
            case .all:
                deleteCapsule { confirmBatchDelete() }
            case .rawJPGPairs:
                batchCapsule(icon: "square.and.arrow.down", label: "Save JPG") {
                    confirmBatch(.keepJPG)
                }
                batchCapsule(icon: "square.and.arrow.down.fill", label: "Save RAW") {
                    confirmBatch(.keepRAW)
                }
                batchCapsule(icon: "sun.max.fill", label: "HDR") {
                    confirmBatchHDR("adaptiveHDR")
                }
            case .rawOnly:
                batchCapsule(icon: "sun.max", label: "HDR HEIF") {
                    confirmBatchHDR("adaptiveHDR")
                }
                batchCapsule(icon: "sun.max.fill", label: "HDR JPEG") {
                    confirmBatchHDR("ultraHDR")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
```

- [ ] **Step 6: 加 `deleteCapsule` helper + `confirmBatchDelete` 方法**

找到 `batchCapsule` helper（约 line 316-330）。在它**下方**插入：

```swift
    private func deleteCapsule(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.medium))
                Text(String(localized: "Delete"))
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, capsulePadH)
            .padding(.vertical, capsulePadV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
```

然后找到 `executeBatch()` 函数（约 line 505-541）。在它**上方**或**下方**新增 `confirmBatchDelete`：

```swift
    private func confirmBatchDelete() {
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task {
            let result = await manager.deleteAssets(selected)
            if !result.cancelled {
                isSelecting = false
                selectedIDs.removeAll()
            }
            // result.cancelled == true：用户在系统弹框点取消，保留 selecting 状态
        }
    }
```

> 不走 `confirmBatch` 现有的 alert 路径 — 系统已自带删除确认 alert，重复确认体验差。

- [ ] **Step 7: Build 验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(gallery): three-way source filter + Delete batch in All mode

- SourceFilter: add .all, default .all, rename "RAW Only" -> "RAW"
- Top filter pills now show All / RAW+JPG / RAW
- Bottom batch toolbar switches by filter:
  · All        -> Delete only (red, system-confirm via PHPhotoLibrary)
  · RAW+JPG    -> Save JPG / Save RAW / HDR (unchanged)
  · RAW        -> HDR HEIF / HDR JPEG (unchanged)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 真机肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: 打 device build + 安装到真机**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/RawStudio-device-3way \
  -allowProvisioningUpdates build 2>&1 | tail -5

xcrun devicectl device install app --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 \
  /tmp/RawStudio-device-3way/Build/Products/Debug-iphoneos/RawStudio.app

xcrun devicectl device process launch --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 com.edz.RawStudio
```

- [ ] **Step 2: 验证项**

在手机上检查：
- 启动时默认筛选 = "All"，看到所有照片（含 HEIC / 纯 JPG）
- 缩略图 badge：RAW+JPG 显示 ARW/CR3/DNG 等；RAW Only 同样；纯 JPG/HEIC 显示 JPG / HEIC / PNG
- 切到 RAW+JPG → 只显示同时有 raw 和 非raw 资源的项；不应包含纯 HEIC/JPG
- 切到 RAW → 只显示无 jpg 兄弟的 RAW
- 全部模式选 N 项点 Delete → 系统弹"删除 N 项？"原生 alert → 确认后照片消失、列表立即刷新
- 全部模式选 N 项点 Delete → 系统 alert 点取消 → 列表 + selection 维持原样
- 进入纯 JPG/HEIC 项的 Compare → 顶部灰底 HEIC/JPG/PNG badge → 底部仅 Edit → 点 Edit 进 JPGEditorView 正常
- RAW+JPG 模式 batch toolbar 仍是 Save JPG / Save RAW / HDR
- RAW 模式 batch toolbar 仍是 HDR HEIF / HDR JPEG

- [ ] **Step 3: 没问题就完成**

如果一切 OK，无需额外提交。如果有问题报回主会话。

---

## 自检清单（写完后过一遍）

- ✅ Spec § 1 (数据模型 PhotoKind + 可选 rawResource + formatLabel) → Task 1 Step 1
- ✅ Spec § 2 (扫描器放开 raw guard) → Task 3 Step 1
- ✅ Spec § 3 (deleteAssets API + cancelled 处理) → Task 4 Step 1
- ✅ Spec § 4 (isRawOnly 调用点适配 - PhotoLibraryManager 461) → Task 1 Step 5
- ✅ Spec § 5 (SourceFilter 三态 / 默认 .all / 三个 filterCapsule / Menu Picker 自动反映) → Task 5 Steps 1-4
- ✅ Spec § 6 (batch toolbar 三分支 + deleteCapsule + confirmBatchDelete) → Task 5 Steps 5-6
- ✅ Spec § 7 (CompareView formatSwitcher / actionRow 各加 jpg-only 分支 + showingRAW grep) → Task 2 Steps 3-5
- ✅ Spec § 8 (rawFormatLabel → formatLabel 在 PhotoCardView/PhotoGridItemView) → Task 1 Steps 8-9
- ✅ 类型一致：`PhotoKind`、`formatLabel`、`deleteAssets(_:)` 在所有 task 里命名/签名完全一致
- ✅ 无 placeholder（每步都有完整代码或命令）
