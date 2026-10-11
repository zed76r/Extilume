# Extilume

Extilume 是一个规划中的 macOS 菜单栏显示器工具，计划提供“外接屏设为主显示器”和“仅使用外接屏”两种模式，并在退出时撤销本应用的显示配置改动。

当前仓库包含[图标资产](assets/branding/)、[分阶段 OpenSpec 提案](openspec/changes/)和[本机显示验证入口](docs/local-display-verification.md)。验证入口默认只读，主屏路径的自动连接／唤醒生命周期尚待实机验收；日常应用与内屏停用尚未完成。开发过程日志和逐次实验记录保留在本地，不纳入 Git。

## License

本项目采用 [MIT License](LICENSE)，版权署名为 `Zed`。

除另有声明外，许可覆盖项目自有的代码、辅助进程、测试、配置、文档（包括 OpenSpec 提案）和图标资产；后续新增的自有项目文件默认沿用 MIT。第三方代码、素材和依赖保留各自的许可证。
