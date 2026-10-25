#Requires -Version 5.1
<#
.SYNOPSIS
  Static checks for every PowerShell file in the repo: Windows PowerShell 5.1's parser, a check that
  files with non-ASCII text have a UTF-8 BOM (5.1 reads BOM-less files as ANSI), and PSScriptAnalyzer.
  Errors fail; analyzer warnings are only counted.

.PARAMETER Root             Repo root (default: the folder above tests\)
.PARAMETER RequireAnalyzer  Fail when PSScriptAnalyzer isn't available (CI). Otherwise it's skipped with a warning.
.PARAMETER AnalyzerPath     Import PSScriptAnalyzer from this path (a .psd1 or module folder) instead of the installed one
#>
param(
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [switch]$RequireAnalyzer,
    [string]$AnalyzerPath
)
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    # the scripts target windows powershell 5.1, so they must be parsed by its parser
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Root', $Root)
    if ($RequireAnalyzer) { $a += '-RequireAnalyzer' }
    if ($AnalyzerPath) { $a += @('-AnalyzerPath', $AnalyzerPath) }
    & $ps @a
    exit $LASTEXITCODE
}

$Root = (Resolve-Path -LiteralPath $Root).ProviderPath
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '\\\.git\\' } | Sort-Object FullName)
$errors = 0
function Get-RelativePath([string]$Path) { $Path.Substring($Root.Length).TrimStart('\') }

Write-Host "`n==> Parsing $($files.Count) files with PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
foreach ($f in $files) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($e in $parseErrors) {
        Write-Host "  $(Get-RelativePath $f.FullName):$($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
        $errors++
    }
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $bom -and @($bytes | Where-Object { $_ -gt 127 }).Count) {
        Write-Host "  $(Get-RelativePath $f.FullName): non-ASCII text without a UTF-8 BOM; Windows PowerShell 5.1 would misread it" -ForegroundColor Red
        $errors++
    }
}
if (-not $errors) { Write-Host '    all files parse' }

Write-Host "`n==> PSScriptAnalyzer" -ForegroundColor Cyan
$haveAnalyzer = $false
if ($AnalyzerPath) { Import-Module $AnalyzerPath -Force; $haveAnalyzer = $true }
elseif (Get-Module PSScriptAnalyzer) { $haveAnalyzer = $true }   # already imported (ci picks the version)
elseif (Get-Module -ListAvailable PSScriptAnalyzer) { Import-Module PSScriptAnalyzer; $haveAnalyzer = $true }
if ($haveAnalyzer) {
    Write-Host "    PSScriptAnalyzer $((Get-Module PSScriptAnalyzer).Version)"
    $diag = @(foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName })
    foreach ($d in $diag | Where-Object { "$($_.Severity)" -in 'Error', 'ParseError' }) {
        Write-Host "  $(Get-RelativePath $d.ScriptPath):$($d.Line): [$($d.RuleName)] $($d.Message)" -ForegroundColor Red
        $errors++
    }
    $warnings = @($diag | Where-Object { "$($_.Severity)" -notin 'Error', 'ParseError' })
    if ($warnings) {
        Write-Host "    $($warnings.Count) warnings/notes (not failing):"
        $warnings | Group-Object RuleName | Sort-Object Count -Descending |
            ForEach-Object { Write-Host ("      {0,4}  {1}" -f $_.Count, $_.Name) }
    }
} elseif ($RequireAnalyzer) {
    Write-Host '  PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer)' -ForegroundColor Red
    $errors++
} else {
    Write-Host '    PSScriptAnalyzer not installed: skipped (Install-Module PSScriptAnalyzer -Scope CurrentUser)' -ForegroundColor Yellow
}

if ($errors) { Write-Host "  lint: $errors problem(s)" -ForegroundColor Red; exit 1 }
Write-Host '  lint passed' -ForegroundColor Green
exit 0
