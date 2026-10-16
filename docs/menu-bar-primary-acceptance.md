# 菜单栏主屏模式本机验收

2026-10-16：阶段一 18/18 项任务的本机验收完成。当前 Mac 的主屏控制、生命周期与用户配置恢复关键路径已有实机证据，11 种注入状态的产品菜单已逐项展开核对，键盘访问和已生效入口的实际旁白名称通过。可在下述已验收配置中日常使用；长期稳定性及其他硬件组合不包含在本次结论中。

适用范围为 macOS 27.0.1、arm64、开盖、单台 MG27U 经 Mac 自带 HDMI 直连、双屏非镜像。Hub、多外屏、虚拟屏及内屏停用未获得本阶段验收。当前本地运行包与构建产物一致；未安装、签名公证或发布，也未提交或推送本轮改动。

## 证据类型

- **实机行为**：实际应用与显示器操作，以及独立探测进程的布局／快照读回。退出恢复须在应用结束后独立读回，再终验结清责任。
- **菜单状态回调**：实际应用主线程 `MenuBarApplicationDelegate.receive` 的状态文字。正常生命周期随后进入 `render`；退出期间的迟到状态可能被忽略，因此日志不单独证明桌面菜单呈现。
- **进程内菜单检查**：测试创建真实 `NSMenu`／`NSMenuItem`，状态和控制器来自注入对象，不创建实际状态栏入口。
- **桌面呈现**：用户提供的仅含本应用菜单的截图，以及用户键盘操作与 Computer Use 页面的核对。
- **注入状态的桌面菜单**：独立普通窗口链接当前 Debug 对象，复用产品 `MenuBarApplicationDelegate`、`NSMenu` 与状态栏组件，控制器为无显示写入的 `FakeSession`。这类证据验证产品菜单的本机呈现，不证明对应硬件故障实际发生。

完整原始记录、显示身份、逐次快照、进程输出及截图保存在忽略的 `.local/verification/` 私有目录，不纳入 Git。本文件保留结论及可复现的测试定位。

## 当前回归结果

当前代码全套通过：156 项 Swift（96 Core、60 Native，其中 12 项菜单集成）及 16 项 Python。新增菜单用例用独立预期表检查全部 11 种状态的文字、信息项禁用、五类动作的隐藏／启用，以及 Command-Q；没有安装状态栏入口或操作真实显示。

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/extilume-clang-cache swift test --disable-sandbox --cache-path /private/tmp/extilume-swift-cache
PYTHONPYCACHEPREFIX=/private/tmp/extilume-python-cache python3 -m unittest discover -s scripts -p 'test_verify_*.py'
openspec validate --specs --strict
```

测试定位：[原生控制器](../Tests/ExtilumeNativeTests/PrimaryApplicationTests.swift)、[菜单集成](../Tests/ExtilumeNativeTests/MenuBarApplicationTests.swift)、[启动恢复](../Tests/ExtilumeNativeTests/PrimaryStartupTests.swift)、[核心恢复记录](../Tests/ExtilumeCoreTests/RecoveryRecordTests.swift)、[状态模型](../Tests/ExtilumeCoreTests/PrimarySessionStatusTests.swift)。下表的测试名可在这些文件中直接查找。

## 全部规格场景

场景名称与 [primary-display-session](../openspec/specs/primary-display-session/spec.md) 对应。行为和呈现分别记录，单项实机通过不扩大为整个场景的桌面验收通过。

| 规格场景 | 自动回归定位 | 实机行为与验证边界 |
| --- | --- | --- |
| 启动主屏版本 | `testMenuShowsFixedModeAndUpdatesObservedStatus`；真实无外屏进程验收脚本 | accessory 策略、仅状态栏窗口及入口已检查；固定模式和已生效桌面菜单截图通过。 |
| 外屏成为主屏 | `testSuccessfulTakeoverPersistsOwnedRecordAndReadsBackB` | 独立读回外屏主屏、内屏活动、非镜像；已生效菜单截图与实际布局一致。 |
| 启动时没有外屏 | `testWaitsWithoutExternalDisplayAndRejectsMirroring`；真实进程脚本 | 单内屏启动等待、无显示事务通过；有旧责任会话的拔线后接入自动应用通过。空责任等待会话的首次接入完整实机流程未单独验证。等待状态有实际菜单回调输出；对应菜单的注入状态桌面呈现已通过。 |
| 重连或唤醒 | `testSleepAndRepeatedWakeReapplyOnceAtOriginalBaseline`、`testRepeatedEventsDoNotRewriteAndShutdownDoesNotReapply` | 实际重连及睡眠唤醒均只新增一轮稳定接管，基准保持；实际状态回调通过；等待、控制中与已生效菜单均已在注入窗口展开核对，未另行截取真实唤醒过程的瞬态菜单。 |
| 合盖后内屏重新连接 | `testClosedLidDefersReapplicationUntilFullBaselineReturns`、`testClosedLidUnknownLayoutStaysUnresolvedAfterOpeningAtBaseline` | 合盖不新增接管；开盖后事务／代次 1→2、基准保持，退出后独立恢复原基准并终验。 |
| 睡眠通知与写前读回交错 | `testSleepGateCancelsStartupAndRetryBeforeOriginWriter`、`testQuitDuringSleepDoesNotRestoreAndCanRetryAfterWake` | 启动／重试写前取消及睡眠期间退出已有模拟覆盖；正常实际睡眠唤醒通过。定时接管写前交错的专门实机注入未验证。 |
| 用户手动改变主屏 | `testConfirmCurrentConfigurationPromotesUnknownLayoutWithoutWritingDisplays`、`testConfirmDispatchBlocksCompetingActionsUntilSaved` | 内屏主屏、外屏左侧 C 不被抢回；明确点击后保存 C，不新增显示事务；实际唤醒再接管并保持 C。确认入口与手动状态的桌面呈现已在注入窗口逐项检查。 |
| 确认期间配置变化或失败 | `testConfirmCurrentConfigurationDoesNotCommitWhenThirdSnapshotDrifts`、`testDisplayEventInvalidatesConfirmationWhileSnapshotReadIsBlocked`、`testConfirmationSaveFailurePreservesRecordAndCanBeRetried` | 不稳定、缺屏／镜像、重复请求、睡眠和保存失败由模拟故障覆盖；未在真实存储／显示器上人为注入这些故障。失败文字及动作的进程内检查与注入状态桌面呈现均通过。 |
| A 到 B 到 C 到 B 后退出 | `testConfirmedCResumesThroughApplicationLayoutAndQuitsBackToC` | 实际确认 C→睡眠唤醒 B→正常退出，退出后两次独立 C、终验及重启基准均通过。用户 120 Hz 设置在退出后保留，随后恢复原可变刷新率。 |
| 用户修改后直接退出 | `testConfirmedConfigurationCanQuitDirectlyAtC`、`testDirectExitPreservesUncoveredC` | 两轮明确确认后的直接退出均独立保持最新 C，终验后才重启。 |
| 重连不能吸收应用状态 | `testOwnCallbackAndReconnectedBDoNotReplaceA`、`testReconnectedBRearmsRecoveryOfLatestCWithoutAnotherApplication` | 实际拔线／重连保持同会话与原基准，重连只新增一次事务；应用 B 未保存为用户原状。 |
| 系统开启镜像 | `testWaitsWithoutExternalDisplayAndRejectsMirroring`、`testMenuShowsFixedModeAndUpdatesObservedStatus` | 实际镜像前／中／退出后快照一致，应用无显示事务、不解除镜像；测试时使用无旧责任的隔离实例。已有未决责任与镜像组合的实机流程、真实镜像现场菜单截图未单独验证；不支持状态的注入菜单呈现已通过。 |
| 目标缺失后又返回 | `testMissingExternalDisplayKeepsPriorRecoveryResponsibility`、`testMissingTargetRestoresOnlyApplicableDisplayAndKeepsResponsibility` | 缺屏保留完整 C；退出请求取消、责任保留；重连后无新接管，重试正常退出后独立 C 及终验通过。缺屏期间进程保持运行。 |
| 应用失败但回滚成功 | `testApplicationFailureRestoresAndCanBeRetried`、`testRetryDispatchImmediatelyDisablesFurtherRetry` | 控制失败、已恢复、可重试由模拟故障及进程内菜单覆盖；对应注入状态的桌面菜单通过，未人为制造真实显示写入故障。 |
| 无法确认恢复 | `testUnknownSourceAtDifferentLayoutCannotBeRecoveredOrQuit`、`testUnconfirmedStatusRejectsTakeoverAndRepeatedRecovery` | 真实手动修改保持来源未决、不抢回；已有恢复未完成桌面截图。全部未决／失败子状态的注入桌面呈现已逐项通过。 |
| 显式恢复完整原基准 | `testUnknownSourceAtBaselineCanBeExplicitlyRecoveredAndRecordRetained`、`testUnknownSourceAtBaselineCanQuitAfterRestorationAndRetainsRecord` | 原基准的显式恢复、正常退出后独立读回和终验路径已有实机证据；陌生布局保持保护由模拟覆盖。 |
| 退出恢复成功 | `testSuccessfulTerminationRepliesOnlyAfterRecoveryCompletion`、`testQuitDuringInitialControlDrainsQueuedEventsWithoutStaleReapplication` | 正常退出及控制写入前取消均通过；应用结束后独立原基准／C、终验再重启。“正在恢复并退出…”的注入菜单呈现通过，未单独截取真实退出过程的瞬态。 |
| 退出恢复失败 | `testFailedTerminationCancelsAndLateStatusCannotReplacePendingExit`、`testFailedQuitKeepsRecordAndRecoveryCanRetry` | 实际缺屏退出取消并保留责任，接回后重试恢复、独立 C 与终验通过；“恢复失败，尚未退出”有实际菜单状态输出；对应注入状态桌面呈现及动作可用性通过。 |

## 生命周期集成结果

| 本机动作 | 独立显示结果 | 实际菜单状态回调 |
| --- | --- | --- |
| 双屏启动 | 外屏主屏，内屏活动扩展，恢复基准保持 | 正在应用→已生效 |
| 无外屏启动 | 仅内屏，无显示事务／新增责任 | 等待外屏连接 |
| 插入／重连同一 HDMI 外屏 | 外屏主屏，基准与会话保持，事务／代次 1→2 | 等待→正在应用→已生效 |
| 拔出外屏 | 内屏唯一活动主屏，完整基准及未决责任保留 | 等待外屏连接 |
| 睡眠／唤醒 | 完整双屏稳定后只接管一次，退出后独立恢复基准／C | 睡眠中等待→正在应用→已生效 |

这些状态文字取自主线程菜单状态回调；源码核对确认正常生命周期会继续渲染菜单。此处记录的是生命周期与状态回调结果，各状态展开后的桌面呈现另由复用产品菜单的注入窗口逐项验收，不把日志当作截图。

额外实机检查包括隔离实例的 SIGKILL 回退：强退前实际 B≠A；任何恢复／重启之前，两次独立读回均为 A，责任文件保持原字节；相同目录重启先处理旧责任再开始新接管。正常退出与控制写入前取消也均有独立终验。

## 菜单呈现与可访问性验收

独立窗口中已保存并逐张检查全部 11 种注入状态的真实产品菜单截图与 Computer Use AX 文本：等待、不支持、正在应用、已生效、手动配置、应用失败已恢复、恢复未完成、无法确认、保留失败、正在恢复退出、退出失败。文案完整，长原因无截断，状态以文字表达；信息项禁用，各动作的显示／隐藏与可用性均符合独立预期表。未决和失败状态始终显示恢复入口并禁用退出，退出过程中隐藏恢复和保留入口。证据位于私有目录 `.local/verification/menu-ui-acceptance-harness/`，其中 `all-eleven-result.json` 汇总全部菜单核对及退出后的独立读回。

这是当前产品原生菜单在本机的呈现验证，控制器使用无显示写入的 FakeSession；不把该证据写成实际硬件故障已发生。上方场景矩阵继续区分真实生命周期、模拟故障与菜单呈现。

实际可访问名称由用户的旁白操作独立确认：用户定位到 Extilume 状态菜单并听到播报，旁白字幕截图包含应用名、模式“外屏主屏”和状态“外屏主屏已生效”。其他状态及动态名称切换未单独以旁白验证；组件 getter 不代替实际读屏。方向键导航、回车打开系统“显示器”页面和 Esc 关闭均已核对。Command-Q 的 `q` 和 `.command` 已检查，未另行执行日常应用的真实快捷键退出。

临时验收窗口与辅助功能检查器均已退出，用户已确认关闭旁白。最后一轮验收前后，日常应用保持同一进程、完整显示快照和恢复目录文件校验值均未变化。本轮只补取呈现证据并更新文档，未重启或替换日常应用。
