# App证据汇总与准入结论（2026-10-25）

**主体任务：23/23完成；日用准入：No-Go，未通过。** 原App账本23/24中的5.5已完整迁入[独立恢复提案4.4](../openspec/changes/fix-internal-display-recovery/tasks.md#4-真实画面与恢复准入)，保留原ID及未验证结论，不计为通过。主体实现18/18、5.1菜单呈现／交互、5.2、5.3、5.4功能覆盖及5.6汇总／核对已闭合；独立提案当前0/13，发布仍须联合验收及恢复必需证据合格。

## 5.1完整菜单呈现与交互（2026-10-25）

按用户批准的证据分层，隔离Release host直接使用冻结产品的菜单delegate及动作守卫；真实展开AppKit菜单，由外部AX检查、局部截图与真实键盘／AX输入验收。控制器和退出、退出回复、打开设置的副作用全部为记录器，没有取得产品控制租约或调用显示入口。

- 44个唯一场景全部通过：覆盖两种模式的全部状态枚举、恢复／确认／退出忙碌及完成状态、未选择、已记忆但待显式激活、模式与迟到状态不匹配。每个场景都有实际外部AX及裁剪截图，检查完整文案、勾号、权限及隐藏项不可达。
- 15组启用动作映射均核对精确单次命令及参数，包含方向键选择、Return激活、Escape取消和AXPress。四个新增禁用项代表实际尝试后，经主队列排空确认没有新增调用；继承的已通过场景另有共享守卫证据。全部状态仍逐项检查AX禁用属性；未把原70次禁用项压力计划宣称为已执行。
- 产品入口和真实偏好路径另用下文首次／升级输入投影、记忆重启，以及当前包的[真实状态栏入口](../.local/verification/internal-app-prepared-replacement-xvm23w5b/native-ui-result.json)。[来源适用性核对](../.local/verification/app-menu-acceptance-basis-tbtondn2/basis.private.json)绑定50个产品源码输入；旧启动UI与当前UI的差别仅为applying忙碌短路，不影响复用的首次／升级非忙碌分支。升级结论仍限无新模式键的输入投影，不扩称完整安装或旧责任迁移。

44项来自明确记录的多段续验，非同一host或一次连续轮次；已通过前缀不重复。中途自动化展开失败均保留；其中一次90秒键鼠窗口实际131.4秒才停止，记录为测试调度超时，不算产品失败或达标用时。用户明确延长后，最后6项完成。[最终聚合](../.local/verification/menu-presentation-c8q3usaj/matrix-result.json)、[独立44项核对](../.local/verification/menu-presentation-c8q3usaj/parent-independent-ui-audit.json)、[窗口超时记录](../.local/verification/menu-presentation-raqgmnbt/window-expired.json)。

host采用regular激活策略、测试Bundle、enable-testing和专用TEST按钮，不代替产品accessory入口、系统全局菜单快捷键或VoiceOver验收。受控状态只证明收到状态后的UI呈现／命令，不证明真实后端产生故障、恢复或时限；原5.5迁入独立恢复提案4.4后仍未验证。[构建及差异绑定](../.local/verification/menu-presentation-c8q3usaj/binding.json)。父代理另核对当前仅外屏App三进程、50项源码及责任记录保持原样，全部测试host已退出：[会话后检](../.local/verification/menu-presentation-c8q3usaj/parent-user-session-check.json)。

## 候选与范围

三类收尾来自不同受控轮次，资源另取一个无切屏观测窗口，不拼称同一轮。三轮manifest及采样进程映像UUID均核对到实际运行的同一旧冻结dist-dev包。没有为了补报告重新停用、睡眠、拔线或注入故障。

新隔离候选把Only暂停态“排列已确认，可停用内屏”改为“双屏已恢复，可调整或确认排列”，并同步一条现有测试断言；20项现有菜单测试和Release通过。该包已完成下述启动菜单及单次暂停实测，现另开临时使用会话，没有覆盖dist-dev或日常dist包。本表资源数值不是新包实测。[现场包绑定](../.local/verification/internal-app-menu-wording-kak7oi35/candidate-manifest.json)。

## 真实菜单切片

前一用户会话的Only生效态AX名称及帮助包含模式和生效状态，外屏主屏无勾、Only有勾，两项可用。菜单实际展开后下／下／上导航，再Escape收起，未按Return或触发动作；独立后检仍仅原外屏活动、内屏硬件匹配且停用，原App／owner／helper及责任有效。

这份旧包菜单记录仅覆盖applied态，不是全部状态验收。[菜单记录](../.local/verification/internal-app-menu-a11y-20261025-ax/observations.txt)、[独立后检](../.local/verification/internal-app-resources-i07z6lxw/post-menu-readback.json)。

### 新隔离包：无显示控制的启动及实际交互

前一App已正常退出、原责任已清；现场为合盖、仅物理外屏活动。此次不要求开盖，不选用模式控制显示。只暂移开发域模式键以进入无选择分支；原偏好有受限备份，最终仍保留用户的Only选择，日常域未写入。两个实际GUI会话使用同一新隔离包，源文件和可执行映像均按manifest核对。

| 覆盖 | 真实结果 | 证据 |
| --- | --- | --- |
| 无模式键的首次选择入口 | 显示“请选择显示模式”；两模式启用、均无勾，既有故障锁保持 | [首次菜单及交互](../.local/verification/internal-app-startup-menu-rv24o_cd/first-selection/ui-result.json) |
| 固定主屏旧版的偏好升级分支 | 只读核对旧固定版域无新模式键；新包实际无键启动呈现未选择。代码只读取explicitDisplayMode.v1，因此可复用该输入投影；不宣称旧责任记录迁移、完整安装升级或干净首次安装全流程通过 | [输入与执行范围](../.local/verification/internal-app-startup-menu-rv24o_cd/execution-plan.json)、[独立结论](../.local/verification/internal-app-startup-menu-rv24o_cd/result.json) |
| 键盘激活及保护拒绝 | 方向键选中精确Only并核对AXSelected后，Return一次；真实显示保护失效拒绝，两模式仍无勾，保存Only意图，无owner/helper；不是恢复失败状态 | [键盘动作](../.local/verification/internal-app-startup-menu-rv24o_cd/first-selection/keyboard-activation.txt)、[拒绝菜单](../.local/verification/internal-app-startup-menu-rv24o_cd/first-selection/refused-menu-ax.txt) |
| 辅助功能实际操作 | 对精确“退出并恢复”执行AXPress一次，App正常退出，零产品进程、故障锁保留；不只检查AX元数据 | [AX操作](../.local/verification/internal-app-startup-menu-rv24o_cd/first-selection/quit-ax-result.txt) |
| 记忆重启及显式激活等待 | 第二会话显示“已选择仅外屏，等待点击模式应用”，两模式启用、均无勾；AX名称及帮助同义。真实展开273×176，Escape后按钮未选中、菜单0×0；未激活模式，App留给用户使用 | [记忆启动菜单](../.local/verification/internal-app-use-ui-v3qd8gwk/remembered-menu-result.json) |

父代理独立后检：两个启动前后完整显示快照相等，无新责任记录；结束时只有新包GUI，没有owner/helper。第二会话沿用用户既有临时开发使用例外，人工暂移故障键，App实际退出后由父包装重新锁存；这不是产品菜单自行清故障。初次准备漏建显式state目录，包在进入GUI前exit1，原失败和修正记录均保留，未计作成功启动。[最终独立结论](../.local/verification/internal-app-startup-menu-rv24o_cd/result.json)。

本启动轮结束时5.1尚未完整验收：它没有覆盖其余状态／权限，已选模式等待点击不能替代缺屏等待，保护锁拒绝不能替代恢复失败。随后按获批的证据分层，以本报告开头的44项真实展开菜单补齐呈现与UI命令映射；对象状态断言仍不替代外部观测，真实后端联合验收由原App5.5迁入独立恢复提案4.4。未配置或测试VoiceOver，系统全局键盘打开菜单的限定自动验证未取得成功证据。

用户限定后续仅推进App主体。对正在使用的Only会话另做不切屏键盘入口检查：系统相关快捷键已启用，初次注入及有限导航未确认目标焦点；唯一纠正使用已有投递权限，发送前断言精确F8及Control／SecondaryFn标志，发送后全局AX焦点返回-25212，遂立即Escape，无后续导航或命令。没有更改快捷键、申请权限、点击模式或退出。父代理核对三进程和责任记录逐字节不变，Only继续使用；不能据此判断产品失败或补勾5.1。[限定纠正结果](../.local/verification/internal-app-keyboard-entry-bbh2ajvn/exact-correction-summary.json)、[独立会话核对](../.local/verification/internal-app-keyboard-entry-bbh2ajvn/parent-checks.json)。

### 新隔离包：单次仅外屏、暂停与退出

用户明确开始验收并要求代理自行操作。只读前检确认开盖、内屏主屏双屏活动、冻结包及源码一致、没有待恢复责任。代理对精确Only、恢复双屏调整、退出三个菜单项各执行一次AXPress，均先保存单次动作凭据；没有第二次停用、C修改、睡眠、拔线或故障注入。

- Only菜单实际展开262×200，Only有勾、主屏无勾，AX名称／帮助为已生效；父代理另核对内屏inactive且硬件匹配、原外屏独占、同包GUI／owner／helper及owned责任。用户回复仅外屏正常。该回复到达恢复任务调度后，仅归属此前Only画面，不作为恢复后或十秒计时证据。
- 恢复后的暂停菜单实际展开260×224，标题及AX名称／帮助均为“双屏已恢复，可调整或确认排列”，两模式无勾；“应用仅外屏”和“设为恢复布局”启用，恢复入口消失。没有点击应用或确认按钮。
- 正常退出后，父代理按显示身份映射逐字段核对完整原快照及全部模式、内屏硬件活动、零产品进程和零责任记录，包装门禁重新锁存。用户在任何App重开前确认双屏正常，随后另开原现场包供使用，等待显式激活，不再切屏。

Only期间像素尺寸及刷新率相同，但ioDisplayModeID与双屏前不同，初次完整模式比较失败已原样保留；未把临时差异豁免成完整模式通过。恢复退出后含该编号在内的全部原模式字段一致，最终原模式核验通过。[模式观察](../.local/verification/internal-app-paused-menu-077549vv/stage1-mode-observation.json)、[最终独立核对](../.local/verification/internal-app-paused-menu-077549vv/final-checks.json)。

实测发现一个瞬时提示缺陷：恢复的.applying回调提前清除UI忙碌标记，曾在收起的AX对象中显示“正在停用内屏…”。该收起对象及旧AX缓存不计作可见忙碌态通过。已在共享receive路径最小修正，中间态保留恢复／确认及待退出意图，终态才收束；四个既有菜单用例先失败再通过，现有20项菜单测试全部通过。未改控制器或显示事务；隔离Release通过，[修复候选绑定](../.local/verification/internal-app-busy-status-wym9hpze/candidate-manifest.json)与现场包分别保存，未替换用户现场包，修复后的忙碌态仍未实机呈现。

[单轮结论](../.local/verification/internal-app-paused-menu-077549vv/result.json)、[Only真实菜单](../.local/verification/internal-app-paused-menu-077549vv/stage1-ui-result.json)、[暂停／退出真实菜单](../.local/verification/internal-app-paused-menu-077549vv/stage2-ui-result.json)。本节补齐5.1暂停态切片，不补勾全部5.1或5.5，不改睡眠画面历史及No-Go结论。

此后用户明确授权实际使用包切换。旧包正常退出并完整恢复最新C／所有模式，旧主辅及责任收束后才启动修复包，重新Only一次；父代理核对原外屏、内屏硬件、共同C及新包保护三进程，用户确认仅外屏正常。修复包现已实际使用，旧包保留，没有覆盖旧现场证据或日常dist文件；新忙碌提示仍未重新触发，不因运行包更新补勾验收。[运行包切换结果](../.local/verification/internal-app-prepared-replacement-xvm23w5b/replacement-result.json)。

## 资源观测

实际时长 60.001433 秒，13样本，间隔5秒。内存为MiB；CPU是ps百分比快照范围，不是区间平均，显示0.0%不等于零CPU。场景为采样时的用户Only会话，未隔离后台负载，不是纯空闲基准；临时使用父进程和防睡眠进程不计入三个产品角色。

| 角色 | RSS MiB | 物理footprint MiB | ps CPU %范围 | package-idle增量／次每秒 | interrupt增量／次每秒 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 菜单App | 78.62–78.69 | 23.31–23.41 | 0.0–0.0 | 0／0.0000 | 4／0.0667 |
| 会话owner | 14.45–14.45 | 5.70–5.70 | 0.0–0.0 | 0／0.0000 | 0／0.0000 |
| 独立helper | 38.42–38.52 | 10.33–10.42 | 0.0–0.0 | 0／0.0000 | 4／0.0667 |

内存和两类计数按本机SDK的libproc RUSAGE_INFO_V0读取。两类唤醒分别报告，不相加冒充全部唤醒；package-idle零增量不证明没有定时器。字段映射见[Apple XNU fill_task_rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)。逐样本核对映像和启动身份，前后进程树与责任一致；不据此推断长期稳定性、驱动内存清理或全部故障资源合格。

[资源摘要](../.local/verification/internal-app-resources-i07z6lxw/summary.json)、[实际包绑定](../.local/verification/internal-app-resources-i07z6lxw/binding.json)。

## 三类收尾映射

| 类别 | 实际观察及责任 | 证据 |
| --- | --- | --- |
| 正常退出 | 手动C轮最后从主屏模式一次正常退出，完整新C／模式恢复，主屏记录restored、无pending／unresolved，内部记录收束，零控制进程；用户在重启前确认新C正常 | [结果](../.local/verification/internal-app-manual-c-fak2o9y1/result.json)、[退出观测](../.local/verification/internal-app-manual-c-fak2o9y1/final-quit-observation.json) |
| 模式切回 | 同轮Only切主屏，准确平移且新C仍为恢复目标；旧owner／helper和内部责任结束，菜单App接续主屏责任，并非提前清掉全部责任 | [主屏责任](../.local/verification/internal-app-manual-c-fak2o9y1/cross-mode-primary-record.private.json)、[汇总](../.local/verification/internal-app-manual-c-fak2o9y1/cross-mode-summary.json) |
| 已观察异常恢复 | 直接退出轮在恢复启用期间实际负向事件触发持久故障；原owner／helper恢复并终验，同一次退出最多一次只读收尾，完整C／模式、记录、零进程及用户确认均取得 | [结果](../.local/verification/internal-app-exit-retest-quysl3rf/result.json)、[观测](../.local/verification/internal-app-exit-retest-quysl3rf/quit-observation.json) |

异常行仅证明“退出中实际负向事件”分支，不替代崩溃、辅助失效、拔线、在途、睡眠矩阵；2.748秒／0.645秒等软件进程观测不证明实际故障至人工可交互十秒。历史跨模式轮的延迟终态复核，依[原记录](../.local/verification/internal-app-mode-switch-r6h5hk53/result.json)双日期边界解释。

## 未决责任与准入

原验证保持No-Go归档，34/38，5.3失败及5.4／5.5／5.14未验不改判。恢复专项现为0/13，其中新增4.4承接App原5.5的联合验收，保持未验证。App主体按23/23收尾不连带勾恢复专项、不宣布日用、不授权安装替换或提交发布。

两份明确保留的D2旧准备记录均owned、layoutPending=true、sourceUnresolved=false，无内屏责任；本次只读，未删除、覆盖、迁移或重放：

- .local/verification/d2-prepared-9xe04zcy/primary-preparation-state/recovery-record.json
- .local/verification/d2-prepared-9xe04zcy/c1-primary-preparation-state/recovery-record.json

它们不与当前用户会话混称已清理。完整准入等待独立恢复提案及其4.4联合验收，并核对已完成App证据的候选适用性。
