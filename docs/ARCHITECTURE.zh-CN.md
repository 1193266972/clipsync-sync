# 架构说明

设计决定，以及迫使这些决定出现的失败。大部分是踩出来的。

[English](ARCHITECTURE.md) | **简体中文**

---

## 1. 单一汇合点，而不是互指路径

**坏的做法：**

```
A 写入  ->  \\B\share\clipsync\A.clip
A 读取  <-  \\B\share\clipsync\<对端>.clip
```

A 读的是自己刚写进去的目录。就算命名完美，读路径和写路径对"谁的剪贴板在哪"的判断也是矛盾的。

**能用的做法：**

```
所有人读写同一个  <hub>
<hub> = D:\share\clipsync           （在持有共享的那台机器上，本地路径）
      = \\HUBHOST\share\clipsync    （其他机器）
```

没人需要知道别人的名字。持有共享的机器走本地 IO，其余机器付 SMB 的延迟。

---

## 2. 永远不要用 IP 推导对端文件名

最初的版本这么干：

```powershell
$PeerHost = ($Peer -split '\.')[0].ToUpper()   # "192.168.31.246" -> "192"
$PeerClip = "\\$Peer\share\clipsync\$PeerHost.clip"   # -> 192.clip
```

而对端发布时用的是自己的 `COMPUTERNAME`，比如 `WIN-TH6V83705F4.clip`。`192.clip` 永远匹配不上。用 IP 调用时，这对机器会静默地永不同步——进程在跑、日志安静、什么都不动。

**修法：** 扫描汇合点，排除自己的名字，取最新的。

```powershell
Get-ChildItem $Hub -Filter '*.clip' -File |
  Where-Object { $_.BaseName.ToUpper() -ne $LocalName } |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
```

再用 `payload.id != 我的 id` 二次确认。

---

## 3. mtime 是变更探测器，永远不是事件身份

把 `if ($file.LastWriteTimeUtc -gt $peerMTime)` 当作"这是新的吗"会以三种方式失败：

| 失败 | 后果 |
|---|---|
| 刚启动（`$peerMTime = MinValue`） | 所有历史文件都显得新 —— 用户的剪贴板被几小时前的内容顶掉 |
| 时钟回拨（NTP 校时） | 已消费的文件重新显得更新 —— 重复投递，剪贴板被冲掉 |
| SMB 时间戳只有秒级 | 同一秒内两次写入比较相等 —— 第二次被漏掉 |

所以 mtime 只用来当"值不值得重读一次"的廉价触发器：

```powershell
$key = "{0}|{1}" -f $pf.LastWriteTimeUtc.Ticks, $pf.Length
if ($key -ne $handledSig -or $retryPending) { ... 重读 ... }
```

身份来自内容。

---

## 4. 只靠哈希去重会悄悄吃掉重复复制

只比哈希不够：

```
用户复制 A  ->  对端收到 A       （.recv = H(A)）
用户复制 B  ->  对端收到 B
用户又复制 A  ->  哈希 == .recv  ->  "已经有了"  ->  丢失
```

重复复制同一段文字是真实且高频的用户动作。

**修法：** `.recv` 存 `"<哈希>|<发布方 ts>"`。

```
哈希不同                       -> 新事件
哈希相同，ts 比记录的新          -> 新事件（重复复制）
哈希相同，ts 不比记录的新        -> 重放，丢弃
```

`ts` 由**发布方**在写入瞬间打印，因此接收方的时钟和文件系统时间戳精度都不再影响判断。

向后兼容是设计出来的：读 `"<哈希>|<ts>"` 时取 `split('|')[0]`，所以旧版本写下的纯哈希照样能解析。

---

## 5. 过期保护

即使有上面的机制，启动后的第一次轮询仍可能采纳很久以前的对端内容。加了闸：

```powershell
if ($ph -ne $recvState.h -and $StaleMinutes -gt 0 -and $ageMin -gt $StaleMinutes) {
    # 跳过，并标记为已处理
}
```

**只对未知内容生效**。重复复制（同哈希、更新的 `ts`）按定义就是新鲜的，绕过这道闸。

默认 5 分钟。`-StaleMinutes 0` 可关闭。

---

## 6. 文件：剪贴板里装的是路径，不是文件

`CF_HDROP` 装的是路径字符串。把本地路径复制给对端毫无用处——对端没有那个盘符。

因为两台机器共享同一个汇合点，流程是：

1. 把文件复制进 `<hub>\files\<批次>\<名字>`
2. 发布 `{"k":"files","h":<批次哈希>,"p":[UNC 路径]}`
3. 接收方对每个路径做 `Test-Path`，然后设 `FileDrop`

对端的资源管理器会直接通过 SMB 打开那个 UNC 路径。

### 批次哈希只用 名字 + 大小

```powershell
sha256( sort( "<小写文件名>|<字节数>" ) )
```

**刻意不用 mtime**：两台机器通过 SMB 看同一个文件，时间戳的精度或时区处理可能不同。哈希会分叉，然后这对机器会永远乒乓。

---

## 7. 图片：只编码一次，并记住自己的编码器

图片没有路径，所以 PNG 写进暂存目录，载荷标注 `k:"img"`。

接收方一次性设置三种剪贴板格式：

| 格式 | 谁在用 |
|---|---|
| `Bitmap` | 画图、Word、多数聊天软件 |
| `PNG` | 浏览器、Electron 应用 |
| `FileDrop` | 资源管理器（粘贴成一个 .png 文件） |

**回环陷阱：** 把 `Bitmap` 重新编码成 PNG **不会**得到完全相同的字节——编码器版本、压缩参数、alpha 处理都会让输出不同。于是：

```
我的编码    -> H1
对端 payload.h -> H0
H1 != H0  ->  "新图片！"  ->  回推  ->  乒乓
```

**修法：** 从收到的 PNG 设置完剪贴板之后，立刻用**自己的**编码器把它重新编码一遍，把这个哈希记成 `$imgSig`，持久化到 `%LOCALAPPDATA%\clipsync\last_img.sig`。

下一轮对同一张位图算出的哈希相同，于是跳过。持久化是为了覆盖重启场景——重启后剪贴板里可能还留着那张收到的图。

文件通道用 `last_files.sig` 做同样的处理。

---

## 8. 轮询成本：用剪贴板序列号

每 400 毫秒把一张 4K 截图编码成 PNG 是浪费。Windows 提供了 `GetClipboardSequenceNumber()`——每次剪贴板变化都会自增的计数器。

```csharp
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
```

```powershell
$seq = [ClipSeq]::GetClipboardSequenceNumber()
if ($seq -ne $lastSeq) { ... 读、哈希、发布 ... }
```

我们自己 `SetDataObject` 之后会刷新 `$lastSeq`，避免触发自己。空闲成本降到每个 tick 读一个整数。

---

## 9. 大载荷制造的是重试风暴，不只是慢

把一个 50 MB 的 base64 块写进 SMB，对端可能读到半成品。JSON 解析失败，对端记 `unreadable/incomplete, retry`，然后两边一起猛敲共享目录好几秒。

所以发布前有硬上限：文本 1 MiB、文件 100 MiB、图片 20 MiB。超限只记一条日志，不发布。

---

## 10. 进程卫生

**单实例** —— 命名互斥量 `Local\clipsync_instance_<HOST>`：

```powershell
try   { $has = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $has = $true }
```

用 `Local\` 而不是 `Global\`，避免额外权限要求。必须处理 `AbandonedMutexException`：被强杀的前任会留下废弃状态的互斥量，拒绝接管就意味着服务永远起不来。

**守护** —— `clipsync-guard.ps1` 监督工作进程：

- 退出后重启，退避 2 秒 → 30 秒，稳定运行 60 秒后重置回 2 秒
- 退出码 `240` 表示"请求正常停止"——不再重启
- 日志 2 MB 轮转

**日志绝不能让主循环崩掉：**

```powershell
try { [System.IO.File]::AppendAllText($LogFile, $line, $Utf8NoBom) } catch { }
```

---

## 11. 真实花掉时间的 PowerShell 细节

| 坑 | 现象 | 修法 |
|---|---|---|
| 缺 UTF-8 BOM | PS 5.1 按 ANSI 代码页解码文件；中文注释变乱码，有时直接语法错误 | 用 `New-Object System.Text.UTF8Encoding $true` 写 |
| `gl` 是内置别名 | 名为 `GL` 的函数会解析成 `Get-Location`；`GL "文本"` 抛"找不到接受实际参数的位置形式参数" | 避开别名名（`gl`、`ls`、`cd`、`sc`），改用 `Write-GuardLog` |
| `$args` 是自动变量 | 赋值静默失效 | 改名 `$childArgs` |
| `-ArgumentList` 数组按空格拼接且不加引号 | 路径开头的 `\\` 在 CRT 解析时少一个反斜杠；UNC 变成 `\server\share`，子进程静默空转 | `'-Hub',('"{0}"' -f $Hub)` |
| 命令行里的中文字面量 | 到达 PowerShell 之前已按 ANSI 代码页转换；非 cmd 宿主还会破坏反斜杠 | 在脚本内构造：`[string]([char]0x5171 + [char]0x4EAB)` |
| 非 STA 线程操作剪贴板 | 在 `Start-Job` / runspace 里 `SetDataObject` 抛错 | 用 `-File` 起独立进程（默认 STA） |
| 对已死 PID 调 `Stop-Process` | 在 `$ErrorActionPreference = 'Stop'` 下是终止性错误，会把控制脚本带走 | `if (Get-Process -Id $p -ErrorAction SilentlyContinue) { ... }` |
| 字符串里的 `"---"` | 被解析成自减运算符 → "必须在 - 运算符后面提供一个值表达式" | 用 `===` |
| `if ($Fn($x))` | 不是合法的调用语法 | `if (My-Function $x)` |
| `GetText()` | 走 ANSI 编组；emoji 与生僻汉字变 `?` | `GetData([DataFormats]::UnicodeText)` / `SetDataObject` 配 `DataObject` |

---

## 12. 这套模式适合什么

传输层是通用的：**用共享文件夹做无服务端的汇合点，内容哈希保证幂等，发布方时间戳确定事件身份。**

可直接复用于：

- 跨机的小文件投放目录
- 配置分发（改一个文件，各机器轮询取走）
- N 台机器之间的小状态广播（每台一个文件）
- 没有消息中间件时的轻量通知

不适合：大文件、高吞吐、严格顺序，或任何需要亚 100 毫秒延迟的场景。
