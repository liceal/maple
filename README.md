<div align="center">

<!-- 点击海报跳转至官网主页 -->
[![Maple - macOS Multi-Pane File Manager](https://raw.githubusercontent.com/liceal/Maple/main/docs/assets/poster.png)](https://liceal.github.io/maple)

<br />

<!-- 实时全版本下载量统计徽章 -->
[![Downloads](https://img.shields.io/github/downloads/liceal/maple/total.svg?style=flat-square&logo=github&color=c2531a&label=Downloads)](https://github.com/liceal/maple/releases)
&nbsp;
[![Latest Release](https://img.shields.io/github/v/release/liceal/maple?style=flat-square&color=733c19)](https://github.com/liceal/maple/releases/latest)

<br /><br />

[![Download Apple Silicon](https://img.shields.io/badge/Download-Apple%20Silicon%20(M%20Series)-c2531a?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/liceal/Maple/releases/latest/download/Maple-arm64.dmg)
&nbsp;&nbsp;
[![Download Intel](https://img.shields.io/badge/Download-Intel%20x86-733c19?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/liceal/Maple/releases/latest/download/Maple-x86_64.dmg)

<br /><br />

<details>
<summary>🛡️ <b>首次打开提示「无法验证开发者」或「已损坏」？点击查看解决指南</b></summary>
<br />
<div align="left">

由于 Maple 是免费开源应用，暂未购买 Apple 付费开发者公证证书，macOS 首次启动时可能会触发 Gatekeeper 安全拦截。任选以下一种方式即可正常打开：

1. **方式一：免命令 · 右键打开（适合普通用户）**
   - 将 `Maple.app` 拖入「应用程序」文件夹后，在「访达 → 应用程序」中找到 **Maple**；
   - 按住键盘 `Control` 键（或鼠标右键）点击 Maple 图标，在弹出菜单中选择 **「打开」**；
   - 若系统仍弹出拦截提示，前往 **「系统设置 → 隐私与安全性」**，滑到底部点击 **「仍要打开」**。

2. **方式二：一行终端命令永久放行（最彻底 · 推荐）**
   打开系统自带的「终端 (Terminal)」，粘贴以下命令并回车，即可移除隔离属性：
   ```bash
   xattr -cr /Applications/Maple.app
   ```

3. **方式三：全自动免拦截一键安装脚本**
   自动检测芯片架构（Apple Silicon / Intel）、下载最新版并自动解除系统拦截：
   ```bash
   curl -fsSL https://liceal.github.io/maple/install.sh | bash
   ```

</div>
</details>

<br />

[MIT License](LICENSE)

</div>
