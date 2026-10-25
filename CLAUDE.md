# CLAUDE.md

Everything an agent needs is in [AGENTS.md](AGENTS.md). Read all of it before running anything on the user's PC.

The Claude desktop app runs its shell in a sandbox where writes to `%APPDATA%` can be redirected into the app's private folder, so files you copy there never reach Stremio. `install.ps1` detects this and, only when given `-Yes`, runs itself again outside the sandbox through WMI. That outside run can't show prompts, so it installs missing tools and closes Stremio without asking: get the user's OK before passing `-Yes`. `restore.ps1` doesn't do this; if it reports a sandbox, ask the user to double-click `restore.cmd`.

Run the installer in the background, since the first run can take 20 minutes or more. Never print stream URLs, and check the result with `& .\tools\mpv-ipc.ps1` in your PowerShell session as described in AGENTS.md.
