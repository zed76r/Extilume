# 仅外屏恢复：D2 离线归因

2026-10-29。本轮完成恢复专项 1.1／1.2 的证据梳理与诊断补强；不是画面修复，也不构成新的实机授权。没有清保护锁、改写旧恢复记录、安装／启动候选或操作显示器。

## 旧现场时间线

原始证据仍在 `.local/verification/d2-prepared-9xe04zcy/`；只在本机保留。下表仅列 `state-jucfi25h/process.log` 的聚合结果，以 controller 的 `systemHasPoweredOn` 为零点，不输出设备标识或原始日志。

| 阶段 | 可核验结果 |
| --- | --- |
| 睡眠前 | 初始停用一次；随后恢复双屏并人工确认内屏主屏 C。日志中的一次 `disableStarted` 在睡眠请求前约 254.402 秒，两次 `enableCompleteStarted` 在请求前约 253.617／239.097 秒。 |
| 唤醒后 +0.287 至 +9.310 秒 | controller 连续 23 次 `layoutRestoreRejected`／`restorationFailed`。八字段签名相同：仅 `isBaselineDisplaySubset=true`；其余七项均 false。旧固定失败码为 `absent`，不能直接映射为当前错误枚举或屏幕角色。 |
| 唤醒后 +10.058 秒 | controller 记录 `restorationVerified`。 |
| 唤醒后 +10.309 秒 | helper 记录 `restorationVerified`。 |
| 整个唤醒后窗口 | `disableStarted`、`enableCompleteStarted`、`originsStarted` 均为零；没有观察到醒后再次显式停用或提交恢复写入。 |

主日志共 1,703 条结构化事件。上述时间是标记之间的连续时钟差，不等于实际故障至可交互恢复的清醒时长，不能用于补判十秒门槛。人工报告的切分抖动与输入源救援仍判失败；最终软件终验不抵销画面故障，也不是正常退出验收。

## 可知与未知

- 睡前记录的 baseline C 为内屏主屏的完整双屏；applied B 为原外屏单屏；pre-disable A 为外屏主屏的完整双屏。23 次拒绝不是完整 C、精确 B 或 A。
- 日志没有保存拒绝时的活动内屏／外屏数量，连接事件也不提供足够的角色关联。旧失败码不应解释成“内屏缺失”。
- 五个关键源文件的冻结摘要与当前源码、准备 manifest 所记 HEAD 的对应源码均不同。2026-10-29尚未定位精确旧源码；2026-10-30已从旧回放目录与Git补齐全部83项源码字节及记录层构建绑定，见下节，仍不能把当前源码直接当作旧实现。
- 当前模型的定向反例显示：内屏单屏能产生 D2 的八字段签名；原外屏单屏会命中 `matchesApplied=true`。这支持优先排查“外屏未活动”，但依赖布局比较规则及记录来源一致，不能无条件认定历史缺失角色，更不能证明画面故障原因。
- 零显式提交标记只约束已记录的主辅调用，不证明系统没有隐式回退，也不排除未覆盖的入口。主日志没有单独恢复入口的完整执行凭证，不能把它补写成已运行或已排除。

## 当前源码的写入边界

当前 `InternalApplicationController` 经 `InternalApplicationWorker` 建立 `GuardSession(.disableInternal)`；停用及受保护布局平移使用 `.forAppOnly`。睡眠请求冻结门禁并撤销重应用；唤醒先恢复／核验 C，成功且授权仍有效才允许重应用。

controller、helper 及独立恢复入口共用 `recoverGuardRecord`：只有记录仍挂有内屏责任、独立读回证明内屏未启用时才尝试启用；只有非空且来源／连接／最新记录均允许的计划才写原点。启用及原点恢复使用 `.forSession`。helper 的接管要求原 owner 已实际结束，不能把 IPC 断开当作所有权已交接。

Apple 对公开事务选项的定义是：`.forAppOnly` 在应用结束时回到当前登录会话配置，`.forSession` 持续到登录会话结束。[CGConfigureOption](https://developer.apple.com/documentation/coregraphics/cgconfigureoption)。公开提交函数按事务应用配置：[CGCompleteDisplayConfiguration](https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:))。这些定义提示应核查作用域结束，但不能证明私有启用 API 的实际效果或旧现场的回退时点。本轮不改作用域选项。

## 最小补强与反例

在成功读回快照、重新检查访问权之后，且在布局校验之前，发出 `recoveryTopologyObserved`。三个生产入口分别标注 controller、helper、recoveryEntry；上下文只含五个计数：在线、活动、活动内屏、活动物理外屏、活动其他屏。不记录 UUID、数值 ID、注册表路径或 EDID，也不增加显示器读写调用。

沿用原有八项布局关系；新计数不能授予恢复权限。完整 C、精确 B、缺内屏、缺外屏、空集、未知身份及未知完整布局使用纯 fixture 区分。未知完整布局可与 C 拥有相同计数，因此计数不能替代身份与布局核验。空集在布局解析失败前仍留下计数，测试要求恢复继续拒绝、无启用或原点写入、保留责任。

后续候选仍需证明具体原因；不将子集当成 B、不加固定等待、不清故障、不重放两份旧准备责任。没有这一步依据，1.3 及真实画面准入保持未完成，也不重开完整验收矩阵。

验证：全量 Swift 679 项，678 通过、1 项既有交互跳过；补充 D2 签名断言后定向 GuardRecovery 22 项通过，Release 构建、OpenSpec strict 及 diff 检查通过。独立窄审查未发现新增阻断；未独立重验旧现场原始数据。

本轮离线产物及构建结果：`.local/verification/internal-recovery-analysis-20261029-xwlqwm9n/`。历史物理结论见 [本机验证记录](local-display-verification.md)；App 与恢复专项的责任仍按 [接入验收记录](internal-display-app-acceptance.md)分列。

## 2026-10-30：补齐旧源码与责任阶段修复

在 `c-wake-offline-repair/consistency-replay/` 找到82项与D2清单完全一致的源码／测试；唯一不同的 `GuardRecovery.swift` 从Git提交 `770f1a99c3d251b4a9ffcb8c21d591b7a0e17362` 取得匹配字节。`DisplayGuard.swift` 在该目录和 `legacy-replay/` 均有精确副本。隔离重建后逐项核对83项摘要，原文件均保持一致；额外回放fixture不计入这83项。

旧修复的 `source-test-manifest.json` 与D2清单完全相同；其 `verification-summary.json` 所记probe摘要、D2准备清单及保存二进制摘要也完全一致。因此已补齐记录层的源码／既有462项测试／Release／保存二进制对应关系，不再以“找不到旧源码”阻断分析。该关系不等于重新构建出了逐字节相同的二进制，也不独立证明历史现场运行时映像。

使用精确旧源码回放28项测试通过，包括新增匿名fixture。旧 `Snapshot.layout()` 只取活动屏，要求存在主屏；`DisplayLayout` 要求主屏原点为零。在原记录为完整双屏C、B为外屏单屏零原点且记录与事件确属同一实现的前提下，非空严格子集只有两个单屏，`matchesApplied=false` 排除了外屏单屏。因此可条件推导23次拒绝观察到内屏单屏，不能进而认定外屏物理断开、驱动故障或隐式作用域回退。

独立审查另发现可复现的责任阶段缺口：已确认C、`owned`且两项pending均false时，首次读到内屏单屏会先落盘`restoring`再拒绝；后续精确B再现时，原本只接受`owned`的重新挂责分支被永久跳过。新增当前实现反例在修复前失败，证明该序列存在，但D2的23次观察均不匹配B，不能把它写成D2根因。

最小修复仅调整共享 `recoverGuardRecord` 的阶段时点：有待恢复写入时，仍先持久保存`restoring`再调用原生操作；没有待恢复写入时，核验失败保留原记录，只有最终完整C、内屏状态、访问权及最新记录全部核验后才确认恢复。精确B、来源、硬件身份及会话／代次检查保持，子集不成为B或新C，故障和停用门禁不解除。

新增回归覆盖首次子集拒绝无写入且记录不变、owner持锁时helper不能接管、owner释放后helper重新加载同一记录并由精确B恢复C；这是共享恢复函数与真实存储锁的交接模型，不是实际helper进程的EOF／退出或电源生命周期验收。原有错误会话、旧代次、新C／来源替换、信息后负向、睡眠门禁及挂责先于原生写入的回归通过。2.3完成；2.1／2.2的联合覆盖、1.3的D2因果修复及现场任务保持未完成。

验证：全量Swift686项，685通过、1项既有交互跳过；首次受限运行有随机测试偏好持久化失败，在允许这些测试偏好写入的环境重跑后无失败。Release构建通过，独立窄审查未发现本次阶段改动的阻断问题。没有安装／启动候选、显示写入、睡眠或故障注入，未清保护锁及旧实验责任。

证据保存在 `.local/verification/internal-recovery-binding-20261030-eltuj95g/`，包含83项来源／摘要、精确历史源码、独立fixture、修复前失败、修复后回归及构建记录。回放fixture初次误将`owned`且无pending等同于`canClear`，后按`canClear`还要求`restored`阶段纠正断言；初次失败与纠正后的结果均保留，未修改历史产品源码来使fixture通过。

## 2026-10-31：App协议与主辅交错契约

2.1复用现有`InternalApplicationCommand`、`InternalApplicationEvent`、`PrimarySessionStatus`及`InternalApplicationExpectation`，没有新增协议或配置。仅将原生入口内已有回调构造移至`InternalApplicationWorkerState.callbacks(parentPID:)`，使生产入口与测试peer使用同一事件映射。新增`testNativeCallbacksCarryRecoveryAndLateFaultThroughApplicationProtocol`通过真实`GuardChannel`驱动App控制器，核对停用成功→恢复调整→重应用及代次更新→故障→迟到成功；故障后不发布`applied`，原C、会话、最新代次及未决责任保留。测试替代进程身份与实际显示效果，不证明真实原生会话已完成这些动作。

2.2新增`testLateEnableAcrossWakeAndIndependentAcknowledgementsRetainsHandoffResponsibility`，组合真实`recoverGuardRecord`、主辅两套`InternalPowerGate`、owner生命周期与独占存储。分别注入启用调用跨越睡眠／提前唤醒后的真实成功和抛错；主辅均等待各自确认，owner确认不能解除helper门禁；保留停止或手动暂停意图，helper在owner持锁时不能取得恢复权，交接后恢复同一最新C、session和generation，已经真实启用的调用不重复启用。交错在闭包栈内确定性触发，不是线程调度或系统电源通知实测。

| 契约 | 本轮及既有直接回归 |
| --- | --- |
| 模式意图、实际状态与故障责任分离 | 新App协议测试；`DisplayModeCoordinatorTests`的显式激活、失败恢复持久锁及迟到旧状态测试 |
| 同用户／会话／代次／独立恢复证明 | `InternalApplicationProcessTests`错误用户及未就绪成功拒绝；`InternalApplicationControllerTests`最终证明拒绝；`InternalFaultedExitTests` |
| 电源确认不等待在途调用，结果不假定取消 | 新主辅组合测试；`InternalPowerGateTests.testSleepAndAcknowledgementDoNotWaitForInFlightCall`；`DisplayEnableTransactionTests.testSleepDuringCommitKeepsActualResultAndConsumesHandleOnce` |
| 唤醒、停止、暂停和真实失败的保留 | 新主辅组合测试；`InternalSessionLifecycleTests`重复睡眠／提前唤醒、停止／暂停、真实失败及退出期间新睡眠测试 |
| 最新C和单一恢复归属 | 新主辅组合及独占锁交接测试；`ProtectedInternalApplicationTests.testOriginalProtectionContractRestoresLatestCAfterNewGenerationLayoutCommit` |

全量Swift688项，687通过、1项既有交互跳过，Release构建通过；独立窄审查未发现本次回调搬移或联合测试的阻断问题。开发说明同组更新，2.1／2.2按离线契约完成。1.3仍缺D2画面因果依据；真实helper EOF／退出、电源事件投递、显示／输入物理效果及十秒指标仍归现场任务，不能由上述fixture改判通过。

本轮证据保存在 `.local/verification/internal-contracts-20261031-1xb589xd/`。未操作显示／睡眠／现场故障、未清保护锁或旧实验责任、未安装／启动候选，日用准入仍为No-Go。

### 计时、事件兼容与物理确认工具核对

3.2按工具准备完成，不增加新的采样或现场轮次：

- 信息／负向兼容沿用`ConnectionCandidateStateTests`的脱敏事件fixture：信息不变更授权或清故障，信息后负向仍撤权；`InternalLinkReconfigurationGateTests`验证较早pending起点不被后续故障或在途返回覆盖。生产观察器将`invalidate(observedAt:)`返回的最早适用时刻交给恢复时钟。
- `InternalRecoveryClockTests`与`RecoveryTimingTests`验证最早起点、未知时钟／跨boot、同轮端点及休眠区间；不可信或不能关联的休眠不扣除。`RecoveryTimingReportTests`保留裸数字不扣休眠、输入顺序拒绝及“软件观测不证明物理恢复”的边界。
- 故障侧`ConnectionTimingMarkersTests`／`ConnectionTimingWindowTests`核对人工物理动作标记顺序与时钟回退；恢复侧`RecoveryConfirmationWindowTests`核对无默认确认、显式点击仅记录一次、取消不记录、失败不能重试。实际入口在点击时调用`captureRecoveryClock`。这些自检不证明人工实际做过动作或设备已经可交互。
- Python校准工具20项、挂起计时包装器7项纯fixture自检通过，覆盖错误binary／timebase／boot、缺失／重复电源端点、伪休眠、超出事件边界及失败输出脱敏。未执行它们的采集／record分支。

D1与D2清单的probe摘要及各自保存实物一致；D1冻结校准脚本与当前`scripts/calibrate-recovery-clock.py`字节相同。当前`ContinuousClock`、`RecoveryClockSample`、`RecoveryTiming`、`InternalRecoveryClock`、`RecoveryTimingReport`、`RecoverySuspensionRecorder`、`RecoverySessionNotifications`及`RecoveryConfirmationWindow`八个源码文件也与D2清单相同。因此可保留并复用历史源码／工具层的校准依据，不机械追加一次睡眠。D1比较记录仍为历史`positive-pause`、单电源区间、正常观察器退出、`hardwareAcceptance=false`；不将其旧休眠区间、样本或授权用作新轮次证据。

当前现场环境与新样本适用性尚未检查；3.1冻结候选时仍须核对环境、工具／二进制绑定及D1适用条件，变化或未知不能自动判为通过。实际故障、独立内屏／C核验、同轮人工可交互终点仍须现场证据。元数据核对结果保存在本轮证据目录的`timing-tool-binding.json`，不包含boot UUID、设备身份或原始采样。

### 共享验收准备的继续核对

3.1／3.3的具体准备见[共享验收清单](internal-display-recovery-acceptance.md)。已定位历史九个通过子轮；六轮有85项源码清单及probe摘要条目，稳定主失效三轮暂未找到对应摘要绑定。原结论保留，当前复用仍须逐项核对，未把原外层收尾失败改判为成功。

本轮139份源码仍与上述验证清单一致，将同一Release的`Extilume`／`extilume-probe`复制至`.local/verification/internal-recovery-acceptance-preparation-20261031-cmltving/`并记录摘要、macOS／架构／SDK元数据，未启动。清单保留F1–F5的15轮小计和所有S1–S7义务，不把小计当完整总数；App、owner与helper须按实际故障角色区分。D2因果、现场环境、具体边界分支与真实在途驱动均未闭合，故不编造可执行批次、不勾3.1／3.3。未改运行代码或重跑Swift／Release，原688项及Release结果只绑定源码一致的离线成果。
