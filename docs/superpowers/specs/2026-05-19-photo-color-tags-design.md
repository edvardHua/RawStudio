# Photo Color Tags (macOS Finder-style)

**Date:** 2026-05-19
**Status:** Approved, ready for implementation

## 问题

用户希望给单张/多张照片打颜色标签（红橙黄绿蓝），方便后续：
- 在缩略图上一眼识别已标记的照片
- 用顶部筛选快速过滤出某一颜色（"我今天想处理所有红标的"）
- 批量打/清除标签

类似 macOS Finder 的 5-7 色标签系统，但单选（一图一色）。

## 设计原则

- **复用现有 UserDefaults + changeCounter pattern**（与 `RAWEditPresetStore` 同款），不需要新存储后端
- **每图最多 1 个标签**，简化 UI 与批量操作语义（覆盖、不切换）
- **三个进入点**：批量 toolbar、CompareView action row、顶部筛选 pill
- **视觉与现有 badge 共存**：纯色小圆点 ●，无背景胶囊，最多 3 badge（pencil ✏️ + wand ⭐ + dot ●）
- **5 个固定颜色**：红橙黄绿蓝，无自定义名称（不像 macOS 那样可重命名）

## 不在范围内（YAGNI）

- 多 tag / 一图多色
- 自定义标签名称
- 自定义标签颜色
- 拖拽分组 / sidebar
- 同步到 PhotoKit 元数据（PhotoKit 不暴露这种字段）
- 旧 asset 被 Photos 删除时主动清掉残留 UserDefaults 项（无功能影响，可后期清理）
- 单元测试（与项目其它功能一致，靠手动验证）

## 设计

### 1. 数据模型 — `RawStudio/Models/PhotoTag.swift`（新文件）

```swift
import SwiftUI

enum PhotoTag: String, CaseIterable, Identifiable, Codable {
    case red
    case orange
    case yellow
    case green
    case blue

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        }
    }

    var label: String {
        switch self {
        case .red:    return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green:  return String(localized: "Green")
        case .blue:   return String(localized: "Blue")
        }
    }
}
```

### 2. 存储 — `RawStudio/Services/PhotoTagStore.swift`（新文件）

```swift
import Foundation

@Observable
final class PhotoTagStore {
    private let prefix = "photoTag_"

    /// SwiftUI 订阅刷新触发器（UserDefaults.set 不触发 @Observable）
    var changeCounter: Int = 0

    func tag(for assetID: String) -> PhotoTag? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + assetID) else {
            return nil
        }
        return PhotoTag(rawValue: raw)
    }

    func setTag(_ tag: PhotoTag?, for assetID: String) {
        let key = prefix + assetID
        if let tag {
            UserDefaults.standard.set(tag.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        changeCounter += 1
    }

    /// 批量打标 / 清标（在一次 changeCounter 自增内完成，避免连续触发）
    func setTag(_ tag: PhotoTag?, for assetIDs: [String]) {
        for id in assetIDs {
            let key = prefix + id
            if let tag {
                UserDefaults.standard.set(tag.rawValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        changeCounter += 1
    }
}
```

完全照搬 `RAWEditPresetStore` 的 UserDefaults + changeCounter 套路；视图通过 body 顶部 `let _ = tagStore.changeCounter` 订阅。

### 3. App root 注入 — `RawStudio/RawStudioApp.swift`

新增 `@State private var tagStore = PhotoTagStore()`，传给 GalleryView。

### 4. 主页筛选 — 加第 4 个 Tag 胶囊

`GalleryView.swift` filter pill row 加：

```swift
@State private var tagFilter: PhotoTag? = nil

// 在 HStack 里 RAW 胶囊后面：
Menu {
    Button {
        tagFilter = nil
    } label: {
        Label(String(localized: "All Tags"), systemImage: tagFilter == nil ? "checkmark" : "circle")
    }
    Divider()
    ForEach(PhotoTag.allCases) { tag in
        Button {
            tagFilter = tag
        } label: {
            Label(tag.label, systemImage: tagFilter == tag ? "checkmark.circle.fill" : "circle.fill")
                .foregroundStyle(tag.color)
        }
    }
} label: {
    HStack(spacing: 4) {
        if let t = tagFilter {
            Circle().fill(t.color).frame(width: 10, height: 10)
        } else {
            Image(systemName: "tag")
                .font(.footnote)
        }
        Text(String(localized: "Tag"))
            .font(.footnote.weight(.medium))
    }
    .padding(.horizontal, smallCapsulePadH)
    .padding(.vertical, smallCapsulePadV)
    .background(
        tagFilter == nil ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.accentColor.opacity(0.15)),
        in: Capsule()
    )
}
.buttonStyle(.plain)
```

> 用 Menu + Button 而不是 Picker，是因为 Label 里要带颜色 Image。

**`filteredPairs` 链上加 tag 过滤：**

```swift
private var filteredPairs: [PhotoPair] {
    let _ = tagStore.changeCounter   // 订阅 tag 变化刷新
    let base: [PhotoPair]
    switch sourceFilter {
    case .all:         base = manager.pairs
    case .rawJPGPairs: base = manager.pairs.filter { $0.kind == .rawJpgPair }
    case .rawOnly:     base = manager.pairs.filter { $0.kind == .rawOnly }
    }
    if let tag = tagFilter {
        return base.filter { tagStore.tag(for: $0.id) == tag }
    }
    return base
}
```

### 5. Batch toolbar 加 Tag 按钮（3 个 filter 场景都加）

`batchActionCapsules` 改：

- **All 模式**：`[Tag] [Delete]`
- **RAW+JPG / RAW 模式**：`[Export] [Tag] [Delete]`

新 helper：

```swift
private var tagCapsuleMenu: some View {
    Menu {
        ForEach(PhotoTag.allCases) { tag in
            Button {
                tagStore.setTag(tag, for: Array(selectedIDs))
            } label: {
                Label(tag.label, systemImage: "circle.fill")
                    .foregroundStyle(tag.color)
            }
        }
        Divider()
        Button(role: .destructive) {
            tagStore.setTag(nil, for: Array(selectedIDs))
        } label: {
            Label(String(localized: "Clear Tag"), systemImage: "xmark.circle")
        }
    } label: {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.subheadline.weight(.medium))
            Text(String(localized: "Tag"))
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, capsulePadH)
        .padding(.vertical, capsulePadV)
        .background(.ultraThinMaterial, in: Capsule())
    }
    .buttonStyle(.plain)
}
```

打标后**不自动退出 selecting 模式**（用户可能继续 Export 或继续打更多）。

### 6. CompareView action row 加 Tag

`CompareView.swift` actionRow 三个 case 都插入 `tagMenuButton`：

- `.jpgOnly` case: `[Tag] [Edit]`（如有 HDR JPEG：`[HDR JPEG] [Tag] [Edit]`）
- `.rawOnly` case: `[HDR HEIF] [HDR JPEG] [Tag] [Edit]`
- `.rawJpgPair` case: `[Save JPG] [Save RAW] [Tag] [Edit] [HDR menu]`

新 helper（vstack 风格与现有 actionItem 一致，但 Menu 包裹）：

```swift
private var tagMenuButton: some View {
    Menu {
        ForEach(PhotoTag.allCases) { tag in
            Button {
                if let pair = currentPair {
                    tagStore.setTag(tag, for: pair.id)
                }
            } label: {
                Label(tag.label, systemImage: "circle.fill")
                    .foregroundStyle(tag.color)
            }
        }
        Divider()
        Button(role: .destructive) {
            if let pair = currentPair {
                tagStore.setTag(nil, for: pair.id)
            }
        } label: {
            Label(String(localized: "Clear Tag"), systemImage: "xmark.circle")
        }
    } label: {
        VStack(spacing: 3) {
            if let pair = currentPair, let t = tagStore.tag(for: pair.id) {
                Circle()
                    .fill(t.color)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
            } else {
                Image(systemName: "tag")
                    .font(.body)
            }
            Text(String(localized: "Tag"))
                .font(.caption2)
        }
        .foregroundStyle(.primary.opacity(0.85))
        .frame(maxWidth: .infinity)
    }
}
```

### 7. 缩略图 card 加颜色点 badge

**`PhotoCardView`（list）chip 区紧跟 wand 后：**

```swift
HStack(spacing: 6) {
    Text(pair.formatLabel)...
    if presetStore.isEdited(for: pair.id) { indicatorBadge(systemName: "pencil") }
    if presetStore.hasUsedPreset(for: pair.id) { indicatorBadge(systemName: "wand.and.stars") }
    if let t = tagStore.tag(for: pair.id) {
        Circle()
            .fill(t.color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
    }
}
```

**`PhotoGridItemView`（grid）overlay HStack 同位置：**

```swift
HStack(spacing: 4) {
    Text(pair.formatLabel)...     // format badge
    Spacer()
    if presetStore.isEdited(for: pair.id) { indicatorBadge(systemName: "pencil") }
    if presetStore.hasUsedPreset(for: pair.id) { indicatorBadge(systemName: "wand.and.stars") }
    if let t = tagStore.tag(for: pair.id) {
        Circle()
            .fill(t.color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
    }
    if isSelecting { /* checkbox */ }
}
```

`let _ = tagStore.changeCounter` 在 body 顶部订阅，确保 setTag 后 cell 立即重渲染。

### 8. 依赖注入 — `tagStore` 透传链

```
RawStudioApp (持有 @State PhotoTagStore)
  ↓ tagStore
GalleryView
  ├ tagStore → PhotoCardView (chip 加颜色点)
  ├ tagStore → PhotoGridItemView (overlay 加颜色点)
  └ tagStore → CompareView (action row 加 Tag menu)
```

每层视图加 `var tagStore: PhotoTagStore` 参数。

### 9. 数据流

```
[选 N 张 + 点 batch Tag → 选红]
  ↓ tagStore.setTag(.red, for: ids)
  ↓ UserDefaults 批量写 + changeCounter += 1
  ↓ @Observable 通知所有读 tagStore.changeCounter 的视图
  ↓ filteredPairs 重算（如果 tagFilter 启用）
  ↓ PhotoCardView/GridItemView body 重新渲染 → 红点 badge 出现

[Compare 单图 Tag → 蓝]
  ↓ tagStore.setTag(.blue, for: pair.id)
  ↓ changeCounter += 1
  ↓ Compare actionRow 的 tagMenuButton 重新渲染（圆点颜色变蓝）

[顶部 Tag pill → 选红]
  ↓ tagFilter = .red (local @State)
  ↓ filteredPairs 重算
  ↓ gallery 只剩红标项
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| asset 被 Photos 删除后 UserDefaults 残留 tag 数据 | 无功能影响（每项 ~30 字节），后期可加 sweep；本期不处理 |
| 标签颜色 `.red` 等在浅色背景对比度 | 加 0.5pt 白色描边确保暗背景上可见 |
| 三个 badge (pencil/wand/dot) 同时存在挤占 grid cell 顶部 | grid cell ~130×130pt，4-5 个小元素够放；现有 wand+pencil 同存已验证过 |
| 4 个 filter pill 在 iPhone SE 这种窄屏可能挤 | 现有 3 个就接近极限；4 个会比较紧。Plan 阶段实测，必要时把 "RAW+JPG" 缩到 "Pair" |
| 批量打标后视图不刷新 | changeCounter 模式与 RAWEditPresetStore 验过；body 顶部订阅就行 |
| Menu Button 的 Label tint 在 iOS 18+ 表现 | iOS 17+ Menu 支持 `.foregroundStyle()` on Label；iOS 26 部署目标 OK |

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/PhotoTag.swift` | **新文件**：enum 5 色 + color/label |
| `RawStudio/Services/PhotoTagStore.swift` | **新文件**：UserDefaults + changeCounter |
| `RawStudio/RawStudioApp.swift` | 新建 PhotoTagStore + 传入 GalleryView |
| `RawStudio/Views/GalleryView.swift` | 加 `tagStore` 参数；filter pill 加第 4 个 Tag menu；batch toolbar 加 Tag 按钮（3 场景）；filteredPairs 链上加 tag 过滤；传 tagStore 给 PhotoCardView / PhotoGridItemView / CompareView |
| `RawStudio/Views/CompareView.swift` | 加 `tagStore` 参数；actionRow 3 个 case 都插入 tagMenuButton |
| `RawStudio/Views/PhotoCardView.swift` | 加 `tagStore` 参数；chip 区追加 tag dot；body 顶部订阅 changeCounter |
| `RawStudio/Views/PhotoGridItemView.swift` | 加 `tagStore` 参数；overlay HStack 追加 tag dot；body 顶部订阅 |
| `RawStudio/Localizable.xcstrings` | 加 8 个新 key：Red/Orange/Yellow/Green/Blue/Tag/All Tags/Clear Tag |

## 验证

- 主页选 3 张照片 → batch toolbar 点 **Tag** → 弹 menu 选「红」→ 退出选择
- 3 张 card 右上角应出现 ● 红点
- 顶部 **Tag** pill 点开 → 选「红」→ 列表仅剩这 3 张
- Tag pill 切回 **All Tags** → 列表恢复
- 进入某红标项 Compare → action row 出现 **Tag**（按钮 icon 变红圆点） → 点开 menu 选「蓝」→ 退出
- 回主页该 card 的红点变蓝
- Compare → Tag → **Clear Tag** → card 上点消失
- 杀掉 app 重启 → 标签状态持久化
- 中英文系统语言切换 → menu 文案、All Tags、Clear Tag 全部 localize
