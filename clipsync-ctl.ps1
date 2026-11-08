#Requires -Version 5.1
<#
  clipsync-ctl.ps1 -- clipsync control entry

  Actions:
    install | start | stop | status | log | selftest | uninstall | autostart-on | autostart-off

  Hub protocol v2: both machines read/write ONE rendezvous folder.
    161: -Hub 'D:\<share>\clipsync'                  (local, fast)
    246: -Hub '\\HUBHOST\<share>\clipsync'    (same folder, over SMB)
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('install','start','stop','status','log','selftest','uninstall','autostart-on','autostart-off')]
    [string]$Action,
    [string]$Hub  = '',
    [string]$Peer = '',
    [string]$ShareName = ''
)

$ErrorActionPreference = 'Continue'

$Share  = [string]([char]0x5171 + [char]0x4EAB)      # 共享
if (-not $ShareName) { $ShareName = $Share }
if (-not $Hub) {
    if ($Peer) { $Hub = "\\$Peer\$ShareName\clipsync" }
    else       { $Hub = 'D:\' + $Share + '\clipsync' }
}

$Dir      = 'C:\clipsync'
$DataDir  = Join-Path $env:LOCALAPPDATA 'clipsync'
$Child    = Join-Path $Dir 'clipsync.ps1'
$Guard    = Join-Path $Dir 'clipsync-guard.ps1'
$Log      = Join-Path $DataDir 'clipsync.log'
$GLog     = Join-Path $DataDir 'guard.log'
$TaskName = 'clipsync-guard'
$SelfName = $env:COMPUTERNAME.ToUpper()

function Say {
    param([string]$m,[string]$c = 'Gray')
    Write-Host $m -ForegroundColor $c
}

function Get-Instances {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'clipsync(-guard)?\.ps1' -and
            $_.CommandLine -notmatch '-NonInteractive'
        }
}

function Do-Install {
    Say ("=== install to {0} ===" -f $Dir) Cyan
    New-Item -ItemType Directory $Dir -Force | Out-Null
    New-Item -ItemType Directory $DataDir -Force | Out-Null
    foreach($n in @('clipsync.ps1','clipsync-guard.ps1','clipsync-ctl.ps1')){
        $src = Join-Path $PSScriptRoot $n
        $dst = Join-Path $Dir $n
        if($src -ne $dst -and (Test-Path -LiteralPath $src)){
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
    foreach($f in @($Child,$Guard)){
        if(Test-Path -LiteralPath $f){
            $len = (Get-Item -LiteralPath $f).Length
            $b = [System.IO.File]::ReadAllBytes($f)
            $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
            $nm = Split-Path $f -Leaf
            Say ("  {0,-24} {1,6} bytes  BOM={2}" -f $nm,$len,$bom)
        } else {
            Say ("  MISSING: {0}" -f $f) Red
        }
    }
    Say "install done" Green
}

function Do-Stop {
    Say "=== stop ===" Cyan
    $inst = @(Get-Instances)
    if($inst.Count -eq 0){ Say "no running instance" Yellow; return }
    foreach($p in $inst){
        if($p.CommandLine -match 'guard'){
            Say ("  stop GUARD PID {0}" -f $p.ProcessId)
            if(Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue){
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Sleep -Milliseconds 800
    foreach($p in @(Get-Instances)){
        Say ("  stop CHILD PID {0}" -f $p.ProcessId)
        if(Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue){
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 600
    $left = @(Get-Instances)
    if($left.Count -gt 0){
        Say "still alive:" Red
        foreach($p in $left){ Say ("  PID {0}" -f $p.ProcessId) }
    } else {
        Say "all stopped" Green
    }
}

function Do-Start {
    Say ("=== start (hub={0}) ===" -f $Hub) Cyan
    if(@(Get-Instances).Count -gt 0){
        Say "existing instance found, stopping first" Yellow
        Do-Stop
    }
    if(-not (Test-Path -LiteralPath $Guard)){
        Say ("missing {0}, run -Action install" -f $Guard) Red
        return
    }
    if(-not (Test-Path -LiteralPath $Hub)){
        try { New-Item -ItemType Directory -Path $Hub -Force -ErrorAction Stop | Out-Null } catch { Say ("cannot create hub: {0}" -f $_.Exception.Message) Red }
    }
    # drop stale own state so history clipboard is not pushed
    if(Test-Path -LiteralPath $Hub){
        Remove-Item -LiteralPath (Join-Path $Hub ($SelfName + '.clip')) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $Hub ($SelfName + '.seen')) -Force -ErrorAction SilentlyContinue
    }
    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
        '-File',('"{0}"' -f $Guard),
        '-Hub',('"{0}"' -f $Hub),
        '-ShareName',('"{0}"' -f $ShareName)
    )
    Start-Process powershell -ArgumentList $argList -WindowStyle Hidden
    Start-Sleep -Seconds 4
    $inst = @(Get-Instances)
    if($inst.Count -gt 0){
        Say "started:" Green
        foreach($p in $inst){
            $role = 'CHILD'
            if($p.CommandLine -match 'guard'){ $role = 'GUARD' }
            Say ("  {0,-6} PID {1}" -f $role,$p.ProcessId)
        }
    } else {
        Say "start FAILED, no process" Red
    }
    if(Test-Path -LiteralPath $GLog){
        Say "=== guard.log tail ===" DarkGray
        Get-Content -LiteralPath $GLog -Encoding UTF8 -Tail 8
    }
}

function Do-Status {
    Say "=== status ===" Cyan
    Say ("host : {0}" -f $env:COMPUTERNAME)
    Say ("dir  : {0}" -f $Dir)
    Say ("data : {0}" -f $DataDir)
    Say ("hub  : {0}" -f $Hub)
    Say ""
    Say "=== processes ===" Yellow
    $inst = @(Get-Instances)
    if($inst.Count -gt 0){
        foreach($p in $inst){
            $role = 'CHILD'
            if($p.CommandLine -match 'guard'){ $role = 'GUARD' }
            Say ("  {0,-6} PID {1,-6} start {2}" -f $role,$p.ProcessId,$p.CreationDate)
        }
    } else {
        Say "  none" Red
    }
    Say ""
    Say "=== logs ===" Yellow
    $logPairs = @()
    $logPairs += ,@($Log,'clipsync.log')
    $logPairs += ,@($GLog,'guard.log')
    foreach($pair in $logPairs){
        $path = $pair[0]
        $nm   = $pair[1]
        if(Test-Path -LiteralPath $path){
            $i = Get-Item -LiteralPath $path
            Say ("  {0,-14} {1,8} bytes  mtime {2}" -f $nm,$i.Length,$i.LastWriteTime)
        } else {
            Say ("  {0,-14} missing" -f $nm)
        }
    }
    Say ""
    Say "=== hub state files ===" Yellow
    if(Test-Path -LiteralPath $Hub){
        $sf = @(Get-ChildItem -LiteralPath $Hub -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.clip','.seen','.recv' } |
                Sort-Object Name)
        foreach($f in $sf){
            Say ("    {0,-24} {1,6}B  {2}" -f $f.Name,$f.Length,$f.LastWriteTime)
        }
        if($sf.Count -eq 0){ Say "    (none)" DarkGray }
    } else {
        Say "    hub unreachable" Red
    }
    Say ""
    Say "=== scheduled task ===" Yellow
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if($t){ Say ("  {0} : {1}" -f $t.TaskName,$t.State) Green } else { Say "  not registered" DarkGray }
}

function Do-Log {
    Say "=== clipsync.log tail 30 ===" Cyan
    if(Test-Path -LiteralPath $Log){ Get-Content -LiteralPath $Log -Encoding UTF8 -Tail 30 } else { Say "no log" Yellow }
    Say ""
    Say "=== guard.log tail 15 ===" Cyan
    if(Test-Path -LiteralPath $GLog){ Get-Content -LiteralPath $GLog -Encoding UTF8 -Tail 15 } else { Say "no log" Yellow }
}

function Do-Selftest {
    Say ("=== selftest (hub={0}) ===" -f $Hub) Cyan
    if(-not (Test-Path -LiteralPath $Hub)){
        Say "hub unreachable" Red
        return
    }
    $all = @(Get-ChildItem -LiteralPath $Hub -Force -ErrorAction SilentlyContinue)
    foreach($f in $all){
        Say ("    {0,-24} {1,6}B  {2}" -f $f.Name,$f.Length,$f.LastWriteTime)
    }

    Add-Type -AssemblyName System.Windows.Forms
    $marker = "CLIPSYNC-SELFTEST-$SelfName-" + (Get-Date -Format 'HHmmss')
    Say ("set clipboard: {0}" -f $marker)
    $dp = New-Object System.Windows.Forms.DataObject
    $dp.SetData([System.Windows.Forms.DataFormats]::UnicodeText,$false,$marker)
    [System.Windows.Forms.Clipboard]::SetDataObject($dp,$true)
    Start-Sleep -Seconds 3

    $myClip = Join-Path $Hub ($SelfName + '.clip')
    if(Test-Path -LiteralPath $myClip){
        try{
            $o = Get-Content -LiteralPath $myClip -Raw -Encoding UTF8 | ConvertFrom-Json
            $t = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($o.t))
            Say ("  own .clip text: {0}" -f $t)
            if($t -eq $marker){ Say "  push path: OK" Green } else { Say "  push path: MISMATCH" Yellow }
        } catch {
            Say ("  .clip parse failed: {0}" -f $_.Exception.Message) Red
        }
    } else {
        Say "  push path: own .clip not created (process down?)" Red
    }

    $peerFiles = @(Get-ChildItem -LiteralPath $Hub -Filter '*.clip' -ErrorAction SilentlyContinue |
                   Where-Object { $_.BaseName.ToUpper() -ne $SelfName })
    if($peerFiles.Count -gt 0){
        Say ("  peer .clip: {0} ({1})" -f $peerFiles[0].Name,$peerFiles[0].LastWriteTime) Green
    } else {
        Say "  peer .clip: none yet" Red
    }
}

function Do-AutostartOn {
    Say "=== register autostart task ===" Cyan
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Guard`" -Hub `"$Hub`" -ShareName `"$ShareName`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    $pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Description 'Cross-machine clipboard sync' | Out-Null
    Say ("registered {0}" -f $TaskName) Green
}

function Do-AutostartOff {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Say ("removed {0}" -f $TaskName) Green
}

function Do-Uninstall {
    Say "=== uninstall ===" Cyan
    Do-Stop
    Do-AutostartOff
    Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Say ("removed {0}" -f $Dir) Green
}

switch ($Action) {
    'install'       { Do-Install }
    'start'         { Do-Start }
    'stop'          { Do-Stop }
    'status'        { Do-Status }
    'log'           { Do-Log }
    'selftest'      { Do-Selftest }
    'autostart-on'  { Do-AutostartOn }
    'autostart-off' { Do-AutostartOff }
    'uninstall'     { Do-Uninstall }
}
