#Requires -Version 5.1
<#
.SYNOPSIS
  Puts the patch back after Stremio updates itself. scripts\stremio-autopatch.lua starts it with
  -WaitPid when Stremio starts, so it sleeps until Stremio's process ends; the scheduled task from
  tools\autopatch-task.ps1 runs it once at logon. Safe to run by hand.

.DESCRIPTION
  A quick check, a few file hashes: nothing happens while Stremio's exe and libmpv-2.dll are the ones
  recorded in state.json, the repo's scripts match the installed ones and cacert.pem is less than 7
  days old. Otherwise it runs install.ps1 -Yes -Unattended -NoLaunch -NeverClose -NoAutoPatch.

  With -WaitPid it first waits for that process (Stremio) to exit and for Stremio's updater to
  finish. It never closes Stremio: if Stremio updated itself and is running (the updater often starts
  the new version), it says so once with a notification and waits for it to close, then patches.
  Before a re-patch it waits for the network (up to 30 minutes, for a logon before Wi-Fi is up), and
  a failed one is tried again up to 3 times, 15 minutes apart or when Stremio closes. Nothing stays
  running otherwise. Without state.json (never installed, or undone with restore.cmd) it does
  nothing. Each action is logged to autopatch.log in the build folder; no links or keys are ever
  written there.

.PARAMETER WorkDir    Build folder (default %USERPROFILE%\stremio-mpv-build)
.PARAMETER ConfigDir  The player's config folder (default %APPDATA%\stremio-mpv)
.PARAMETER CheckOnly  Only print what it would do
.PARAMETER Quiet      No notifications
.PARAMETER WaitPid    Wait for this process to exit first (Stremio's, from the player script)
#>
param(
    [string]$WorkDir = "$env:USERPROFILE\stremio-mpv-build",
    [string]$ConfigDir = (Join-Path $env:APPDATA 'stremio-mpv'),
    [switch]$CheckOnly,
    [switch]$Quiet,
    [int]$WaitPid
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Scripts = 'original-tracks.lua', 'stream-watchdog.lua', 'stremio-autopatch.lua'
$CaMaxAge = New-TimeSpan -Days 7
$Retries = 3
$RetryWait = 900
$LogPath = Join-Path $WorkDir 'autopatch.log'
$NotePath = Join-Path $WorkDir 'autopatch-notified.txt'

function Log([string]$t) {
    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $t
    Write-Host $line
    if ($CheckOnly) { return }
    try {
        # keep the log small: the last ~500 lines
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 200KB) {
            $keep = Get-Content -LiteralPath $LogPath -Tail 500
            Set-Content -LiteralPath $LogPath -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

# an empty file (cut short by a shutdown) reads as '', not as an error
function Read-Text([string]$path) {
    if (Test-Path -LiteralPath $path) { return "$(Get-Content -LiteralPath $path -Raw)".Trim() }
    return ''
}

# a whole new file swapped in, so a shutdown leaves the old or the new one, never half of it
function Write-TextAtomic([string]$path, [string]$text) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

# one notification per situation (key), not one every time stremio closes
function Notify([string]$key, [string]$title, [string]$text) {
    if ($Quiet -or $CheckOnly) { return }
    if ((Read-Text $NotePath) -eq $key) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(15000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep 10
        $n.Dispose()
        # remembered only once shown, so a notification that failed is tried again next time
        Write-TextAtomic $NotePath $key
    } catch { Log "couldn't show a notification: $($_.Exception.Message)" }
}

function Test-Official([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $s = Get-AuthenticodeSignature -LiteralPath $path
    return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -like 'CN=Smart Code OOD*')
}

function Get-Hash([string]$path) {
    if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path).Hash } else { '' }
}

# size and modification time: enough to notice that stremio replaced a file, without reading ~100 MB
function Get-Stamp([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $i = Get-Item -LiteralPath $path
    return "$($i.Length)/$($i.LastWriteTimeUtc.Ticks)"
}

function Get-StremioDir($state) {
    $dir = $state.stremioDir
    if (-not $dir) {
        $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{DD3870DA-AF3C-4C73-B010-72944AB610C6}_is1' -ErrorAction SilentlyContinue
        $dir = if ($reg -and $reg.InstallLocation) { $reg.InstallLocation } else { "$env:LOCALAPPDATA\Programs\Stremio" }
    }
    return $dir.TrimEnd('\')
}

# while it waits it needs no cpu and almost no memory: idle priority, and the working set handed back.
# back to below normal before working, since install.ps1, cargo and csc inherit the priority
function Enter-Sleep {
    try {
        $me = [Diagnostics.Process]::GetCurrentProcess()
        $me.PriorityClass = 'Idle'
        [GC]::Collect()
        $me.MaxWorkingSet = $me.MinWorkingSet
    } catch { }
}
function Exit-Sleep {
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
}

function Get-StremioProcesses([string]$dir) {
    $prefix = $dir + '\'
    @(Get-Process stremio-shell-ng, stremio-runtime -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# stremio's updater is an inno setup installer: it runs from a %TEMP%\is-*.tmp folder, or as an
# uninstaller in stremio's folder. waits (up to 10 minutes) until none is running
function Wait-Updater([string]$dir) {
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and ($_.Path -match '\\is-[0-9a-z]+\.tmp\\' -or
                ($_.Path.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase) -and $_.Name -like 'unins*') -or
                $_.Name -match 'stremio.*setup|setup.*stremio') })
        if (-not $busy) { return }
        Start-Sleep 3
    } while ((Get-Date) -lt $deadline)
}

# at logon wi-fi may not be up yet; install.ps1 needs github
function Wait-Network {
    for ($i = 0; $i -lt 60; $i++) {
        try { $null = [Net.Dns]::GetHostAddresses('github.com'); return $true } catch { Start-Sleep 30 }
    }
    return $false
}

$waitLock = $null
$mutex = $null
try {
    if ($WaitPid) {
        # one waiter per stremio process. the shared lock below is taken only once stremio has ended,
        # so a stremio opened while another check runs still gets its own waiter
        $waitLock = New-Object Threading.Mutex($false, "Local\StremioMPV-Relay-wait-$WaitPid")
        if (-not $waitLock.WaitOne(0)) { $waitLock.Dispose(); $waitLock = $null; return }
        Enter-Sleep
        try { Wait-Process -Id $WaitPid -ErrorAction Stop } catch { }
        Start-Sleep 2
    }
    Exit-Sleep
    # one check at a time; a check that only prints needs no lock
    if (-not $CheckOnly) {
        $mutex = New-Object Threading.Mutex($false, 'Local\StremioMPV-Relay-autopatch')
        try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }
    }

    $attempt = 0
    :check while ($true) {
        $stateFile = Join-Path $WorkDir 'state.json'
        $stateRaw = Read-Text $stateFile
        if (-not $stateRaw) {
            if ($CheckOnly) { Log 'no state.json: not installed (or restored), nothing to do' }
            return
        }
        $state = $stateRaw | ConvertFrom-Json

        $stremioDir = Get-StremioDir $state
        if ($WaitPid -and -not $CheckOnly) { Wait-Updater $stremioDir }
        $exe = Join-Path $stremioDir 'stremio-shell-ng.exe'
        $dll = Join-Path $stremioDir 'libmpv-2.dll'
        if (-not (Test-Path -LiteralPath $exe)) {
            Log "Stremio not found at ${stremioDir}: nothing to do"
            return
        }
        $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion

        # the files are hashed only when their size or date changed since the last run that found them patched
        $stampPath = Join-Path $WorkDir 'autopatch-stamp.txt'
        $stamp = (Get-Stamp $exe) + '|' + (Get-Stamp $dll) + '|' + $state.exeHash + '|' + $state.dllHash
        $needPatch = $false
        if ((Read-Text $stampPath) -ne $stamp) {
            $needPatch = (Get-Hash $exe) -ne $state.exeHash -or (Get-Hash $dll) -ne $state.dllHash
            if (-not $needPatch -and -not $CheckOnly) { Write-TextAtomic $stampPath $stamp }
        }
        $why = @()
        if ($needPatch) { $why += "Stremio $ver isn't patched (it updated itself, or its files were replaced)" }
        # an install made with -MpvTag latest/<tag> -AllowUnpinned keeps its libmpv
        $pin = Get-Content -LiteralPath (Join-Path $Repo 'config\mpv-pin.json') -Raw | ConvertFrom-Json
        if (-not $needPatch -and $state.pinned -ne $false -and $state.mpvTag -ne $pin.tag) {
            $needPatch = $true
            $why += "the repo pins libmpv $($pin.tag), installed is $($state.mpvTag)"
        }
        foreach ($s in $Scripts) {
            if ((Get-Hash (Join-Path $Repo "config\scripts\$s")) -ne (Get-Hash (Join-Path $ConfigDir "scripts\$s"))) { $why += "scripts\$s differs from the repo" }
        }
        $relaySrc = Join-Path $Repo 'tools\relay\relay.cs'
        if (Test-Path -LiteralPath $relaySrc) {
            $built = if (Test-Path -LiteralPath (Join-Path $ConfigDir 'relay\relay.exe')) { Read-Text (Join-Path $ConfigDir 'relay\relay.cs.sha256') } else { '' }
            if ($built -ne (Get-Hash $relaySrc)) { $why += 'relay\relay.exe is missing or older than the repo' }
        }
        $ca = Join-Path $ConfigDir 'cacert.pem'
        if (-not (Test-Path -LiteralPath $ca)) { $why += 'cacert.pem is missing' }
        elseif ((Get-Date) - (Get-Item -LiteralPath $ca).LastWriteTime -gt $CaMaxAge) { $why += 'cacert.pem is more than 7 days old' }
        if (-not $why) {
            if ($CheckOnly) { Log 'everything is in place, nothing to do' }
            return
        }

        if ($needPatch -and (Get-Hash $exe) -ne $state.exeHash -and -not (Test-Official $exe)) {
            # neither the official file nor ours: a fork or a manual build; install.ps1 would refuse anyway
            Log "stremio-shell-ng.exe is neither Stremio's signed original nor the patched one in state.json; leaving it alone"
            Notify "foreign-$ver" 'StremioMPV Relay' "Stremio's exe was replaced by something else, so the patch wasn't put back. Run install.cmd to see why."
            return
        }

        $running = Get-StremioProcesses $stremioDir
        if ($needPatch -and $running) {
            Log "Stremio $ver needs the patch again but is running: waiting until it's closed"
            Notify "running-$ver" 'StremioMPV Relay' "Stremio updated to $ver. When you finish watching, quit it (right-click its icon next to the clock, Quit) and the fixes go back on by themselves."
            if ($CheckOnly) { return }
            # the unpatched stremio can't start this script, so this run waits for it
            Enter-Sleep
            $running | Wait-Process -ErrorAction SilentlyContinue
            Start-Sleep 2
            Exit-Sleep
            Wait-Updater $stremioDir
            continue check
        }

        Log ('running install.ps1: ' + ($why -join '; '))
        if ($CheckOnly) { return }
        if ($needPatch -and -not (Wait-Network)) {
            Log 'no network for 30 minutes: not patching now'
            Notify "offline-$ver" 'StremioMPV Relay' "Stremio $ver needs the patch again, but there was no internet connection. It will be tried at the next logon, or run install.cmd."
            return
        }
        # restore.cmd may have run in the meantime
        if ((Read-Text $stateFile) -ne $stateRaw) { continue check }

        $installLog = Join-Path $WorkDir 'autopatch-install.log'
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'install.ps1'),
                  '-Yes', '-Unattended', '-NoLaunch', '-NeverClose', '-NoAutoPatch', '-WorkDir', $WorkDir, '-StremioDir', $stremioDir)
        if ($state.pinned -eq $false -and $state.mpvTag) { $argv += @('-MpvTag', [string]$state.mpvTag, '-AllowUnpinned') }
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = @(& $ps @argv 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        Set-Content -LiteralPath $installLog -Value $out -Encoding UTF8
        if ($code -eq 0 -and ($out -match '^DONE$')) {
            Log "install.ps1 finished (Stremio $ver)"
            if ($needPatch) { Notify "patched-$ver" 'StremioMPV Relay' "Stremio $ver is patched again: original tracks, reconnects and the slow-connection fix are back." }
            return
        }
        $err = ($out | Where-Object { $_ -match '^ERROR: ' } | Select-Object -Last 1) -replace '^ERROR: ', ''
        if (-not $err) { $err = "exit code $code" }
        Log "install.ps1 failed: $err (full output in $installLog)"
        if ($err -match 'Stremio is running') { continue check }   # opened during the build: wait for it to close
        if ($err -match 'No state\.json') { return }               # restored meanwhile
        if ($needPatch -and $attempt -lt $Retries) {
            # a github or network hiccup, a tag not published yet, a file in use: later, or once stremio closes
            $attempt++
            $running = Get-StremioProcesses $stremioDir
            Log "trying again $(if ($running) { 'when Stremio closes' } else { "in $($RetryWait / 60) minutes" }) ($attempt of $Retries)"
            Enter-Sleep
            if ($running) { $running | Wait-Process -ErrorAction SilentlyContinue; Start-Sleep 2 } else { Start-Sleep $RetryWait }
            Exit-Sleep
            continue check
        }
        Notify "failed-$ver-$err" 'StremioMPV Relay' "Couldn't patch Stremio $ver again: $err Stremio still works, without the fixes. Run install.cmd to see more."
        return
    }
} catch {
    Log "error: $($_.Exception.Message)"
} finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
    if ($waitLock) { try { $waitLock.ReleaseMutex() } catch { }; $waitLock.Dispose() }
}
