<#
.SYNOPSIS
  Sends JSON IPC commands to a running mpv (e.g. Stremio's patched player) and prints the replies.
.EXAMPLE
  .\tools\mpv-ipc.ps1 -Pipe stremio-mpv -Commands '["get_property","sid"]','["get_property","current-tracks/sub/lang"]'
#>
param(
    [string]$Pipe = 'stremio-mpv',
    [Parameter(Mandatory)][string[]]$Commands
)
$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
$client.Connect(5000)
$writer = New-Object System.IO.StreamWriter($client)
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($client, [Text.Encoding]::UTF8)
$id = 0
foreach ($cmd in $Commands) {
    $id++
    $writer.WriteLine('{"command":' + $cmd + ',"request_id":' + $id + '}')
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        # mpv also sends events on the pipe; skip until our reply arrives
        if ($line -match ('"request_id":' + $id + '\b')) {
            $obj = $line | ConvertFrom-Json
            [pscustomobject]@{ command = $cmd; data = $obj.data; error = $obj.error }
            break
        }
    }
}
$client.Dispose()
