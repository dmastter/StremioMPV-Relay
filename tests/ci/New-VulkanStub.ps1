#Requires -Version 5.1
<#
.SYNOPSIS
  Builds a stand-in vulkan-1.dll next to mpv.exe, for CI runners that have no GPU driver.

.DESCRIPTION
  shinchiro's mpv.exe imports a few functions from vulkan-1.dll, so Windows refuses to start it when
  the Vulkan loader (normally installed by the GPU driver) is missing. The tests run with --vo=null and
  never touch Vulkan, so a DLL that exports the same names and reports "not available" is enough.
  The export list is read from mpv.exe's import table; the DLL is compiled with MSVC (cl.exe).
  Nothing is downloaded.

.PARAMETER MpvExe  mpv.exe whose imports to satisfy; the DLL is written next to it
.PARAMETER Force   Build even if Windows already has a vulkan-1.dll
#>
param(
    [Parameter(Mandatory)][string]$MpvExe,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common.ps1')

if (-not $Force -and (Test-Path -LiteralPath "$env:SystemRoot\System32\vulkan-1.dll")) {
    Write-Host '    this machine has a Vulkan loader; no stub needed'
    return
}

function Get-ImportedName([byte[]]$Image, [string]$Dll) {
    $pe = [BitConverter]::ToInt32($Image, 0x3C)
    $sections = [BitConverter]::ToUInt16($Image, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($Image, $pe + 20)
    $opt = $pe + 24
    if ([BitConverter]::ToUInt16($Image, $opt) -ne 0x20B) { throw 'not a 64-bit PE image' }
    $map = foreach ($i in 0..($sections - 1)) {
        $s = $opt + $optSize + 40 * $i
        [pscustomobject]@{ Va = [BitConverter]::ToUInt32($Image, $s + 12); Size = [math]::Max([BitConverter]::ToUInt32($Image, $s + 8), [BitConverter]::ToUInt32($Image, $s + 16)); Raw = [BitConverter]::ToUInt32($Image, $s + 20) }
    }
    $toOffset = { param($rva) foreach ($m in $map) { if ($rva -ge $m.Va -and $rva -lt $m.Va + $m.Size) { return [int]($rva - $m.Va + $m.Raw) } }; throw "rva $rva outside the image" }
    $readName = { param($o) $e = [Array]::IndexOf($Image, [byte]0, $o); [Text.Encoding]::ASCII.GetString($Image, $o, $e - $o) }
    $desc = & $toOffset ([BitConverter]::ToUInt32($Image, $opt + 112 + 8))   # data directory 1: imports
    while ([BitConverter]::ToUInt32($Image, $desc + 12)) {
        if ((& $readName (& $toOffset ([BitConverter]::ToUInt32($Image, $desc + 12)))) -eq $Dll) {
            $thunkRva = [BitConverter]::ToUInt32($Image, $desc)
            if (-not $thunkRva) { $thunkRva = [BitConverter]::ToUInt32($Image, $desc + 16) }
            $t = & $toOffset $thunkRva
            # 64-bit thunks: the high bit means import by ordinal, otherwise the low dword is a name rva
            while ($true) {
                $lo = [BitConverter]::ToUInt32($Image, $t); $hi = [BitConverter]::ToUInt32($Image, $t + 4)
                if (-not $lo -and -not $hi) { break }
                if ($hi -ge 2147483648) { throw "$Dll is imported by ordinal; can't build a stub" }
                & $readName ((& $toOffset $lo) + 2)
                $t += 8
            }
        }
        $desc += 20
    }
}

$MpvExe = (Resolve-Path -LiteralPath $MpvExe).ProviderPath
$names = @(Get-ImportedName ([IO.File]::ReadAllBytes($MpvExe)) 'vulkan-1.dll')
if (-not $names) { Write-Host '    mpv.exe does not import vulkan-1.dll; no stub needed'; return }
Write-Host "    mpv.exe imports $($names.Count) functions from vulkan-1.dll: $($names -join ', ')"

$build = Join-Path ([IO.Path]::GetTempPath()) ("vkstub-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $build | Out-Null
try {
    # *ProcAddr return a function pointer (null = not available); the rest return a VkResult
    @'
__declspec(noinline) long long vk_stub_fail(void) { return -3; } /* VK_ERROR_INITIALIZATION_FAILED */
__declspec(noinline) void *vk_stub_null(void) { return 0; }
'@ | Set-Content -LiteralPath "$build\stub.c" -Encoding ASCII
    $exports = $names | ForEach-Object { "    $_=$(if ($_ -like '*ProcAddr') { 'vk_stub_null' } else { 'vk_stub_fail' })" }
    (@('LIBRARY vulkan-1', 'EXPORTS') + $exports) | Set-Content -LiteralPath "$build\stub.def" -Encoding ASCII

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = if (Test-Path -LiteralPath $vswhere) { & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath }
    if (-not $vs) { throw 'MSVC (Visual Studio C++ tools) not found' }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    # vcvars64.bat calls vswhere itself and expects it on PATH
    $cmd = "set `"PATH=$(Split-Path $vswhere);%PATH%`" && call `"$vcvars`" >nul && cd /d `"$build`" && cl /nologo /LD /O1 stub.c /link /DEF:stub.def /OUT:vulkan-1.dll"
    if ((Invoke-Native "$env:SystemRoot\System32\cmd.exe" @('/c', $cmd)) -ne 0) { throw 'building the stub failed' }
    $dest = Join-Path (Split-Path -Parent $MpvExe) 'vulkan-1.dll'
    Copy-Item -LiteralPath "$build\vulkan-1.dll" -Destination $dest -Force
    Write-Host "    stub written to $dest"
} finally {
    Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction SilentlyContinue
}
