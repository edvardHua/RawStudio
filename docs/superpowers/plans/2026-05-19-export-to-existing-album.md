# Export to Existing Album Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ExportOptionsSheet 的 Save To section 从「不/新建」两态扩展为「不/新建/现有」三态，现有相册通过 sub-sheet（复用 AlbumPickerView）选择，并过滤掉不可写入的 smart album。

**Architecture:** `ExportOptions.newAlbumName: String?` 替换为 `album: AlbumTarget` 枚举（`none / createNew(name:) / existing(id:)`）。`ExportOptionsSheet` 加 `manager` 参数和 `AlbumMode` 局部枚举（picker 标签），Save To section 重写为 segmented + 子可视区。`PhotoLibraryManager.performExportBatch` 改 switch on enum。

**Tech Stack:** Swift 5 / SwiftUI / Photos.framework / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-19-export-to-existing-album-design.md`

**项目背景：**
- 当前分支：`worktree-feat+export-sheet`，HEAD `0bcec18`（含 i18n 提交）
- 真机：iPhone 15 Pro Max (`E71BC21F-DC20-5570-9A10-6F3CF3CA5B28`)
- 模拟器：iPhone 17 Pro (`DFABFFCE-4305-46F5-B38B-35BFCD1EB986`)
- LSP/SourceKit 在 PBXFileSystemSynchronizedRootGroup 项目里有恼人误报，**只信 xcodebuild 输出**
- 现有 `AlbumPickerView`（`RawStudio/Views/GalleryView.swift:525`）签名：`(albums: [Album], selectedAlbumID: String?, onSelect: (Album) -> Void, isPresented: Binding<Bool>)` — 完整复用
- 现有 `Album` 模型（`RawStudio/Models/Album.swift`）有 `id: String`、`title: String`、`collection: PHAssetCollection`
- `manager.albums` 已通过 `fetchAlbums()` 加载（启动时调用）
- `PHAssetCollection.canPerform(.addContent)` 用于过滤可写相簿（smart album 通常返回 false）

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/ExportOptions.swift` | `newAlbumName: String?` 字段 → `album: AlbumTarget` enum |
| `RawStudio/Services/PhotoLibraryManager.swift` | `performExportBatch` 的 album 解析改 switch on enum |
| `RawStudio/Views/ExportOptionsSheet.swift` | 加 `manager` 参数；Save To section 重写；新 `AlbumMode` 局部 enum + 4 个 @State；AlbumPickerView sub-sheet；主按钮 disable |
| `RawStudio/Views/GalleryView.swift` | sheet 调用处传 `manager: manager` |
| `RawStudio/Localizable.xcstrings` | 加 6 个新 key 的 zh-Hans 翻译 |

---

## Task 1: 模型迁移（shape-only，无行为变化）

**Files:**
- Modify: `RawStudio/Models/ExportOptions.swift`（整个文件重写）
- Modify: `RawStudio/Services/PhotoLibraryManager.swift:719-740`（`performExportBatch` 内 album 解析块）
- Modify: `RawStudio/Views/ExportOptionsSheet.swift:67-75`（`onConfirm` 内 finalAlbumName 构造）

- [ ] **Step 1: 重写 `ExportOptions.swift`**

整个文件替换为：

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

    enum AlbumTarget: Equatable {
        case none
        case createNew(name: String)
        case existing(id: String)    // PHAssetCollection.localIdentifier
    }

    var source: Source
    var format: Format
    var useHDR: Bool
    var album: AlbumTarget
}
```

> 删除 `newAlbumName: String?`，添加 `AlbumTarget` 枚举 + `album: AlbumTarget` 字段。

- [ ] **Step 2: 更新 `PhotoLibraryManager.performExportBatch` 的 album 解析**

定位：

```bash
grep -n "func performExportBatch\|newAlbumName" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Services/PhotoLibraryManager.swift
```

预期：`func performExportBatch` 约 line 719；`if let name = options.newAlbumName, !name.isEmpty` 约 line 730。

找到当前块（约 lines 728-739）：

```swift
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
```

整段替换为：

```swift
        var album: PHAssetCollection? = nil
        var albumError: String? = nil
        switch options.album {
        case .none:
            break
        case .createNew(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                do {
                    album = try await createAlbum(name: trimmed)
                } catch {
                    albumError = error.localizedDescription
                    // 不中止；继续导出但不加入相册
                }
            }
        case .existing(let id):
            album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            if album == nil {
                albumError = String(localized: "Selected album not found")
            }
        }
```

- [ ] **Step 3: 更新 `ExportOptionsSheet.onConfirm` 构造**

定位：

```bash
grep -n "finalAlbumName\|newAlbumName" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/ExportOptionsSheet.swift
```

找到当前块（约 lines 66-75 — Primary button 内的 `Button { ... }` 中）：

```swift
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
```

整段替换为（注意：仍用现有 `saveToNewAlbum`/`albumName` @State；Task 2 才重做这些）：

```swift
                    Button {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let albumTarget: ExportOptions.AlbumTarget
                        if saveToNewAlbum {
                            albumTarget = .createNew(name: trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
                        } else {
                            albumTarget = .none
                        }
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            album: albumTarget
                        ))
                    } label: {
```

> Task 1 完成后：UI 行为完全不变（仍是 toggle + textfield），但内部数据走新枚举。

- [ ] **Step 4: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. 忽略 SourceKit 误报。

如果遇到 `Missing argument for parameter 'newAlbumName'` 或 `'album'` — 漏改某个调用点。grep:
```bash
grep -rn "newAlbumName\|ExportOptions(source" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio --include="*.swift"
```

- [ ] **Step 5: Commit**

```bash
git add RawStudio/Models/ExportOptions.swift RawStudio/Services/PhotoLibraryManager.swift RawStudio/Views/ExportOptionsSheet.swift
git commit -m "$(cat <<'EOF'
refactor(export): replace newAlbumName String? with AlbumTarget enum

ExportOptions gains AlbumTarget { none / createNew(name:) / existing(id:) }
in place of the previous newAlbumName: String?. This shape-only refactor
prepares for the next task adding the "existing album" UI mode — the
enum encodes the three states with type-system mutual exclusion.

performExportBatch routes album resolution via switch (existing case
still resolves to createAlbum). ExportOptionsSheet onConfirm constructs
.createNew or .none from the existing saveToNewAlbum toggle; UI behavior
unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Sheet UI 重设计 + GalleryView 传 manager

**Files:**
- Modify: `RawStudio/Views/ExportOptionsSheet.swift`（substantial rewrite of Save To section + state + sub-sheet）
- Modify: `RawStudio/Views/GalleryView.swift`（sheet 调用处加 `manager: manager`）

- [ ] **Step 1: 在 `ExportOptionsSheet.swift` 加 `manager` 参数 + 新 @State**

定位 struct 顶部属性声明（约 lines 3-13）。当前：

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
```

整段替换为：

```swift
struct ExportOptionsSheet: View {
    let selectedCount: Int
    let filter: SourceFilter
    let manager: PhotoLibraryManager
    let onCancel: () -> Void
    let onConfirm: (ExportOptions) -> Void

    // 局部 picker tag，不污染 ExportOptions 模型
    private enum AlbumMode: Hashable {
        case none
        case createNew
        case existing
    }

    @State private var source: ExportOptions.Source = .original
    @State private var format: ExportOptions.Format = .jpg
    @State private var useHDR: Bool = false
    @State private var albumMode: AlbumMode = .none
    @State private var albumName: String = ExportOptionsSheet.defaultAlbumName()
    @State private var selectedExistingAlbumID: String? = nil
    @State private var selectedExistingAlbumTitle: String? = nil
    @State private var showAlbumPicker: Bool = false
```

> 删除 `saveToNewAlbum`（被 `albumMode` 取代）；保留 `albumName`（createNew 模式仍用）；加 manager 参数 + AlbumMode 枚举 + 3 个新 @State。

- [ ] **Step 2: 重写 Save To section**

定位现有 Save To section（约 lines 50-60）。当前：

```swift
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
```

整段替换为：

```swift
                    // Save To
                    sectionGroup(title: String(localized: "Save To")) {
                        VStack(spacing: 12) {
                            Picker("", selection: $albumMode) {
                                Text("None").tag(AlbumMode.none)
                                Text("New").tag(AlbumMode.createNew)
                                Text("Existing").tag(AlbumMode.existing)
                            }
                            .pickerStyle(.segmented)

                            switch albumMode {
                            case .none:
                                EmptyView()

                            case .createNew:
                                TextField(String(localized: "Album Name"), text: $albumName)
                                    .textFieldStyle(.roundedBorder)
                                    .submitLabel(.done)

                            case .existing:
                                Button {
                                    showAlbumPicker = true
                                } label: {
                                    HStack {
                                        Text(String(localized: "Choose Album"))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(selectedExistingAlbumTitle ?? String(localized: "Not Selected"))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
```

- [ ] **Step 3: 重写主按钮 — 加 disable + 新 onConfirm 构造**

定位现有主按钮 Button block（约 lines 65-86）：

```swift
                    Button {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let albumTarget: ExportOptions.AlbumTarget
                        if saveToNewAlbum {
                            albumTarget = .createNew(name: trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
                        } else {
                            albumTarget = .none
                        }
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            album: albumTarget
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
```

整段替换为：

```swift
                    Button {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let albumTarget: ExportOptions.AlbumTarget
                        switch albumMode {
                        case .none:
                            albumTarget = .none
                        case .createNew:
                            albumTarget = .createNew(name: trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
                        case .existing:
                            // disabled-button 守卫保证 selectedExistingAlbumID 非 nil
                            albumTarget = .existing(id: selectedExistingAlbumID!)
                        }
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            album: albumTarget
                        ))
                    } label: {
                        Text("Export \(selectedCount) Photos")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isExportReady ? .white : Color.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                isExportReady ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.gray.opacity(0.5)),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isExportReady)
                    .padding(.top, 8)
```

- [ ] **Step 4: 加 `isExportReady` 计算属性**

在 `body` 之外、`defaultAlbumName()` 之上（或 struct 任意位置）插入：

```swift
    private var isExportReady: Bool {
        switch albumMode {
        case .none, .createNew: return true
        case .existing: return selectedExistingAlbumID != nil
        }
    }
```

- [ ] **Step 5: 加 AlbumPickerView sub-sheet modifier**

定位 `.presentationDetents([.medium, .large])`（约 line 102，在 NavigationStack 收尾处）。在它**上方**插入 `.sheet` modifier：

```swift
            .sheet(isPresented: $showAlbumPicker) {
                let writableAlbums = manager.albums.filter { $0.collection.canPerform(.addContent) }
                AlbumPickerView(
                    albums: writableAlbums,
                    selectedAlbumID: selectedExistingAlbumID,
                    onSelect: { album in
                        selectedExistingAlbumID = album.id
                        selectedExistingAlbumTitle = album.title
                    },
                    isPresented: $showAlbumPicker
                )
            }
```

放在 NavigationStack 闭合 `}` 之前（与 `.toolbar { ... }` 同级）。

- [ ] **Step 6: `GalleryView.swift` — sheet 调用处传 `manager`**

定位：

```bash
grep -n "ExportOptionsSheet(" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/GalleryView.swift
```

预期约 line 110。当前：

```swift
                ExportOptionsSheet(
                    selectedCount: selectedIDs.count,
                    filter: sourceFilter,
                    onCancel: { showExportSheet = false },
                    onConfirm: { options in
                        showExportSheet = false
                        executeExport(options: options)
                    }
                )
```

替换为（在 `filter:` 后插入 `manager: manager,`）：

```swift
                ExportOptionsSheet(
                    selectedCount: selectedIDs.count,
                    filter: sourceFilter,
                    manager: manager,
                    onCancel: { showExportSheet = false },
                    onConfirm: { options in
                        showExportSheet = false
                        executeExport(options: options)
                    }
                )
```

- [ ] **Step 7: Build verify**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

如果遇到 `Missing argument for parameter 'manager'` — Step 6 漏改。
如果遇到 `Cannot find 'saveToNewAlbum'` — Step 2/3 没把 `saveToNewAlbum` 引用全清掉。grep:
```bash
grep -n "saveToNewAlbum" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Views/ExportOptionsSheet.swift
```
应该返回 0 hits。

- [ ] **Step 8: Commit**

```bash
git add RawStudio/Views/ExportOptionsSheet.swift RawStudio/Views/GalleryView.swift
git commit -m "$(cat <<'EOF'
feat(export-sheet): add "existing album" mode via 3-way segmented picker

Save To section becomes None / New / Existing. Existing pushes
AlbumPickerView as a sub-sheet (filtered to canPerform(.addContent)
user albums — smart albums excluded). Main button disabled in
Existing mode until an album is chosen.

ExportOptionsSheet now takes a manager: PhotoLibraryManager to access
manager.albums. GalleryView's sheet call updated accordingly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: zh-Hans 翻译

**Files:**
- Modify: `RawStudio/Localizable.xcstrings`（加 6 个 keys）

- [ ] **Step 1: 加 6 个新 key 的 zh-Hans 翻译**

定位插入点 — Wand 前面（保持字母序）：

```bash
grep -n "\"Wand\"" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Localizable.xcstrings
```

应在末尾附近。在 `"Wand" : { ... }` **前面**插入 6 个新条目（必须维持 JSON 合法，每个条目后加 `,`）。

需要插入的 keys（按字母序）：
- `"Choose Album"` → "选择相簿"
- `"Existing"` → "现有"
- `"New"` → "新建"
- `"None"` → "不"
- `"Not Selected"` → "未选择"
- `"Selected album not found"` → "未找到所选相簿"

> 字母序：C < E < N(ew) < N(one) < N(ot) < S < W

具体插入方法：用 `Read` 找到 `"Wand"` 那行（约 1405 左右），然后整段替换 `"Wand" : { ... }` 块为新 6 个条目 + 保留原 Wand。

参考已有 entry 格式（每个 entry 这样）：

```json
    "Choose Album" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "选择相簿"
          }
        }
      }
    },
```

完整插入块（6 entries，最后那个也加逗号，因为 Wand 跟在后面）：

```json
    "Choose Album" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "选择相簿"
          }
        }
      }
    },
    "Existing" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "现有"
          }
        }
      }
    },
    "New" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "新建"
          }
        }
      }
    },
    "None" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "不"
          }
        }
      }
    },
    "Not Selected" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "未选择"
          }
        }
      }
    },
    "Selected album not found" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "未找到所选相簿"
          }
        }
      }
    },
```

把这 6 个 entries 插在 `"Wand" : {` 那一行的**正上方**（注意缩进 4 空格）。

- [ ] **Step 2: JSON 合法性 + build 双验证**

```bash
python3 -m json.tool /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio/Localizable.xcstrings > /dev/null && echo "JSON OK"
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -3
```

Expected: `JSON OK` + `** BUILD SUCCEEDED **`

如果 JSON 报错（缺逗号、引号不闭合等），用 `Read` 找到 Wand 上方区域看格式。

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
i18n(export-sheet): add zh-Hans for existing-album UI keys

- None → 不
- New → 新建
- Existing → 现有
- Choose Album → 选择相簿
- Not Selected → 未选择
- Selected album not found → 未找到所选相簿

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 真机肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: Build for device + 装机**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+export-sheet/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/RawStudio-device-existing-album \
  -allowProvisioningUpdates build 2>&1 | tail -5

xcrun devicectl list devices 2>&1 | grep "Edvardzeng"

# 如果设备 connected/available：
xcrun devicectl device install app --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 \
  /tmp/RawStudio-device-existing-album/Build/Products/Debug-iphoneos/RawStudio.app
xcrun devicectl device process launch --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 com.edz.RawStudio
```

> 设备 unavailable / launch 失败时：让用户解锁手机 + 信任证书 + 手动点 app 图标启动

- [ ] **Step 2: 验证项**

**A. UI 出现：**
- RAW+JPG 模式选 N 张 → Export → 弹 sheet
- Save To section 出现 segmented：`不 / 新建 / 现有`（中文）或 `None / New / Existing`（英文）
- 默认选「不」→ 主按钮可点

**B. 「新建」模式（回归测试）：**
- 切到「新建」→ 显示 TextField，预填 `Export YYYY-MM-DD HH:mm`
- 修改名称为「测试新建」→ Export
- Photos 库出现「测试新建」相簿，里面是导出图

**C. 「现有」模式（新功能核心）：**
- 切到「现有」→ 显示「选择相簿 ... 未选择 ›」按钮 + 主按钮 disabled（灰色）
- 点按钮 → 弹 sub-sheet（AlbumPickerView）
- **列表只显示 user album**（"最近"、"截图"、"收藏"等 smart album 不在列表里 — Apple 系统创建的 smart album）
- 选一个相簿 → sub-sheet 关 → 主 sheet 显示「选择相簿 ... 旅行 ›」
- 主按钮变蓝可点 → Export
- 退回 Photos 库 → 该相簿中出现新导出的照片

**D. 边角：**
- 「现有」模式 + 没选相簿 → 主按钮一直 disabled
- 系统语言中英文切换：各处文案正常 localize

- [ ] **Step 3: 没问题就完成**

如果一切 OK 不需要额外提交。如有问题报回主会话。

---

## 自检清单

- ✅ Spec § 1 (AlbumTarget 枚举) → Task 1 Step 1
- ✅ Spec § 2 (UI 重做：manager 参数 + AlbumMode + segmented + 子可视区) → Task 2 Steps 1-2
- ✅ Spec § 3 (AlbumPickerView sub-sheet 复用 + canPerform 过滤) → Task 2 Step 5
- ✅ Spec § 4 (主按钮 disable + isExportReady) → Task 2 Steps 3-4
- ✅ Spec § 5 (onConfirm 构造 AlbumTarget) → Task 2 Step 3
- ✅ Spec § 6 (performExportBatch switch on enum) → Task 1 Step 2
- ✅ Spec § 7 (GalleryView 传 manager) → Task 2 Step 6
- ✅ Spec § 8 / § 9 (i18n 6 keys) → Task 3
- ✅ 类型一致：`ExportOptions.AlbumTarget`、`AlbumMode` 全程命名一致；`selectedExistingAlbumID` 等 @State 名称贯穿
- ✅ 无 placeholder
