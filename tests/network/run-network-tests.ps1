#Requires -Version 5.1
<#
.SYNOPSIS
  Plays a generated ~2-minute video through flaky_server.py with mpv.com and the network options of
  config\mpv.conf, once per fault mode, and checks that playback reaches the end without hanging.

.DESCRIPTION
  The network options are read from the conf file every run (cache*, demuxer-*, curl-*,
  network-timeout, stream-*, http-*, tls-*), so changing mpv.conf changes what is tested.
  Playback is untimed (as fast as the stream allows), so a healthy run takes seconds; a case counts
  as hung when it is still running after 2 x network-timeout + 60 s. Modes run in parallel.
  A mode named tls-<mode> runs the same fault over https, with a test CA made by openssl (the one in
  Git for Windows works) given as tls-ca-file. tls-untrusted gives mpv a different CA instead and
  passes when playback is refused, which shows the certificate really is checked.
  The player also runs config\scripts\stream-watchdog.lua, which replaces a connection that is too
  slow for the video: slow and tls-slow only reach the end in time because of it, and slowall checks
  that it gives up after a few tries when every connection is slow.

.PARAMETER Mpv        mpv.com (needs the libcurl backend if the conf uses curl-* options)
.PARAMETER Ffmpeg     ffmpeg.exe, to generate the test video
.PARAMETER Python     python.exe for the test server
.PARAMETER OpenSsl    openssl.exe, to make the certificates for the tls-* modes
.PARAMETER WorkDir    The video goes to <WorkDir>\network, logs to <WorkDir>\logs\network
.PARAMETER Conf       mpv.conf to take the network options from
.PARAMETER Watchdog   stream-watchdog.lua to run in the player
.PARAMETER NoWatchdog Runs the player without it (slow and tls-slow should then fail)
.PARAMETER Modes      Fault modes of flaky_server.py to run
.PARAMETER Duration   Length of the generated video in seconds
.PARAMETER Tolerance  How far before the end (seconds) still counts as reaching the end
#>
param(
    [string]$Mpv,
    [string]$Ffmpeg,
    [string]$Python,
    [string]$OpenSsl,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'stremiompv-relay-tests'),
    [string]$Conf = (Join-Path $PSScriptRoot '..\..\config\mpv.conf'),
    [string]$Watchdog = (Join-Path $PSScriptRoot '..\..\config\scripts\stream-watchdog.lua'),
    [switch]$NoWatchdog,
    [string[]]$Modes = @('ok', 'close', 'fin', 'close503', '503', 'stall', 'slow', 'slowall', 'tls-ok', 'tls-close503', 'tls-stall', 'tls-slow', 'tls-untrusted'),
    [int]$Duration = 120,
    [double]$Tolerance = 1.5
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture

$Mpv = Resolve-Mpv $Mpv
$Python = Resolve-Python $Python
$server = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'flaky_server.py')).ProviderPath
$report = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'report.lua')).ProviderPath
$Watchdog = if ($NoWatchdog) { '' } else { (Resolve-Path -LiteralPath $Watchdog).ProviderPath }
$Modes = @($Modes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
$videoDir = Join-Path $WorkDir 'network'
$logDir = Join-Path $WorkDir 'logs\network'
New-Item -ItemType Directory -Force -Path $videoDir, $logDir | Out-Null
Get-ChildItem -LiteralPath $logDir -File | Remove-Item

# ------------------------------------------------------------------ options from the conf
Write-Section "Network options from $Conf"
$netPattern = '^(cache|cache-.+|demuxer-.+|curl-.+|network-timeout|stream-.+|http-.+|tls-.+|user-agent|referrer)$'
$netOpts = @(Read-KeyValueConf $Conf | Where-Object { $_.Name -match $netPattern })
if (-not $netOpts) { Write-Host '    none found: testing mpv defaults' -ForegroundColor Yellow }
$netOpts | ForEach-Object { Write-Host "    $($_.Name)=$($_.Value)" }
$netArgs = @($netOpts | ForEach-Object { "--$($_.Name)=$($_.Value)" })
$known = & { $ErrorActionPreference = 'Continue'; & $Mpv --no-config --list-options 2>&1 } | ForEach-Object { "$_" }
$unknown = @($netOpts | Where-Object { $n = $_.Name; -not ($known -match "^\s+--$([regex]::Escape($n))\s") })
if ($unknown) { throw "this mpv doesn't know $(($unknown.Name) -join ', '). It needs a build with the libcurl backend: $Mpv" }
$nt = ($netOpts | Where-Object Name -eq 'network-timeout' | Select-Object -Last 1).Value
$networkTimeout = if ($nt) { [double]::Parse($nt, $inv) } else { 60 }
$limit = [math]::Max(90, 2 * $networkTimeout + 60)

# ------------------------------------------------------------------ test video
$video = Join-Path $videoDir "video-$($Duration)s.mkv"
if (-not (Test-Path -LiteralPath $video)) {
    $Ffmpeg = Resolve-Ffmpeg $Ffmpeg
    Write-Section "Generating a $Duration s test video"
    # noise keeps the bitrate up (~2 Mbit/s), so the file is big enough to break in the middle
    $a = @('-y', '-nostdin', '-hide_banner', '-loglevel', 'error',
           '-f', 'lavfi', '-i', 'testsrc2=size=480x270:rate=25,noise=alls=12:allf=t',
           '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000',
           '-t', "$Duration", '-map', '0:v', '-map', '1:a', '-c:v', 'mpeg4', '-b:v', '2000k', '-g', '50',
           '-c:a', 'aac', '-b:a', '96k', '-f', 'matroska', "$video.part")
    if ((Invoke-Native $Ffmpeg $a) -ne 0) { throw 'ffmpeg failed to generate the test video' }
    Move-Item -LiteralPath "$video.part" -Destination $video -Force
}
$size = (Get-Item -LiteralPath $video).Length
$faultAt = [long]($size * 0.3)
# slow: one connection at a tenth of the bitrate. slowall: every connection just below the bitrate,
# so reconnecting can't help; it plays only the first 30 s, which still takes longer than real time
$bitrate = $size / $Duration
$slowRate = @{ slow = [long]($bitrate / 10); slowall = [long]($bitrate * 0.9) }
$endAt = @{ slowall = 30 }
# the watchdog gives up after two slow new connections: a handful of requests, not dozens
$maxSlowallRequests = 8
Write-Host "    video: $video ($([math]::Round($size / 1MB, 1).ToString($inv)) MB); faults at byte $faultAt (30%)"

# ------------------------------------------------------------------ certificates for https
$tlsVerify = ($netOpts | Where-Object Name -eq 'tls-verify' | Select-Object -Last 1).Value
if ($Modes -like 'tls-*') {
    $OpenSsl = Resolve-OpenSsl $OpenSsl
    Write-Section 'Making a test CA and a certificate for 127.0.0.1'
    $certDir = Join-Path $WorkDir 'network\certs'
    if (Test-Path -LiteralPath $certDir) { Remove-Item -LiteralPath $certDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $certDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $certDir 'server.ext'), "basicConstraints=CA:FALSE`nkeyUsage=digitalSignature,keyEncipherment`nextendedKeyUsage=serverAuth`nsubjectAltName=IP:127.0.0.1,DNS:localhost`n")
    $steps = @(
        @('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=StremioMPV Relay test CA', '-keyout', "$certDir\ca.key", '-out', "$certDir\ca.pem"),
        @('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=StremioMPV Relay unrelated CA', '-keyout', "$certDir\other.key", '-out', "$certDir\other.pem"),
        @('req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=127.0.0.1', '-keyout', "$certDir\server.key", '-out', "$certDir\server.csr"),
        @('x509', '-req', '-days', '2', '-in', "$certDir\server.csr", '-CA', "$certDir\ca.pem", '-CAkey', "$certDir\ca.key", '-CAcreateserial', '-extfile', "$certDir\server.ext", '-out', "$certDir\server.pem"))
    foreach ($a in $steps) { if ((Invoke-Native $OpenSsl $a -Quiet) -ne 0) { throw "openssl $($a[0]) failed: $OpenSsl" } }
    Write-Host "    $certDir"
}

# ------------------------------------------------------------------ run every mode at once
Write-Section "Playing through the fault server: $($Modes -join ', ') (hang limit $limit s)"
$runs = @()
try {
    foreach ($m in $Modes) {
        $port = Get-FreeTcpPort
        $tls = $m -like 'tls-*'
        $fault = $m -replace '^tls-', ''
        if ($fault -eq 'untrusted') { $fault = 'ok' }
        $srvArgs = @('-I', '-u', $server, $video, "$port", $fault, '--fault-at', "$faultAt")
        if ($slowRate[$fault]) { $srvArgs += @('--slow-rate', "$($slowRate[$fault])") }
        if ($tls) { $srvArgs += @('--tls', "$certDir\server.pem", "$certDir\server.key") }
        $srv = Start-LoggedProcess -FilePath $Python -Arguments $srvArgs -LogBase (Join-Path $logDir "server-$m")
        # the first python start on a fresh ci runner can take over 10 s (on-access scanning)
        if (-not (Wait-TcpPort $port 60000)) { throw "the test server for mode $m didn't start (see $logDir\server-$m.err)" }
        $a = @('--no-config', '--vo=null', '--no-audio', '--untimed', '--msg-color=no', '--msg-level=all=warn,report=info,stream_watchdog=info',
               "--script=$report") + $netArgs
        # the test server is on 127.0.0.1, which the watchdog skips by default (stremio's torrent server)
        if ($Watchdog) { $a += @("--script=$Watchdog", '--script-opts-append=stream-watchdog-allow_local=yes') }
        if ($endAt[$m]) { $a += "--end=$($endAt[$m])" }
        # the conf's own tls-ca-file (if any) is the user's windows roots; the test CA replaces it
        if ($tls) { $a += "--tls-ca-file=$certDir\$(if ($m -eq 'tls-untrusted') { 'other.pem' } else { 'ca.pem' })" }
        $a += "$(if ($tls) { 'https' } else { 'http' })://127.0.0.1:$port/video.mkv"
        $p = Start-LoggedProcess -FilePath $Mpv -Arguments $a -LogBase (Join-Path $logDir "mpv-$m")
        $runs += [pscustomobject]@{ Mode = $m; Server = $srv; Player = $p; Watch = [Diagnostics.Stopwatch]::StartNew(); Hung = $false }
    }
    while (@($runs | Where-Object { -not $_.Player.HasExited -and -not $_.Hung }).Count) {
        foreach ($r in $runs) {
            if (-not $r.Player.HasExited -and -not $r.Hung -and $r.Watch.Elapsed.TotalSeconds -gt $limit) {
                Stop-ProcessTree $r.Player; $r.Hung = $true
            }
        }
        Start-Sleep -Milliseconds 250
    }
} finally {
    foreach ($r in $runs) { Stop-ProcessTree $r.Player; Stop-ProcessTree $r.Server }
}

# ------------------------------------------------------------------ check
$results = foreach ($r in $runs) {
    $base = Join-Path $logDir "mpv-$($r.Mode)"
    $out = @(Get-Content -LiteralPath "$base.out", "$base.err" -ErrorAction SilentlyContinue)
    $srvLog = @(Get-Content -LiteralPath (Join-Path $logDir "server-$($r.Mode).out") -ErrorAction SilentlyContinue)
    $res = $out | Where-Object { $_ -match 'RESULT pos=' } | Select-Object -Last 1
    $pos = $dur = $null; $reason = ''
    if ($res -match 'pos=([\d.]+) duration=([\d.]+) reason=(\S+)') {
        $pos = [double]::Parse($Matches[1], $inv); $dur = [double]::Parse($Matches[2], $inv); $reason = $Matches[3]
    }
    if (-not $dur) { $dur = $Duration }
    if ($endAt[$r.Mode]) { $dur = [math]::Min($dur, $endAt[$r.Mode]) }
    $faults = @($srvLog | Where-Object { $_ -cmatch ' FAULT ' } | ForEach-Object { ($_ -csplit ' FAULT ', 2)[1] })
    $requests = @($srvLog | Where-Object { $_ -match ' req \d+ range ' }).Count
    # the player's first complaint about the stream (ffmpeg's reconnect at the very end of the file is normal)
    $player = @($out | Where-Object { $_ -match '^\[(curl|ffmpeg|stream_watchdog)' -and $_ -notmatch 'Opening|Mime-type' -and $_ -notmatch "reconnect at $size\b" }) | Select-Object -First 1
    if ("$player".Length -gt 90) { $player = "$player".Substring(0, 87) + '...' }
    $tlsError = @($out -match '^\[ffmpeg\] tls: ').Count -gt 0
    $problem = if ($r.Mode -eq 'tls-untrusted') {
            if ($r.Hung) { "hung: still running after $limit s" }
            elseif ($reason -eq 'eof') { "played a server whose certificate isn't trusted (tls-verify=$tlsVerify)" }
            elseif (-not $tlsError) { 'refused, but not because of the certificate' }
        }
        elseif ($r.Hung) { "hung: still running after $limit s" }
        elseif ($null -eq $pos) { "no result (mpv exit code $($r.Player.ExitCode))" }
        elseif ($reason -ne 'eof' -or $pos -lt $dur - $Tolerance) { "stopped at $($pos.ToString('0.0', $inv)) of $($dur.ToString('0.0', $inv)) s ($reason)" }
        elseif ($r.Mode -notin 'ok', 'tls-ok' -and -not $faults) { 'the fault was never injected, so nothing was tested' }
        elseif ($r.Mode -eq 'slowall' -and $Watchdog -and $requests -gt $maxSlowallRequests) { "$requests requests: the watchdog kept reconnecting although every connection is slow" }
        elseif ($r.Mode -eq 'slowall' -and $Watchdog -and -not ($out -match "reconnecting doesn't help")) { "the watchdog never said that reconnecting doesn't help" }
    [pscustomobject]@{
        Mode = $r.Mode; Result = $(if ($problem) { 'FAIL' } else { 'PASS' })
        Reached = $(if ($null -ne $pos) { $pos.ToString('0.0', $inv) + '/' + $dur.ToString('0.0', $inv) } else { '-' })
        Seconds = $(if ($r.Hung) { [int]$limit } else { [int]($r.Player.ExitTime - $r.Player.StartTime).TotalSeconds })
        Requests = $requests
        Fault = ($faults -join '; '); Player = "$player".Trim(); Problem = $problem
    }
}

Write-Section 'Network results'
$results | Format-Table Mode, Result, Reached, Seconds, Requests, Fault, Player -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL')
foreach ($r in $failed) { Write-Host "  FAIL $($r.Mode): $($r.Problem)" -ForegroundColor Red }
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logDir 'results.json') -Encoding UTF8
if ($failed) { Write-Host "  $($failed.Count) of $(@($results).Count) network modes failed. Logs: $logDir" -ForegroundColor Red; exit 1 }
Write-Host "  all $(@($results).Count) network modes passed" -ForegroundColor Green
exit 0
