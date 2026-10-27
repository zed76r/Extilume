# Proposal

## Why

用户反馈：在应用中点击“外屏主屏”或“仅外屏”后，要等待很久外屏才成为主屏；相同显示器在 macOS 显示器设置中切换主屏则感知为瞬间生效。需要定位应用增加的等待并尝试消除，避免将必要的恢复保护、系统事务耗时或状态刷新延迟混为同一问题；当前尚无分阶段实测数据，不能断言根因或承诺零延迟。

## What Changes

- 对齐菜单点击、请求受理、旧模式恢复、快照／保护准备、主屏提交、实际主屏读回、菜单状态更新的时间线；仅外屏另记内屏停用完成时间。
- 在相同硬件、拓扑及起始布局下，对比应用基线、macOS 显示器设置和修复候选，区分首次选择、重试和两个模式互切。
- 根据测量尝试最小修复，优先处理经证实的队列阻塞、重复昂贵探测或不适用于显式点击的等待；保留新鲜身份核验、写前复核、独立保护和恢复责任。
- 增加显式切换的响应与计时验收要求，实际读回前不标记成功；若未复现或没有安全有效的修复，记录结论和剩余瓶颈，不以调短超时或提前更新状态冒充提速。
- 不扩展显示拓扑支持，不引入新控制 API、常驻服务或性能设置，不处理 PC 输入切换，不借此解锁“仅外屏”故障保护或替代恢复可靠性提案。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `primary-display-session`：补充显式外屏主屏切换的分阶段计时、避免无关等待及真实效果验收要求。
- `internal-display-session`：补充仅外屏与模式互切的分段响应要求，区分主屏迁移与内屏停用，并维持恢复门禁。

## Impact

- 预期检查 `MenuBarApplication`、`DisplayModeCoordinator`、`PrimaryController`、`PrimaryReapplicationScheduler`、`InternalApplicationController`、`InternalApplicationWorker`、`GuardSession` 以及共享快照／witness 路径；仅修改有测量依据的路径。
- 复用现有 Core／Native 测试、可注入控制器和快照读取，补充必要的时序回归及脱敏性能记录；不新增依赖。
- 与 `fix-internal-display-recovery`、`add-external-display-disable-mode` 并存，不接管其未完成的恢复验收，不覆盖工作区已有诊断改动。
- 本轮只新增规划文件；实施、真实显示切换／停用及安装需后续对应授权。静态分析和离线测试不能证明肉眼切换速度或真实输出已改善。
