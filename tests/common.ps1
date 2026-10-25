# helpers shared by the test runners (dot-source it)

function Resolve-Tool {
    param(
        [string]$Given,
        [Parameter(Mandatory)][string]$What,
        [string[]]$Names = @(),
        [string[]]$Candidates = @()
    )
    if ($Given) {
        if (-not (Test-Path -LiteralPath $Given -PathType Leaf)) { throw "$What not found at $Given" }
        return (Resolve-Path -LiteralPath $Given).ProviderPath
    }
    foreach ($n in $Names) {
        # the WindowsApps python.exe is only a store shortcut
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
        if ($c) { return $c.Source }
    }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    throw "$What not found. Pass its path as a parameter."
}

function Resolve-Mpv([string]$Given) {
    Resolve-Tool -Given $Given -What 'mpv.com' -Names 'mpv.com' -Candidates @(
        "$env:LOCALAPPDATA\Programs\mpv\mpv.com", "$env:ProgramFiles\mpv\mpv.com",
        "$env:USERPROFILE\scoop\apps\mpv\current\mpv.com")
}

function Resolve-Ffmpeg([string]$Given) {
    Resolve-Tool -Given $Given -What 'ffmpeg.exe' -Names 'ffmpeg.exe' -Candidates @(
        "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe", "$env:USERPROFILE\scoop\apps\ffmpeg\current\bin\ffmpeg.exe",
        "$env:LOCALAPPDATA\Programs\Stremio\ffmpeg.exe")
}

# git for windows ships openssl, so it's there on github's runners and most dev machines
function Resolve-OpenSsl([string]$Given) {
    Resolve-Tool -Given $Given -What 'openssl.exe' -Names 'openssl.exe' -Candidates @(
        "$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
        "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe")
}

function Resolve-Python([string]$Given) {
    try { return Resolve-Tool -Given $Given -What 'python.exe' -Names 'python.exe', 'python3.exe' }
    catch {
        if ($Given) { throw }
        $py = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $py) { throw }
        $exe = (@(& $py.Source -3 -c 'import sys; print(sys.executable)') | Select-Object -First 1)
        if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
        throw
    }
}

# quotes arguments for a windows command line (CommandLineToArgvW rules)
function ConvertTo-CommandLine([string[]]$Arguments) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a }
        else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    $quoted -join ' '
}

# starts a process with stdout/stderr in <LogBase>.out / .err
function Start-LoggedProcess {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [Parameter(Mandatory)][string]$LogBase)
    $p = Start-Process -FilePath $FilePath -ArgumentList (ConvertTo-CommandLine $Arguments) -NoNewWindow -PassThru `
        -RedirectStandardOutput "$LogBase.out" -RedirectStandardError "$LogBase.err"
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    $p
}

# kills a process we started and its children (mpv.com runs mpv.exe as a child)
function Stop-ProcessTree($Process) {
    if ($Process -and -not $Process.HasExited) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F 2>&1 | Out-Null
        [void]$Process.WaitForExit(5000)
    }
}

# runs a native tool; returns its exit code. windows powershell turns native stderr into errors
# under ErrorActionPreference=Stop, so that is relaxed while it runs
function Invoke-Native {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [switch]$Quiet)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            if (-not $Quiet) { Write-Host "    $_" }
        }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

# reads key=value lines from an mpv.conf or a script-opts file. stops at the first [profile]
function Read-KeyValueConf([Parameter(Mandatory)][string]$Path) {
    $list = New-Object System.Collections.ArrayList
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim().TrimStart([char]0xFEFF)
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('[')) { break }
        if ($line.StartsWith('--')) { $line = $line.Substring(2) }
        $name, $value = $line -split '=', 2
        $name = $name.Trim()
        if ($null -eq $value) { $value = 'yes' }
        else {
            $value = $value.Trim()
            if ($value.StartsWith('"')) { $value = $value.Substring(1, $value.IndexOf('"', 1) - 1) }
            else { $value = ($value -replace '\s+#.*$', '').Trim() }
        }
        [void]$list.Add([pscustomobject]@{ Name = $name; Value = $value })
    }
    $list
}

function Get-FreeTcpPort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { $l.LocalEndpoint.Port } finally { $l.Stop() }
}

function Wait-TcpPort([int]$Port, [int]$TimeoutMs = 10000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $c = New-Object Net.Sockets.TcpClient
        try { $c.Connect('127.0.0.1', $Port); return $true } catch { Start-Sleep -Milliseconds 200 } finally { $c.Close() }
    }
    $false
}

function Write-Section([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
