# HDR HEIC → Ultra HDR JPEG 导出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compare 页面打开 HDR HEIC 时新增 "HDR JPEG" 按钮，导出 Android 兼容的 Ultra HDR JPEG（MPF + gain map）。

**Architecture:** 复用现成 `UltraHDRWriter`。`CIImage(data: options: [.expandToHDR: true])` 拿到扩展范围 CIImage，UltraHDRWriter 内部 SDR 路径走 sRGB（自动 clamp）、HDR 路径走 HLG（保留扩展），所以同一 CIImage 输入两次即产生有效 gain map。CompareView 通过 ImageIO 检测 HDR 后才显示按钮。

**Tech Stack:** Swift 5 / SwiftUI / Photos.framework / CoreImage / ImageIO / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-13-hdr-heic-to-ultra-hdr-jpeg-design.md`

**项目背景：**
- 当前 worktree 分支：`worktree-feat+three-way-filter`，HEAD ~ `1e8d4a3`（spec commit）
- 类 `@Observable final class PhotoLibraryManager`，MainActor 默认隔离
- 无单元测试套件 — 验证 = `xcodebuild build` 通过 + 真机肉眼测
- 真机：iPhone 15 Pro Max (`E71BC21F-DC20-5570-9A10-6F3CF3CA5B28`)
- 模拟器：iPhone 17 Pro (`DFABFFCE-4305-46F5-B38B-35BFCD1EB986`)
- LSP/SourceKit 在 PBXFileSystemSynchronizedRootGroup 项目里有恼人误报，**只信 xcodebuild 输出**

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Services/PhotoLibraryManager.swift` | 新增 `static func isHDRImage(data:) -> Bool`、新增 `func exportUltraHDRJPEGFromImage(for:) async throws` |
| `RawStudio/Views/CompareView.swift` | 加 `@State isHDRJpgSource`、`loadImages` jpg 分支里设值、actionRow `.jpgOnly` 加条件按钮、新增 `exportUltraHDRFromImage()` 函数 |

---

## Task 1: PhotoLibraryManager — HDR 检测 + HEIC 导出函数

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift`（在已有 RAW 用的 `exportUltraHDRJPEG` 函数旁边追加新方法）

- [ ] **Step 1: 在 `exportUltraHDRJPEG` 函数下方插入 `isHDRImage` static helper + `exportUltraHDRJPEGFromImage`**

先用 grep 定位 `exportUltraHDRJPEG` 函数末尾（找它和下一个 `func performAction` 的位置）：

```bash
grep -n "func exportUltraHDRJPEG\|func performAction" /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio/Services/PhotoLibraryManager.swift
```

预期能看到 `func exportUltraHDRJPEG(for pair:` 和 `func performAction(` 两行。在 `exportUltraHDRJPEG` 函数的右大括号 `}` 之后、`func performAction` 之前插入下面整段：

```swift

    /// 判断给定的图像数据是否是 HDR（含 gain map 或 10-bit HLG 等标记）。
    /// 用于决定是否在 CompareView 上显示 HDR JPEG 导出按钮。
    static func isHDRImage(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]

        // 1. depth >= 10（Apple HDR HEIC 都是 10-bit）
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

    /// 把 HDR HEIC（或任何含 HDR gain map 的图）转成 Ultra HDR JPEG（Android 兼容的 MPF + gain map JPEG）。
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

> 关键 trick 复述：`UltraHDRWriter.writeUltraHDRJPEG` 的 `renderToRGBA8` 用 sRGB 颜色空间（自动把 > 1.0 的扩展值 clamp 到 [0, 1]），`renderToRGBAF16` 用 HLG（保留扩展值）。所以同一个含 HDR 内容的 `CIImage` 输入两次，输出的 SDR 与 HDR 像素就有差，gain map 自然非零。

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`. 忽略 SourceKit 的 `Cannot find type` 误报。

如果遇到 `'expandToHDR' is not a member of CIImageOption`，可能是部署目标低于 iOS 17。本项目部署 iOS 26.2，应不会发生 — 报告 BLOCKED。

如果遇到 `'extractImageProperties'` / `'propertiesWithNormalizedOrientation'` / `'saveAsNewAsset'` 找不到，说明这些是 `private` 但调用方 `func exportUltraHDRJPEGFromImage` 在同一 class 里也应能访问；若依然报错就是文件位置放错，搬到正确的 class scope 内。

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
feat(library): add HDR detection + Ultra HDR JPEG export from HEIC

- isHDRImage(data:) static: checks depth >= 10 or HDR gain map aux data
- exportUltraHDRJPEGFromImage(for:): loads with expandToHDR, feeds the
  same CIImage to UltraHDRWriter twice (sRGB clamps for SDR, HLG keeps
  extended range for HDR — gain map emerges naturally)

Used by CompareView in the next task to add an HDR JPEG button on
HDR HEIC items.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: CompareView — 状态 + 检测 + 按钮 + 调用

**Files:**
- Modify: `RawStudio/Views/CompareView.swift`（新增 @State、loadImages 修改、actionRow 修改、新函数）

- [ ] **Step 1: 添加 `@State private var isHDRJpgSource: Bool = false`**

找到 `@State private var jpgImage: UIImage?` 这一行（约 line 11）。在 `@State` 段落里**任意位置**插一行（建议放在 `@State private var jpgMetadata: PhotoMetadata?` 旁边，约 line 13-14 附近）：

```swift
    @State private var isHDRJpgSource: Bool = false
```

例如插在 line 14 之后，让结构成：

```swift
    @State private var jpgImage: UIImage?
    @State private var rawImage: UIImage?
    @State private var jpgMetadata: PhotoMetadata?
    @State private var rawMetadata: PhotoMetadata?
    @State private var isHDRJpgSource: Bool = false      // 新增
    @State private var isLoadingImages = true
```

- [ ] **Step 2: `loadImages()` 的 jpg 分支末尾设值**

找到 `loadImages()`（约 line 405-456）。当前 jpg 加载分支是：

```swift
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
```

整段替换为：

```swift
            // 加载 JPG（如有）
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

> 唯二变化：jpg 存在分支里加 `isHDRJpgSource = PhotoLibraryManager.isHDRImage(data: jpgData)`；jpg 不存在分支里加 `isHDRJpgSource = false`。

- [ ] **Step 3: actionRow `.jpgOnly` 分支条件加按钮**

找到 actionRow（约 line 330-360）。当前 `.jpgOnly` 分支是：

```swift
                case .jpgOnly:
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
```

替换为：

```swift
                case .jpgOnly:
                    if isHDRJpgSource {
                        actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDRFromImage() }
                        actionDivider
                    }
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
```

- [ ] **Step 4: 新增 `exportUltraHDRFromImage()` 函数**

找到现有的 `exportUltraHDR()` 函数（约 line 529-547）。在它 **下方**（即 `}` 之后、下一个函数前）插入：

```swift

    private func exportUltraHDRFromImage() {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            processingMessage = String(localized: "Exporting Ultra HDR...")

            do {
                try await manager.exportUltraHDRJPEGFromImage(for: pair)
                isProcessing = false

                toastMessage = String(localized: "Ultra HDR JPEG exported to library")
                withAnimation { showToast = true }
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
```

> 故意复刻 `exportUltraHDR()` 风格（同样的 isProcessing → do/catch → toast/error 流程）。`processingMessage` 与 `toastMessage` 使用与 `exportUltraHDR()` 完全相同的 localized 字符串（因为对用户而言都是"导出 Ultra HDR"），系统已存在的 .strings 不必新增。

- [ ] **Step 5: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add RawStudio/Views/CompareView.swift
git commit -m "$(cat <<'EOF'
feat(CompareView): show HDR JPEG button on HDR HEIC items

- @State isHDRJpgSource tracks whether the loaded jpg-only image has
  HDR (gain map / 10-bit) signal
- loadImages() sets isHDRJpgSource via PhotoLibraryManager.isHDRImage
  on the jpg branch
- actionRow .jpgOnly conditionally surfaces an HDR JPEG action above
  Edit when isHDRJpgSource is true
- exportUltraHDRFromImage() mirrors the existing exportUltraHDR()
  control flow but calls the new exportUltraHDRJPEGFromImage API

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 真机肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: Build for device + 安装**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/.claude/worktrees/feat+three-way-filter/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/RawStudio-device-hdr \
  -allowProvisioningUpdates build 2>&1 | tail -5

xcrun devicectl list devices 2>&1 | grep "Edvardzeng"
# 如果状态是 connected：
xcrun devicectl device install app --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 \
  /tmp/RawStudio-device-hdr/Build/Products/Debug-iphoneos/RawStudio.app
xcrun devicectl device process launch --device E71BC21F-DC20-5570-9A10-6F3CF3CA5B28 com.edz.RawStudio
```

> 如果设备 unavailable，告诉用户解锁手机/插紧 USB，然后手动用 Xcode → Window → Devices and Simulators → 选设备 → "+" 装 `/tmp/RawStudio-device-hdr/Build/Products/Debug-iphoneos/RawStudio.app`

- [ ] **Step 2: 验证项**

在手机上：
- 进入 RawStudio，切到 **All** 筛选
- 找一张 iPhone 拍的 HDR 照片（默认 iPhone 拍照即是 HDR HEIC），点开 Compare
- **顶部应该是灰底 HEIC badge**
- **底部 actionRow 应该是 [HDR JPEG] | [Edit]** 两个按钮（HDR JPEG 在前）
- 点 HDR JPEG → 进度条 "Exporting Ultra HDR..." → toast "Ultra HDR JPEG exported to library"
- 退出回 Photos 库，能看到新的 `*_UltraHDR.jpg` 文件
- 找一张非 HDR 的 HEIC（如 iPhone 截图，多为 8-bit SDR HEIC）打开 → **底部仅有 [Edit]**，没有 HDR JPEG

（可选）把生成的 `_UltraHDR.jpg` AirDrop 给 Mac，用 Preview 打开（macOS 14+），高光部分应明显比普通 JPEG 更亮。

- [ ] **Step 3: 没问题就完成**

如果一切 OK 不需要额外提交。如有问题报回主会话。

---

## 自检清单（写完后过一遍）

- ✅ Spec § 1 (HDR 检测 helper) → Task 1 Step 1
- ✅ Spec § 2 (新 export 方法) → Task 1 Step 1
- ✅ Spec § 3 (CompareView @State + loadImages 设值) → Task 2 Steps 1-2
- ✅ Spec § 4 (actionRow 条件按钮) → Task 2 Step 3
- ✅ Spec § 5 (新 exportUltraHDRFromImage 函数) → Task 2 Step 4
- ✅ Spec § 7 (验证清单) → Task 3
- ✅ 类型一致：`isHDRImage(data:)` 在 Task 1 与 Task 2 调用签名一致；`exportUltraHDRJPEGFromImage(for:)` 同上；`isHDRJpgSource` 命名贯穿
- ✅ 无 placeholder（所有代码块完整）
