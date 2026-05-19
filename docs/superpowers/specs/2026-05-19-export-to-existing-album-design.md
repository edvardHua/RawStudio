# Export to Existing Album

**Date:** 2026-05-19
**Status:** Approved, ready for implementation

## 问题

刚合入的 ExportOptionsSheet 只支持"新建相簿"或"不创建"。用户希望也能把这批导出送进**现有的 user album**（例如已有的"旅行"相簿）。

## 设计原则

- **三态枚举语义清楚**：替换 `newAlbumName: String?` 为 `AlbumTarget` 枚举（none / createNew / existing），互斥语义在类型层面保证
- **iOS Photos 习惯的交互**：segmented picker（不 / 新建 / 现有）+ 子可视区
- **复用现有 AlbumPickerView**：sheet-on-sheet，避免新写 UI
- **过滤可写相簿**：smart album（最近 / 截图 / 收藏等）不能被 `PHAssetCollectionChangeRequest.addAssets` 写入，picker 列表中过滤掉
- **显式选中要求**：用户选了"现有"但没选具体相簿时禁用主按钮

## 不在范围内（YAGNI）

- "创建相簿层级 / 文件夹"
- "选多个相簿同时加入"
- "智能相簿 favorite 通过 toggle 加入"（虽然技术上可行，跳出 picker 模型）
- "记住上次选过的相簿"（每次默认 .none）
- 单元测试（与项目其它功能一致，靠手动验证）

## 设计

### 1. 模型 — `ExportOptions.swift`

**当前**：

```swift
struct ExportOptions: Equatable {
    enum Source: Equatable { case original, fromRaw }
    enum Format: Equatable { case jpg, heic }
    var source: Source
    var format: Format
    var useHDR: Bool
    var newAlbumName: String?    // nil = 不创建相簿
}
```

**改为**：

```swift
struct ExportOptions: Equatable {
    enum Source: Equatable { case original, fromRaw }
    enum Format: Equatable { case jpg, heic }

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

> `newAlbumName: String?` 字段移除；初始化方式调整。所有调用方（`ExportOptionsSheet` `onConfirm`、`performExportBatch`）跟着改。

### 2. `ExportOptionsSheet.swift` — Save To section 改造

**新增 props**：

```swift
let manager: PhotoLibraryManager
```

**新增 @State**：

```swift
// 局部枚举，仅 sheet 内部用（picker tag）
private enum AlbumMode: Hashable {
    case none
    case createNew
    case existing
}

@State private var albumMode: AlbumMode = .none
@State private var selectedExistingAlbumID: String? = nil
@State private var selectedExistingAlbumTitle: String? = nil
@State private var showAlbumPicker: Bool = false
// albumName 字段保留（之前已有）
```

**Save To section 整段重写**：

```swift
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

**主按钮加 disable**：

```swift
let isReady: Bool = {
    switch albumMode {
    case .none, .createNew: return true
    case .existing: return selectedExistingAlbumID != nil
    }
}()

Button {
    // onConfirm 构造（见 §3）
} label: {
    Text("Export \(selectedCount) Photos")
        .font(.body.weight(.semibold))
        .foregroundStyle(isReady ? .white : Color.white.opacity(0.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            isReady ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.gray.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .padding(.horizontal, 16)
}
.buttonStyle(.plain)
.disabled(!isReady)
.padding(.top, 8)
```

**Sub-sheet 调用 AlbumPickerView**（放在 NavigationStack 上的 modifier）：

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

> `AlbumPickerView` 原样复用；它有 `onSelect` + `isPresented` 两个 binding，刚好够用。

### 3. `onConfirm` 构造 `ExportOptions.album`

```swift
let albumTarget: ExportOptions.AlbumTarget
switch albumMode {
case .none:
    albumTarget = .none
case .createNew:
    let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
    albumTarget = .createNew(name: trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
case .existing:
    // disabled-button 保证 selectedExistingAlbumID 非 nil；这里强解包安全
    albumTarget = .existing(id: selectedExistingAlbumID!)
}
onConfirm(ExportOptions(
    source: filter == .rawOnly ? .fromRaw : source,
    format: format,
    useHDR: useHDR,
    album: albumTarget
))
```

### 4. `PhotoLibraryManager.performExportBatch` 路由改造

当前 album 解析：

```swift
var album: PHAssetCollection? = nil
var albumError: String? = nil
if let name = options.newAlbumName, !name.isEmpty {
    do {
        album = try await createAlbum(name: name)
    } catch {
        albumError = error.localizedDescription
    }
}
```

替换为：

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
        }
    }
case .existing(let id):
    album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    if album == nil {
        albumError = String(localized: "Selected album not found")
    }
}
```

后续 `for pair in pairs { try await exportOne(... addToAlbum: album) }` 不动。

### 5. `GalleryView.swift` — sheet 调用处传 `manager`

```swift
.sheet(isPresented: $showExportSheet) {
    ExportOptionsSheet(
        selectedCount: selectedIDs.count,
        filter: sourceFilter,
        manager: manager,             // 新增
        onCancel: { showExportSheet = false },
        onConfirm: { options in
            showExportSheet = false
            executeExport(options: options)
        }
    )
}
```

### 6. Localization — 新增 zh-Hans 翻译

`Localizable.xcstrings` 加：
- "None" → "不"
- "New" → "新建"
- "Existing" → "现有"
- "Choose Album" → "选择相簿"
- "Not Selected" → "未选择"
- "Selected album not found" → "未找到所选相簿"

## 数据流

```
[用户在 sheet 选 segmented "Existing"]
  ↓ 子可视区显示 "选择相簿" 按钮
  ↓ 点 → 弹 AlbumPickerView sub-sheet
  ↓ 用户选「旅行」相簿 → onSelect callback
  ↓ selectedExistingAlbumID = "ABC123"; selectedExistingAlbumTitle = "旅行"
  ↓ Sub-sheet 关闭
  ↓ 主 sheet 显示「选择相簿 ... 旅行 ›」
  ↓ 主按钮 enabled
  ↓ 点 Export
  ↓ onConfirm 构造 ExportOptions(album: .existing(id: "ABC123"))
  ↓ executeExport → performExportBatch
  ↓ switch on options.album → fetchAssetCollections → PHAssetCollection
  ↓ 逐张 exportOne(... addToAlbum: collection)
  ↓ saveAsNewAsset 内部 placeholder + albumChange.addAssets
  ↓ Photos 库的「旅行」相簿出现新导出图
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| `manager.albums` 在新装 app / 用户没访问相簿时未加载 | `fetchAlbums()` 在启动时已调用过；为空时 picker 显示空列表（acceptable） |
| 用户选择的现有相簿被并发删除 | `fetchAssetCollections(...).firstObject` 返回 nil → `albumError` 写明，batch 仍跑（不加相簿） |
| Sheet-on-sheet iPad 上偶发动画卡 | iOS 18+ presentationDetents 兼容；如有问题改 NavigationLink push 但需重构 AlbumPickerView |
| smart album（最近/截图/收藏）误入 picker 列表 | `canPerform(.addContent)` 过滤 |
| disabled 按钮在 Existing 模式下没选相簿时点不动，但用户可能误以为坏了 | 灰化样式 + 文字"未选择"提示足够；不再加额外 alert |

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Models/ExportOptions.swift` | `newAlbumName: String?` → `AlbumTarget` enum + `album: AlbumTarget` 字段 |
| `RawStudio/Views/ExportOptionsSheet.swift` | 加 `manager` 参数；Save To section 重写（segmented + 子可视区）；新 @State；AlbumPickerView sub-sheet；主按钮 disable 条件 |
| `RawStudio/Services/PhotoLibraryManager.swift` | `performExportBatch` 里 album 解析改 switch on enum |
| `RawStudio/Views/GalleryView.swift` | sheet 调用处传 manager |
| `RawStudio/Localizable.xcstrings` | 加 6 个新 key 的 zh-Hans 翻译 |

## 验证

- 真机：在 RAW+JPG 或 RAW 模式选 N 张 → Export
- segmented 「不」→ 主按钮可点 → 导出到「所有照片」，不进相簿
- segmented 「新建」→ 输入框预填 → Export → 出现新相簿
- segmented 「现有」→ 主按钮 disabled（灰色 + 0.5 opacity）→ 点「选择相簿 ... 未选择」→ 弹 picker
- Picker 只显示**可写**用户相簿（"最近"、"收藏"、"截图"等 smart album 不在列表里）
- 选一个 → 返回主 sheet 显示「选择相簿 ... XXX ›」→ 主按钮变蓝可点
- 点 Export → 进入该相簿，Photos 库验证
- 系统语言中英文切换：各处文案正常 localize
