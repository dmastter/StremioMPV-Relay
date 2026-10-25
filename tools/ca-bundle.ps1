# helpers for https in the patched player (dot-source it). install.ps1 uses them, and so do the tests.
#
# the newer libmpv opens network streams with ffmpeg (curl-enabled=no in mpv.conf), and ffmpeg's tls
# (openssl) checks certificates (tls-verify=yes) but can't read windows' certificate store. without a ca
# file every https stream fails with "tls: error:0A000086" and stremio's spinner never stops. so we
# export windows' trusted root certificates to a pem file and point tls-ca-file at it.

# writes windows' trusted root certificates to $Path as pem and returns how many it wrote.
# windows only downloads most of its roots the first time something needs them, so the full list comes
# from windows update (certutil -generateSSTFromWU). the local stores are added on top: they hold
# enterprise roots and the ones antivirus https scanning installs. roots in the disallowed stores and
# expired ones are left out. an existing file is only replaced once the new one is complete.
function Export-CaBundle {
    param([Parameter(Mandatory)][string]$Path, [switch]$NoWindowsUpdate)
    $certs = @{}
    $fromWu = 0
    if (-not $NoWindowsUpdate) {
        $sst = Join-Path ([IO.Path]::GetTempPath()) ("stremiompv-roots-{0}.sst" -f [guid]::NewGuid().ToString('N'))
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & "$env:SystemRoot\System32\certutil.exe" -generateSSTFromWU $sst 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $sst)) {
                $col = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
                $col.Import($sst)
                foreach ($c in $col) { $certs[$c.Thumbprint] = $c }
                $fromWu = $col.Count
            }
        } catch { $fromWu = 0 }
        finally {
            $ErrorActionPreference = $old
            Remove-Item -LiteralPath $sst -ErrorAction SilentlyContinue
        }
    }
    foreach ($store in 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\AuthRoot', 'Cert:\CurrentUser\Root') {
        foreach ($c in @(Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue)) { $certs[$c.Thumbprint] = $c }
    }
    foreach ($store in 'Cert:\LocalMachine\Disallowed', 'Cert:\CurrentUser\Disallowed') {
        foreach ($c in @(Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue)) { $certs.Remove($c.Thumbprint) }
    }
    $now = Get-Date
    $valid = @($certs.Values | Where-Object { $_.NotAfter -gt $now -and $_.NotBefore -lt $now } | Sort-Object Subject, Thumbprint)
    if (-not $valid.Count) { throw "Couldn't read any trusted root certificate from Windows." }
    # offline (a logon before wi-fi is up): the local stores alone are far fewer. an existing, fuller file
    # is kept, and its old date makes the next check try again
    if (-not $NoWindowsUpdate -and -not $fromWu -and (Test-Path -LiteralPath $Path)) {
        $have = @(Select-String -LiteralPath $Path -Pattern '^-----BEGIN CERTIFICATE-----').Count
        if ($have -gt $valid.Count) { throw "Windows Update's list of roots couldn't be downloaded; keeping the existing $have roots." }
    }

    $sb = New-Object Text.StringBuilder
    foreach ($c in $valid) {
        $b64 = [Convert]::ToBase64String($c.RawData)
        [void]$sb.Append("# $($c.Subject -replace '[^\x20-\x7E]', '?')`n-----BEGIN CERTIFICATE-----`n")
        for ($i = 0; $i -lt $b64.Length; $i += 64) { [void]$sb.Append($b64.Substring($i, [Math]::Min(64, $b64.Length - $i)) + "`n") }
        [void]$sb.Append("-----END CERTIFICATE-----`n")
    }
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item -LiteralPath $tmp -Destination $Path }
    [pscustomobject]@{ Count = $valid.Count; FromWindowsUpdate = $fromWu }
}

# makes the global part of an mpv.conf (before the first [profile]) point tls-ca-file at $CaFile.
# returns 'added', 'updated' (it pointed at a file that's gone), 'kept' (already right) or 'custom'
# (the user set their own existing file, which is left alone). mpv doesn't expand ~~ in tls-ca-file,
# so the line needs the full path; quotes keep spaces in user names working.
function Set-MpvCaFile {
    param([Parameter(Mandatory)][string]$Conf, [Parameter(Mandatory)][string]$CaFile)
    $bytes = [IO.File]::ReadAllBytes($Conf)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
    if ($bom) { $text = $text.Substring(1) }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($text -split "\r?\n"))
    if ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

    $want = 'tls-ca-file="' + $CaFile + '"'
    $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimStart().StartsWith('[')) { $end = $i; break } }
    $at = -1; $verify = -1
    for ($i = 0; $i -lt $end; $i++) {
        if ($lines[$i] -match '^\s*(--)?tls-ca-file\s*=\s*(.*?)\s*$') { $at = $i; $current = $Matches[2] }
        elseif ($lines[$i] -match '^\s*(--)?tls-verify\s*=') { $verify = $i }
    }
    if ($at -ge 0) {
        if ($lines[$at].Trim() -eq $want) { return 'kept' }
        $current = $current.Trim('"')
        if ($current -and (Test-Path -LiteralPath $current -PathType Leaf)) { return 'custom' }
        $lines[$at] = $want
        $result = 'updated'
    } elseif ($verify -ge 0) {
        $lines.Insert($verify + 1, $want)
        $result = 'added'
    } else {
        # an mpv.conf from before this fix: add the line with its reason at the end of the global part
        $block = @('', '# https streams: windows'' trusted root certificates, exported by install.cmd (see tools\ca-bundle.ps1)', $want)
        if ($end -lt $lines.Count) { $block = $block[1..2] + '' }
        $lines.InsertRange($end, [string[]]$block)
        $result = 'added'
    }
    $out = ($lines -join $nl) + $nl
    $enc = New-Object Text.UTF8Encoding($bom)
    [IO.File]::WriteAllText("$Conf.tmp", $out, $enc)
    Move-Item -LiteralPath "$Conf.tmp" -Destination $Conf -Force
    $result
}
