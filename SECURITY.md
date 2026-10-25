# Security

## What the installer downloads

| What | From | How it's checked |
|---|---|---|
| Stremio's shell source | `git clone --depth 1` of the tag `v<version>` from https://github.com/Stremio/stremio-shell-ng | For versions listed in `$KnownShellCommits` in `install.ps1` (currently 5.0.26), the tag must point to the reviewed commit or the install stops. Other versions are built from the tag as Stremio published it. |
| Rust dependencies | crates.io, plus one Git dependency on GitHub (Stremio/native-windows-gui, at the commit in `Cargo.lock`) | `cargo build --locked` uses exactly the versions in Stremio's `Cargo.lock` and checks each crate's checksum. If that build fails, the installer retries without `--locked` and says so in its output. |
| libmpv | Release assets of https://github.com/shinchiro/mpv-winbuild-cmake, third-party Windows builds that mpv.io links to | The download URL must be under that repo's releases. The `.7z` must match both GitHub's SHA-256 digest and `sha256` in `config\mpv-pin.json`, and the extracted `libmpv-2.dll` must match `dllSha256`. With `-AllowUnpinned`, only GitHub's digest is checked. |
| Microsoft's list of trusted root certificates, for `cacert.pem` | Windows Update, through `certutil -generateSSTFromWU` | Windows' own checks. Roots in Windows' Disallowed stores and expired ones are left out; your PC's own trusted roots are added. |
| Build tools, only if missing and you agree | winget packages `Git.Git`, `Rustlang.Rustup`, `Microsoft.VisualStudio.2022.BuildTools` and `7zip.7zip`; rustup then downloads the Rust toolchain | winget's and rustup's own checks. |

The release lookup goes to `api.github.com`. If a `GITHUB_TOKEN` environment variable is set, the installer sends it there as a bearer token (to avoid rate limits) and nowhere else. Nothing about you is sent anywhere, and nothing from Stremio or mpv is redistributed by this repo.

## Things to know

- The patched `stremio-shell-ng.exe` is built on your PC and is unsigned, so Windows, Smart App Control and antivirus products can't vouch for it. The official signed files are backed up in `%USERPROFILE%\stremio-mpv-build\original-<version>`, and `restore.cmd` puts them back.
- `install.cmd` and `restore.cmd` run the PowerShell scripts next to them as you, with `-ExecutionPolicy Bypass` for that one process. Read `install.ps1` before running it. It refuses to run as administrator; the tool installers ask for elevation themselves.
- `-Yes` answers every prompt. In a sandboxed agent shell it also lets the installer start itself outside the sandbox through WMI, which is why agents are told to ask the user first.
- `-Force` rebuilds and reinstalls, and it also skips two checks: the reviewed-commit check and the refusal to overwrite an exe that is neither Stremio's signed original nor one this installer built.
- Scripts in `%APPDATA%\stremio-mpv\scripts` run inside Stremio's player with your rights. Anything that can write to that folder can run code there, so only add scripts you trust.
- The IPC pipe `\\.\pipe\stremio-mpv` is on by default. Any program running as your user can connect to it and send any mpv command, including ones that start other programs, and can read the current stream URL. Remove the `input-ipc-server` line from `mpv.conf` if you don't need it.
- The relay (`%APPDATA%\stremio-mpv\relay\relay.exe`) is built on your PC from `tools\relay\relay.cs` and is unsigned. It listens only on `127.0.0.1`, on a port it picks, and answers only requests that carry a random 128-bit token, which only the player gets; it verifies HTTPS certificates against Windows' own store. Stream links reach it inside the player's request path, so a program running as you that can read the player's memory or its IPC pipe could see them, as it already can. Its log never records links, hosts or queries. `relay=no` in `script-opts\stream-watchdog.conf` turns it off.
- With every Stremio session (started by the player, it waits for Stremio to end), and once at logon (scheduled task "StremioMPV Relay autopatch"), `tools\autopatch.ps1` runs from this repo folder as you, without admin rights, and through it `install.ps1 -Yes` when Stremio needs the patch again. Anything that can write to this folder, or to `%APPDATA%\stremio-mpv\autopatch-path.txt`, could change what runs then, so keep the repo in a folder only you can write to (your Documents is fine). `restore.cmd` deletes the task and `autopatch-path.txt`.
- The playback log is off by default because it records stream URLs, which can contain your debrid API key.
- `tools\diagnose.ps1` only reads. It cuts URLs down to their host, removes your Windows user name and never opens the playback log. Read its output before posting it anyway.

## Reporting a vulnerability

Please report security problems privately through GitHub: open the Security tab of https://github.com/dmastter/StremioMPV-Relay and choose "Report a vulnerability" (https://github.com/dmastter/StremioMPV-Relay/security/advisories/new). Don't open a public issue for them. Include what you found, how to reproduce it and which version of this repo you used. If that button isn't available, open an issue that only asks for a private contact, with no details.

This is a small personal project with no bounty. Only the latest version on the `main` branch gets fixes.

## Problems that belong elsewhere

- Bugs in Stremio itself, the ones that also happen with the official, unpatched app, go to Stremio: https://github.com/Stremio/stremio-bugs/issues. Please don't report problems caused by this patch to Stremio.
- Problems in mpv go to https://github.com/mpv-player/mpv, and problems specific to shinchiro's builds to https://github.com/shinchiro/mpv-winbuild-cmake.
