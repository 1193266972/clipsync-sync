# clipsync

跨机剪贴板同步（Windows）——**文本、图片、文件**，走 SMB 共享。无服务端、无客户端、无云。

一个共享文件夹作为汇合点，每台机器把自己的剪贴板写进去，读走别人的。加机器不用改任何现有配置。

```
机器 A ──┐
机器 B ──┼──►  \\HUBHOST\share\clipsync\   ◄──  一个共享文件夹
机器 C ──┘        （所有机器读写这里）
```

[English](README.md) | **简体中文**

---

## 为什么会有这个

最直觉的做法——"我写进你的共享，再从你的共享读"——是坏的：每台机器最终读到的是自己写的那份。另一个常见坑是用 IP 地址推算对端剪贴板的文件名，那永远匹配不上对端真实的 `COMPUTERNAME`。

本项目用**单一汇合点 + 动态发现对端**解决前者，用**内容哈希 + 发布方时间戳**的事件模型解决时钟偏移与回环问题。

---

## 能力

| | |
|---|---|
| **文本** | 纯文本，UTF-8 走 base64 —— 中文、重音字符、emoji 全不坏 |
| **图片** | 以 PNG 发布；接收方同时设置 `Bitmap` + `PNG` + `FileDrop`，各类程序都能原生粘贴 |
| **文件** | 复制到共享上的暂存目录，剪贴板里带的是 **UNC 路径**，对端真的能打开 |
| **无需服务端** | 用现成的 SMB 共享 |
| **自愈** | 守护进程按指数退避重启工作进程 |
| **开机自启** | 可选 `AtLogOn` 计划任务 |
| **有边界** | 大小上限、过期保护、暂存清理、日志轮转 |

---

## 快速开始

### 1. 选一个汇合点

任何两台机器都能**读写**的目录，例如 `\\HUBHOST\share\clipsync`。

持有该共享的那台机器建议用**本地路径**（`D:\share\clipsync`）以获得最快速度，其他机器用 UNC 路径。两者指向同一个物理目录。

### 2. 每台机器安装

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\\HUBHOST\share\clipsync\deploy\install.ps1"
```

把 `install.ps1` 与三个工作脚本一起放进汇合点内部（例如 `deploy\` 子目录）。安装器会从自身位置推导汇合点——从共享里运行，它就自己配好了。

它会：

1. 非管理员时通过 UAC 提权
2. 解析汇合点（或用 `-Hub` 指定）
3. 探测汇合点**可写**
4. 按 `checksums.txt` 比对字节数与 SHA-256
5. 复制到 `C:\clipsync`，BOM 丢失则自动补回
6. 对所有脚本做语法检查
7. 停掉已有实例
8. 用解析出的汇合点启动
9. 注册 `AtLogOn` 计划任务
10. 打印日志尾部与验证步骤

### 3. 完事

在一台机器上复制，到另一台粘贴。没有别的配置。

---

## 手动安装

```powershell
New-Item -ItemType Directory C:\clipsync -Force
Copy-Item .\*.ps1 C:\clipsync\ -Force

Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\clipsync
.\clipsync-ctl.ps1 -Action start -Hub '\\HUBHOST\share\clipsync'
.\clipsync-ctl.ps1 -Action autostart-on -Hub '\\HUBHOST\share\clipsync'
```

---

## 日常运维

```powershell
cd C:\clipsync

.\clipsync-ctl.ps1 -Action status  -Hub '<hub>'   # 进程、日志、汇合点状态文件、计划任务
.\clipsync-ctl.ps1 -Action log                    # 两个日志的尾部
.\clipsync-ctl.ps1 -Action stop
.\clipsync-ctl.ps1 -Action start   -Hub '<hub>'
.\clipsync-ctl.ps1 -Action selftest -Hub '<hub>'  # 写一个标记，验证它真的落地了
.\clipsync-ctl.ps1 -Action autostart-on  -Hub '<hub>'
.\clipsync-ctl.ps1 -Action autostart-off
.\clipsync-ctl.ps1 -Action uninstall
```

日志：`%LOCALAPPDATA%\clipsync\clipsync.log` 与 `guard.log`。

---

## 工作原理

### 汇合点里的文件

```
<hub>\
  <HOST>.clip      {"h":sha256,"id":"<本次启动 id>","ts":unix,"t":"base64 utf8 文本"}
  <HOST>.seen      本机最后推送过的 sha256
  <HOST>.recv      "<sha256>|<ts>"，本机最后接收过的
  <HOST>.files     {"k":"files"|"img","h","id","ts","p":[UNC 路径],"w","ht"}
  <HOST>.fseen
  <HOST>.frecv
  files\<批次>\    文件与图片的暂存目录
```

每台机器只写以自己名字命名的文件。读取的含义是：扫描目录，取**最新的、名字不是我的**那一个。

### 回环保护

四道闸，命中任一即丢弃：

1. `payload.id` 等于我自己的启动 id —— 这是我写的
2. `payload.h` 等于我的 `.seen` —— 我刚推出去的
3. `payload.h` 等于我的 `.recv` **且** `payload.ts` 不比记录的更新 —— 已经收过
4. 当前剪贴板哈希等于 `.recv` —— 这段内容来自对端

第 3 条让"重复复制同一段文字"成为新事件（新 `ts`），同时仍能忽略真正的重放。

### 为什么是 `h|ts` 而不只是 `h`

两种失败模式会撞在一起：

- **时钟回拨**让已消费的文件重新显得更新 → 重复投递
- **重复复制相同文字**看起来像"已看过" → 丢失投递

如果只比时间戳，两者表现完全一样。把**发布方的** `ts` 和哈希一起存下来就能区分：同哈希且 `ts` 更新 = 新事件；同哈希但 `ts` 不更新 = 重放。

### 文件为什么用 UNC 路径

`CF_HDROP` 存的是**路径**，不是字节。本地路径在对端毫无意义。因为两台机器看得见同一个共享，载荷里直接带文件的 UNC 路径，接收方把它设成 `FileDrop` —— 目标程序会直接通过 SMB 打开。

图片同样以 PNG 存到暂存目录并发布，但接收方额外设置 `Bitmap` 与 `PNG` 两种剪贴板格式，这样聊天软件和画图程序粘到的是真正的图像，而不是一个文件。

---

## 限制

| | |
|---|---|
| 文本 | 1 MiB（base64 载荷上限） |
| 文件 | 单批 100 MiB |
| 图片 | PNG 编码后 20 MiB |
| 文件夹 | **不支持** —— 递归复制体积不可控，会记日志跳过 |
| 延迟 | 约 0.5 秒（400 ms 轮询） |
| 会话 | 需要交互式登录；session 0 里没有剪贴板 |
| 多机 | 所有机器共用**一个**剪贴板 —— 最后写入者生效，不是点对点 |

所有阈值都是参数：`-MaxPublishBytes`、`-MaxFilesTotalBytes`、`-MaxImageBytes`、`-StagingKeepDays`、`-IntervalMs`、`-StaleMinutes`。

---

## 环境要求

- Windows 10 / 11，PowerShell 5.1
- 安装需要管理员权限（写计划任务和 `C:\`）
- 每台机器对汇合点都要有**读和写**权限

---

## 文档

- [`docs/ARCHITECTURE.zh-CN.md`](docs/ARCHITECTURE.zh-CN.md) —— 设计说明、协议，以及每个决定背后的踩坑
- [`docs/TROUBLESHOOTING.zh-CN.md`](docs/TROUBLESHOOTING.zh-CN.md) —— 现象 → 原因 → 处理
- [`CHANGELOG.zh-CN.md`](CHANGELOG.zh-CN.md) —— 版本历史，包括塑造了这套设计的那些 bug

英文版：[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) · [`CHANGELOG.md`](CHANGELOG.md)

---

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
