# 旧实验布局责任结清方案

2026-11-06。**新候选经单独授权执行一次后部分完成并停止：第一份已结清，第二份仍未决。** 停止阶段为 processes，类别 closeout-environment；两份原件备份均保留，不重试、不回滚。新旧候选及各自消费／停止回执保留，Dg1 继续阻断。本方案不属于 Dg1 的动作白名单，不新增其现场额度。历史执行与最新结果见文末。

## 已知状态与来源

2026-11-02 只读前检保存于 `.local/verification/dg1-readonly-preflight-20261102-ud71eot0/`。当时用户确认双屏正常、可交互；两次进程采样未见已知控制进程。两份旧记录均为 `owned`、布局责任未决、来源已决，且无内／外屏启用责任。当时完整布局与两份旧 baseline／applied 均不相同；UUID 集合及原模式匹配。以上是当时的读回，未来操作前必须重新核验。

目标记录仅为：

- `.local/verification/d2-prepared-9xe04zcy/primary-preparation-state/recovery-record.json`
- `.local/verification/d2-prepared-9xe04zcy/c1-primary-preparation-state/recovery-record.json`

默认日常目录的布局记录及 `internal-session/recovery-record.json` 当时均不存在；这不证明自定义目录没有责任，也不能解除两份旧记录。用户确认“画面正常”不等于同意把当前 C 认作两份旧会话的新恢复基准。

## 为什么不能直接调用现有命令

[`PrimaryController`](../Sources/ExtilumeNative/PrimaryController.swift) 的 `confirmUserOnly()` 可在明确确认后更新 C，但仍保留 `owned` 阶段。`recoverOnly()` 的常规恢复分支即使布局责任已解除，仍会调用 `.forSession` 原点提交；其来源未决特殊分支也不适用于当前两份来源已决记录。`finalizeOnly()` 会清除记录。因此不能将这些命令组合为本方案的“仅更新记录”操作。

[`RecoveryRecord`](../Sources/ExtilumeCore/RecoveryRecord.swift) 已有 `observe(_:source: .confirmedUser)`、`beginRestoration()` 和 `confirmRestored(actual:)` 状态转换；[`RecoveryStore`](../Sources/ExtilumeCore/RecoveryStore.swift) 已有独占所有权及原子保存。专用入口在 [LayoutRecordCloseout.swift](../Sources/ExtilumeNative/LayoutRecordCloseout.swift)，复用这些机制并执行以下前置条件。它不调用 `PrimaryController`、显示 writer、启用／停用、恢复或清记录入口；正常 App 和既有恢复命令的行为保持。

## 专用路径的限定合同

1. 先实现、离线验证并审查专用路径，冻结源码、工具及候选。之后才请求明确授权：采用独立核验的当前完整 C 作为这两份旧会话的新基准，更新指定记录，并创建限定的私有原件备份、回执及存储锁／原子保存临时文件。授权不包含显示提交、睡眠、App 启停、删除记录、清故障锁或重置历史额度。
2. 操作前重新核验同 boot、工具绑定、记录目录归属、完整 UUID／硬件身份和原模式、进程观察能力及无已知 owner／helper／在途事务。分别取得独占存储所有权，再核对原件字节摘要、session、generation 和完整内容仍与获批材料相同。保护或归属不明即停止。
3. 每份记录只接受经验证的 `owned`、`sourceUnresolved=false`、`internalDisplay=nil`、`externalDisplay=nil` 布局责任。两次独立完整读回须等于获批 C、与旧记录 UUID 集合一致，且人工确认实际双屏正常。用户须明确确认这就是两份旧会话的新 C；软件正常或旧的人工确认不能代替。
4. 在写入前保存不可覆盖的原件字节备份及摘要，私有权限、文件和目录同步完成后才继续；备份不能依赖 `RecoveryStore.save` 的临时回滚文件。所有状态转换只在内存副本中进行：确认用户 C，检查 baseline 精确为该 C、无 pending／unresolved，再开始恢复、确认 restored 并执行完整 `validate()`。任何异常均不保存部分转换。
5. 每份仅一次原子 `store.save`，保留原 session、generation 和 applied／原始布局来源；专用路径不得持有原点 writer 或启用 API，不调用现有恢复／finalize／clear。保存前再次核对原记录与独立 C；保存后核对完整记录、独立 C／模式未变，保留原件、前后摘要和结果回执。单独的 `restored` 标志不足以放行。
6. 两份文件不构成跨目录原子事务。首个错误立即停止，保留双方原件和已完成／未完成回执；不自动回滚、不重试、不重放旧布局。两份均独立核验结清之前，Dg1 继续阻断。历史画面失败、No-Go、故障锁及既有额度均保留。

## 离线验证范围

用合成记录及临时私有目录验证：新完整 C 正向结清；旧 applied／pre-disable 或缺屏子集不能冒充新 C；来源未决、启用责任、代次／原件变更、独占锁冲突、第二次 C 不同、备份同步失败、转换失败、原子保存失败均停止；两份部分成功须保留原件和回执。还须证明调用图没有显示写入入口，并验证保存后独立读回失败不能报告结清。不得用真实旧记录充当测试夹具。

## 实现、候选与验收边界

- Core 的 `confirmingLayoutCloseout(actual:)` 只生成经验证的内存副本；`closeLayoutResponsibility` 只在原件字节匹配、独占所有权及备份／观察回调成功后保存一次。实际原子替换前再次核对原件、目录身份及时间／进程门槛。
- 新路径在替换后目录同步失败时保留不确定的新文件及旧 inode 备份，停止且不回写原记录；永久原件备份另已持久保存。普通 `RecoveryStore.save` 保持原有失败回滚行为。两者有独立故障注入反例，不能把同步失败当作未发生更新。
- 两份旧记录先统一核验资格及独占锁，再保存双方原件，然后逐份执行。保存后的实际字节另存 `old-*-restored.json`，`old-*-verified.json` 记录前后摘要、session 和 generation，最终再次比对两份记录与摘要。
- 观察复用两个独立 snapshot 和独立内屏硬件 witness；每一组完整快照必须精确等于获批 C，包括模式及数值 ID，变化即停止。boot 必须一致。请求中的物理确认和采用新 C 仅为输入标记，不能代替用户对具体清单的真实授权。
- 当前 UID 的已知映像按门槛及约一秒间隔检查，不保存进程路径列表或参数。超过三秒观察间隙、进程查询错误、意外已知控制映像均停止；查询结束后重新读钟，不能用查询前的旧时间授予提交。有限采样不能排除瞬时或改名控制进程，不宣称全轮无 owner。
- 单次处理窗口为 30 秒连续时钟，输入观察须为同 boot 最近十分钟内取得；每次只读 witness 受剩余截止约束。文件系统及系统查询不可抢占，迟到调用返回后停止；已请求的保存可能已落盘，不能据超时假定未写入。异常记录和回执收尾保留，不重试、不为额度或报告补写责任。
- 每个已核准 evidenceDirectory 使用不可覆盖的 `attempt.json`，并绑定候选及输入摘要。复制清单仍指向同一目录；失败、部分完成或更换输入不能自动获取重试授权。换候选须重新核定范围，不复活 Dg1 或历史额度。

初始冻结候选：`.local/verification/closeout-prepared-20261103/`，其中 probe、完整源码清单及未授权模板均有绑定。该候选后来已授权执行一次并失败，evidence 目录已含消费及停止回执，**不可再次执行**；初始 `field.template.json` 的 `approved=false` 不代表尚未尝试。验证材料在 `.local/verification/closeout-offline-20261103/`，实际输入和核对材料见文末。Dg1 v4 仍仅静态准备，v1–v4 均保留且未执行诊断。

限定入口形式如下；原候选已失败停止，**禁止照此重跑**。任何后续候选须先完成离线诊断与范围核定，再按相应门槛取得新的具体授权：

```sh
/absolute/frozen/extilume-probe --closeout-layout-records --allow-record-write /absolute/private/approved-field.json
```

必须同时检查命令退出码为 0、没有 `stopped.json`、双方原件与前后摘要／独立终验均吻合，才可接受 `complete.json`。写完成回执期间也可能超时；此时命令失败并保留停止回执，不能只凭完成文件存在放行。`save-requested` 后失败的角色须按未确认结果处理，不能自动回滚或重试。两份真正结清之前 Dg1 继续阻断；实际结清也不代表画面修复或任务 4.3 全部通过。

104 项定向 Swift 回归（含 21 项新增结清测试）、60 项 Python 自检及 Release 构建通过，最终构建前后 64 份编译源码／包描述不变，145 份源码／测试／脚本／包描述绑定一致。离线验证覆盖成功及 legacy v1 不迁移、资格／来源／启用责任拒绝、字节变化、独占冲突、备份及保存失败、双份部分成功、目录身份及提交时目录替换、身份读回冲突、迟到回执／慢查询／最后提交门槛、证据目录不可重用。限定独立审查发现的三项问题已修正；最终慢查询门槛由主代理修正并用合成反例核验。这些离线结果不能证明现场成功；后续实际授权、日常退出终验及结清失败结果见下节。

## 首次授权尝试与停止结果

现场材料保存于 `.local/verification/closeout-readonly-preflight-20261103-feil9_o6/`。新只读前检发现日常 App 正在使用默认目录，记录在观察期间由外屏恢复中的 v4 变为仅布局责任的 v2 `owned`。经用户单独授权一次正常恢复退出后，先核对原 PID、映像和恢复目标，再调用一次 `NSRunningApplication.terminate()`；菜单可访问性读取超时，未通过菜单发出退出请求，也未使用强退或重试。实际 App 已退出，日常记录为 `restored`、无 pending／unresolved；独立双读 C／原模式、同 boot 内屏硬件身份均吻合，用户再次确认双屏正常可交互。

用户随后明确授权采用当前内屏主屏完整 C，仅结清两份指定旧记录。实际输入保存在 `field.authorized.json`，原候选执行一次后退出码 1，仅返回通用失败信息。候选 `evidence/` 仅有 `attempt.json` 和 `stopped.json`，无完整观察、原件备份、保存请求或完成回执；两份真实记录均仍为 `owned`、布局 pending，字节及 session／generation 与获批原件一致。具体失败原因未记录，不能推断为某个硬件或进程故障。

最终已知 App／控制／probe 进程采样为零，未再发送信号。原候选与已消费的尝试标记、授权输入和停止回执全部保留，禁止复用或删除标记补轮；没有重试，也没有请求睡眠。Dg1 额度未消费，两份旧责任继续阻断 1.5／4.3。下一步须先离线定位停止原因；不能把正常退出成功、授权或源测试通过当作旧记录已结清。

## 2026-11-06 离线停止诊断

仅凭旧回执无法还原具体失败分支。源码调用链表明，目录／独占锁、时钟／boot／进程门槛、两次完整快照、独立内屏 witness 或身份比对失败，都可能在首个观察回执之前停止。进程路径读取失败同样属于停止条件，但没有证据证明历史现场触发了该条件；不放宽任何门槛，也不据此归因。

修订后的工具在 `stopped.json` 增加固定枚举 `stage` 及脱敏 `failureCode`，保留原有 `verifiedRoles`。阶段区分存储／所有权、各项 checkpoint、首／第二快照、布局比对、内屏读取／比对、备份、保存及终验；嵌套检查成功后恢复调用方阶段，失败保留实际停止阶段。CLI 同样只输出有限错误类别，不输出异常原文、路径、进程参数或 `NSError.userInfo`。停止回执仍为尽力持久化，失败时不能保证阶段信息留存，不能补写或重试。

这些字段只说明有限操作阶段。尤其 `stage=save`、`failureCode=store-io` 不能区分替换前失败与替换后同步失败，`verifiedRoles=[]` 也不能单独证明零保存；仍须合并保存请求、原件和独立终验判断不确定结果。旧回执不补字段，历史原因保持未知。

修改前，将与旧候选绑定一致的 145 份源码／测试／脚本／包描述完整保存于 `.local/verification/closeout-diagnostics-offline-20261106/previous-source-snapshot/`。本轮仅变更两个 Native 源文件及一个测试文件，没有替换旧冻结二进制、模板或消费／停止回执，也没有生成新现场候选或重置额度。现有 Dg1 v4 不因新构建通过而更新或放行；新候选仍需重新核对适用性、明确清单与授权。

107 项定向 Swift 测试（含 24 项结清测试）与 Release 构建通过。新增三个合成测试覆盖锁冲突、进程门槛、两次快照、嵌套 checkpoint、内屏读取／身份、部分完成及敏感错误不序列化；均注入时钟、boot、进程检查和设备读回，不运行真实 probe。限定独立审查未发现此次增量改变原调用顺序、授权、期限或保存契约。验证材料保存在同一离线目录。本轮未做真实记录读写、App 操作、显示事务或睡眠；1.5／4.3 继续阻断，进度仍为 7/15。

## 新候选与本次只读前检

用户随后授权准备新候选及只读前检，并重新确认开盖、解锁、双屏正常可交互。新候选在 `.local/verification/closeout-prepared-20261106/`：从已验证离线 artifact 复制 probe，保存 145 份完整源码字节、64 份编译源码及两个冻结成员绑定。主代理独立复核通过；模板三项授权标记均为 false，结清 evidence 目录为空。旧候选及 Dg1 v1–v4 物料保持，未重置额度。

本次前检材料在 `.local/verification/closeout-readonly-preflight-20261106-rb_dyozc/`。一次性脚本只允许 `--display-snapshot`、`--internal-display-snapshot` 和 `--sample-recovery-clock`，只向该私有前检目录保存读回；不调用结清、恢复、App 启停或睡眠。两份目录通过只读 fd 暂持独占锁，完成后释放。执行前审查提出绑定校验后启动及 proposal 同步后的期限漏检，已在实际 spawn 和持久化返回后加门槛，以 12 项合成断言核验；没有将审查意见当作现场通过。30 秒连续时钟约束包含准备和观察，各 reader 受剩余预算限制；不可抢占调用返回后停止，不承诺硬实时。

本次单次前检退出 0，连续耗时 1.18 秒，无停止回执。两次完整 C 精确一致，内屏硬件身份与前后 boot 时钟匹配，原模式吻合；前后已知映像采样为零。两份真实记录仍为 v2、owned、布局 pending，来源已决且无启用责任，字节／session／generation 与历史绑定一致。目录身份及原件在前检结束后再次独立核验，未写入；日常布局记录 restored、无未决责任。进程证据仍仅为有限已知映像采样，不排除改名或瞬时 owner。

拟采用的新完整 C 为：

| 角色 | 逻辑原点 | 逻辑尺寸 | 模式与旋转 |
| --- | --- | --- | --- |
| 内屏，主屏 | (0, 0) | 1728 × 1117 | 3456 × 2234、120 Hz、0° |
| 外屏 | (1728, 297) | 1920 × 1080 | 3840 × 2160、144 Hz、0° |

`field.proposed.json` 是本次初始完整私有输入，`approved=false`、`adoptCurrentC=false`；实际画面确认来自本轮用户回答。`approval-summary.json` 提供脱敏清单：仅上文指定两份旧记录各至多一次 owned→restored，持久原件备份及实际字节／前后摘要，保留 session／generation／applied，30 秒窗口，零显示提交／睡眠／App 启停，失败停止不补轮。前检时点仍须另获本次采用该 C 与限定记录／备份／回执／存储临时文件写入的授权，上次已消费授权不沿用；随后获得的新授权及执行结果见下节。输入观察超过十分钟即不适用，实际工具仍须重新核对原件、身份、C、进程和期限；前检通过不保证结清成功。

## 本次新授权执行：部分完成后停止

用户明确选择「授权本次仅记录结清」，按上述具体清单另存 `field.authorized.json`，不修改初始模板。调用前原件、目录、工具／源码及输入十分钟时限仍匹配，结清 evidence 为空。新候选只调用一次 `--closeout-layout-records --allow-record-write`，退出 1，未重试。初始模板仍为 false 不代表候选未执行。

停止回执为 `verifiedRoles=[old-1]`、`stage=processes`、`failureCode=closeout-environment`。已持久保存双方 original、七组完整观察，第一份 save-requested／restored／verified，以及第二份 save-requested；没有 complete。该类别只定位到进程查询门槛，不能区分枚举与映像读取等具体系统调用，也不能据此认定某个控制进程存在；不追溯宣称此前旧候选是同一原因。

失败后仅做独立只读收尾：

| 记录 | 实际结果 | 独立核验 |
| --- | --- | --- |
| primary-preparation-state（old-1） | restored，无 pending／来源未决 | 新 baseline 精确为获准 C；实际字节与 saved／verified 摘要吻合，session／generation／applied 等其他字段保持 |
| c1-primary-preparation-state（old-2） | owned，布局 pending | 实际字节仍为获准原件，session／generation 及目录身份保持，未补写 |

双方不可覆盖原件备份均与获准摘要吻合。收尾两次完整 C 等于获准 C，同 boot 内屏身份正常，日常布局记录仍 restored；最终已知 App／控制进程采样为零。用户再次确认实际双屏正常可交互。有限采样不证明全轮无 owner，也不抹除已发生的停止。

材料仍在本次前检目录，包含 `closeout-stop-audit.json`、`post-closeout-summary.json` 与独立收尾快照／时钟；候选 evidence、授权输入及原件保留。没有回滚第一份、补写第二份、再次执行结清、显示提交、App 启停或睡眠。第二份仍阻断 1.5／4.3，Dg1 v1–v4 额度未消费，历史 No-Go 及 7/15 不变。

后续应先离线细分进程检查失败原因，并为仅剩一份责任重新核定方案。现有入口要求两份均 owned，不能把已 restored 的第一份重新纳入补跑，也不能放宽资格或复用消费标记绕过。新范围、工具及任何真实记录写入仍须分别具体准备和授权。

## 进程检查的离线细分

保留两轮已消费候选的源码、二进制及回执后，修订源码将原 `processes／closeout-environment` 的三个拒绝分支分别编码为：

| 新错误类别 | 含义 |
| --- | --- |
| closeout-processListSizing | 首次进程列表容量查询未返回正数 |
| closeout-processListRead | 实际列表读取无有效结果或达到预留容量边界 |
| closeout-processImageUnavailable | 映像读取失败，且不能按原 ESRCH 条件确认进程已消失 |

生产扫描调用及放行条件保持：仍扫描当前 UID，仍只跳过自己、非正 PID 和已确认消失的条目；已知三个映像仍须同时满足亲子及同一执行文件条件。查询操作与判断拆开以便纯合成注入，未增加重试、延迟、忽略未知进程或记录 PID／路径的分支。列表／映像失败继续拒绝。

合成反例确认，“映像不可读且进程未消失”必然拒绝，即便它可能被猜作自身 witness；猜测不能替代身份。`freshWitness` 在收到回复后、等待退出前仍有 `checkAccess` 调用点，未来只读诊断须覆盖该交错，但现有证据不能证明当时出现过某种进程状态。旧回执没有子分支信息，不补写、不将本次源码分类当作历史原因已查明，也不以再次写记录触发诊断。

本轮仅修改诊断源码和合成测试，未打开实际恢复状态路径、运行现场进程扫描或 Native reader，也未准备新现场候选。111 项定向 Swift（含 4 项新进程分类测试）及 Release 构建通过；限定独立审查未发现拒绝／放行语义变化，指出原生查询与 witness 退出交错仍须后续只读验证。146 份源码／测试／脚本／包描述及其中 64 份编译源码已绑定，离线材料在 `.local/verification/closeout-process-diagnostics-offline-20261106/`。旧候选及已消费标记保持。

## 单份剩余责任方案（仅规划，尚未实现）

目标仅为上轮仍未决的 `c1-primary-preparation-state`（old-2）；已经独立核验结清的 `primary-preparation-state`（old-1）只作只读凭证。拟用独立的 `legacy-layout-residual-closeout-v1` 范围，不把现有双记录入口改成任意数量，也不接受将 old-1 再次转换或保存。现有代码仍要求两份均 owned，不能按本方案直接执行。

1. **先完成只读诊断。** 新的只读诊断须复用生产进程检查，并覆盖自身 witness 回复／退出交错；离线验证及实际诊断范围另行准备。仍有查询错误或观察缺口就停止，不能用残余记录的写入来试错。有限采样及改名／瞬时进程盲区保持，不宣称完整 owner 缺席。
2. **绑定前次部分结果。** 新清单限定引用前次授权输入、attempt／stopped、双方 original、old-1 restored／verified 及上轮独立收尾证明；核对输入摘要和 UUID 语义、角色与 session／generation、old-1 保存后摘要及 old-2 未变原件。所有材料须为私有、非符号链接文件，引用身份或内容不符即停止，不删改旧标记。
3. **只读保全 old-1。** 以只读目录／文件 fd 独立解码校验 old-1：实际字节须等于已核验保存后字节，restored、无 pending／来源未决，baseline 为前次获准 C，其他字段保持。只读凭证不进入可写 `RecoveryStore` 集合，不产生保存、转换、清除或自动修复请求；目标与凭证的目录／文件身份必须不同。提交前及终验再次核对，变化即停止，不回滚或改写凭证。
4. **重新核对 old-2 与当前 C。** 独占目标目录，核对私有目录身份、原件字节及完整 Core 校验；仅允许 owned、布局 pending、来源已决、无内／外屏启用责任。当前 C 须同 boot 独立双读、与新输入精确一致，并有独立内屏硬件身份及新的人工实际观察；布局／模式应与前次获准 C 相符。旧数值 ID／boot 样本不作为当前证据。C、模式、责任或原件变化须停止并重新核定，不能顺带更新 old-1。
5. **只保存目标一次。** 先在新私有 evidence 目录消费新范围的一次授权并持久保存 old-2 原件，保留与前次 original 的绑定；只在内存副本采用获准 C、转换为 restored 并校验，然后复用现有单份 Core 原子保存与实际替换前检查。保留 version／session／generation／applied 等来源，不迁移、删除或补写其他记录。保存后持久保存实际字节、前后摘要及独立终验；30 秒连续窗口、三秒观察间隙、输入十分钟时限及查询／同步返回后的截止检查保持。
6. **失败与新授权分开。** 替换后同步失败保留不确定结果，不自动回写原件。已请求但未终验的保存不得仅靠 phase 或空 verifiedRoles 判为未写；不补轮、不回滚 old-1。新工具、源码、候选和具体目标／C／限定文件写入均须先准备并验证，再另获明确授权；旧次授权、原候选和 Dg1 额度不能沿用。全部旧责任独立闭合后也不能自动执行 Dg1 或改判历史 No-Go。

实现前须冻结的合成验收包括：单份成功只写 old-2；旧双份入口继续拒绝单份；old-1 已变／非 restored／凭证或前次输入摘要不符；old-2 字节／代次／责任变化；C／模式／身份冲突；锁与符号链接／目录替换；备份失败；原子替换前拒绝及替换后同步失败；保存后凭证变化、迟到终验与完整回执规则。均用合成记录，不能使用真实旧记录作夹具。本方案不新增任务勾选或现场额度，1.5／4.3 与 7/15 保持。
