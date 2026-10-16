# Extilume

Extilume 是一个开发中的 macOS 菜单栏显示器工具，第一阶段提供“外接屏设为主显示器”，并在退出时撤销本应用负责的显示配置改动。

当前仓库包含[菜单栏应用](docs/menu-bar-primary.md)、[图标资产](assets/branding/)、[分阶段 OpenSpec 提案](openspec/changes/)和[默认只读的本机显示验证入口](docs/local-display-verification.md)。菜单栏应用的限定硬件生命周期、显式保留用户配置及退出恢复已通过本机验证；11 种注入状态菜单的桌面呈现、键盘访问与已生效入口的实际旁白名称均已核对，本机验收 18/18 完成，可在已验收的 HDMI 直连、开盖双屏非镜像配置下日常使用，详见[本机验收矩阵](docs/menu-bar-primary-acceptance.md)。内屏停用属于后续独立阶段。开发过程日志和逐次实验记录保留在本地，不纳入 Git。

## License

本项目采用 [MIT License](LICENSE)，版权署名为 `Zed`。

除另有声明外，许可覆盖项目自有的代码、辅助进程、测试、配置、文档（包括 OpenSpec 提案）和图标资产；后续新增的自有项目文件默认沿用 MIT。第三方代码、素材和依赖保留各自的许可证。
