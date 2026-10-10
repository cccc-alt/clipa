# Clipa

轻巧的 macOS 剪贴板历史工具。用接近 Spotlight 的紧凑面板，快速找回文本、图片和文件。

**[下载最新版](https://github.com/cccc-alt/clipa/releases/latest)** · [更新说明](https://github.com/cccc-alt/clipa/blob/main/CHANGELOG.md) · [界面预览](https://github.com/cccc-alt/clipa/blob/main/docs/images/clipboard.png)

当前版本 **2.8.0（Build 21）**。安装包支持 **Apple Silicon / macOS 14+**，在 macOS 26 及更新系统使用原生玻璃材质，支持浅色与深色外观。

## 功能

| 功能 | 说明 |
| --- | --- |
| 快速找回 | 全文搜索、类型筛选、键盘选择、按需内容预览 |
| 历史管理 | 文本、图片、文件、收藏、备注与可恢复的会话内备注草稿 |
| 多工作区 | 独立历史与容量上限，支持创建、切换、重命名及移到废纸篓 |
| 资料集 | 按项目整理历史，支持界面和 MCP 批量操作；删除资料集保留原历史 |
| 隐私保护 | SQLCipher 整库加密；私密内容另用 AES-GCM 加密，密钥保存在 macOS 钥匙串 |
| 私密条目 | Touch ID 或系统密码验证，60 秒自动锁定；不参与搜索和本地接口访问 |
| 过滤规则 | 忽略指定应用、遵循机密标记、过滤密码管理器及疑似敏感内容 |
| 本地集成 | Cursor / Claude Desktop / Codex 连接向导、工作区授权、连接诊断与凭据轮换；接口默认关闭 |
| 新手引导 | 首次启动自动展示，覆盖搜索复制、隐私设置和登录启动 |

## 安装与使用

1. 从 [Releases](https://github.com/cccc-alt/clipa/releases/latest) 下载 DMG，将 **Clipa.app** 拖入“应用程序”。
2. 打开 Clipa，按引导完成设置，或选择“稍后再看”。完成或跳过后不再自动弹出。
3. 在任意应用复制内容，按 **⌃⌘V** 打开历史，搜索并按回车复制，再到目标应用按 **⌘V** 粘贴。

顶部菜单只保留“打开剪贴板、登录时启动、设置、关于 Clipa、退出 Clipa”。其他功能在设置中管理；新手引导可从 **设置 → 通用 → 新手引导** 重新查看。

安装包使用 ad-hoc 签名，尚未通过 Apple 公证。首次打开若被系统阻止，可在核实下载来源后通过“系统设置 → 隐私与安全性”允许打开；钥匙串授权在 macOS 系统弹窗中完成。

| 快捷键 | 操作 |
| --- | --- |
| `⌃⌘V` | 打开 / 关闭剪贴板面板 |
| `↑` / `↓` | 选择条目 |
| `↩` | 复制选中条目并关闭面板 |
| 空格 / `⌘Y` | 查看详情；输入搜索词后使用 `⌘Y` |
| `Esc` | 返回上一级、取消编辑或关闭面板 |
| `⌘S` | 保存正在编辑的备注 |
| `⌘,` | 打开设置 |

## CLI / MCP

在 **设置 → 应用集成** 选择客户端，确认工作区与权限后保存连接配置。已有 Clipa 配置需要勾选替换，并会先备份；Codex 使用官方 CLI 更新配置。完成后重新启动 AI 客户端，并调用 `clipa_status` 验证。

自动连接的客户端配置只保存连接编号，令牌单独保存在仅当前用户可读的凭据文件中。“重新连接”会轮换凭据，“检测连接”不会伪造客户端使用记录；高级用户仍可手动创建令牌。

**从 2.7 及更早版本升级：旧授权需要在“管理授权”中确认工作区后恢复访问。** 仅元信息或预览权限不会返回备注；私密条目始终不可访问。本机连接不等于 AI 在本机处理，客户端可能把获准读取的内容发送至其模型服务。

- CLI：`/Applications/Clipa.app/Contents/Helpers/clipa`
- MCP：`/Applications/Clipa.app/Contents/Helpers/clipa-mcp`
- 客户端通过 `CLIPA_TOKEN` 环境变量提供令牌；不要把真实令牌提交到仓库。

MCP 提供 16 项工具，并按权限显示：诊断与重新连接、工作区列表、搜索/读取/复制/写入/备注/删除，以及资料集创建、重命名、删除和成员整理。搜索支持工作区、来源、类型、时间及资料集筛选；正文和备注默认按 64 KiB 分页，上限 256 KiB。

跨授权工作区的读取和资料整理不会切换界面；复制、新增、修改及删除历史需要先在 Clipa 中打开对应工作区。

## 从源码构建

需要 Apple Silicon Mac、含 **macOS 26 或更新 SDK** 的 Xcode / Command Line Tools。

```sh
git clone https://github.com/cccc-alt/clipa.git
cd clipa
zsh Scripts/build.sh
```

脚本会编译随仓库提供的 SQLCipher、构建应用及 CLI / MCP 助手、签名并生成安装包。产物为 `.build/app/Clipa.app` 和 `dist/Clipa-<版本>.dmg`；构建入口以此脚本为准。

隔离数据与钥匙串的回归检查：

```sh
.build/app/Clipa.app/Contents/MacOS/Clipa --selftest
.build/app/Clipa.app/Contents/MacOS/Clipa --onboarding-probe
.build/app/Clipa.app/Contents/MacOS/Clipa --workflow-probe
.build/app/Clipa.app/Contents/MacOS/Clipa --integration-probe
```

项目采用 [BSD 2-Clause](https://github.com/cccc-alt/clipa/blob/main/LICENSE) 许可；SQLCipher 许可见 [Vendor/SQLCipher/LICENSE.md](https://github.com/cccc-alt/clipa/blob/main/Vendor/SQLCipher/LICENSE.md)。
