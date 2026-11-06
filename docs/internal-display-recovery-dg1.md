# Dg1 普通双屏 C 诊断准备

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

睡前／醒后各最多两次完整 C 读回，同时取得独立内屏证明；实际画面另由人工确认。终端仅在对应确认提示时接受 `normal`；任何阶段输入 `abnormal`／`rescue`／取消都停止，不等待后续快照补齐，不把人工标记当故障实际起点。软件 C 正常不抹去画面异常或救援。

出现异常、缺端点、无正休眠、配对错误、身份／模式不一致或超时，不补睡眠、不启动日常 App、不强退 owner／helper、不清责。仅收束本工具创建的读回、只读电源观察器及请求进程；清理失败也不得报告信息充分。现场已明确的用户安全交接独立执行，不能为采集延迟救援。

## 离线验证与尚未验证

本轮重新通过 33 项 Dg1、20 项时钟及 7 项挂起工具自检，均为纯合成／mock；Dg1 白名单反例同时拒绝新增的记录结清命令。专用记录路径及相关 Core 存储／记录回归另有定向 Swift 测试与新 Release 构建；此前 5 项采集器测试结果保留，未将其当成本轮重测。

此前只读前检证据在 `.local/verification/dg1-readonly-preflight-20261102-ud71eot0/`：当时 C／原模式及双屏实际画面正常，但两份旧布局责任未结清，默认日常两类记录不存在。后续日常状态已变化，不能沿用当时的空目录结论。旧记录的[专用结清路径](internal-display-recovery-closeout.md)已实现并获单次授权尝试，但失败停止；不能直接调用现有恢复命令代替或补轮。

未运行 Dg1 物理路径或完整 Swift 测试集，未取得 Dg1 执行授权；新的只读及日常退出证据见下文，不能替代诊断或恢复验收。同 boot 历史事务、隐式重配和未捕获干扰仍未排除。任务 1.5、1.3、3.1／3.3和第 4 组保持未完成。

后续授权收尾已更新：[首次结清尝试与停止结果](internal-display-recovery-closeout.md#首次授权尝试与停止结果)。日常 App 经一次正常退出恢复并终验，用户确认实际画面正常；另获授权的旧记录专用结清单次尝试失败，双方原件未变，候选停止且不可重试。Dg1 未执行、额度未消费，旧责任门槛仍未满足；上述准备阶段的“未运行”不应解释为该结清候选仍可领取首次尝试。
