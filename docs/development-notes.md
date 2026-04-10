# 开发经验总结 — RAW+JPG Split

## 用户偏好与设计原则

### UI 设计风格

1. **简洁高级** — 参考 Apple 原生 App 的风格，不要多余装饰，内容优先
2. **Liquid Glass 风格** — 使用独立的玻璃胶囊按钮（`.ultraThinMaterial` + `Capsule()`），不使用连续的工具栏条
3. **按钮布局** — 水平排列（图标在左，文字在右），**左对齐**（右侧留空），不居中
4. **背景** — 跟随系统明暗模式（`Color(.systemBackground)`），不要硬编码黑色或白色
5. **字体** — 使用 SwiftUI Dynamic Type 预设（`.largeTitle`、`.body`、`.caption` 等），不要硬编码 `.system(size: N)`
6. **间距** — 使用 `@ScaledMetric` 让 padding 自适应不同设备尺寸
7. **颜色** — 使用语义色（`.primary`、`.secondary`、`.tertiary`），不要硬编码 `.white` 或 `.black`（格式徽章等有色背景上的白字除外）
8. **导航栏** — 不使用系统 inline 标题，偏好自定义浮动 header（大标题 + 副标题 + 玻璃胶囊按钮）
9. **不需要固定的 toolbar 条** — 所有工具栏改为浮动的独立胶囊按钮
10. **所有控件在不同 Apple 设备上比例刚好** — 不能在大屏上太小、小屏上太大

### 功能设计偏好

1. **操作不破坏原图** — Keep/Save 只保存新照片到相册，不自动删除原图。删除是独立操作
2. **操作后不自动跳转** — 执行 Save JPG/Save RAW 后停留在当前照片，不跳到下一张
3. **不需要"已处理/未处理"状态跟踪** — Keep/Save 是纯导出操作，不标记状态
4. **删除需要用户确认** — 系统弹窗确认，用户拒绝则不做任何操作（不弹 error，不跳转）
5. **iCloud 下载时可以返回** — 加载中返回按钮可用，但执行保存/删除时隐藏返回按钮防止中断
6. **分享功能** — 通过系统 UIActivityViewController 分享当前图片
7. **编辑器参数可保存为预设** — RAW 和 JPG 编辑器都支持预设的保存/加载/删除

### 图层编辑偏好

1. **遮罩边缘需要高斯模糊** — 不然调整参数时边缘过渡不自然，提供 Edge Feather 滑块让用户控制
2. **自定义图层** — 最多 3 个，通过画笔涂抹 + 魔棒两种方式定义选区
3. **选区可视化** — 半透明红色遮罩覆盖在选中区域上
4. **魔棒容差可调** — 提供滑动条控制选择宽松程度

## 技术经验教训

### PhotoKit

1. **`PHAssetMediaSubtype` 没有 `photoRAW` 标记** — RAW 照片无法在数据库层面预过滤，必须遍历所有图片并检查 `PHAssetResource`
2. **RAW-only 的照片**，RAW 文件的 resource type 是 `.photo`（不是 `.alternatePhoto`）。需要通过 UTI 检查来区分 RAW 和 JPG
3. **`UIImage(data:)` 不支持大多数相机 RAW 格式**（ARW、CR3、NEF 等）— 必须用 `CIRAWFilter` 解码
4. **删除照片时 `PHPhotoLibrary.performChanges` 返回的 success 需要检查** — 用户可能拒绝删除权限

### CIRAWFilter

1. **`CIRAWFilter.outputImage` 的 `extent` 原点可能不在 (0,0)** — 例如 `(0, -100, 3000, 2000)`。任何使用 `ciContext.createCGImage` 或遮罩对齐时都需要处理
2. **输出可能是 HDR/float16 格式** — Vision 框架不支持。传给 Vision 前需要强制 `createCGImage(format: .RGBA8, colorSpace: sRGB)`
3. **Draft 模式** — `isDraftModeEnabled = true` + `scaleFactor = 0.25` 大幅提升预览渲染速度
4. **`extendedDynamicRangeAmount`** — 0.0 = SDR，1.0 = HDR。用于导出 Adaptive HDR / Ultra HDR

### Vision 框架（语义分割）

1. **`VNImageRequestHandler.perform()` 是同步调用** — 必须在后台线程（`Task.detached`）执行，否则阻塞主线程
2. **`SegmentationService` 必须是 `@Observable`** — 否则遮罩生成后 SwiftUI 不知道属性变了，图层按钮永远灰显
3. **RAW 图片不能直接用于 Vision** — CIRAWFilter 输出的 CIImage 格式 Vision 不支持。解决方案：用 CompareView 已渲染好的 `UIImage`（标准 sRGB CGImage）传给 Vision
4. **皮肤检测** — 用人物遮罩 AND YCbCr 颜色阈值，在一个 CPU pass 中完成，避免 CIMultiplyCompositing 的格式兼容问题

### SwiftUI 性能

1. **不要对数据模型用 `@Observable`**（如 `PhotoPair`）— 当缩略图加载时会触发级联更新，导致整个列表重新渲染
2. **缩略图用 `NSCache`** — 每个 cell 用自己的 `@State` 管理缩略图，通过 `.task(id:)` 异步加载
3. **用 `LazyVStack` 替代 `List`** — `List` 对 section 不是真正的懒加载
4. **`PHImageRequestOptions.deliveryMode` 用 `.fastFormat`** — 单次回调，避免 `withCheckedContinuation` 的多次 resume 问题
5. **`DateFormatter` 要静态缓存** — 不要在每次 `groupedByDate()` 调用时创建新的
6. **`ZoomableImageView`（UIScrollView）不能放在 SwiftUI `ScrollView` 里** — 会导致布局尺寸为 zero，图片不显示

### Swift 6 严格并发

1. **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — 所有类型默认在主线程。需要用 `nonisolated` 和 `Task.detached` 把重活放到后台
2. **`AsyncStream` 的生产闭包在调用线程上同步执行** — 如果在 MainActor 调用 `for await`，生产者也在主线程运行。必须在 `AsyncStream` 闭包内用 `Task.detached` 把生产逻辑放到后台

### JPG 编辑

1. **`CIImage(data:)` 保留 EXIF 方向但不自动旋转像素** — 需要 `ciImage.oriented(forExifOrientation:)` 手动应用方向，否则编辑时图片旋转

### 文件共享

1. **只有 Documents 目录对用户可见** — 通过 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 启用
2. **App Bundle 中的资源需要复制到 Documents 目录** — Bundle 是只读的，用户无法直接访问

## 项目架构原则

1. **零外部依赖** — 全部使用 Apple 原生框架（PhotoKit、CoreImage、Vision、Accelerate）
2. **`PBXFileSystemSynchronizedRootGroup`** — 文件放到 `RAW+JPGSplit/` 目录下自动同步到 Xcode 项目，不需要手动编辑 pbxproj
3. **共享组件** — 编辑器共享 `EditorComponents.swift`（滑动条、标签页、工具栏、格式徽章），避免代码重复
4. **统一持久化** — 所有编辑参数通过 `RAWEditPresetStore` 管理，自定义遮罩通过 `CustomMaskStore` 管理
5. **中英文双语** — 所有 UI 字符串通过 `Localizable.xcstrings` 本地化，程序化字符串用 `String(localized:)`
