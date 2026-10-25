#Requires -Version 5.1
<#
.SYNOPSIS
  Compiles tools\relay\relay.cs into relay.exe with the C# compiler that ships with Windows
  (.NET Framework 4.x, C# 5). Nothing is downloaded.

.PARAMETER Out  Where to write relay.exe
#>
param(
    [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'relay.cs'
$csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $csc) {
    Write-Host 'ERROR: csc.exe not found (it comes with the .NET Framework 4.x in %WINDIR%\Microsoft.NET)'
    exit 1
}
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null

# winexe: mpv starts it, and a console app would flash a window
$a = @('/nologo', '/optimize+', '/target:winexe', '/noconfig', '/r:System.dll', '/r:System.Core.dll', "/out:$Out", $src)
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $output = @(& $csc @a 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $old }
if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    Write-Host "ERROR: compiling $src failed (exit code $LASTEXITCODE)"
    exit 1
}
exit 0
