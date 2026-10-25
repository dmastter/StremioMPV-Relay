#Requires -Version 5.1
<#
.SYNOPSIS
  Tests tools\relay\relay.cs: builds relay.exe, plays the network tests' video through it from
  flaky_server.py with mpv.com in real time, once per fault mode, and checks its HTTP side directly.

.DESCRIPTION
  Every mode gets its own fault server and relay; all modes play at the same time, with the network
  options of config\mpv.conf (read like run-network-tests.ps1 does), for -PlaySeconds of real time. A
  small probe script counts how often playback stopped to wait for data (paused-for-cache) after the
  first 5 s of video. A mode passes when playback reaches the end with reason eof, never stopped to
  wait for data after those 5 s, the fault really happened, and the relay's log holds no url, host,
  port, query string or token.
  slowall runs every connection at 0.6 x the video's bitrate, so only parallel connections keep up.
  Before playback, full downloads through the relay (some with faults) are compared with the file, and
  the relay's answers to a bad token, HEAD, ranges and an unsatisfiable range are checked. Two more
  relays check that it exits by itself when its parent process ends and after --idle-exit.

.PARAMETER Mpv          mpv.com
.PARAMETER Ffmpeg       ffmpeg.exe, to generate the test video
.PARAMETER Python       python.exe for the test server
.PARAMETER OpenSsl      openssl.exe, for the certificates of the tls-* modes
.PARAMETER WorkDir      relay.exe and logs go to <WorkDir>\relay and <WorkDir>\logs\relay; the video is shared
                        with the network tests (<WorkDir>\network)
.PARAMETER Conf         mpv.conf to take the network options from
.PARAMETER Modes        Fault modes to play through the relay (tls-<mode> serves https)
.PARAMETER HashModes    Fault modes for the full-download comparisons
.PARAMETER Duration     Length of the generated video in seconds
.PARAMETER PlaySeconds  How much of it to play, in real time
.PARAMETER Connections  --connections for the playback relays (1 shows that slowall then stalls)
#>
param(
    [string]$Mpv,
    [string]$Ffmpeg,
    [string]$Python,
    [string]$OpenSsl,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'stremiompv-relay-tests'),
    [string]$Conf = (Join-Path $PSScriptRoot '..\..\config\mpv.conf'),
    [string[]]$Modes = @('ok', 'close', 'fin', 'close503', '503', 'stall', 'slow', 'slowall', 'tls-ok', 'tls-slow'),
    [string[]]$HashModes = @('ok', 'close', 'fin', 'stall', 'slow'),
    [int]$Duration = 120,
    [int]$PlaySeconds = 60,
    [int]$Connections = 4
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture

$Mpv = Resolve-Mpv $Mpv
$Python = Resolve-Python $Python
$server = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\network\flaky_server.py')).ProviderPath
$Modes = @($Modes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$HashModes = @($HashModes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
$relayDir = Join-Path $WorkDir 'relay'
$videoDir = Join-Path $WorkDir 'network'
$logDir = Join-Path $WorkDir 'logs\relay'
New-Item -ItemType Directory -Force -Path $relayDir, $videoDir, $logDir | Out-Null
# two runs in one work folder would delete each other's logs and ready files, and the second couldn't
# rebuild relay.exe while the first runs it: the second one stops here instead
try { $lock = [IO.File]::Open((Join-Path $relayDir 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] { throw "another relay test run is using $WorkDir (wait for it, or pass another -WorkDir)" }
trap { if ($lock) { $lock.Close() }; break }
Get-ChildItem -LiteralPath $logDir -File | Remove-Item
Get-ChildItem -LiteralPath $relayDir -File -Filter 'ready-*' | Remove-Item

# ------------------------------------------------------------------ build
Write-Section 'Building relay.exe'
$relayExe = Join-Path $relayDir 'relay.exe'
& (Join-Path $PSScriptRoot '..\..\tools\relay\build.ps1') -Out $relayExe
if ($LASTEXITCODE -ne 0) { throw 'tools\relay\build.ps1 failed' }
Write-Host "    $relayExe"

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

# ------------------------------------------------------------------ test video (the network tests' one)
$video = Join-Path $videoDir "video-$($Duration)s.mkv"
if (-not (Test-Path -LiteralPath $video)) {
    $Ffmpeg = Resolve-Ffmpeg $Ffmpeg
    Write-Section "Generating a $Duration s test video"
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
$bitrate = $size / $Duration
# slow: one connection at a tenth of the bitrate, which the relay must replace. slowall: every
# connection at 0.6 x the bitrate, so only several at once keep up (4 x 0.6 = 2.4 x)
$slowRate = @{ slow = [long]($bitrate / 10); slowall = [long]($bitrate * 0.6) }
Write-Host "    video: $video ($([math]::Round($size / 1MB, 1).ToString($inv)) MB, $([math]::Round($bitrate / 1KB).ToString($inv)) KB/s); faults at byte $faultAt (30%)"

# ------------------------------------------------------------------ certificates for https
$certDir = Join-Path $relayDir 'certs'
if (@($Modes + $HashModes) -like 'tls-*') {
    $OpenSsl = Resolve-OpenSsl $OpenSsl
    Write-Section 'Making a test CA and a certificate for 127.0.0.1'
    if (Test-Path -LiteralPath $certDir) { Remove-Item -LiteralPath $certDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $certDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $certDir 'server.ext'), "basicConstraints=CA:FALSE`nkeyUsage=digitalSignature,keyEncipherment`nextendedKeyUsage=serverAuth`nsubjectAltName=IP:127.0.0.1,DNS:localhost`n")
    $steps = @(
        @('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=StremioMPV Relay relay test CA', '-keyout', "$certDir\ca.key", '-out', "$certDir\ca.pem"),
        @('req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=127.0.0.1', '-keyout', "$certDir\server.key", '-out', "$certDir\server.csr"),
        @('x509', '-req', '-days', '2', '-in', "$certDir\server.csr", '-CA', "$certDir\ca.pem", '-CAkey', "$certDir\ca.key", '-CAcreateserial', '-extfile', "$certDir\server.ext", '-out', "$certDir\server.pem"))
    foreach ($a in $steps) { if ((Invoke-Native $OpenSsl $a -Quiet) -ne 0) { throw "openssl $($a[0]) failed: $OpenSsl" } }
    Write-Host "    $certDir"
}

# ------------------------------------------------------------------ probe: stops to wait for data
$probe = Join-Path $relayDir 'probe.lua'
[IO.File]::WriteAllText($probe, @'
-- counts how often playback waited for data (paused-for-cache) after the first 5 s of video, and the
-- least video buffered ahead after those 5 s (the margin)
local pos, duration, stalls, early, waited, since, ahead = 0, 0, 0, 0, 0, nil, -1
mp.observe_property("time-pos", "number", function(_, v) if v then pos = v end end)
mp.observe_property("demuxer-cache-duration", "number", function(_, v)
    if v and pos >= 5 and (ahead < 0 or v < ahead) then ahead = v end
end)
mp.observe_property("duration", "number", function(_, v) if v then duration = v end end)
mp.observe_property("paused-for-cache", "bool", function(_, v)
    if v then
        since = mp.get_time()
        if pos >= 5 then stalls = stalls + 1 else early = early + 1 end
    elseif since then
        waited = waited + mp.get_time() - since
        since = nil
    end
end)
mp.register_event("end-file", function(e)
    print(("RESULT pos=%.2f duration=%.2f reason=%s stalls=%d early=%d waited=%.2f ahead=%.1f"):format(
        pos, duration, tostring(e.reason), stalls, early, waited, ahead))
end)
'@.Replace("`r`n", "`n"))

# a second test server for what flaky_server.py doesn't do. expire: /link redirects to a cdn url that
# serves 3 requests and then answers 403, like a debrid link that expired (a count, not a time, so it
# happens whatever the speed). noranges: ignores Range
$linkServer = Join-Path $relayDir 'link_server.py'
[IO.File]::WriteAllText($linkServer, @'
import http.server, os, sys, threading, time
path, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
size = os.path.getsize(path)
lock = threading.Lock()
issued = {}

def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def empty(self, code, headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.close_connection = False   # see below

    def do_GET(self):
        start, end, ranged = 0, size - 1, False
        rng = self.headers.get("Range")
        if mode == "expire":
            if self.path.startswith("/link"):
                with lock:
                    gen = len(issued) + 1
                    issued[gen] = 0
                log(f"redirect to cdn link {gen}")
                return self.empty(302, [("Location", f"/cdn/{gen}/video.mkv?sig=not-for-logs")])
            try:
                gen = int(self.path.split("/")[2])
            except (IndexError, ValueError):
                return self.empty(404)
            with lock:
                served = issued.get(gen)
                if served is not None and served < 3:
                    issued[gen] = served + 1
            if served is None or served >= 3:
                log(f"FAULT cdn link {gen} expired -> 403")
                return self.empty(403)
            if rng and rng.startswith("bytes="):
                a, b = rng[6:].split(",")[0].split("-")
                start, end = (max(0, size - int(b)), size - 1) if a == "" else (int(a), min(int(b), size - 1) if b else size - 1)
                ranged = True
                if start >= size:
                    return self.empty(416, [("Content-Range", f"bytes */{size}")])
        elif rng:
            log("FAULT range ignored -> 200")
        log(f"req range {start}-{end}")
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Content-Length", str(end - start + 1))
        if ranged:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            # the client closes: a server-side shutdown right after the last write loses the tail on
            # some windows builds' loopback (flaky_server.py does the same)
            self.close_connection = False
        except OSError:
            self.close_connection = True

server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
log(f"serving {os.path.basename(path)} ({size} bytes), mode {mode}")
server.serve_forever()
'@.Replace("`r`n", "`n"))

function ConvertTo-Base64Url([string]$Text) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Start-Relay([string]$Name, [string[]]$Extra = @()) {
    $ready = Join-Path $relayDir "ready-$Name.json"
    $a = @('--ready-file', $ready, '--log', (Join-Path $logDir "relay-$Name.log")) + $Extra
    if ($Extra -notcontains '--parent-pid') { $a += @('--parent-pid', "$PID") }
    $p = Start-LoggedProcess -FilePath $relayExe -Arguments $a -LogBase (Join-Path $logDir "relay-$Name")
    [pscustomobject]@{ Name = $Name; Process = $p; Ready = $ready; Info = $null; Started = [DateTime]::Now }
}

function Wait-Relay($Relay, [int]$TimeoutMs = 20000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Relay.Ready)) {
        if ($Relay.Process.HasExited) { throw "relay $($Relay.Name) exited with code $($Relay.Process.ExitCode) (see $logDir\relay-$($Relay.Name).err)" }
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { throw "relay $($Relay.Name) wrote no ready file in $($TimeoutMs / 1000) s" }
        Start-Sleep -Milliseconds 100
    }
    $Relay.Info = [IO.File]::ReadAllText($Relay.Ready) | ConvertFrom-Json
    $Relay.Started = [DateTime]::Now
}

function Get-RelayUrl($Relay, [string]$Upstream) {
    "http://127.0.0.1:$($Relay.Info.port)/$($Relay.Info.token)/$(ConvertTo-Base64Url $Upstream)/video.mkv"
}

# GET or HEAD through the relay; error statuses come back as results too
function Invoke-Relay([string]$Url, [string]$Method = 'GET', [long[]]$Range = @()) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Proxy = $null
    $req.KeepAlive = $false
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    if ($Range.Count -eq 2) { $req.AddRange($Range[0], $Range[1]) } elseif ($Range.Count -eq 1) { $req.AddRange($Range[0]) }
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
    try {
        $ms = New-Object IO.MemoryStream
        if ($Method -ne 'HEAD') { $resp.GetResponseStream().CopyTo($ms) }
        [pscustomobject]@{ Status = [int]$resp.StatusCode; Length = $resp.ContentLength; Range = $resp.Headers['Content-Range']; Body = $ms.ToArray() }
    } finally { $resp.Close() }
}

function Read-FileRange([string]$Path, [long]$Offset, [int]$Count) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] $Count
        [void]$fs.Seek($Offset, 'Begin')
        $got = 0
        while ($got -lt $Count) { $n = $fs.Read($b, $got, $Count - $got); if ($n -le 0) { break }; $got += $n }
        $b
    } finally { $fs.Close() }
}

function Test-SameBytes([byte[]]$A, [byte[]]$B) { [Convert]::ToBase64String($A) -eq [Convert]::ToBase64String($B) }

# the relay keeps its log open for writing
function Read-SharedText([string]$Path) {
    $fs = New-Object IO.FileStream($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() }
}

# what a relay log must never contain: urls, hosts, query strings, the upstream port, the token
function Find-Leak([string]$Path, [int]$UpstreamPort, [string[]]$Secrets) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'no log' }
    $text = Read-SharedText $Path
    $found = @()
    if ($text -match '(?i)http') { $found += '"http"' }
    if ($text.Contains('?')) { $found += 'a query string' }
    if ($text -match '(?i)127\.0\.0\.1|localhost') { $found += 'a host' }
    if ($UpstreamPort -and $text -match "\b$UpstreamPort\b") { $found += "the server's port $UpstreamPort" }
    foreach ($s in $Secrets) { if ($s -and $text.Contains($s)) { $found += 'the token or the encoded url' } }
    $found -join ', '
}

function Get-RequestLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($l in (Read-SharedText $Path) -split "`r?`n") {
        if ($l -match '-> (\d+).*, sent (\d+) in ([\d.]+) s \(([\d.]+) MB/s\), connections (\d+), hedged (\d+), retries (\d+)(?:, cdn [\d.]+ MB/s per connection)?: (.*)$') {
            [pscustomobject]@{ Status = [int]$Matches[1]; Sent = [long]$Matches[2]; Seconds = [double]::Parse($Matches[3], $inv)
                MBps = [double]::Parse($Matches[4], $inv); Connections = [int]$Matches[5]; Hedged = [int]$Matches[6]; Retries = [int]$Matches[7]; Outcome = $Matches[8] }
        }
    }
}

# ------------------------------------------------------------------ servers and relays
Write-Section "Starting the fault servers and relays: $($Modes -join ', '); downloads: $($HashModes -join ', ')"
$runs = @()
$checks = New-Object System.Collections.ArrayList
$all = @()
function Add-Check([string]$Name, [string]$Problem, [string]$Detail) {
    [void]$checks.Add([pscustomobject]@{ Check = $Name; Result = $(if ($Problem) { 'FAIL' } else { 'PASS' }); Detail = $(if ($Problem) { $Problem } else { $Detail }) })
}
$exitParent = $null; $exitIdle = $null; $parentProc = $null
try {
    $jobs = @(foreach ($m in $Modes) { [pscustomobject]@{ Name = "play-$m"; Mode = $m; Kind = 'play' } }) +
            @(foreach ($m in @($HashModes) + 'expire', 'noranges') { [pscustomobject]@{ Name = "get-$m"; Mode = $m; Kind = 'get' } }) +
            @([pscustomobject]@{ Name = 'api'; Mode = 'ok'; Kind = 'api' }, [pscustomobject]@{ Name = 'cancel'; Mode = 'slowall'; Kind = 'cancel' })
    foreach ($j in $jobs) {
        $port = Get-FreeTcpPort
        $tls = $j.Mode -like 'tls-*'
        $fault = $j.Mode -replace '^tls-', ''
        if ($fault -in 'expire', 'noranges') { $srvArgs = @('-I', '-u', $linkServer, $video, "$port", $fault) }
        else { $srvArgs = @('-I', '-u', $server, $video, "$port", $fault, '--fault-at', "$faultAt") }
        if ($slowRate[$fault]) { $srvArgs += @('--slow-rate', "$($slowRate[$fault])") }
        if ($tls) { $srvArgs += @('--tls', "$certDir\server.pem", "$certDir\server.key") }
        $srv = Start-LoggedProcess -FilePath $Python -Arguments $srvArgs -LogBase (Join-Path $logDir "server-$($j.Name)")
        $j | Add-Member -NotePropertyName Port -NotePropertyValue $port
        $j | Add-Member -NotePropertyName Server -NotePropertyValue $srv
        $j | Add-Member -NotePropertyName Upstream -NotePropertyValue "$(if ($tls) { 'https' } else { 'http' })://127.0.0.1:$port/$(if ($fault -eq 'expire') { 'link' } else { 'video.mkv' })?token=not-for-logs"
        $all += $j
    }
    foreach ($j in $all) {
        if (-not (Wait-TcpPort $j.Port 60000)) { throw "the test server for $($j.Name) didn't start (see $logDir\server-$($j.Name).err)" }
        $extra = @()
        if ($j.Mode -like 'tls-*') { $extra += @('--insecure-test-ca', "$certDir\ca.pem") }
        if ($j.Kind -eq 'api') { $extra += @('--port', "$(Get-FreeTcpPort)", '--token', '0123456789abcdef0123456789abcdef') }
        if ($j.Kind -eq 'cancel') { $extra += @('--port', "$(Get-FreeTcpPort)", '--token', 'fedcba9876543210fedcba9876543210') }
        if ($j.Kind -eq 'play') { $extra += @('--connections', "$Connections") }
        $j | Add-Member -NotePropertyName Relay -NotePropertyValue (Start-Relay $j.Name $extra)
    }
    # relays that must exit by themselves: when their parent ends, and when idle
    $parentProc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 4' -WindowStyle Hidden -PassThru
    $null = $parentProc.Handle
    $exitParent = Start-Relay 'exit-parent' @('--parent-pid', "$($parentProc.Id)")
    $exitIdle = Start-Relay 'exit-idle' @('--idle-exit', '5')
    foreach ($j in $all) { Wait-Relay $j.Relay }
    Wait-Relay $exitParent
    Wait-Relay $exitIdle

    # -------------------------------------------------------------- full downloads, compared with the file
    $want = (Get-FileHash -LiteralPath $video -Algorithm SHA256).Hash
    $gets = foreach ($j in $all | Where-Object Kind -eq 'get') {
        $out = Join-Path $relayDir "download-$($j.Mode).bin"
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out }
        $p = Start-LoggedProcess -FilePath "$env:SystemRoot\System32\curl.exe" -Arguments @('-sS', '-o', $out, (Get-RelayUrl $j.Relay $j.Upstream)) -LogBase (Join-Path $logDir "curl-$($j.Mode)")
        [pscustomobject]@{ Job = $j; Process = $p; Out = $out }
    }

    # -------------------------------------------------------------- answers to single requests
    Write-Section 'Checking single requests'
    $api = $all | Where-Object Kind -eq 'api'
    $apiUrl = Get-RelayUrl $api.Relay $api.Upstream
    $p = "port $($api.Relay.Info.port), token as given"
    Add-Check 'given port and token' $(if ($api.Relay.Info.token -ne '0123456789abcdef0123456789abcdef') { 'the ready file has another token' }) $p
    $r = Invoke-Relay ($apiUrl -replace '/0123456789abcdef0123456789abcdef/', '/0123456789abcdef0123456789abcdee/')
    Add-Check 'wrong token' $(if ($r.Status -ne 403) { "status $($r.Status) instead of 403" }) '403'
    $r = Invoke-Relay ($apiUrl -replace '/[A-Za-z0-9_-]+/video\.mkv$', '/not*base64/video.mkv')
    Add-Check 'bad url' $(if ($r.Status -ne 400) { "status $($r.Status) instead of 400" }) '400'
    $r = Invoke-Relay $apiUrl 'HEAD'
    Add-Check 'HEAD' $(if ($r.Status -ne 200 -or $r.Length -ne $size) { "status $($r.Status), length $($r.Length) (expected 200, $size)" }) "200, Content-Length $size"
    $r = Invoke-Relay $apiUrl 'HEAD' @(100, 199)
    $problem = if ($r.Status -ne 206 -or $r.Length -ne 100 -or $r.Range -ne "bytes 100-199/$size") { "status $($r.Status), length $($r.Length), range '$($r.Range)'" }
    Add-Check 'HEAD bytes=100-199' $problem "206, $($r.Range)"
    $r = Invoke-Relay $apiUrl 'GET' @(100, 199)
    $problem = if ($r.Status -ne 206 -or $r.Length -ne 100 -or $r.Range -ne "bytes 100-199/$size") { "status $($r.Status), length $($r.Length), range '$($r.Range)'" }
    elseif (-not (Test-SameBytes $r.Body (Read-FileRange $video 100 100))) { "$($r.Body.Length) bytes that differ from the file" }
    Add-Check 'GET bytes=100-199' $problem "206, $($r.Range), same bytes as the file"
    $r = Invoke-Relay $apiUrl 'GET' @(-1000)
    $problem = if ($r.Status -ne 206 -or $r.Range -ne "bytes $($size - 1000)-$($size - 1)/$size") { "status $($r.Status), range '$($r.Range)'" }
    elseif (-not (Test-SameBytes $r.Body (Read-FileRange $video ($size - 1000) 1000))) { 'bytes differ from the file' }
    Add-Check 'GET bytes=-1000' $problem "206, $($r.Range), same bytes"
    $a = [long]($size / 2)
    $r = Invoke-Relay $apiUrl 'GET' @($a, ($a + 9999999))
    $problem = if ($r.Status -ne 206 -or $r.Length -ne 10000000) { "status $($r.Status), length $($r.Length)" }
    elseif (-not (Test-SameBytes $r.Body (Read-FileRange $video $a 10000000))) { 'bytes differ from the file' }
    Add-Check 'GET 10 MB from the middle' $problem "206, $($r.Range), same bytes"
    $r = Invoke-Relay $apiUrl 'GET' @($size)
    Add-Check 'GET past the end' $(if ($r.Status -ne 416 -or $r.Range -ne "bytes */$size") { "status $($r.Status), range '$($r.Range)'" }) "416, $($r.Range)"
    $prio = (Get-Process -Id $api.Relay.Process.Id).PriorityClass
    Add-Check 'priority' $(if ("$prio" -ne 'BelowNormal') { "priority $prio" }) "$prio"

    # a player that goes away (it does on every seek) must take the relay's connections with it
    $cancel = $all | Where-Object Kind -eq 'cancel'
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', [int]$cancel.Relay.Info.port)
    $st = $c.GetStream()
    $st.ReadTimeout = 15000
    $q = [Text.Encoding]::ASCII.GetBytes("GET $(([Uri](Get-RelayUrl $cancel.Relay $cancel.Upstream)).PathAndQuery) HTTP/1.1`r`nHost: 127.0.0.1`r`nRange: bytes=0-`r`n`r`n")
    $st.Write($q, 0, $q.Length)
    $buf = New-Object byte[] 65536
    $got = 0
    while ($got -lt 300000) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $got += $n }
    $c.Close()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $srvOut = Join-Path $logDir "server-$($cancel.Name).out"
    do {
        Start-Sleep -Milliseconds 200
        $lines = @(Get-Content -LiteralPath $srvOut -ErrorAction SilentlyContinue | ForEach-Object { $_ -split '(?=\d\d:\d\d:\d\d )' } | Where-Object { $_ })
        $open = @($lines | Where-Object { $_ -match ' req (\d+) range ' } | ForEach-Object { $Matches[1] } |
            Where-Object { $n = $_; -not ($lines -match " req $n -> ") })
    } while ($open.Count -and $sw.Elapsed.TotalSeconds -lt 5)
    $started = @($lines -match ' req \d+ range ').Count
    $relayLog = Read-SharedText (Join-Path $logDir 'relay-cancel.log')
    $problem = if ($open.Count) { "$($open.Count) of $started upstream requests still open 5 s after the client left" }
        elseif ($relayLog -notmatch 'client closed') { 'the relay did not log the client leaving' }
    Add-Check 'client leaves' $problem ([string]::Format($inv, 'all {0} upstream requests closed within {1:0.0} s', $started, $sw.Elapsed.TotalSeconds))

    # the player's side restarts a relay that died with the same port and token, so ffmpeg's reconnect to
    # the same url works: kill one in the middle of a transfer and start it again
    $old = $cancel.Relay.Info
    $c = Start-LoggedProcess -FilePath "$env:SystemRoot\System32\curl.exe" -Arguments @('-s', '-o', 'NUL', (Get-RelayUrl $cancel.Relay $cancel.Upstream)) -LogBase (Join-Path $logDir 'curl-restart')
    Start-Sleep -Seconds 1
    Stop-ProcessTree $cancel.Relay.Process
    Remove-Item -LiteralPath $cancel.Relay.Ready
    $cancel.Relay = Start-Relay 'cancel' @('--port', "$($old.port)", '--token', $old.token)
    Wait-Relay $cancel.Relay
    $r = Invoke-Relay (Get-RelayUrl $cancel.Relay $cancel.Upstream) 'GET' @(1000, 1999)
    Stop-ProcessTree $c
    $problem = if ($cancel.Relay.Info.port -ne $old.port -or $cancel.Relay.Info.token -ne $old.token) { "came back on port $($cancel.Relay.Info.port) with another token" }
        elseif ($r.Status -ne 206 -or -not (Test-SameBytes $r.Body (Read-FileRange $video 1000 1000))) { "status $($r.Status) after the restart" }
    Add-Check 'restart on the same port' $problem "same port and token right after a kill mid-transfer; bytes=1000-1999 ok"

    foreach ($g in $gets) {
        if (-not $g.Process.WaitForExit(120000)) { Stop-ProcessTree $g.Process }
        $secs = ($g.Process.ExitTime - $g.Process.StartTime).TotalSeconds
        $got = if (Test-Path -LiteralPath $g.Out) { (Get-FileHash -LiteralPath $g.Out -Algorithm SHA256).Hash } else { '' }
        $faults = @(Get-Content -LiteralPath (Join-Path $logDir "server-$($g.Job.Name).out") -ErrorAction SilentlyContinue | Where-Object { $_ -cmatch ' FAULT ' })
        $problem = if ($g.Process.ExitCode -ne 0) { "curl exit code $($g.Process.ExitCode): $(Get-Content -LiteralPath (Join-Path $logDir "curl-$($g.Job.Mode).err") -Raw)" }
            elseif ($got -ne $want) { 'the download differs from the file' }
            elseif ($g.Job.Mode -ne 'ok' -and -not $faults) { 'the fault was never injected' }
        $req = Get-RequestLine (Join-Path $logDir "relay-$($g.Job.Name).log") | Select-Object -Last 1
        # a stalled or crawling connection must be replaced, well before the 15 s read timeout would
        if (-not $problem -and $g.Job.Mode -in 'stall', 'slow' -and (-not $req.Hedged -or $secs -gt 12)) {
            $problem = "the $($g.Job.Mode) connection wasn't replaced in time ($([int]$secs) s, hedged $($req.Hedged))"
        }
        $label = @{ expire = 'expiring redirect'; noranges = 'no range support' }[$g.Job.Mode]
        Add-Check "download ($(if ($label) { $label } else { $g.Job.Mode }))" $problem ([string]::Format($inv,
            'identical, {0:0.0} s, {1:0.00} MB/s, connections {2}, hedged {3}, retries {4}', $secs, $req.MBps, $req.Connections, $req.Hedged, $req.Retries))
        if (Test-Path -LiteralPath $g.Out) { Remove-Item -LiteralPath $g.Out }
    }

    # -------------------------------------------------------------- real-time playback
    Write-Section "Playing $PlaySeconds s in real time through the relay: $($Modes -join ', ')"
    $limit = $PlaySeconds + 60
    foreach ($j in $all | Where-Object Kind -eq 'play') {
        $a = @('--no-config', '--vo=null', '--ao=null', '--msg-color=no', '--msg-level=all=warn,probe=info', "--script=$probe", "--end=$PlaySeconds") +
             $netArgs + (Get-RelayUrl $j.Relay $j.Upstream)
        $p = Start-LoggedProcess -FilePath $Mpv -Arguments $a -LogBase (Join-Path $logDir "mpv-$($j.Mode)")
        $runs += [pscustomobject]@{ Job = $j; Player = $p; Watch = [Diagnostics.Stopwatch]::StartNew(); Hung = $false }
    }
    while (@($runs | Where-Object { -not $_.Player.HasExited -and -not $_.Hung }).Count) {
        foreach ($r in $runs) {
            if (-not $r.Player.HasExited -and -not $r.Hung -and $r.Watch.Elapsed.TotalSeconds -gt $limit) { Stop-ProcessTree $r.Player; $r.Hung = $true }
        }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds 1   # the relays log a request when the player has closed it
    foreach ($j in $all) {
        $j.Relay.Process.Refresh()
        $j | Add-Member -NotePropertyName Cpu -NotePropertyValue $j.Relay.Process.TotalProcessorTime.TotalSeconds
        $j | Add-Member -NotePropertyName PeakMB -NotePropertyValue ([math]::Round($j.Relay.Process.PeakWorkingSet64 / 1MB))
    }

    # -------------------------------------------------------------- the relays that exit by themselves
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((-not $exitParent.Process.HasExited -or -not $exitIdle.Process.HasExited) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 200 }
    if (-not $parentProc.HasExited) { $problem = 'the parent process is still running' }
    elseif (-not $exitParent.Process.HasExited) { $problem = 'still running after its parent process ended' }
    else {
        $after = ($exitParent.Process.ExitTime - $parentProc.ExitTime).TotalSeconds
        $problem = if ($after -gt 4) { "exited $($after.ToString('0.0', $inv)) s after its parent" } elseif (Test-Path -LiteralPath $exitParent.Ready) { 'left its ready file behind' }
    }
    Add-Check 'exits with its parent' $problem $(if ($exitParent.Process.HasExited) { "exited $(($exitParent.Process.ExitTime - $parentProc.ExitTime).TotalSeconds.ToString('0.0', $inv)) s after its parent; ready file removed" })
    if (-not $exitIdle.Process.HasExited) { $problem = 'still running long after --idle-exit 5' }
    else {
        $idle = ($exitIdle.Process.ExitTime - $exitIdle.Started).TotalSeconds
        $problem = if ($idle -lt 4) { "exited after $($idle.ToString('0.0', $inv)) s, before --idle-exit 5" } elseif ($idle -gt 9) { "exited after $($idle.ToString('0.0', $inv)) s" } elseif (Test-Path -LiteralPath $exitIdle.Ready) { 'left its ready file behind' }
    }
    Add-Check 'exits when idle (--idle-exit 5)' $problem $(if ($exitIdle.Process.HasExited) { "exited after $(($exitIdle.Process.ExitTime - $exitIdle.Started).TotalSeconds.ToString('0.0', $inv)) s; ready file removed" })
} finally {
    foreach ($r in $runs) { Stop-ProcessTree $r.Player }
    foreach ($j in $all) { if ($j.Relay) { Stop-ProcessTree $j.Relay.Process }; Stop-ProcessTree $j.Server }
    foreach ($x in $exitParent, $exitIdle) { if ($x) { Stop-ProcessTree $x.Process } }
    if ($parentProc) { Stop-ProcessTree $parentProc }
}

# ------------------------------------------------------------------ check
foreach ($j in $all) {
    $leak = Find-Leak (Join-Path $logDir "relay-$($j.Name).log") $j.Port @($j.Relay.Info.token, (ConvertTo-Base64Url $j.Upstream))
    Add-Check "log of relay $($j.Name)" $(if ($leak) { "contains $leak" }) 'no url, host, port, query or token'
}
$results = foreach ($r in $runs) {
    $j = $r.Job
    $base = Join-Path $logDir "mpv-$($j.Mode)"
    $out = @(Get-Content -LiteralPath "$base.out", "$base.err" -ErrorAction SilentlyContinue)
    $srvLog = @(Get-Content -LiteralPath (Join-Path $logDir "server-$($j.Name).out") -ErrorAction SilentlyContinue)
    $res = $out | Where-Object { $_ -match 'RESULT pos=' } | Select-Object -Last 1
    $pos = $null; $reason = ''; $stalls = $early = 0; $waited = 0; $ahead = '-'
    if ($res -match 'pos=([\d.]+) duration=([\d.]+) reason=(\S+) stalls=(\d+) early=(\d+) waited=([\d.]+) ahead=(-?[\d.]+)') {
        $pos = [double]::Parse($Matches[1], $inv); $reason = $Matches[3]
        $stalls = [int]$Matches[4]; $early = [int]$Matches[5]; $waited = [double]::Parse($Matches[6], $inv); $ahead = $Matches[7]
    }
    $faults = @($srvLog | Where-Object { $_ -cmatch ' FAULT ' } | ForEach-Object { ($_ -csplit ' FAULT ', 2)[1] })
    $requests = @($srvLog | Where-Object { $_ -match ' req \d+ range ' }).Count
    $lines = @(Get-RequestLine (Join-Path $logDir "relay-$($j.Name).log"))
    $main = $lines | Sort-Object Sent -Descending | Select-Object -First 1
    $problem = if ($r.Hung) { "hung: still running after $limit s" }
        elseif ($null -eq $pos) { "no result (mpv exit code $($r.Player.ExitCode))" }
        elseif ($reason -ne 'eof' -or $pos -lt $PlaySeconds - 1.5) { "stopped at $($pos.ToString('0.0', $inv)) of $PlaySeconds s ($reason)" }
        elseif ($stalls -and $j.Mode -eq 'slowall') {
            # tells a relay that doesn't keep its connections busy from a test server that can't keep its rate
            "playback waited for data $stalls time(s) after the first 5 s; the relay got $(if ($main) { $main.MBps.ToString('0.00', $inv) } else { '?' }) MB/s, " +
            "$Connections connections at 0.6 x the bitrate make $(($Connections * $slowRate.slowall / 1MB).ToString('0.00', $inv)) MB/s and the video needs $(($bitrate / 1MB).ToString('0.00', $inv))"
        }
        elseif ($stalls) { "playback waited for data $stalls time(s) after the first 5 s" }
        elseif ($j.Mode -notin 'ok', 'tls-ok' -and -not $faults) { 'the fault was never injected, so nothing was tested' }
    [pscustomobject]@{
        Mode = $j.Mode; Result = $(if ($problem) { 'FAIL' } else { 'PASS' })
        Reached = $(if ($null -ne $pos) { $pos.ToString('0.0', $inv) } else { '-' })
        Stalls = $stalls; Early = $early; Waited = $waited.ToString('0.0', $inv); 'Min ahead' = $ahead
        Requests = $requests; Conns = ($lines | Measure-Object Connections -Sum).Sum
        Hedged = ($lines | Measure-Object Hedged -Sum).Sum; Retries = ($lines | Measure-Object Retries -Sum).Sum
        'MB/s' = $(if ($main) { $main.MBps.ToString('0.00', $inv) } else { '-' })
        'CPU s' = $j.Cpu.ToString('0.0', $inv); 'Peak MB' = $j.PeakMB
        Fault = ($faults -join '; '); Problem = $problem
    }
}

Write-Section 'Relay playback results'
$results | Format-Table Mode, Result, Reached, Stalls, Early, Waited, 'Min ahead', Requests, Conns, Hedged, Retries, 'MB/s', 'CPU s', 'Peak MB', Fault -AutoSize | Out-String -Width 240 | Write-Host
Write-Section 'Relay checks'
$checks | Format-Table Check, Result, Detail -AutoSize | Out-String -Width 240 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL') + @($checks | Where-Object Result -eq 'FAIL')
$lock.Close()
foreach ($r in $results | Where-Object Result -eq 'FAIL') { Write-Host "  FAIL $($r.Mode): $($r.Problem)" -ForegroundColor Red }
foreach ($c in $checks | Where-Object Result -eq 'FAIL') { Write-Host "  FAIL $($c.Check): $($c.Detail)" -ForegroundColor Red }
@{ playback = @($results); checks = @($checks) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logDir 'results.json') -Encoding UTF8
if ($failed) { Write-Host "  $($failed.Count) relay test(s) failed. Logs: $logDir" -ForegroundColor Red; exit 1 }
Write-Host "  all $(@($results).Count) playback modes and $($checks.Count) checks passed" -ForegroundColor Green
exit 0
