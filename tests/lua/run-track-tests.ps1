#Requires -Version 5.1
<#
.SYNOPSIS
  Runs config\scripts\original-tracks.lua in mpv.com against every generated fixture, with a fake
  Stremio poking at the player, and checks what the script ends up with.

.DESCRIPTION
  Every case runs in its own mpv.com (--no-config --vo=null --ao=null, real time) with
  tests\lua\harness.lua and the repo's script, which gets the repo's script-opts. Cases run in parallel.
  Checks per case: final sid, subtitles visible, no hidden secondary track left, audio track,
  Stremio's sub-scale kept (unless sub_scale forces one), default colors softened to sub_alpha,
  custom colors kept, the file's tracks are what the fixture declared, and no Lua errors.

.PARAMETER Mpv          mpv.com (default: PATH, then common locations)
.PARAMETER Ffmpeg       ffmpeg.exe, to generate the fixtures if needed
.PARAMETER WorkDir      Fixtures go to <WorkDir>\fixtures, logs to <WorkDir>\logs\lua
.PARAMETER Script       The track script under test
.PARAMETER ScriptOpts   Its options file (passed as --script-opts, since --no-config skips script-opts\)
.PARAMETER Only         Run only these case names (wildcards allowed)
.PARAMETER MaxParallel  How many mpv instances at once
#>
param(
    [string]$Mpv,
    [string]$Ffmpeg,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'stremiompv-relay-tests'),
    [string]$Script = (Join-Path $PSScriptRoot '..\..\config\scripts\original-tracks.lua'),
    [string]$ScriptOpts = (Join-Path $PSScriptRoot '..\..\config\script-opts\original-tracks.conf'),
    [string[]]$Only,
    [int]$MaxParallel = 24
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture

$Mpv = Resolve-Mpv $Mpv
$Script = (Resolve-Path -LiteralPath $Script).ProviderPath
$harness = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'harness.lua')).ProviderPath
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
$fixDir = Join-Path $WorkDir 'fixtures'
$logDir = Join-Path $WorkDir 'logs\lua'

Write-Section 'Fixtures'
& (Join-Path $PSScriptRoot '..\fixtures\make-fixtures.ps1') -OutDir $fixDir -Ffmpeg $Ffmpeg
$manifest = [IO.File]::ReadAllText((Join-Path $fixDir 'manifest.json')) | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Get-ChildItem -LiteralPath $logDir -File | Remove-Item

# ------------------------------------------------------------------ what the repo's options imply
$opts = @{ sub_scale = '0'; sub_alpha = '0.88'; guard_seconds = '30' }   # the script's own defaults
foreach ($kv in (Read-KeyValueConf $ScriptOpts)) { $opts[$kv.Name] = $kv.Value }
$scriptOptArgs = @($opts.Keys | Sort-Object | ForEach-Object { "original-tracks-$_=$($opts[$_])" })
$forcedScale = [double]::Parse($opts.sub_scale, $inv)
$alpha = [double]::Parse($opts.sub_alpha, $inv)
if ($alpha -lt 1) { $alpha = [math]::Max(0.2, $alpha) }
$guard = [double]::Parse($opts.guard_seconds, $inv)
# the script writes the alpha with two decimals; mpv may round or truncate it to a byte
$a2 = [double]::Parse($alpha.ToString('0.00', $inv), $inv)
$softAlphas = @([int][math]::Floor($a2 * 255), [int][math]::Round($a2 * 255)) | ForEach-Object { '{0:X2}' -f $_ } | Select-Object -Unique
$softens = $alpha -gt 0 -and $alpha -lt 1

$defaultStyle = @{ Scale = '0.66'; Text = '#FFFFFFFF'; Outline = '#FF000000' }   # stremio's 100% and default colors

function Get-ExpectedColor([string]$Given, [string]$Rgb) {
    if ($Given -and $Given.ToUpper() -ne "#FF$Rgb") { return $Given.ToUpper() }
    if ($softens) { return $softAlphas | ForEach-Object { "#$_$Rgb" } }
    "#FF$Rgb"
}

# the fake stremio: sid=no on load, its own audio and subtitle picks, then its size and colors
function Get-StremioInterference($Fixture, $Style) {
    $acts = @('0.05:sid=no', '0.5:aid=1')
    $firstEnglish = @($Fixture.subs | Where-Object { $_.lang -like 'en*' }) | Select-Object -First 1
    if ($firstEnglish) { $acts += "1:sid=$($firstEnglish.id)" }
    $acts + @('1.5:sid=no', "2:sub-scale=$($Style.Scale)", "2:sub-color=$($Style.Text)", "2:sub-border-color=$($Style.Outline)")
}

# a case is a fixture plus what the fake stremio does (-Style $null: no stremio at all) and extra actions
function Get-TestCase {
    param([string]$Name, $Fixture, $Style = $defaultStyle, [string[]]$Extra = @(), [string]$ExpectSid = $Fixture.expectSid,
          [int]$Quit = $Fixture.quit, [string]$About = $Fixture.about)
    $acts = @()
    if ($Style) { $acts += Get-StremioInterference -Fixture $Fixture -Style $Style }
    $acts += $Extra
    if ($Fixture.acts) { $acts += $Fixture.acts }
    [pscustomobject]@{
        Name = $Name; Fixture = $Fixture; About = $About; Acts = ($acts | Where-Object { $_ }) -join ';'
        ExpectSid = $ExpectSid; ExpectAid = $Fixture.expectAid; Quit = $Quit
        ExpectScale = $(if ($forcedScale -gt 0) { $forcedScale } elseif ($Style) { [double]::Parse($Style.Scale, $inv) } else { 1.0 })
        ExpectText = @(Get-ExpectedColor -Given $Style.Text -Rgb 'FFFFFF')
        ExpectOutline = @(Get-ExpectedColor -Given $Style.Outline -Rgb '000000')
        Process = $null; Watch = $null; Killed = $false; Log = Join-Path $logDir $Name
    }
}

# ------------------------------------------------------------------ cases
$fx = @{}; foreach ($f in $manifest.fixtures) { $fx[$f.name] = $f }
$cases = New-Object System.Collections.ArrayList
foreach ($f in $manifest.fixtures) { [void]$cases.Add((Get-TestCase -Name $f.name -Fixture $f)) }
$late = $guard + 10
$more = @(
    @{ Name = 'plain-mpv'; Fixture = $fx['tagged']; Style = $null
       About = 'standalone mpv: nobody else touches tracks, size or colors' }
    @{ Name = 'custom-style'; Fixture = $fx['single-english']; Style = @{ Scale = '0.495'; Text = '#FFFFFF00'; Outline = '#FF202020' }
       About = 'Stremio at 75% size with yellow text and a grey outline: all kept' }
    @{ Name = 'manual-off'; Fixture = $fx['single-english']; Extra = "${late}:sid=no"; ExpectSid = 'no'; Quit = $late + 10
       About = "the user turns subtitles off after the $guard s guard: respected" }
    @{ Name = 'manual-pick'; Fixture = $fx['tagged']; Extra = "${late}:sid=2"; ExpectSid = '2'; Quit = $late + 10
       About = "the user picks the SDH track after the $guard s guard: respected" }
    @{ Name = 'addon-no-english'; Fixture = $fx['no-english']; Extra = '2.5:!sub-add=addon.srt'
       ExpectSid = "$(@($fx['no-english'].subs).Count + 1)"; About = "no English embedded: Stremio's addon subtitle stays" }
    @{ Name = 'addon-fake-only'; Fixture = $fx['fake-only']; Extra = '2.5:!sub-add=addon.srt'
       ExpectSid = "$(@($fx['fake-only'].subs).Count + 1)"; About = 'English-tagged tracks are fake: the addon subtitle Stremio picked comes back' }
)
foreach ($m in $more) { [void]$cases.Add((Get-TestCase @m)) }
# powershell -File passes "a,b" as one string
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only) { $cases = @($cases | Where-Object { $n = $_.Name; @($Only | Where-Object { $n -like $_ }).Count -gt 0 }) }
if (-not $cases.Count) { throw "no case matches -Only $($Only -join ', ')" }

# ------------------------------------------------------------------ run
Write-Section "Running $($cases.Count) cases with $(Split-Path $Script -Leaf) (up to $MaxParallel at once, longest $(($cases | Measure-Object Quit -Maximum).Maximum) s)"
Write-Host "    mpv: $Mpv"
Write-Host "    script-opts: $($scriptOptArgs -join ', ')"
$queue = New-Object System.Collections.Queue
$cases | Sort-Object Quit -Descending | ForEach-Object { $queue.Enqueue($_) }
$running = New-Object System.Collections.ArrayList
try {
    while ($queue.Count -or $running.Count) {
        while ($queue.Count -and $running.Count -lt $MaxParallel) {
            $c = $queue.Dequeue()
            $so = @("harness-quit=$($c.Quit)", "harness-acts=$($c.Acts)") + $scriptOptArgs
            $a = @('--no-config', '--vo=null', '--ao=null', '--keep-open=yes', '--msg-color=no',
                   '--msg-level=all=error,harness=info,original_tracks=info', "--script=$harness", "--script=$Script",
                   "--script-opts=$($so -join ',')", (Join-Path $fixDir $c.Fixture.file))
            $c.Process = Start-LoggedProcess -FilePath $Mpv -Arguments $a -LogBase $c.Log
            $c.Watch = [Diagnostics.Stopwatch]::StartNew()
            [void]$running.Add($c)
        }
        foreach ($c in @($running)) {
            if ($c.Process.HasExited) { $running.Remove($c) }
            elseif ($c.Watch.Elapsed.TotalSeconds -gt $c.Quit + 60) { Stop-ProcessTree $c.Process; $c.Killed = $true; $running.Remove($c) }
            else { continue }
            Write-Host ("    finished {0,-18} in {1,3} s" -f $c.Name, [int]$c.Watch.Elapsed.TotalSeconds)
        }
        Start-Sleep -Milliseconds 250
    }
} finally {
    foreach ($c in @($running)) { Stop-ProcessTree $c.Process }
}

# ------------------------------------------------------------------ check
function Test-Case($c) {
    $problems = New-Object System.Collections.ArrayList
    $lines = @()
    foreach ($ext in '.out', '.err') {
        if (Test-Path -LiteralPath ($c.Log + $ext)) { $lines += [IO.File]::ReadAllLines($c.Log + $ext) }
    }
    $finalLine = $lines | Where-Object { $_ -match '\[harness\] FINAL ' } | Select-Object -Last 1
    $tracksLine = $lines | Where-Object { $_ -match '\[harness\] TRACKS ' } | Select-Object -First 1
    $errors = @($lines | Where-Object { $_ -match 'Lua error|stack traceback|attempt to (call|index|compare|perform)' })
    if ($errors) { [void]$problems.Add("Lua error: $($errors[0].Trim())") }
    if (-not ($lines -match '^\[original_tracks\]')) { [void]$problems.Add('the track script never logged anything (not loaded?)') }
    $final = $null
    if ($finalLine) { $final = ($finalLine -replace '^.*\[harness\] FINAL ', '') | ConvertFrom-Json }
    else {
        $why = if ($c.Killed) { 'killed after a timeout' } else { "mpv exited with code $($c.Process.ExitCode)" }
        [void]$problems.Add("no final state ($why)")
    }
    if ($tracksLine) {
        # windows powershell's ConvertFrom-Json hands a json array down the pipeline as one object
        $all = ($tracksLine -replace '^.*\[harness\] TRACKS ', '') | ConvertFrom-Json
        $tracks = @(foreach ($t in $all) { if ($t.type -eq 'sub' -and -not $t.external) { $t } })
        if ($tracks.Count -ne @($c.Fixture.subs).Count) { [void]$problems.Add("file has $($tracks.Count) subtitle tracks, fixture declares $(@($c.Fixture.subs).Count)") }
        foreach ($s in $c.Fixture.subs) {
            $t = $tracks | Where-Object { $_.id -eq $s.id }
            $lang = if ($t.lang -and $t.lang -ne 'und') { $t.lang } else { '' }
            if (-not $t -or $lang -ne $s.lang -or "$($t.title)" -ne $s.title -or [bool]$t.forced -ne $s.forced) {
                [void]$problems.Add("subtitle track $($s.id) isn't tagged as declared (lang '$($s.lang)', title '$($s.title)', forced $($s.forced))")
            }
        }
    }
    if ($final) {
        if ($final.sid -ne $c.ExpectSid) { [void]$problems.Add("sid is $($final.sid), expected $($c.ExpectSid)") }
        if ($c.ExpectSid -ne 'no' -and $final.sub_visibility -ne 'yes') { [void]$problems.Add('subtitles are hidden') }
        if ($final.secondary_sid -ne 'no') { [void]$problems.Add("secondary-sid left at $($final.secondary_sid)") }
        if ($c.ExpectAid -and $final.aid -ne $c.ExpectAid) { [void]$problems.Add("aid is $($final.aid), expected $($c.ExpectAid)") }
        if ([math]::Abs([double]$final.sub_scale - $c.ExpectScale) -gt 0.001) { [void]$problems.Add("sub-scale is $($final.sub_scale), expected $($c.ExpectScale)") }
        if ($c.ExpectText -notcontains "$($final.sub_color)".ToUpper()) { [void]$problems.Add("sub-color is $($final.sub_color), expected $($c.ExpectText -join ' or ')") }
        if ($c.ExpectOutline -notcontains "$($final.sub_outline_color)".ToUpper()) { [void]$problems.Add("sub-outline-color is $($final.sub_outline_color), expected $($c.ExpectOutline -join ' or ')") }
    }
    [pscustomobject]@{
        Case = $c.Name; Expect = $c.ExpectSid; Sid = $final.sid; Aid = $final.aid; Visible = $final.sub_visibility
        Scale = $(if ($final) { ([double]$final.sub_scale).ToString('0.###', $inv) }); Color = $final.sub_color; Outline = $final.sub_outline_color
        Hides = $final.hides; 'SidAt(s)' = $(if ($final -and $null -ne $final.last_sid_change) { ([double]$final.last_sid_change).ToString('0.0', $inv) })
        Result = $(if ($problems.Count) { 'FAIL' } else { 'PASS' }); Problems = $problems; About = $c.About
    }
}

$results = @($cases | Sort-Object Name | ForEach-Object { Test-Case $_ })
Write-Section 'Track script results'
$results | Format-Table Case, Expect, Sid, Aid, Visible, Scale, Color, Outline, Hides, 'SidAt(s)', Result -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL')
foreach ($r in $failed) {
    Write-Host "  FAIL $($r.Case): $($r.About)" -ForegroundColor Red
    $r.Problems | ForEach-Object { Write-Host "       - $_" -ForegroundColor Red }
}
$results | Select-Object Case, Expect, Sid, Aid, Visible, Scale, Color, Outline, Hides, 'SidAt(s)', Result, Problems, About |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logDir 'results.json') -Encoding UTF8
if ($failed) { Write-Host "  $($failed.Count) of $($results.Count) track cases failed. Logs: $logDir" -ForegroundColor Red; exit 1 }
Write-Host "  all $($results.Count) track cases passed" -ForegroundColor Green
exit 0
