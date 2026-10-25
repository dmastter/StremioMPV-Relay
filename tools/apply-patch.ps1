#Requires -Version 5.1
<#
.SYNOPSIS
  Applies the StremioMPV Relay patch to a stremio-shell-ng source tree (idempotent).
.PARAMETER Source  Root of the stremio-shell-ng checkout
#>
param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference = 'Stop'

$player = Join-Path $Source 'src\stremio_app\stremio_player\player.rs'
if (-not (Test-Path -LiteralPath $player)) { throw "player.rs not found under $Source" }
$code = [IO.File]::ReadAllText($player)
# checks the property, not the marker comment, so trees patched under an older marker are skipped too
if ($code.Contains('set_property!("config-dir"')) { Write-Host "    patch already applied"; return }

# the anchor is the first property set inside Mpv::with_initializer, before mpv_initialize
$anchor = '        set_property!("wid"'
$hits = ([regex]::Matches($code, [regex]::Escape($anchor))).Count
if ($hits -ne 1) {
    throw "Patch anchor found $hits times in player.rs (expected 1). Stremio changed this code; see AGENTS.md, 'If the patch doesn't apply'."
}
$patch = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\patch\config-loading.rs.txt')).TrimEnd()
$code = $code.Replace($anchor, $patch + "`n" + $anchor)
[IO.File]::WriteAllText($player, $code, (New-Object Text.UTF8Encoding($false)))
Write-Host "    patch applied: config-dir = %APPDATA%\stremio-mpv, config = yes, load-scripts = yes"
