#Requires -Version 5.1
<#
.SYNOPSIS
  CI helper: downloads the pinned shinchiro mpv and a pinned ffmpeg, checks their SHA-256 and unpacks them.

.DESCRIPTION
  mpv: the player package mpv-x86_64-<date>-git-<hash>.7z from the same shinchiro release as
  config\mpv-pin.json. Its SHA-256 must match the digest GitHub's API reports for that asset, and the
  release's libmpv asset must still match the pin, so the tests run the same build users install.
  The player must also report the pinned mpvVersion.
  ffmpeg: a release build by gyan.dev (the Windows builds ffmpeg.org links to), from its GitHub
  releases (GyanD/codexffmpeg), checked against -FfmpegSha256 and GitHub's digest.
  If the machine has no Vulkan loader (no GPU driver), a stand-in vulkan-1.dll is built for mpv.exe.

.PARAMETER Dest          Output folder: <Dest>\mpv\mpv.com and <Dest>\ffmpeg\ffmpeg.exe
.PARAMETER FfmpegTag     Release tag in GyanD/codexffmpeg, e.g. 9.0.2
.PARAMETER FfmpegAsset   Asset name, e.g. ffmpeg-9.0.2-essentials_build.7z
.PARAMETER FfmpegSha256  Expected SHA-256 of that asset (lowercase hex)
.PARAMETER PinFile       mpv-pin.json (default: the repo's config\mpv-pin.json)
.PARAMETER DryRun        Only resolve the URLs and checksums
#>
param(
    [Parameter(Mandatory)][string]$Dest,
    [Parameter(Mandatory)][string]$FfmpegTag,
    [Parameter(Mandatory)][string]$FfmpegAsset,
    [Parameter(Mandatory)][string]$FfmpegSha256,
    [string]$PinFile,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot '..\common.ps1')
# windows powershell leaves $PSScriptRoot empty in param defaults of scripts with [Parameter()]
if (-not $PinFile) { $PinFile = Join-Path $PSScriptRoot '..\..\config\mpv-pin.json' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$api = @{ 'User-Agent' = 'StremioMPV-Relay-ci'; Accept = 'application/vnd.github+json' }
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
if ($token) { $api.Authorization = "Bearer $token" }

function Get-ReleaseAsset([string]$Repo, [string]$Tag, [string]$Name) {
    try { $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $api }
    catch { throw "release $Tag of $Repo not found ($($_.Exception.Message)). If it was deleted, update the pin." }
    $asset = $rel.assets | Where-Object name -eq $Name
    if (-not $asset) { throw "$Name is not in release $Tag of $Repo" }
    if ($asset.browser_download_url -ne "https://github.com/$Repo/releases/download/$Tag/$Name") {
        throw "unexpected download url $($asset.browser_download_url)"
    }
    $asset
}

function Get-Sha256Digest($Asset) {
    if ("$($Asset.digest)" -notmatch '^sha256:([0-9a-f]{64})$') { return $null }
    $Matches[1]
}

function Save-VerifiedFile([string]$Url, [string]$Sha256, [string]$OutFile) {
    $ok = (Test-Path -LiteralPath $OutFile) -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLower() -eq $Sha256
    if (-not $ok) {
        Invoke-WebRequest $Url -OutFile "$OutFile.part" -UseBasicParsing -Headers @{ 'User-Agent' = 'StremioMPV-Relay-ci' }
        Move-Item -LiteralPath "$OutFile.part" -Destination $OutFile -Force
    }
    $hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $Sha256) {
        Remove-Item -LiteralPath $OutFile -Force
        throw "SHA-256 mismatch for $(Split-Path $OutFile -Leaf): got $hash, expected $Sha256"
    }
    Write-Host "    $(Split-Path $OutFile -Leaf): SHA-256 $hash verified"
}

function Expand-7z([string]$Archive, [string]$To) {
    if (Test-Path -LiteralPath $To) { Remove-Item -LiteralPath $To -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    $7z = @((Get-Command 7z.exe -ErrorAction SilentlyContinue).Source, "$env:ProgramFiles\7-Zip\7z.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    $rc = if ($7z) { Invoke-Native $7z @('x', '-y', "-o$To", $Archive) -Quiet }
          else { Invoke-Native "$env:SystemRoot\System32\tar.exe" @('-xf', $Archive, '-C', $To) -Quiet }
    if ($rc -ne 0) { throw "couldn't extract $Archive" }
}

# ------------------------------------------------------------------ resolve
$pin = Get-Content -LiteralPath $PinFile -Raw | ConvertFrom-Json
if ($pin.asset -notmatch '^mpv-dev-(x86_64-\d{8}-git-[0-9a-f]+\.7z)$') { throw "unexpected asset name in mpv-pin.json: $($pin.asset)" }
$mpvName = "mpv-$($Matches[1])"
Write-Section "mpv: shinchiro release $($pin.tag)"
$dev = Get-ReleaseAsset -Repo 'shinchiro/mpv-winbuild-cmake' -Tag $pin.tag -Name $pin.asset
if ((Get-Sha256Digest $dev) -ne $pin.sha256) { throw "GitHub's digest for $($pin.asset) is $($dev.digest), but mpv-pin.json says $($pin.sha256)" }
$player = Get-ReleaseAsset -Repo 'shinchiro/mpv-winbuild-cmake' -Tag $pin.tag -Name $mpvName
$playerSha = Get-Sha256Digest $player
if (-not $playerSha) { throw "GitHub reports no sha256 digest for $mpvName" }
Write-Host "    $($pin.asset) matches the pin; player package $mpvName, sha256 $playerSha"

Write-Section "ffmpeg: gyan.dev $FfmpegTag"
$ff = Get-ReleaseAsset -Repo 'GyanD/codexffmpeg' -Tag $FfmpegTag -Name $FfmpegAsset
$ffDigest = Get-Sha256Digest $ff
if ($ffDigest -and $ffDigest -ne $FfmpegSha256.ToLower()) { throw "GitHub's digest for $FfmpegAsset is $ffDigest, the workflow pins $FfmpegSha256" }
Write-Host "    $FfmpegAsset, sha256 $FfmpegSha256$(if ($ffDigest) { ' (same as GitHub''s digest)' })"
if ($DryRun) { return }

# ------------------------------------------------------------------ download, verify, unpack
$downloads = Join-Path $Dest 'downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null

Save-VerifiedFile -Url $player.browser_download_url -Sha256 $playerSha -OutFile (Join-Path $downloads $mpvName)
$mpvDir = Join-Path $Dest 'mpv'
Expand-7z -Archive (Join-Path $downloads $mpvName) -To $mpvDir
if (-not (Test-Path -LiteralPath "$mpvDir\mpv.com")) { throw "mpv.com not found in $mpvName" }
& (Join-Path $PSScriptRoot 'New-VulkanStub.ps1') -MpvExe "$mpvDir\mpv.exe"
$versionOut = & "$mpvDir\mpv.com" --no-config --version
$version = $versionOut | Select-Object -First 1
if ($LASTEXITCODE -ne 0 -or "$version" -notlike "$($pin.mpvVersion) *") { throw "mpv.com reports '$version', expected $($pin.mpvVersion)" }
Write-Host "    $version"

Save-VerifiedFile -Url $ff.browser_download_url -Sha256 $FfmpegSha256.ToLower() -OutFile (Join-Path $downloads $FfmpegAsset)
$ffTmp = Join-Path $Dest 'ffmpeg-unpacked'
Expand-7z -Archive (Join-Path $downloads $FfmpegAsset) -To $ffTmp
$exe = Get-ChildItem -LiteralPath $ffTmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
if (-not $exe) { throw "ffmpeg.exe not found in $FfmpegAsset" }
$ffDir = Join-Path $Dest 'ffmpeg'
New-Item -ItemType Directory -Force -Path $ffDir | Out-Null
Copy-Item -Path (Join-Path $exe.DirectoryName '*.exe') -Destination $ffDir -Force
Remove-Item -LiteralPath $ffTmp -Recurse -Force
# read the whole output first: cutting the pipe early (Select-Object -First) makes ffmpeg exit with 1
$ffVersion = & "$ffDir\ffmpeg.exe" -hide_banner -version
if ($LASTEXITCODE -ne 0) { throw "ffmpeg -version failed ($LASTEXITCODE)" }
Write-Host "    $($ffVersion | Select-Object -First 1)"

Write-Section 'Tools ready'
Write-Host "    mpv:    $mpvDir\mpv.com"
Write-Host "    ffmpeg: $ffDir\ffmpeg.exe"
# github's powershell wrapper exits with the last native exit code; everything above already checked its own
exit 0
