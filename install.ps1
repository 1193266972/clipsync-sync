<#
  install.ps1 -- clipsync 一键部署器

  用途：把剪贴板同步装到一台新 Windows 机器上，一条命令搞定。
  设计原则：脚本从共享目录里跑，自己就知道 Hub 在哪。

  用法：

    方式 A（推荐）：新机器上直接跑共享里的安装器
        powershell -NoProfile -ExecutionPolicy Bypass -File "\\HOST\共享\clipsync\install.ps1"

        Hub 自动取 $PSScriptRoot（也就是这个共享目录本身）。

    方式 B：本机路径运行，显式指定 Hub
        .\install.ps1 -Hub '\\HUBHOST\共享\clipsync'

    可选参数：
        -Hub <路径>        显式指定汇合点
        -NoAutostart       不注册开机自启
        -SkipStart         只装不启动
        -Force             跳过校验和比对（脚本被改过时用）
        -NoElevate         不以管理员重启（仅调试用）

  它会做：
    1) 提权检查，非管理员自动重启自己
    2) 确定 Hub
    3) 校验三个脚本的大小与 SHA256（比对同目录 checksums.txt）
    4) 复制到 C:\clipsync，缺 BOM 自动补
    5) 语法检查
    6) 停掉旧实例
    7) 用指定 Hub 启动
    8) 注册登录自启（可关）
    9) 打印状态与验证方法
#>
param(
    [string]$Hub = '',
    [switch]$NoAutostart,
    [switch]$SkipStart,
    [switch]$Force,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

$share = [string]([char]0x5171 + [char]0x4EAB)   # 共享
$InstallerDir = $PSScriptRoot
if (-not $InstallerDir) { $InstallerDir = (Get-Location).Path }

# 若安装器放在 <Hub>\deploy\ 下，Hub 取上一级
function Get-HubFromInstallerDir([string]$d) {
    $leaf = (Split-Path $d -Leaf)
    if ($leaf -ieq 'deploy') { return (Split-Path $d -Parent) }
    return $d
}

function Say {
    param([string]$m,[string]$c = 'Gray')
    Write-Host $m -ForegroundColor $c
}

# ---------- 0. 提权 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    Say "需要管理员权限，正在重新以管理员启动..." Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    if ($Hub) { $a += @('-Hub', ('"{0}"' -f $Hub)) }
    if ($NoAutostart) { $a += '-NoAutostart' }
    if ($SkipStart)   { $a += '-SkipStart' }
    if ($Force)       { $a += '-Force' }
    Start-Process powershell -Verb RunAs -ArgumentList $a
    return
}

Say "========================================" Cyan
Say " clipsync 一键部署" Cyan
Say "========================================" Cyan
Say ("  安装器目录 : {0}" -f $InstallerDir)
Say ("  计算机名   : {0}" -f $env:COMPUTERNAME)
Say ""

# ---------- 1. 确定 Hub ----------
$cand = Get-HubFromInstallerDir $InstallerDir
if (-not $Hub) {
    if ($cand -like '\\*') {
        $Hub = $cand
        Say ("Hub 自动取安装器所在共享: {0}" -f $Hub) Green
    } else {
        # 本地目录跑：若该目录看起来就是 hub（含 .clip/.recv 或 files 子目录），沿用它
        $looksLikeHub = $false
        if (Test-Path -LiteralPath (Join-Path $cand 'files')) { $looksLikeHub = $true }
        elseif (@(Get-ChildItem -LiteralPath $cand -Filter '*.clip' -File -ErrorAction SilentlyContinue).Count -gt 0) { $looksLikeHub = $true }
        if ($looksLikeHub) {
            $Hub = $cand
            Say ("Hub 取安装器所在目录（看起来就是汇合点）: {0}" -f $Hub) Green
        } else {
            Say "无法自动判断 Hub。请用 -Hub 指定，例如:" Red
            Say ("  .\install.ps1 -Hub '\\HUBHOST\{0}\clipsync'" -f $share) Red
            throw "Hub not specified"
        }
    }
}
$Hub = $Hub.TrimEnd('\')
Say ("  Hub        : {0}" -f $Hub)

if (-not (Test-Path -LiteralPath $Hub)) {
    Say ("Hub 不可访问，尝试创建: {0}" -f $Hub) Yellow
    try { New-Item -ItemType Directory -Path $Hub -Force | Out-Null } catch { throw "cannot create hub: $($_.Exception.Message)" }
}
# 写权限探测（要能建 staging）
$probe = Join-Path $Hub ('.wtest_' + [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    [System.IO.File]::WriteAllText($probe, 'x')
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Say "  Hub 可写   : True" Green
} catch {
    Say ("  Hub 可写   : False -> {0}" -f $_.Exception.Message) Red
    throw "hub not writable"
}
Say ""

# ---------- 2. 准备源脚本 ----------
$names = @('clipsync.ps1','clipsync-guard.ps1','clipsync-ctl.ps1')
$src = @{}
foreach ($n in $names) {
    $p = Join-Path $InstallerDir $n
    if (-not (Test-Path -LiteralPath $p)) { throw "missing source script: $p" }
    $src[$n] = $p
}

# ---------- 3. 校验和 ----------
Say "=== [1/7] 校验源文件 ===" Cyan
$ckPath = Join-Path $InstallerDir 'checksums.txt'
$expect = @{}
if (Test-Path -LiteralPath $ckPath) {
    foreach ($line in Get-Content -LiteralPath $ckPath -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t.Split('|')
        if ($parts.Count -ge 3) {
            $expect[$parts[0].Trim()] = @{ size = [long]$parts[1].Trim(); hash = $parts[2].Trim().ToUpper() }
        }
    }
}
$ckFail = 0
foreach ($n in $names) {
    $p = $src[$n]
    $i = Get-Item -LiteralPath $p
    $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpper()
    $b = [System.IO.File]::ReadAllBytes($p)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $okSize = $true; $okHash = $true
    if ($expect.ContainsKey($n)) {
        $okSize = ($i.Length -eq $expect[$n].size)
        $okHash = ($h -eq $expect[$n].hash)
    }
    $flag = 'OK'
    if (-not ($okSize -and $okHash -and $bom)) { $flag = 'WARN' }
    if ($flag -eq 'WARN') { $ckFail++ }
    Say ("  {0,-22} {1,6}B BOM={2,-5} size={3,-5} hash={4,-5} {5}" -f $n, $i.Length, $bom, $okSize, $okHash, $flag) $(if($flag -eq 'OK'){'Green'}else{'Yellow'})
}
if ($ckFail -gt 0 -and -not $Force) {
    Say "  校验未全部通过。若确认脚本可信，加 -Force 继续。" Red
    throw "checksum mismatch"
}
Say ""

# ---------- 4. 复制 + 补 BOM ----------
Say "=== [2/7] 安装到 C:\clipsync ===" Cyan
$dstDir = 'C:\clipsync'
New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
$utf8bom = New-Object System.Text.UTF8Encoding $true
foreach ($n in $names) {
    $target = Join-Path $dstDir $n
    Copy-Item -LiteralPath $src[$n] -Destination $target -Force
    $b = [System.IO.File]::ReadAllBytes($target)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF)
    if (-not $hasBom) {
        [System.IO.File]::WriteAllText($target, [System.Text.Encoding]::UTF8.GetString($b), $utf8bom)
        Say ("  {0} 已补 UTF-8 BOM" -f $n) Yellow
    }
    Say ("  {0,-22} {1,6}B" -f $n, (Get-Item -LiteralPath $target).Length)
}
Say ""

# ---------- 5. 语法检查 ----------
Say "=== [3/7] 语法检查 ===" Cyan
foreach ($n in $names) {
    $p = Join-Path $dstDir $n
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in $errs) { Say ("  {0} 行{1}: {2}" -f $n, $e.Extent.StartLineNumber, $e.Message) Red }
        throw "syntax errors in $n"
    }
    Say ("  {0,-22} OK" -f $n) Green
}
Say ""

# ---------- 6. 停旧实例 ----------
Say "=== [4/7] 停止旧实例 ===" Cyan
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'clipsync(-guard)?\.ps1' -and $_.CommandLine -notmatch '-NonInteractive' } |
    ForEach-Object {
        try {
            if (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                $killed++
            }
        } catch { }
    }
Say ("  已停止 {0} 个进程" -f $killed) $(if($killed -gt 0){'Green'}else{'Gray'})
Start-Sleep -Milliseconds 800
Say ""

if ($SkipStart) {
    Say "已指定 -SkipStart，安装完成但未启动。" Yellow
    return
}

# ---------- 7. 启动 ----------
Say "=== [5/7] 启动 ===" Cyan
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$guard = Join-Path $dstDir 'clipsync-guard.ps1'
$childArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
    '-File',('"{0}"' -f $guard),
    '-Hub',('"{0}"' -f $Hub),
    '-ShareName',('"{0}"' -f $share)
)
Start-Process powershell -ArgumentList $childArgs -WindowStyle Hidden
Start-Sleep -Seconds 4

$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -match 'clipsync(-guard)?\.ps1' -and $_.CommandLine -notmatch '-NonInteractive' })
if ($running.Count -gt 0) {
    foreach ($p in $running) {
        $role = 'CHILD'
        if ($p.CommandLine -match 'guard') { $role = 'GUARD' }
        Say ("  {0,-6} PID {1}" -f $role, $p.ProcessId) Green
    }
} else {
    Say "  启动失败，无进程。请看 %LOCALAPPDATA%\clipsync\guard.log" Red
}
Say ""

# ---------- 8. 自启 ----------
Say "=== [6/7] 开机自启 ===" Cyan
if ($NoAutostart) {
    Say "  已指定 -NoAutostart，跳过" Yellow
} else {
    $taskName = 'clipsync-guard'
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guard`" -Hub `"$Hub`" -ShareName `"$share`""
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        $pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Description 'Cross-machine clipboard sync' | Out-Null
        Say ("  已注册 {0}（登录时拉起，账户 {1}）" -f $taskName, $env:USERNAME) Green
    } catch {
        Say ("  注册失败: {0}" -f $_.Exception.Message) Red
    }
}
Say ""

# ---------- 9. 汇总 ----------
Say "=== [7/7] 汇总 ===" Cyan
Say ("  机器        : {0}" -f $env:COMPUTERNAME)
Say ("  Hub         : {0}" -f $Hub)
Say ("  脚本目录    : {0}" -f $dstDir)
Say ("  日志        : {0}" -f (Join-Path $env:LOCALAPPDATA 'clipsync\clipsync.log'))
$logPath = Join-Path $env:LOCALAPPDATA 'clipsync\clipsync.log'
if (Test-Path -LiteralPath $logPath) {
    Say "  --- 日志尾部 ---" DarkGray
    Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 8 | ForEach-Object { Say ("    " + $_) }
}
Say ""
Say "验证方法：" Cyan
Say "  1) 本机复制一段文字，到另一台 Ctrl+V"
Say "  2) 本机截图后 Ctrl+V 到另一台（应直接出图）"
Say "  3) 本机复制文件，到另一台资源管理器粘贴"
Say ""
Say "日常运维：" Cyan
Say ("  cd {0}" -f $dstDir)
Say "  .\clipsync-ctl.ps1 -Action status -Hub '<Hub>'"
Say "  .\clipsync-ctl.ps1 -Action log"
Say "  .\clipsync-ctl.ps1 -Action stop"
Say ""
Say "部署完成。" Green
