#Requires -Version 5.1
<#
.SYNOPSIS
  Patches your local Stremio (Windows desktop, stremio-shell-ng) so its built-in player loads your own
  mpv config and scripts from %APPDATA%\stremio-mpv, and swaps in a newer libmpv build.

.DESCRIPTION
  Nothing from Stremio or mpv is redistributed. The script clones Stremio's source for the exact version
  you have installed, applies a 7-line patch (patch\config-loading.rs.txt), builds it on your PC, downloads
  a pinned libmpv build from shinchiro's Windows builds (the ones mpv.io links to) and checks its SHA-256,
  backs up Stremio's official signed files and installs. Run it again after every Stremio update; when
  nothing changed it only refreshes the config.

.PARAMETER StremioDir     Stremio install folder (default: read from the uninstall registry, else %LOCALAPPDATA%\Programs\Stremio)
.PARAMETER WorkDir        Build folder (default: %USERPROFILE%\stremio-mpv-build). Holds the backup of the official files.
.PARAMETER MpvTag         'pinned' (default, config\mpv-pin.json), 'latest' or a shinchiro release tag
.PARAMETER AllowUnpinned  Accept a libmpv build that isn't the pinned one (checked only against GitHub's checksum)
.PARAMETER Yes            Don't ask (install tools, close Stremio). Agents: only after the user agreed in chat.
.PARAMETER BuildOnly      Build and download only; don't touch Stremio or the config
.PARAMETER ForceConfig    Overwrite mpv.conf and script-opts even if you edited them
.PARAMETER Force          Rebuild and reinstall even if already patched; allow overwriting a non-official exe
.PARAMETER NoLaunch       Don't start Stremio at the end
.PARAMETER NeverClose     If Stremio is running when the files must be replaced, stop without changing anything instead of closing it
.PARAMETER NoAutoPatch    Don't register the scheduled task that puts the patch back after Stremio updates (tools\autopatch-task.ps1)
.PARAMETER Unattended     For tools\autopatch.ps1: never install or modify build tools, skip the sandbox probe, and stop if state.json is missing (restored)
.PARAMETER ConfigDir      Where to copy the config (testing only: the patched player always reads %APPDATA%\stremio-mpv)
#>
param(
    [string]$StremioDir,
    [string]$WorkDir = "$env:USERPROFILE\stremio-mpv-build",
    [string]$MpvTag = 'pinned',
    [switch]$AllowUnpinned,
    [switch]$Yes,
    [switch]$BuildOnly,
    [switch]$ForceConfig,
    [switch]$Force,
    [switch]$NoLaunch,
    [switch]$NeverClose,
    [switch]$NoAutoPatch,
    [switch]$Unattended,
    [string]$ConfigDir = (Join-Path $env:APPDATA 'stremio-mpv'),
    [switch]$Relaunched,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = $PSScriptRoot
$MinVersion = [version]'5.0.24'        # first release with stremio's own security and reconnect fixes
$KnownShellCommits = @{ '5.0.26' = 'e13a0912b287f90283db63d5359dda805154bf32' }
$Toolchain = 'stable-x86_64-pc-windows-msvc'
$SystemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
. (Join-Path $Repo 'tools\ca-bundle.ps1')

function Step($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    $t" -ForegroundColor Yellow }
function Ask($q) {
    if ($Yes) { return $true }
    return (Read-Host "    $q [y/N]") -match '^(y|yes|s|si)$'
}
function ArgQ([string]$s) { '"' + ($s -replace '(\\+)$', '$1$1') + '"' }   # quote for a command line

# runs a native tool and returns its exit code. git, cargo and rustup print progress on stderr, which
# windows powershell would turn into terminating errors under ErrorActionPreference=Stop.
function Run([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @argv 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            if ($line.Trim() -and $line -ne 'System.Management.Automation.RemoteException') { Write-Host "    $line" }
        }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

function Update-SessionPath {
    $env:Path = (@("$env:USERPROFILE\.cargo\bin", "$env:ProgramFiles\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd",
        [Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';')
}

function Test-Official([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $s = Get-AuthenticodeSignature -LiteralPath $path
    return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -like 'CN=Smart Code OOD*')
}

function Get-PeMachine([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C; $fs.Position = $br.ReadInt32() + 4
        return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}

function Get-StremioProcesses([string]$dir) {
    $prefix = $dir.TrimEnd('\') + '\'
    Get-Process stremio-shell-ng, stremio-runtime -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
}

# writes a whole new file next to the old one and swaps it in, so a shutdown leaves the old or the new one
function Set-FileAtomic([string]$src, [string]$dst) {
    $tmp = "$dst.new"
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    if (Test-Path -LiteralPath $dst) { [IO.File]::Replace($tmp, $dst, [NullString]::Value) } else { [IO.File]::Move($tmp, $dst) }
}
function Write-TextAtomic([string]$path, [string]$text) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}
function Write-State([hashtable]$s) { Write-TextAtomic (Join-Path $WorkDir 'state.json') ($s | ConvertTo-Json) }

# some sandboxed launchers (e.g. desktop AI apps) silently redirect writes under %APPDATA% / %LOCALAPPDATA%
# into a private folder, so the real Stremio would never see the files. detect it by writing a probe and
# checking it from a process started outside the sandbox (WMI). returns $true, $false or $null (unknown).
function Test-Redirected {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $probes = @((Join-Path $env:APPDATA "stremio-mpv-probe-$id.tmp"), (Join-Path $StremioDir "stremio-mpv-probe-$id.tmp"))
    $out = Join-Path $WorkDir "probe-$id.txt"
    try {
        foreach ($p in $probes) { [IO.File]::WriteAllText($p, 'probe') }
        $checks = ($probes | ForEach-Object { "(if exist `"$_`" (echo REAL) else (echo REDIRECTED))" }) -join ' & '
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c ($checks) > `"$out`"" }
        if ($r.ReturnValue -ne 0) { return $null }
        for ($i = 0; $i -lt 40 -and -not (Test-Path -LiteralPath $out); $i++) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Milliseconds 300
        $text = Get-Content -LiteralPath $out -ErrorAction SilentlyContinue
        if (-not $text) { return $null }
        return [bool]($text -match 'REDIRECTED')
    } catch { return $null }
    finally { Remove-Item -LiteralPath ($probes + $out) -ErrorAction SilentlyContinue }
}

function Expand-Mpv([string]$archive, [string]$dest) {
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if ((Test-Path $SystemTar) -and ((& $SystemTar --version) -match 'liblzma')) {
        if ((Run $SystemTar @('-xf', $archive, '-C', $dest, 'libmpv-2.dll', 'include/mpv/client.h')) -eq 0) { return }
    }
    $7z = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $7z) { throw "Windows' tar can't open .7z files on this Windows build. Install 7-Zip (winget install 7zip.7zip) and run again." }
    if ((Run $7z @('x', '-y', "-o$dest", $archive, 'libmpv-2.dll', 'include\mpv\client.h')) -ne 0) { throw "Couldn't extract $archive." }
}

# ---------------------------------------------------------------------------------------------- setup
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }
if ($LogFile) { Start-Transcript -LiteralPath $LogFile -Append | Out-Null }

if (-not $StremioDir) {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{DD3870DA-AF3C-4C73-B010-72944AB610C6}_is1' -ErrorAction SilentlyContinue
    $StremioDir = if ($reg -and $reg.InstallLocation) { $reg.InstallLocation } else { "$env:LOCALAPPDATA\Programs\Stremio" }
}
$StremioDir = $StremioDir.TrimEnd('\'); $WorkDir = $WorkDir.TrimEnd('\'); $ConfigDir = $ConfigDir.TrimEnd('\')

try {
    if ($MpvTag -notmatch '^(pinned|latest|\d{8})$') { throw "-MpvTag must be 'pinned', 'latest' or a shinchiro tag like 20261019." }
    if (-not [Environment]::Is64BitProcess) { throw "Run this from 64-bit PowerShell." }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Don't run this as administrator: run install.cmd from a normal window (installers ask for elevation themselves)."
    }

    # ------------------------------------------------------------------------------------- sandbox
    # an unattended run comes from autopatch.ps1, which a scheduled task or the player starts outside any sandbox
    if (-not $Relaunched -and -not $BuildOnly -and -not $Unattended) {
        $redirected = Test-Redirected
        if ($null -eq $redirected) {
            Warn "Couldn't check whether this shell is sandboxed. If you run this from an AI desktop app, run install.cmd yourself instead."
        } elseif ($redirected) {
            Warn "This shell's writes to %APPDATA% are redirected (sandboxed app), so the installer must run outside it."
            if (-not $Yes) {
                throw "The outside run can't show prompts. It may install Git, Rust and VS Build Tools with winget (accepting their licenses) and close Stremio. Confirm that with the user, then run again with -Yes."
            }
            $log = Join-Path $WorkDir ("relaunch-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $cmd = (ArgQ $ps) + ' -NoProfile -ExecutionPolicy Bypass -File ' + (ArgQ $PSCommandPath) +
                   ' -Relaunched -Yes -StremioDir ' + (ArgQ $StremioDir) + ' -WorkDir ' + (ArgQ $WorkDir) +
                   " -MpvTag $MpvTag -ConfigDir " + (ArgQ $ConfigDir) + ' -LogFile ' + (ArgQ $log)
            foreach ($s in 'AllowUnpinned', 'ForceConfig', 'Force', 'NoLaunch', 'NeverClose', 'NoAutoPatch', 'Unattended') { if ((Get-Variable $s -ValueOnly).IsPresent) { $cmd += " -$s" } }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
            if ($r.ReturnValue -ne 0) { throw "Couldn't start the installer outside the sandbox (WMI code $($r.ReturnValue)). Run install.cmd yourself." }
            Write-Host "    Running outside the sandbox (log: $log)"
            $seen = 0; $deadline = (Get-Date).AddHours(2); $result = $null
            while (-not $result) {
                Start-Sleep 2
                $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
                if ($lines.Count -gt $seen) { $lines[$seen..($lines.Count - 1)] | ForEach-Object { Write-Host $_ }; $seen = $lines.Count }
                if ($lines -match '^(DONE|FAILED)$') { $result = if ($lines -match '^DONE$') { 'DONE' } else { 'FAILED' } }
                elseif (-not (Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue)) { Start-Sleep 2; $result = 'FAILED' }
                elseif ((Get-Date) -gt $deadline) { $result = 'FAILED'; Warn "Timed out waiting for the outside run." }
            }
            Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
            if ($result -ne 'DONE') { exit 1 }
            return
        }
    }

    # ------------------------------------------------------------------------------------- stremio
    Step "Checking Stremio"
    $exe = Join-Path $StremioDir 'stremio-shell-ng.exe'
    $dllPath = Join-Path $StremioDir 'libmpv-2.dll'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Stremio not found at $StremioDir. Install the official Windows app from stremio.com or pass -StremioDir." }
    $machine = Get-PeMachine $exe
    if ($machine -ne 0x8664) { throw ("This Stremio isn't the x64 build (PE machine 0x{0:X4}). Only x64 is supported." -f $machine) }
    $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { throw "Unexpected Stremio version '$ver'." }
    if ([version]$ver -lt $MinVersion) { throw "Stremio $ver is too old: update Stremio (5.0.24 or later) first." }
    Ok "Stremio $ver at $StremioDir"
    if (-not $Relaunched) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
    $stateFile = Join-Path $WorkDir 'state.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { Warn "Ignoring unreadable state.json." }
    }
    # restore.cmd deletes state.json first: an automatic run that finds none must not patch again
    if ($Unattended -and -not $state) { throw "No state.json (Stremio was restored or never installed): not patching automatically." }
    $ours = $state -and $state.version -eq $ver -and (Get-FileHash -LiteralPath $exe).Hash -eq $state.exeHash
    $official = Test-Official $exe
    if (-not $official -and -not $ours -and -not $Force) {
        throw "This stremio-shell-ng.exe is neither Stremio's signed original nor one this installer built (a fork?). Not overwriting it. Reinstall the official app, or pass -Force."
    }
    $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    if ($sac -eq 1) {
        Warn "Smart App Control is on: Windows may block the locally built Stremio and libmpv."
        if (-not (Ask "Continue anyway?")) { throw "Aborted." }
    }

    # re-patching after stremio updates: scripts\stremio-autopatch.lua starts tools\autopatch.ps1 with
    # stremio (it finds it through autopatch-path.txt) and a scheduled task checks once at logon
    function Register-AutoPatch {
        if ($NoAutoPatch -or $ConfigDir -ne (Join-Path $env:APPDATA 'stremio-mpv')) { return }
        Step "Automatic re-patching after Stremio updates"
        # autopatch.ps1 reads state.json from the default build folder
        if ($WorkDir -ne "$env:USERPROFILE\stremio-mpv-build") {
            Warn "Automatic re-patching needs the default -WorkDir; skipped. Run install.cmd again after every Stremio update."
            return
        }
        $pathFile = Join-Path $ConfigDir 'autopatch-path.txt'
        if (-not (Ask "Put the patch back by itself after Stremio updates (a check that waits for each Stremio session to end, and one at logon; as you, no admin)?")) {
            Remove-Item -LiteralPath $pathFile -ErrorAction SilentlyContinue
            try { $null = & (Join-Path $Repo 'tools\autopatch-task.ps1') -Remove } catch { }
            Ok "Off: run install.cmd again after every Stremio update."
            return
        }
        # utf-8 without a bom, which the player script reads as is
        Write-TextAtomic $pathFile (Join-Path $Repo 'tools\autopatch.ps1')
        Ok "autopatch-path.txt written: the player starts the check with Stremio"
        try { Ok (& (Join-Path $Repo 'tools\autopatch-task.ps1')) }
        catch { Warn "Couldn't register the scheduled task ($($_.Exception.Message)); the check that starts with Stremio still works." }
    }

    # the download relay that stream-watchdog.lua plays remote links through, built with the c#
    # compiler that comes with windows. rebuilt only when tools\relay\relay.cs changes
    function Install-Relay {
        $src = Join-Path $Repo 'tools\relay\relay.cs'
        if (-not (Test-Path -LiteralPath $src)) { return }
        $dir = Join-Path $ConfigDir 'relay'
        $exePath = Join-Path $dir 'relay.exe'
        $mark = Join-Path $dir 'relay.cs.sha256'
        $hash = (Get-FileHash -LiteralPath $src).Hash
        Get-ChildItem -LiteralPath $dir -Filter 'relay.exe.old*' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $exePath) -and (Test-Path -LiteralPath $mark) -and "$(Get-Content -LiteralPath $mark -Raw)".Trim() -eq $hash) {
            Ok "relay\relay.exe up to date"
            return
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $new = "$exePath.new"
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $code = Run $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'tools\relay\build.ps1'), '-Out', $new)
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $new)) {
            Warn "Couldn't build relay\relay.exe. Links play directly, with the slower seek-based fix for slow connections."
            return
        }
        # a relay that is running keeps its exe open, but windows lets a running exe be renamed
        if (Test-Path -LiteralPath $exePath) { Move-Item -LiteralPath $exePath -Destination ("$exePath.old-" + [guid]::NewGuid().ToString('N')) -Force }
        Move-Item -LiteralPath $new -Destination $exePath -Force
        Write-TextAtomic $mark $hash
        Get-ChildItem -LiteralPath $dir -Filter 'relay.exe.old*' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
        Ok "relay\relay.exe built (plays remote links over several connections at once)"
    }

    # always replaced with the repo's copies; other .lua files in scripts\ are the user's
    $OurScripts = 'original-tracks.lua', 'stream-watchdog.lua', 'stremio-autopatch.lua'
    function Copy-Config {
        Step "Installing config in $ConfigDir"
        New-Item -ItemType Directory -Force -Path "$ConfigDir\scripts", "$ConfigDir\script-opts" | Out-Null
        foreach ($name in $OurScripts) {
            Copy-Item -LiteralPath "$Repo\config\scripts\$name" -Destination "$ConfigDir\scripts\$name" -Force
            Ok "scripts\$name updated"
        }
        foreach ($f in 'mpv.conf', 'script-opts\original-tracks.conf') {
            $dst = Join-Path $ConfigDir $f
            if ($ForceConfig -or -not (Test-Path -LiteralPath $dst)) {
                Copy-Item -LiteralPath (Join-Path "$Repo\config" $f) -Destination $dst -Force; Ok "$f written"
            } else { Ok "$f kept (already exists; -ForceConfig overwrites it)" }
        }
        $others = Get-ChildItem -LiteralPath "$ConfigDir\scripts" -Filter *.lua -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $OurScripts }
        foreach ($o in $others) { Warn "Other script in scripts\: $($o.Name). If it also picks tracks, the two will fight; remove one." }
        Install-Relay

        # https streams need a ca file (see tools\ca-bundle.ps1). refreshed on every run, since windows'
        # list of trusted roots changes over time
        $ca = Join-Path $ConfigDir 'cacert.pem'
        try {
            $b = Export-CaBundle -Path $ca
            $from = if ($b.FromWindowsUpdate) { "$($b.FromWindowsUpdate) from Windows Update plus this PC's own" } else { "this PC's own; Windows Update's list couldn't be downloaded" }
            Ok "cacert.pem written: $($b.Count) trusted root certificates ($from)"
        } catch {
            if (Test-Path -LiteralPath $ca) { Warn "Couldn't refresh cacert.pem ($($_.Exception.Message)); keeping the old one." }
            else { throw "Couldn't write cacert.pem, which https streams need: $($_.Exception.Message)" }
        }
        switch (Set-MpvCaFile -Conf (Join-Path $ConfigDir 'mpv.conf') -CaFile $ca) {
            'added'   { Ok "mpv.conf: tls-ca-file added, so https streams can be verified" }
            'updated' { Ok "mpv.conf: tls-ca-file pointed at a missing file; now cacert.pem" }
            'kept'    { Ok "mpv.conf: tls-ca-file already set" }
            'custom'  { Warn "mpv.conf sets its own tls-ca-file; kept. If https streams don't start, point it at $ca." }
        }
    }

    $pin = Get-Content -LiteralPath "$Repo\config\mpv-pin.json" -Raw | ConvertFrom-Json
    $wantedTag = if ($MpvTag -eq 'pinned') { $pin.tag } else { $MpvTag }
    if (-not $BuildOnly -and -not $Force -and $ours -and (Get-FileHash -LiteralPath $dllPath).Hash -eq $state.dllHash -and
        ($wantedTag -eq 'latest' -or $wantedTag -eq $state.mpvTag)) {
        Ok "Stremio $ver is already patched."
        Copy-Config
        Register-AutoPatch
        if (Get-StremioProcesses $StremioDir) { Warn "Stremio is running: close it fully and start it again so the player loads this config." }
        Write-Output "DONE"
        return
    }

    # ------------------------------------------------------------------------------------- tools
    Step "Checking build tools"
    Update-SessionPath
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    function Has-Msvc { (Test-Path $vswhere) -and [bool](& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) }
    function Has-WinSdk {
        $root = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
        [bool]($root -and (Get-ChildItem "$root\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue))
    }
    $canTar = (Test-Path $SystemTar) -and ((& $SystemTar --version) -match 'liblzma')
    $missing = @()
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $missing += @{ n = 'Git'; id = 'Git.Git'; o = $null } }
    if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { $missing += @{ n = 'Rust (rustup)'; id = 'Rustlang.Rustup'; o = $null } }
    if (-not (Has-Msvc) -or -not (Has-WinSdk)) {
        $missing += @{ n = 'Visual Studio 2022 Build Tools (C++ and Windows SDK)'; id = 'Microsoft.VisualStudio.2022.BuildTools'
                       o = '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' }
    }
    if (-not $canTar -and -not (Test-Path "$env:ProgramFiles\7-Zip\7z.exe")) { $missing += @{ n = '7-Zip'; id = '7zip.7zip'; o = $null } }
    if ($missing -and $Unattended) { throw "Missing: $($missing.n -join ', '). Run install.cmd to install them." }
    if ($missing -and -not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Missing: $($missing.n -join ', '). winget isn't available: install 'App Installer' from the Microsoft Store, or install them by hand."
    }
    foreach ($m in $missing) {
        if (-not (Ask "$($m.n) is missing. Install it with winget (accepting its license)?")) { throw "$($m.n) is required." }
        $wargs = @('install', '--id', $m.id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements')
        if ($m.o) { $wargs += @('--override', $m.o) }
        $rc = Run winget $wargs
        if ($rc -ne 0) { Warn "winget returned $rc for $($m.n); checking whether it's usable anyway." }
        Update-SessionPath
    }
    foreach ($c in 'git', 'rustup') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c isn't on PATH yet. Open a new window and run install.cmd again." }
    }
    if ((-not (Has-Msvc) -or -not (Has-WinSdk)) -and (Test-Path $vswhere) -and -not $Unattended) {
        $vsPath = & $vswhere -products * -latest -property installationPath
        if ($vsPath) {
            Warn "Adding the C++ tools and Windows SDK to $vsPath"
            Run "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" @('modify', '--installPath', $vsPath, '--add',
                'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
                '--quiet', '--norestart') | Out-Null
        }
    }
    if (-not (Has-Msvc) -or -not (Has-WinSdk)) { throw "C++ build tools or the Windows SDK are still missing. Reboot if an installer asked to, then run again." }
    if (-not ((& rustup toolchain list) -match "^$([regex]::Escape($Toolchain))")) {
        if ((Run rustup @('toolchain', 'install', $Toolchain, '--profile', 'minimal')) -ne 0) { throw "rustup couldn't install $Toolchain." }
    }
    $env:RUSTUP_TOOLCHAIN = $Toolchain
    Ok "git, $((& cargo --version) -join ''), MSVC and Windows SDK ready"

    # ------------------------------------------------------------------------------------- source + patch
    Step "Getting Stremio $ver source"
    $tags = @(& git ls-remote --tags --refs https://github.com/Stremio/stremio-shell-ng.git) -replace '^.*refs/tags/', ''
    $tag = if ($tags -contains "v$ver") { "v$ver" } else { $tags | Where-Object { $_ -like "v$ver-*" } | Select-Object -First 1 }
    if (-not $tag) { throw "Stremio $ver has no matching tag in Stremio/stremio-shell-ng yet. Try again later." }
    $src = Join-Path $WorkDir "shell-$ver"
    if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath "$src\Cargo.toml")) { Remove-Item -LiteralPath $src -Recurse -Force }
    if (-not (Test-Path -LiteralPath "$src\Cargo.toml")) {
        # cloned next to it and renamed when complete, so a clone cut short (shutdown) is never mistaken for a good one
        $partial = "$src.partial"
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force }
        if ((Run git @('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', $tag, 'https://github.com/Stremio/stremio-shell-ng.git', $partial)) -ne 0) {
            throw "Couldn't clone $tag of Stremio/stremio-shell-ng."
        }
        Move-Item -LiteralPath $partial -Destination $src
    }
    $head = ((& git -C $src rev-parse HEAD) -join '').Trim()
    if ($KnownShellCommits[$ver] -and $head -ne $KnownShellCommits[$ver] -and -not $Force) {
        throw "$tag now points to $head, not the reviewed commit $($KnownShellCommits[$ver]). Stopping."
    }
    if (-not (Select-String -LiteralPath "$src\Cargo.toml" -Pattern "^version = `"$([regex]::Escape($ver))`"" -Quiet)) {
        Warn "Cargo.toml in $tag doesn't say version $ver; building it anyway."
    }
    Ok "$tag ($head)"

    Step "Applying patch"
    & (Join-Path $Repo 'tools\apply-patch.ps1') -Source $src

    Step "Building (first time takes a few minutes)"
    $env:CARGO_TARGET_DIR = Join-Path $WorkDir 'target'
    Push-Location -LiteralPath $src
    try {
        if ((Run cargo @('build', '--release', '--locked', '--target', 'x86_64-pc-windows-msvc')) -ne 0) {
            Warn "Build with --locked failed; retrying without it."
            if ((Run cargo @('build', '--release', '--target', 'x86_64-pc-windows-msvc')) -ne 0) { throw "cargo build failed." }
        }
    } finally { Pop-Location }
    $built = Join-Path $env:CARGO_TARGET_DIR 'x86_64-pc-windows-msvc\release\stremio-shell-ng.exe'
    Ok $built

    # ------------------------------------------------------------------------------------- libmpv
    Step "Getting libmpv"
    $wantTag = $wantedTag
    $hdr = @{ 'User-Agent' = 'StremioMPV-Relay-installer' }
    if ($env:GITHUB_TOKEN) { $hdr.Authorization = "Bearer $env:GITHUB_TOKEN" }
    $mpvDir = Join-Path $WorkDir "libmpv-$wantTag"
    $pinned = ($wantTag -eq $pin.tag)
    $archive = if ($pinned) { Join-Path $mpvDir $pin.asset } else { $null }
    $cachedOk = $pinned -and (Test-Path -LiteralPath $archive) -and ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower() -eq $pin.sha256)
    if (-not $cachedOk) {
        $api = if ($wantTag -eq 'latest') { 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest' }
               else { "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/tags/$wantTag" }
        try { $rel = Invoke-RestMethod $api -Headers $hdr }
        catch {
            if ($pinned) { throw "The pinned libmpv build $($pin.tag) is no longer on GitHub (shinchiro keeps about 30 builds). Update this repo, or run with -MpvTag latest -AllowUnpinned." }
            throw "Couldn't query shinchiro's releases: $($_.Exception.Message)"
        }
        $asset = $rel.assets | Where-Object { $_.name -match '^mpv-dev-x86_64-\d{8}-git-[0-9a-f]+\.7z$' } | Select-Object -First 1
        if (-not $asset) { throw "No mpv-dev-x86_64 build in shinchiro release $($rel.tag_name)." }
        if ($asset.browser_download_url -notlike 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/*') { throw "Unexpected download URL $($asset.browser_download_url)." }
        $pinned = ($rel.tag_name -eq $pin.tag -and $asset.name -eq $pin.asset)
        if (-not $pinned -and -not $AllowUnpinned) {
            throw "libmpv $($rel.tag_name) isn't the reviewed build ($($pin.tag)). Run again with -AllowUnpinned to trust GitHub's checksum alone."
        }
        $mpvDir = Join-Path $WorkDir "libmpv-$($rel.tag_name)"
        New-Item -ItemType Directory -Force -Path $mpvDir | Out-Null
        $archive = Join-Path $mpvDir $asset.name
        Invoke-WebRequest $asset.browser_download_url -OutFile "$archive.part" -UseBasicParsing
        Move-Item -LiteralPath "$archive.part" -Destination $archive -Force
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
        if (-not $asset.digest -or "sha256:$hash" -ne $asset.digest) { Remove-Item -LiteralPath $archive; throw "Checksum missing or wrong for $($asset.name)." }
        if ($pinned -and $hash -ne $pin.sha256) { Remove-Item -LiteralPath $archive; throw "$($asset.name) doesn't match the pinned SHA-256." }
        $usedTag = $rel.tag_name
    } else { $usedTag = $pin.tag }
    Ok "$(Split-Path $archive -Leaf): SHA-256 verified$(if ($pinned) { ' (pinned build)' } else { ' (GitHub checksum only)' })"

    Expand-Mpv $archive "$mpvDir\ex"
    $newDll = Join-Path $mpvDir 'ex\libmpv-2.dll'
    if (-not (Test-Path -LiteralPath $newDll)) { throw "libmpv-2.dll not found in $(Split-Path $archive -Leaf)." }
    if ($pinned -and (Get-FileHash -LiteralPath $newDll).Hash.ToLower() -ne $pin.dllSha256) { throw "libmpv-2.dll doesn't match the pinned SHA-256." }
    $apiLine = Select-String -LiteralPath (Join-Path $mpvDir 'ex\include\mpv\client.h') -Pattern 'define MPV_CLIENT_API_VERSION MPV_MAKE_VERSION\((\d+),' | Select-Object -First 1
    if (-not $apiLine -or $apiLine.Matches[0].Groups[1].Value -ne '2') { throw "This libmpv doesn't have client API 2.x, which Stremio needs." }
    # the newer libmpv needs vulkan-1.dll (gpu driver); without it stremio wouldn't even start
    Add-Type -Namespace StremioMpvNative -Name K32 -MemberDefinition '[DllImport("kernel32",SetLastError=true,CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibraryExW(string p,IntPtr h,uint f); [DllImport("kernel32")] public static extern bool FreeLibrary(IntPtr h);' -ErrorAction SilentlyContinue
    $h = [StremioMpvNative.K32]::LoadLibraryExW($newDll, [IntPtr]::Zero, 0x1100)
    if ($h -eq [IntPtr]::Zero) {
        $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $hint = if (-not (Test-Path "$env:SystemRoot\System32\vulkan-1.dll")) { ' vulkan-1.dll is missing: install or update your GPU driver.' } else { '' }
        throw "This libmpv can't load on this PC (Win32 error $e).$hint Nothing was changed."
    }
    [void][StremioMpvNative.K32]::FreeLibrary($h)
    Ok "libmpv $usedTag loads on this PC (client API 2.x)"

    if ($BuildOnly) {
        Write-Host "`nBuilt: $built`nlibmpv: $newDll"
        Write-Output "DONE"
        return
    }

    # ------------------------------------------------------------------------------------- install
    Step "Installing"
    if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $ver) { throw "Stremio updated itself while building. Run again." }
    try { [IO.File]::WriteAllText((Join-Path $StremioDir 'stremiompv-write-test.tmp'), 'x'); Remove-Item -LiteralPath (Join-Path $StremioDir 'stremiompv-write-test.tmp') }
    catch { throw "Can't write to $StremioDir. Run from an account that owns the Stremio install." }

    $running = @(Get-StremioProcesses $StremioDir)
    if ($running) {
        if ($NeverClose) { throw "Stremio is running and -NeverClose was given: nothing was changed. Close Stremio and run this again." }
        if (-not (Ask "Stremio is running. Close it now?")) { throw "Close Stremio and run this again." }
        $running | ForEach-Object { [void]$_.CloseMainWindow() }
        Start-Sleep 3
        Get-StremioProcesses $StremioDir | Stop-Process -Force
        Start-Sleep 2
    }

    $backup = Join-Path $WorkDir "original-$ver"
    if (-not ((Test-Official "$backup\stremio-shell-ng.exe") -and (Test-Official "$backup\libmpv-2.dll"))) {
        if ((Test-Official $exe) -and (Test-Official $dllPath)) {
            # copied to a separate folder and renamed when both files are there: a half-made backup is redone
            $partial = "$backup.partial"
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $partial | Out-Null
            Copy-Item -LiteralPath $exe, $dllPath -Destination $partial
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
            Move-Item -LiteralPath $partial -Destination $backup
            Ok "Backup of Stremio's official signed files: $backup"
        } else {
            Warn "The installed files aren't both Stremio's signed originals, so no backup was made (reinstall Stremio to get them back)."
        }
    }
    # state.json first, then each file swapped in one step: whatever stops this (a shutdown, an error),
    # the next run finds either stremio's own files or ours, never a patched exe it doesn't recognise
    Write-State @{ version = $ver; exeHash = (Get-FileHash -LiteralPath $built).Hash; dllHash = (Get-FileHash -LiteralPath $newDll).Hash
       mpvTag = $usedTag; pinned = ($wantedTag -eq $pin.tag); shellCommit = $head; stremioDir = $StremioDir; date = (Get-Date).ToString('s') }
    Set-FileAtomic $built $exe
    Set-FileAtomic $newDll $dllPath
    Ok "Patched stremio-shell-ng.exe and libmpv $usedTag installed"

    Copy-Config

    # keep only the current source and libmpv folders
    Get-ChildItem -LiteralPath $WorkDir -Directory | Where-Object {
        ($_.Name -like 'shell-*' -and $_.Name -ne "shell-$ver") -or ($_.Name -like 'libmpv-*' -and $_.FullName -ne $mpvDir)
    } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Register-AutoPatch

    if (-not $NoLaunch) {
        Step "Starting Stremio"
        $p = Start-Process -FilePath $exe -PassThru
        $ipc = Select-String -LiteralPath (Join-Path $ConfigDir 'mpv.conf') -Pattern '^\s*input-ipc-server=\\\\\.\\pipe\\stremio-mpv' -Quiet
        if ($ipc) {
            $up = $false
            for ($i = 0; $i -lt 40 -and -not $p.HasExited; $i++) {
                if ([IO.Directory]::GetFiles('\\.\pipe\') -contains '\\.\pipe\stremio-mpv') { $up = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if ($up) { Ok "The patched player started and loaded your config." }
            else { Warn "The patched player didn't come up. If Stremio misbehaves, run restore.cmd to go back to the official files." }
        }
    }
    Write-Host "`nDone. In Stremio go to Settings > Player > 'Play in external player' and set it to Disabled." -ForegroundColor Green
    if (-not (Get-ScheduledTask -TaskName 'StremioMPV Relay autopatch' -ErrorAction SilentlyContinue)) {
        Write-Host "After a Stremio update, run install.cmd again." -ForegroundColor Green
    }
    Write-Output "DONE"
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Output "FAILED"
    if ($LogFile) { Stop-Transcript | Out-Null }
    exit 1
}
if ($LogFile) { Stop-Transcript | Out-Null }
