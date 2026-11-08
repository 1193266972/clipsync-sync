<#
  clipsync.ps1 (v2.5) -- 跨机剪贴板同步：文本 + 文件 + 图片

  三条通道，互相独立，各用各的状态文件：

    文本  <HOST>.clip / .seen / .recv
    文件  <HOST>.files / .fseen / .frecv     {"k":"files",...}
    图片  <HOST>.files / .fseen / .frecv     {"k":"img",...}

  文件与图片共用 .files 通道，用 k 字段区分。理由：两者的 staging、
  去重、时效、大小保护逻辑完全一致，只有"怎么放进剪贴板"不同。

  ── 图片的做法（v2.5 新增）──────────────────────────────────────
  发布：
      取 Clipboard.GetImage() -> 编码成 PNG 字节 -> 哈希 -> 落到 staging
      payload: {"k":"img","h":<png字节哈希>,"id","ts","p":[UNC],"w","ht"}
  接收：
      读 UNC 上的 PNG -> 同时设置三种剪贴板格式：
          Bitmap     （画图/聊天窗口直接贴出图）
          PNG        （浏览器、Electron 应用优先取这个）
          FileDrop   （资源管理器粘贴成文件）
      目标程序按自己支持的格式选，这是"体验优先"的关键。

  ── 图片的回环保��为什么不能只靠哈希 ──────────────────────────
  Bitmap 被再次编码成 PNG 时，即使像素相同，字节也可能不同
  （编码器版本、压缩参数、有无 alpha 都会影响）。
  于是"我方算出的哈希 != 对端 payload.h"，会被判定成新图片而回推。

  解法：收到图片并设置剪贴板后，立刻把"我方重新编码后的哈希"记下来
  （$imgSig），并持久化到 %LOCALAPPDATA%\clipsync\last_img.sig。
  下一轮我方编码出的哈希与之相等 -> 判定为自己刚收的，不回推。
  文件通道同理用 last_files.sig 持久化，覆盖重启场景。

  ── 其他 ───────────────────────────────────────────────────────
  * 用 GetClipboardSequenceNumber() 做变更检测，不再每 400ms 重读剪贴板
  * 文本通道逻辑与 v2.3 一致；文件通道与 v2.4 一致
  * 文件夹仍不支持（递归体积不可控）
#>
param(
    [string]$Hub,
    [string]$Peer,
    [string]$ShareName = [string]([char]0x5171 + [char]0x4EAB),   # 共享
    [int]$IntervalMs = 400,
    [int]$StaleMinutes = 5,
    [int]$MaxPublishBytes = 1048576,
    [long]$MaxFilesTotalBytes = 104857600,
    [long]$MaxImageBytes = 20971520,
    [int]$StagingKeepDays = 2,
    [string]$UncRoot = '',
    [switch]$NoFiles,
    [switch]$NoImages,
    [string]$LogFile = "$env:LOCALAPPDATA\clipsync\clipsync.log"
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ClipSeqSrc = @'
using System;
using System.Runtime.InteropServices;
public static class ClipSeq {
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
'@
try { Add-Type -TypeDefinition $ClipSeqSrc -ErrorAction Stop } catch { }

if (-not $Hub -or $Hub.Trim().Length -eq 0) {
    if ($Peer) { $Hub = "\\$Peer\$ShareName\clipsync" }
    else       { $Hub = 'D:\' + [string]([char]0x5171 + [char]0x4EAB) + '\clipsync' }
}
$Hub = $Hub -replace '/', '\'

$LocalName = $env:COMPUTERNAME.ToUpper()
$LocalId   = [guid]::NewGuid().ToString('N')
$MyClip    = Join-Path $Hub ($LocalName + '.clip')
$MySeen    = Join-Path $Hub ($LocalName + '.seen')
$MyRecv    = Join-Path $Hub ($LocalName + '.recv')
$MyFiles   = Join-Path $Hub ($LocalName + '.files')
$MyFSeen   = Join-Path $Hub ($LocalName + '.fseen')
$MyFRecv   = Join-Path $Hub ($LocalName + '.frecv')
$StageDir  = Join-Path $Hub 'files'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$Sha256    = [System.Security.Cryptography.SHA256]::Create()

# ---------- 单实例 ----------
$instMutexName = 'Local\clipsync_instance_' + $LocalName
$instMutex = New-Object System.Threading.Mutex($false, $instMutexName)
try   { $hasInst = $instMutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $hasInst = $true }
if (-not $hasInst) {
    Write-Host "another clipsync instance already running, exit"
    return
}

$StateDir = Split-Path $LogFile
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$ImgSigFile  = Join-Path $StateDir 'last_img.sig'
$FileSigFile = Join-Path $StateDir 'last_files.sig'

function Log([string]$m) {
    $line = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $m
    try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8NoBom) } catch { }
}

function Get-Sha([string]$s) {
    $b = $Utf8NoBom.GetBytes($s)
    return ([System.BitConverter]::ToString($Sha256.ComputeHash($b)) -replace '-', '').ToLower()
}

function Get-ShaBytes([byte[]]$bytes) {
    return ([System.BitConverter]::ToString($Sha256.ComputeHash($bytes)) -replace '-', '').ToLower()
}

function Write-TextFile([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

function Read-TextFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [System.IO.File]::ReadAllText($path, $Utf8NoBom) } catch { return $null }
}

function Parse-Recv([string]$raw) {
    $r = @{ h = ''; ts = [long]0 }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $r }
    $raw = $raw.Trim()
    $parts = $raw.Split('|')
    $r.h = $parts[0].Trim().ToLower()
    if ($parts.Count -ge 2) {
        $n = [long]0
        if ([long]::TryParse($parts[1].Trim(), [ref]$n)) { $r.ts = $n }
    }
    return $r
}

function Get-UncRoot {
    if ($UncRoot) { return ($UncRoot -replace '/', '\').TrimEnd('\') }
    if ($Hub.StartsWith('\\')) { return $Hub.TrimEnd('\') }
    $ip = $null
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
               Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } |
               Select-Object -First 1
        if ($cfg) { $ip = $cfg.IPv4Address.IPAddress }
    } catch { }
    if (-not $ip) { $ip = $env:COMPUTERNAME }
    $leaf = Split-Path $Hub -Leaf
    $parent = Split-Path (Split-Path $Hub -Parent) -Leaf
    return "\\$ip\$parent\$leaf"
}

$UncBase = Get-UncRoot

function Get-ClipSeq {
    try { return [ClipSeq]::GetClipboardSequenceNumber() } catch { return [uint32]0 }
}

function Get-ClipText {
    for ($i = 0; $i -lt 4; $i++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::UnicodeText)) {
                $v = [System.Windows.Forms.Clipboard]::GetData([System.Windows.Forms.DataFormats]::UnicodeText)
                if ($v -is [string]) { return $v }
                $v2 = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
                return $v2
            }
            return $null
        } catch { Start-Sleep -Milliseconds 30 }
    }
    return $null
}

function Set-ClipText([string]$text) {
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $dp = New-Object System.Windows.Forms.DataObject
            $dp.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $false, $text)
            $dp.SetData([System.Windows.Forms.DataFormats]::StringFormat, $false, $text)
            $dp.SetData([System.Windows.Forms.DataFormats]::Text, $false, $text)
            [System.Windows.Forms.Clipboard]::SetDataObject($dp, $true)
            return $true
        } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}

function Get-ClipFiles {
    for ($i = 0; $i -lt 4; $i++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
                $col = [System.Windows.Forms.Clipboard]::GetFileDropList()
                $arr = @()
                foreach ($p in $col) { if ($p) { $arr += $p } }
                return $arr
            }
            return $null
        } catch { Start-Sleep -Milliseconds 30 }
    }
    return $null
}

function Set-ClipFiles([string[]]$paths) {
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $col = New-Object System.Collections.Specialized.StringCollection
            foreach ($p in $paths) { [void]$col.Add($p) }
            [System.Windows.Forms.Clipboard]::SetFileDropList($col)
            return $true
        } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}

function Get-ClipImage {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                $im = [System.Windows.Forms.Clipboard]::GetImage()
                if ($null -ne $im) { return $im }
            }
            return $null
        } catch { Start-Sleep -Milliseconds 30 }
    }
    return $null
}

# 同时设置 Bitmap + PNG + FileDrop，让目标程序自选格式
function Set-ClipImage([byte[]]$pngBytes, [string]$uncPath) {
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $ms  = New-Object System.IO.MemoryStream(,$pngBytes)
            $img = [System.Drawing.Image]::FromStream($ms)
            $dp  = New-Object System.Windows.Forms.DataObject
            $dp.SetData([System.Windows.Forms.DataFormats]::Bitmap, $false, (New-Object System.Drawing.Bitmap($img)))
            try { $dp.SetData('PNG', $false, $pngBytes) } catch { }
            if ($uncPath) {
                $col = New-Object System.Collections.Specialized.StringCollection
                [void]$col.Add($uncPath)
                try { $dp.SetFileDropList($col) } catch { }
            }
            [System.Windows.Forms.Clipboard]::SetDataObject($dp, $true)
            $img.Dispose(); $ms.Dispose()
            return $true
        } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}

function Convert-ImageToPng([System.Drawing.Image]$img) {
    $ms = New-Object System.IO.MemoryStream
    $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return $bytes
}

function Get-FileSetHash([string[]]$paths) {
    $items = @()
    foreach ($p in $paths) {
        try {
            $i = Get-Item -LiteralPath $p -ErrorAction Stop
            $items += ("{0}|{1}" -f $i.Name.ToLower(), $i.Length)
        } catch {
            $items += ("{0}|?" -f (Split-Path $p -Leaf).ToLower())
        }
    }
    $items = $items | Sort-Object
    return (Get-Sha ($items -join "`n"))
}

function Get-PeerClip {
    if (-not (Test-Path -LiteralPath $Hub)) { return $null }
    try {
        $cands = @(Get-ChildItem -LiteralPath $Hub -Filter '*.clip' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.BaseName.ToUpper() -ne $LocalName })
        if ($cands.Count -eq 0) { return $null }
        return ($cands | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    } catch { return $null }
}

function Get-PeerFiles {
    if (-not (Test-Path -LiteralPath $Hub)) { return $null }
    try {
        $cands = @(Get-ChildItem -LiteralPath $Hub -Filter '*.files' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.BaseName.ToUpper() -ne $LocalName })
        if ($cands.Count -eq 0) { return $null }
        return ($cands | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    } catch { return $null }
}

function Remove-OldStaging {
    if (-not (Test-Path -LiteralPath $StageDir)) { return }
    try {
        $limit = (Get-Date).AddDays(-1 * $StagingKeepDays)
        foreach ($d in @(Get-ChildItem -LiteralPath $StageDir -Directory -ErrorAction SilentlyContinue)) {
            if ($d.LastWriteTime -lt $limit) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Log ("staging cleaned: {0}" -f $d.Name)
            }
        }
    } catch { }
}

$mySig        = ''
$handledSig   = ''
$retryPending = $false
$peerName     = ''
$lastSent     = ''
$recvState    = Parse-Recv (Read-TextFile $MyRecv)
$lastErr      = ''
$pushFails    = 0
$tooBigLogged = [long]-1
$lastPullLog  = [datetime]::MinValue

$fileSig      = ''
$fileHandled  = ''
$fileRecv     = Parse-Recv (Read-TextFile $MyFRecv)
$fileSkipNote = ''
$fileSentH    = ''
if (Read-TextFile $MyFSeen) { $fileSentH = (Read-TextFile $MyFSeen).Trim() }

$imgSig       = ''
if (Test-Path -LiteralPath $ImgSigFile) { $imgSig = (Get-Content -LiteralPath $ImgSigFile -Raw).Trim() }
$filePersist  = ''
if (Test-Path -LiteralPath $FileSigFile) { $filePersist = (Get-Content -LiteralPath $FileSigFile -Raw).Trim() }
if ($filePersist -and -not $fileSig) { $fileSig = $filePersist }

$lastSeq = [uint32]0

Log "=== start local=$LocalName id=$LocalId hub=$Hub unc=$UncBase stale=${StaleMinutes}min maxpub=${MaxPublishBytes}B"
if (-not $NoFiles) {
    Log ("file channel enabled: stage={0} maxTotal={1}MiB keep={2}d" -f $StageDir, [int]($MaxFilesTotalBytes/1MB), $StagingKeepDays)
    Remove-OldStaging
}
if (-not $NoImages) { Log ("image channel enabled: maxImage={0}MiB" -f [int]($MaxImageBytes/1MB)) }

try {
while ($true) {

    # ============ 1. 本机剪贴板 -> Hub（用序列号做变更检测） ============
    $seqNow = Get-ClipSeq
    if ($seqNow -ne $lastSeq) {
        $lastSeq = $seqNow

        $didImage = $false
        $didFiles = $false

        # --- 1a. 图片优先 ---
        if (-not $NoImages) {
            $img = Get-ClipImage
            if ($null -ne $img) {
                try {
                    $png = Convert-ImageToPng $img
                    $ih  = Get-ShaBytes $png
                    if ($ih -ne $imgSig) {
                        $imgSig = $ih
                        try { Write-TextFile $ImgSigFile $ih } catch { }
                        $fileRecv = Parse-Recv (Read-TextFile $MyFRecv)

                        if ($ih -eq $fileRecv.h) {
                            Log ("image <- peer ({0}x{1}) [echo suppressed]" -f $img.Width, $img.Height)
                        } elseif ($png.Length -gt $MaxImageBytes) {
                            Log ("IMAGE PUSH skipped: {0:N1} MiB > {1} MiB" -f ($png.Length/1MB), [int]($MaxImageBytes/1MB))
                        } else {
                            $t0 = Get-Date
                            $batch = $ih.Substring(0,16)
                            $dest  = Join-Path $StageDir $batch
                            if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                            $name = "clip-img-{0}.png" -f (Get-Date -Format 'HHmmssfff')
                            $local = Join-Path $dest $name
                            [System.IO.File]::WriteAllBytes($local, $png)
                            $unc = Join-Path $UncBase ("files\{0}\{1}" -f $batch, $name)
                            $payload = @{
                                k  = 'img'
                                h  = $ih
                                id = $LocalId
                                ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                                p  = @($unc)
                                w  = $img.Width
                                ht = $img.Height
                            } | ConvertTo-Json -Compress -Depth 4
                            Write-TextFile $MyFiles $payload
                            Write-TextFile $MyFSeen $ih
                            $fileSentH = $ih
                            $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                            Log ("local -> hub image: {0}x{1}, {2:N1} MiB, {3} ms" -f $img.Width, $img.Height, ($png.Length/1MB), $ms)
                        }
                        $didImage = $true
                    } else {
                        $didImage = $true
                    }
                } finally {
                    $img.Dispose()
                }
            }
        }

        # --- 1b. 文件（图片不存在时才处理） ---
        if (-not $NoFiles -and -not $didImage) {
            $paths = Get-ClipFiles
            if ($null -ne $paths -and $paths.Count -gt 0) {
                $fh = Get-FileSetHash $paths
                if ($fh -ne $fileSig) {
                    $fileSig = $fh
                    try { Write-TextFile $FileSigFile $fh } catch { }
                    $fileRecv = Parse-Recv (Read-TextFile $MyFRecv)
                    if ((Read-TextFile $MyFSeen)) { $fileSentH = (Read-TextFile $MyFSeen).Trim() }

                    if ($fh -eq $fileRecv.h) {
                        Log ("files <- peer ({0} item(s)) [echo suppressed]" -f $paths.Count)
                    } elseif ($fh -eq $fileSentH) {
                        # 自己刚推过
                    } else {
                        $dirs = @(); $files = @(); $total = [long]0; $hasMissing = $false
                        foreach ($p in $paths) {
                            if (-not (Test-Path -LiteralPath $p)) { $hasMissing = $true; continue }
                            $it = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                            if ($null -eq $it) { continue }
                            if ($it.PSIsContainer) { $dirs += $it.FullName; continue }
                            $files += $it; $total += $it.Length
                        }
                        if ($hasMissing) {
                            Log "files skipped: some paths no longer exist"
                        } elseif ($dirs.Count -gt 0) {
                            $note = "files skipped: folder not supported ({0} dir(s))" -f $dirs.Count
                            if ($fileSkipNote -ne $note) { $fileSkipNote = $note; Log $note }
                        } elseif ($files.Count -gt 0) {
                            if ($total -gt $MaxFilesTotalBytes) {
                                $note = "files skipped: total {0} MiB > {1} MiB" -f [int]($total/1MB), [int]($MaxFilesTotalBytes/1MB)
                                if ($fileSkipNote -ne $note) { $fileSkipNote = $note; Log $note }
                            } else {
                                $t0 = Get-Date
                                try {
                                    $batch = $fh.Substring(0,16)
                                    $dest  = Join-Path $StageDir $batch
                                    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null }
                                    $uncList = @()
                                    foreach ($f in $files) {
                                        $target = Join-Path $dest $f.Name
                                        Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
                                        $uncList += (Join-Path $UncBase ("files\{0}\{1}" -f $batch, $f.Name))
                                    }
                                    $payload = @{
                                        k  = 'files'
                                        h  = $fh
                                        id = $LocalId
                                        ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                                        p  = $uncList
                                    } | ConvertTo-Json -Compress -Depth 4
                                    Write-TextFile $MyFiles $payload
                                    Write-TextFile $MyFSeen $fh
                                    $fileSentH = $fh
                                    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                                    Log ("local -> hub files: {0} item(s), {1:N1} MiB, {2} ms" -f $files.Count, ($total/1MB), $ms)
                                } catch {
                                    Log ("FILE PUSH FAILED: {0}" -f $_.Exception.Message)
                                }
                            }
                        }
                    }
                    $didFiles = $true
                }
            }
        }

        # --- 1c. 文本（既非图片也非文件时） ---
        if (-not $didImage -and -not $didFiles) {
            $txt = Get-ClipText
            if ($null -ne $txt -and $txt.Length -gt 0) {
                $bytes = $Utf8NoBom.GetBytes($txt)
                $sig = Get-Sha $txt
                if ($sig -ne $mySig) {
                    $mySig = $sig
                    $recvState = Parse-Recv (Read-TextFile $MyRecv)
                    if ($sig -eq $recvState.h) {
                        Log ("clipboard <- peer ({0} chars) [echo suppressed]" -f $txt.Length)
                    } elseif ($bytes.Length -gt $MaxPublishBytes) {
                        if ($tooBigLogged -ne $bytes.Length) {
                            $tooBigLogged = $bytes.Length
                            Log ("PUSH skipped: text too large ({0} bytes > {1})" -f $bytes.Length, $MaxPublishBytes)
                        }
                    } else {
                        $payload = @{
                            h  = $sig
                            id = $LocalId
                            ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                            t  = [System.Convert]::ToBase64String($bytes)
                        } | ConvertTo-Json -Compress
                        try {
                            if (-not (Test-Path -LiteralPath $Hub)) { New-Item -ItemType Directory -Path $Hub -Force -ErrorAction Stop | Out-Null }
                            Write-TextFile $MyClip $payload
                            Write-TextFile $MySeen $sig
                            $lastSent  = $sig
                            $pushFails = 0
                            Log ("local -> hub ({0} chars, {1} bytes)" -f $txt.Length, $bytes.Length)
                        } catch {
                            $pushFails++
                            if ($pushFails -le 3 -or ($pushFails % 60) -eq 0) {
                                Log ("PUSH FAILED #{0}: {1}" -f $pushFails, $_.Exception.Message)
                            }
                        }
                    }
                }
            }
        }
    }

    # ============ 2. Hub 中对端文本 -> 本机剪贴板 ============
    try {
        $pf = Get-PeerClip
        if ($null -ne $pf) {
            $key = "{0}|{1}" -f $pf.LastWriteTimeUtc.Ticks, $pf.Length
            if ($key -ne $handledSig -or $retryPending) {
                $raw = Read-TextFile $pf.FullName
                $obj = $null
                if ($raw) { try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null } }

                if ($null -eq $obj -or -not $obj.t) {
                    if (((Get-Date) - $lastPullLog).TotalSeconds -gt 5) {
                        Log ("PULL: {0} unreadable/incomplete, retry" -f $pf.Name)
                        $lastPullLog = Get-Date
                    }
                } else {
                    $ph   = ([string]$obj.h).ToLower()
                    $pid_ = [string]$obj.id
                    $pts  = [long]0
                    if ($obj.ts) { try { $pts = [long]$obj.ts } catch { $pts = 0 } }

                    $recvState = Parse-Recv (Read-TextFile $MyRecv)
                    $lastSent  = Read-TextFile $MySeen

                    if ($pid_ -eq $LocalId) { $handledSig = $key; $retryPending = $false }
                    elseif ($ph -eq $mySig) { $handledSig = $key; $retryPending = $false }
                    elseif ($ph -eq $lastSent) { $handledSig = $key; $retryPending = $false }
                    else {
                        $isNew = $false
                        if ($ph -ne $recvState.h) { $isNew = $true }
                        elseif ($pts -gt $recvState.ts) { $isNew = $true }

                        if (-not $isNew) { $handledSig = $key; $retryPending = $false }
                        else {
                            $stale = $false
                            if ($ph -ne $recvState.h -and $StaleMinutes -gt 0) {
                                $ageMin = $null
                                if ($pts -gt 0) { $ageMin = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $pts) / 60.0 }
                                if ($null -eq $ageMin) { $ageMin = ([DateTime]::UtcNow - $pf.LastWriteTimeUtc).TotalMinutes }
                                if ($ageMin -gt $StaleMinutes) {
                                    $stale = $true
                                    if (((Get-Date) - $lastPullLog).TotalSeconds -gt 10) {
                                        Log ("PULL skip stale {0} (age {1:N0} min > {2} min)" -f $pf.Name, $ageMin, $StaleMinutes)
                                        $lastPullLog = Get-Date
                                    }
                                    $handledSig = $key; $retryPending = $false
                                }
                            }
                            if (-not $stale) {
                                $ptxt = $Utf8NoBom.GetString([System.Convert]::FromBase64String([string]$obj.t))
                                if ($pf.BaseName.ToUpper() -ne $peerName) {
                                    $peerName = $pf.BaseName.ToUpper()
                                    Log ("peer identified: {0}" -f $peerName)
                                }
                                if (Set-ClipText $ptxt) {
                                    $newSig = Get-Sha $ptxt
                                    $mySig  = $newSig
                                    Write-TextFile $MyRecv ("{0}|{1}" -f $ph, $pts)
                                    $recvState = @{ h = $ph; ts = $pts }
                                    $handledSig = $key
                                    $retryPending = $false
                                    $lastSeq = Get-ClipSeq
                                    Log ("hub -> clipboard ({0} chars) from {1}" -f $ptxt.Length, $peerName)
                                } else {
                                    Log "SET CLIPBOARD FAILED (locked, will retry)"
                                    $retryPending = $true
                                }
                            }
                        }
                    }
                }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -ne $lastErr) { Log "PULL ERR: $msg"; $lastErr = $msg }
    }

    # ============ 3. Hub 中对端文件/图片 -> 本机剪贴板 ============
    if (-not $NoFiles -or -not $NoImages) {
        try {
            $ff = Get-PeerFiles
            if ($null -ne $ff) {
                $fkey = "{0}|{1}" -f $ff.LastWriteTimeUtc.Ticks, $ff.Length
                if ($fkey -ne $fileHandled) {
                    $fraw = Read-TextFile $ff.FullName
                    $fobj = $null
                    if ($fraw) { try { $fobj = $fraw | ConvertFrom-Json } catch { $fobj = $null } }

                    if ($null -eq $fobj -or -not $fobj.p) {
                        if (((Get-Date) - $lastPullLog).TotalSeconds -gt 5) {
                            Log ("FILE PULL: {0} unreadable/incomplete, retry" -f $ff.Name)
                            $lastPullLog = Get-Date
                        }
                    } else {
                        $fh2 = ([string]$fobj.h).ToLower()
                        $fid = [string]$fobj.id
                        $fts = [long]0
                        if ($fobj.ts) { try { $fts = [long]$fobj.ts } catch { $fts = 0 } }
                        $kind = 'files'
                        if ($fobj.k) { $kind = [string]$fobj.k }
                        $fileRecv = Parse-Recv (Read-TextFile $MyFRecv)

                        if ($fid -eq $LocalId) {
                            $fileHandled = $fkey
                        } elseif ($fh2 -eq $fileSig -or $fh2 -eq $fileSentH) {
                            $fileHandled = $fkey
                        } elseif ($kind -eq 'img' -and $fh2 -eq $imgSig) {
                            $fileHandled = $fkey
                        } else {
                            $isNewF = $false
                            if ($fh2 -ne $fileRecv.h) { $isNewF = $true }
                            elseif ($fts -gt $fileRecv.ts) { $isNewF = $true }

                            if (-not $isNewF) {
                                $fileHandled = $fkey
                            } else {
                                $staleF = $false
                                if ($fh2 -ne $fileRecv.h -and $StaleMinutes -gt 0) {
                                    $ageF = $null
                                    if ($fts -gt 0) { $ageF = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $fts) / 60.0 }
                                    if ($null -eq $ageF) { $ageF = ([DateTime]::UtcNow - $ff.LastWriteTimeUtc).TotalMinutes }
                                    if ($ageF -gt $StaleMinutes) { $staleF = $true }
                                }
                                if ($staleF) {
                                    $fileHandled = $fkey
                                } else {
                                    $plist = @($fobj.p | ForEach-Object { [string]$_ })
                                    $usable = @()
                                    $missing = 0
                                    foreach ($p in $plist) { if (Test-Path -LiteralPath $p) { $usable += $p } else { $missing++ } }

                                    if ($usable.Count -eq 0) {
                                        Log ("FILE PULL skipped: {0} path(s) unreachable" -f $missing)
                                        $fileHandled = $fkey
                                    } elseif ($kind -eq 'img') {
                                        # 图片：Bitmap + PNG + FileDrop 三格式一起给
                                        $pngPath = $usable[0]
                                        $pngBytes = $null
                                        try { $pngBytes = [System.IO.File]::ReadAllBytes($pngPath) } catch { $pngBytes = $null }
                                        if ($null -eq $pngBytes) {
                                            Log "IMAGE PULL: cannot read png bytes, retry"
                                        } else {
                                            if (Set-ClipImage $pngBytes $pngPath) {
                                                # 关键：记录"我方重新编码后的哈希"，否则会被判成新图回推
                                                try {
                                                    $ms = New-Object System.IO.MemoryStream(,$pngBytes)
                                                    $im2 = [System.Drawing.Image]::FromStream($ms)
                                                    $re = Convert-ImageToPng $im2
                                                    $imgSig = Get-ShaBytes $re
                                                    $im2.Dispose(); $ms.Dispose()
                                                    Write-TextFile $ImgSigFile $imgSig
                                                } catch { $imgSig = $fh2 }
                                                Write-TextFile $MyFRecv ("{0}|{1}" -f $fh2, $fts)
                                                $fileRecv = @{ h = $fh2; ts = $fts }
                                                $fileHandled = $fkey
                                                $lastSeq = Get-ClipSeq
                                                $dim = ''
                                                if ($fobj.w) { $dim = "{0}x{1} " -f $fobj.w, $fobj.ht }
                                                Log ("hub -> clipboard image: {0}{1:N1} MiB from {2}" -f $dim, ($pngBytes.Length/1MB), $ff.BaseName.ToUpper())
                                            } else {
                                                Log "IMAGE SET CLIPBOARD FAILED (locked, will retry)"
                                            }
                                        }
                                    } else {
                                        if ($missing -gt 0) { Log ("FILE PULL: {0} path(s) missing, using {1}" -f $missing, $usable.Count) }
                                        if (Set-ClipFiles $usable) {
                                            $fileSig = Get-FileSetHash $usable
                                            try { Write-TextFile $FileSigFile $fileSig } catch { }
                                            Write-TextFile $MyFRecv ("{0}|{1}" -f $fh2, $fts)
                                            $fileRecv = @{ h = $fh2; ts = $fts }
                                            $fileHandled = $fkey
                                            $lastSeq = Get-ClipSeq
                                            Log ("hub -> clipboard files: {0} item(s) from {1}" -f $usable.Count, $ff.BaseName.ToUpper())
                                        } else {
                                            Log "FILE SET CLIPBOARD FAILED (locked, will retry)"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            $msg = $_.Exception.Message
            Log ("FILE PULL ERR: {0}" -f $msg)
        }
    }

    Start-Sleep -Milliseconds $IntervalMs
}
} finally {
    Log "=== stop local=$LocalName"
    try { $instMutex.ReleaseMutex() } catch {}
    try { $instMutex.Dispose() } catch {}
}
