# 棋研桌面图标

日期：2026-09-15。随 1.1（2026091506）交付。

## 设计与资源

使用内置 `image_gen` 工具生成，主题为深玉绿背景、象牙色象棋棋子、金色轮廓和单字“棋”，以小箭头呼应走法指引。完整生成提示词保存在 [app-icon-prompt.txt](app-icon-prompt.txt)。

最终资产：[AppIcon.png](../XiangqiCoach/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png)。原始生成图保留在本机，选定图只做资源规格适配：等比缩小到 1024×1024、RGB 不透明 PNG。满幅方形背景，由 iOS 应用系统图标遮罩。

最终资源 SHA-256：`45685494c3ce3198afb8a50fa62e4d30933aab3050ed0a97c18f88348dbc47dd`。

## 接入与验证

- `Assets.xcassets` 按 asset catalog 类型进入主应用资源编译，`AppIcon` 为主应用的图标资源。工程生成脚本保持同样配置。
- 录屏扩展和测试目标不设置应用图标；清除原工程中指向不存在资源的 AccentColor 名称。
- 真机与模拟器 Release 构建成功；构建后 `Info.plist` 的 `CFBundleIcons / CFBundlePrimaryIcon` 指向 `AppIcon`，包含编译后的 `Assets.car` 和图标输出。
- 源图与 60/120 像素缩略图已核对：“棋”字准确清晰，关键内容在系统裁切安全区域内。
- 本地 Maestro 启动应用、核对开始按钮、返回桌面流程 **1/1 通过**；实际 iOS 26.5 模拟器桌面截图显示新图标，已做视觉检查。
- 主应用与录屏扩展均为 2026091506，严格签名校验及 IPA 完整性校验通过。
- 已覆盖安装到 iPhone 17 Pro Max 并启动，随后查询手机确认 `com.lgj.xiangqicoach` 为 1.1（2026091506）。使用原应用标识更新，未卸载或清空应用数据。

## 本地交付证据

`build/app-icon/` 保留生成资产元数据、两种平台的构建日志、Maestro 报告和桌面截图、安装/启动/手机版本记录。这些本地测试证据不进入仓库。

安装包：`build/app-icon/XiangqiCoach-1.1-2026091506.ipa`。

安装包 SHA-256：`f74f69d7a7ddb19779a3e15cb86d530e732919e18df468503ed04d7c4bcf64d6`。
