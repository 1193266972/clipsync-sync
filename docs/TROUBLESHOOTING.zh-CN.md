# 故障排查

现象 → 原因 → 处理。先看 `%LOCALAPPDATA%\clipsync\clipsync.log` 和 `guard.log`。

[English](TROUBLESHOOTING.md) | **简体中文**

---

## 安装阶段

**`Hub 不可访问`**

共享不通，或路径写错。先验：

```powershell
Test-Path '\\HUBHOST\share\clipsync'
```

返回 False 说明共享本身有问题，与 clipsync 无关。

**`Hub 可写: False`**

有读权限但没有写权限。机器必须能在汇合点里创建 `files\` 暂存目录。去改共享权限。

**校验和不符**

有人改过脚本，或复制损坏。来源可信就加 `-Force` 重跑，否则从汇合点重新复制。

**`syntax errors in …`**

脚本丢了 BOM 或被截断。重新复制；安装器会自动补 BOM。

---

## 进程在跑，但什么都不动

**日志只有一行 `=== start`，之后没有下文**

看子进程真实命令行：

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'clipsync' } |
  Select-Object ProcessId, CommandLine
```

如果 `-Hub` 显示为 `\HUBHOST\share\clipsync`（单个反斜杠），说明 UNC 路径被未加引号的参数拼接吃掉了。通过 `clipsync-ctl.ps1` 重启，它会给路径参数加引号。

**从不出现 `peer identified`**

汇合点里除了你自己，没有任何 `*.clip`。对方要么没在跑，要么指向了别的目录。对照：

```powershell
Get-ChildItem '<hub>' -Filter '*.clip'
```

---

## 内容不落地

**`PULL skip stale <name> (age N min > 5 min)`**

这是按设计工作的：对端文件比 `-StaleMinutes` 更老，启动时不采纳。对端复制了新内容就会恢复。想关掉：`-StaleMinutes 0`。

**`clipboard <- peer (...) [echo suppressed]`**

你粘贴的是最初来自对端的内容。正确地不回推。

**文本能同步，图片和文件不行**

对端是旧版本，没有这些通道。看汇合点里有没有 `.files`，或在对端日志里找 `file channel enabled` / `image channel enabled`。

**重复复制同一段文字不同步**

只有一侧还跑着 2.3 之前的版本（纯哈希去重）才会。两边都升级即可；新版把更新的 `ts` 当作新事件。

---

## 日志里的错误

**`PUSH FAILED #n: …`**

写汇合点失败——权限、网络中断、共享消失。验 `Test-Path '<hub>'` 且可写。

**`PULL: <name> unreadable/incomplete, retry`**

对端正写到一半，或发布了巨大的内容。会自动重试。持续出现说明对端在无大小保护的情况下发布——查它的版本。

**`SET CLIPBOARD FAILED (locked, will retry)`**

别的程序占着剪贴板。会自动重试。如果长期出现，找那个剪贴板管理器或频繁轮询剪贴板的程序。

**`PUSH skipped: text too large (N bytes > 1048576)`**

按设计工作。确实需要就调大 `-MaxPublishBytes`。

**`files skipped: folder not supported`**

文件夹是刻意不支持的。复制里面的文件。

**`files skipped: total N MiB > 100 MiB`**

批次上限。拆开，或调大 `-MaxFilesTotalBytes`。

**`IMAGE PUSH skipped: N MiB > 20 MiB`**

图片在 PNG 编码后的上限。调大 `-MaxImageBytes`。

**`FILE PULL skipped: N path(s) unreachable`**

暂存被清理了（默认 2 天），或本机访问不到共享。让发送方重新复制，或调大 `-StagingKeepDays`。

---

## 重启之后

**什么都没跑起来**

任务是 `AtLogOn`，也就是**用户登录时**启动，不是开机启动。查：

```powershell
Get-ScheduledTask -TaskName 'clipsync-guard'
```

`Ready` 表示下次登录会跑；`Disabled` 表示被关掉了。

**任务存在但从不触发**

触发账户与实际登录账户不一致。用正确账户登录后再注册一次：

```powershell
cd C:\clipsync
.\clipsync-ctl.ps1 -Action autostart-off
.\clipsync-ctl.ps1 -Action autostart-on -Hub '<hub>'
```

**RDP 里 / 以服务方式跑时没有剪贴板同步**

按设计如此。剪贴板属于交互式会话，session 0 没有剪贴板。用户态无法绕过。

---

## 健康检查

```powershell
cd C:\clipsync

# 进程 + 汇合点状态 + 计划任务
.\clipsync-ctl.ps1 -Action status -Hub '<hub>'

# 端到端：写一个标记，验证它到达汇合点
.\clipsync-ctl.ps1 -Action selftest -Hub '<hub>'
```

`status` 应显示一个 `GUARD` 和一个 `CHILD`。少了 `CHILD` 说明守护进程正在反复重启它——读 `guard.log`。

---

## 怎么读日志

```
15:14:58.596 === start local=MACHINE-A id=76d1... hub=D:\share\clipsync stale=5min maxpub=1048576B
15:14:58.660 peer identified: MACHINE-B
15:14:58.682 hub -> clipboard (1846 chars) from MACHINE-B     ← 拉取
15:15:21.150 local -> hub (29 chars)                           ← 推送
15:49:59.423 local -> hub image: 1280x720, 0.1 MiB, 25 ms
15:50:18.618 hub -> clipboard image: 1280x720 0.1 MiB from MACHINE-B
15:46:56.794 local -> hub files: 1 item(s), 20.0 MiB, 5 ms
15:46:37.223 hub -> clipboard files: 1 item(s) from MACHINE-B
```

推送是 `local -> hub`，拉取是 `hub -> clipboard`。如果永远只有单向，说明另一台机器没在跑或配置错了。
