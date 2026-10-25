-- stream-watchdog.lua
-- opens a new connection when the current one is too slow to keep up with the video.
-- works in the patched Stremio player and in standalone mpv.
--
-- debrid cdns sometimes hand out a connection that keeps sending, only far below the video's
-- bitrate (a congested node or route). ffmpeg reconnects when nothing arrives for network-timeout
-- seconds, never when data arrives slowly, so playback stops to buffer every few seconds until the
-- server happens to close that connection. a new connection usually gets a fast path again.
--
-- when less than a second is buffered, or playback has been waiting for data (paused-for-cache) for
-- stall_seconds, or starts waiting again soon after the last wait, and data has been arriving at less
-- than 1.5 times the video's average bitrate (too little for its busier scenes), it seeks just past
-- the end of the cached data, which makes the demuxer send a new request on a new connection, and
-- then seeks back to where playback was, so nothing is skipped. if the new connections are too slow
-- as well, it says so on screen and stops trying for a while: then it's the server or the network,
-- and reconnecting doesn't help.
--
-- only remote streams that can seek are watched. local files, hls/dash and stremio's own streaming
-- server (torrents on 127.0.0.1) are left alone.
--
-- with relay.exe in ~~/relay (install.cmd builds it from tools\relay), remote http(s) links are
-- played through it instead: it runs on this pc only, downloads each range over several connections
-- at once and replaces a slow connection in the background, so the player never has to seek. the
-- seek trick above is then not needed and stays off. if the relay can't start, links play directly
-- with the seek trick; if it stops during playback, it's started again on the same port, which
-- ffmpeg's own reconnection finds. hls/dash playlists, links with credentials and links the player
-- must send extra headers to play directly, and so does a link that fails to open through the relay.
--
-- options (script-opts/stream-watchdog.conf, optional): stall_seconds, max_reconnects, allow_local,
-- relay (yes/no), relay_exe, relay_connections, relay_log.
-- format: one key=value per line, no spaces around '=', comments on their own line, no BOM.

local msg = require "mp.msg"
local options = require "mp.options"

local opts = {
    stall_seconds = 2,     -- waiting this long for data counts as a slow connection
    max_reconnects = 4,    -- at most this many new connections per 5 minutes
    allow_local = false,   -- also watch streams from this pc (only the tests need this)
    relay = true,          -- play remote links through relay.exe when it's there
    relay_exe = "~~/relay/relay.exe",
    relay_connections = 4, -- parallel connections per link
    relay_log = "~~/relay/relay.log",   -- sizes and speeds only, never links; empty = no log
}
options.read_options(opts, "stream-watchdog")

local GRACE = 8            -- after loading or a seek, the cache gets this long to fill
local RESTALL = 60         -- a new wait this soon after the previous one doesn't need stall_seconds
local WINDOW = 300         -- max_reconnects is counted over this many seconds
local CHECK_AFTER = 6      -- the new connection's speed is judged this long after it starts
local BUSY_LIMIT = 30      -- gives up on its own seeks if they haven't finished by then
local ENOUGH = 1.5         -- a connection this many times the average bitrate keeps up: waits come from elsewhere
local LOW_AHEAD = 1        -- with a slow connection, it doesn't wait for the stop once less than this is buffered
local LOCAL_HOSTS = { ["127.0.0.1"] = true, ["localhost"] = true, ["[::1]"] = true, ["::1"] = true }

local active = false
local settle_at = 0        -- last load or seek; nothing happens for GRACE seconds after it
local stall_since = nil    -- when the current wait for data started
local last_stall = -1e9    -- when the previous wait started
local reconnects = {}      -- times of the new connections made for this file
local slow_streak = 0      -- new connections in a row that were too slow as well
local paused_until = 0     -- after giving up, nothing happens until then
local own = nil            -- our seek in progress: { orig, phase, at }
local check_at = nil       -- when to judge the new connection's speed
local samples = {}         -- recent cache-speed readings: { t, bytes per second }
local relayed = false      -- the current file's link while it plays through the relay, else false
local relay = { running = false, port = nil, token = nil, restarts = 0 }

local function now() return mp.get_time() end

-- state for tools\diagnose.ps1 and agents, readable through the ipc pipe (no urls)
local function publish(key, value) mp.set_property_native("user-data/stream-watchdog/" .. key, value) end

local function host_of(url)
    local h = url:match("^%a[%w+.-]*://([^/?#]+)")
    if not h then return nil end
    h = h:gsub("^.*@", "")
    if h:sub(1, 1) == "[" then return h:match("^(%[.-%])") end
    return (h:gsub(":%d+$", ""))
end

-- ---------------------------------------------------------------------------- relay

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- base64url without padding: the link goes in the relay's path, so nothing in it needs escaping
local function b64url(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
        local len = c and 4 or (b and 3 or 2)
        for j = 1, len do out[#out + 1] = B64:sub(q[j] + 1, q[j] + 1) end
    end
    return table.concat(out)
end

local function expand(p) return mp.command_native({ "expand-path", p }) end

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

local ready_file = ((os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\stremiompv-relay-" ..
    tostring(mp.get_property_number("pid", 0)) .. ".json")

local function read_ready()
    local f = io.open(ready_file, "r")
    if not f then return nil end
    local txt = f:read("*a") or ""
    f:close()
    local port, token = tonumber(txt:match('"port"%s*:%s*(%d+)')), txt:match('"token"%s*:%s*"(%x+)"')
    if port and token then return port, token end
end

local function start_relay()
    os.remove(ready_file)
    local args = { expand(opts.relay_exe), "--ready-file", ready_file,
        "--parent-pid", tostring(mp.get_property_number("pid", 0)),
        "--connections", tostring(opts.relay_connections) }
    if opts.relay_log ~= "" then
        args[#args + 1] = "--log"
        args[#args + 1] = expand(opts.relay_log)
    end
    -- after a crash, the same port and token: the url ffmpeg reconnects to stays valid
    if relay.port then
        for _, a in ipairs({ "--port", tostring(relay.port), "--token", relay.token }) do args[#args + 1] = a end
    end
    relay.running = true
    local started = now()
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
        capture_stdout = false, capture_stderr = false }, function(_, res)
        relay.running = false
        local code = res and res.status or "?"
        -- it also exits normally after 5 idle minutes, e.g. once a whole episode is cached; only exits
        -- right after starting count as failures, so a long file can't use the restarts up
        local quick = now() - started < 30
        if relayed and (not quick or relay.restarts < 5) then
            if quick then relay.restarts = relay.restarts + 1 end
            msg.verbose(("the relay stopped (%s) during playback; starting it again"):format(tostring(code)))
            start_relay()
        else
            msg.verbose(("the relay stopped (%s)"):format(tostring(code)))
        end
    end)
end

-- links the relay can't carry: hls/dash (their segments are named relative to the playlist's own
-- url), credentials in the link, and extra headers the player was told to send
local function relayable(url)
    local path = (url:match("^[^?#]*") or url):lower()
    if path:match("%.m3u8?$") or path:match("%.mpd$") then return false, "segmented stream" end
    if url:match("^%a[%w+.-]*://[^/?#]*@") then return false, "credentials in the link" end
    for _, p in ipairs({ "http-header-fields", "referrer", "cookies-file" }) do
        local v = mp.get_property_native(p)
        if v and v ~= "" and not (type(v) == "table" and #v == 0) then return false, p .. " is set" end
    end
    return true
end

mp.add_hook("on_load", 50, function(hook)
    relayed = false
    publish("relay", "no")
    if not opts.relay then return end
    local url = mp.get_property("stream-open-filename", "")
    if not url:lower():match("^https?://") then return end
    local h = host_of(url)
    if not h or (LOCAL_HOSTS[h:lower()] and not opts.allow_local) then return end
    local ok, why = relayable(url)
    if not ok then
        publish("relay", "no: " .. why)
        return
    end
    if not file_exists(expand(opts.relay_exe)) then
        publish("relay", "no: relay.exe missing")
        return
    end
    hook:defer()
    -- a fresh start may take any free port: the old one may have been taken meanwhile
    if not relay.running then
        relay.port, relay.token = nil, nil
        start_relay()
    end
    local deadline = now() + 3
    local function poll()
        local port, token = read_ready()
        if port and relay.running then
            relay.port, relay.token = port, token
            mp.set_property("stream-open-filename", ("http://127.0.0.1:%d/%s/%s"):format(port, token, b64url(url)))
            relayed = url
            publish("relay", "yes")
            msg.info("playing through the relay")
            hook:cont()
        elseif now() > deadline or not relay.running then
            msg.warn("the relay didn't start: playing the link directly")
            publish("relay", "no: didn't start")
            hook:cont()
        else
            mp.add_timeout(0.05, poll)
        end
    end
    poll()
end)

-- the link failed through the relay (a server that wants something the relay doesn't send): once more,
-- directly. lavf:// makes mpv see a different name, which it needs before it opens the file again
mp.add_hook("on_load_fail", 50, function()
    if not relayed then return end
    local url = relayed
    relayed = false
    msg.warn("the link failed through the relay; playing it directly")
    publish("relay", "no: failed through the relay")
    mp.set_property("stream-open-filename", "lavf://" .. url)
end)

-- a standalone mpv ends the relay itself at exit, before it can delete its ready file
mp.register_event("shutdown", function() os.remove(ready_file) end)

-- ---------------------------------------------------------------------------- watchdog

local function watchable()
    if relayed then return false, "plays through the relay" end
    if not mp.get_property_bool("demuxer-via-network", false) then return false, "not a network stream" end
    if not mp.get_property_bool("seekable", false) then return false, "not seekable" end
    local fmt = (mp.get_property("file-format") or ""):lower()
    if fmt:find("hls", 1, true) or fmt:find("dash", 1, true) then return false, "segmented stream" end
    local h = host_of(mp.get_property("path") or "")
    if not h then return false, "no host" end
    if LOCAL_HOSTS[h:lower()] and not opts.allow_local then return false, "local server" end
    return true
end

-- bytes per second the video needs on average at the current speed
local function needed_rate()
    local size = mp.get_property_number("file-size")
    local dur = mp.get_property_number("duration")
    if not size or not dur or dur <= 0 then return nil end
    return size / dur * mp.get_property_number("speed", 1)
end

local function avg_speed(seconds)
    local t0, sum, n = now() - seconds, 0, 0
    for _, s in ipairs(samples) do
        if s[1] >= t0 then sum, n = sum + s[2], n + 1 end
    end
    return n > 0 and sum / n or nil
end

local function mbs(v) return ("%.2f MB/s"):format((v or 0) / 1048576) end

local function recent_reconnects()
    local t0, n = now() - WINDOW, 0
    for _, t in ipairs(reconnects) do if t >= t0 then n = n + 1 end end
    return n
end

local function give_up(speed, need)
    paused_until = now() + WINDOW
    publish("gave-up", true)
    slow_streak = 0
    msg.warn(("reconnecting doesn't help (%s, the video needs %s); not reconnecting for %d s")
        :format(mbs(speed), mbs(need), WINDOW))
    -- faster than needed on average means bitrate peaks, not a slow server: nothing to tell
    if speed and need and speed < need then
        mp.osd_message(("The server sends %s and this video needs %s: it's the server or the network, not the player")
            :format(mbs(speed), mbs(need)), 8)
    end
end

local function reconnect()
    local pos = mp.get_property_number("time-pos")
    local st = mp.get_property_native("demuxer-cache-state")
    if not pos or not st or st.eof then return end
    local target = math.max(st["cache-end"] or pos, pos) + 0.05
    local dur = mp.get_property_number("duration")
    if dur and target > dur - 1 then return end   -- nearly everything is read already
    reconnects[#reconnects + 1] = now()
    publish("reconnects", #reconnects)
    own = { orig = pos, target = target, phase = "ahead", at = now() }
    msg.info(("slow connection (%s, the video needs %s): reconnecting")
        :format(mbs(avg_speed(5)), mbs(needed_rate())))
    -- past the cached data: the demuxer has to make a new request
    mp.commandv("seek", ("%.3f"):format(target), "absolute+exact")
end

local function judge()
    check_at = nil
    local need = needed_rate()
    -- an idle cache is full: the connection keeps up
    if mp.get_property_bool("demuxer-cache-idle", false) or not need then slow_streak = 0 return end
    local speed = avg_speed(4)
    if speed and speed < need * ENOUGH then
        slow_streak = slow_streak + 1
        msg.info(("the new connection is slow too (%s)"):format(mbs(speed)))
        if slow_streak >= 2 then give_up(speed, need) end
    else
        slow_streak = 0
    end
end

local function tick()
    local t = now()
    samples[#samples + 1] = { t, mp.get_property_number("cache-speed", 0) }
    while #samples > 0 and samples[1][1] < t - 10 do table.remove(samples, 1) end
    if not active then return end
    if own then
        if t - own.at > BUSY_LIMIT then own = nil; settle_at = t end
        return
    end
    if check_at and t >= check_at then judge() end
    if t < paused_until or t - settle_at < GRACE then return end
    if mp.get_property_bool("pause", false) or mp.get_property_bool("seeking", false) then return end
    local st = mp.get_property_native("demuxer-cache-state")
    if not st or st.eof then return end   -- everything is read already
    if stall_since then
        local waited = t - stall_since
        if waited < opts.stall_seconds and stall_since - last_stall > RESTALL then return end
    elseif mp.get_property_number("demuxer-cache-duration", 1e9) >= LOW_AHEAD then
        return
    end
    -- a fast connection that still runs dry isn't the problem (or the bitrate is unknown: live)
    local speed, need = avg_speed(5), needed_rate()
    if not speed or not need or speed >= need * ENOUGH then return end
    if recent_reconnects() >= opts.max_reconnects then
        give_up(speed, need)
        return
    end
    reconnect()
end

local function start()
    local ok, why = watchable()
    active = ok
    settle_at, stall_since, last_stall = now(), nil, -1e9
    reconnects, slow_streak, paused_until, own, check_at = {}, 0, 0, nil, nil
    if not ok then msg.verbose("not watching: " .. why) end
    publish("watching", ok and "yes" or ("no: " .. why))
    publish("reconnects", 0)
    publish("gave-up", false)
end

mp.register_event("file-loaded", start)

mp.register_event("end-file", function()
    active, own, check_at, stall_since, relayed = false, nil, nil, nil, false
    relay.restarts = 0
end)

mp.register_event("seek", function()
    if not own then settle_at = now() end
end)

mp.register_event("playback-restart", function()
    local t = now()
    if not own then settle_at = t return end
    if own.phase == "ahead" then
        -- landed somewhere else: the user (or stremio) seeked meanwhile, and that seek wins
        local p = mp.get_property_number("time-pos")
        if p and math.abs(p - own.target) > 1 then
            own, settle_at = nil, t
            return
        end
        -- the new connection is open; go back to where playback was (normally still cached)
        own.phase = "back"
        msg.verbose(("new connection open at %.2f; back to %.2f"):format(mp.get_property_number("time-pos", -1), own.orig))
        mp.commandv("seek", ("%.3f"):format(own.orig), "absolute+exact")
    else
        msg.verbose(("resumed at %.2f"):format(mp.get_property_number("time-pos", -1)))
        own, settle_at, check_at = nil, t, t + CHECK_AFTER
        stall_since = nil
    end
end)

mp.observe_property("paused-for-cache", "bool", function(_, waiting)
    if waiting then
        if stall_since then return end
        stall_since = now()
    elseif stall_since then
        last_stall, stall_since = stall_since, nil
    end
end)

mp.add_periodic_timer(0.5, tick)

-- loaded while a file is already playing (load-script through the ipc pipe): watch it right away
if mp.get_property("path") and not mp.get_property_bool("idle-active", true) then start() end
