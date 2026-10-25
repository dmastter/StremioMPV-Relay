#Requires -Version 5.1
<#
.SYNOPSIS
  Generates the subtitle-scenario MKVs for tests\lua\run-track-tests.ps1, plus manifest.json with
  what each one must end up selecting.

.DESCRIPTION
  Each MKV is a tiny lavfi video with silent audio tracks and SRT tracks built from dialogue.json
  (lines written for these tests). Nothing binary is committed: run this to get the files.
  The fixtures are only rebuilt when this script, dialogue.json or ffmpeg change (or with -Force).

.PARAMETER OutDir  Folder for the MKVs, the SRTs and manifest.json
.PARAMETER Ffmpeg  ffmpeg.exe (default: PATH, then common locations)
.PARAMETER Force   Rebuild even if manifest.json is up to date
#>
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Ffmpeg,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common.ps1')

# audio layouts: mpv numbers tracks of each type from 1, in file order
$DubFirst = @(@{ lang = 'rus'; title = 'Dub'; default = $true }, @{ lang = 'eng'; title = 'Original' })
$OriginalOnly = @(@{ lang = 'eng'; title = 'Original'; default = $true })

# subtitle entries: set (from dialogue.json), lang ('' = untagged), title, forced, default,
# start/step in seconds (defaults 2 and 3) and once (don't repeat the lines until the end)
$Fixtures = @(
    @{ name = 'tagged'; duration = 70; quit = 40; expectSid = '1'; expectAid = '2'; audio = $DubFirst
       about = 'correct tags: full English, SDH and a forced signs track; Russian dub is the default audio'
       subs = @(@{ set = 'en'; lang = 'eng'; title = 'English' }
                @{ set = 'sdh'; lang = 'eng'; title = 'English SDH' }
                @{ set = 'signs'; lang = 'eng'; title = 'English Forced'; forced = $true; start = 5; step = 20 }) }
    @{ name = 'mislabeled'; duration = 80; quit = 50; expectSid = '4'; expectAid = '2'; audio = $DubFirst
       about = 'Czech, Greek and Chinese tracks tagged eng; the real English carries the forced flag'
       subs = @(@{ set = 'cz'; lang = 'eng'; title = 'English'; default = $true }
                @{ set = 'el'; lang = 'eng' }
                @{ set = 'zh'; lang = 'eng' }
                @{ set = 'en'; lang = 'eng'; title = 'English'; forced = $true }) }
    @{ name = 'typographic'; duration = 60; quit = 40; expectSid = '2'; expectAid = '1'; audio = $OriginalOnly
       about = 'curly quotes, ellipses, dashes and music notes in the real English; Czech tagged eng ranks first'
       subs = @(@{ set = 'cz'; lang = 'eng'; title = 'English'; default = $true }
                @{ set = 'typo'; lang = 'eng'; title = 'English' }) }
    @{ name = 'untagged'; duration = 60; quit = 40; expectSid = '2'; expectAid = '1'; audio = @(@{ default = $true })
       about = 'Greek tagged eng, and the real English with no language tag; one untagged audio track'
       subs = @(@{ set = 'el'; lang = 'eng'; title = 'English' }
                @{ set = 'en' }) }
    @{ name = 'sdh-only'; duration = 80; quit = 50; expectSid = '1'; expectAid = '2'; audio = $DubFirst
       about = 'only an SDH track, with a cold open full of [cues]'
       subs = @(@{ set = 'sdh'; lang = 'eng'; title = 'English SDH' }) }
    @{ name = 'sdh-vs-fake'; duration = 80; quit = 50; expectSid = '1'; expectAid = '2'; audio = $DubFirst
       about = 'SDH track (default flag) and a Czech track tagged as plain English'
       subs = @(@{ set = 'sdh'; lang = 'eng'; title = 'English SDH'; default = $true }
                @{ set = 'cz'; lang = 'eng'; title = 'English' }) }
    @{ name = 'signs-sparse'; duration = 90; quit = 50; expectSid = '2'; expectAid = '1'; audio = $OriginalOnly
       about = 'a sparse signs track tagged English ranks first, the full English second'
       subs = @(@{ set = 'sparse'; lang = 'eng'; title = 'English'; default = $true; start = 5; step = 20; once = $true }
                @{ set = 'en'; lang = 'eng'; title = 'English' }) }
    @{ name = 'late-english'; duration = 120; quit = 60; expectSid = '3'; expectAid = '1'; audio = $OriginalOnly
       about = 'Czech tagged eng, an English track that starts at 70 s, and a full English SDH'
       subs = @(@{ set = 'cz'; lang = 'eng'; default = $true }
                @{ set = 'en'; lang = 'eng'; title = 'English'; start = 70 }
                @{ set = 'sdh'; lang = 'eng'; title = 'English SDH' }) }
    @{ name = 'long-intro'; duration = 100; quit = 60; expectSid = '1'; expectAid = '1'; audio = $OriginalOnly
       about = 'dialogue starts after a 20 s silent intro; a sparse forced track talks during the intro'
       subs = @(@{ set = 'en'; lang = 'eng'; title = 'English'; start = 20 }
                @{ set = 'sdh'; lang = 'eng'; title = 'English SDH'; start = 20 }
                @{ set = 'sparse3'; lang = 'eng'; forced = $true; start = 3; step = 4; once = $true }) }
    @{ name = 'single-late'; duration = 80; quit = 50; expectSid = '1'; expectAid = '1'; audio = $OriginalOnly
       about = 'a single English track that starts at 20 s'
       subs = @(@{ set = 'en'; lang = 'eng'; title = 'English'; start = 20 }) }
    @{ name = 'two-sparse'; duration = 150; quit = 120; expectSid = '3'; expectAid = '1'; audio = $OriginalOnly
       about = 'two sparse tracks rank first; the full English (SDH title) starts at 20 s'
       subs = @(@{ set = 'sparse3'; lang = 'eng'; title = 'English'; start = 3; step = 4; once = $true }
                @{ set = 'sparse3'; lang = 'eng'; title = 'English (signs)'; start = 3; step = 4; once = $true }
                @{ set = 'en'; lang = 'eng'; title = 'English SDH'; start = 20 }) }
    @{ name = 'english-at-130'; duration = 220; quit = 175; expectSid = '2'; expectAid = '1'; audio = $OriginalOnly
       about = 'Czech tagged English talks from 5 s; the real English starts at 130 s'
       subs = @(@{ set = 'cz'; lang = 'eng'; title = 'English'; start = 5 }
                @{ set = 'en'; lang = 'eng'; title = 'English SDH'; start = 130 }) }
    @{ name = 'all-at-130'; duration = 220; quit = 175; expectSid = '2'; expectAid = '1'; audio = $OriginalOnly
       about = 'every track is silent until 130 s, longer than the 120 s probe limit'
       subs = @(@{ set = 'cz'; lang = 'eng'; title = 'English'; start = 130 }
                @{ set = 'en'; lang = 'eng'; title = 'English SDH'; start = 130 }) }
    @{ name = 'resume-seek'; duration = 300; quit = 60; expectSid = '2'; expectAid = '1'; audio = $OriginalOnly
       acts = '1:!seek=150'
       about = 'Stremio resumes at 2:30; Czech tagged English and the real English talk all along'
       subs = @(@{ set = 'cz'; lang = 'eng'; title = 'English'; start = 5 }
                @{ set = 'en'; lang = 'eng'; title = 'English SDH'; start = 5 }) }
    @{ name = 'no-english'; duration = 60; quit = 30; expectSid = 'no'; expectAid = '1'; audio = $OriginalOnly
       about = 'only Czech and Greek tracks, correctly tagged'
       subs = @(@{ set = 'cz'; lang = 'cze'; title = 'Czech'; default = $true }
                @{ set = 'el'; lang = 'gre' }) }
    @{ name = 'fake-only'; duration = 60; quit = 40; expectSid = 'no'; expectAid = '1'; audio = $OriginalOnly
       about = 'two tracks tagged English that are really Czech and Greek'
       subs = @(@{ set = 'cz'; lang = 'eng'; title = 'English'; default = $true }
                @{ set = 'el'; lang = 'eng'; title = 'English' }) }
    @{ name = 'single-english'; duration = 80; quit = 40; expectSid = '1'; expectAid = '2'; audio = $DubFirst
       about = 'one untitled English track; the Russian dub is the default audio'
       subs = @(@{ set = 'en'; lang = 'eng' }) }
)

function Format-SrtTime([double]$s) {
    $t = [TimeSpan]::FromMilliseconds([math]::Round($s * 1000))
    '{0:00}:{1:00}:{2:00},{3:000}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, $t.Milliseconds
}

function ConvertTo-Srt($Sub, [double]$Duration, $Dialogue) {
    $set = $Dialogue.($Sub.set)
    if (-not $set) { throw "unknown line set '$($Sub.set)'" }
    $start = if ($null -ne $Sub.start) { [double]$Sub.start } else { 2.0 }
    $step = if ($null -ne $Sub.step) { [double]$Sub.step } else { 3.0 }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($set.intro) { $set.intro | ForEach-Object { $lines.Add($_) } }
    $set.body | ForEach-Object { $lines.Add($_) }
    $sb = New-Object Text.StringBuilder
    $i = 0
    for ($t = $start; $t + 2 -le $Duration - 1; $t += $step) {
        if ($i -ge $lines.Count) {
            if ($Sub.once) { break }
            $lines.AddRange([string[]]$set.body)
        }
        [void]$sb.AppendFormat("{0}`n{1} --> {2}`n{3}`n`n", ($i + 1), (Format-SrtTime $t), (Format-SrtTime ($t + 2)), $lines[$i])
        $i++
    }
    $sb.ToString()
}

$Ffmpeg = Resolve-Ffmpeg $Ffmpeg
New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $OutDir 'srt') | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath
$manifestPath = Join-Path $OutDir 'manifest.json'
$utf8 = New-Object Text.UTF8Encoding($false)

# fingerprint of everything that shapes the output, to skip work when nothing changed
$ffVersion = (@(& $Ffmpeg -hide_banner -version) | Select-Object -First 1)
$sha = [Security.Cryptography.SHA256]::Create()
$bytes = [byte[]]([IO.File]::ReadAllBytes($PSCommandPath) + [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'dialogue.json')) + $utf8.GetBytes($ffVersion))
$generator = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()

if (-not $Force -and (Test-Path -LiteralPath $manifestPath)) {
    $old = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $missing = @($old.fixtures | Where-Object { -not (Test-Path -LiteralPath (Join-Path $OutDir $_.file)) })
    if ($old.generator -eq $generator -and -not $missing) {
        Write-Host "    fixtures up to date in $OutDir"
        return
    }
}

$dialogue = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dialogue.json'), $utf8) | ConvertFrom-Json
Write-Host "    $ffVersion"
$entries = foreach ($f in $Fixtures) {
    $file = "$($f.name).mkv"
    $a = @('-y', '-nostdin', '-hide_banner', '-loglevel', 'error',
           '-f', 'lavfi', '-i', "color=c=0x202020:s=160x90:r=5:d=$($f.duration)",
           '-f', 'lavfi', '-i', 'anullsrc=r=8000:cl=mono')
    for ($i = 0; $i -lt $f.subs.Count; $i++) {
        $srt = Join-Path $OutDir "srt\$($f.name)-$($i + 1).srt"
        [IO.File]::WriteAllText($srt, (ConvertTo-Srt -Sub $f.subs[$i] -Duration $f.duration -Dialogue $dialogue), $utf8)
        $a += @('-i', $srt)
    }
    $a += @('-map', '0:v')
    for ($i = 0; $i -lt $f.audio.Count; $i++) { $a += @('-map', '1:a') }
    for ($i = 0; $i -lt $f.subs.Count; $i++) { $a += @('-map', "$($i + 2):s") }
    $a += @('-t', "$($f.duration)", '-c:v', 'mpeg4', '-q:v', '20', '-g', '50', '-c:a', 'aac', '-c:s', 'subrip',
            '-disposition:v:0', 'default', '-default_mode', 'passthrough')
    # every flag is set explicitly so different ffmpeg versions write the same dispositions
    foreach ($kind in 'a', 's') {
        $tracks = @(if ($kind -eq 'a') { $f.audio } else { $f.subs })
        for ($i = 0; $i -lt $tracks.Count; $i++) {
            $t = $tracks[$i]
            $flags = @(); if ($t.default) { $flags += 'default' }; if ($t.forced) { $flags += 'forced' }
            $a += @("-disposition:${kind}:$i", $(if ($flags) { $flags -join '+' } else { '0' }))
            if ($t.lang) { $a += @("-metadata:s:${kind}:$i", "language=$($t.lang)") }
            if ($t.title) { $a += @("-metadata:s:${kind}:$i", "title=$($t.title)") }
        }
    }
    $a += Join-Path $OutDir $file
    if ((Invoke-Native $Ffmpeg $a) -ne 0) { throw "ffmpeg failed for $file" }
    Write-Host ("    {0,-16} expects sid={1,-3} {2}" -f $f.name, $f.expectSid, $f.about)

    $id = 0
    [ordered]@{
        name = $f.name; file = $file; about = $f.about; duration = $f.duration; quit = $f.quit
        expectSid = $f.expectSid; expectAid = $f.expectAid; acts = $(if ($f.acts) { $f.acts } else { '' })
        subs = @($f.subs | ForEach-Object {
            $id++
            [ordered]@{ id = $id; set = $_.set; lang = "$($_.lang)"; title = "$($_.title)"; forced = [bool]$_.forced; default = [bool]$_.default }
        })
    }
}

# an "addon" subtitle that the fake Stremio can load, as Stremio does with addon subtitles
[IO.File]::WriteAllText((Join-Path $OutDir 'addon.srt'), (ConvertTo-Srt -Sub @{ set = 'en' } -Duration 120 -Dialogue $dialogue), $utf8)

$manifest = [ordered]@{ generator = $generator; ffmpeg = $ffVersion; addon = 'addon.srt'; fixtures = @($entries) }
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), $utf8)
Write-Host "    $(@($entries).Count) fixtures written to $OutDir"
