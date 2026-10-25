#Requires -Version 5.1
<#
.SYNOPSIS
  Runs every test suite: lint (PowerShell 5.1 parser + PSScriptAnalyzer), the https config helpers, the
  track script tests, the network tests and the relay tests. Exits with 1 if any suite fails.

.DESCRIPTION
  Needs mpv.com (a recent shinchiro build, like the pinned libmpv), ffmpeg, Python 3 and openssl. They are
  looked up on PATH and in common install folders unless given. Nothing outside -WorkDir is written,
  and mpv runs with --no-config (or a test config folder), so the installed Stremio and %APPDATA%\stremio-mpv are untouched.

.PARAMETER Mpv           mpv.com
.PARAMETER Ffmpeg        ffmpeg.exe
.PARAMETER Python        python.exe
.PARAMETER OpenSsl       openssl.exe, for the https network tests (Git for Windows has one)
.PARAMETER WorkDir       Generated media and logs (default: %TEMP%\stremiompv-relay-tests)
.PARAMETER MaxParallel   mpv instances at once in the track tests
.PARAMETER AnalyzerPath  PSScriptAnalyzer module to import instead of the installed one
.PARAMETER SkipLint      Skip the static checks
.PARAMETER SkipConfig    Skip the tests of tools\ca-bundle.ps1
.PARAMETER SkipLua       Skip the track script tests
.PARAMETER SkipNetwork   Skip the network tests
.PARAMETER SkipRelay     Skip the relay tests (tools\relay)
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1
.EXAMPLE
  .\tests\run-all.ps1 -Mpv C:\tools\mpv\mpv.com -Ffmpeg C:\tools\ffmpeg\bin\ffmpeg.exe -SkipNetwork
#>
param(
    [string]$Mpv,
    [string]$Ffmpeg,
    [string]$Python,
    [string]$OpenSsl,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'stremiompv-relay-tests'),
    [int]$MaxParallel = 24,
    [string]$AnalyzerPath,
    [switch]$SkipLint,
    [switch]$SkipConfig,
    [switch]$SkipLua,
    [switch]$SkipNetwork,
    [switch]$SkipRelay
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$suites = @()
if (-not $SkipLint) { $suites += 'lint' }
if (-not $SkipConfig) { $suites += 'config' }
if (-not $SkipLua) { $suites += 'lua' }
if (-not $SkipNetwork) { $suites += 'network' }
if (-not $SkipRelay -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'relay\run-relay-tests.ps1'))) { $suites += 'relay' }

Write-Section 'Tools'
if ($suites -contains 'lua' -or $suites -contains 'network' -or $suites -contains 'relay') {
    $Mpv = Resolve-Mpv $Mpv
    $Ffmpeg = Resolve-Ffmpeg $Ffmpeg
    Write-Host "    mpv:    $Mpv"
    Write-Host "            $(@(& $Mpv --no-config --version) | Select-Object -First 1)"
    Write-Host "    ffmpeg: $Ffmpeg"
}
if ($suites -contains 'network' -or $suites -contains 'relay') {
    $Python = Resolve-Python $Python
    Write-Host "    python: $Python ($(& $Python --version))"
    $OpenSsl = Resolve-OpenSsl $OpenSsl
    Write-Host "    openssl: $OpenSsl"
}
Write-Host "    work:   $WorkDir"

$summary = foreach ($s in $suites) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = 1
    try {
        switch ($s) {
            'lint' {
                $a = @{}; if ($AnalyzerPath) { $a.AnalyzerPath = $AnalyzerPath }
                & (Join-Path $PSScriptRoot 'lint.ps1') @a
            }
            'config' {
                $a = @{ WorkDir = $WorkDir }; if ($Mpv) { $a.Mpv = $Mpv }
                & (Join-Path $PSScriptRoot 'config\run-config-tests.ps1') @a
            }
            'lua' { & (Join-Path $PSScriptRoot 'lua\run-track-tests.ps1') -Mpv $Mpv -Ffmpeg $Ffmpeg -WorkDir $WorkDir -MaxParallel $MaxParallel }
            'network' { & (Join-Path $PSScriptRoot 'network\run-network-tests.ps1') -Mpv $Mpv -Ffmpeg $Ffmpeg -Python $Python -OpenSsl $OpenSsl -WorkDir $WorkDir }
            'relay' { & (Join-Path $PSScriptRoot 'relay\run-relay-tests.ps1') -Mpv $Mpv -Ffmpeg $Ffmpeg -Python $Python -OpenSsl $OpenSsl -WorkDir $WorkDir }
        }
        $code = $LASTEXITCODE
    } catch {
        Write-Host "  $s suite crashed: $($_.Exception.Message)" -ForegroundColor Red
    }
    [pscustomobject]@{ Suite = $s; Result = $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }); Seconds = [int]$sw.Elapsed.TotalSeconds }
}

Write-Section 'Summary'
$summary | Format-Table -AutoSize | Out-String | Write-Host
if ($summary | Where-Object Result -eq 'FAIL') { exit 1 }
exit 0
