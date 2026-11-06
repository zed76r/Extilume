# Dg1 普通双屏 C 诊断准备

2026-11-06最新状态：v6已按新授权请求一次睡眠，额度已消费，不可复用。唤醒后约0.343秒的首次快照只见内屏，执行器以incomplete-C停止；随后收尾读回双屏恢复，用户本机弹窗确认normal。电源观察器区间给出约18.775秒正休眠，但缺完整结束夹取，整体informationSufficient=false；不能据此判核心修复通过。v5原失败证据保持，详见文末。

以下为此前准备过程，保留当时的失败和未决状态，不作为当前状态：

2026-11-06。任务 1.4 的离线工具与单轮路径已准备。旧记录的新结清候选单次执行部分完成：第一份 restored，第二份仍 owned／布局 pending，Dg1 继续阻断。**Dg1 未执行，未请求睡眠或消费其额度**。诊断输入模板保持 `approved=false`，未冻结现场输入及救援范围，不能直接运行；新旧结清候选的消费标记不可删除或复用。

2026-11-06 离线续行只补齐[结清工具的停止阶段与错误类别](internal-display-recovery-closeout.md#2026-11-06-离线停止诊断)。Dg1 v4 与旧结清物料保持原样，未执行或重新冻结；工作树的新源码及 Release 构建不代表旧候选适用或现场授权。历史结清原因仍未知，两份旧责任门槛保持。

同日后续另授权的新结清候选静态准备及[一次只读前检](internal-display-recovery-closeout.md#新候选与本次只读前检)通过。随后另获仅记录结清授权，单次执行在 processes／closeout-environment 停止，第一份独立核验结清、第二份原件未变且未决，双方原件备份保留；软件及人工收尾画面正常。详见[部分完成结果](internal-display-recovery-closeout.md#本次新授权执行部分完成后停止)。停止不重试，Dg1 v1–v4 额度仍未消费，不计诊断或恢复验收通过。

## 范围与结果

遵守 [design 2a](../openspec/changes/fix-internal-display-recovery/design.md#2a-dg1-只建立正休眠的普通双屏-c-基线)：诊断工具零新增停用、未观察到意外控制进程时，普通内屏主屏完整 C 经实测正休眠后是否出现异常。最多一次普通睡眠，无新 owner／helper、停用、重应用、额外显示提交、模式改写、故障或日常重启。

若日常 App 尚在运行，只有另外明确列入现场范围后，才可对已核 PID／UID／内核映像及文件摘要的既有 `Extilume` 发一次正常退出请求。退出中的原责任补偿单列；退出失败、未得到预期 C 或责任未结清均停止，不强退、不调整主屏凑条件。

结果把 `informationSufficient`、`physicalObservation`、安全交接及清理分别报告；`hardwareAcceptance` 永远为 false，`ownerCausality` 永远为 unknown。正常一轮仅建立基线，不计 1.3、4.*、十秒恢复或 F／S 分支通过，不改历史 No-Go。

## 工具与绑定

静态 `prepare` 可在尚无 `.local/verification` 的新检出目录中创建共享预算目录及缺失父路径；不会启动程序、授权模板或消费现场额度。准备测试使用独立临时仓库，不依赖当前工作区已有目录。

- 执行器：[diagnose-recovery-baseline.py](../scripts/diagnose-recovery-baseline.py)；自检：[test_diagnose_recovery_baseline.py](../scripts/test_diagnose_recovery_baseline.py)。只用 Python 标准库，不新增依赖。
- 复用现有 `calibrate-recovery-clock.py` 的原生／Swift 样本校验与正休眠判定，以及既有 IPC 帧、坐标和角色校验。
- 只读 native 入口限 `--display-snapshot`、`--internal-display-snapshot`、`--sample-recovery-clock`、`--record-suspension-evidence`；没有恢复、停用、重应用或通用命令入口。
- 采集器现在即时输出 `power-event-observation`，使用刚加入合法区间的原事件，字段与最终证据一致；失败配对不输出。没有增加采样、显示写入或更改电源确认。
- 独立内屏 witness 必须与同次布局快照的数值 ID、canonical／reported UUID、boot／registry 证明及启用状态全部一致；原始快照和身份回复只保存在 0700 目录的 0600 文件。
- D1 时钟／工具的旧适用依据保留；新标记没有改变时钟读法，现场仍须重新核对当前环境适用性和同轮正休眠，不能沿用旧区间或旧授权。

本轮最终静态准备包：`.local/verification/dg1-prepared-20261103-v4/`。`manifest.json` 绑定五个工具／二进制成员及当前源码、测试、脚本和 `Package.swift`；`field.template.json` 是未授权模板。因专用旧记录路径涉及 Core／Native 编译源码，本轮重新构建 Release 并核对 64 份编译源码／包描述和构建绑定，材料在 `.local/verification/closeout-offline-20261103/`。v1–v3 均保留且未执行或消费现场额度；此前构建和前检材料原样保留。换工具副本不授予或重置现场额度；准备包不是完整 App 安装包，也不是现场环境已冻结的证明。

`prepare` 只创建新的私有目录、复制已构建 probe 与工具、保存摘要和模板，不运行它们；目录已存在即拒绝覆盖：

```sh
python3 scripts/diagnose-recovery-baseline.py prepare \
  --directory /absolute/new/private-bundle \
  --probe /absolute/built/extilume-probe
```

## 现场前必须填写和核对的子清单

以下是任务 1.5 的前置材料，不是本次授权。模板不能通过改一个 `approved` 值变成已获用户授权；实际授权还须来自用户对具体候选、动作及救援范围的明确确认。

| 字段 | 要求 |
| --- | --- |
| candidate／manifestSHA256／probeSHA256 | 对应本次准备包；变更工具须重新核对，不沿用旧候选授权 |
| macOS／architecture／bootSession | 当前实际环境及同启动会话；模板 boot 为空，未核对 |
| expectedC | 独立取得并明确确认的完整内屏主屏 C 快照及原模式；不从缺屏子集、旧目标或中间布局生成 |
| internalHardwareIdentity | 同 boot 的有效 registry 证明；现场再由独立内屏 witness 交叉核验 |
| records | 正好列出 `old-1`、`old-2`、`daily` 三个角色的绝对路径。两份旧责任必须存在、绑定原件摘要，且已按原门槛核验、无冲突或未决写入；禁止缺失声明。daily 已存在则绑定摘要；确认缺失只允许下述默认目录合同。不自动恢复、覆盖、删除或清锁 |
| daily | 已退出则 null；仍在运行且另获正常退出授权时，填写 pid、executable、sha256、recordSHA256；不为诊断先启动 |
| rescueOperator／rescueActions | 事先明确由用户接管的具体安全恢复范围；工具不自动执行这些动作，未落实不得开始 |
| calibrationApplicable／lidOpenAndUnlocked | 当前校准适用性、开盖且已解锁的现场核对，不沿用历史布尔结论 |

任何日常退出前，先用同轮时钟样本核对实际boot。运行时重新核对责任文件摘要及 `restored`／无 pending／无 unresolved 状态，日常退出补偿除外；允许补偿的日常记录必须是稳定 `owned`、来源已决且无内／外屏启用责任，补偿必须保留原 session、generation、baseline，并取得独立 C／原模式核验。旧责任门槛不满足就阻断，诊断工具没有绕过入口。

日常 App 已退出且适用目录已核定为默认 `~/Library/Application Support/Extilume` 时，daily 记录项可用 `absent=true` 和 `directoryIdentity={device: st_dev, inode: st_ino}` 代替 sha256，路径必须是该目录的 `recovery-record.json`，同时 `daily=null`。这些值须来自重新核验的真实目录；不能任填空目录、伪造 restored 文件或启动 App 生成记录。目录须已存在、归当前用户、权限 0700。运行期间以不跟随链接的目录描述符复核身份，检查该记录及 `internal-session/recovery-record.json` 确切不存在；内部目录存在时也须私有且无链接。任何记录出现、读取异常、目录替换／缺失均停止，请求睡眠前强制再查。该模式只证明核定默认目录的缺失，不排除其他自定义会话责任；归属不明仍阻断。正常退出后丢失原有记录继续算失败，不套用该缺失模式。

另获明确现场授权并完成上述材料后，才从冻结副本调用 `run --bundle <绝对准备包路径> --field <0700目录中的0600授权输入>`。本轮没有调用该入口。

## 配额、截止与异常收尾

每个 candidate 在准备包之外的固定绝对 `budgetDirectory` 领取一个 O_EXCL 标记。先 fsync 文件与目录，再允许首个动作；正常退出和睡眠各在请求前追加、fsync 消费记录。复制准备包仍引用同一标记，执行器重启、前检失败、崩溃或睡眠请求失败都不返还额度。不能通过换输出目录或清标记补轮。

从进入现场准备起总窗口最多 180 秒连续时钟（包含睡眠），与原生配对 wake 后十秒取更早截止。不会用人工点击时刻重置 wake 起点。原生读回／观察器就绪另有至多五秒的短等待，仍受更早总截止约束；迟到返回不授予新动作。截止只是采集上限，不是恢复通过期限、正常亮屏等待或强制唤醒依据。

全轮按约一秒一次的进程观察检查实际 PID／UID／内核映像；超过三秒清醒观察间隙、读取异常或意外控制进程就停止。有限轮询不能排除瞬时启动、伪装 argv 或其他未覆盖进程干扰，不推论全轮无 owner。原始进程参数和 `pmset` 前检输出不落盘、不输出。

睡前／醒后各最多两次完整 C 读回，同时取得独立内屏证明；实际画面另由人工确认。确认通道由清单绑定：新候选使用本机弹窗，旧清单缺省保留终端。仅在对应检查点接受实际画面确认；弹窗可选正常／异常／救援，关闭或超时不视为正常，默认回车选择异常。任何阶段的即时 `abnormal`／`rescue` 输入仍立即停止，不等待后续快照补齐，不把人工标记当故障实际起点。软件 C 正常不抹去画面异常或救援。

出现异常、缺端点、无正休眠、配对错误、身份／模式不一致或超时，不补睡眠、不启动日常 App、不强退 owner／helper、不清责。仅收束本工具创建的读回、只读电源观察器及请求进程；清理失败也不得报告信息充分。现场已明确的用户安全交接独立执行，不能为采集延迟救援。

## 离线验证与尚未验证

本轮重新通过 33 项 Dg1、20 项时钟及 7 项挂起工具自检，均为纯合成／mock；Dg1 白名单反例同时拒绝新增的记录结清命令。专用记录路径及相关 Core 存储／记录回归另有定向 Swift 测试与新 Release 构建；此前 5 项采集器测试结果保留，未将其当成本轮重测。

此前只读前检证据在 `.local/verification/dg1-readonly-preflight-20261102-ud71eot0/`：当时 C／原模式及双屏实际画面正常，但两份旧布局责任未结清，默认日常两类记录不存在。后续日常状态已变化，不能沿用当时的空目录结论。旧记录的[专用结清路径](internal-display-recovery-closeout.md)已实现并获单次授权尝试，但失败停止；不能直接调用现有恢复命令代替或补轮。

未运行 Dg1 物理路径或完整 Swift 测试集，未取得 Dg1 执行授权；新的只读及日常退出证据见下文，不能替代诊断或恢复验收。同 boot 历史事务、隐式重配和未捕获干扰仍未排除。任务 1.5、1.3、3.1／3.3和第 4 组保持未完成。

后续授权收尾已更新：[首次结清尝试与停止结果](internal-display-recovery-closeout.md#首次授权尝试与停止结果)。日常 App 经一次正常退出恢复并终验，用户确认实际画面正常；另获授权的旧记录专用结清单次尝试失败，双方原件未变，候选停止且不可重试。Dg1 未执行、额度未消费，旧责任门槛仍未满足；上述准备阶段的“未运行”不应解释为该结清候选仍可领取首次尝试。

## 2026-11-06 结清后的新候选与只读前检

最新准备包为 `.local/verification/dg1-prepared-20261106-v5/`，重新构建当前 Release probe，冻结工具、源码副本、摘要及未授权模板；33项Dg1、20项时钟、7项挂起自检通过。与v4相比，执行器仅增加静态prepare创建缺失父目录，运行逻辑未变；五份时钟／休眠／系统电源源码及校准脚本摘要相同，当前原生／Swift时钟夹取校验通过，不复用旧休眠样本。所有可见准备包的预算标记重新核对均未消费。

首次只读检查因用户当前已运行新版App而停止；独立计数确认1个App。随后通过已安装新CLI成功取得真实跨进程status回复，保护失败状态仍保留，未发送模式命令。一次性前检读取安装元数据时误用了要求私有父目录的时钟读取器，已修正该元数据读取方式，保留失败记录；生产门槛及执行器未更改。

最终只读检查1.195秒通过：绑定已安装App映像，除该App外没有意外控制进程；三类记录均符合结清门槛且字节未变；双读完整C稳定、内屏为主屏、与获准结清C一致，同boot内屏身份匹配。睡眠阻止条件检查通过。用户本轮确认开盖、已解锁、双屏画面正常可操作。证据在 `preflight-running-app-verified/report.json`，这不是执行就绪或睡眠授权。

执行前仍须另获一次正常退出App与一次普通睡眠的明确授权；App退出后必须重新核验无控制进程、当前C／模式／身份、日常及旧责任、睡眠阻止条件与校准环境，任何不符即停止。本次计划由用户用键鼠唤醒；异常即停止采集、交由用户接管，必要时用户断开外屏恢复内屏使用。该交接范围须随授权确认，工具不自动拔线、切换显示、清锁或重启。`approval-summary.json` 保持 approved=false，未生成已授权现场输入，未调用 run。任务1.5尚未完成，进度仍7/15。

## 2026-11-06 授权单轮执行与证据不足收尾

用户明确授权一次正常退出、退出后复核、最多一次普通睡眠及异常由用户接管。绑定当前App映像后持久记录唯一退出尝试，发送一次正常SIGTERM（App映射至正常退出恢复生命周期），退出成功，无强退。退出后0.416秒只读复核通过，三类记录已结清、字节未变、内屏主屏C及身份稳定，无控制进程，睡眠阻止检查通过。

从正常退出请求前开始另设180秒连续时钟外层截止；随后由冻结v5的run入口领取候选额度。睡前检查点使用用户本轮已明确的开盖解锁双屏正常观察；只请求一次sleepnow，未新增控制会话或显示操作。醒后四份总快照均匹配C，执行器到达after人工确认检查点，但在聊天确认能够送入前触发唤醒后采集截止，stopReason=collection-deadline、informationSufficient=false、physicalObservation=unknown，观察器清理完成；保留原始result不回填或改判。

用户随后报告“正常”，并补充看到熄屏就立即唤醒。该人工观察独立保存在post-stop-observation.json，明确发生在采集停止后。保存的一组合法电源配对通知跨度约2.015629秒，但配对时钟的实际休眠界为[0,419]纳秒，不能证明正休眠；通知跨度不是实际休眠时长。缺少after-clock完整夹取，不能给出完整Dg1测量通过。快速唤醒可能影响入睡，本轮没有足够依据确认这一因果；此前引导未明确区分熄屏与真正休眠。

独立收尾见independent-post-stop-summary.json：三类记录字节保持且restored，四份已保存C快照一致，冻结绑定未变，无控制进程，观察器已清理；一次退出、一次睡眠、无补轮、无新显示会话。原预算、result及证据均保留。用户实际画面正常与诊断信息不足分别报告，不将期限拒绝认作画面故障。任务1.5所需正休眠及完整证据未满足，仍不勾选，1.3根因未知，进度7/15。不得复用v5或自动增加睡眠；若继续，需先解决熄屏／入睡引导及短窗口人工观察交付问题，再按原范围重新审查具体候选与授权。

## 2026-11-06 采集顺序修复与本机确认

已用离线反例复现：旧顺序先等人工确认，确认超时会跳过结束时钟和电源测量；新顺序先保存机器证据及machine-measurement回执，再询问画面。确认迟到仍为collection-deadline、informationSufficient=false，不能因机器数据完整宣称画面正常。非法配对提前停止时没有取得人工观察，明确保留unknown；即时异常／救援继续中断，清理及正休眠规则不变。

用户明确选择本机弹窗。新模板confirmationMethod为local-dialog，旧输入缺省terminal；运行清单只接受这两种值。固定AppleScript通过本机osascript呈现三种选择，无自由文本或通用命令，默认键不是正常。子进程纳入原清理集合，等待期间继续执行原时钟／进程／责任检查，弹窗时限不超过剩余窗口，迟到正常及未知输出均拒绝。醒后不用等待聊天转发。显示熄灭只说明屏幕状态，不代表已休眠；不能看到熄屏就立即唤醒，具体唤醒安排须在下轮授权前说明，睡眠结论仍由同轮时钟给出。

38项Dg1、20项时钟、7项挂起回归通过；新增反例覆盖机器证据先落盘、人工超时不通过、弹窗四种结果、未知输出、错误退出、迟到正常及等待期间即时异常。AppleScript静态编译通过，未展示真实弹窗、未执行新睡眠。仅更新Python诊断工具与文档，无Native代码变更；旧v5证据、授权及消费标记保持。新准备包v6仅静态准备，未授权、未执行、不以新目录重置v5额度；下一次现场须重新核对候选和单轮授权。1.5仍缺正休眠完整证据，进度7/15。

### v6弹窗实测及最新只读现场检查

本机弹窗已实测：受限执行环境中返回cancel，隔离诊断确认macOS错误-1713（errAENoUserInteraction）；桌面交互获准环境中返回normal，耗时4.343秒。错误诊断仅替换错误分支为错误编号，成功分支与冻结弹窗相同。此为按钮回传验证，不是Dg1现场画面验收，不证明睡醒后10秒窗口内完整采集能通过。运行必须具备桌面交互能力，睡前弹窗不可用则停止，不能将取消当成正常。

v6只读预检发现运行中的已安装App；内核路径及制品绑定通过，但记录检查停止。当前AI status返回“外屏主屏已生效”，daily为owned、layoutPending=true、sourceUnresolved=false，无internalDisplay/externalDisplay禁用记录；old-1/old-2仍restored。正常退出将触发布局恢复，须取得该动作授权后重新预检，不能复用上轮已退出状态。此次未退出App、未睡眠、未显示写入；v6消费额度未使用。实测回执与停止报告位于.local/verification/dg1-prepared-20261106-v6/。

### v6已授权正常退出与退出后预检

用户单独授权一次正常退出、恢复接管前布局及只读预检，未授权睡眠。重新核对内核进程路径、制品摘要、daily稳定owned且仅布局责任、基线及历史记录后，发送一次SIGTERM，由已安装App的正常退出生命周期处理；0.776秒完成，未强制终止。daily变为restored，session/generation/applied/baseline保留，历史记录及内屏记录不变，无控制进程残留。

退出后只读预检1.169秒通过：三类记录就绪，连续两次双屏快照相同、内屏主屏、匹配既定C，内屏硬件身份及同启动会话核验通过，未检测到系统睡眠阻止项；记录在预检前后不变。证据：v6/authorized-normal-exit-result.json与v6/post-exit-preflight/report.json。新field.proposed.json仍approved=false，lidOpenAndUnlocked=false、calibrationApplicable=false；软件快照不替代用户实际画面确认。v6睡眠额度未使用，未发起睡眠、未清锁或启动App。1.5保持未完成，进度7/15。

### v6单轮执行与外屏早期缺失

本轮用户授权一次普通睡眠、异常停止不重试；现场准备弹窗明确开盖解锁双屏正常、熄屏后约15秒键鼠唤醒及用户救援交接，用户确认ready，冻结入口睡前确认normal。准备入口首次在读取公开校准元数据时因私有权限读取器不适用停止，未领取预算或执行现场动作；修正为公开元数据读取并逐项比对冻结时钟源码、脚本和probe后，前检通过，正式run仅执行一次。

睡前两次双屏C正常；消费sleep一次。唯一合法电源配对跨度26.747081083秒，观察器自身continuous/awake夹取计算休眠区间[18.774934790,18.774935085]秒。唤醒后0.343219秒首次拓扑快照为内屏在线活动、外屏未出现，立即以incomplete-C停止，未执行第四次快照或补轮。完整原生／Swift结束夹取尚未采集，因此这个正区间不能替代完整CLOCK.compare，informationSufficient保持false，hardwareAcceptance=false，ownerCausality=unknown。

收尾只读快照恢复双屏在线活动；用户在停止后本机弹窗确认normal。三个责任记录摘要不变，无控制进程，观察器清理完成，无新增停用或显示写入。不能把停止后正常改写成轮内通过，也不能从一次采样确定外屏缺失持续多久，或认定是谁造成的。证据在v6/result.json、suspension.json、offline-timing-analysis.json、post-stop-readback.json和post-stop-physical-observation.json。

离线反例进一步定位到采集器顺序缺陷：醒后拓扑拒绝在结束时钟之前发生，导致关键停止路径丢失完整机器测量。已将结束时钟／停止观察器／机器测量保存前移至醒后拓扑检查之前；缺外屏仍立即拒绝，未增加轮询、放宽完整C或延长截止。新增反例在旧代码失败，新代码及39项Dg1、20项时钟、7项挂起测试全部通过（66项）。仅修改工作区工具，冻结v6及已消费回执不变；未准备或执行新现场候选。核心原因未证明，1.3仍阻断；1.5仍缺完整时钟对照，7/15不变。

### 外屏短暂缺失的离线恢复路径核对

本轮只检查源码及合成回归，没有现场动作。针对v6见到的“内屏正常、外屏短暂不在活动集合”形状，增加testTransientMissingExternalRetainsRecordUntilExactCReturnsWithoutDisplayWrites：以已确认C且无待执行写入的保护记录模拟外屏缺失，recoverGuardRecord抛unresolvedSource、记录字节不变、没有enable或origins调用；同一原始C返回后，恢复核验成功且仍无显示写入。42项GuardRecoveryTests及InternalSessionLifecycleTests通过。此为合成状态路径证明，不是v6存在owner的证明，也不证明历史黑屏根因。

源码路径为DisplayGuard.didWake→recoverAfterWake→pauseForConfiguration→recoverGuardRecord→RecoveryRecord.layoutRestorePlan。无layoutPending且current不等于baseline时，layoutRestorePlan抛unresolvedSource；internalWakeVerificationRetryDelay只接纳unstable/internalStateChanged，故该错误没有醒后就绪等待机会，pauseForConfiguration最终loseProtection并stop。后续外屏回到C不能撤回已锁存故障。现有拒绝保留了写入安全，但将暂时不完整的可见集合与不可接受的来源变化合并处理。

待确认的最小修复方向：在任何恢复写入之前，单列严格受限的只读拓扑就绪检查。仅已证明内屏启用、原记录无布局／内屏待写且无来源未决、缺失的只是已绑定外屏时允许等待；不在缺屏状态确认C、清责、清锁或再次停用，不延长原十秒预算。完整原C与身份／模式重新独立核验后才回到既有恢复流程；未知身份、坐标变化、责任变化、保护丢失及超时仍拒绝。此方向需要先修订现有设计中的分类和准入约束，尚未修改生产恢复代码或授权新现场测试。

### 已批准的只读就绪候选完成

用户确认design 2d方向后，已在主控自动醒后路径接入InternalWakeTopologyReadiness。其依据来自与记录绑定的已确认完整C；无待写责任且内屏独立启用证明和完整DisplayState不变时，仅缺绑定外屏可在原十秒预算内只读等待。完整原C返回后继续原恢复核验；模式、坐标、身份、记录变化和过期均拒绝。不扩展辅助／重启恢复入口，不清锁、不接纳子集，不增加现场额度。

75项GuardRecoveryTests、InternalSessionLifecycleTests、SnapshotWitnessTests通过，Release构建成功，严格规划校验通过。候选源码及二进制摘要、构建和测试日志保存在.local/verification/wake-topology-candidate-20261106/manifest.json及同目录日志。任务1.3按已确认范围完成，进度8/15；完整恢复现场及硬件准入未验，当前安装包未替换。下一步需冻结此候选的有限验收及单独现场授权，不能直接沿用v6或历史睡眠额度。
