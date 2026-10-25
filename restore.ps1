#Requires -Version 5.1
<#
.SYNOPSIS
  Puts back Stremio's official signed files saved by install.ps1, and removes the scheduled task that
  would put the patch back after Stremio updates.
.PARAMETER RemoveConfig  Also delete %APPDATA%\stremio-mpv (including your edits)
.PARAMETER Yes           Don't ask before closing Stremio or deleting the config
#>
param(
    [string]$StremioDir,
    [string]$WorkDir = "$env:USERPROFILE\stremio-mpv-build",
    [switch]$RemoveConfig,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'

function Ask($q) { if ($Yes) { return $true }; return (Read-Host "$q [y/N]") -match '^(y|yes|s|si)$' }
function Test-Official([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $s = Get-AuthenticodeSignature -LiteralPath $path
    return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -like 'CN=Smart Code OOD*')
}

if (-not $StremioDir) {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{DD3870DA-AF3C-4C73-B010-72944AB610C6}_is1' -ErrorAction SilentlyContinue
    $StremioDir = if ($reg -and $reg.InstallLocation) { $reg.InstallLocation } else { "$env:LOCALAPPDATA\Programs\Stremio" }
}
$StremioDir = $StremioDir.TrimEnd('\')

# writes from a sandboxed app (e.g. an AI desktop app) may never reach the real folders
$probe = Join-Path $env:APPDATA ("stremio-mpv-probe-" + [guid]::NewGuid().ToString('N') + '.tmp')
$out = Join-Path $WorkDir ("probe-" + [guid]::NewGuid().ToString('N') + '.txt')
try {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    [IO.File]::WriteAllText($probe, 'probe')
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c (if exist `"$probe`" (echo REAL) else (echo REDIRECTED)) > `"$out`"" }
    if ($r.ReturnValue -ne 0) { throw "probe could not start" }
    for ($i = 0; $i -lt 40 -and -not (Test-Path -LiteralPath $out); $i++) { Start-Sleep -Milliseconds 250 }
    Start-Sleep -Milliseconds 300
    if ((Get-Content -LiteralPath $out -ErrorAction SilentlyContinue) -match 'REDIRECTED') {
        Write-Host "This shell is sandboxed and its changes may not reach the real folders. Double-click restore.cmd yourself." -ForegroundColor Yellow
        exit 1
    }
} catch { } finally { Remove-Item -LiteralPath $probe, $out -ErrorAction SilentlyContinue }

# first, so the task can't patch Stremio again behind the user's back
try { & (Join-Path $PSScriptRoot 'tools\autopatch-task.ps1') -Remove }
catch { Write-Host "Couldn't remove the scheduled task 'StremioMPV Relay autopatch' ($($_.Exception.Message)). Delete it in Task Scheduler." -ForegroundColor Yellow }
# and the player script's pointer to autopatch.ps1, so closing stremio starts nothing either
Remove-Item -LiteralPath (Join-Path $env:APPDATA 'stremio-mpv\autopatch-path.txt') -ErrorAction SilentlyContinue

$exe = Join-Path $StremioDir 'stremio-shell-ng.exe'
$ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
$backup = Join-Path $WorkDir "original-$ver"
if (Test-Official $exe) {
    Remove-Item -LiteralPath (Join-Path $WorkDir 'state.json') -ErrorAction SilentlyContinue
    Write-Host "Stremio $ver is already the official signed build (probably updated itself). Nothing to restore." -ForegroundColor Green
} elseif (-not ((Test-Official "$backup\stremio-shell-ng.exe") -and (Test-Official "$backup\libmpv-2.dll"))) {
    Write-Host "No official backup for Stremio $ver in $backup." -ForegroundColor Yellow
    Write-Host "Reinstall the official app from https://www.stremio.com/downloads to get the original files back."
    exit 1
} else {
    $prefix = $StremioDir + '\'
    $running = @(Get-Process stremio-shell-ng, stremio-runtime -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($running -and -not (Ask "Stremio is running. Close it now?")) { Write-Host "Close Stremio and run this again."; exit 1 }
    # before stremio closes: the re-patch check waiting for this stremio wakes up then, and without
    # state.json it leaves the restored files alone
    Remove-Item -LiteralPath (Join-Path $WorkDir 'state.json') -ErrorAction SilentlyContinue
    if ($running) {
        $running | ForEach-Object { [void]$_.CloseMainWindow() }
        Start-Sleep 3
        $running | Where-Object { -not $_.HasExited } | Stop-Process -Force
        Start-Sleep 2
    }
    Copy-Item -LiteralPath "$backup\stremio-shell-ng.exe" -Destination $exe -Force
    Copy-Item -LiteralPath "$backup\libmpv-2.dll" -Destination (Join-Path $StremioDir 'libmpv-2.dll') -Force
    Write-Host "Official Stremio $ver restored (signature: $((Get-AuthenticodeSignature -LiteralPath $exe).Status))." -ForegroundColor Green
}

if ($RemoveConfig) {
    $cfg = Join-Path $env:APPDATA 'stremio-mpv'
    if (Ask "Delete $cfg, including your edits?") {
        Remove-Item -LiteralPath $cfg -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $cfg"
    }
}
