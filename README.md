# Extilume

Extilume 是一个 macOS 菜单栏显示器工具，提供“外屏主屏”和“仅外屏（停用内屏）”两种模式，并在切回或退出时恢复本应用负责的显示配置。

当前准备版本为 **0.1.0-beta.1**，见[beta说明](docs/releases/0.1.0-beta.1.md)。仅外屏已完成本机基础功能及App主体验收，正式日用准入仍保留独立联合验收门槛；外屏主屏的既有验收见[本机矩阵](docs/menu-bar-primary-acceptance.md)。

仓库包含[双模式App说明](docs/internal-display-app.md)、[图标资产](assets/branding/)、[OpenSpec规格](openspec/specs/)和[默认只读的本机验证入口](docs/local-display-verification.md)。开发过程日志和逐次实验记录保留在本地，不纳入Git。

## License

本项目采用 [MIT License](LICENSE)，版权署名为 `Zed`。

除另有声明外，许可覆盖项目自有的代码、辅助进程、测试、配置、文档（包括 OpenSpec 提案）和图标资产；后续新增的自有项目文件默认沿用 MIT。第三方代码、素材和依赖保留各自的许可证。
