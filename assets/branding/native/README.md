# Extilume 原生图标源层

状态：已完成可编辑 `.icon` 源资产、macOS 27 六种外观渲染和 Xcode 编译；未接入或安装应用。

三个 SVG 均为 1024×1024 的可编辑几何，保留 v1 的单一外屏与收束光形，去除烘焙圆角底板、阴影及高光。v1 PNG 和 prompt 未改动。

- `layers/screen.svg`：蓝色屏面。
- `layers/focus-light.svg`：屏内收束光形。
- `layers/monitor-body.svg`：显示器边框及支架。
- `source-preview.html`：三层合成的静态源几何预览，含 64/32 CSS 像素视图；不代表系统渲染或已验收。

`../Extilume.icon` 先由 Icon Composer 新建、导入 SVG 并保存，再依据实际保存的结构补齐三层；最终在原生应用重新打开及保存，确认 `3 layers in 1 group`。源层副本保存在包内 `Assets/`，修改外部 SVG 后需重新导入，二者不会自动同步。

使用 Icon Composer 打开 `../Extilume.icon` 继续编辑。背景、材质、阴影及系统蒙版由原生文档管理，不包含 v1 的整张栅格图。`.icon` 是源文档，不是传统 `.icns` 的改名，也不是已安装的应用图标。

`index.html` 展示最终预览。`previews/` 包含 Default、Dark、ClearLight、ClearDark、TintedLight、TintedDark 各 1024、64、32 像素，共 18 张 PNG，均由 Apple `ictool 27.0 (129)` 实际渲染，不是缩放 1024 图片得到。已逐张视觉检查：显示器与光形可辨、Clear 轮廓完整；TintedDark 默认紫色偏暗，32 像素细节较弱。未验证所有 tint 色、动态壁纸及安装后的系统表现。

从仓库根目录重现单张导出（其余外观替换 `Default`；小尺寸同时替换 width、height 和文件名）：

```sh
icon_tool='/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'
"$icon_tool" "$PWD/assets/branding/Extilume.icon" \
  --export-image --output-file "$PWD/assets/branding/native/previews/Default-1024.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 \
  --scale 1 --design-generation 27
```

本次 CLI 在受限沙箱内报 `The file “Extilume.icon” couldn’t be opened.`；同一原生工具经批准在沙箱外运行成功，未改系统设置。`verification.json` 记录所有渲染退出码与尺寸、RGBA、四角透明度检查。

Xcode 27.0（27A266a）的 `actool` 已针对 `macosx`、`mac`、最低部署版本 `27.0` 成功编译同一 `.icon`，退出码为 0，生成 `Assets.car`、`Extilume.icns` 和包含 `CFBundleIconFile` / `CFBundleIconName` 的 plist。编译生成的 [Extilume.icns](Extilume.icns) 已保存在此目录，容器头和长度校验通过；`Assets.car` 和 plist 仅留在临时编译目录。

继续编辑及接入 Xcode 时使用 [Extilume.icon](../Extilume.icon) 分层源文件；`.icns` 是本次编译导出物。已完成的原生渲染和编译检查不替代应用集成或运行验收。
