# AGENTS.md

This is the runbook for an AI agent that sets up StremioMPV Relay on a user's Windows PC. It assumes you know nothing else about the project. Read all of it before running anything.

## The end state

1. Stremio's official Windows app (stremio-shell-ng) runs an exe built on this PC from Stremio's source plus a 7-line patch (`patch\config-loading.rs.txt`). The patch sets `config-dir` to `%APPDATA%\stremio-mpv`, `config` to `yes` and `load-scripts` to `yes` before libmpv initializes, so the built-in player loads that folder.
2. `libmpv-2.dll` in Stremio's folder is the build pinned in `config\mpv-pin.json` (shinchiro `20261019`, mpv v0.41.0-1224-g6a262d11f, client API 2.6).
3. `%APPDATA%\stremio-mpv` holds `mpv.conf`, `scripts\original-tracks.lua`, `scripts\stream-watchdog.lua`, `scripts\stremio-autopatch.lua` and `script-opts\original-tracks.conf`, copied from `config\`, plus `cacert.pem` with Windows' trusted root certificates. `mpv.conf` has a `tls-ca-file="<full path of cacert.pem>"` line: without it every `https` stream fails with `tls: error:0A000086` and Stremio spins forever.
4. Stremio's official signed exe and dll are backed up in `%USERPROFILE%\stremio-mpv-build\original-<version>`, and `%USERPROFILE%\stremio-mpv-build\state.json` records what was installed.
5. In Stremio, Settings > Player > "Play in external player" is Disabled.
6. `%APPDATA%\stremio-mpv\relay\relay.exe` is built from `tools\relay\relay.cs` with Windows' own C# compiler (`relay.cs.sha256` next to it records the source), and `stream-watchdog.lua` plays remote links through it.
7. Re-patching after Stremio updates, tied to Stremio: when Stremio starts, `scripts\stremio-autopatch.lua` starts `tools\autopatch.ps1 -WaitPid <Stremio's pid>` from this repo folder (the path is in `%APPDATA%\stremio-mpv\autopatch-path.txt`), which sleeps at idle priority until that process ends. Stremio ends its process without shutting libmpv down, so mpv's `shutdown` event can't be used. The scheduled task "StremioMPV Relay autopatch" (as the user, no admin) runs the same script once at logon, for updates made while no patched Stremio ran. It waits for Stremio's updater, patches only while Stremio isn't running, and exits. Nothing runs between Stremio sessions. Closing Stremio's window only hides it in the tray; quitting is from the tray icon.

Everything is built and downloaded on the user's PC. Never upload, commit or share the built exe, the DLL or the backup. Stremio's shell source has no LICENSE file, so builds of it must not be redistributed.

## Ground rules

- Ask the user before installing any tool (Git, Rust, Visual Studio 2022 Build Tools, 7-Zip), before closing Stremio, and before passing `-Yes` to `install.ps1`. `-Yes` answers yes to every prompt, including running the installer outside your sandbox and registering the scheduled task (tell the user about it; `-NoAutoPatch` leaves it out).
- Never print stream URLs: they can contain the user's debrid API key. From the player, never print `path`, `filename`, `stream-open-filename`, the full `track-list` or whole `current-tracks/...` objects (external tracks carry addon URLs). Use the checks in "Verify".
- The mpv log (`log-file` in `mpv.conf`) is off by default. Don't turn it on unless the user asks. If they do, never paste its contents anywhere, and turn it off again when you're done.
- Don't touch the user's Stremio or debrid accounts. Nothing here needs them.
- Don't open issues or pull requests, or post anything anywhere, without the user's explicit consent.
- Don't run anything as administrator, and don't change Windows security settings (Smart App Control, antivirus, machine-wide execution policy).
- Don't overwrite the user's `mpv.conf` or `original-tracks.conf` without asking.

## Before you start

Collect the facts without changing anything. `tools\diagnose.ps1` is read-only and reports all of them; give it an `-OutFile` so it doesn't write to the user's Desktop:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diagnose.ps1 -OutFile "$env:TEMP\stremio-mpv-diagnose.txt"
```

What to look at:

- Windows is 64-bit and you're not running as administrator. `install.ps1` refuses to run elevated or from 32-bit PowerShell.
- Stremio's folder is the `InstallLocation` value under `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{DD3870DA-AF3C-4C73-B010-72944AB610C6}_is1`, or `%LOCALAPPDATA%\Programs\Stremio` if that's missing.
- `(Get-Item "<Stremio folder>\stremio-shell-ng.exe").VersionInfo.ProductVersion` is 5.0.24 or later, and the exe is x64.
- The exe is either Stremio's original (`Get-AuthenticodeSignature` returns `Valid` with a subject starting `CN=Smart Code OOD`) or the one recorded in `state.json`. Anything else is a fork or a manual build: stop and ask.
- Which build tools are missing.
- Whether your shell is sandboxed (see "Sandboxed shells and %APPDATA% redirection").

Then tell the user what will happen and get their OK: which tools will be installed with winget (accepting their licenses, about 5 GB for the Visual Studio Build Tools), that Stremio will be closed and started again, that the first run can take 20 minutes or more, and, if your shell is sandboxed, that the installer will run outside the sandbox.

## Path A: run the installer

This is the preferred path. After the user agreed, from the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Yes
```

- Call `install.ps1` directly. `install.cmd` ends with `pause`, which would hang a non-interactive shell.
- Run it in the background and poll its output. The first run can take 20 minutes or more (installing the Build Tools and compiling); a run with nothing to rebuild takes seconds.
- Agent shells can't answer prompts. Without `-Yes`, the first prompt fails or counts as "no" and the run stops. That's why you ask the user first and then pass `-Yes`.
- The last line of output is `DONE` or `FAILED`. On failure, the line before it starts with `ERROR:` and the exit code is 1.
- In a sandboxed shell, the installer detects the redirection. With `-Yes` it starts itself again outside the sandbox through WMI, writes that run's output to a log in the build folder and streams it into your output. Without `-Yes` it stops and says to confirm with the user first.

What it does, in order, so you can follow its output:

1. Refuses to run from 32-bit PowerShell or as administrator, and checks for the sandbox (skipped with `-BuildOnly`).
2. Checks Stremio: found, x64, version 5.0.24 or later, and the exe is Stremio's signed original or the one in `state.json` (otherwise it stops unless `-Force`). Warns and asks if Smart App Control is on.
3. If Stremio is already patched by it (same version, exe and DLL hashes as in `state.json`), it only refreshes the config and prints `DONE`.
4. Build tools: offers to install Git (`Git.Git`), Rust (`Rustlang.Rustup`), the Visual Studio 2022 Build Tools with the C++ workload (`Microsoft.VisualStudio.2022.BuildTools`) and, if Windows' `tar` can't read `.7z`, 7-Zip (`7zip.7zip`) with winget. If the C++ tools or the Windows SDK are still missing after that, it adds them to the newest Visual Studio installation with the Visual Studio installer. It installs the Rust toolchain `stable-x86_64-pc-windows-msvc` (minimal profile) and uses it through `RUSTUP_TOOLCHAIN`.
5. Source: finds the tag `v<version>` (or `v<version>-*`) in Stremio/stremio-shell-ng, clones it with depth 1 into `shell-<version>` in the build folder, and checks that HEAD is the reviewed commit for known versions (5.0.26: `e13a0912b287f90283db63d5359dda805154bf32`).
6. Applies the patch with `tools\apply-patch.ps1`.
7. Builds with `cargo build --release --locked --target x86_64-pc-windows-msvc` into a shared target folder (`<build folder>\target`). If that fails, it prints "Build with --locked failed; retrying without it." and builds without `--locked`.
8. Gets libmpv: downloads the pinned `.7z` from shinchiro's GitHub releases (or reuses a cached copy whose hash matches), checks it against GitHub's SHA-256 digest and `config\mpv-pin.json`, extracts `libmpv-2.dll` and `include\mpv\client.h`, checks the DLL hash, checks client API 2.x, and checks that the DLL loads on this PC (it needs `vulkan-1.dll` from the GPU driver). Nothing in Stremio's folder has changed up to this point.
9. Installs: checks Stremio didn't update itself meanwhile, checks it can write to Stremio's folder, closes Stremio (after asking), backs up both official signed files to `original-<version>` if that backup doesn't exist yet, and copies the new exe and DLL.
10. Copies the config (both scripts are always replaced), warns about other `.lua` scripts in `scripts\`, writes `cacert.pem` and the `tls-ca-file` line in `mpv.conf` (`tools\ca-bundle.ps1`), writes `state.json` and deletes old `shell-*` and `libmpv-*` folders. When Stremio is already patched (step 3) it does the config part only, and warns if Stremio is running, since the player reads the config when Stremio starts.
11. Builds `relay\relay.exe` in the config folder with `tools\relay\build.ps1` when `relay.cs` changed (a running relay's exe is renamed out of the way first), and, after asking, registers the scheduled task with `tools\autopatch-task.ps1`. Both also happen on the already-patched path.
12. Starts Stremio and waits up to 20 seconds for the pipe `\\.\pipe\stremio-mpv` ("The patched player started and loaded your config.").

Flags:

| Flag | Effect |
|---|---|
| `-Yes` | Answers yes to every prompt: installing tools with winget (accepting their licenses), closing Stremio, going on with Smart App Control on, and running outside the sandbox. Only after the user agreed. |
| `-StremioDir <path>` | Stremio's folder, when it isn't the registry location or the default. |
| `-WorkDir <path>` | Build folder (default `%USERPROFILE%\stremio-mpv-build`). It holds the backup. |
| `-MpvTag pinned\|latest\|<yyyymmdd>` | Which shinchiro build to use. Default `pinned`. |
| `-AllowUnpinned` | Accepts a build other than the pinned one, checked only against GitHub's digest. Ask the user first. |
| `-BuildOnly` | Builds and downloads only. Doesn't touch Stremio or the config, and skips the sandbox check. |
| `-ForceConfig` | Overwrites `mpv.conf` and `script-opts\original-tracks.conf`, losing the user's edits. Ask first. |
| `-Force` | Rebuilds and reinstalls even if already patched. It also overwrites an exe that is neither official nor in `state.json`, and skips the reviewed-commit check. Ask first. |
| `-NoLaunch` | Doesn't start Stremio at the end. |
| `-NeverClose` | If Stremio is running when its files must be replaced, stops with nothing changed instead of closing it. The scheduled task uses it. |
| `-NoAutoPatch` | Doesn't register the scheduled task. |
| `-Unattended` | For `tools\autopatch.ps1`: never installs or modifies build tools (stops instead), skips the sandbox probe, and stops if `state.json` is missing, so a restored Stremio isn't patched again. |
| `-ConfigDir <path>` | Testing only: copies the config somewhere else. The patched player always reads `%APPDATA%\stremio-mpv`. |
| `-LogFile <path>` | Also writes a transcript there. |

`-Relaunched` is used internally for the run outside the sandbox.

## Path B: the same steps by hand

Use this when the installer can't run, or to debug one step. It produces the same result as Path A. In a sandboxed shell, every write to `%APPDATA%` or Stremio's folder, and every Stremio launch, has to happen in a process started through WMI (see the sandbox section), so prefer Path A there.

```powershell
$repo = '<this repo>'
$work = "$env:USERPROFILE\stremio-mpv-build"
$stremio = '<Stremio folder>'
$ver = (Get-Item "$stremio\stremio-shell-ng.exe").VersionInfo.ProductVersion
New-Item -ItemType Directory -Force $work | Out-Null
```

1. Tools. After the user agreed, install what's missing:

   ```powershell
   winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
   winget install --id Rustlang.Rustup --exact --silent --accept-source-agreements --accept-package-agreements
   winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --silent --accept-source-agreements --accept-package-agreements --override "--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
   rustup toolchain install stable-x86_64-pc-windows-msvc --profile minimal
   ```

   The C++ tools are there when `& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath` prints a path. The Windows SDK is there when `rc.exe` exists under `<KitsRoot10>\bin\*\x64\`, with `KitsRoot10` read from `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots`. Stremio's `build.rs` needs `rc.exe`. After installing, open a new shell, or add `%USERPROFILE%\.cargo\bin` and Git's `cmd` folder to `PATH`.

2. Source. Use the tag `v<version>`; if it doesn't exist, look for `v<version>-*` in `git ls-remote --tags --refs https://github.com/Stremio/stremio-shell-ng.git`.

   ```powershell
   git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$ver" https://github.com/Stremio/stremio-shell-ng.git "$work\shell-$ver"
   $head = (git -C "$work\shell-$ver" rev-parse HEAD).Trim()
   ```

   For 5.0.26, `$head` must be `e13a0912b287f90283db63d5359dda805154bf32`. If it isn't, stop and tell the user. For versions not listed in `$KnownShellCommits` in `install.ps1` there's no reviewed commit; tell the user you're building the tag as published.

3. Patch:

   ```powershell
   & "$repo\tools\apply-patch.ps1" -Source "$work\shell-$ver"
   ```

   It inserts `patch\config-loading.rs.txt` right before the only line in `src\stremio_app\stremio_player\player.rs` that starts with eight spaces and `set_property!("wid"`, and does nothing if the file already sets `config-dir`. `patch\player.rs.diff` shows the result for 5.0.26.

4. Build. `RUSTUP_TOOLCHAIN` overrides the `rust-toolchain.toml` in Stremio's source.

   ```powershell
   $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
   $env:CARGO_TARGET_DIR = "$work\target"
   Push-Location "$work\shell-$ver"
   cargo build --release --locked --target x86_64-pc-windows-msvc
   Pop-Location
   $built = "$work\target\x86_64-pc-windows-msvc\release\stremio-shell-ng.exe"
   ```

   If `--locked` fails, building without it lets cargo pick dependency versions other than the ones in Stremio's `Cargo.lock`. The installer does that automatically; if you do it by hand, tell the user.

5. libmpv. Download the pinned build and check it against both GitHub's digest and the pin:

   ```powershell
   $pin = Get-Content "$repo\config\mpv-pin.json" -Raw | ConvertFrom-Json
   $rel = Invoke-RestMethod "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/tags/$($pin.tag)" -Headers @{ 'User-Agent' = 'StremioMPV-Relay' }
   $asset = $rel.assets | Where-Object name -eq $pin.asset
   $mpvDir = "$work\libmpv-$($pin.tag)"
   New-Item -ItemType Directory -Force $mpvDir | Out-Null
   $archive = Join-Path $mpvDir $pin.asset
   Invoke-WebRequest $asset.browser_download_url -OutFile $archive -UseBasicParsing
   $h = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
   ($h -eq $pin.sha256) -and ("sha256:$h" -eq $asset.digest)    # must be True
   ```

   The download URL must start with `https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/`. If the release no longer exists (shinchiro keeps about 30 builds), stop and ask: the options are a newer version of this repo, or `-MpvTag latest -AllowUnpinned`, which trusts GitHub's digest alone.

   Extract only the two files you need. Windows' own `tar` reads `.7z` only when `tar --version` mentions `liblzma`, which some Windows 10 builds don't:

   ```powershell
   New-Item -ItemType Directory -Force "$mpvDir\ex" | Out-Null
   & "$env:SystemRoot\System32\tar.exe" -xf $archive -C "$mpvDir\ex" libmpv-2.dll include/mpv/client.h
   # without liblzma, use 7-Zip instead:
   # & "$env:ProgramFiles\7-Zip\7z.exe" x -y "-o$mpvDir\ex" $archive libmpv-2.dll include\mpv\client.h
   ```

   Then check that `(Get-FileHash "$mpvDir\ex\libmpv-2.dll").Hash` equals `$pin.dllSha256` (case doesn't matter), that `include\mpv\client.h` contains `#define MPV_CLIENT_API_VERSION MPV_MAKE_VERSION(2,`, and that the DLL loads on this PC:

   ```powershell
   Add-Type -Namespace StremioMpvNative -Name K32 -MemberDefinition '[DllImport("kernel32",SetLastError=true,CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibraryExW(string p,IntPtr h,uint f); [DllImport("kernel32")] public static extern bool FreeLibrary(IntPtr h);'
   $hd = [StremioMpvNative.K32]::LoadLibraryExW("$mpvDir\ex\libmpv-2.dll", [IntPtr]::Zero, 0x1100)
   if ($hd -eq [IntPtr]::Zero) { 'does not load' } else { [void][StremioMpvNative.K32]::FreeLibrary($hd); 'loads' }
   ```

   If it doesn't load, stop: nothing has been changed yet. It needs `vulkan-1.dll` in `System32`, which comes with the GPU driver, so the user should install or update their GPU driver.

6. Install. Check that `(Get-Item "$stremio\stremio-shell-ng.exe").VersionInfo.ProductVersion` is still `$ver` (Stremio can update itself during a long build). Ask the user, then close Stremio:

   ```powershell
   $mine = { Get-Process stremio-shell-ng, stremio-runtime -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$stremio\*" } }
   & $mine | ForEach-Object { [void]$_.CloseMainWindow() }
   Start-Sleep 3
   & $mine | Stop-Process -Force
   ```

   Back up the official files only if `$work\original-$ver\stremio-shell-ng.exe` doesn't exist yet, and only if both files are Stremio's signed originals (status `Valid`, subject starting `CN=Smart Code OOD`). Never overwrite an existing backup.

   ```powershell
   New-Item -ItemType Directory -Force "$work\original-$ver" | Out-Null
   Copy-Item "$stremio\stremio-shell-ng.exe", "$stremio\libmpv-2.dll" "$work\original-$ver"
   Copy-Item $built "$stremio\stremio-shell-ng.exe" -Force
   Copy-Item "$mpvDir\ex\libmpv-2.dll" "$stremio\libmpv-2.dll" -Force
   ```

7. Config, in `%APPDATA%\stremio-mpv`:
   - Create `scripts` and `script-opts`.
   - Always copy `config\scripts\original-tracks.lua`, `config\scripts\stream-watchdog.lua` and `config\scripts\stremio-autopatch.lua` into `scripts\`.
   - Copy `config\mpv.conf` and `config\script-opts\original-tracks.conf` only if they don't exist yet. If they do, keep them and tell the user how they differ from the repo's copies.
   - If `scripts\` contains other `.lua` files, tell the user: another script that picks tracks will fight with `original-tracks.lua`.
   - Write `cacert.pem` and the `tls-ca-file` line. This is needed in every install, also when the user's `mpv.conf` was kept:

     ```powershell
     . "$repo\tools\ca-bundle.ps1"
     Export-CaBundle -Path "$env:APPDATA\stremio-mpv\cacert.pem"          # Count, FromWindowsUpdate
     Set-MpvCaFile -Conf "$env:APPDATA\stremio-mpv\mpv.conf" -CaFile "$env:APPDATA\stremio-mpv\cacert.pem"
     ```

     `Set-MpvCaFile` returns `added`, `updated`, `kept` or `custom` (the user's own existing file, left alone). mpv doesn't expand `~~` in `tls-ca-file`, so the line holds the full path.

   - Build the relay: `& "$repo\tools\relay\build.ps1" -Out "$env:APPDATA\stremio-mpv\relay\relay.exe"`, then write the SHA-256 of `tools\relay\relay.cs` to `relay\relay.cs.sha256` next to it.

8. `state.json`. Later `install.ps1` runs use it to recognise the exe as theirs; without it they refuse to overwrite a non-official exe unless `-Force`. The scheduled task reads it too.

   ```powershell
   @{ version = $ver; exeHash = (Get-FileHash "$stremio\stremio-shell-ng.exe").Hash; dllHash = (Get-FileHash "$stremio\libmpv-2.dll").Hash
      mpvTag = $pin.tag; shellCommit = $head; stremioDir = $stremio; date = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content "$work\state.json" -Encoding UTF8
   ```

   `exeHash` and `dllHash` are the SHA-256 of the installed files as `Get-FileHash` prints them (uppercase hex).

   With the user's OK, turn on re-patching: write the full path of `$repo\tools\autopatch.ps1` to `%APPDATA%\stremio-mpv\autopatch-path.txt` and register the logon task with `& "$repo\tools\autopatch-task.ps1"`. `-Status` shows the task, `-Remove` deletes it.

9. Start Stremio (through WMI if your shell is sandboxed) and check that the pipe appears within about 20 seconds: `[IO.Directory]::GetFiles('\\.\pipe\') -contains '\\.\pipe\stremio-mpv'`. Then run the checks in "Verify".

10. Ask the user to set Settings > Player > "Play in external player" to Disabled.

Optionally, delete `shell-*` and `libmpv-*` folders in `$work` from older versions.

## Sandboxed shells and %APPDATA% redirection

Some desktop agent apps, including the Claude desktop app, run their shell in a sandbox where writes to `%APPDATA%` (and sometimes `%LOCALAPPDATA%`) are silently redirected to a private folder, for example `%LOCALAPPDATA%\Packages\<app>\LocalCache\Roaming\...`. Your own reads and tests look fine, but Stremio, started by the user, reads the real folder and finds nothing.

`install.ps1` handles this. It writes probe files to `%APPDATA%` and to Stremio's folder, checks them from a process started through WMI (which runs outside the sandbox), and if they were redirected it starts itself outside the sandbox, but only with `-Yes`. `restore.ps1` only detects it: it stops and asks the user to double-click `restore.cmd`.

To check by hand:

```powershell
$work = "$env:USERPROFILE\stremio-mpv-build"
New-Item -ItemType Directory -Force $work | Out-Null
$probe = Join-Path $env:APPDATA 'stremio-mpv-probe.tmp'
$out = Join-Path $work 'probe.txt'
[IO.File]::WriteAllText($probe, 'probe')
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd /c (if exist `"$probe`" (echo REAL) else (echo REDIRECTED)) > `"$out`"" } | Out-Null
Start-Sleep 2
Get-Content $out        # REAL or REDIRECTED
Remove-Item $probe, $out
```

Keep the parentheses around the whole `if ... else ...`. Without them, cmd applies `> "<out>"` only to the `else` branch, so a REAL result never reaches the file.

When writes are redirected:

- Prefer Path A with `-Yes`, after asking the user.
- For manual steps, stage files in a folder that isn't redirected (the build folder under `%USERPROFILE%` works) and copy them with a process started through `Win32_Process.Create`, writing its output to a file you can read.
- Start Stremio through WMI too, so it reads the real config.
- Keep paths under 260 characters. Longer paths break `tar`, `Copy-Item` and mpv's script loading.

## Verify

Query the player with `tools\mpv-ipc.ps1`. Run it inside your current PowerShell session with the call operator, not as a separate `powershell -File` process:

```powershell
& .\tools\mpv-ipc.ps1 -Commands '["get_property","mpv-version"]', '["get_property","config-dir"]', '["get_property_string","options/curl-enabled"]', '["get_property_string","options/network-timeout"]', '["get_property_string","options/stream-lavf-o"]', '["get_property_string","options/tls-verify"]', '["get_property_string","options/tls-ca-file"]'
```

Expected as soon as Stremio is running (no playback needed):

| Property | Expected |
|---|---|
| `mpv-version` | `mpv v0.41.0-1224-g6a262d11f`, the `mpvVersion` in `config\mpv-pin.json` |
| `config-dir` | ends in `\stremio-mpv` |
| `options/curl-enabled` | `no` |
| `options/network-timeout` | `15` (`15.000000` as a string) |
| `options/stream-lavf-o` | contains `reconnect_at_eof=1` |
| `options/tls-verify` | `yes` |
| `options/tls-ca-file` | ends in `\stremio-mpv\cacert.pem`, and that file exists |

If the user kept an older `mpv.conf`, `curl-enabled`, `network-timeout` and `stream-lavf-o` can differ. Tell them; don't change it on your own.

During playback (ask the user to start something):

| Property | What it tells you |
|---|---|
| `aid`, `sid` | The selected audio and subtitle track ids. |
| `current-tracks/audio/lang`, `current-tracks/sub/lang` | Their language tags. |
| `sub-visibility` | `false` while candidates are being tested hidden. |
| `sub-scale` | Follows Stremio's size setting: 100% is 0.66. |
| `sub-color` | `#E0FFFFFF` while Stremio's text color is its default. |

When the user says playback keeps stopping to buffer, run `tools\diagnose.ps1` while it plays. Its player section shows `network speed now`, `video needs (average)`, `buffered ahead` and `waiting for data`, without URLs. A speed far below what the video needs, while buffered ahead stays near zero, is a slow connection: `stream-watchdog.lua` should replace it within a few seconds (see "How stream-watchdog.lua decides"). If it stays slow after that, the server or the user's line is the limit, and the player shows a message saying so. Don't conclude that from one reading: a single connection can be slow while a new one to the same link is fast, and the speed changes from minute to minute. Never test the stream URL yourself with another tool unless the user agrees, and never print it.

For an overview of the tracks, use `tools\diagnose.ps1`: it prints a reduced track list (id, type, lang, title, codec, default, forced, selected) with URLs and the user name removed. The track script's own messages go to the mpv log, which is off, so judge it by these properties.

Signs a user can check alone: the exe's Properties has no Digital Signatures tab, and Continue Watching keeps progress.

The repo also has automated tests (`tests\run-all.ps1`, described in `tests\README.md`): lint, the track script against generated fixtures with simulated Stremio interference, and the network settings against a fault-injecting server. They run on every push in GitHub Actions; run them locally if you change `config\` or the scripts.

## Reference setup

The author's working setup, checked on 2026-10-20:

| Item | Value |
|---|---|
| Windows | 11 Pro, x64 |
| Stremio | 5.0.26, official app |
| Official `stremio-shell-ng.exe` before patching | sha256 `23c301325bd13dd6c00471a5255d93e1f928431e1ea4a1ba4a29ba98a771e293`, signed by Smart Code OOD |
| Official `libmpv-2.dll` before patching | sha256 `c8d267f66bc1352cae1168362f11e7ca7a39fa898985527ca584199e966f6e5b` (mpv v0.41.0-524-g5921fe50b), signed by Smart Code OOD |
| Stremio source | tag `v5.0.26`, commit `e13a0912b287f90283db63d5359dda805154bf32` |
| Rust | 1.99 stable, `x86_64-pc-windows-msvc` |
| C++ tools | Visual Studio 2022 Build Tools (C++ tools and Windows SDK) |
| libmpv archive | shinchiro `20261019`, `mpv-dev-x86_64-20261019-git-6a262d11f6.7z`, sha256 `ca8604754170db6f1b23139d8449782b1ae294a883211131954d30085985f77b` |
| Installed `libmpv-2.dll` | sha256 `b57cd73984a458e6f1b2e5021d57825487b9e69ea78c9a4111dc7a90279d9764` (mpv v0.41.0-1224-g6a262d11f, client API 2.6) |
| Stremio settings | "Play in external player" Disabled, subtitle size 100%, everything else default |

The patched exe's hash differs from machine to machine. That's expected.

## What to tell the user at the end

Keep it short and leave out stream URLs:

- The Stremio version, that `stremio-shell-ng.exe` is now the locally built, unsigned patched exe, and where the backup of the official files is.
- The libmpv version from `mpv-version`.
- Which config files were written and which of the user's own were kept.
- The results of the checks in "Verify", and anything that didn't match.
- Any warnings: other scripts in `scripts\`, Smart App Control, a build without `--locked`, an unpinned libmpv.
- Whether `relay.exe` was built and the scheduled task registered (`tools\autopatch-task.ps1 -Status`).
- What's left for them: set "Play in external player" to Disabled, run `install.cmd` after every Stremio update if they didn't want the scheduled task, and use `restore.cmd` to undo everything (it also removes the task).

## Stop and ask the user when

- A tool needs installing, Stremio needs closing, or `-Yes` or the run outside the sandbox is needed, and you don't have their OK yet.
- The installer says the exe is "neither Stremio's signed original nor one this installer built". Don't add `-Force` on your own.
- The tag points to a different commit than the reviewed one ("not the reviewed commit"). Don't get around it with `-Force`.
- The patch anchor isn't found exactly once.
- The pinned libmpv is gone or a checksum doesn't match. Never work around a checksum, and use `-AllowUnpinned` only with the user's OK.
- libmpv doesn't load on this PC (Vulkan, GPU driver).
- Smart App Control is on.
- Stremio is older than 5.0.24, isn't x64, or isn't the official app.
- The user's `mpv.conf` or `original-tracks.conf` differ from the repo's. Overwriting them with `-ForceConfig` loses their edits.
- `restore.ps1` reports a sandbox. The user has to double-click `restore.cmd`.
- `autopatch.log` or a notification says a re-patch failed. Read `autopatch-install.log` in the build folder, then treat it like any failed `install.ps1` run.
- Anything fails in a way this file doesn't cover.

## If the patch doesn't apply

`tools\apply-patch.ps1` stops with "Patch anchor found N times in player.rs (expected 1)" when Stremio has changed that code. Nothing has been installed at that point. To fix it:

1. In `src\stremio_app\stremio_player\player.rs`, find where libmpv is created. In 5.0.26, `create_mpv` calls `Mpv::with_initializer(|initializer| { ... })` and defines a `set_property!` macro inside it.
2. The three properties (`config-dir` = `%APPDATA%\stremio-mpv`, `config` = `yes`, `load-scripts` = `yes`) must be set inside that initializer, before `mpv_initialize`. libmpv reads config files and loads scripts during initialization, and its default is `config=no`.
3. Pick a new anchor line that appears exactly once, right where the patch should go, and change `$anchor` in `tools\apply-patch.ps1`. Keep the `StremioMPV Relay` marker comment in `patch\config-loading.rs.txt`: the upstream canary looks for it. The script skips a tree that already sets `config-dir`.
4. Build, install and run the checks in "Verify". Patch nothing else in Stremio.
5. With the user's consent, offer the change upstream as a pull request (see CONTRIBUTING.md), including a regenerated `patch\player.rs.diff`.

## How stream-watchdog.lua decides

A debrid CDN sometimes hands out a connection that keeps sending far below the video's bitrate. FFmpeg's reconnect options only act when nothing arrives for `network-timeout` seconds, so a slow connection is kept until the server closes it, and playback stops to buffer every few seconds. The script runs on every file and replaces such a connection.

- It watches only remote network streams that can seek: not local files, not HLS or DASH, and not hosts on this PC (`127.0.0.1`, `localhost`, `::1`), which is how Stremio's own server serves torrents. `allow_local=yes` in `script-opts\stream-watchdog.conf` lifts the last limit (the tests use it).
- It does nothing for 8 seconds after a file loads or any seek, so the cache can fill.
- It acts when playback is waiting for data (`paused-for-cache`) for `stall_seconds` (2), or starts waiting again within 60 seconds of the previous wait, and the average download speed of the last 5 seconds is below 1.5 times the video's average bitrate (`file-size` / `duration` × `speed`). A connection faster than that isn't the problem, so it's left alone. With no known size or duration (live streams), it does nothing.
- To get a new connection, it seeks 0.05 s past the end of the cached data (`demuxer-cache-state/cache-end`). A target outside the cache makes the demuxer send a new request, which FFmpeg opens on a new connection. When playback restarts there, it seeks back to the position before the wait, which is normally still cached, so nothing is skipped and no further request is made.
- 6 seconds later it checks the new connection: if the cache isn't full and the speed is still below 1.5 times the bitrate, that counts as slow. After two slow new connections in a row, or 4 new connections within 5 minutes (`max_reconnects`), it stops for 5 minutes. When the speed is below the bitrate itself, it shows "The server sends X MB/s and this video needs Y MB/s: it's the server or the network, not the player" for 8 seconds.

Its messages go to the mpv log, which is off. The network tests `slow`, `tls-slow` and `slowall` cover it.

### The relay

When `relay\relay.exe` exists (and `relay` isn't `no` in `stream-watchdog.conf`), an `on_load` hook rewrites `stream-open-filename` for every remote `http(s)` link to `http://127.0.0.1:<port>/<token>/<base64url of the link>`. `path`, which Stremio reads, stays the original link. The seek trick above stays off for those files, since the relay handles slow connections itself. Played directly instead: links ending in `.m3u8`/`.m3u`/`.mpd` (HLS and DASH segments are named relative to the playlist's own URL), links with credentials (`user:pass@`), and links while `http-header-fields`, `referrer` or `cookies-file` is set, since the relay sends only the range and the User-Agent. If a link fails to open through the relay, an `on_load_fail` hook opens it again directly (as `lavf://<link>`, which mpv needs to retry).

- The script starts `relay.exe` as a subprocess of the player on the first such link, with `--ready-file %TEMP%\stremiompv-relay-<player pid>.json`, `--parent-pid <player pid>`, `--connections 4` and `--log ~~/relay/relay.log`, and waits up to 3 seconds for the ready file (`{"port":…,"token":…,"pid":…}`). If it doesn't come, the link plays directly.
- The relay listens only on `127.0.0.1` and answers only requests with its random token. It splits each requested range into chunks, downloads up to 4 at once on separate connections, streams the first one as it arrives, starts a second request on a new connection when a chunk is far slower than the others or stops for 2 seconds, and retries failed chunks (resets, 5xx, 503) for up to a minute before closing the player's connection, so FFmpeg's own reconnect takes over. After two failures on a redirected CDN link it resolves the original link again (another node), and a session that failed doesn't leave that link cached. Servers that answer a range with less than asked are followed up with requests for the rest. Sends to the player never block, so a player that closes during a seek can't leave a session behind.
- If the relay stops during playback, the script starts it again with the same port and token, so FFmpeg's reconnect finds it. It exits when the player exits and after 5 minutes without a client (common once a whole episode is cached); only exits within 30 seconds of starting count towards the limit of 5 restarts per file. A relay started fresh for a new file takes any free port.
- Its log has one line per request (range, size, speed, connections, replaced connections, retries, and `cdn X MB/s per connection`: the average rate of its connections while they downloaded, which is what the CDN delivers, unlike the request's own speed, which drops to the video's bitrate once the player's cache is full) and never a link, host or query. It's capped at about 1 MB.
- `tools\diagnose.ps1` sums it up in "CDN speed (relay.log, last 7 days)": per day, the downloads of 16 MB or more, the median and lowest per-connection CDN speed, and the replaced connections and retries. Only if 4 times the lowest stays below what the videos need for days is the CDN worth changing: the debrid service's speed test (TorBox: torbox.app/speedtest) recommends one, and the user changes it in their account. Never change the user's debrid settings yourself.
- `user-data/stream-watchdog/relay` says `yes` when the current file plays through it, or why not. `tools\diagnose.ps1` shows it as "through the relay".

`tests\relay\run-relay-tests.ps1` plays through the relay in real time against the fault server and checks that playback never waits for data.

## How original-tracks.lua decides

The script runs on every file load. Its options are in `script-opts\original-tracks.conf`: `sub_scale` (0), `sub_alpha` (0.88) and `guard_seconds` (30).

### Audio

Among the file's own audio tracks (external ones are ignored), it picks the first track flagged original or with "original" in its title or language tag (Cyrillic spellings too). Otherwise it picks the first English track: a language tag starting with `en`, or, when there's no tag or it's `und`, "english" in the title. Commentary tracks (the commentary flag, or "comment" in the title) are never picked this way. If there's exactly one audio track, that one is used. If nothing qualifies, the selection is left alone and "This release has no original audio: pick another one" shows for 8 seconds.

### Subtitle candidates

Only text tracks embedded in the file count. External tracks (addon subtitles) and image formats (`hdmv_pgs_subtitle`, `dvd_subtitle`, `dvb_subtitle`, `xsub`) are skipped, since image subtitles have no text to check. Candidates are ranked in five groups, in file order within each group:

1. English, with no forced flag and not SDH.
2. English SDH: the hearing-impaired flag, or "sdh", "hearing" or the word "cc" in the title.
3. English with the forced flag. The flag is often wrong.
4. No language tag (or `und`) and no "english" in the title.
5. English with "forced" in the title (Cyrillic spellings too).

### Text check

Each new line from a track under test is cleaned first: ASS `{...}` and HTML `<...>` tags, `[...]` and `(...)` cues, typographic quotes, dashes, ellipses and music notes are removed. A line then counts as foreign when it has 3 or more letters outside ASCII (accented Latin, Greek, Cyrillic, CJK and so on), or when such letters make up more than 10% of its letters. Words are runs of ASCII letters and apostrophes, and English words are those in a built-in list of very common dialogue words.

For each track:

- It's rejected as soon as it has at least 2 foreign lines making up more than half its lines, or at least 2 lines and 8 words with no common English word.
- It stays undecided until it has at least 4 lines and 12 words.
- Then it's confirmed if at least 20% of its words are common English words and at most a third of its lines are foreign. Otherwise it's rejected.

A repeated line (after seeking back) counts once, the line already on screen when a track is assigned is ignored, and a line with no words and no foreign letters is ignored.

### Testing two tracks at a time

- On load, candidate 1 goes to `sid` and is visible. Candidate 2 goes to `secondary-sid`, hidden because `secondary-sub-visibility` is set to no. Their lines are read from `sub-text` and `secondary-sub-text`.
- A rejected track is replaced by the next candidate in the queue. Once the visible track has been rejected, `sub-visibility` is turned off and the rest are tested hidden.
- When a track is confirmed while the other slot holds a better-ranked track that is still undecided, the script waits up to 15 seconds for it, then takes the best confirmed one. Otherwise it takes the confirmed track at once.
- An undecided track goes to the back of the queue (if other candidates are waiting) when it has been silent for 15 seconds of video while the other slot showed a line, or for 45 seconds of video once any line has been seen. That keeps sparse signs tracks and tracks that start late from blocking the rest.
- After 120 seconds of played video, counted from the first line seen and not counting seeks, it takes the best confirmed track, or failing that the best-ranked track still under test.
- When it settles on a track, it sets `sid` to it, turns off `secondary-sid`, turns `sub-visibility` on, and keeps reverting outside `sid` changes for 10 more seconds.
- If every candidate is rejected, it shows "This release has no English subtitles of its own" for 6 seconds and turns subtitles off. If Stremio tried to select a track that wasn't a candidate (an addon subtitle, for example) while the script was reverting its changes, it switches to that track instead.
- If there were no candidates at all, it sets `sid=no` on load without a message, and leaves Stremio's later choices alone, so Stremio can load addon subtitles.

### Stremio's own track changes

Stremio sends `sid=no` on load and then sets `aid` and `sid` from its own preferences. For `guard_seconds` (30 seconds of real time) after load, the script reverts any `aid` change if it picked an audio track, and any `sid` change if it has subtitle candidates, including changes the user makes. After that, a `sid` change is treated as the user's choice: testing stops and the choice is kept, including subtitles off. Audio changes after the guard are left alone.

### Size and colors

Size is left to Stremio, whose 100% is `sub-scale` 0.66. With `sub_scale` above 0, the script sets that value whenever `sub-scale` changes. When Stremio sets `sub-color` to `#FFFFFFFF` or `sub-outline-color` to `#FF000000` (its default solid colors), the script replaces them with white or black at `sub_alpha` opacity; at 0.88, mpv reports `sub-color` as `#E0FFFFFF`. Any other color is left alone. A `sub_alpha` below 0.2 is raised to 0.2, and 1 or more turns this off.

### Fallback in mpv.conf

If the script can't act, `alang=eng,en`, `slang=eng,en`, `subs-with-matching-audio=yes`, `subs-fallback=no` and `subs-fallback-forced=no` make mpv prefer English and skip default-flagged or forced tracks in other languages.

### Tested scenarios

The script was tested on 15 scenarios covering:

- correctly tagged releases;
- Russian editions with many dubs;
- a real release where seven "eng" tracks were really Czech, German, Greek, French, Malay, Slovak and Chinese, and the real English track was flagged forced;
- SDH-only releases that open with `[cues]`;
- sparse signs tracks;
- English that starts late, at 2:10;
- long intros;
- seeking;
- files with no English;
- simulated Stremio interference (`sid=no`, its own `aid` and `sid`, scale and colors).

A reviewer also ran a simulation of 2,700 scenarios.

## Alternative without patching

If the user doesn't want a patched Stremio, set "Play in external player" to M3U Playlist and make `.m3u` files open with a standalone mpv (a shinchiro build) whose `%APPDATA%\mpv` folder holds the same `mpv.conf` options, `original-tracks.lua` and `stream-watchdog.lua`. On Windows, Stremio's external player options are only VLC and M3U Playlist. The cost is progress: Stremio can mark an episode as watched when it's opened, but it gets no playback position back from an external player, so Continue Watching can't resume.
