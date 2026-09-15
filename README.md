# 棋研悬浮教练 · 天天象棋人机辅助

一个用于**天天象棋人机练习**的 iOS 辅助工具：通过系统录屏读取指定棋盘，在本机识别局面、调用 Pikafish 计算，并用画中画展示棋盘、走法箭头和语音提示。

**本项目不维护。** 仅按仓库中的固定棋盘样本实现，不提供持续更新、主题适配或问题排查承诺。天天象棋改版、棋盘布局或棋子样式变化后，请自行修改源码、补充测试并重新编译安装。用途为人机练习与研究。

## 功能与范围

- 只适配指定的木纹圆棋子棋盘，红方在下、黑方在下自动识别，自动根据合法走子和上一步起点/落点标记确认轮次，无需校准、选择颜色或手动同步。
- 支持标准开局和已走棋局面；仓库样本包括红方 `h2e2`（炮二平五）之后的黑底局面。
- 浮窗显示已确认棋盘和起终点箭头；思考时保留棋盘，点选棋子、等待重新识别时可回看上一条走法。
- 双方回合都计算：我方显示绿色箭头并播报，对手显示蓝色预测箭头且不播报，明确标为“对手走法”。
- 已记录的实际棋局支持我方或对方悔棋，稳定确认后恢复历史轮次、撤销旧搜索和箭头，再计算恢复后的局面；超出已记录历史时仍需可信标记重新同步。
- 语音直接播报着法，例如“炮二平五”，不加“建议”前缀。
- 接受实际新局面、切换朝向或停止录屏后，旧走法清除；过期画面不会冒充实时识别结果。
- 录屏、识别、NNUE 计算均在手机本机完成，无需云端识别服务。

仅支持样本对应的对局棋盘位置，不提供其他主题或玩法布局兼容。手机分辨率不同不等于一定可用，是否可用应以实际录屏回归为准。

## 使用

首页只有一个“开始”主按钮，无开关、不用滑动；使用说明和实时状态放在右上角“使用帮助”二级页面。应用绘制的指引区域采用直角，系统画中画外框仍由 iOS 控制。

1. 在真机打开 App，点击“开始”。接收器、识别和悬浮来源自动准备。
2. 弹出的系统录屏面板已指定“棋研录屏”，点击“开始直播”。这一次系统确认不能由 App 跳过。
3. 确认后自动开启悬浮指导，再切到指定的人机棋盘，保持完整棋盘可见。关闭过悬浮窗时，返回首页点“继续指导”恢复。
4. 看到走法后在天天象棋中操作。点选棋子时可回看上一条走法，落子确认后显示下一阶段状态。
5. 从中局进入时保持上一步白色起点与落点标记可见，程序自动确认轮次；标记不清晰时等待下一次可确认的走子。
6. 结束时关闭系统录屏。

[系统录屏确认需要用户亲自操作](https://support.apple.com/guide/security/replaykit-security-seca5fc039dd/web)，无法实现无授权静默开启其他 App 的屏幕采集。模拟器不能代替真机 ReplayKit 连续录屏验收。开发签名到期后需要重新签名安装。

## 编译安装

需要 macOS、Xcode 和 iPhone，最低部署版本为 iOS 17。已验证的开发环境为 Xcode 26.6、iOS 26.5 模拟器，以及 iPhone 17 Pro Max / iOS 26.6.2。

仓库已包含 Xcode 工程、Pikafish 源码、NNUE 权重和测试资源，可直接打开：

```sh
open XiangqiCoach.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中，为主应用和 `XiangqiCoachBroadcast` 扩展选择自己的开发团队并启用自动签名。若更改 Bundle Identifier，需同时修改主应用、扩展、测试目标，以及 `XiangqiCoach/Capture/BroadcastPickerView.swift` 中的 `extensionBundleIdentifier`。选择已连接的 iPhone 后运行。

若需要重新生成工程，安装 Ruby 的 `xcodeproj` gem，并先修改 `scripts/generate_project.rb` 中的团队和 Bundle Identifier：

```sh
gem install xcodeproj
ruby scripts/generate_project.rb
```

生成脚本会重建 `.xcodeproj`，因此工程中的自定义配置应同步回脚本。签名证书、描述文件和安装产物不提交到仓库。

## 棋盘变化后如何自行适配

| 文件或目录 | 作用 |
| --- | --- |
| `XiangqiCoach/Analysis/BoardLayout.swift` | 屏幕中棋盘四角交叉点的归一化坐标 |
| `XiangqiCoach/Resources/board-template-*.png` | 红黑棋子与空位模板 |
| `XiangqiCoach/Analysis/BoardRecognizer.swift` | 图像特征、颜色/清晰度检查、棋子分类与朝向判断 |
| `XiangqiCoach/Analysis/LastMoveRecognizer.swift` | 上一步起点/落点标记识别 |
| `XiangqiCoach/Analysis/BoardTracker.swift` | 连续帧确认、合法走子跟踪和自动轮次锚定 |
| `XiangqiCoachBroadcast/FrameSender.swift` | 录屏帧缩放、编码和本机发送 |
| `XiangqiCoach/App/CoachViewModel.swift` | 录屏、识别、计算和提示状态协调 |
| `XiangqiCoach/Overlay/` | 画中画棋盘与走法绘制 |
| `XiangqiCoachTests/Fixtures/` | 独立于生产布局的真实棋盘样本与标注 |

适配时先采集新棋盘的实际录屏帧，标注真实棋子和局面，再更新布局、模板或特征实现。不要把已经走过棋的图片当成标准开局，也不要仅放宽识别阈值来掩盖错位。同步覆盖两个朝向、选中高亮、走子动画、浮窗阴影、遮挡、模糊、吃子和局面切换。

## 测试与本地诊断

```sh
xcodebuild -project XiangqiCoach.xcodeproj -scheme XiangqiCoach \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=<模拟器ID>' \
  -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO \
  ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO test
```

测试覆盖真实本机 TCP 传输、独立坐标实图识别、红黑朝向、已走炮局面、棋规与走子历史、计算取消/超时、上一步标记与自动轮次、最新帧调度、选子期间走法保留，以及图形箭头与旧帧隔离。另覆盖双方连续悔棋、跨历史段恢复、悬浮启动/停止竞态与原生按钮整块命中。界面流程在 `.maestro/`，本次验证记录见 [一键入口与悔棋回归](docs/simple-start-takeback-validation.md)。

运行诊断保存在 App 自己的 `Documents/coach-diagnostics.json`，只记录版本、状态、局面、帧数和耗时，不保存录屏照片或头像。诊断文件和完整截图留在本地，不进入仓库。自动测试通过不代表所有天天象棋版本和真机布局均可用。

## 引擎、权重与素材来源

使用 [官方 Pikafish 2025-06-23](https://github.com/official-pikafish/Pikafish/tree/2b6cf79d55d9d168604cf42ce61b517653d6f2fc) 核心，默认单线程、16 MiB Hash、800 ms 搜索，保留实际走子历史用于重复局面处理。

随仓库提供的 NNUE 为 44,880,002 字节，SHA-256：

```text
9b2ce59b760c26f284b9fcadd091fa789d9fd4e8c1dd71ffbd42212503a13e95
```

该权重与此前核对过的 Pro 象棋权重一致；本项目不包含 Pro 的完整源码，也不声称复刻了其全部规则或功能。

- Pikafish 源码许可：[GPL-3.0](XiangqiCoach/Resources/Pikafish/GPL-3.0.txt)。
- NNUE 权重单独条款：[NNUE-License.md](XiangqiCoach/Resources/Pikafish/NNUE-License.md)，包含未经许可不得商用等要求。
- Zstandard 依赖许可：[BSD 条款](XiangqiCoach/Resources/Pikafish/Zstd-BSD-LICENSE.txt) 与 [固定来源记录](XiangqiCoach/Resources/Pikafish/Zstd-Source-Notice.txt)。
- 引擎接入说明：[pikafish-integration.md](docs/pikafish-integration.md)。
- 棋盘与棋子图来自用户提供的截图裁剪，来源记录见 [棋盘样本](docs/board-fixture-provenance.json) 和 [绘制素材](XiangqiCoach/Resources/ProUI/ASSET_PROVENANCE.json)。这些第三方素材的权利不因放入仓库而转移；文件名 `pro_` 不表示素材来自 Pro 官方。
