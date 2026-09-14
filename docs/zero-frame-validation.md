# 录屏零帧修复 · 2026-09-14

目标构建：2026091404。用户反馈录屏正常、进入后没有反应。

## 故障证据

- 真机 2026091403 诊断：`isScreenCaptured=true`，`receivedFrameCount=0`，`phase=waitingForFrame`；主应用与 `XiangqiCoachBroadcast` 进程均在运行。计数在棋盘识别前增加，因此该故障不由红黑识别或引擎引起。
- 当前接收端将 `127.0.0.1:43981` 放入 `NWParameters.requiredLocalEndpoint`，同时向 `NWListener(using:on:)` 再指定固定端口。原生 Network.framework 最小复现直接抛出 POSIX EINVAL 22，监听器未创建。
- 旧 iOS 模拟器的 `build/auto-side/tests.log:2205` 与 `build/regression/release-tests-v2.log:1704` 均已出现系统原文：`Local endpoint has port set, cannot override to 43981: 127.0.0.1:43981`。这也确认之前测试通过时，宿主应用的真实监听器已经失败。
- 对照：只指定 requiredLocalEndpoint 可在 43981 上 ready；重复设置随机端口 `.any` 也能 ready，因此原有两项使用随机端口的 TCP 测试漏掉了生产配置故障。
- 实际 FrameSender 的 BGRA/NV12 编码对照中，DeviceRGB/sRGB 共 24 次均能产生可解码 JPEG，没有证据支持更换编码颜色空间。

## 修复与验收范围

接收器只通过 requiredLocalEndpoint 指定本机地址和固定端口，保留仅 127.0.0.1 接收的边界。新增显式非零固定端口（43982，避免与测试宿主的 43981 冲突）的真实连接、JPEG 收帧断言。诊断独立保留接收通道、系统录屏与 PiP 状态；静止状态每十秒更新存活时间，仍仅覆盖本机一个 JSON 文件，不保存屏幕截图。

本次不调整棋盘模板、红黑自动识别、引擎权重和棋盘绘制。自动化传输结果与真机系统录屏结果分别记录，不能用注入的 sample buffer 代替用户实际开启 ReplayKit 的验收。

## 自动传输验证

直接编译未替换实现的生产 FrameSender、FrameReceiver 和 FrameProtocol，默认 `127.0.0.1:43981` 实际收到了 6/6 张 CMSampleBuffer 编码帧，覆盖 BGRA、NV12 全范围/视频范围、709 标记和旋转。该项在 macOS 原生框架执行，证明生产编解码和固定端口连接路径；不代表真机 ReplayKit 或持续后台录屏。证据：`build/zero-frame/real-sender-results.jsonl`。

## iOS 回归与安装

- Xcode 26.6 / iOS 26.5 专用模拟器，Release 配置：92 项 XCTest 全部通过、0 失败。新增显式固定端口收帧用例已执行通过，测试日志不再出现固定端点端口覆盖错误。结果：`build/zero-frame/tests.xcresult`，日志：`build/zero-frame/tests.log`。
- 真机 Release 签名构建通过；2026-09-14 23:55 安装 2026091404，23:56 启动成功。
- 从 iPhone 实际读回构建号 2026091404、新会话 ID、`receiverStatus=录屏接收器已就绪`、`isPictureInPicturePossible=true`。此时 `isScreenCaptured=false`，系统录屏尚未重新开启；因此当前只确认真机接收器启动成功，持续录屏收帧待用户系统确认后检查。证据：`build/zero-frame/phone-after-launch.json`。
- 此次为网络故障诊断，回归前保留了原日志；没有清除手机数据。UI 绘制无改动，图形相关 XCTest 已随整套测试通过，未把静态截图称为实际连续录屏。
