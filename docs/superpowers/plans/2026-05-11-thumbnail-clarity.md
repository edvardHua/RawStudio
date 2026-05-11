# 主界面缩略图清晰度优化 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用按上下文请求像素 + `.opportunistic` 两阶段交付替换固定 160×160 `.fastFormat` 缩略图，消除列表/网格上采样模糊。

**Architecture:** `PhotoLibraryManager` 暴露新的 `loadThumbnailStream(for:size:) -> AsyncStream<UIImage>` API（内部缓存按 64 px 桶化），列表/网格视图分别按 `cellWidth × displayScale` 像素订阅 stream，旧 `loadThumbnail` 删除。

**Tech Stack:** Swift 5 / SwiftUI / Photos.framework / `PHCachingImageManager` / `AsyncStream` / iOS 26.2

**Spec:** `docs/superpowers/specs/2026-05-11-thumbnail-clarity-design.md`

**项目背景：**
- 类 `PhotoLibraryManager` 标注 `@Observable`，build setting `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（即默认 MainActor 隔离）
- `PHCachingImageManager` 与 `NSCache` 都是线程安全的（Apple 文档保证）
- 项目无单元测试套件，验证以**编译通过 + 模拟器肉眼对比**为准
- 模拟器：用 `iPhone 17 Pro`（DFABFFCE-4305-46F5-B38B-35BFCD1EB986）

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `RawStudio/Services/PhotoLibraryManager.swift` | 新增 `bucketWidth` helper + `loadThumbnailStream(for:size:)`；删除旧 `loadThumbnail(for:)` |
| `RawStudio/Views/PhotoCardView.swift` | 加 `@Environment(\.displayScale)`；`.task` 改用 stream；进入 task 时清空旧 thumbnail |
| `RawStudio/Views/PhotoGridItemView.swift` | 同上 + 用 `GeometryReader` 包裹现有 `ZStack` 以读取真实 cell 宽度 |

---

## Task 1: 新增 `loadThumbnailStream` API（保留旧 API 暂不删，确保中间状态可编译）

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift:228-258`（在 `loadThumbnail` 函数旁边追加新函数与 helper）

- [ ] **Step 1: 在 `// MARK: - Thumbnails` 段落前插入 `bucketWidth` helper 与新 stream 函数**

打开 `RawStudio/Services/PhotoLibraryManager.swift`，找到 `// MARK: - Thumbnails` 这一行（约第 228 行），在 **旧 `loadThumbnail` 函数下方、`// MARK: - Load Full Images for Compare`（约第 260 行）之前** 插入下列代码：

```swift
    /// 把任意宽度向上取整到 64 的倍数，避免不同请求把缓存撑爆 N 份
    private func bucketWidth(_ w: CGFloat) -> Int {
        ((Int(w) + 63) / 64) * 64
    }

    /// 高质量两阶段缩略图加载。
    ///
    /// `size` 是**像素**单位，调用方负责乘以 `displayScale`。
    /// 使用 `.opportunistic` 交付模式：cache 命中只 yield 一次；cache 未命中可能 yield 两次
    /// （先低清后高清），以 `PHImageResultIsDegradedKey == false` 的那次作为最终图存入缓存。
    func loadThumbnailStream(for pair: PhotoPair, size: CGSize) -> AsyncStream<UIImage> {
        let key = "\(pair.id)@\(bucketWidth(size.width))" as NSString
        let cache = thumbnailCache
        let manager = cachingManager

        return AsyncStream { continuation in
            // Cache 命中：直接 yield 最终图后 finish
            if let cached = cache.object(forKey: key) {
                continuation.yield(cached)
                continuation.finish()
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let requestID = manager.requestImage(
                for: pair.asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil

                if let image {
                    continuation.yield(image)
                    if !isDegraded {
                        cache.setObject(image, forKey: key)
                    }
                }

                // 终止条件：拿到非 degraded 图、被取消、或出错
                if !isDegraded || isCancelled || hasError {
                    continuation.finish()
                }
            }

            // .task(id:) 切换 pair 时 stream 终止 → 取消未完成的 PHImage 请求
            continuation.onTermination = { @Sendable _ in
                manager.cancelImageRequest(requestID)
            }
        }
    }
```

> 关键点：
> - 把 `cachingManager` / `thumbnailCache` 拷贝到本地常量后捕获，避免在 `@Sendable` 闭包里捕获 `self`（MainActor 隔离冲突）
> - PHImageManager 回调可能多次触发，必须用 `AsyncStream` 而不是 `CheckedContinuation`
> - 终止条件覆盖 3 种情况：拿到最终图 / 被取消 / 出错，否则 stream 永不 finish 会泄露

- [ ] **Step 2: 编译验证（旧 + 新两套 API 共存）**

在项目根目录执行：

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -20
```

Expected: 最后一行 `** BUILD SUCCEEDED **`，无 error / warning。

如果看到 Sendable 相关 warning，复检 Step 1 代码是否捕获了 `self`。

- [ ] **Step 3: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
feat(thumbnails): add loadThumbnailStream API with two-stage delivery

Returns AsyncStream<UIImage> using .opportunistic + .exact options,
keyed by per-asset id bucketed to 64px width. Old loadThumbnail kept
in place until callers migrate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 迁移 `PhotoCardView` 到新 stream API

**Files:**
- Modify: `RawStudio/Views/PhotoCardView.swift:10-11`（添加 `displayScale` 环境变量）
- Modify: `RawStudio/Views/PhotoCardView.swift:65-69`（重写 `.task` block）

- [ ] **Step 1: 添加 `@Environment(\.displayScale)` 属性**

找到 `PhotoCardView.swift` 第 10 行 `@State private var thumbnail: UIImage?`，在它**下方**插入一行：

```swift
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale
```

- [ ] **Step 2: 重写 `.task` block**

找到 `PhotoCardView.swift` 第 65-69 行：

```swift
        .task(id: pair.id) {
            if let manager, thumbnail == nil {
                thumbnail = await manager.loadThumbnail(for: pair)
            }
        }
```

替换为：

```swift
        .task(id: pair.id) {
            guard let manager else { return }
            thumbnail = nil   // 清掉视图复用残留的旧图
            let side = 72 * displayScale
            let px = CGSize(width: side, height: side)
            for await img in manager.loadThumbnailStream(for: pair, size: px) {
                thumbnail = img
            }
        }
```

> 为什么要 `thumbnail = nil`：LazyVStack 会复用 cell view，原代码的 `thumbnail == nil` 守卫意味着切换 pair 后旧图会一直挂着不刷新（已有 bug），顺手修掉。

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add RawStudio/Views/PhotoCardView.swift
git commit -m "$(cat <<'EOF'
refactor(PhotoCardView): use loadThumbnailStream sized 72pt × scale

Requests sharper thumbnails matching actual render pixels (216 px on
3x devices vs the previous fixed 160 px). Also clears stale thumb on
view recycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 迁移 `PhotoGridItemView` 到新 stream API + GeometryReader

**Files:**
- Modify: `RawStudio/Views/PhotoGridItemView.swift`（整个 body 重写，加 displayScale 与 GeometryReader）

- [ ] **Step 1: 添加 `@Environment(\.displayScale)` 属性**

找到 `PhotoGridItemView.swift` 第 9 行 `@State private var thumbnail: UIImage?`，在它**下方**插入一行：

```swift
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale
```

- [ ] **Step 2: 用 GeometryReader 包裹整个 ZStack 并改写 `.task`**

找到 `PhotoGridItemView.swift` 第 11-51 行（整个 `var body`），整段替换为：

```swift
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Thumbnail
                thumbnailView
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                // Overlays
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        // RAW format badge
                        Text(pair.rawFormatLabel)
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

                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: pair.id) {
                guard let manager else { return }
                thumbnail = nil
                let side = max(proxy.size.width, 1) * displayScale
                let px = CGSize(width: side, height: side)
                for await img in manager.loadThumbnailStream(for: pair, size: px) {
                    thumbnail = img
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
```

> 关键点：
> - `GeometryReader` 默认撑满父容器；`.aspectRatio(1, .fit)` **必须放在 GeometryReader 外侧**才能让 LazyVGrid 正确决定 cell 高度
> - 原 thumbnailView 上的 `.aspectRatio(1, .fit)` 已删除（外层已强制 1:1）；`.frame(maxWidth: .infinity, maxHeight: .infinity)` 改成 `proxy.size.width/height` 显式给定
> - `.task(id: pair.id)` 在 layout pass 之后执行，所以 `proxy.size.width` 已是真实 cell 宽度（约屏宽/3）

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add RawStudio/Views/PhotoGridItemView.swift
git commit -m "$(cat <<'EOF'
refactor(PhotoGridItemView): use loadThumbnailStream + GeometryReader

Reads real cell width from GeometryReader and requests pixels matching
displayScale (~390 px on 3x screens). Wraps existing ZStack so that
.aspectRatio(1, .fit) stays applied to the cell.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 删除旧 `loadThumbnail` API

**Files:**
- Modify: `RawStudio/Services/PhotoLibraryManager.swift:230-258`（删除整个旧函数）

- [ ] **Step 1: 验证已无其它调用方**

```bash
grep -rn "loadThumbnail(for:" /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio/
```

Expected: 输出**为空**（除了即将删除的定义本身）。如果有遗漏的调用方，回到 Task 2/3 补迁移。

- [ ] **Step 2: 删除旧函数体**

找到 `RawStudio/Services/PhotoLibraryManager.swift` 中这段（约第 230-258 行）：

```swift
    func loadThumbnail(for pair: PhotoPair) async -> UIImage? {
        let key = pair.id as NSString

        // Check cache first
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            cachingManager.requestImage(
                for: pair.asset,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if let image {
            thumbnailCache.setObject(image, forKey: key)
        }
        return image
    }
```

整段删除（包含函数签名到 `}`）。

- [ ] **Step 3: 删除已无引用的 `thumbnailSize` 常量**

找到 `RawStudio/Services/PhotoLibraryManager.swift:53`：

```swift
    private let thumbnailSize = CGSize(width: 160, height: 160)
```

整行删除。

- [ ] **Step 4: 验证 `thumbnailSize` 已无其它引用**

```bash
grep -n "thumbnailSize" /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio/Services/PhotoLibraryManager.swift
```

Expected: 输出为空。

- [ ] **Step 5: 编译验证**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add RawStudio/Services/PhotoLibraryManager.swift
git commit -m "$(cat <<'EOF'
chore(thumbnails): remove obsolete loadThumbnail API

All callers now use loadThumbnailStream. Drops the fixed 160×160
thumbnailSize constant as well.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 模拟器肉眼验证

**Files:** 无（仅人工验证）

- [ ] **Step 1: 安装并启动 app**

```bash
xcodebuild -project /Users/edvard.zeng/workspace/RAW+JPGSplit/RawStudio.xcodeproj \
  -scheme RawStudio \
  -destination 'platform=iOS Simulator,id=DFABFFCE-4305-46F5-B38B-35BFCD1EB986' \
  -derivedDataPath /tmp/RawStudio-build \
  build 2>&1 | tail -5

xcrun simctl boot DFABFFCE-4305-46F5-B38B-35BFCD1EB986 2>/dev/null || true
xcrun simctl install DFABFFCE-4305-46F5-B38B-35BFCD1EB986 \
  /tmp/RawStudio-build/Build/Products/Debug-iphonesimulator/RawStudio.app
open -a Simulator
xcrun simctl launch DFABFFCE-4305-46F5-B38B-35BFCD1EB986 com.edz.RawStudio
```

- [ ] **Step 2: 在模拟器里授权照片库并加载样图**

模拟器照片 app 自带几张样片。回到 RawStudio：
- 进入主界面（GalleryView）
- 滚动列表视图：检查 72×72 缩略图是否清晰（无明显马赛克/锯齿）
- 切到网格视图（底部 "Grid View" 按钮）：检查 cell 是否清晰
- 快速来回切换列表/网格 → 切换相册 → 应不闪白屏（cache 命中）

Expected: 缩略图肉眼上明显比修改前清晰；首次加载有不到 1 秒的低清→高清过渡是正常的。

- [ ] **Step 3: （可选）截图归档对比**

```bash
xcrun simctl io DFABFFCE-4305-46F5-B38B-35BFCD1EB986 screenshot /tmp/raw-studio-after.png
```

如果之前有 before 截图，可放一起对比。

- [ ] **Step 4: 没问题就结束**

如果一切正常，无需额外提交。

如果发现问题：
- 清晰度仍不够 → 检查是否乘了 `displayScale`、`size` 是否真的传到了 PHImageManager
- 加载慢 → `.exact` resize 在大库上可能略慢，可以局部回退到 `.fast`（但通常不需要）
- 出现内存警告 → NSCache 应自动释放；检查是否真的因为 cache 桶种类太多撑爆

---

## 自检清单（写完后过一遍）

- ✅ Spec § 1 (API 形状) → Task 1
- ✅ Spec § 2 (内部实现：deliveryMode/resizeMode/cancel) → Task 1
- ✅ Spec § 3 (cache key + 桶化) → Task 1
- ✅ Spec § 4 (调用方 PhotoCardView) → Task 2
- ✅ Spec § 4 (调用方 PhotoGridItemView + GeometryReader) → Task 3
- ✅ Spec § 5 (旧 API 删除) → Task 4
- ✅ Spec § 6 (验证) → Task 5
- ✅ 类型一致：`loadThumbnailStream(for:size:)` 在 Task 1/2/3 签名完全一致
- ✅ 无 placeholder（每步都有完整代码或命令）
