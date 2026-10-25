-- test harness for original-tracks.lua (based on a reviewer's watch.lua).
-- logs property changes, plays a fake stremio from --script-opts=harness-acts=... and prints the
-- final state as json after harness-quit seconds.
--
-- acts: "seconds:property=value;..." counted from file-loaded. special properties:
--   !seek=150         absolute seek (stremio resuming playback)
--   !sub-add=f.srt    load an external subtitle and select it (stremio's addon subtitles);
--                     relative paths are taken from the folder of the playing file
--   !pause=yes|no
local utils = require "mp.utils"
local o = { quit = 30, acts = "" }
require("mp.options").read_options(o, "harness")

local t0 = mp.get_time()
local function log(...) print(("%7.2f"):format(mp.get_time() - t0), ...) end

local hides, last_sid_change = 0, nil
for _, p in ipairs({ "sid", "secondary-sid", "aid", "sub-visibility", "sub-scale", "sub-color", "sub-outline-color" }) do
    mp.observe_property(p, "native", function(name, v)
        log("EV", name, tostring(v))
        if name == "sub-visibility" and v == false then hides = hides + 1 end
        if name == "sid" then last_sid_change = mp.get_time() - t0 end
    end)
end

local function act(prop, val)
    log("ACT", prop, val)
    local ok, err
    if prop == "!sub-add" then
        local dir = utils.split_path(mp.get_property("path", ""))
        ok, err = mp.commandv("sub-add", utils.join_path(dir, val), "select", "addon", "eng")
    elseif prop == "!seek" then
        ok, err = mp.commandv("seek", val, "absolute")
    elseif prop == "!pause" then
        ok, err = mp.set_property("pause", val)
    else
        ok, err = mp.set_property(prop, val)
    end
    -- stremio's own changes can fail too (e.g. a track already selected as secondary)
    if not ok then log("ACT-FAILED", prop, val, tostring(err)) end
end

local loads = 0
mp.register_event("file-loaded", function()
    loads = loads + 1
    local tracks = {}
    for _, t in ipairs(mp.get_property_native("track-list", {})) do
        tracks[#tracks + 1] = { type = t.type, id = t.id, lang = t.lang, title = t.title,
            forced = t.forced, default = t.default, external = t.external }
    end
    print("TRACKS " .. utils.format_json(tracks))
    if loads > 1 then return end
    for t, prop, val in o.acts:gmatch("([%d%.]+):(!?[%w%-]+)=([^;]*)") do
        mp.add_timeout(tonumber(t), function() act(prop, val) end)
    end
end)

mp.add_timeout(o.quit, function()
    local final = {
        sid = mp.get_property("sid"),
        secondary_sid = mp.get_property("secondary-sid"),
        aid = mp.get_property("aid"),
        sub_visibility = mp.get_property("sub-visibility"),
        sub_scale = mp.get_property_number("sub-scale"),
        sub_color = mp.get_property("sub-color"),
        sub_outline_color = mp.get_property("sub-outline-color"),
        sub_external = mp.get_property_native("current-tracks/sub/external"),
        time_pos = mp.get_property_number("time-pos"),
        hides = hides,
        last_sid_change = last_sid_change,
    }
    print("FINAL " .. utils.format_json(final))
    mp.command("quit")
end)
