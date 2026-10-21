# macOS 文件夹支持阶段 0 摘要

## 完成内容

- 新增独立 `RawStudio-macOS` App target 和共享 `RawStudio-macOS` scheme。
- 新增最简 SwiftUI macOS 入口与占位根视图，最低系统版本设为 macOS 14。
- macOS target 仅显式编译顶层 `macOS/` 下的两个源文件，不会自动纳入 `RawStudio/` 中依赖 PhotoKit/UIKit 的 iOS 文件。
- 为 macOS target 启用 App Sandbox，并配置用户选择文件夹的读写 entitlement，为后续 NSOpenPanel 与 security-scoped bookmark 工作预留权限。
- 保留现有 iOS target、bundle ID、iOS 部署设置和同步目录配置。

## 资源归属

阶段 0 的 macOS 占位界面不依赖资源目录或字符串目录。现有 `Assets.xcassets`（含 AppIcon）、`Localizable.xcstrings`、`InfoPlist.xcstrings` 及 `Resources/` 仍位于 `RawStudio/`，由现有 iOS 同步分组管理；macOS target 没有引用这些资源。后续需要 macOS 图标或本地化时，再明确添加适配资源，避免把 iOS 专用图标配置默认带入 macOS target。

## 验证

- `plutil -lint RawStudio.xcodeproj/project.pbxproj macOS/RawStudioMac.entitlements` 通过。
- `xmllint --noout RawStudio.xcodeproj/xcshareddata/xcschemes/RawStudio-macOS.xcscheme` 通过。
- 初始验证时 Xcode 缺少 `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`。通过 Xcode 官方首次启动组件安装完成修复后，`xcodebuild -list -project RawStudio.xcodeproj` 可列出 `RawStudio` 和 `RawStudio-macOS` 两个 scheme。
- `xcodebuild -project RawStudio.xcodeproj -scheme RawStudio-macOS -destination 'platform=macOS' -derivedDataPath /private/tmp/RawStudioDerivedData CODE_SIGNING_ALLOWED=NO build` 成功（`BUILD SUCCEEDED`）。命令使用 `/private/tmp`，以避开受限环境不能写入用户 Library 下 DerivedData/log 目录的问题。
- 构建日志仍提示当前会话无法连接 CoreSimulatorService、未发现模拟器运行时，并且 Metal Toolchain 缓存不可写；这些提示未阻断 macOS target 构建。模拟器运行时/Metal 工具链的交互式可用状态未在本次确认。

## 下一阶段约定

阶段 1 可基于 `macOS/` 独立实现文件夹访问服务；扫描服务需异步、可取消并增量交付结果。目录面板选择的 URL 应持有 security-scoped 访问生命周期，并持久化 bookmark。当前 target 的 sandbox entitlement 已允许用户所选文件夹读写。
