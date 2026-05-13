# 编辑/预设标识 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GalleryView 缩略图卡片在已编辑 / 已套用预设时显示对应的小 badge（最多 2 个）。

**Architecture:** `RAWEditPresetStore` 新增"用过预设"标记（2 个 UserDefaults flag）+ `isEdited` / `hasUsedPreset` 综合查询 + `changeCounter` 触发 SwiftUI 刷新。Editor 在 preset 选中时打标，保存时若 params 回到默认则清标。`PhotoCardView` / `PhotoGridItemView` 接收 `presetStore`，在格式 chip 后/右上角条件渲染 SF Symbol badge。

**Tech Stack:** Swift 5 / SwiftUI / `@Observable` / UserDefaults / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-13-edit-and-preset-badges-design.md`

**项目背景：**
- 类 `@Observable final class RAWEditPresetStore` ✅ 已是 `@Observable`（确认过 `RawStudio/Services/RAWEditPresetStore.swift:4`）
- `LayerEdits` 已有 `var hasAnyLayerEdits: Bool`（`RawStudio/Models/LayerEditParams.swift:91-94`）→ 用 `!hasAnyLayerEdits` 替代 spec 里的 `isEmpty`，无需新增模型代码
- 真机：iPhone 15 Pro Max (`E71BC21F-DC20-5570-9A10-6F3CF3CA5B28`)
- 模拟器：iPhone 17 Pro (`DFABFFCE-4305-46F5-B38B-35BFCD1EB986`)
- LSP/SourceKit 在 PBXFileSystemSynchronizedRootGroup 项目里有恼人误报，**只信 xcodebuild 输出**

**关键事实：**
- `UserDefaults.set` 不触发 `@Observable` 通知 → 必须显式 `changeCounter` 自增
- 视图通过在 body 顶部 `let _ = presetStore.changeCounter` 订阅刷新

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Services/RAWEditPresetStore.swift` | 加 2 prefix、4 mark/clear、2 query、`changeCounter` 字段；既有 save/remove 方法末尾追加 `changeCounter += 1` |
| `RawStudio/Views/RAWEditorView.swift` | preset onSelect 加 mark；save 路径加"params.isModified == false 时 clear" |
| `RawStudio/Views/JPGEditorView.swift` | 同上（JPG 版本） |
| `RawStudio/Views/PhotoCardView.swift` | 加 `presetStore` 参数、`indicatorBadge` helper、chip 区追加 2 条件 badge、body 顶部订阅 `changeCounter` |
| `RawStudio/Views/PhotoGridItemView.swift` | 加 `presetStore` 参数、`indicatorBadge` helper、overlay HStack 追加 2 条件 badge、body 顶部订阅 |
| `RawStudio/Views/GalleryView.swift` | 在 PhotoCardView / PhotoGridItemView 调用处传 `presetStore: presetStore` |

---

## Task 1: `RAWEditPresetStore` — 数据层

**Files:**
- Modify: `RawStudio/Services/RAWEditPresetStore.swift`

- [ ] **Step 1: 加 changeCounter 字段 + 2 个新 prefix**

找到 line 13-18（既有 prefix 声明）：

```swift
    private let presetsKey = "rawEditPresets"
    private let jpgPresetsKey = "jpgEditPresets"
    private let assetParamsPrefix = "rawEditParams_"
    private let jpgAssetParamsPrefix = "jpgEditParams_"
    private let layerEditsPrefix = "layerEdits_"
    private let jpgLayerEditsPrefix = "layerEdits_jpg_"
```

在它们下方追加（保留同样的缩进）：

```swift
    private let usedRawPresetPrefix = "usedRawPreset_"
    private let usedJpgPresetPrefix = "usedJpgPreset_"

    /// 任意 UserDefaults 写操作后递增，迫使依赖此属性的 SwiftUI 视图重渲染。
    /// （UserDefaults.set 本身不触发 @Observable 通知）
    var changeCounter: Int = 0
```

- [ ] **Step 2: 在所有 UserDefaults 写方法末尾加 `changeCounter += 1`**

下面每个函数的最后一行（在右大括号之前）追加 `changeCounter += 1`。逐个 grep 定位：

```bash
grep -n "func saveParams\|func saveJPGParams\|func saveLayerEdits\|func saveJPGLayerEdits\|func removeParams" /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio/Services/RAWEditPresetStore.swift
```

预期能定位到 5 个函数。逐个改：

**`saveParams(_:, for:)`** — 当前函数体（约 line 92-98）：
```swift
    func saveParams(_ params: RAWEditParams, for assetID: String) {
        let key = assetParamsPrefix + assetID
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
```
改为：
```swift
    func saveParams(_ params: RAWEditParams, for assetID: String) {
        let key = assetParamsPrefix + assetID
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: key)
        }
        changeCounter += 1
    }
```

**`removeParams(for:)`** — 类似处理，函数末尾追加 `changeCounter += 1`。

**`saveJPGParams(_:, for:)`** — 同样末尾追加 `changeCounter += 1`。

**`saveLayerEdits(_:, for:)`** — 同样追加。

**`saveJPGLayerEdits(_:, for:)`** — 同样追加。

> 注：`changeCounter += 1` **永远** 在函数末尾（即使 `if let` 没成功落盘也算"想写过"）。这是为了即使序列化失败，UI 也会重新查询当前真实状态。

- [ ] **Step 3: 在文件末尾、最后一个 `}` 之前插入 mark/clear/query 方法**

找到文件末尾的 class 闭括号（`grep -n "^}" RawStudio/Services/RAWEditPresetStore.swift` 取最后一个）。在它之前插入：

```swift

    // MARK: - Preset Usage Tracking

    /// 标记用户在此 asset 上套用过 RAW 预设
    func markRawPresetUsed(for assetID: String) {
        UserDefaults.standard.set(true, forKey: usedRawPresetPrefix + assetID)
        changeCounter += 1
    }

    /// 标记用户在此 asset 上套用过 JPG 预设
    func markJpgPresetUsed(for assetID: String) {
        UserDefaults.standard.set(true, forKey: usedJpgPresetPrefix + assetID)
        changeCounter += 1
    }

    /// 清掉 RAW 预设标记（用户把 RAW 重置为默认时调）
    func clearRawPresetUsed(for assetID: String) {
        UserDefaults.standard.removeObject(forKey: usedRawPresetPrefix + assetID)
        changeCounter += 1
    }

    /// 清掉 JPG 预设标记
    func clearJpgPresetUsed(for assetID: String) {
        UserDefaults.standard.removeObject(forKey: usedJpgPresetPrefix + assetID)
        changeCounter += 1
    }

    // MARK: - Edit Status Queries

    /// 实际产出是否不同于原图（任一编辑数据非默认即是）
    func isEdited(for assetID: String) -> Bool {
        if loadParams(for: assetID).isModified { return true }
        if loadJPGParams(for: assetID).isModified { return true }
        if loadLayerEdits(for: assetID).hasAnyLayerEdits { return true }
        if loadJPGLayerEdits(for: assetID).hasAnyLayerEdits { return true }
        return false
    }

    /// 是否曾套用过任一预设（RAW 或 JPG）
    func hasUsedPreset(for assetID: String) -> Bool {
        UserDefaults.standard.bool(forKey: usedRawPresetPrefix + assetID) ||
        UserDefaults.standard.bool(forKey: usedJpgPresetPrefix + assetID)
    }
```

- [ ] **Step 4: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+badges/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`. 忽略 SourceKit 误报。

如果遇到 `Value of type 'LayerEdits' has no member 'hasAnyLayerEdits'` —— 罕见，但说明 `LayerEdits.hasAnyLayerEdits` 不存在。Plan 假设它存在（已 grep 验过 `RawStudio/Models/LayerEditParams.swift:91`），如不存在则 BLOCKED。

- [ ] **Step 5: Commit**

```bash
git add RawStudio/Services/RAWEditPresetStore.swift
git commit -m "$(cat <<'EOF'
feat(presets): add usage tracking + edit/preset queries + changeCounter

- Two new UserDefaults flags (usedRawPreset_<id>, usedJpgPreset_<id>)
- mark/clear methods for both
- isEdited(for:) checks all 4 edit sources for non-default
- hasUsedPreset(for:) returns true if either flag set
- changeCounter (@Observable var) bumped on every UserDefaults write
  so SwiftUI views observing it auto-refresh

Used by gallery cards in subsequent task to surface edit/preset badges.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Editors — preset 选中打标 + 保存时清标

**Files:**
- Modify: `RawStudio/Views/RAWEditorView.swift`（line 96-98 save 路径、line 119-121 preset onSelect）
- Modify: `RawStudio/Views/JPGEditorView.swift`（line 112-114 save 路径、line 134-136 preset onSelect）

- [ ] **Step 1: `RAWEditorView` preset onSelect 打标**

找到 line 119-121。当前：

```swift
                    onSelect: { preset in
                        params = preset.params
                    }
```

改为：

```swift
                    onSelect: { preset in
                        params = preset.params
                        presetStore.markRawPresetUsed(for: assetID)
                    }
```

- [ ] **Step 2: `RAWEditorView` save 路径条件清标**

找到 line 96-98。当前：

```swift
                        presetStore.saveParams(params, for: assetID)
                        presetStore.saveLayerEdits(layerEdits, for: assetID)
                        onDone(params, layerEdits)
```

改为：

```swift
                        presetStore.saveParams(params, for: assetID)
                        presetStore.saveLayerEdits(layerEdits, for: assetID)
                        if !params.isModified {
                            presetStore.clearRawPresetUsed(for: assetID)
                        }
                        onDone(params, layerEdits)
```

- [ ] **Step 3: `JPGEditorView` preset onSelect 打标**

找到 line 134-136。当前：

```swift
                    onSelect: { preset in
                        params = preset.params
                    }
```

改为：

```swift
                    onSelect: { preset in
                        params = preset.params
                        presetStore.markJpgPresetUsed(for: assetID)
                    }
```

- [ ] **Step 4: `JPGEditorView` save 路径条件清标**

找到 line 112-114。当前：

```swift
                        presetStore.saveJPGParams(params, for: assetID)
                        presetStore.saveJPGLayerEdits(layerEdits, for: assetID)
                        onDone(params, layerEdits, previewImage)
```

改为：

```swift
                        presetStore.saveJPGParams(params, for: assetID)
                        presetStore.saveJPGLayerEdits(layerEdits, for: assetID)
                        if !params.isModified {
                            presetStore.clearJpgPresetUsed(for: assetID)
                        }
                        onDone(params, layerEdits, previewImage)
```

- [ ] **Step 5: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+badges/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -5
```

**Expected:** `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add RawStudio/Views/RAWEditorView.swift RawStudio/Views/JPGEditorView.swift
git commit -m "$(cat <<'EOF'
feat(editors): mark preset-applied on selection, clear on reset-to-default

- RAWEditorView/JPGEditorView call mark*PresetUsed when preset picker
  fires onSelect
- On save, if final params == default (user fully reset), clear the
  preset flag so badge disappears
- Layer edits are independent — not affected by these flags

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Gallery cards — UI badges + 依赖注入

**Files:**
- Modify: `RawStudio/Views/PhotoCardView.swift`
- Modify: `RawStudio/Views/PhotoGridItemView.swift`
- Modify: `RawStudio/Views/GalleryView.swift`

- [ ] **Step 1: `PhotoCardView` 加 presetStore 参数 + indicatorBadge helper + 订阅 changeCounter + chip 区加 badge**

找到 `PhotoCardView.swift` 的 struct 定义顶部（约 line 3-8）：

```swift
struct PhotoCardView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    var manager: PhotoLibraryManager?
```

在 `manager` 那行下面追加：

```swift
    var presetStore: RAWEditPresetStore
```

找到 `var body: some View {` 那一行（约 line 19）。在它的左大括号 `{` 下一行（即 body 第一句之前）插入订阅触发：

```swift
    var body: some View {
        let _ = presetStore.changeCounter   // 订阅刷新触发
        HStack(spacing: 12) {
```

> 即在 `HStack(spacing: 12) {` 之前那一行插入 `let _ = presetStore.changeCounter`。

找到现有 chip 区（约 line 45-52）：

```swift
                HStack(spacing: 6) {
                    Text(pair.formatLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill, in: Capsule())
                }
```

整段替换为：

```swift
                HStack(spacing: 6) {
                    Text(pair.formatLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill, in: Capsule())

                    if presetStore.isEdited(for: pair.id) {
                        indicatorBadge(systemName: "pencil")
                    }
                    if presetStore.hasUsedPreset(for: pair.id) {
                        indicatorBadge(systemName: "wand.and.stars")
                    }
                }
```

在文件末尾（struct 闭合 `}` 之前）追加 helper：

```swift

    @ViewBuilder
    private func indicatorBadge(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.5), in: Circle())
    }
```

- [ ] **Step 2: `PhotoGridItemView` 同样改造**

找到 `PhotoGridItemView.swift` struct 顶部（约 line 3-7）：

```swift
struct PhotoGridItemView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    var manager: PhotoLibraryManager?
```

下方追加：

```swift
    var presetStore: RAWEditPresetStore
```

找到 body 开头（约 line 11）：

```swift
    var body: some View {
        GeometryReader { proxy in
```

在 `GeometryReader` 之前插入订阅：

```swift
    var body: some View {
        let _ = presetStore.changeCounter   // 订阅刷新触发
        GeometryReader { proxy in
```

找到 overlays 顶部 HStack（约 line 21-39）：

```swift
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        // RAW format badge
                        Text(pair.formatLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)

                        Spacer()

                        // Selection checkbox
                        if isSelecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .white)
                                .shadow(radius: 2)
                        }
                    }
                    .padding(6)
```

整个 HStack 体替换为：

```swift
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        // RAW format badge
                        Text(pair.formatLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)

                        Spacer()

                        // Edit / preset indicators
                        if presetStore.isEdited(for: pair.id) {
                            indicatorBadge(systemName: "pencil")
                        }
                        if presetStore.hasUsedPreset(for: pair.id) {
                            indicatorBadge(systemName: "wand.and.stars")
                        }

                        // Selection checkbox
                        if isSelecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .white)
                                .shadow(radius: 2)
                        }
                    }
                    .padding(6)
```

> 唯一改动：`HStack {` → `HStack(spacing: 4) {` 给 indicator 留点间距；中间 `Spacer()` 后插入两个 indicator 条件块；checkbox 块原样保留在 indicator 之后。

在 struct 闭合 `}` 之前追加同款 helper：

```swift

    @ViewBuilder
    private func indicatorBadge(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.5), in: Circle())
    }
```

- [ ] **Step 3: `GalleryView` 在两个 cell 调用处传 presetStore**

```bash
grep -n "PhotoCardView\|PhotoGridItemView" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+badges/RawStudio/Views/GalleryView.swift
```

预期能看到 `PhotoCardView(...)` 和 `PhotoGridItemView(...)` 的调用点。

`PhotoCardView` 调用（约 list 渲染处）：

当前：
```swift
                        PhotoCardView(
                            pair: pair,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(pair.id),
                            onToggleSelect: { toggleSelect(pair.id) },
                            manager: manager
                        )
```

改为（在 `manager` 后追加 `presetStore`）：

```swift
                        PhotoCardView(
                            pair: pair,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(pair.id),
                            onToggleSelect: { toggleSelect(pair.id) },
                            manager: manager,
                            presetStore: presetStore
                        )
```

`PhotoGridItemView` 调用（约 grid 渲染处）：

当前：
```swift
                            PhotoGridItemView(
                                pair: pair,
                                isSelecting: isSelecting,
                                isSelected: selectedIDs.contains(pair.id),
                                manager: manager
                            )
```

改为：

```swift
                            PhotoGridItemView(
                                pair: pair,
                                isSelecting: isSelecting,
                                isSelected: selectedIDs.contains(pair.id),
                                manager: manager,
                                presetStore: presetStore
                            )
```

- [ ] **Step 4: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+badges/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`

如果报 `Missing argument for parameter 'presetStore'` —— Step 3 漏改。如果报 `Cannot find type 'RAWEditPresetStore' in scope` —— 这是 SourceKit 误报，xcodebuild 看得到。

- [ ] **Step 5: Commit**

```bash
git add RawStudio/Views/PhotoCardView.swift RawStudio/Views/PhotoGridItemView.swift RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(gallery): add edited / preset-applied badges to photo cards

Cards now surface up to 2 SF Symbol indicators next to the format
chip / format badge:
- pencil — when isEdited(for:) is true (any of RAW params, JPG params,
  RAW layerEdits, JPG layerEdits non-default)
- wand.and.stars — when hasUsedPreset(for:) is true

Subscribes to presetStore.changeCounter so writes from editors
trigger an immediate re-render.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 真机肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: Build for device + 装机**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+badges/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/RawStudio-device-badges \
  -allowProvisioningUpdates build 2>&1 | tail -5

xcrun devicectl list devices 2>&1 | grep "Edvardzeng"

# 如果状态 connected：
xcrun devicectl device install app --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 \
  /tmp/RawStudio-device-badges/Build/Products/Debug-iphoneos/RawStudio.app
xcrun devicectl device process launch --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 com.edz.RawStudio
```

> 设备 unavailable 时让用户解锁/插紧 USB；或者 Xcode → Window → Devices and Simulators → 选设备 → "+" 装 `/tmp/RawStudio-device-badges/Build/Products/Debug-iphoneos/RawStudio.app`

- [ ] **Step 2: 验证项**

在手机上：

**测试 1：编辑 → 出 pencil**
- 进 RawStudio，找一张普通照片，点开 Compare
- Edit → 调任一滑杆（比如曝光）→ done → 退出回 Gallery
- **缩略图 chip 区应出现 ✏️ pencil**（列表视图）
- 切到网格视图，**缩略图右上角应出现 ✏️ pencil**

**测试 2：套预设 → 出 pencil + wand**
- 还是同一张照片（或换一张）→ Edit → 选个预设 → done → 退出
- **应同时显示 ✏️ + ⭐ 两个 badge**

**测试 3：重置 → badge 清除**
- 那张套了预设的照片 → Edit → Reset 按钮 → done
- **两个 badge 都消失**（因为 params 回到默认 + 我们清了 preset 标记）

**测试 4：持久化**
- 完全杀掉 app（双击 home 上滑）→ 重新启动
- 之前打过 badge 的照片仍然有 badge

- [ ] **Step 3: 没问题就完成**

如果一切 OK 不需要额外提交。如有问题报回主会话。

---

## 自检清单

- ✅ Spec § 1 (mark/clear/query + changeCounter) → Task 1 Steps 1-3
- ✅ Spec § 2 (UserDefaults.set 不触发 @Observable，需 changeCounter) → Task 1 Steps 1-2
- ✅ Spec § 3 (Editor preset onSelect 打标 + save 时条件清) → Task 2
- ✅ Spec § 4 (indicatorBadge helper) → Task 3 Step 1+2 (各加一份；DRY 损失可接受 — 两个文件本来就独立)
- ✅ Spec § 5 (PhotoGridItemView overlay 加 badges) → Task 3 Step 2
- ✅ Spec § 6 (PhotoCardView chip 区加 badges) → Task 3 Step 1
- ✅ Spec § 7 (依赖注入) → Task 3 Step 3
- ✅ 类型一致：`presetStore: RAWEditPresetStore`、`isEdited(for:)`、`hasUsedPreset(for:)`、`indicatorBadge(systemName:)` 全程同名
- ✅ 无 placeholder
- ✅ 替换 `LayerEdits.isEmpty` → `LayerEdits.hasAnyLayerEdits`（取反）— Spec § 1 备注里说过会 grep 确认；已确认存在
