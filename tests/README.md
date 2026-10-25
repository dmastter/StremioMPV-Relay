# Tests

Automated checks for the parts of StremioMPV Relay that can be tested without Stremio: the PowerShell
scripts, `config\scripts\original-tracks.lua`, `config\scripts\stream-watchdog.lua` and the network
options in `config\mpv.conf`.
Everything runs on a standalone `mpv.com` with `--no-config`, in a work folder of its own. The tests
never touch the installed Stremio, `%APPDATA%\stremio-mpv` or a running player, and the test media is
generated on the fly. No binaries are committed.

## Running them

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1
```

You need:

| Tool | Used for | Found automatically at |
|---|---|---|
| `mpv.com` | playing the fixtures | `PATH`, `%LOCALAPPDATA%\Programs\mpv`, `%ProgramFiles%\mpv`, scoop |
| `ffmpeg.exe` | generating the test media (any recent version) | `PATH`, `%ProgramFiles%\ffmpeg\bin`, scoop, Stremio's own `ffmpeg.exe` |
| Python 3 | the fault-injecting HTTP server | `PATH` (`python.exe`, or the `py` launcher) |
| `openssl.exe` | the test certificates for the HTTPS modes | `PATH`, Git for Windows (`%ProgramFiles%\Git\usr\bin`) |
| PSScriptAnalyzer | lint (optional locally) | installed modules |

Use a recent shinchiro build of mpv, ideally the release pinned in `config\mpv-pin.json`, so you test the
same mpv that Stremio will run. Pass explicit paths, or skip suites, when needed:

```powershell
.\tests\run-all.ps1 -Mpv C:\tools\mpv\mpv.com -Ffmpeg C:\tools\ffmpeg\bin\ffmpeg.exe -Python C:\Python312\python.exe
.\tests\run-all.ps1 -SkipNetwork -WorkDir C:\temp\stremiompv-relay-tests
```

Generated media and logs go to `-WorkDir` (default `%TEMP%\stremiompv-relay-tests`): `fixtures\`,
`network\`, `logs\lua\<case>.out`, `logs\network\mpv-<mode>.out` and `server-<mode>.out`, and a
`results.json` per suite. A full run takes about 4 minutes, almost all of it the track tests, which play
in real time. `run-all.ps1` exits with 1 if any suite fails.

Each suite can also run on its own:

| Script | What it does | Time |
|---|---|---|
| `tests\lint.ps1` | Parses every `.ps1` with Windows PowerShell 5.1's parser, flags non-ASCII files without a UTF-8 BOM (5.1 would read them as ANSI) and runs PSScriptAnalyzer. Errors fail; warnings are only counted. `-RequireAnalyzer` fails when PSScriptAnalyzer is missing; `-AnalyzerPath` imports it from a folder. | seconds |
| `tests\config\run-config-tests.ps1` | Tests `tools\ca-bundle.ps1`: the exported `cacert.pem` (local stores, then with Windows Update's list unless `-Offline`) and the `tls-ca-file` line in the repo's `mpv.conf`, an older one without it, one with profiles, a stale path, the user's own file and a BOM. With `-Mpv`, mpv reads the line back from a folder with a space in its name. It also runs `tools\autopatch.ps1 -CheckOnly` against fake Stremio and build folders: everything in place, not installed, an outdated or missing script, an old `cacert.pem`, a newer pinned libmpv, a foreign exe, a replaced dll and, where a backup of Stremio's signed files exists, a real update. | seconds |
| `tests\fixtures\make-fixtures.ps1 -OutDir <dir>` | Generates the subtitle fixtures and `manifest.json`. Skips the work when nothing changed. | seconds |
| `tests\lua\run-track-tests.ps1` | Track script tests. `-Only manual-*,tagged` runs some cases; `-Script` and `-ScriptOpts` test another copy of the script or its options. | ~3 min |
| `tests\network\run-network-tests.ps1` | Network fault tests. `-Modes ok,stall` runs some modes; `-Conf` tests another `mpv.conf`. | ~45 s (`slowall`), up to the hang limit |
| `tests\relay\run-relay-tests.ps1` | Builds `relay.exe` and plays through it in real time against the fault server: no wait for data allowed. Also checks its responses, its log and that it exits by itself. | ~2 min |

## Track script tests (`tests\lua`)

`fixtures\make-fixtures.ps1` builds small MKVs with ffmpeg: a tiny `lavfi` video, silent audio tracks
and SRT subtitle tracks made from `fixtures\dialogue.json`. The dialogue was written for these tests,
along with its Czech, Greek and Chinese translations. Every fixture declares the `sid` (and `aid`) the
script must end up with:

| Fixture | Scenario | Expected sid |
|---|---|---|
| `tagged` | correct tags: full English, SDH and a forced signs track; Russian dub is the default audio | 1 |
| `mislabeled` | Czech, Greek and Chinese tracks tagged `eng`; the real English carries the forced flag | 4 |
| `typographic` | curly quotes, ellipses, dashes and music notes in the real English; Czech tagged `eng` ranks first | 2 |
| `untagged` | Greek tagged `eng`, and the real English with no language tag | 2 |
| `sdh-only` | only an SDH track, with a cold open full of `[cues]` | 1 |
| `sdh-vs-fake` | SDH track (default flag) and a Czech track tagged as plain English | 1 |
| `signs-sparse` | a sparse signs track tagged English ranks first, the full English second | 2 |
| `late-english` | Czech tagged `eng`, an English track that starts at 70 s, and a full English SDH | 3 |
| `long-intro` | dialogue starts after a 20 s silent intro; a sparse forced track talks during the intro | 1 |
| `single-late` | a single English track that starts at 20 s | 1 |
| `two-sparse` | two sparse tracks rank first; the full English starts at 20 s | 3 |
| `english-at-130` | Czech tagged English talks from 5 s; the real English starts at 130 s | 2 |
| `all-at-130` | every track is silent until 130 s, longer than the 120 s probe limit | 2 |
| `resume-seek` | Stremio resumes at 2:30; Czech tagged English and the real English talk all along | 2 |
| `no-english` | only Czech and Greek tracks, correctly tagged | no |
| `fake-only` | two tracks tagged English that are really Czech and Greek | no |
| `single-english` | one untitled English track; the Russian dub is the default audio | 1 |

`lua\run-track-tests.ps1` plays every fixture in its own `mpv.com --no-config --vo=null --ao=null`, in
real time and in parallel, with `lua\harness.lua` and the repo's script. The script gets the values of
`config\script-opts\original-tracks.conf` through `--script-opts`, because `--no-config` skips that
folder. The harness logs every track and style change, prints the file's track list and the final state
as JSON, and plays a fake Stremio:

- `sid=no` right after load, `aid=1` (the first audio track), Stremio's own pick of the first `eng`
  subtitle, then `sid=no` again;
- `sub-scale=0.66` (Stremio's 100%), `sub-color=#FFFFFFFF` and `sub-border-color=#FF000000` (its default colors).

The fixtures run with that interference, plus these extra cases:

| Case | Checks |
|---|---|
| `plain-mpv` | no Stremio at all (standalone mpv): same pick, size left at 1 |
| `custom-style` | Stremio at 75% size (`0.495`) with yellow text and a grey outline: all three kept |
| `manual-off` | the user turns subtitles off after the guard time (`guard_seconds` + 10 s): respected |
| `manual-pick` | the user picks the SDH track after the guard time: respected |
| `addon-no-english` | no English embedded: the addon subtitle Stremio loads stays selected |
| `addon-fake-only` | the English-tagged tracks are fake: the addon subtitle Stremio picked during the probe comes back |

Every case checks that:

- the final `sid` is the expected one, and subtitles are visible (`sub-visibility=yes`) when a track is expected;
- no hidden `secondary-sid` is left behind, and `aid` is the original audio;
- `sub-scale` is still what Stremio set, so the script doesn't force a size. If `sub_scale` in the
  options file is above 0, that value is expected instead;
- Stremio's default colors are softened to `sub_alpha` (`#E0FFFFFF` and `#E0000000` at 0.88), and custom
  colors are left alone;
- the MKV really has the tracks the fixture declares (language, title, forced flag), so a different
  ffmpeg version can't silently change a scenario;
- the script logged something and raised no Lua error.

The table shows each case's final state, how many times subtitles were hidden while probing (`Hides`)
and when `sid` last changed (`SidAt(s)`).

## Network tests (`tests\network`)

`network\flaky_server.py` is a small HTTP server with Range support that breaks on purpose, once, when a
response reaches 30% of the file. Because the fault is tied to a file offset, not a request number, it
works whatever request size the player uses:

| Mode | Fault |
|---|---|
| `ok` | none |
| `close` | the connection is reset (TCP RST) |
| `fin` | the server closes the connection cleanly before the end: the client sees an early end of data |
| `close503` | reset, and the reconnection gets an HTTP 503 (what Real-Debrid does) |
| `503` | clean close, and the reconnection gets an HTTP 503 |
| `stall` | the server stops sending and keeps the connection open |
| `slow` | that response goes on at a tenth of the video's bitrate and stays open (a congested CDN node); new connections get full speed |
| `slowall` | every response runs at 0.9 times the bitrate from its first byte (a slow server or line), so reconnecting can't help |
| `maxage`, `idleclose` | also available for manual tests: connections recycled after 20 s, or closed after 5 s without reads |

With `--tls CERT KEY` the server speaks HTTPS. The runner's `tls-<mode>` modes use that: it makes a
throwaway CA and a certificate for `127.0.0.1` with openssl, and gives mpv the CA as `tls-ca-file` (it
replaces the `cacert.pem` path the installer writes). It runs `tls-ok`, `tls-close503`, `tls-stall` and
`tls-slow` like their HTTP versions, and `tls-untrusted`, where mpv gets an unrelated CA and passes only if playback
is refused with a `tls:` certificate error. That's the failure every HTTPS stream had before `cacert.pem`.

`network\run-network-tests.ps1` generates a 2-minute video (about 30 MB) and plays it once per mode, all
modes at the same time, with `config\scripts\stream-watchdog.lua` loaded (`-NoWatchdog` leaves it out;
`slow` and `tls-slow` then hang, which shows the test catches a slow connection). It runs `mpv.com --no-config --vo=null --no-audio --untimed` with the network
options read from `config\mpv.conf` on every run: `cache*`, `demuxer-*`, `curl-*`, `network-timeout`,
`stream-*`, `http-*` and `tls-*`. So the test follows whatever the conf says, and fails early if this mpv
doesn't know one of those options. `network\report.lua` prints how far playback got. A mode passes when:

- playback reaches the end (within 1.5 s) with reason `eof`;
- mpv exits by itself before the hang limit (2 × `network-timeout` + 60 s, at least 90 s);
- the server log shows the fault really happened;
- for `slowall`, which plays only the first 30 s: the watchdog logged that reconnecting doesn't help and
  the server saw at most 8 requests, so it doesn't keep reconnecting when that can't help.

The table also lists the number of requests and the player's first network message.

## CI (`.github\workflows`)

- **`ci.yml`** runs on every push and pull request. The `lint` job installs PSScriptAnalyzer 1.24.0 and
  runs `tests\lint.ps1 -RequireAnalyzer` under Windows PowerShell 5.1. The `tests` job runs
  `tests\ci\get-tools.ps1`, then `tests\run-all.ps1 -SkipLint`, and uploads the logs if something fails.
  `get-tools.ps1`:
  - downloads the player package `mpv-x86_64-<date>-git-<hash>.7z` from the same shinchiro release as
    `config\mpv-pin.json`, and checks it against the SHA-256 digest GitHub's API reports;
  - checks that the release's `mpv-dev` asset still matches the pin, and that `mpv.com` reports the pinned `mpvVersion`;
  - downloads ffmpeg (a gyan.dev release build, pinned by tag and SHA-256 in `ci.yml`).

  GitHub's runners have no GPU driver, so no `vulkan-1.dll`, which `mpv.exe` imports. In that case
  `tests\ci\New-VulkanStub.ps1` compiles a stand-in DLL with MSVC that exports the same functions and
  reports Vulkan as unavailable. The tests use `--vo=null`, so Vulkan is never used. shinchiro keeps
  about 30 releases, so this job starts failing once the pinned build is deleted: that's the signal to
  update the pin.
- **`upstream-canary.yml`** runs daily, or by hand with an optional tag. It takes the newest
  `vX.Y.Z` tag of Stremio/stremio-shell-ng, applies the patch with `tools\apply-patch.ps1` and builds it
  with `cargo build --release --target x86_64-pc-windows-msvc` (with `--locked` first, as `install.ps1`
  does). If any step fails, it opens an issue titled "Upstream canary: the patch or build fails on the
  newest stremio-shell-ng", or comments on the open one. It closes that issue once a run passes again.
  It only has `contents: read` and `issues: write`.
