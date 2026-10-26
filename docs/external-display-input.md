# 外接屏 DDC 输入源能力

此模块只处理标准 DDC/CI VCP `0x60`。它读取能力字符串中显示器明确列出的输入码；切换时在同一截止时间内重新读能力、发送一次输入命令并读回当前码。能力缺失、目标变化、输入码不受支持、传输超时或读回失联都会失败关闭，不会重试输入写入，也不会据此声称 PC 画面已显示。

目标绑定使用 `ExternalDisplayIdentity` 的显示 UUID、EDID UUID、IORegistry 路径、启动会话和 registry entry ID。原生传输在调用前再次核对当前启动会话、路径、EDID 和 registry entry，并要求唯一的外接 `DCPAVServiceProxy` 映射到该目标。数值显示 ID 不参与 DDC 选屏。

## 调用边界

`ExternalDisplayInputController` 默认没有硬件验证目标，因此 `availability(for:)` 返回 `hardwareAcceptanceRequired`，`sendOnce` 会拒绝发送。只有主流程在计划中的硬件验收完成后，按同一份物理身份创建带验证绑定的 controller 才能开放写入。`ExternalDisplayInputConfiguration.automaticEnabled` 默认为 `false`；读取能力不会自动打开该开关。

私有 DDC 调用在独立子进程执行。主应用和 probe 的启动分派器已在普通菜单启动前调用 `runExternalDisplayInputProbeIfRequested()`，以处理 `--external-display-input` 子进程请求。controller 的默认探针使用现有 `freshWitness` 和截止时间；如果子进程没有被分派，读回会失败并保持输入写入门关闭。

## 传输和限制

Apple Silicon 原生传输在运行时解析 IOKit 导出的 `IOAVServiceCreateWithService`、`IOAVServiceReadI2C` 和 `IOAVServiceWriteI2C`，并将 DDC 服务绑定到目标的 IORegistry 项。它只实现标准地址和 VCP `0x60`，不实现亮度、音量、厂商扩展或 Intel 传输。IOAVService 是无公开头文件的私有 SPI；符号缺失、服务不唯一、层级关联不符或显示器不响应时都报告不可用。

VCP `0x60` 支持及其输入值是显示器报告的能力，不证明所选输入就是用户的 PC 端口。即使输入码读回成功，也不能证明显示器实际输出 PC 画面；手动输入按钮仍是兜底。

实现前核对了 [m1ddc 源码](https://github.com/waydabber/m1ddc) 与其 [MIT 许可证](https://github.com/waydabber/m1ddc/blob/main/LICENSE)。这里只参考它公开记录的 Apple Silicon DDC/CI 能力与 `IOAVService` 接口，不复制其源文件或代码片段；本仓库未新增第三方代码声明。

本实现没有读取或写入当前物理显示器，也没有完成型号、端口或停用后的 DDC 通道硬件验收。自动能力保持关闭，直到独立实机验收完成。

## 设置与单次交接

离线候选包含“自动切到 PC”设置菜单，仅列出验收注入的能力值；当前真实连接未验收时只显示不可用原因，普通启动不开放新交接模式或自动控制。设置按物理 UUID、EDID 与 registry path 隔离，开关默认关闭；输入号必须由用户确认对应实际 PC 端口。

显式进入时先核对能力与目标，成功停用外屏后才发送一次 PC 输入命令。DDC 失败不回滚已完成的仅内屏布局，显示独立的输入码未确认结果，并提示使用显示器实体按钮。连接回调、唤醒、崩溃后重启及恢复动作均不发送 PC 输入命令；恢复 Mac 配置后仍须手动切回 Mac 输入。

DDC/CI 回复校验包含隐含的主机地址 `0x50`；此协议约定另与 [ddcutil 的包校验实现](https://github.com/rockowitz/ddcutil/blob/master/src/base/ddc_packets.c)交叉核对。仅核对协议事实，未复制其源代码。
