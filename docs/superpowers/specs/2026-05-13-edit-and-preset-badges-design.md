# 主页面缩略图卡片：编辑/预设标识

**Date:** 2026-05-13
**Status:** Approved, ready for implementation

## 问题

GalleryView 的列表 / 网格视图的缩略图卡片只显示原始格式 badge（ARW / DNG / HEIC 等），无法一眼看出哪些照片已经编辑过、哪些套用过预设。用户希望：

1. **已编辑标识**：当照片实际产出已不同于原图时显示
2. **预设套用标识**：用户在该照片上至少套用过一次预设时显示（后续手动微调不清）
3. 一张缩略图卡片最多 2 个标识

## 设计原则

- **"已编辑"严格语义**：实际产出和原图不一致才算 — 检查 RAW params / JPG params / RAW layerEdits / JPG layerEdits 任一非默认
- **"预设套用"是一次性事件**：用户在编辑器里点过预设就打标，重置回默认才清（后续微调保持有标）
- **新追踪与现有 params 解耦**：单独存 `usedRawPreset_<id>` / `usedJpgPreset_<id>` 两个 flag，不污染现有 params 结构
- **图标 badge**：与现有 RAW format badge 同款样式（半透明黑底 + 白色 SF Symbol），保持视觉一致

## 不在范围内（YAGNI）

- 显示具体预设名（仅显示"用过预设"的通用标识）
- 编辑历史 / 时间戳
- 区分 RAW 编辑 vs JPG 编辑两种 badge（合并为单一"已编辑"）
- Badge 长按显示详情等交互
- 单元测试（与项目其他功能一致，靠手动验证）

## 设计

### 1. `RAWEditPresetStore` — 预设套用标记 + 综合查询

新增 2 个 UserDefaults key prefix：

```swift
private let usedRawPresetPrefix = "usedRawPreset_"
private let usedJpgPresetPrefix = "usedJpgPreset_"
```

新增 4 个 mark/clear 方法：

```swift
/// 标记用户在此 asset 上套用过 RAW 预设
func markRawPresetUsed(for assetID: String) {
    UserDefaults.standard.set(true, forKey: usedRawPresetPrefix + assetID)
    bumpChangeCounter()
}

func markJpgPresetUsed(for assetID: String) {
    UserDefaults.standard.set(true, forKey: usedJpgPresetPrefix + assetID)
    bumpChangeCounter()
}

/// 清掉 RAW 预设标记（用户把 RAW 重置为默认时调）
func clearRawPresetUsed(for assetID: String) {
    UserDefaults.standard.removeObject(forKey: usedRawPresetPrefix + assetID)
    bumpChangeCounter()
}

func clearJpgPresetUsed(for assetID: String) {
    UserDefaults.standard.removeObject(forKey: usedJpgPresetPrefix + assetID)
    bumpChangeCounter()
}
```

新增 2 个查询：

```swift
/// 实际产出是否不同于原图（任一编辑数据非默认即是）
func isEdited(for assetID: String) -> Bool {
    if loadParams(for: assetID).isModified { return true }
    if loadJPGParams(for: assetID).isModified { return true }
    if !loadLayerEdits(for: assetID).isEmpty { return true }
    if !loadJPGLayerEdits(for: assetID).isEmpty { return true }
    return false
}

/// 是否曾套用过任一预设（RAW 或 JPG）
func hasUsedPreset(for assetID: String) -> Bool {
    UserDefaults.standard.bool(forKey: usedRawPresetPrefix + assetID) ||
    UserDefaults.standard.bool(forKey: usedJpgPresetPrefix + assetID)
}
```

> 假设 `LayerEdits` 已有 `isEmpty` 计算属性。Plan 阶段先 grep 确认；如无，加上一行扩展。

### 2. `@Observable` 刷新机制

`RAWEditPresetStore` 现状是否 `@Observable` —— Plan 阶段确认。如不是则加 `@Observable`。

`UserDefaults.standard.set` 不会自动触发 `@Observable` 通知。在 store 里加：

```swift
/// 任意写操作后递增，迫使依赖此属性的 SwiftUI 视图重渲染
var changeCounter: Int = 0

private func bumpChangeCounter() {
    changeCounter += 1
}
```

并在所有"写到 UserDefaults"的方法（`saveParams`, `saveJPGParams`, `saveLayerEdits`, `saveJPGLayerEdits`, `removeParams`, `mark*`, `clear*`）末尾调 `bumpChangeCounter()`。

视图侧通过读 `changeCounter`（直接或间接，比如 `_ = presetStore.changeCounter` 在 body 里）订阅变化。

> 备选：若 store 已经是 `@Observable` 但 `saveParams` 等已经触发了观察通知（例如本身写了 `@Published` 属性），可省略 changeCounter 步骤。Plan 阶段确认。

### 3. Editor 接入

**`RAWEditorView.swift`** preset onSelect callback（约 line 119-121）：

```swift
onSelect: { preset in
    params = preset.params
    presetStore.markRawPresetUsed(for: assetID)   // 新增
}
```

**`JPGEditorView.swift`** 同理（约 line 134-136）。

**Reset 路径**：找编辑器内的"Reset" / `params.reset()` / `params = RAWEditParams()` 调用点（plan 阶段 grep）。在每个 reset 后追加：
- RAW: `presetStore.clearRawPresetUsed(for: assetID)`
- JPG: `presetStore.clearJpgPresetUsed(for: assetID)`

**Save 路径**：在编辑器 onDone 回调里，如果 `params.isModified == false`（用户回到了默认），同样调 `clearXxxPresetUsed`。这覆盖"用户用滑杆把每个值手动拉回默认"这个边角。

### 4. UI badges helper（PhotoCardView + PhotoGridItemView 复用）

两种位置都用同款样式（与现有 raw format badge 风格统一）：

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

图标：
- `pencil` — 已编辑
- `wand.and.stars` — 预设套用

### 5. PhotoGridItemView — 网格单元格 overlay

现有结构（约 line 20-44）顶部 HStack：左边 format badge，右边 selection checkbox。改为：左 format / 中 spacer / 右一组（指示器 + checkbox）：

```swift
HStack(spacing: 4) {
    // RAW format badge (现有 — 不动)
    Text(pair.formatLabel)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(.white)

    Spacer()

    // 新增 — 编辑/预设指示器
    if presetStore.isEdited(for: pair.id) {
        indicatorBadge(systemName: "pencil")
    }
    if presetStore.hasUsedPreset(for: pair.id) {
        indicatorBadge(systemName: "wand.and.stars")
    }

    // Selection checkbox (现有 — 保留位置)
    if isSelecting {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .shadow(radius: 2)
    }
}
.padding(6)
```

### 6. PhotoCardView — 列表行

现有结构（约 line 45-52）信息列里有一行 chip 区只放了 format chip。改为：

```swift
HStack(spacing: 6) {
    Text(pair.formatLabel)
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.fill, in: Capsule())

    // 新增 — 编辑/预设指示器
    if presetStore.isEdited(for: pair.id) {
        indicatorBadge(systemName: "pencil")
    }
    if presetStore.hasUsedPreset(for: pair.id) {
        indicatorBadge(systemName: "wand.and.stars")
    }
}
```

### 7. 依赖注入

`PhotoCardView` / `PhotoGridItemView` 当前签名只有 `manager: PhotoLibraryManager?`。需要加：

```swift
var presetStore: RAWEditPresetStore
```

`GalleryView` 已经持有 `presetStore`（line 22 `var presetStore: RAWEditPresetStore`）— 在 `PhotoCardView(...)` 和 `PhotoGridItemView(...)` 调用处传入即可。

### 8. 数据流

```
[用户进 Edit → 选预设]
  ↓ presetStore.markRawPresetUsed (or markJpgPresetUsed)
  ↓ UserDefaults 写入 + changeCounter 自增
  ↓ SwiftUI 通过观察 changeCounter 触发 PhotoCard/Grid 重渲染
  ↓ presetStore.hasUsedPreset(for: pair.id) → true → wand.and.stars badge 出现

[用户调滑杆 → 保存]
  ↓ presetStore.saveParams (or savePreset/saveLayerEdits)
  ↓ UserDefaults 写入 + changeCounter 自增
  ↓ presetStore.isEdited(for: pair.id) → true → pencil badge 出现

[用户重置]
  ↓ presetStore.removeParams + clearRawPresetUsed
  ↓ changeCounter 自增 → badges 消失
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| `RAWEditPresetStore` 不是 `@Observable` | Plan 阶段确认；如不是则加上 |
| `LayerEdits.isEmpty` 不存在 | Plan 阶段加 `var isEmpty: Bool` 计算属性 |
| 旧已编辑 asset 没有 preset 标记 | 符合预期 — 没人记录过；用户重新进编辑器套预设即标。**不需要数据迁移**。 |
| 每个 cell 出现都查 4 次 UserDefaults | 单 key 读 ~µs；LazyVStack/LazyVGrid 仅可见 cell；忽略 |
| `UserDefaults.set` 不触发 `@Observable` | `bumpChangeCounter()` 显式触发；视图通过读 `changeCounter` 订阅 |
| 编辑器 reset 路径有多处（RAW reset、JPG reset、layer reset） | Plan 阶段 grep 全部 reset 调用点逐一接入；新增 changeCounter 触发兜底 |
| 用户拉滑杆 → 看似默认但浮点不严格相等 | `RAWEditParams.isModified` 用 `self != RAWEditParams()`，结构体 `==` 自动逐字段比较；浮点字面量 `1.0` 等通常严格相等。可接受 |

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Services/RAWEditPresetStore.swift` | 加 2 个 key prefix、4 个 mark/clear、2 个 query、changeCounter 字段 + bumpChangeCounter 调用、必要时加 `@Observable` |
| `RawStudio/Models/LayerEditParams.swift` | 视情况加 `isEmpty` 计算属性 |
| `RawStudio/Views/RAWEditorView.swift` | preset onSelect 加 mark；找 reset 路径加 clear；onDone 检查 isModified == false 时 clear |
| `RawStudio/Views/JPGEditorView.swift` | 同上 |
| `RawStudio/Views/PhotoCardView.swift` | 加 `presetStore` 参数、加 `indicatorBadge` helper、chip 区追加 2 个条件 badge |
| `RawStudio/Views/PhotoGridItemView.swift` | 加 `presetStore` 参数、加 `indicatorBadge` helper、overlay HStack 追加 2 个条件 badge |
| `RawStudio/Views/GalleryView.swift` | 在 PhotoCardView / PhotoGridItemView 调用处传 `presetStore: presetStore` |

## 验证

- 真机：找一张照片 → Compare → Edit → 调任一滑杆 → done → 回 Gallery
  - 列表行 chip 区应出现 ✏️ pencil
  - 切到网格视图，缩略图右上角应出现 ✏️ pencil
- 同一张照片 → Edit → 选个预设 → done → 回 Gallery
  - 应同时显示 ✏️ + ⭐
- Edit → 重置回默认 → done → 回 Gallery
  - 两个 badge 都消失
- 重启 app 后 badge 状态保持（数据持久化）
