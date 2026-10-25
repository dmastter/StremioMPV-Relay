-- stremio-autopatch.lua
-- when the patched player starts with stremio, starts tools\autopatch.ps1 -WaitPid <stremio's pid>
-- from the repo folder install.cmd ran from (its path is in ~~/autopatch-path.txt). that sleeps until
-- stremio's process ends, however it ends: quit from the tray icon, an update ("install now" runs
-- the installer and exits), a crash. then it waits for stremio's updater, puts the patch back if an
-- update replaced it, and exits. so it lives exactly as long as stremio does.
--
-- this can't wait for mpv's shutdown event instead: stremio ends its process without shutting the
-- player down, so scripts never see it.
--
-- install.cmd writes ~~/autopatch-path.txt only when the automatic re-patching was accepted, and
-- restore.cmd deletes it; without it this script does nothing. a standalone mpv reads its own config
-- folder, so it never finds the file. a second copy started for the same stremio exits at once.

local msg = require "mp.msg"

local function autopatch_path()
    local f = io.open(mp.command_native({ "expand-path", "~~/autopatch-path.txt" }), "r")
    if not f then return nil end
    -- a utf-8 bom, if an editor added one, isn't part of the path
    local p = (f:read("*l") or ""):gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
    f:close()
    if p == "" then return nil end
    local s = io.open(p, "r")
    if not s then return nil end
    s:close()
    return p
end

local script = autopatch_path()
if script then
    local ps = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    -- detached: it outlives the player, has no console window and sleeps until stremio's pid exits
    mp.command_native({ name = "subprocess", detach = true, playback_only = false,
        args = { ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", script, "-WaitPid", tostring(mp.get_property_number("pid", 0)) } })
    msg.verbose("started the re-patch check that runs when stremio ends")
end
