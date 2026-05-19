# Photo Color Tags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 5 色（红橙黄绿蓝）单选标签系统，3 个进入点（顶部筛选 pill / 批量 toolbar / CompareView），缩略图 card 显示颜色圆点。

**Architecture:** 新 `PhotoTag` enum + `PhotoTagStore` service（与 `RAWEditPresetStore` 同款 UserDefaults prefix + `@Observable changeCounter` pattern）。`ContentView` 创建 store 传给 `GalleryView`，再透传给 `PhotoCardView` / `PhotoGridItemView` / `CompareView`。

**Tech Stack:** Swift 5 / SwiftUI / @Observable / UserDefaults / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-19-photo-color-tags-design.md`

**项目背景：**
- 当前分支：`main` (HEAD `dcd750c`，spec commit)
- 真机：iPhone 15 Pro Max (`E71BC21F-DC20-5570-9A10-6F3CF3CA5B28`)
- 模拟器：iPhone 17 Pro (`DFABFFCE-4305-46F5-B38B-35BFCD1EB986`)
- LSP/SourceKit 在 PBXFileSystemSynchronizedRootGroup 项目里有恼人误报，**只信 xcodebuild 输出**
- Store 创建在 `ContentView.swift`（不是 `RawStudioApp.swift`，与现有 `manager`/`presetStore` 同位）
- 已有 `AlbumPickerView`（GalleryView.swift 内）— 不动
- `RAWEditPresetStore` 已是 `@Observable` 并有 `changeCounter: Int` —— 完全照搬

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/PhotoTag.swift` | **新文件**：5 色 enum + color/label |
| `RawStudio/Services/PhotoTagStore.swift` | **新文件**：UserDefaults + changeCounter |
| `RawStudio/ContentView.swift` | 新 `@State tagStore` + 传给 GalleryView |
| `RawStudio/Views/GalleryView.swift` | 加 `tagStore` 参数；filter pill 加第 4 个 Tag menu；`@State tagFilter`；filteredPairs 加 tag 过滤；batch toolbar 加 Tag 按钮；call sites 传 tagStore 给 cell views + CompareView |
| `RawStudio/Views/PhotoCardView.swift` | 加 `tagStore` 参数；chip 区追加 tag dot；body 顶部订阅 changeCounter |
| `RawStudio/Views/PhotoGridItemView.swift` | 加 `tagStore` 参数；overlay HStack 追加 tag dot；body 顶部订阅 |
| `RawStudio/Views/CompareView.swift` | 加 `tagStore` 参数 + init 接收；actionRow 3 case 都插入 `tagMenuButton`；body 顶部订阅 |
| `RawStudio/Localizable.xcstrings` | 加 8 个新 key：Red/Orange/Yellow/Green/Blue/Tag/All Tags/Clear Tag |

---

## Task 1: 数据层 — `PhotoTag` + `PhotoTagStore`

**Files:**
- Create: `RawStudio/Models/PhotoTag.swift`
- Create: `RawStudio/Services/PhotoTagStore.swift`

- [ ] **Step 1: 新文件 `RawStudio/Models/PhotoTag.swift`**

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

- [ ] **Step 2: 新文件 `RawStudio/Services/PhotoTagStore.swift`**

```swift
import Foundation

@Observable
final class PhotoTagStore {
    private let prefix = "photoTag_"

    /// SwiftUI 订阅刷新触发器（UserDefaults.set 不触发 @Observable 通知）
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

    /// 批量打标 / 清标（一次 changeCounter 自增内完成，避免连续刷新）
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

- [ ] **Step 3: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. 忽略 SourceKit 误报。

- [ ] **Step 4: Commit**

```bash
git add RawStudio/Models/PhotoTag.swift RawStudio/Services/PhotoTagStore.swift
git commit -m "$(cat <<'EOF'
feat(model): add PhotoTag enum + PhotoTagStore service

5-color tag system (red/orange/yellow/green/blue) backed by per-asset
UserDefaults entries (prefix "photoTag_"). Mirrors RAWEditPresetStore's
@Observable + changeCounter pattern so SwiftUI views auto-refresh
after setTag(_:for:) writes.

PhotoTag exposes Color (SwiftUI) and localized label for menu items.
PhotoTagStore offers both single-asset and batch setTag overloads;
both bump changeCounter exactly once (not per-asset) to avoid render
storms during batch operations.

No consumers yet; Task 2 wires it through ContentView/GalleryView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `ContentView` 创建 store + `GalleryView` 基础接线（filter pill + filteredPairs + batch toolbar）

**Files:**
- Modify: `RawStudio/ContentView.swift`
- Modify: `RawStudio/Views/GalleryView.swift`

> 这个 task 完成后：`GalleryView` 可以筛选/批量打标，但缩略图 card 还没显示颜色点（T3 加）、CompareView 还没 Tag menu（T4 加）。

- [ ] **Step 1: `ContentView` 创建 tagStore + 传入 GalleryView**

找到 `ContentView.swift` 当前内容（约 line 11-12）：

```swift
struct ContentView: View {
    @State private var manager = PhotoLibraryManager()
    @State private var presetStore = RAWEditPresetStore()
```

在 `presetStore` 下面追加：

```swift
    @State private var tagStore = PhotoTagStore()
```

找到 `GalleryView(manager: manager, presetStore: presetStore)` 调用（约 line 22），改为：

```swift
                GalleryView(manager: manager, presetStore: presetStore, tagStore: tagStore)
```

- [ ] **Step 2: `GalleryView` 加 `tagStore` 参数 + `tagFilter` state**

找到 `GalleryView.swift` 顶部 struct 属性（约 line 20-26）：

```swift
struct GalleryView: View {
    @Bindable var manager: PhotoLibraryManager
    var presetStore: RAWEditPresetStore
    @State private var sourceFilter: SourceFilter = .all
```

在 `presetStore` 下面加一行：

```swift
    var tagStore: PhotoTagStore
```

在 `sourceFilter` 下面加一行（与既有 @State 同位）：

```swift
    @State private var tagFilter: PhotoTag? = nil
```

- [ ] **Step 3: `filteredPairs` 加 tag 过滤分支**

找到 `filteredPairs` 计算属性（约 line 50-57）。当前：

```swift
    private var filteredPairs: [PhotoPair] {
        switch sourceFilter {
        case .all:         return manager.pairs
        case .rawJPGPairs: return manager.pairs.filter { $0.kind == .rawJpgPair }
        case .rawOnly:     return manager.pairs.filter { $0.kind == .rawOnly }
        }
    }
```

整段替换为（订阅 changeCounter + 链式过滤）：

```swift
    private var filteredPairs: [PhotoPair] {
        let _ = tagStore.changeCounter   // 订阅 tag 变化触发刷新
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

- [ ] **Step 4: filter pill row 加第 4 个 Tag 胶囊**

定位 filter pill 区：

```bash
grep -n "filterCapsule(.*All\|filterCapsule(.*RAW+JPG\|filterCapsule(.*\"RAW\"," /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/GalleryView.swift
```

当前 filter row（约 line 254-271）：

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

在 `filterCapsule(... .rawOnly ...)` 块之后、`Spacer()` 之前，插入 Tag Menu 胶囊：

```swift
                filterCapsule(
                    label: String(localized: "RAW"),
                    isActive: sourceFilter == .rawOnly
                ) { sourceFilter = .rawOnly }

                tagFilterCapsule

                Spacer()
```

然后在文件内添加 `tagFilterCapsule` 计算属性。定位现有 `filterCapsule` helper:

```bash
grep -n "private func filterCapsule" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/GalleryView.swift
```

在 `filterCapsule(label:isActive:action:)` 函数闭合 `}` 之后插入：

```swift

    /// 顶部 Tag 筛选胶囊 — 第 4 个 pill，点开 Menu 选颜色
    private var tagFilterCapsule: some View {
        Menu {
            Button {
                tagFilter = nil
            } label: {
                Label(String(localized: "All Tags"),
                      systemImage: tagFilter == nil ? "checkmark" : "circle")
            }
            Divider()
            ForEach(PhotoTag.allCases) { tag in
                Button {
                    tagFilter = tag
                } label: {
                    Label(tag.label,
                          systemImage: tagFilter == tag ? "checkmark.circle.fill" : "circle.fill")
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
                    .foregroundStyle(tagFilter == nil ? Color.primary : .white)
            }
            .padding(.horizontal, smallCapsulePadH)
            .padding(.vertical, smallCapsulePadV)
            .background(
                tagFilter == nil
                    ? AnyShapeStyle(.ultraThinMaterial)
                    : AnyShapeStyle(Color.accentColor),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 5: Batch toolbar 加 Tag 按钮（3 个 filter 场景都加）**

定位 `batchActionCapsules`：

```bash
grep -n "private var batchActionCapsules" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/GalleryView.swift
```

当前内容：

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

整段替换为（在 Delete 前面插入 tagCapsuleMenu）：

```swift
    private var batchActionCapsules: some View {
        HStack(spacing: 10) {
            switch sourceFilter {
            case .all:
                tagCapsuleMenu
                deleteCapsule { confirmBatchDelete() }
            case .rawJPGPairs, .rawOnly:
                batchCapsule(icon: "square.and.arrow.up", label: "Export") {
                    showExportSheet = true
                }
                tagCapsuleMenu
                deleteCapsule { confirmBatchDelete() }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
```

在 `deleteCapsule` helper 函数闭合 `}` 之后（grep `private func deleteCapsule` 定位）插入：

```swift

    /// 批量打标胶囊 — 选中模式下出现
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
                    .lineLimit(1)
            }
            .padding(.horizontal, capsulePadH)
            .padding(.vertical, capsulePadV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 6: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

如果 `Missing argument for parameter 'tagStore'` — Step 1 的 GalleryView call 没改对。
如果 `Cannot find 'tagFilter' in scope` — Step 2 没加 @State。

- [ ] **Step 7: Commit**

```bash
git add RawStudio/ContentView.swift RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(gallery): wire tagStore for filter pill + batch tag + filteredPairs

- ContentView creates PhotoTagStore @State, passes to GalleryView
- GalleryView gains tagStore param + tagFilter @State
- filteredPairs adds tag filter step on top of source filter
  (subscribes to changeCounter for SwiftUI auto-refresh)
- 4th filter pill "Tag" with Menu: All Tags + 5 colors, active state
  shows colored dot + accent background
- Batch toolbar gains tagCapsuleMenu in both All and RAW+JPG/RAW modes;
  Menu offers 5 colors + Clear Tag (destructive)

Cell views (PhotoCardView/PhotoGridItemView) and CompareView still
unaware of tags — next tasks surface them visually.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `PhotoCardView` + `PhotoGridItemView` 加 tag 颜色点

**Files:**
- Modify: `RawStudio/Views/PhotoCardView.swift`
- Modify: `RawStudio/Views/PhotoGridItemView.swift`
- Modify: `RawStudio/Views/GalleryView.swift`（call sites 加 tagStore 参数）

- [ ] **Step 1: `PhotoCardView` 加 `tagStore` 参数**

找到 PhotoCardView struct 属性（约 line 3-9）。当前：

```swift
struct PhotoCardView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    var manager: PhotoLibraryManager?
    var presetStore: RAWEditPresetStore
```

在 `presetStore` 下面追加：

```swift
    var tagStore: PhotoTagStore
```

- [ ] **Step 2: `PhotoCardView` body 顶部订阅 tagStore.changeCounter**

找到 `var body: some View {` 内的第一行（约 line 20，应该是 `let _ = presetStore.changeCounter`）。在它下方加一行：

```swift
    var body: some View {
        let _ = presetStore.changeCounter
        let _ = tagStore.changeCounter
        HStack(spacing: 12) {
```

- [ ] **Step 3: `PhotoCardView` chip 区追加 tag dot**

找到 chip area（约 line 46-55）。当前：

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

在末尾的 `}` 前追加 tag dot：

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
                    if let t = tagStore.tag(for: pair.id) {
                        Circle()
                            .fill(t.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
                    }
                }
```

- [ ] **Step 4: `PhotoGridItemView` 加 `tagStore` 参数**

找到 PhotoGridItemView struct 属性（约 line 3-8）。当前：

```swift
struct PhotoGridItemView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    var manager: PhotoLibraryManager?
    var presetStore: RAWEditPresetStore
```

在 `presetStore` 下面追加：

```swift
    var tagStore: PhotoTagStore
```

- [ ] **Step 5: `PhotoGridItemView` body 顶部订阅**

找到 `var body: some View {` 内的第一行（应该是 `let _ = presetStore.changeCounter`）。在它下方加：

```swift
    var body: some View {
        let _ = presetStore.changeCounter
        let _ = tagStore.changeCounter
        GeometryReader { proxy in
```

- [ ] **Step 6: `PhotoGridItemView` overlay HStack 追加 tag dot**

找到 overlay HStack（约 line 22-50）。当前结构：

```swift
                    HStack(spacing: 4) {
                        // RAW format badge
                        Text(pair.formatLabel)...

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

在两个 `if presetStore` block 后、`// Selection checkbox` 注释前插入 tag dot：

```swift
                    HStack(spacing: 4) {
                        // RAW format badge
                        Text(pair.formatLabel)...   // (existing code unchanged)

                        Spacer()

                        // Edit / preset indicators
                        if presetStore.isEdited(for: pair.id) {
                            indicatorBadge(systemName: "pencil")
                        }
                        if presetStore.hasUsedPreset(for: pair.id) {
                            indicatorBadge(systemName: "wand.and.stars")
                        }
                        if let t = tagStore.tag(for: pair.id) {
                            Circle()
                                .fill(t.color)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
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

- [ ] **Step 7: `GalleryView` 在两个 cell 调用处传 `tagStore`**

定位 cell view 调用点：

```bash
grep -n "PhotoCardView(\|PhotoGridItemView(" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/GalleryView.swift
```

**`PhotoCardView(...)` 调用** — 当前：

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

改为（追加 `tagStore: tagStore`）：

```swift
                        PhotoCardView(
                            pair: pair,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(pair.id),
                            onToggleSelect: { toggleSelect(pair.id) },
                            manager: manager,
                            presetStore: presetStore,
                            tagStore: tagStore
                        )
```

**`PhotoGridItemView(...)` 调用** — 当前：

```swift
                            PhotoGridItemView(
                                pair: pair,
                                isSelecting: isSelecting,
                                isSelected: selectedIDs.contains(pair.id),
                                manager: manager,
                                presetStore: presetStore
                            )
```

改为：

```swift
                            PhotoGridItemView(
                                pair: pair,
                                isSelecting: isSelecting,
                                isSelected: selectedIDs.contains(pair.id),
                                manager: manager,
                                presetStore: presetStore,
                                tagStore: tagStore
                            )
```

- [ ] **Step 8: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add RawStudio/Views/PhotoCardView.swift RawStudio/Views/PhotoGridItemView.swift RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(card): tag dot badge on PhotoCardView / PhotoGridItemView

Both cell views accept tagStore: PhotoTagStore. When the asset has a
tag, a 10pt filled circle (with subtle white stroke) appears in the
existing badge row next to pencil/wand. Bodies subscribe to
tagStore.changeCounter so setTag writes trigger an immediate
re-render. GalleryView call sites pass tagStore through.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `CompareView` 加 `tagMenuButton` 到 action row

**Files:**
- Modify: `RawStudio/Views/CompareView.swift`
- Modify: `RawStudio/Views/GalleryView.swift`（CompareView call site 加 tagStore）

- [ ] **Step 1: `CompareView` 加 `tagStore` 属性 + init 参数**

找到 CompareView 顶部 props（约 line 8）：

```swift
    var presetStore: RAWEditPresetStore
```

下面追加：

```swift
    var tagStore: PhotoTagStore
```

找到 init（约 line 41）：

```swift
    init(manager: PhotoLibraryManager, pairs: [PhotoPair], startIndex: Int, presetStore: RAWEditPresetStore) {
        self.manager = manager
        self._pairs = State(initialValue: pairs)
        self.startIndex = startIndex
        self.presetStore = presetStore
        self._currentIndex = State(initialValue: startIndex)
    }
```

整段替换为：

```swift
    init(manager: PhotoLibraryManager, pairs: [PhotoPair], startIndex: Int, presetStore: RAWEditPresetStore, tagStore: PhotoTagStore) {
        self.manager = manager
        self._pairs = State(initialValue: pairs)
        self.startIndex = startIndex
        self.presetStore = presetStore
        self.tagStore = tagStore
        self._currentIndex = State(initialValue: startIndex)
    }
```

- [ ] **Step 2: body 顶部订阅 tagStore.changeCounter**

定位 `var body: some View {`。在 body 内的最开头插入订阅行：

```bash
grep -n "var body: some View" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/CompareView.swift
```

约 line 62。在 `var body: some View {` 后的第一行（应该是 `ZStack {` 或类似）之前插入：

```swift
    var body: some View {
        let _ = tagStore.changeCounter
        ZStack {
```

（如果 body 第一行不是 ZStack，就在 body 闭合大括号 `{` 之后、首个 View 之前插入。）

- [ ] **Step 3: 加 `tagMenuButton` helper**

找到 `actionItem` helper（约 line 363）。在它之上或之下插入新 helper：

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

- [ ] **Step 4: actionRow 3 个 case 都插入 `tagMenuButton`**

找到 `actionRow`：

```bash
grep -n "private var actionRow" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/CompareView.swift
```

当前内容（约 line 331-360）：

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
                    if isHDRJpgSource {
                        actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDRFromImage() }
                        actionDivider
                    }
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

整段替换为（每个 case 在 Edit 之前插入 `tagMenuButton actionDivider`）：

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
                    tagMenuButton
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }

                case .rawJpgPair:
                    actionItem(icon: "square.and.arrow.down", label: "Save JPG") { performAction(.keepJPG) }
                    actionDivider
                    actionItem(icon: "square.and.arrow.down.fill", label: "Save RAW") { performAction(.keepRAW) }
                    actionDivider
                    tagMenuButton
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                    actionDivider
                    // HDR menu
                    hdrMenuButton

                case .jpgOnly:
                    if isHDRJpgSource {
                        actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDRFromImage() }
                        actionDivider
                    }
                    tagMenuButton
                    actionDivider
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

- [ ] **Step 5: `GalleryView` 在 CompareView 调用处传 `tagStore`**

定位：

```bash
grep -n "CompareView(" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Views/GalleryView.swift
```

找到调用（约 line 130-135）。当前：

```swift
                CompareView(
                    manager: manager,
                    pairs: filteredPairs,
                    startIndex: index,
                    presetStore: presetStore
                )
```

改为：

```swift
                CompareView(
                    manager: manager,
                    pairs: filteredPairs,
                    startIndex: index,
                    presetStore: presetStore,
                    tagStore: tagStore
                )
```

- [ ] **Step 6: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add RawStudio/Views/CompareView.swift RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(compare): add Tag menu button to action row (3 kind branches)

CompareView gains tagStore: PhotoTagStore via new init parameter.
Each pair.kind branch in actionRow inserts a tagMenuButton between
the existing actions and Edit. Button face shows the current tag
color as a filled circle, or a tag icon when untagged. Menu offers
5 colors + Clear Tag (destructive).

GalleryView's CompareView call site updated to pass tagStore.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Localization — 8 个新 zh-Hans key

**Files:**
- Modify: `RawStudio/Localizable.xcstrings`

需要加的 key（按字母序）：
- `All Tags` → 所有标签
- `Blue` → 蓝
- `Clear Tag` → 清除标签
- `Green` → 绿
- `Orange` → 橙
- `Red` → 红
- `Tag` → 标签
- `Yellow` → 黄

- [ ] **Step 1: 定位插入点**

```bash
grep -n '"Wand" :' /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Localizable.xcstrings
```

预期约 line 1465（前一次 export-sheet 插入完之后）。"Wand" 应仍是最后一项。

确认字母序插入位置（每个 key 落点）：
- `All Tags` — 在 "All" 后面（line ~94 附近，A 段）
- `Blue` / `Clear Tag` — 在 B / C 段
- `Green` / `Orange` / `Red` / `Yellow` — 各自字母段
- `Tag` — T 段

按 Xcode 实际行为，**严格字母序不重要**，只要 JSON 合法即可。Xcode 重新打开会自动重排。

为了减少 grep 麻烦，**全部追加到 Wand 之前**即可（一次性插入 8 个）。

- [ ] **Step 2: 在 `"Wand" : {` 之前插入 8 个新条目**

定位 `"Wand"` 行后，把整段 `"Wand" : { ... }` 块替换为 8 个新条目 + 保留的 Wand：

`Read` 当前 `"Wand"` 块（约 11 行）。然后用 `Edit` 把它替换为下面（注意每个新条目末尾的 `,`，Wand 是最后一项无尾 `,`）：

```json
    "All Tags" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "所有标签"
          }
        }
      }
    },
    "Blue" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "蓝"
          }
        }
      }
    },
    "Clear Tag" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "清除标签"
          }
        }
      }
    },
    "Green" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "绿"
          }
        }
      }
    },
    "Orange" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "橙"
          }
        }
      }
    },
    "Red" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "红"
          }
        }
      }
    },
    "Tag" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "标签"
          }
        }
      }
    },
    "Yellow" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "黄"
          }
        }
      }
    },
    "Wand" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "魔棒"
          }
        }
      }
    }
```

- [ ] **Step 3: JSON 合法性 + build 双验证**

```bash
python3 -m json.tool /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio/Localizable.xcstrings > /dev/null && echo "JSON OK"
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -3
```

Expected: `JSON OK` + `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add RawStudio/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
i18n(tags): add zh-Hans for 5 tag colors + 3 UI strings

- Red / Orange / Yellow / Green / Blue → 红 / 橙 / 黄 / 绿 / 蓝
- Tag → 标签
- All Tags → 所有标签
- Clear Tag → 清除标签

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 真机肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: Build for device + 装机**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+tags/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/RawStudio-device-tags \
  -allowProvisioningUpdates build 2>&1 | tail -5

xcrun devicectl list devices 2>&1 | grep "Edvardzeng"

xcrun devicectl device install app --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 \
  /tmp/RawStudio-device-tags/Build/Products/Debug-iphoneos/RawStudio.app
xcrun devicectl device process launch --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 com.edz.RawStudio
```

> 如果 launch 失败 "Security/未信任"，让用户解锁 + 点 iPhone 设置里的开发者证书 Trust，然后手动点 RawStudio 图标启动。

- [ ] **Step 2: 验证项**

**A. 顶部 filter pill：**
- 主页应看到第 4 个胶囊：图标 "🏷️ Tag"（未选标签时）
- 点开 → Menu 弹出：「所有标签」 + 5 色（红橙黄绿蓝带颜色圆点）
- 选「红」→ pill 变蓝底白字，左侧显示红色小圆点
- 列表过滤为只剩红标项（空列表如果还没打标）

**B. 批量打标：**
- 切回「所有标签」→ 选 3 张照片
- 底部 batch toolbar 出现：All 模式 `[Tag] [Delete]`；RAW+JPG / RAW 模式 `[Export] [Tag] [Delete]`
- 点 Tag → Menu 弹 5 色 + Clear Tag → 选「红」
- 退选择 → 3 张 card 右上角出现 ● 红点（grid mode 和 list mode 都验）

**C. CompareView 单图打标：**
- 进入某红标项 Compare → action row 出现 Tag 按钮（face 为红色圆点）
- 点 Tag → Menu → 选「蓝」 → 按钮 face 变蓝
- 退回主页 → card 红点变蓝
- 再进 Compare → Tag → Clear Tag → 退回 → card 上无圆点

**D. 持久化：**
- 杀掉 app（双击 Home 上滑）→ 重启
- 之前打过的标签状态保持

**E. i18n：**
- 切系统语言为英文 → menu 文案变 Red/Orange/.../Blue/Tag/All Tags/Clear Tag
- 切回中文 → 全部中文

- [ ] **Step 3: 没问题就完成**

如果一切 OK 不需要额外提交。如有问题报回主会话。

---

## 自检清单

- ✅ Spec § 1 (PhotoTag enum) → Task 1 Step 1
- ✅ Spec § 2 (PhotoTagStore service) → Task 1 Step 2
- ✅ Spec § 3 (App root tagStore 注入) → Task 2 Step 1（ContentView，不是 RawStudioApp，已注明）
- ✅ Spec § 4 (filter pill 加 Tag menu + filteredPairs 加 tag 过滤) → Task 2 Steps 2-4
- ✅ Spec § 5 (batch toolbar 加 Tag 按钮 3 场景) → Task 2 Step 5
- ✅ Spec § 6 (CompareView tagMenuButton) → Task 4 Steps 3-4
- ✅ Spec § 7 (PhotoCardView + PhotoGridItemView tag dot) → Task 3
- ✅ Spec § 8 (依赖注入透传链) → Task 2 Step 2 + Task 3 Step 7 + Task 4 Step 5
- ✅ 类型一致：`PhotoTag`、`PhotoTagStore`、`tagStore: PhotoTagStore`、`tagFilter: PhotoTag?` 全程命名一致
- ✅ 无 placeholder（每步都有完整代码或命令）
