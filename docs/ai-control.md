# AI 命令行操作

新版 App 提供本机 Apple Events 接口，AI 可运行 `Extilume --control` 获取 JSON，无需 computer use 点击菜单栏。接口只连接已经运行的 App，不启动第二个控制器；旧安装包不支持此接口。首次调用可能需要在 macOS“隐私与安全性 → 自动化”中允许调用方控制 Extilume。

安装支持接口的版本后（本地验证包可替换 APP 路径）：

```sh
APP=/Applications/Extilume.app
"$APP/Contents/MacOS/Extilume" --control status
# 用户已明确授权显示操作后，使用 status.actions 当前返回的标识：
"$APP/Contents/MacOS/Extilume" --control apply-externalOnly --allow-display-write
"$APP/Contents/MacOS/Extilume" --control status
```

`status` 只读取 App 的菜单状态，不读取或修改恢复记录。返回 `status` 文本和当前可用 `actions`。动作复用菜单处理器、忙碌检查和控制器保护锁：`apply-externalPrimary`、`apply-externalOnly`、`disable-external`、`restore-external`、`retry`、`retry-recovery`、`restore-for-configuration`、`confirm-configuration`、`quit`。只使用本次状态中实际返回的动作；停用外接屏与恢复外接屏是不同标识，避免重复请求误触反向切换。

后续源码新增结构化字段：`sessionState`沿用`PrimarySessionStatus`的Codable协议（例如`{"applying":{}}`、`{"recoveryIncomplete":{}}`），`selectedMode`表示当前意图，`stateMode`表示状态对应的模式，`requiresExplicitActivation`表示是否还需显式应用。判断某模式已应用须同时核对`sessionState.applied`、两种模式一致且无需显式应用，最终恢复还要关联独立凭证和实际画面。旧回复缺少这些字段时按未知处理，不能从中文文案推测成功。当前源码另提供`confirm-configuration`与`quit`，复用“设为恢复布局”及“退出并恢复”的菜单权限和忙碌检查；确认布局须有用户对当前C的明确确认。睡眠和解除保护不在此接口中。

2026-11-06结构化回复已通过52项Swift定向测试与Release构建，包含状态序列化、旧回复兼容、拒绝权限、模式意图与已应用模式不一致。该增量目前仅在源码和本地构建，安装版保持原状。

`--allow-display-write` 是调用方的显式声明，不代替用户授权。返回 `accepted` 仅代表操作已受理，不代表显示已经生效；后续读 `status`，仍需真实画面验收。`unavailable` 表示当前菜单不可执行。连接恢复涉及人工确认时返回 `human-confirmation-required`，不自动作出物理连接声明。

传输超时或报错后不自动重试写入，先读状态；超时不意味着操作没有执行。工具不清保护锁、不执行记录结清，也不提供强制开关；`quit`是正常退出请求，仍须核对实际退出和恢复结果。App 必须已运行支持接口的版本；命令默认连接 `com.extilume.development`，可用 `--bundle-id` 指定另一个已运行构建。

批次执行器现在可加`--target-process PID:START_SECONDS:START_MICROSECONDS`，放在`--allow-display-write`之后、`--bundle-id`之前；三个值来自内核进程身份读取，不能沿用上轮数值。客户端要求目标PID、启动时间和可执行文件路径与本次绑定匹配；调用的CLI须来自同一个候选App路径。接收端在动作前再核对自身PID和启动时间，过期绑定返回`target-mismatch`。未指定此参数时保留原来唯一bundle实例的行为。该参数不授权写入，不启动目标，也不解除App保护。

执行器的`control_application`适配器仅在已持久消费的请求内发送`start`／`restore`／`confirm-user`／`stop`对应命令，并在核验阶段发送只读`status`。每个写请求只能调用一次实际传输；调用前后复核App身份与候选摘要。客户端超时仅终止该次CLI子进程，App可能已经受理，批次因此停止并保留已消费次数，不能重试。完整现场采集与恢复交接仍需接入后冻结。

传输使用 `EXLM/ctrl` Apple Event，direct object 是 UTF-8 JSON 字符串 `{ "action": "status", "allowDisplayWrite": false }`，返回同样是 JSON 字符串。macOS 管理 Automation 权限，接口未开放网络端口。权限放行后的本机调用方可以发送操作，因此 AI 应在每次实际显示操作前确认用户授权范围。

本轮验证：50 项 Swift 定向测试通过，包含真实 Apple Events 向假控制器的往返、后台派发切回主线程、参数拒绝、菜单状态门禁和物理连接确认拒绝；5 项打包测试通过。尚未用真实 App 执行显示操作，也未验证跨进程 Automation 授权流程；本地候选不等于已安装版本。

安装前复核修正了打包签名：组装完成后执行本机 ad-hoc 签名，再严格验证整个 App。已验证的新包为 `.local/verification/ai-control-signed-20261106/Extilume.app`，旧安装包完整备份在同目录的 `previous-installed/Extilume.app`，清单与签名均已核对。旧候选 `ai-control-20261106` 不用于安装；安装准备时 `/Applications/Extilume.app` 尚未替换。本机签名不代表 Developer ID 签名或公证。

用户明确授权后，新签名开发包已原子替换到 `/Applications/Extilume.app`；独立回读确认整个包的文件摘要与候选一致，严格签名验证通过。旧包与原备份均保留并校验，临时安装目录已移除。安装前后未发现 App/控制进程；未启动 App、未切换显示、未清除保护锁。安装回执为 `ai-control-signed-20261106/installation-result.json`。跨进程调用与真实显示操作仍未验收。

批次接线新增待命启动：`--recovery-batch --state-directory <绝对路径>`须配合执行器生成的私有预算环境，仅用于隔离候选。它检查旧责任和持久保护锁、限制可选模式为仅外屏，并显式禁用自动启动；启动不会应用已有模式或自动恢复旧责任。App就绪及owner/helper身份回执先完整落盘，再以不可覆盖的硬链接原子发布；执行器逐一核对内核启动时间、父子关系和候选映像，不能只凭文件名认领进程。

批次的`confirm-user`控制适配器要求本轮本机弹窗返回正常。正常、异常、救援或取消均留固定结果；超时或异常停止，不重问补轮。完成核验还须读取请求后的configurationConfirmationStarted／Finished成功标记与结构化manualConfiguration状态，不能将之前已处于该状态当成新确认完成。`quit`受理后允许App已退出，交由独立退出验证器判断结果；不会要求已正常退出的App继续存活。

本轮122项Swift、122项Python回归通过，包含待命启动、保护锁保留、原子回执、人工确认异常／超时和退出竞态。真实候选、睡眠计时与独立恢复终验尚待集成；该版本未安装或实机运行。

2026-11-07新增`run-recovery-batch.py`固定正常单轮入口，已接入同轮正休眠、原生重应用、App退出回执及执行器独立C／模式／内屏／进程终验。`prepare`构建并冻结隔离候选与未授权模板；`run`只接受本轮绑定清单，仍通过上述目标绑定和正常quit接口。异常后至多派发尚未发送的同一次正常quit，超时不重发；保护进程及未EOF管道保留到安全交接。140项Swift、171项Python及Release通过，具体入口和边界见[恢复验收说明](internal-display-recovery-acceptance.md#固定正常单轮入口与独立终验2026-11-07)。当前持久保护锁仍在，未执行现场轮次或安装。
