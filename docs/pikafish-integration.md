# Pikafish 引擎恢复与来源

2026-09-14 根据本任务保留的源码输出和明确版本信息恢复。引擎使用官方 Pikafish 2025-06-23，NNUE 与此前对 Android Pro 象棋实机核验的模型逐字节一致。模型读取失败或局面非法时返回错误，不降级到简易 Swift 搜索。

## 固定来源

- 官方源码：<https://github.com/official-pikafish/Pikafish/tree/2b6cf79d55d9d168604cf42ce61b517653d6f2fc>
- 标签：`Pikafish-2025-06-23`
- 完整提交：`2b6cf79d55d9d168604cf42ce61b517653d6f2fc`
- 官方模型发布包：<https://github.com/official-pikafish/Pikafish/releases/download/Pikafish-2025-06-23/Pikafish.2025-06-23.7z>
- NNUE 大小：44,880,002 字节。
- NNUE SHA-256：`9b2ce59b760c26f284b9fcadd091fa789d9fd4e8c1dd71ffbd42212503a13e95`。
- 下载的源码归档 SHA-256：`bc34fe46cfa68d3aedaf1af7880b773e602e686243bac8b88ef90df38b4d0e2d`。
- 官方发行包 SHA-256：`0bcca441327c547772475665fe3763fda826064411f23ad042511785c11a36b5`。

完整源码和作者信息位于 `XiangqiCoach/Vendor/Pikafish`；打包模型、GPL、独立模型许可和机器可读来源位于 `XiangqiCoach/Resources/Pikafish`。

## 与 Pro 的一致性边界

此前已安装 Android 包 `vip.wqby.pro` 的二进制 UCI 自报 `Pikafish 2025-06-27`。其模型与这里官方模型哈希完全相同。相同标准开局、单线程、16 MiB Hash、固定 12 层，推荐 `g3g4`、59,716 节点、完整主变化一致：

`g3g4 h7e7 b2e2 h9g7 h0g2 b9c7 b0c2 a9b9 a0b0 i9h9 b0b6`

Pro 还包含 AsianRule、ChineseRule、ScoreType、LU_Output 等额外选项，对应分支完整源码仍未找到。因此这里只能确认模型完全相同、上述开局核心搜索相同，不能宣称所有长将、长捉与残局行为都与 Pro 一致。官方分值为标准兵值归一化，Pro 默认 Elo 显示，数字不能直接比较。

## 本地适配与 API

- 仅给官方 `Engine` 和 `Network` 增加只读模型加载状态检查，避免 CLI 的网络校验通过 `exit()` 终止 iOS App；未修改搜索或评估算法。
- 原生桥先检查 FEN 行列、子数、子位、将帅安全、轮次和每步历史，防止旧解析器对错误识别输入越界。
- Swift `search(position:timeLimit:maximumDepth:nodeLimit:history:)` 保持原接口，默认 0.8 秒预算、最大 64 层；报告真实完成深度、节点数和耗时。
- `AnalysisHistory` 的可信根局面与实际合法走子传入 `set_position(rootFEN, moves)`，保留重复与长将分析所需历史。Swift 先线性重放检查最终局面相符，原生完整检查每步棋规。
- 所有重型初始化与模型加载都在第一次 `search` 的调用队列上执行。`XiangqiEngine()` 本身只保存配置。
- `cancel()` 由线程安全版本号和短锁停止旧搜索；不会让主线程等待整个搜索或加载过程。过期结果不返回给界面。
- H/E/r 编码转换为标准 N/B/w，返回 ICCS 走法和主变化再次通过当前 Swift 局面的合法走法校验。
- 引擎使用单线程和 16 MiB Hash，与 Pro 原生默认相同。Swift 只提供输入/输出桥，不采用 iOS 子进程方式。

## 构建和许可

C++17 / libc++；编译 `src` 中 33 个 `.cpp`，排除 `main.cpp`、`universal` 和 `temp_builds`。原生启用 `-O3`、`NDEBUG`、`IS_64BIT`、`USE_POPCNT`；arm64 额外启用 `USE_NEON=8`。Swift 桥接头为 `XiangqiCoach/Engine/Native/XiangqiCoach-Bridging-Header.h`。

引擎为 GPL v3，完整条款见源码 `Copying.txt` 与应用资源 `GPL-3.0.txt`。分发修改版本须遵守源码及许可提供义务。模型权重按官方 `NNUE-License.md` 使用，个人非商用练习；商业使用须另获授权。

## 恢复验证

`build/engine-recovery/host-check.log` 记录本机重建的官方 33 个源文件与 ObjC++ 桥验证：模型加载、标准开局 59,716 节点、吃车、避毒兵、应将、一步杀、非法输入、取消/恢复以及双马循环历史的 2,079 节点对照。

`PikafishEngineTests.swift` 含 13 项引擎测试；`XiangqiPositionTests.swift` 含 8 项棋规测试，覆盖开局走法数量、蹩马腿、塞象眼、河界、炮架、将帅照面、兵卒方向、九宫、坐标和变更局面。主机结果不能代替 iPhone 连续录屏、后台悬浮及设备性能验收。

2026-09-14 使用恢复后的 Swift/ObjC++/C++ 在 macOS 直接编译并执行上述 XCTest：21 项全部通过（8 项棋规、13 项引擎），耗时约 5.7 秒；日志为 `build/engine-recovery/swift-tests.log`。未运行 xcodebuild 或操作模拟器。
