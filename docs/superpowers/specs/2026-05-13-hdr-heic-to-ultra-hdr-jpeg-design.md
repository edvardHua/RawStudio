# HDR HEIC → Ultra HDR JPEG 导出

**Date:** 2026-05-13
**Status:** Approved, ready for implementation

## 问题

Compare 页面打开 jpg-only 项时（多数为 iPhone 拍的 HDR HEIC），底部 actionRow 仅有 Edit。用户希望能直接导出 Ultra HDR JPEG（MPF + gain map 格式），便于分享给 Android 设备（Android 14+ 原生支持 Ultra HDR JPEG）。

## 设计原则

- **复用 `UltraHDRWriter`**：现有 writer 已经是通用 SDR/HDR CIImage → Ultra HDR JPEG，无需改动
- **同 CIImage 双渲染技巧**：`CIImage(data:options: [.expandToHDR: true])` 拿到扩展范围 CIImage，UltraHDRWriter 的 SDR 路径用 sRGB 渲染（自动 clamp），HDR 路径用 HLG 渲染（保留扩展值），所以同一个 CIImage 输入两次即可
- **按钮仅在 HDR HEIC 上出现**：用 ImageIO 检测，避免 SDR HEIC 上"按了没效果"的困惑
- **延续现有命名**：按钮名 "HDR JPEG"，与 RAW Only 模式那个一致；输出文件后缀 `_UltraHDR.jpg`

## 不在范围内（YAGNI）

- 批量 HDR JPEG 导出（CompareView 单图导出已够，全部模式也只有 Delete 按钮）
- 非 HEIC 输入的 HDR 检测（Apple HDR 几乎都用 HEIC）
- HDR 强度调节 / 自定义 headroom / gain map quality 调节
- 进度细分（已有 isProcessing 兜底）
- 单元测试（与项目其他功能一致，靠手动验证）

## 设计

### 1. HDR 检测 helper（`PhotoLibraryManager` 静态方法）

```swift
/// 判断给定的图像数据是否是 HDR（含 gain map 或 10-bit HLG 等标记）。
/// 用于决定是否在 CompareView 上显示 HDR JPEG 导出按钮。
static func isHDRImage(data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]

    // 1. depth >= 10 (Apple HDR HEIC 都是 10-bit)
    if let depth = properties?[kCGImagePropertyDepth as String] as? Int, depth >= 10 {
        return true
    }

    // 2. 含 HDR gain map auxiliary data
    let auxTypes: [CFString] = [
        "kCGImageAuxiliaryDataTypeISOGainMap" as CFString,    // iOS 18+ ISO HDR
        "kCGImageAuxiliaryDataTypeHDRGainMap" as CFString,    // Apple HDR
    ]
    for type in auxTypes {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
            return true
        }
    }
    return false
}
```

### 2. 新 export 方法（`PhotoLibraryManager`）

```swift
/// 把 HDR HEIC 转成 Ultra HDR JPEG（Android 兼容的 MPF + gain map JPEG）。
/// 复用 UltraHDRWriter：SDR 路径走 sRGB（clamp），HDR 路径走 HLG（保留扩展），同一 CIImage 输入两次即可。
func exportUltraHDRJPEGFromImage(for pair: PhotoPair) async throws {
    guard let jpgResource = pair.jpgResource else {
        throw SplitError.extractionFailed("This photo has no image resource")
    }
    let data = try await extractResourceData(for: jpgResource)

    guard let ciImage = CIImage(data: data, options: [.expandToHDR: true]) else {
        throw SplitError.extractionFailed("Cannot decode image as HDR")
    }

    let exifProperties = Self.propertiesWithNormalizedOrientation(Self.extractImageProperties(from: data))

    let writer = UltraHDRWriter(ciContext: ciContext)
    let ultraHDRData = try writer.writeUltraHDRJPEG(
        sdrImage: ciImage,
        hdrImage: ciImage,
        exifProperties: exifProperties
    )

    try await saveAsNewAsset(
        data: ultraHDRData,
        resourceType: .photo,
        originalFilename: (jpgResource.originalFilename as NSString)
            .deletingPathExtension + "_UltraHDR.jpg"
    )
}
```

### 3. CompareView 状态

```swift
@State private var isHDRJpgSource: Bool = false
```

在 `loadImages()` 的 jpg 加载分支里设值（紧接 `cachedJPGData = jpgData` 之后）：

```swift
if let jpgResource = pair.jpgResource {
    let jpgData = try await manager.extractRawData(for: jpgResource)
    cachedJPGData = jpgData
    isHDRJpgSource = PhotoLibraryManager.isHDRImage(data: jpgData)
    if let jpgResult = try await manager.loadJPGImageWithMetadata(for: pair) {
        jpgImage = jpgResult.0
        jpgMetadata = jpgResult.1
    } else {
        jpgImage = nil
        jpgMetadata = nil
    }
} else {
    cachedJPGData = nil
    isHDRJpgSource = false
    jpgImage = nil
    jpgMetadata = nil
}
```

> 注：`isHDRImage` 同步函数，对几 MB 的 HEIC 几十 ms，不阻塞 UI；放在已有 await 之后，时序天然符合。

### 4. actionRow `.jpgOnly` 分支条件加按钮

```swift
case .jpgOnly:
    if isHDRJpgSource {
        actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDRFromImage() }
        actionDivider
    }
    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
```

### 5. CompareView 新本地函数 `exportUltraHDRFromImage()`

参考现有 `exportUltraHDR()` 的写法（导出函数 + isProcessing/toast/error 流程）：

```swift
private func exportUltraHDRFromImage() {
    guard let pair = currentPair, !isProcessing else { return }
    Task {
        isProcessing = true
        processingMessage = String(localized: "Exporting Ultra HDR…")
        do {
            try await manager.exportUltraHDRJPEGFromImage(for: pair)
            toastMessage = String(localized: "Ultra HDR JPEG saved")
            showToast = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isProcessing = false
        processingMessage = ""
    }
}
```

## 数据流

```
[用户进 Compare 看 HEIC 项]
  ↓ loadImages
  ↓ extractRawData(jpgResource) → jpgData
  ↓ PhotoLibraryManager.isHDRImage(data: jpgData) → Bool
  ↓ isHDRJpgSource = true (HDR HEIC) 或 false
  ↓ actionRow .jpgOnly 分支按 isHDRJpgSource 条件渲染
[用户点 HDR JPEG]
  ↓ exportUltraHDRFromImage()
  ↓ manager.exportUltraHDRJPEGFromImage(for: pair)
    ↓ extractResourceData(jpgResource) → data
    ↓ CIImage(data: data, options: [.expandToHDR: true])
    ↓ UltraHDRWriter.writeUltraHDRJPEG(sdr=ci, hdr=ci, exif=…)
    ↓ saveAsNewAsset(_UltraHDR.jpg)
  ↓ toast "Ultra HDR JPEG saved"
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 检测把 10-bit SDR HEIC 误判为 HDR | 输出仍是合法 Ultra HDR JPEG，gain map 接近 0，等价于普通 JPEG。无害 |
| `CIImage(data:options:)` 在某些非标准 HEIC 上返回 nil | `guard let` 兜底抛 `extractionFailed`；CompareView toast 报错 |
| 检测可能漏掉无 gain map / 8-bit 但 HDR 的边角情况 | 极少见；用户可以期待主流 iPhone HDR 照片正确识别 |
| iCloud 未下载 | `extractResourceData` 内部会触发下载（已有逻辑） |
| 转换耗时（~1-3s 在 iPhone 15 Pro Max） | isProcessing + processingMessage 已经覆盖 |
| ImageIO `kCGImageAuxiliaryDataTypeISOGainMap` 字符串硬编码 | 苹果该常量在 iOS 18 才公开符号；硬编码字符串向前/向后兼容 |

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Services/PhotoLibraryManager.swift` | 新增 `static func isHDRImage(data:)` + 新增 `func exportUltraHDRJPEGFromImage(for:)` |
| `RawStudio/Views/CompareView.swift` | 加 `@State isHDRJpgSource`、`loadImages` 设值、actionRow `.jpgOnly` 加条件按钮、加 `exportUltraHDRFromImage()` 函数 |

## 验证

- 真机：iPhone 默认拍照得到的 HDR HEIC → 进 Compare → 顶部灰底 HEIC badge + 底部 **HDR JPEG** + Edit
- 设置 → 相机 → 关闭 HDR / 用截图等 SDR HEIC → 进 Compare → 底部 **仅 Edit**（无 HDR JPEG 按钮）
- 点 HDR JPEG → 进度条 → toast "Ultra HDR JPEG saved" → Photos 库出现新 `_UltraHDR.jpg`
- 把生成的 jpg 分享到 Android 14+ 设备应该能渲染出 HDR 高光（具体取决于 Android 应用支持，至少 Google Photos 支持）
- AirDrop 同样的 jpg 回 Mac 用 Preview 打开，应能看到 HDR 高亮（macOS 14+）
