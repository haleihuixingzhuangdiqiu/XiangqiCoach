# 2026-09-14 重建记录

原 `/Users/lgj/foxcodes/XiangqiCoach` 工程及构建产物已不存在，常用开发目录、可读缓存和已有 foxcodes.zip 中未发现完整源工程。本次从同一任务的历史源码读取记录与补丁中提取源文本，不执行旧命令。未能完整恢复的棋规方法按原接口重新实现并验证。

- 恢复 App 生命周期、搜索状态机、ReplayKit 扩展与回环传输、走子历史、PiP 和图形棋盘。
- 官方源代码和 NNUE 重新获取；权重与原 Pro 对照记录哈希一致，固定深度开局对照一致。
- 原 Pro 图像与旧主题原始截图已丢失。当前图形素材、识别模板来自用户新提供的两张截图，保留裁切和内容哈希；模板不包含头像、昵称或状态栏。
- 第二张资源保留已经走过的红 h2e2 与白色起点光圈，不改标成标准开局。
- 新补识别质量门禁、压缩变体、两种布局切换和同步意图延迟到新鲜画面确认。
- 新诊断文件记录构建号、记录时间及会话标识，区分历史诊断和当前运行。

重建工作副本位于 `/private/tmp/xiangqi-rebuild-20260914`，交付源码保存回 `/Users/lgj/foxcodes/XiangqiCoach`，并保留本地 Git 历史；独立源代码 ZIP 保存到 `/Users/lgj/Documents/XiangqiCoach-backups/XiangqiCoach-20260914-source.zip`。测试、截图及日志保留于工程的 `build/regression`；原始任务记录留在 Codex 自己的会话目录，不复制到交付代码包。

本次新测试结果单独记录在 `rebuild-validation.md`，不将历史通过记录当作当前验证。
