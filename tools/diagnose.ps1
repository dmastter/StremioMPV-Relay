#Requires -Version 5.1
<#
.SYNOPSIS
  Collects what's needed to debug a StremioMPV Relay install, without stream links or your user name.
.DESCRIPTION
  Read-only: it changes nothing. It prints a report and saves it to a text file you can attach to a
  GitHub issue. It collects the Windows build, Stremio's version and file signatures, state.json, the
  installed libmpv hash against the pinned one, the names of the config files, mpv.conf without comments
  and, if the patched player is running, a few player properties and a reduced track list.
  Every URL becomes <url host=...> and your Windows user name becomes <user>. The playback log is never read.
.PARAMETER StremioDir  Stremio install folder (default: same lookup as install.ps1)
.PARAMETER WorkDir     Build folder (default: %USERPROFILE%\stremio-mpv-build)
.PARAMETER OutFile     Where to save the report (default: stremio-mpv-diagnose.txt on your Desktop)
.PARAMETER Pipe        mpv IPC pipe name (default: stremio-mpv)
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diagnose.ps1
#>
param(
    [string]$StremioDir,
    [string]$WorkDir = "$env:USERPROFILE\stremio-mpv-build",
    [string]$OutFile,
    [string]$Pipe = 'stremio-mpv'
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$ConfigDir = Join-Path $env:APPDATA 'stremio-mpv'
$SystemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
$report = New-Object System.Collections.Generic.List[string]

function Line([string]$t) { $report.Add($t) }
function Section([string]$t) { $report.Add(''); $report.Add("== $t") }
function Field([string]$k, $v) { $report.Add(('{0,-24} {1}' -f ($k + ':'), $v)) }
function YesNo($b) { if ($b) { 'yes' } else { 'no' } }

# urls (they can carry debrid keys) keep only their host; the windows user name goes too
function Redact([string]$s) {
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, '(?i)magnet:\?[^\s"''<>]*', '<magnet>')
    $s = [regex]::Replace($s, '(?i)\b[a-z][a-z0-9+.\-]*://([^\s/?#"''<>]*)[^\s"''<>]*', [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $h = $m.Groups[1].Value
        $at = $h.LastIndexOf('@')
        if ($at -ge 0) { $h = $h.Substring($at + 1) }
        if ($h) { "<url host=$h>" } else { '<url>' }
    })
    $s = [regex]::Replace($s, '(?i)([\\/])Users([\\/])(?!Public\b|Default\b)[^\\/\s"'']+', '$1Users$2<user>')
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) {
        $s = [regex]::Replace($s, '(?i)(?<![a-z0-9])' + [regex]::Escape($env:USERNAME) + '(?![a-z0-9])', '<user>')
    }
    return $s
}

# first non-empty output line of a native tool, or $null. stderr must not stop the script.
function First-Line([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $exe @argv 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
        if ($out.Count) { return $out[0].Trim() }
        return $null
    } catch { return $null }
    finally { $ErrorActionPreference = $old }
}

function Signature([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 'file missing' }
    $s = Get-AuthenticodeSignature -LiteralPath $path
    if ($s.SignerCertificate) {
        $cn = ($s.SignerCertificate.Subject -split ',')[0].Trim()
        return "$($s.Status) ($cn)"
    }
    return "$($s.Status)"
}

function Test-Official([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $s = Get-AuthenticodeSignature -LiteralPath $path
    return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -like 'CN=Smart Code OOD*')
}

function Sha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}

# same text as the repo's copy, ignoring line endings. $ignore drops matching lines from the installed
# copy first (install.cmd adds tls-ca-file to mpv.conf)
function Same-AsRepo([string]$installed, [string]$repoCopy, [string]$ignore) {
    if (-not (Test-Path -LiteralPath $installed)) { return 'missing' }
    if (-not (Test-Path -LiteralPath $repoCopy)) { return 'repo copy not found' }
    $a = [IO.File]::ReadAllText($installed) -replace "`r`n", "`n"
    if ($ignore) { $a = [regex]::Replace($a, "(?m)^$ignore.*`n?", '') }
    $b = [IO.File]::ReadAllText($repoCopy) -replace "`r`n", "`n"
    if ($a -ceq $b) { return 'same as this repo' }
    return 'differs from this repo (edited, or from another version)'
}

function Without-Comments([string]$path) {
    Get-Content -LiteralPath $path | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
        ForEach-Object { '    ' + $_.Trim() }
}

function Run-Section([string]$name, [scriptblock]$body) {
    Section $name
    try { & $body } catch { Line "    error: $($_.Exception.Message)" }
}

if (-not $StremioDir) {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{DD3870DA-AF3C-4C73-B010-72944AB610C6}_is1' -ErrorAction SilentlyContinue
    $StremioDir = if ($reg -and $reg.InstallLocation) { $reg.InstallLocation } else { "$env:LOCALAPPDATA\Programs\Stremio" }
}
$StremioDir = $StremioDir.TrimEnd('\'); $WorkDir = $WorkDir.TrimEnd('\')
$exe = Join-Path $StremioDir 'stremio-shell-ng.exe'
$dll = Join-Path $StremioDir 'libmpv-2.dll'
$pin = $null
try { $pin = Get-Content -LiteralPath (Join-Path $Repo 'config\mpv-pin.json') -Raw | ConvertFrom-Json } catch { }
$state = $null
$stateFile = Join-Path $WorkDir 'state.json'
if (Test-Path -LiteralPath $stateFile) { try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { } }

Line 'StremioMPV Relay diagnose'
Field 'Date' (Get-Date).ToString('yyyy-MM-dd HH:mm')
if ($pin) { Field 'Repo pinned libmpv' "$($pin.tag) ($($pin.mpvVersion))" }

Run-Section 'Windows' {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $name = "$($cv.ProductName)"
    if ([int]$cv.CurrentBuild -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }
    Field 'Windows' ('{0} {1}, build {2}.{3}' -f $name, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
    Field '64-bit Windows' (YesNo ([Environment]::Is64BitOperatingSystem))
    Field 'PowerShell' "$($PSVersionTable.PSVersion)"
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    Field 'Running as admin' (YesNo ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))
    $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    $sacText = switch ("$sac") { '0' { 'off' } '1' { 'on' } '2' { 'evaluation' } default { 'not reported' } }
    Field 'Smart App Control' $sacText
    Field 'vulkan-1.dll present' (YesNo (Test-Path (Join-Path $env:SystemRoot 'System32\vulkan-1.dll')))
}

Run-Section 'Stremio' {
    Field 'Folder' $StremioDir
    if (-not (Test-Path -LiteralPath $exe)) { Line '    stremio-shell-ng.exe not found'; return }
    Field 'Version' (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    $fs = [IO.File]::OpenRead($exe)
    try { $br = New-Object IO.BinaryReader($fs); $fs.Position = 0x3C; $fs.Position = $br.ReadInt32() + 4; $machine = $br.ReadUInt16() }
    finally { $fs.Dispose() }
    Field 'x64 build' (YesNo ($machine -eq 0x8664))
    $exeHash = Sha256 $exe
    Field 'Exe signature' (Signature $exe)
    if ($state) { Field 'Exe matches state.json' (YesNo ($exeHash -eq "$($state.exeHash)".ToLower())) }
    Field 'libmpv-2.dll signature' (Signature $dll)
    $dllHash = Sha256 $dll
    Field 'libmpv-2.dll sha256' $dllHash
    if ($pin) { Field 'Pinned dll sha256' $pin.dllSha256 }
    $kind = if (-not $dllHash) { 'missing' }
            elseif ($pin -and $dllHash -eq $pin.dllSha256) { "the pinned build ($($pin.tag))" }
            elseif (Test-Official $dll) { "Stremio's own signed libmpv (not patched, or Stremio updated itself)" }
            elseif ($state -and $dllHash -eq "$($state.dllHash)".ToLower()) { "the build in state.json ($($state.mpvTag))" }
            else { 'unknown build' }
    Field 'Installed libmpv is' $kind
    $procs = @(Get-Process stremio-shell-ng, stremio-runtime -ErrorAction SilentlyContinue)
    $names = ($procs | Group-Object ProcessName | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    Field 'Running' $(if ($names) { $names } else { 'not running' })
}

Run-Section 'Build folder' {
    Field 'Folder' $WorkDir
    if (-not (Test-Path -LiteralPath $WorkDir)) { Line '    not found (install.cmd has not run yet, or another -WorkDir was used)'; return }
    if ($state) {
        foreach ($p in $state.PSObject.Properties | Sort-Object Name) { Field "state.json $($p.Name)" $p.Value }
    } elseif (Test-Path -LiteralPath $stateFile) { Line '    state.json unreadable' }
    else { Line '    no state.json' }
    $backups = @(Get-ChildItem -LiteralPath $WorkDir -Directory -Filter 'original-*' -ErrorAction SilentlyContinue)
    if (-not $backups) { Line '    no backup folders (original-<version>)' }
    foreach ($b in $backups) {
        Field "Backup $($b.Name)" ('exe signed: {0}, dll signed: {1}' -f (YesNo (Test-Official "$($b.FullName)\stremio-shell-ng.exe")), (YesNo (Test-Official "$($b.FullName)\libmpv-2.dll")))
    }
}

Run-Section 'Build tools' {
    Field 'winget' $(if (Get-Command winget -ErrorAction SilentlyContinue) { 'found' } else { 'not found' })
    Field 'git' $(if (Get-Command git -ErrorAction SilentlyContinue) { First-Line git @('--version') } else { 'not found' })
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup -and (Test-Path "$env:USERPROFILE\.cargo\bin\rustup.exe")) { $rustup = "$env:USERPROFILE\.cargo\bin\rustup.exe" }
    if ($rustup) {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $tc = @(& $rustup toolchain list 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) } catch { $tc = @() }
        finally { $ErrorActionPreference = $old }
        Field 'rustup toolchains' $(if ($tc) { $tc -join ', ' } else { 'none' })
    } else { Field 'rustup' 'not found' }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msvc = (Test-Path $vswhere) -and [bool](& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    Field 'MSVC C++ tools' (YesNo $msvc)
    $root = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
    Field 'Windows SDK rc.exe' (YesNo ($root -and (Get-ChildItem "$root\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue)))
    $tar = (Test-Path $SystemTar) -and ((First-Line $SystemTar @('--version')) -match 'liblzma')
    Field 'tar can open .7z' (YesNo $tar)
    $7z = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ }
    Field '7-Zip' $(if ($7z) { 'found' } else { 'not found' })
}

Run-Section 'Config (%APPDATA%\stremio-mpv)' {
    if (-not (Test-Path -LiteralPath $ConfigDir)) { Line '    folder not found'; return }
    $root = (Resolve-Path -LiteralPath $ConfigDir).Path.TrimEnd('\') + '\'
    # names only: the playback log, if any, is listed but never opened
    $files = @(Get-ChildItem -LiteralPath $ConfigDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($root.Length) })
    Field 'Files' $(if ($files) { $files -join ', ' } else { 'none' })
    Field 'mpv.conf' (Same-AsRepo (Join-Path $ConfigDir 'mpv.conf') (Join-Path $Repo 'config\mpv.conf') '\s*tls-ca-file\s*=')
    $ca = Join-Path $ConfigDir 'cacert.pem'
    if (Test-Path -LiteralPath $ca) {
        $n = @(Select-String -LiteralPath $ca -Pattern '^-----BEGIN CERTIFICATE-----').Count
        Field 'cacert.pem' "$n certificates, written $((Get-Item -LiteralPath $ca).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
    } else { Field 'cacert.pem' 'missing: https streams fail (run install.cmd)' }
    $line = Select-String -LiteralPath (Join-Path $ConfigDir 'mpv.conf') -Pattern '^\s*tls-ca-file\s*=\s*"?([^"]*)"?\s*$' -ErrorAction SilentlyContinue | Select-Object -Last 1
    $caConf = if (-not $line) { 'not set: https streams fail (run install.cmd)' }
        elseif (Test-Path -LiteralPath $line.Matches[0].Groups[1].Value -PathType Leaf) { 'set, file exists' }
        else { 'set, but the file is missing: https streams fail (run install.cmd)' }
    Field 'tls-ca-file in mpv.conf' $caConf
    Field 'original-tracks.conf' (Same-AsRepo (Join-Path $ConfigDir 'script-opts\original-tracks.conf') (Join-Path $Repo 'config\script-opts\original-tracks.conf'))
    Field 'original-tracks.lua' (Same-AsRepo (Join-Path $ConfigDir 'scripts\original-tracks.lua') (Join-Path $Repo 'config\scripts\original-tracks.lua'))
    Field 'stream-watchdog.lua' (Same-AsRepo (Join-Path $ConfigDir 'scripts\stream-watchdog.lua') (Join-Path $Repo 'config\scripts\stream-watchdog.lua'))
    $relayExe = Join-Path $ConfigDir 'relay\relay.exe'
    $relayMark = Join-Path $ConfigDir 'relay\relay.cs.sha256'
    $relaySrc = Join-Path $Repo 'tools\relay\relay.cs'
    Field 'relay.exe' $(if (-not (Test-Path -LiteralPath $relayExe)) { 'missing: links play directly (run install.cmd)' }
        elseif ((Test-Path -LiteralPath $relaySrc) -and (Test-Path -LiteralPath $relayMark) -and [IO.File]::ReadAllText($relayMark).Trim() -eq (Get-FileHash -LiteralPath $relaySrc).Hash) { 'built from this repo' }
        else { 'built from another version (run install.cmd)' })
    Field 'stremio-autopatch.lua' (Same-AsRepo (Join-Path $ConfigDir 'scripts\stremio-autopatch.lua') (Join-Path $Repo 'config\scripts\stremio-autopatch.lua'))
    $apPath = Join-Path $ConfigDir 'autopatch-path.txt'
    Field 're-patch check' $(if (-not (Test-Path -LiteralPath $apPath)) { 'off (no autopatch-path.txt)' }
        elseif (($p = [IO.File]::ReadAllText($apPath).Trim()) -and (Test-Path -LiteralPath $p)) { 'on' } else { 'on, but autopatch.ps1 is missing or moved (run install.cmd again)' })
    Field 'autopatch task' (& (Join-Path $Repo 'tools\autopatch-task.ps1') -Status)
    $apLog = Join-Path $WorkDir 'autopatch.log'
    if (Test-Path -LiteralPath $apLog) {
        Line '    -- last autopatch.log lines:'
        Get-Content -LiteralPath $apLog -Tail 5 | ForEach-Object { Line "    $_" }
    }
    foreach ($f in 'mpv.conf', 'script-opts\original-tracks.conf') {
        $p = Join-Path $ConfigDir $f
        if (Test-Path -LiteralPath $p) {
            Line "    -- $f without comments:"
            Without-Comments $p | ForEach-Object { Line $_ }
        }
    }
}

# what the cdn really delivered: the relay logs, per player request, the speed of each of its connections
# while downloading (not the player's pace, which drops to the video's bitrate once its cache is full)
Run-Section 'CDN speed (relay.log, last 7 days)' {
    $log = Join-Path $ConfigDir 'relay\relay.log'
    if (-not (Test-Path -LiteralPath $log)) { Line '    no relay.log yet (nothing played through the relay)'; return }
    $since = (Get-Date).Date.AddDays(-6)
    # shared read: a running relay keeps its log open
    $fs = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    $rows = foreach ($l in ($text -split "`r?`n")) {
        if ($l -notmatch '^(\d{4}-\d\d-\d\d) \S+ GET .*, sent (\d+) in .*, hedged (\d+), retries (\d+), cdn ([\d.]+) MB/s per connection:') { continue }
        $day = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        # short requests (probing the file, seeks) say little about the cdn
        if ($day -lt $since -or [long]$Matches[2] -lt 16MB) { continue }
        [pscustomobject]@{ Day = $Matches[1]; Hedged = [int]$Matches[3]; Retries = [int]$Matches[4]
            Rate = [double]::Parse($Matches[5], [Globalization.CultureInfo]::InvariantCulture) }
    }
    if (-not $rows) { Line '    nothing played through the relay in the last 7 days (or only with an older relay.exe)'; return }
    Line ('    {0,-10} {1,9} {2,28} {3,9} {4,8}' -f 'day', 'downloads', 'cdn per connection (median', 'replaced', 'retries')
    Line ('    {0,-10} {1,9} {2,28} {3,9} {4,8}' -f '', '', '/ lowest), MB/s', '', '')
    foreach ($g in ($rows | Group-Object Day | Sort-Object Name)) {
        $r = @($g.Group.Rate | Sort-Object)
        $median = $r[[int][math]::Floor(($r.Count - 1) / 2)]
        Line ('    {0,-10} {1,9} {2,28} {3,9} {4,8}' -f $g.Name, $r.Count, ('{0:0.0} / {1:0.0}' -f $median, $r[0]),
            ($g.Group | Measure-Object Hedged -Sum).Sum, ($g.Group | Measure-Object Retries -Sum).Sum)
    }
    Line '    The relay uses 4 connections at once: trouble starts only if 4 x the lowest falls below what'
    Line "    your videos need (a 4K remux about 3-4 MB/s, see 'video needs' below). If it does for days,"
    Line '    run your debrid service''s speed test (TorBox: torbox.app/speedtest) and pick the CDN it recommends.'
}

Run-Section "Player (pipe \\.\pipe\$Pipe)" {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        try { $client.Connect(1500) }
        catch { Line '    not available (Stremio not running, not patched, or input-ipc-server removed from mpv.conf)'; return }
        $writer = New-Object System.IO.StreamWriter($client)
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, [Text.Encoding]::UTF8)
        $script:ipcId = 0
        $script:ipcBroken = $false
        function Ask-Mpv([string]$cmd) {
            if ($script:ipcBroken) { return $null }
            $script:ipcId++
            $writer.WriteLine('{"command":' + $cmd + ',"request_id":' + $script:ipcId + '}')
            while ($true) {
                $task = $reader.ReadLineAsync()
                if (-not $task.Wait(3000) -or $null -eq $task.Result) { $script:ipcBroken = $true; return $null }
                # mpv also sends events on the pipe; skip until our reply arrives
                if ($task.Result -match ('"request_id":' + $script:ipcId + '\b')) { return ($task.Result | ConvertFrom-Json) }
            }
        }
        foreach ($p in 'mpv-version', 'config-dir', 'options/curl-enabled', 'options/network-timeout', 'options/stream-lavf-o', 'options/tls-verify', 'options/tls-ca-file') {
            $r = Ask-Mpv ('["get_property_string","' + $p + '"]')
            if (-not $r) { Field $p 'no reply' }
            elseif ($r.error -ne 'success') { Field $p "error: $($r.error)" }
            else { Field $p $r.data }
        }
        # network speed against what the video needs (numbers only, no urls)
        $n = @{}
        foreach ($p in 'demuxer-via-network', 'file-size', 'duration', 'cache-speed', 'demuxer-cache-duration', 'paused-for-cache') {
            $r = Ask-Mpv ('["get_property","' + $p + '"]')
            if ($r -and $r.error -eq 'success') { $n[$p] = $r.data }
        }
        if ($n['demuxer-via-network'] -eq $true) {
            $need = if ($n['file-size'] -and $n['duration']) { '{0:N2} MB/s' -f ($n['file-size'] / $n['duration'] / 1MB) } else { 'unknown' }
            Field 'network speed now' ('{0:N2} MB/s' -f ([double]$n['cache-speed'] / 1MB))
            Field 'video needs (average)' $need
            Field 'buffered ahead' ('{0:N1} s' -f [double]$n['demuxer-cache-duration'])
            Field 'waiting for data' (YesNo $n['paused-for-cache'])
            $r = Ask-Mpv '["get_property","user-data/stream-watchdog"]'
            if ($r -and $r.error -eq 'success' -and $r.data) {
                Field 'through the relay' $r.data.relay
                Field 'watchdog' ("{0}; {1} reconnects{2}" -f $r.data.watching, $r.data.reconnects, $(if ($r.data.'gave-up') { '; gave up for now' } else { '' }))
            } else { Field 'watchdog' 'not loaded (scripts\stream-watchdog.lua)' }
        }
        $r = Ask-Mpv '["get_property","track-list"]'
        if (-not $r -or $r.error -ne 'success') { Line '    track list: no reply'; return }
        $tracks = @($r.data)
        if (-not $tracks.Count) { Line '    track list: empty (nothing playing)'; return }
        $row = '    {0,3} {1,-5} {2,-8} {3,-17} {4,-7} {5,-6} {6,-8} {7}'
        Line ($row -f 'id', 'type', 'lang', 'codec', 'default', 'forced', 'selected', 'title')
        foreach ($t in $tracks) {
            Line ($row -f $t.id, $t.type, $t.lang, $t.codec, (YesNo $t.default), (YesNo $t.forced), (YesNo $t.selected), $t.title)
        }
    } finally { $client.Dispose() }
}

$clean = @($report | ForEach-Object { Redact $_ })
$clean | Write-Output

if (-not $OutFile) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { $desktop = $env:TEMP }
    $OutFile = Join-Path $desktop 'stremio-mpv-diagnose.txt'
}
try {
    [IO.File]::WriteAllLines($OutFile, [string[]]$clean, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nSaved to $OutFile. Read it before posting: it should contain no links, keys or names." -ForegroundColor Green
} catch {
    Write-Host "`nCouldn't save $OutFile ($($_.Exception.Message)). Copy the text above instead." -ForegroundColor Yellow
}
