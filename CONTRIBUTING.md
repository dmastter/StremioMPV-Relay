# Contributing

Issues and pull requests are welcome. For a bug, use the bug report form and include the output of `tools\diagnose.ps1`. For anything bigger than a fix, open an issue first so we can agree on the approach.

## Ground rules

- Never commit binaries or build output. `.gitignore` already excludes `.exe`, `.dll`, `.7z`, `.zip`, `.log` and `state.json`. Never share builds of Stremio either: its shell source has no LICENSE file.
- Never put stream URLs, debrid keys or playback logs in issues, commits or test fixtures.
- Keep the patch to Stremio minimal. It only turns on config loading; behaviour belongs in `config\`.

## Running the tests

`tests\run-all.ps1` runs the test suites:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1
```

They use a standalone mpv (`mpv.com`), ffmpeg to generate the subtitle test files, and Python 3 and openssl (Git for Windows has one) for the network tests. The runners look for these on `PATH` and in common install folders, or take their paths as parameters. The track tests play generated files through `config\scripts\original-tracks.lua` with a fake Stremio changing tracks, and the network tests play a video from `tests\network\flaky_server.py`, a local HTTP server that breaks the connection on purpose (reset, early close, 503 on reconnect, stalls, a connection that turns slow and more), over plain HTTP and over HTTPS with a test certificate, with `config\scripts\stream-watchdog.lua` replacing slow connections. `tests\config` checks `tools\ca-bundle.ps1`, which makes HTTPS streams work in the installed player.

Tests must never touch the installed Stremio or `%APPDATA%\stremio-mpv`: run mpv with `--no-config` and work in a temporary folder. Run the tests before and after changing `config\mpv.conf`, the scripts in `config\scripts` or the installer.

## Updating the pinned libmpv

`config\mpv-pin.json` names the libmpv build the installer accepts:

| Field | Meaning |
|---|---|
| `tag` | shinchiro release tag, `yyyymmdd` |
| `asset` | Archive name, `mpv-dev-x86_64-<date>-git-<hash>.7z` (the plain x86_64 one, without `-v3`) |
| `sha256` | SHA-256 of that `.7z`, lowercase hex |
| `dllSha256` | SHA-256 of the `libmpv-2.dll` inside it, lowercase hex |
| `mpvVersion` | What the player reports as `mpv-version`, for example `mpv v0.41.0-1224-g6a262d11f` |

To move to a newer build:

1. Pick a release from https://github.com/shinchiro/mpv-winbuild-cmake/releases.
2. Run `install.ps1 -BuildOnly -MpvTag <tag> -AllowUnpinned`. It builds Stremio (reusing the cached build), downloads the archive into the build folder, checks it against GitHub's digest, checks client API 2.x and that the DLL loads, and prints where the DLL is.
3. Hash the archive and the DLL with `(Get-FileHash <file> -Algorithm SHA256).Hash.ToLower()` and fill in the fields.
4. Install it on a test machine, read `mpv-version` through the pipe (see AGENTS.md) for `mpvVersion`, and run the tests, the network ones above all.
5. Update the reference table in AGENTS.md.

Existing installs keep their old libmpv on a plain re-run, because the installer sees Stremio as already patched. Tell users to run `install.cmd -Force` in the release notes.

mpv's curl HTTP client stays off (`curl-enabled=no`) because it doesn't retry HTTP errors yet, so a 503 ends the video early. Before turning it back on in a newer build, check the 503 cases of the network tests.

## Updating the patch anchor

`tools\apply-patch.ps1` inserts `patch\config-loading.rs.txt` right before the only line in `src\stremio_app\stremio_player\player.rs` that starts with eight spaces and `set_property!("wid"`. It stops if that text appears 0 or 2+ times, and does nothing if the file already contains `StremioMPV Relay`. When a Stremio release changes that file:

1. Find where libmpv is created. The three properties must be set inside the initializer, before `mpv_initialize`.
2. Change `$anchor` in `tools\apply-patch.ps1` to a line that appears exactly once, where the patch should go.
3. Keep the `StremioMPV Relay` marker comment in `patch\config-loading.rs.txt`, which the upstream canary looks for. The script skips a tree that already sets `config-dir`, so it's safe to run twice.
4. Regenerate `patch\player.rs.diff` from a patched checkout of the new tag.
5. Read the changes between the old and new tags (`player.rs`, `build.rs` and `Cargo.lock` above all) and add the new tag's commit to `$KnownShellCommits` in `install.ps1`.
6. Build, install, and run the tests and the checks in AGENTS.md.

## Adding a subtitle language

This isn't supported yet. The text check only knows English, and a new language would need:

- a list of its common words, like `WORDS` in `original-tracks.lua`;
- a different rule for foreign letters, since today any letter outside ASCII counts as foreign, which would reject most other languages;
- its language codes in `is_english()` and in `alang`/`slang` in `mpv.conf`;
- an option in `script-opts\original-tracks.conf` to choose the language, and the on-screen message to match;
- new test cases.

Please open an issue before starting on this.

## Style

- PowerShell has to run on Windows PowerShell 5.1: no `??`, no ternary operator, no `ConvertFrom-Json -AsHashtable`. Keep `.ps1` files ASCII-only, because 5.1 reads files without a BOM in the system's ANSI code page, and check that they parse with `[System.Management.Automation.Language.Parser]::ParseFile`.
- Native tools that write to stderr (git, cargo, rustup, winget) go through the `Run` helper in `install.ps1`, so Windows PowerShell doesn't turn their progress output into errors.
- The automatic re-patching runs `install.ps1` from the folder `install.cmd` last ran from, with whatever is in it, after every Stremio session that needs it. If you develop in that folder, half-done edits to `config\scripts`, `relay.cs` or `install.ps1` reach your player the next time Stremio ends. Work in a separate clone, or delete `%APPDATA%\stremio-mpv\autopatch-path.txt` while you work.
- Line endings follow `.gitattributes`: CRLF for `.ps1` and `.cmd`, LF for `.lua` and `.cs`. The installed `relay.exe` is matched to the SHA-256 of `relay.cs`, so a line-ending change would make the next check rebuild it.
- Code comments are short, lowercase and explain why.
- Messages to the user say what happened and what to do next.
- Docs are plain English with sentence-case headings, and every claim has to match the code.
