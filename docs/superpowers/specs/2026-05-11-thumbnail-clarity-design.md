# 主界面缩略图清晰度优化

**Date:** 2026-05-11
**Status:** Approved, ready for implementation

## 问题

`GalleryView` 的列表与网格在真机上预览图明显模糊。根因有三个叠加：

1. `PhotoLibraryManager.thumbnailSize` 固定 `160 × 160` 像素，远小于真实显示像素：
   - 列表：`72pt × 72pt` → 3x 屏 = `216 × 216` px（拉伸 1.35×）
   - 网格：屏宽/3 ≈ `130pt` → 3x 屏 = `390 × 390` px（拉伸 2.4×）
2. `options.deliveryMode = .fastFormat`：Photos 框架直接返回低质量预览，永不升级
3. `options.resizeMode = .fast`：使用快速但低质量的缩放算法

## 目标

- 列表与网格缩略图在所有设备倍率（2x/3x）下都不被上采样
- 加载分两阶段（先低清后高清），避免首屏空白闪烁
- 缓存内存增长可控（NSCache 桶化策略）

## 不在范围内（YAGNI）

- 滚动方向预热（`PHCachingImageManager.startCaching`）
- 自定义 LRU/磁盘缓存
- iPad 多列网格的特殊处理（`displayScale` + `GeometryReader` 已自适应）
- 单元测试（依赖真实 Photos 库，性价比低；以手动验证为准）

## 设计

### 1. API 形状

`PhotoLibraryManager.swift`：

```swift
// 删除
func loadThumbnail(for pair: PhotoPair) async -> UIImage?

// 新增
func loadThumbnailStream(for pair: PhotoPair, size: CGSize) -> AsyncStream<UIImage>
```

返回 `AsyncStream` 是必要的：`.opportunistic` 交付模式下 `PHImageManager` 会**多次回调**（先低清后高清），用 `CheckedContinuation` 多次 resume 会触发运行时崩溃。`AsyncStream` 是唯一干净的承载形式。

`size` 参数是**像素**单位，由调用方负责乘以 `displayScale`。

### 2. 内部实现要点

```swift
let options = PHImageRequestOptions()
options.deliveryMode = .opportunistic   // 旧: .fastFormat
options.resizeMode   = .exact            // 旧: .fast
options.isNetworkAccessAllowed = true
options.isSynchronous = false
```

- **缓存命中**：yield 一次缓存图后 `continuation.finish()`
- **缓存未命中**：
  - 每个非空回调 yield 一次（订阅方据此更新 `@State`）
  - 当 `info[PHImageResultIsDegradedKey] != true` 时把图存入 cache 并 finish
  - `image == nil` 时跳过（取消/失败）
- 在 `continuation.onTermination` 里调用 `cachingManager.cancelImageRequest(requestID)`，确保 `.task(id:)` 切换 pair 时旧请求被取消

### 3. 缓存 key 与桶化

`thumbnailCache` 实例不变，key 规则改为：

```swift
private func bucketWidth(_ w: CGFloat) -> Int {
    ((Int(w) + 63) / 64) * 64    // 向上取整到 64 的倍数
}

let key = "\(pair.id)@\(bucketWidth(size.width))" as NSString
```

预期共存桶数：列表 216 → 256，网格 390 → 448 → 共 2 档。即使 iPad 加 3-4 列，也最多 4 档。

### 4. 调用方变化

两个调用方都加 `@Environment(\.displayScale)`：

**PhotoCardView.swift**（列表，72pt 固定）

```swift
@Environment(\.displayScale) private var displayScale
@State private var thumbnail: UIImage?

.task(id: pair.id) {
    guard let manager else { return }
    let side = 72 * displayScale
    let px = CGSize(width: side, height: side)
    for await img in manager.loadThumbnailStream(for: pair, size: px) {
        thumbnail = img
    }
}
```

**PhotoGridItemView.swift**（网格，cell 宽度由 GeometryReader 拿）

GeometryReader 套在现有 `ZStack` **外层**（即作为整个 cell 的根），把 `proxy.size.width` 作为状态传给 `.task`。结构示意：

```swift
var body: some View {
    GeometryReader { proxy in
        ZStack(alignment: .topLeading) {
            // ... 现有 thumbnailView + overlays 不动 ...
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: pair.id) {
            guard let manager else { return }
            let side = max(proxy.size.width, 1) * displayScale
            let px = CGSize(width: side, height: side)
            for await img in manager.loadThumbnailStream(for: pair, size: px) {
                thumbnail = img
            }
        }
    }
    .aspectRatio(1, contentMode: .fit)   // 移到 GeometryReader 外侧维持 1:1
}
```

> 注意：`GeometryReader` 默认会撑满父容器，所以 `.aspectRatio(1, .fit)` 必须放在 `GeometryReader` 之外；否则 cell 会在 LazyVGrid 里失去 1:1 约束。原来 `aspectRatio` 在 `thumbnailView` 上的位置需要移除。

> `proxy.size` 在 LazyVGrid 内部是稳定的（cell 宽度由网格列定义决定）。`.task` 在 layout 之后执行，并用 `max(_, 1)` 兜底。

### 5. 不动的部分

- `PHCachingImageManager` 实例保持
- `NSCache<NSString, UIImage>` 实例保持（仅 key 规则变）
- 旧 `loadThumbnail(for:)` 直接删除（只有 2 个调用点都同步更新）

## 数据流

```
[View .task]
   ↓ size = cellWidth * displayScale (px)
[loadThumbnailStream]
   ↓ check cache (key = id@bucket)
   ├─ hit → yield 1× → finish
   └─ miss → PHCachingImageManager.requestImage(.opportunistic, .exact)
              ↓ multiple callbacks
              ├─ degraded image → yield (no cache write)
              └─ final image → cache + yield → finish
   ↓
[View @State thumbnail = img]   ← updates twice if degraded path taken
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| `.task` 切换 pair 时旧 stream 不释放 | `continuation.onTermination` 取消 PHImage request |
| `.exact` + 高清版本导致缓存内存上涨 | 桶化限制条目种类；NSCache 内存压力下自动淘汰 |
| GeometryReader 首帧 size = 0 | `.task` 在 layout 后执行，且代码用 `max(_, 1)` 兜底；首次 yield 前 cell 宽度已确定 |
| 旧 API 删除导致编译错 | 只有 2 个调用点（PhotoCardView, PhotoGridItemView），同步改完即可 |

## 验证

- 手动：真机/模拟器跑 GalleryView，列表 + 网格分别滚动，肉眼对照前后清晰度
- 检查内存：Instruments Allocations 看 thumbnailCache 持续滚动 5 分钟后驻留量
- 检查取消：用 Console 看 PHAsset 取消日志（快速切换 pair 时）

## 涉及文件

- `RawStudio/Services/PhotoLibraryManager.swift`（删旧函数 + 写新函数 + bucketWidth helper）
- `RawStudio/Views/PhotoCardView.swift`（task block 重写）
- `RawStudio/Views/PhotoGridItemView.swift`（外层套 GeometryReader + task block 重写）
