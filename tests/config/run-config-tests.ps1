#Requires -Version 5.1
<#
.SYNOPSIS
  Tests tools\ca-bundle.ps1: exporting Windows' trusted roots to a pem file, and pointing tls-ca-file in
  an mpv.conf at it without breaking the rest of the file.

.DESCRIPTION
  Works in <WorkDir>\config only. With -Mpv, it also checks that mpv reads the line it writes (a full,
  quoted path with spaces) as the right file.

.PARAMETER Mpv      mpv.com (optional)
.PARAMETER WorkDir  Test files go to <WorkDir>\config
.PARAMETER Offline  Skip Windows Update's list of roots (the local stores are still tested)
#>
param(
    [string]$Mpv,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'stremiompv-relay-tests'),
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot '..\..\tools\ca-bundle.ps1')
$repoConf = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\config\mpv.conf')).ProviderPath
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
# a space in the folder name, like a windows user name with one
$dir = Join-Path (Resolve-Path -LiteralPath $WorkDir).ProviderPath 'config\user name'
if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $results.Add([pscustomobject]@{ Test = $name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = $detail })
}
function Test-Case([string]$name, [scriptblock]$body) {
    try { & $body } catch { Check $name $false "crashed: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ cacert.pem
Write-Section 'Exporting trusted roots'
$ca = Join-Path $dir 'cacert.pem'
function Test-Pem([string]$name, $info) {
    $text = [IO.File]::ReadAllText($ca)
    $blocks = [regex]::Matches($text, '-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+)-----END CERTIFICATE-----')
    $bad = 0
    foreach ($b in $blocks) {
        try { $null = New-Object Security.Cryptography.X509Certificates.X509Certificate2(, [Convert]::FromBase64String($b.Groups[1].Value)) } catch { $bad++ }
    }
    $long = @($text -split "`n" | Where-Object { $_ -notlike '#*' -and $_.Length -gt 64 }).Count
    Check $name ($blocks.Count -eq $info.Count -and $info.Count -ge 10 -and -not $bad -and -not $long -and -not $text.Contains("`r") -and -not [IO.File]::Exists("$ca.tmp")) `
        "$($info.Count) roots ($($info.FromWindowsUpdate) from Windows Update), $($blocks.Count) pem blocks, $bad unreadable, $long long lines"
}
Test-Case 'local stores only' {
    $info = Export-CaBundle -Path $ca -NoWindowsUpdate
    Test-Pem 'local stores only' $info
    $script:localCount = $info.Count
}
# the weekly refresh writes over the existing file (swapped in one step)
Test-Case 'over an existing file' {
    (Get-Item -LiteralPath $ca).LastWriteTime = (Get-Date).AddDays(-8)
    $info = Export-CaBundle -Path $ca -NoWindowsUpdate
    Test-Pem 'over an existing file' $info
    Check 'over an existing file: date' (((Get-Date) - (Get-Item -LiteralPath $ca).LastWriteTime).TotalMinutes -lt 5) ((Get-Item -LiteralPath $ca).LastWriteTime.ToString('s'))
}
if (-not $Offline) {
    Test-Case 'with Windows Update' {
        $info = Export-CaBundle -Path $ca
        Test-Pem 'with Windows Update' $info
        if (-not $info.FromWindowsUpdate) { Write-Host '    Windows Update list not available here; only the local stores were tested' -ForegroundColor Yellow }
        elseif ($info.Count -lt $script:localCount) { Check 'Windows Update adds roots' $false "$($info.Count) < $($script:localCount)" }
    }
}

# ------------------------------------------------------------------ mpv.conf
Write-Section 'Pointing tls-ca-file at it'
$want = 'tls-ca-file="' + $ca + '"'
$conf = Join-Path $dir 'mpv.conf'
function Read-Lines { @([IO.File]::ReadAllText($conf) -split "\r?\n") }
function Without-CaLine([string]$text) { [regex]::Replace($text, '(?m)^tls-ca-file=.*\r?\n', '') }

Test-Case "repo's mpv.conf" {
    Copy-Item -LiteralPath $repoConf -Destination $conf -Force
    $before = [IO.File]::ReadAllText($conf)
    $r1 = Set-MpvCaFile -Conf $conf -CaFile $ca
    $after = [IO.File]::ReadAllText($conf)
    $lines = Read-Lines
    $i = [array]::IndexOf($lines, $want)
    $r2 = Set-MpvCaFile -Conf $conf -CaFile $ca
    Check "repo's mpv.conf" ($r1 -eq 'added' -and $i -gt 0 -and $lines[$i - 1] -eq 'tls-verify=yes' -and (Without-CaLine $after) -ceq $before -and
        $r2 -eq 'kept' -and [IO.File]::ReadAllText($conf) -ceq $after) "first run: $r1, line after tls-verify: $($i -gt 0 -and $lines[$i - 1] -eq 'tls-verify=yes'), second run: $r2"
}

Test-Case 'old mpv.conf, no tls lines' {
    [IO.File]::WriteAllText($conf, "cache=yes`r`ncurl-enabled=no`r`n")
    $r = Set-MpvCaFile -Conf $conf -CaFile $ca
    $text = [IO.File]::ReadAllText($conf)
    Check 'old mpv.conf, no tls lines' ($r -eq 'added' -and $text.StartsWith("cache=yes`r`ncurl-enabled=no`r`n`r`n#") -and $text.EndsWith("$want`r`n")) "$r"
}

Test-Case 'profile after the global part' {
    [IO.File]::WriteAllText($conf, "cache=yes`n[stream]`nprofile-desc=x`ntls-ca-file=C:\elsewhere.pem`n")
    $r = Set-MpvCaFile -Conf $conf -CaFile $ca
    $lines = Read-Lines
    $p = [array]::IndexOf($lines, '[stream]')
    $i = [array]::IndexOf($lines, $want)
    Check 'profile after the global part' ($r -eq 'added' -and $i -ge 0 -and $i -lt $p -and $lines[$p + 2] -eq 'tls-ca-file=C:\elsewhere.pem' -and
        -not [IO.File]::ReadAllText($conf).Contains("`r")) "$r, line at $i, profile at $p"
}

Test-Case 'points at a missing file' {
    [IO.File]::WriteAllText($conf, "tls-verify=yes`ntls-ca-file=`"$dir\gone.pem`"`ncache=yes`n")
    $r = Set-MpvCaFile -Conf $conf -CaFile $ca
    Check 'points at a missing file' ($r -eq 'updated' -and (Read-Lines)[1] -eq $want -and (Read-Lines)[2] -eq 'cache=yes') "$r"
}

Test-Case "the user's own file" {
    $own = Join-Path $dir 'own.pem'
    Copy-Item -LiteralPath $ca -Destination $own
    $text = "tls-ca-file=$own`n"
    [IO.File]::WriteAllText($conf, $text)
    $r = Set-MpvCaFile -Conf $conf -CaFile $ca
    Check "the user's own file" ($r -eq 'custom' -and [IO.File]::ReadAllText($conf) -ceq $text) "$r"
}

Test-Case 'BOM kept' {
    [IO.File]::WriteAllText($conf, "tls-verify=yes`r`n", (New-Object Text.UTF8Encoding($true)))
    $r = Set-MpvCaFile -Conf $conf -CaFile $ca
    $bytes = [IO.File]::ReadAllBytes($conf)
    $bom = $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, 3, $bytes.Length - 3)
    Check 'BOM kept' ($r -eq 'added' -and $bom -and $text -ceq "tls-verify=yes`r`n$want`r`n") "$r, bom: $bom"
}

# ------------------------------------------------------------------ mpv reads it
if ($Mpv) {
    Test-Case 'mpv reads the line' {
        $Mpv = Resolve-Mpv $Mpv
        Copy-Item -LiteralPath $repoConf -Destination $conf -Force
        $null = Set-MpvCaFile -Conf $conf -CaFile $ca
        $lua = Join-Path $dir 'print-ca.lua'
        [IO.File]::WriteAllText($lua, "print('CAFILE=' .. mp.get_property('options/tls-ca-file') .. '|' .. mp.get_property('options/tls-verify'))`nmp.command('quit')`n")
        # input-ipc-server is cleared so the test can't collide with a running stremio
        $out = & { $ErrorActionPreference = 'Continue'; & $Mpv "--config-dir=$dir" '--input-ipc-server=' '--load-scripts=no' "--script=$lua" '--idle=yes' '--vo=null' '--ao=null' '--msg-level=all=error,print_ca=info' 2>&1 } |
            ForEach-Object { "$_" } | Where-Object { $_ -match 'CAFILE=' }
        Check 'mpv reads the line' ("$out" -like "*CAFILE=$ca|yes") "$out"
    }
}

# ------------------------------------------------------------------ autopatch decisions
# tools\autopatch.ps1 -CheckOnly against a fake stremio folder and build folder: it prints what it would
# do and changes nothing. a real update (stremio's signed exe) needs stremio's files, so that case runs
# only where a backup made by install.ps1 exists.
Write-Section 'Automatic re-patching (tools\autopatch.ps1 -CheckOnly)'
$autopatch = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\tools\autopatch.ps1')).ProviderPath
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
$apRoot = Join-Path (Resolve-Path -LiteralPath $WorkDir).ProviderPath 'config\autopatch'
function New-FakeInstall([string]$name) {
    $root = Join-Path $apRoot $name
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $s = Join-Path $root 'Stremio'; $w = Join-Path $root 'build'; $c = Join-Path $root 'config'
    New-Item -ItemType Directory -Force -Path $s, $w, "$c\scripts" | Out-Null
    [IO.File]::WriteAllText("$s\stremio-shell-ng.exe", 'patched exe')
    [IO.File]::WriteAllText("$s\libmpv-2.dll", 'pinned dll')
    foreach ($f in 'original-tracks.lua', 'stream-watchdog.lua', 'stremio-autopatch.lua') { Copy-Item -LiteralPath "$repoRoot\config\scripts\$f" -Destination "$c\scripts\$f" }
    [IO.File]::WriteAllText("$c\cacert.pem", 'pem')
    if (Test-Path -LiteralPath "$repoRoot\tools\relay\relay.cs") {
        New-Item -ItemType Directory -Force -Path "$c\relay" | Out-Null
        [IO.File]::WriteAllText("$c\relay\relay.exe", 'relay')
        [IO.File]::WriteAllText("$c\relay\relay.cs.sha256", (Get-FileHash -LiteralPath "$repoRoot\tools\relay\relay.cs").Hash)
    }
    $pin = Get-Content -LiteralPath "$repoRoot\config\mpv-pin.json" -Raw | ConvertFrom-Json
    @{ version = '5.0.26'; exeHash = (Get-FileHash -LiteralPath "$s\stremio-shell-ng.exe").Hash; dllHash = (Get-FileHash -LiteralPath "$s\libmpv-2.dll").Hash
       mpvTag = $pin.tag; stremioDir = $s } | ConvertTo-Json | Set-Content -LiteralPath "$w\state.json" -Encoding UTF8
    [pscustomobject]@{ Stremio = $s; Work = $w; Config = $c }
}
function Invoke-AutoPatch($fake) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $autopatch -CheckOnly -WorkDir $fake.Work -ConfigDir $fake.Config 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $old
    return ($out -join ' ')
}
function Test-AutoPatch([string]$case, [scriptblock]$setup, [string]$expect) {
    Test-Case "autopatch: $case" {
        $fake = New-FakeInstall ($case -replace '\W', '-')
        & $setup $fake
        $out = Invoke-AutoPatch $fake
        Check "autopatch: $case" ($out -match $expect) $out
    }
}
Test-AutoPatch 'all in place' { } 'nothing to do'
Test-AutoPatch 'not installed' { param($f) Remove-Item -LiteralPath "$($f.Work)\state.json" } 'no state\.json'
Test-AutoPatch 'script outdated' { param($f) Add-Content -LiteralPath "$($f.Config)\scripts\stream-watchdog.lua" '-- old' } 'running install\.ps1: .*stream-watchdog\.lua differs'
Test-AutoPatch 'script missing' { param($f) Remove-Item -LiteralPath "$($f.Config)\scripts\original-tracks.lua" } 'running install\.ps1: .*original-tracks\.lua differs'
Test-AutoPatch 'cacert.pem old' { param($f) (Get-Item -LiteralPath "$($f.Config)\cacert.pem").LastWriteTime = (Get-Date).AddDays(-8) } 'running install\.ps1: cacert\.pem is more than 7 days old'
Test-AutoPatch 'new libmpv pinned' { param($f)
    $st = Get-Content -LiteralPath "$($f.Work)\state.json" -Raw | ConvertFrom-Json; $st.mpvTag = '20200101'
    $st | ConvertTo-Json | Set-Content -LiteralPath "$($f.Work)\state.json" -Encoding UTF8 } 'running install\.ps1: the repo pins libmpv'
Test-AutoPatch 'foreign exe' { param($f) [IO.File]::WriteAllText("$($f.Stremio)\stremio-shell-ng.exe", 'someone else') } 'neither Stremio''s signed original'
Test-AutoPatch 'dll replaced' { param($f) [IO.File]::WriteAllText("$($f.Stremio)\libmpv-2.dll", 'other dll') } 'running install\.ps1: Stremio .* isn''t patched'
Test-AutoPatch 'unpinned libmpv kept' { param($f)
    $st = Get-Content -LiteralPath "$($f.Work)\state.json" -Raw | ConvertFrom-Json
    $st.mpvTag = '20200101'; $st | Add-Member pinned $false
    $st | ConvertTo-Json | Set-Content -LiteralPath "$($f.Work)\state.json" -Encoding UTF8 } 'everything is in place'
# files a shutdown cut short are empty: no crash, and a real change is still seen
Test-AutoPatch 'empty stamp file' { param($f)
    [IO.File]::WriteAllText("$($f.Work)\autopatch-stamp.txt", '')
    [IO.File]::WriteAllText("$($f.Stremio)\libmpv-2.dll", 'other dll') } 'running install\.ps1: Stremio .* isn''t patched'
Test-AutoPatch 'empty state.json' { param($f) [IO.File]::WriteAllText("$($f.Work)\state.json", '') } 'no state\.json'
if (Test-Path -LiteralPath "$repoRoot\tools\relay\relay.cs") {
    Test-AutoPatch 'empty relay mark' { param($f) [IO.File]::WriteAllText("$($f.Config)\relay\relay.cs.sha256", '') } 'running install\.ps1: relay\\relay\.exe is missing or older'
    Test-AutoPatch 'relay outdated' { param($f) [IO.File]::WriteAllText("$($f.Config)\relay\relay.cs.sha256", 'old') } 'running install\.ps1: relay\\relay\.exe is missing or older'
}
$backup = Get-ChildItem -LiteralPath "$env:USERPROFILE\stremio-mpv-build" -Directory -Filter 'original-*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath "$($_.FullName)\stremio-shell-ng.exe" } | Select-Object -First 1
if ($backup) {
    # stremio's own signed exe and dll in place of the patched ones: what an update leaves
    Test-AutoPatch 'stremio updated' { param($f)
        Copy-Item -LiteralPath "$($backup.FullName)\stremio-shell-ng.exe", "$($backup.FullName)\libmpv-2.dll" -Destination $f.Stremio -Force } 'running install\.ps1: Stremio .* isn''t patched'
} else { Write-Host '    no backup of Stremio''s official files on this PC: the "stremio updated" case is skipped' }

Write-Section 'Config results'
$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL')
if ($failed) { Write-Host "  $($failed.Count) of $($results.Count) config tests failed" -ForegroundColor Red; exit 1 }
Write-Host "  all $($results.Count) config tests passed" -ForegroundColor Green
exit 0
