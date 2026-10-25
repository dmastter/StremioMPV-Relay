# StremioMPV Relay

StremioMPV Relay patches the official Stremio app for Windows so its built-in player loads an mpv configuration from `%APPDATA%\stremio-mpv`, and it swaps the player's libmpv for a newer build. With the configuration in this repo, playback recovers by itself when a stream's connection breaks or slows to a crawl, and a small script picks the original audio and real English subtitles. Continue Watching keeps working because it is still Stremio's own player.

This project isn't affiliated with Stremio or mpv, and it doesn't redistribute anything from them. The installer builds Stremio from its public source on your PC with a 7-line patch, and downloads libmpv from shinchiro's builds (third-party Windows builds that mpv.io links to), checked against a pinned SHA-256.

## What it fixes

### Streams that stall and never come back

Sometimes Stremio's player sits on the spinner with no network activity, and only seeking gets it going again. The author hit this with TorBox. To measure it, we played a 2-minute video from a local test server that breaks the connection on purpose (`tests\network`) and timed how long playback took to continue after each fault.

| libmpv and settings | Connection cut | Server closes the connection early | Cut, then HTTP 503 on reconnect | Connection stalls (open, no data) |
|---|---|---|---|---|
| Stremio's own libmpv (0.41.0-524) with Stremio's reconnect settings | recovers (~6 s) | never recovers | recovers | never recovers |
| Stremio's own libmpv with this repo's settings | ~32 s | ~62 s | ~32 s | ~61 s |
| Newer libmpv with Stremio's settings | ~7 s | ~6 s | ~67 s | ~67 s |
| Newer libmpv with this repo's settings (what gets installed) | ~22 s | ~21 s | ~22 s | ~21 s |
| Newer libmpv with mpv's curl client and 64 MB chunks (an earlier version of this project) | recovers | recovers | fails: the video ends early | inconsistent: hung for minutes in some runs |

"Never recovers" means the player hung and made no new request, which is the same bug as in real use. On a plain cut, Stremio's own setup is quicker. The installed setup recovers from all four faults in about 20 seconds.

So in practice you should see far fewer stalls, and when a connection breaks, playback resumes on its own in about 20 seconds in our tests. Real debrid CDNs weren't tested this way.

The settings are in `config\mpv.conf`. They turn off mpv's newer curl HTTP client (it doesn't retry HTTP errors yet, which is why the earlier version failed on a 503), give up on a connection that sends nothing for 15 seconds, and tell FFmpeg to reconnect after drops, an early end of data, network errors and HTTP 408, 429, 500, 502, 503 and 504.

### Connections that stay open but are too slow

A debrid CDN sometimes hands out a connection that keeps sending, only far below the video's bitrate. In one real case a 4K episode needing about 2.9 MB/s got 1.0 to 1.5 MB/s, so the player stopped to buffer every few seconds, while a fresh connection to the same link got 39 MB/s, and 4 at once 75 MB/s. It happened again about 8 minutes after each new connection, typically once the cache was full and the connection had sat idle. FFmpeg only reconnects when nothing arrives at all for `network-timeout` seconds, so it kept the slow connection until the server happened to close it.

The script `stream-watchdog.lua` handles this in one of two ways:

- **Through the relay** (the default once `install.cmd` has built `relay.exe`). Remote links go through a small program on your PC that downloads each part of the video over several connections at once, in short requests, and replaces a slow connection in the background. The player reads from it as if it were the server, so it never has to seek or wait for a new connection. It listens only on `127.0.0.1`, needs a random key that only the player knows, writes sizes and speeds to `relay\relay.log` but never links, and stops by itself when Stremio closes or after 5 minutes without use.
- **Without the relay** (if it can't be built or started). With a slow connection and less than a second buffered, or after 2 seconds waiting for data, it seeks just past the cached data, which makes the player open a new connection, and then seeks back to where you were. Nothing is skipped, but you see a pause of a second or two while the new connection starts. In the tests (`slow` and `tls-slow` in `tests\network`), the same setup without the script stopped every second and never caught up.

If the new connections are slow too, reconnecting can't help: the server or your line is the limit. After two of those, the script shows "The server sends X MB/s and this video needs Y MB/s: it's the server or the network, not the player" and stops trying for 5 minutes. It never makes more than 4 new connections in 5 minutes. It leaves local files, HLS and links from Stremio's own local server (torrents) alone.

### HTTPS streams that never start

FFmpeg, which opens the streams with these settings, checks HTTPS certificates but can't read Windows' certificate store. Without help, every `https` link (debrid CDNs such as TorBox's) fails with `tls: error:0A000086`, and Stremio shows its spinner forever. Links that go through Stremio's own local server use plain HTTP, so they were never affected.

`install.cmd` exports Windows' trusted root certificates to `cacert.pem` in `%APPDATA%\stremio-mpv` and points `tls-ca-file` in `mpv.conf` at it, so certificates are still checked. It takes the full list of roots from Windows Update, because Windows only downloads most of them the first time something needs one, and adds the ones on your PC, such as those of a company network or an antivirus that scans HTTPS. It refreshes the file on every run.

### Wrong audio and subtitle tracks

Many releases tag their tracks badly: a dub marked as default, "English" subtitle tracks that are really Czech or Chinese, the real English track flagged forced. The script `original-tracks.lua` sorts this out on every video:

- Audio: the track flagged or titled "original", otherwise the English one, never a commentary track. A file with a single audio track keeps it.
- Subtitles: English text subtitles embedded in the file, checked by reading their lines as they play. A track whose lines are full of letters outside the English alphabet (Cyrillic, Greek, Chinese, Czech accents and so on) or have no common English words is rejected and the next one is tried. The odd accented name like "José" is fine. Full subtitles come first, then SDH, then tracks flagged forced. Image subtitles (PGS, VobSub) can't be read, so they're skipped.
- If the file has no English subtitles of its own, subtitles are turned off and Stremio is free to use addon subtitles.
- For 30 seconds after a video loads, the script undoes Stremio's own track changes. After that, whatever you pick in Stremio's menu stays, including subtitles off.
- Subtitle size follows Stremio's setting. Stremio's default solid white text and black outline get 88% opacity, and any color you pick in Stremio is left alone.

While tracks are being tested, subtitles can be missing for a few seconds: the most likely track is shown right away, and if it turns out wrong, the others are tested hidden until one passes. Two messages can appear on screen: "This release has no original audio: pick another one" and "This release has no English subtitles of its own".

## Requirements

- Windows 10 or 11, 64-bit.
- The official Stremio app from [stremio.com](https://www.stremio.com/downloads), version 5.0.24 or later.
- A GPU driver that provides Vulkan (`vulkan-1.dll`). The newer libmpv needs it, and the installer checks it before changing anything.
- About 5 GB of disk for build tools on the first run: Git, Rust and Visual Studio 2022 Build Tools (C++ and the Windows SDK). The installer offers to install whichever are missing with winget, plus 7-Zip on Windows builds whose `tar` can't open `.7z` files.

## Install

1. Download this repo (Code > Download ZIP) and extract it. Running `install.cmd` from inside the ZIP won't work.
2. Double-click `install.cmd`. Don't run it as administrator; the tool installers ask for permission themselves. It asks before installing anything or closing Stremio. The first run can take 20 minutes or more, and later runs are much faster.
3. In Stremio, open Settings > Player and set "Play in external player" to Disabled.

After a full install, `install.cmd` starts Stremio and prints "The patched player started and loaded your config."

### After a Stremio update

Stremio's updates put its official files back, so the fixes stop working until the patch is applied again. Stremio itself keeps working in the meantime.

`install.cmd` offers to do this for you, tied to Stremio rather than running all the time:

- When Stremio starts, the player script `stremio-autopatch.lua` starts `tools\autopatch.ps1` from this folder, which sleeps (idle priority, about 17 MB, no CPU) until Stremio's process ends, however it ends: quitting from the tray icon, "Install now" on an update, a crash. Then it waits for Stremio's updater, checks the size and date of two files (about 0.3 seconds), puts the patch back if an update replaced it, and exits. It can't simply react to Stremio closing: Stremio ends its process without shutting the player down, so the player's scripts never see it. Closing Stremio's window with the X only hides it in the tray.
- An update can also happen while no patched Stremio is running (Stremio installed again, or an update applied as it starts). For that case a scheduled task, "StremioMPV Relay autopatch", runs the same check once when you log on. It runs as you, without admin rights or a window, at low priority, and exits.
- It never closes Stremio. If the updater started the new, unpatched version, it shows a notification once (quit Stremio from its tray icon when you finish watching), sleeps until Stremio has quit and then patches. In the one real update so far (5.0.26 to 5.0.27), it patched within a minute of quitting.

Before re-patching it waits for the network (up to 30 minutes, for a logon before Wi-Fi is up), and a failed attempt (GitHub down, a new Stremio version not tagged yet) is tried again up to 3 times, 15 minutes apart or when Stremio closes. It never installs build tools on its own: if they were removed, it says so and `install.cmd` has to be run. The installer records the new state before swapping each file in one step, so a shutdown in the middle leaves something the next check recognises and finishes. It also notices when this folder has newer scripts, a newer `relay.cs` or a newer pinned libmpv (unless you chose another one with `-MpvTag ... -AllowUnpinned`), and refreshes `cacert.pem` once a week, keeping the old one if Windows Update can't be reached. It logs what it did to `%USERPROFILE%\stremio-mpv-build\autopatch.log`. If a re-patch fails, it says so with a notification, and Stremio keeps working without the fixes until you run `install.cmd` to see why.

Without the task, run `install.cmd` again after every Stremio update. When nothing has changed, `install.cmd` only refreshes the config: it updates the scripts, `relay.exe` and `cacert.pem` and keeps your `mpv.conf` and `original-tracks.conf`. Close Stremio fully and start it again afterwards.

A new Stremio version is built from its tag on Stremio's GitHub, so the install can fail for a while if that tag isn't published yet, or if Stremio changed the code the patch hooks into (see Troubleshooting).

If you download a newer version of this repo that pins a newer libmpv, run `install.cmd` again, or let the scheduled task do it the next time Stremio is closed.

### With an AI agent

Open this folder in an AI coding agent (Claude Code, Codex, Cursor or similar) and ask it to "Follow AGENTS.md". The agent will ask you before installing tools, closing Stremio or running the installer outside its sandbox, and it checks the result through the player.

## Customize

Your config lives in `%APPDATA%\stremio-mpv`. Changes apply the next time Stremio starts, so make sure it has fully closed first.

| What | Where | Notes |
|---|---|---|
| Subtitle size and color | Stremio's own settings | The script follows them. |
| Opacity of Stremio's default subtitle colors | `sub_alpha` in `script-opts\original-tracks.conf` | 0.88 by default. 1 leaves them solid; values below 0.2 count as 0.2. |
| A fixed subtitle size that ignores Stremio | `sub_scale` in `script-opts\original-tracks.conf` | 0 (off) by default. Stremio's 100% is about 0.66. |
| How long Stremio's track picks are undone | `guard_seconds` in `script-opts\original-tracks.conf` | 30 by default. |
| When a slow connection is replaced | `stall_seconds` in `script-opts\stream-watchdog.conf` | 2 by default: seconds of waiting for data. The file is optional; create it to change this. |
| How many new connections at most | `max_reconnects` in `script-opts\stream-watchdog.conf` | 4 per 5 minutes by default (without the relay). |
| The relay | `relay=no` in `script-opts\stream-watchdog.conf` | On by default when `relay\relay.exe` exists. `relay_connections` sets how many connections per link (4). |
| Automatic re-patching | `autopatch-path.txt` and the task "StremioMPV Relay autopatch" | Delete `autopatch-path.txt` and run `tools\autopatch-task.ps1 -Remove` to turn it off; `install.cmd` turns it on again. |
| Cache size | `demuxer-max-bytes` and `demuxer-max-back-bytes` in `mpv.conf` | 400 MiB ahead and 100 MiB behind. |
| Reconnection | `network-timeout` and `stream-lavf-o` in `mpv.conf` | Check the table above before changing these. |
| HTTPS certificates | `tls-verify` and `tls-ca-file` in `mpv.conf` | `install.cmd` writes the `tls-ca-file` line with the full path of `cacert.pem` (mpv doesn't expand `~~` there). If you point it at a file of your own, that's kept. |
| Debug log | `log-file` in `mpv.conf` | Off. It records stream URLs, which can contain your debrid key. |
| IPC pipe | `input-ipc-server` in `mpv.conf` | On. Remove the line to turn it off. |
| Other mpv scripts | `scripts\` | Another script that also picks tracks will fight with `original-tracks.lua`. |

`original-tracks.conf` and `stream-watchdog.conf` take one `key=value` per line, with no spaces around `=` and comments on their own line, saved without a BOM (Notepad's "UTF-8" is fine). `install.cmd` keeps your edited `mpv.conf` and `original-tracks.conf` unless you pass `-ForceConfig`, and always replaces `scripts\original-tracks.lua` and `scripts\stream-watchdog.lua` with the repo's copies. The one line it adds to a kept `mpv.conf` is `tls-ca-file`, when it's missing or points at a file that no longer exists.

## What gets installed where

| What | Where |
|---|---|
| Patched `stremio-shell-ng.exe`, built on your PC | Stremio's folder, usually `%LOCALAPPDATA%\Programs\Stremio` |
| `libmpv-2.dll`, the pinned shinchiro build | Stremio's folder |
| Backup of Stremio's official signed exe and dll | `%USERPROFILE%\stremio-mpv-build\original-<version>` |
| Stremio's source, the build output, the libmpv download and `state.json` | `%USERPROFILE%\stremio-mpv-build` |
| mpv config and scripts, and `cacert.pem` (Windows' trusted root certificates) | `%APPDATA%\stremio-mpv` |
| `relay.exe`, built on your PC from `tools\relay\relay.cs` with Windows' own C# compiler, and its log | `%APPDATA%\stremio-mpv\relay` |
| `autopatch-path.txt`, the path of `tools\autopatch.ps1` that the player starts with Stremio | `%APPDATA%\stremio-mpv` |
| Scheduled task "StremioMPV Relay autopatch" (as you, no admin, once at logon) | Task Scheduler. It runs `tools\autopatch.ps1` from this folder, so keep the folder where it is. |
| Build tools, only if missing and you agree | Git, Rust (`%USERPROFILE%\.rustup` and `.cargo`), Visual Studio 2022 Build Tools, 7-Zip |

After each install, source and libmpv folders from older versions are deleted from the build folder.

## Check that it's working

You don't need an agent for this:

- In Stremio's folder, right-click `stremio-shell-ng.exe` and open Properties. Stremio's official file has a Digital Signatures tab and the patched one doesn't.
- `install.cmd` ends with "The patched player started and loaded your config."
- Watch something for a minute and close it. It should show up in Continue Watching with its progress.

### Is my debrid CDN fast enough?

`tools\diagnose.ps1` has a "CDN speed" section built from the relay's log (sizes and speeds only): for each of the last 7 days, the median and lowest speed of a single connection to your debrid CDN while it downloaded. The relay uses 4 connections at once, so playback only suffers if 4 times the lowest falls below what your videos need (a 4K remux about 3-4 MB/s). If that keeps happening for days, run your debrid service's speed test (TorBox: torbox.app/speedtest) and pick the CDN it recommends in your account settings. A single bad evening isn't a reason to switch: the relay already replaces slow connections.

## Troubleshooting

| Symptom | What to do |
|---|---|
| "winget isn't available" | Install App Installer from the Microsoft Store, or install Git, Rust and the Visual Studio 2022 Build Tools by hand. Then run `install.cmd` again. |
| "C++ build tools or the Windows SDK are still missing", or the build can't find `rc.exe` | Reboot if an installer asked you to, then run again. If it still fails, open Visual Studio Installer, modify Build Tools 2022 and add "Desktop development with C++" with a Windows 11 SDK. |
| "git isn't on PATH yet" or "rustup isn't on PATH yet" | Close the window and run `install.cmd` again. |
| "Patch anchor found 0 times in player.rs" (or 2 or more) | Stremio changed the code the patch hooks into, and nothing was installed. Check for a newer version of this repo, or open an issue. |
| "has no matching tag in Stremio/stremio-shell-ng yet" | Stremio hasn't published the source of your version yet. Try again in a few days. |
| "The pinned libmpv build ... is no longer on GitHub" | shinchiro keeps about 30 builds. Download the latest version of this repo. If it still pins the same build, `install.cmd -MpvTag latest -AllowUnpinned` uses the newest build, checked only against GitHub's checksum. |
| "Checksum missing or wrong" or "doesn't match the pinned SHA-256" | Don't try to get around it. Run again later, and open an issue if it repeats. |
| "Windows' tar can't open .7z files" (some Windows 10 builds) | Install 7-Zip (`winget install 7zip.7zip`) and run again. |
| "This libmpv can't load on this PC" | The newer libmpv needs Vulkan. Install or update your GPU driver. Nothing was changed. |
| "Smart App Control is on" | Windows may block the locally built exe and the dll. The installer asks before going on. If Stremio won't start afterwards, run `restore.cmd`. |
| Your antivirus flags `stremio-shell-ng.exe` | The file is unsigned and was built on your PC, which some antivirus products distrust. Allow that file if you trust the build, or run `restore.cmd`. |
| "Don't run this as administrator" | Double-click `install.cmd` as your normal user, or run it from a terminal that isn't elevated. |
| "neither Stremio's signed original nor one this installer built" | Your Stremio exe isn't the official one (a fork, or a build you made). Reinstall Stremio from stremio.com, or pass `-Force` if you know what that file is. |
| The fixes stopped working after Stremio updated | Run `install.cmd` again. |
| Every debrid stream spins forever, while torrents through Stremio play | The HTTPS certificate check can't find `cacert.pem`. Run `install.cmd` again, then close Stremio fully and start it. `tools\diagnose.ps1` shows `cacert.pem` and `tls-ca-file in mpv.conf`. |
| "The patched player didn't come up", or Stremio misbehaves | Run `restore.cmd` to go back to the official files, then open an issue. |
| Subtitles are missing for a few seconds at the start | The script is testing tracks hidden. They appear once an English track passes. |
| Wrong audio or subtitles | Pick the right track in Stremio's menu after the first 30 seconds and it will stay. Please open an issue with the release name. |

## Reporting a problem

Open PowerShell in this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diagnose.ps1
```

It only reads. It prints a report and saves it as `stremio-mpv-diagnose.txt` on your Desktop, with links cut down to their host name and your Windows user name removed, and it never opens the playback log. If a video is playing while you run it, the report includes its track list, which helps with wrong-track problems. Read the report, then open an issue with the bug report form. Please never post stream links, debrid keys or the playback log.

Security problems go through [SECURITY.md](SECURITY.md) instead.

## Privacy

Nothing here needs or reads your Stremio or debrid accounts, and there's no telemetry. The installer talks to GitHub (Stremio's source, one of its dependencies and shinchiro's releases), crates.io (Rust dependencies), Windows Update (Microsoft's list of trusted root certificates, through `certutil -generateSSTFromWU`) and, only if it installs tools, winget's sources and Rust's download servers.

The playback log is off by default because it records stream URLs, and those can contain your debrid API key. If you turn it on, remove the URLs before sharing it with anyone.

The IPC pipe `\\.\pipe\stremio-mpv` is on: `install.cmd` uses it to confirm the player started, and agents use it to check the settings. It's a local pipe, but any program running as your user could use it to see what's playing or to control the player. Remove the `input-ipc-server` line from `mpv.conf` to turn it off.

## Uninstall

1. Double-click `restore.cmd`. It removes the scheduled task, puts back Stremio's official signed files from the backup, and asks before closing Stremio. If Stremio has updated itself since, the official files are already back and there's nothing to restore.
2. Delete `%USERPROFILE%\stremio-mpv-build` and `%APPDATA%\stremio-mpv`. Running `restore.cmd -RemoveConfig` from a terminal deletes the config too, after asking.
3. If you installed the build tools only for this, you can remove them:

```powershell
rustup self uninstall
winget uninstall --id Microsoft.VisualStudio.2022.BuildTools --exact
winget uninstall --id Git.Git --exact
winget uninstall --id 7zip.7zip --exact
```

If `restore.cmd` finds no backup, reinstall Stremio from stremio.com to get the official files back.

## FAQ

### Does it need my Stremio or debrid account, or any key?

No. Nothing here logs in anywhere or reads your keys.

### Does it override my language settings?

Yes. It always looks for the original audio and English subtitles, and for the first 30 seconds of each video it undoes Stremio's own track picks, including the ones that come from your language settings. Changes you make after that stay.

### Can it pick subtitles in other languages?

Not yet. The text check only knows English. [CONTRIBUTING.md](CONTRIBUTING.md) explains what adding a language would take.

### Does it work on macOS, Linux or Android?

No. The patch is for Stremio's Windows app (stremio-shell-ng) only.

### Why not just download a ready-made patched exe?

Stremio's shell source has no LICENSE file, so there's no permission to redistribute builds of it. You also shouldn't run an unsigned exe from a stranger. Building it on your PC means you run Stremio's own code plus a patch you can read in `patch\config-loading.rs.txt`.

### Does it work with "Play in external player"?

No. It changes Stremio's built-in player, so that setting has to be Disabled.

## License

MIT for the files in this repo (see [LICENSE](LICENSE)). Stremio and mpv belong to their authors and keep their own terms. This project downloads them on your PC and doesn't redistribute them.
