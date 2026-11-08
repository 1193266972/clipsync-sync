#Requires -Version 5.1
<#
  clipsync-guard.ps1 -- clipboard sync 守护器

  职责：
    * 单实例保护（named mutex），重复启动直接退出
    * 子进程 clipsync.ps1 崩溃/被杀后自动拉起（指数退避，上限 30s）
    * 自定义退出码 0xF0 = 正常停止，不会再拉起
    * 日志轮转（超过 2MB 归档为 .1）
    * 状态文件心跳，便于观察

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File clipsync-guard.ps1 -Hub '\\HUBHOST\share\clipsync'
    powershell -NoProfile -ExecutionPolicy Bypass -File clipsync-guard.ps1 -Hub '\\HUBHOST\share\clipsync' -Stop
#>
param(
    [string]$Hub,
    [string]$Peer,
    [string]$ShareName = [string]([char]0x5171 + [char]0x4EAB),
    [int]$IntervalMs = 400,
    [switch]$Stop,
    [switch]$NoGuard
)

$ErrorActionPreference = 'Stop'

$DataDir  = Join-Path $env:LOCALAPPDATA 'clipsync'
$Child    = Join-Path $PSScriptRoot 'clipsync.ps1'
$GuardLog = Join-Path $DataDir 'guard.log'
$MutexName = 'Local\clipsync_guard_' + ((("$Hub|$Peer") -replace '[^0-9A-Za-z]','_'))

if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

function Write-GuardLog([string]$m) {
    $line = "{0:yyyy-MM-dd HH:mm:ss.fff} [guard] {1}" -f (Get-Date), $m
    try { [System.IO.File]::AppendAllText($GuardLog, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false)) } catch {}
    Write-Host $line
}

function Rotate([string]$path, [int]$maxBytes = 2MB) {
    if (Test-Path -LiteralPath $path) {
        $f = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt $maxBytes) {
            $archive = "$path.1"
            Remove-Item $archive -Force -ErrorAction SilentlyContinue
            try { Move-Item $path $archive -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# ---------------- Stop 模式 ----------------
if ($Stop) {
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'clipsync(-guard)?\.ps1' -and $_.CommandLine -notmatch '-NonInteractive' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++; Write-GuardLog "stopped PID $($_.ProcessId)" } catch {}
        }
    Write-GuardLog "stop complete, killed=$killed"
    return
}

# ---------------- 单实例 ----------------
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
try {
    $acquired = $mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}
if (-not $acquired) {
    Write-GuardLog "another guard is already running for peer=$Peer, exit"
    return
}
Write-GuardLog "mutex acquired hub=$Hub peer=$Peer share=$ShareName interval=${IntervalMs}ms"

# 确保子脚本存在且完好
if (-not (Test-Path -LiteralPath $Child)) {
    Write-GuardLog "FATAL child script missing: $Child"
    $mutex.ReleaseMutex(); return
}
$childLen = (Get-Item -LiteralPath $Child).Length
if ($childLen -lt 3000) {
    Write-GuardLog "FATAL child script suspiciously small: $childLen bytes"
    $mutex.ReleaseMutex(); return
}
Write-GuardLog "child script ok ($childLen bytes)"

$backoff = 2
$maxBackoff = 30
$startCount = 0

try {
    while ($true) {
        Rotate $GuardLog
        Rotate (Join-Path $DataDir 'clipsync.log')

        $startCount++
        $childArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass',
            '-File',('"{0}"' -f $Child),
            '-ShareName',('"{0}"' -f $ShareName),
            '-IntervalMs',$IntervalMs
        )
        if ($Hub)  { $childArgs += @('-Hub', ('"{0}"' -f $Hub)) }
        if ($Peer) { $childArgs += @('-Peer', ('"{0}"' -f $Peer)) }
        Write-GuardLog "starting child (attempt #$startCount)"
        $t0 = Get-Date
        try {
            $p = Start-Process powershell -ArgumentList $childArgs -WindowStyle Hidden -PassThru -ErrorAction Stop
        } catch {
            Write-GuardLog "spawn failed: $($_.Exception.Message)"
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, $maxBackoff)
            continue
        }
        Write-GuardLog "child PID=$($p.Id)"

        $p.WaitForExit()
        $code = $p.ExitCode
        $ran = ((Get-Date) - $t0).TotalSeconds
        Write-GuardLog ("child exited code=$code after {0:N1}s" -f $ran)

        if ($code -eq 240) { Write-GuardLog "child requested clean stop, guard exiting"; break }

        # 稳定运行超过 60 秒则重置退避
        if ($ran -gt 60) { $backoff = 2 }
        Write-GuardLog "restarting in ${backoff}s"
        Start-Sleep -Seconds $backoff
        $backoff = [Math]::Min($backoff * 2, $maxBackoff)
    }
} finally {
    Write-GuardLog "guard loop ended"
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}
