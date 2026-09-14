# 棋研悬浮教练

iOS 17 及以上的本地象棋识别与画中画教练。项目于 2026-09-14 从原任务的源码记录重建；录屏图像只经设备本机回环连接传输，模型、识别、棋局跟踪和计算均在本机运行。

## 使用

1. 打开 App，点击红色录屏按钮，在系统弹窗选择“棋研录屏”，确认开始直播。
2. 默认自动开启悬浮指导，然后切回棋盘。屏幕底部棋子的颜色会自动识别，无需设置“我执”红方或黑方。
3. 浮窗显示确认后的棋盘和建议箭头，思考时保留棋盘；画面过期时保留上次局面但撤下箭头。
4. 如果从中局进入且无法推导轮次，回教练选择“当前轮到”并点“同步”，再回棋盘等连续稳定画面。超时后也可点同步重试。

系统录屏确认和锁屏解锁需要用户亲自操作。

## 识别范围

已适配用户提供的木质圆棋子主题、红黑两种朝向，以及 1280×2781 和旧 1320×2868 两组布局。新实图有一张红方已走 h2e2（炮二平五），模板按该真实局面标注，黑方接着走。旧原始截图已丢失，旧布局测试使用当前棋盘按旧几何重建，不能等同于旧原图验收。

识别以颜色、笔画、棋子数量和将帅合法位置共同验证，不要求始终是标准开局。连续两张稳定画面后才接受新局面，轮次由合法走子（最多追赶两步）推导；无法推导时明确同步，不猜测。对不支持主题或模糊/遮挡画面暂停新指引。

## 引擎与素材来源

使用官方 Pikafish 2025-06-23 源码（2b6cf79d55d9d168604cf42ce61b517653d6f2fc）和先前从 Pro 象棋核对过的同款 NNUE。权重 SHA-256：

`9b2ce59b760c26f284b9fcadd091fa789d9fd4e8c1dd71ffbd42212503a13e95`

默认单线程、16 MiB Hash、800 ms 搜索；保留实际走子历史用于重复局面处理。Pro 额外的亚洲规则等改动未获得完整源码，不能宣称整个 Pro 算法完全复刻。详见 `docs/pikafish-integration.md` 与资源目录中的许可及来源记录。

原 Pro 棋盘图片未恢复；当前显示素材取自用户新提供的无高亮棋盘，保留来源与裁切哈希，详见 `XiangqiCoach/Resources/ProUI/ASSET_PROVENANCE.json`。文件名 pro_ 仅为恢复现有加载接口。

## 构建

需要 Xcode、Ruby 和 xcodeproj gem：

```sh
ruby scripts/generate_project.rb
xcodebuild -project XiangqiCoach.xcodeproj -scheme XiangqiCoach \
  -configuration Debug -destination 'platform=iOS Simulator,id=<模拟器ID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

真机使用个人团队自动签名，应用标识为 `com.lgj.xiangqicoach`，扩展为 `com.lgj.xiangqicoach.broadcast`。更换开发者需要修改生成脚本中的团队标识。签名证书、配置文件不纳入源码。

运行状态最多每秒写入一次 `Documents/coach-diagnostics.json`，包含构建号、会话 ID 和记录时间，避免把升级前的旧诊断误当成新版本验收。该文件不保存录屏照片或头像。

## 测试

覆盖真实本机 TCP 分段/错误/旧帧传输、棋规和走子历史、识别正反方向及已走炮局面、搜索取消/超时/恢复、PiP 时钟与缓存、棋盘图形和过期箭头隔离。每次重建必须重新运行；历史测试记录不代替当前验收。最新结果见 `docs/rebuild-validation.md`。
