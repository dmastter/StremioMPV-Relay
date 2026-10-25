-- original-tracks.lua
-- picks the original audio and full English subtitles embedded in the file.
-- works in the patched Stremio player and in standalone mpv.
--
-- some releases lie about subtitle languages (tracks tagged "eng" that are really czech, greek,
-- chinese...), so subtitles are verified by their actual text: the most likely candidate is shown
-- right away and checked as lines appear; if it fails, the rest are tested hidden, two at a time
-- (primary sid + secondary-sid), until one turns out to be real english.
--
-- stremio sends sid=no on load and later picks tracks its own way: for the first seconds any of
-- its changes are reverted. after that, manual changes are respected.
-- subtitle size stays under stremio's control; only its default solid colors get a softer opacity.
-- if the file has no english subtitles of its own, stremio is free to use addon subtitles.
--
-- options (script-opts/original-tracks.conf): sub_scale, sub_alpha, guard_seconds.
-- format: one key=value per line, no spaces around '=', comments on their own line, no BOM.

local msg = require "mp.msg"
local options = require "mp.options"

local opts = {
    sub_scale = 0,         -- force a subtitle size (mpv sub-scale); 0 = use stremio's size setting
    sub_alpha = 0.88,      -- opacity used instead of stremio's default solid colors (1 = leave them)
    guard_seconds = 30,    -- how long stremio's own track changes are reverted after load
}
options.read_options(opts, "original-tracks")
-- below ~0.2 the subtitles would be practically invisible
if opts.sub_alpha < 1 then opts.sub_alpha = math.max(0.2, opts.sub_alpha) end

local WAIT_PREFERRED = 15   -- max wait for a better-ranked candidate once another one is confirmed
local PROBE_LIMIT = 120     -- after this much played video (counted from the first line), finish with the best found
local SILENCE_SECONDS = 15  -- a candidate silent this long while the other slot talks goes to the back
local SILENCE_LONG = 45     -- ...and so does one silent this long once any line has been seen
local TEXT_COLOR = ("1.0/1.0/1.0/%.2f"):format(opts.sub_alpha)
local OUTLINE_COLOR = ("0.0/0.0/0.0/%.2f"):format(opts.sub_alpha)

-- image subtitles have no text, so they can't be verified
local BITMAP = { hdmv_pgs_subtitle = true, dvd_subtitle = true, dvb_subtitle = true, xsub = true }

-- very common words in english dialogue
local WORDS = {}
for w in ([[the you i to a and is it what that of in me we no yes okay ok this my your do don't are not be
have for on with he she they was just know right here there so all can get go oh hey well like if but how why
who where when come got gonna want did can't i'm it's you're that's there's let's up out about now think tell
him her them our us his an at as by from would will could should been were had has am going look see said
mean really one good sorry please thank thanks sir yeah uh um]]):gmatch("%S+") do WORDS[w] = true end

local function label(t)
    return ((t.title or "") .. " " .. (t.lang or "")):lower()
end

-- string.lower doesn't fold cyrillic, so variants are listed explicitly
local function contains(s, ...)
    for _, p in ipairs({ ... }) do if s:find(p, 1, true) then return true end end
    return false
end

local function is_english(t)
    local lang = (t.lang or ""):lower()
    if lang ~= "" and lang ~= "und" then return lang:match("^en") ~= nil end
    return label(t):find("english") ~= nil
end

local function no_language(t)
    local lang = (t.lang or ""):lower()
    return (lang == "" or lang == "und") and not label(t):find("english")
end

-- audio: flagged or titled "original" first, then english; never commentary.
-- if there is a single audio track, that one.
function pick_audio(tracks)
    local original, english, only, n = nil, nil, nil, 0
    for _, t in ipairs(tracks) do
        if t.type == "audio" and not t.external then
            n, only = n + 1, t
            local s = label(t)
            if not t.commentary and not s:find("comment") then
                if not original and (t.original or contains(s, "original", "оригинал", "Оригинал", "ОРИГИНАЛ")) then
                    original = t
                end
                if not english and is_english(t) then english = t end
            end
        end
    end
    return original or english or (n == 1 and only or nil)
end

-- english subtitle candidates, most likely first
function subtitle_candidates(tracks)
    local groups = { {}, {}, {}, {}, {} }
    for _, t in ipairs(tracks) do
        if t.type == "sub" and not t.external and not BITMAP[t.codec] then
            local s = label(t)
            local titled_forced = contains(s, "forced", "форс", "Форс", "ФОРС")
            local sdh = t["hearing-impaired"] or s:find("sdh") or s:find("hearing") or s:find("%f[%w]cc%f[%W]")
            if is_english(t) then
                if titled_forced then table.insert(groups[5], t)
                elseif t.forced then table.insert(groups[3], t)   -- the flag is sometimes wrong
                elseif sdh then table.insert(groups[2], t)
                else table.insert(groups[1], t) end
            elseif no_language(t) then
                table.insert(groups[4], t)
            end
        end
    end
    local list = {}
    for _, g in ipairs(groups) do for _, t in ipairs(g) do table.insert(list, t) end end
    return list
end

-- one line: word count, english word count and whether it has non-english letters
function analyze_line(line)
    -- drop style tags and cues like [music] or (sighs)
    line = line:gsub("{[^}]*}", ""):gsub("<[^>]*>", ""):gsub("%b[]", " "):gsub("%b()", " "):lower()
    -- typographic quotes, ellipsis, dashes and music notes don't count
    line = line:gsub("\226\128[\147\148\152\153\156\157\166]", " "):gsub("\226\153[\170\171]", " ")
    local ascii, other = 0, 0
    for _ in line:gmatch("%a") do ascii = ascii + 1 end
    -- only letters from other scripts (not symbols like ¶ « » or general punctuation)
    for _ in line:gmatch("[\195-\225\227-\237]") do other = other + 1 end
    local foreign = other >= 3 or (other >= 1 and other / (ascii + other) > 0.1)
    local total, english = 0, 0
    for w in line:gmatch("[%a']+") do
        total = total + 1
        if WORDS[w] then english = english + 1 end
    end
    return total, english, foreign
end

-- verdict after some lines: true english, false not english, nil not sure yet
function verdict(m)
    if m.foreign >= 2 and m.foreign * 2 > m.lines then return false end
    if m.lines >= 2 and m.words >= 8 and m.english == 0 then return false end
    if m.lines < 4 or m.words < 12 then return nil end
    return (m.english / m.words) >= 0.2 and m.foreign * 3 <= m.lines
end

local chosen_aid, chosen_sid
local guard_until, sid_guard_until = 0, 0
local candidates, next_idx = {}, 1
local slots = {}            -- "primary" and "secondary": {idx, id, m, v, ignore, since}
local probing = false
local wait_timer
local stremio_pick           -- last track stremio tried to select while probing (addon subtitle...)
local last_line             -- video position of the last line seen in any slot
local probe_start

local PROPERTY = { primary = "sid", secondary = "secondary-sid" }
local TEXT = { primary = "sub-text", secondary = "secondary-sub-text" }

local function position()
    return mp.get_property_number("time-pos")
end

local function kill_wait()
    if wait_timer then wait_timer:kill(); wait_timer = nil end
end

local function sid_guarded()
    local now = mp.get_time()
    return now < guard_until or now < sid_guard_until
end

local function assign(slot)
    local t = candidates[next_idx]
    if t then
        slots[slot] = { idx = next_idx, id = t.id, v = nil,
            m = { lines = 0, words = 0, english = 0, foreign = 0 },
            ignore = mp.get_property(TEXT[slot]) }
        next_idx = next_idx + 1
        msg.info(("testing subtitle track %d (%s %s) as %s"):format(t.id, t.lang or "?", t.title or "", slot))
        if slot == "primary" then chosen_sid = t.id end
        mp.set_property(PROPERTY[slot], tostring(t.id))
    else
        slots[slot] = nil
        if slot == "primary" then chosen_sid = false end
        mp.set_property(PROPERTY[slot], "no")
    end
end

-- id: chosen track; nil: nothing english, leave it to stremio and its addons
local function finish(id)
    probing = false
    slots = {}
    kill_wait()
    mp.set_property("secondary-sid", "no")
    mp.set_property_bool("sub-visibility", true)
    if id then
        msg.info(("subtitles: track %d confirmed as english"):format(id))
        chosen_sid = id
        sid_guard_until = mp.get_time() + 10
        mp.set_property_number("sid", id)
    else
        msg.info("no embedded track looks english: leaving it to stremio")
        chosen_sid = nil
        mp.set_property("sid", stremio_pick and tostring(stremio_pick) or "no")
        mp.add_timeout(1, function()
            mp.osd_message("This release has no English subtitles of its own", 6)
        end)
    end
end

local function best_confirmed()
    local best
    for _, r in pairs(slots) do
        if r.v == true and (not best or r.idx < best.idx) then best = r end
    end
    return best
end

local function evaluate()
    local p, s = slots.primary, slots.secondary
    if p and p.v == false then
        msg.info(("track %d rejected: not english"):format(p.id))
        mp.set_property_bool("sub-visibility", false)   -- the next ones are tested hidden
        assign("primary"); p = slots.primary
    end
    if s and s.v == false then
        msg.info(("track %d rejected: not english"):format(s.id))
        assign("secondary"); s = slots.secondary
    end
    local best = best_confirmed()
    if best then
        local other = (best == p) and s or p
        if other and other.v == nil and other.idx < best.idx then
            -- a better-ranked candidate is still undecided: give it some time, not forever
            if not wait_timer then
                wait_timer = mp.add_timeout(WAIT_PREFERRED, function()
                    wait_timer = nil
                    local b = best_confirmed()
                    if probing and b then finish(b.id) end
                end)
            end
            return
        end
        finish(best.id)
        return
    end
    if not p and not s then finish(nil) end
end

-- a candidate that stays silent while there is dialogue is sparse (signs) or starts late:
-- move it to the back of the queue so it doesn't block the others
local function requeue(slot)
    local r = slots[slot]
    if not candidates[next_idx] then return end
    msg.info(("track %d silent for now: moved to the back of the queue"):format(r.id))
    table.insert(candidates, candidates[r.idx])
    if slot == "primary" then mp.set_property_bool("sub-visibility", false) end
    assign(slot)
end

local probe_elapsed, prev_pos = 0, nil
local function check_silences()
    if not probing then return end
    local now = position()
    if not now then return end
    local d = prev_pos and now - prev_pos or 0
    prev_pos = now
    if last_line and d > 0 and d < 5 then probe_elapsed = probe_elapsed + d end
    if probe_elapsed > PROBE_LIMIT then
        local pick = best_confirmed()
        if not pick then for _, r in pairs(slots) do if not pick or r.idx < pick.idx then pick = r end end end
        finish(pick and pick.id)
        return
    end
    for _, name in ipairs({ "primary", "secondary" }) do
        local r = slots[name]
        if r and r.v == nil then
            r.since = r.since or now
            if now < r.since then r.since = now end   -- seeked backwards
            local quiet_from = r.last or r.since
            if now < quiet_from then quiet_from = now end
            -- only when the other slot keeps talking meanwhile: a real english track with a long pause
            -- between lines must not be pushed back just because nobody spoke for a while
            local other = slots[name == "primary" and "secondary" or "primary"]
            local dialogue = other and other.last and other.last > quiet_from
            -- and a track silent for much longer, once anything at all has been said, is sparse
            -- (signs, a stray line) and must not block the queue either
            local long_quiet = last_line and now - quiet_from >= SILENCE_LONG
            if (now - quiet_from >= SILENCE_SECONDS and dialogue) or long_quiet then
                requeue(name)
            end
        end
    end
end

local function record(slot, txt)
    local r = slots[slot]
    if not probing or not r or not txt or txt == "" or txt == r.ignore then return end
    r.ignore = nil
    -- after rewinding, the same lines come again: count each one once
    r.seen = r.seen or {}
    if r.seen[txt] then return end
    r.seen[txt] = true
    local total, english, foreign = analyze_line(txt)
    if total == 0 and not foreign then return end
    r.m.lines = r.m.lines + 1
    r.m.words = r.m.words + total
    r.m.english = r.m.english + english
    if foreign then r.m.foreign = r.m.foreign + 1 end
    r.v = verdict(r.m)
    last_line = position() or last_line
    r.last = last_line
    if r.v ~= nil then evaluate() end
end

mp.register_event("file-loaded", function()
    kill_wait()
    mp.set_property_bool("sub-visibility", true)
    mp.set_property_bool("secondary-sub-visibility", false)
    local tracks = mp.get_property_native("track-list", {})
    local audio = pick_audio(tracks)
    chosen_aid = audio and audio.id or nil
    guard_until, sid_guard_until = mp.get_time() + opts.guard_seconds, 0
    if chosen_aid then mp.set_property_number("aid", chosen_aid) end
    candidates, next_idx, slots = subtitle_candidates(tracks), 1, {}
    if not audio then
        mp.osd_message("This release has no original audio: pick another one", 8)
    end
    last_line, probe_start = nil, position()
    probe_elapsed, prev_pos, stremio_pick = 0, nil, nil
    if #candidates == 0 then
        -- no english of its own: drop default-flagged tracks; stremio may use addon subtitles
        chosen_sid = nil
        mp.set_property("sid", "no")
        msg.info("no embedded english subtitle candidates")
        return
    end
    probing = true
    assign("primary")
    assign("secondary")
end)

-- every 2 s: silent candidates to the back of the queue and probe time limit (in video time)
mp.add_periodic_timer(2, function()
    if probing and not probe_start then probe_start = position() end
    check_silences()
end)

mp.register_event("end-file", function()
    kill_wait()
    chosen_aid, chosen_sid, probing, slots, stremio_pick = nil, nil, false, {}, nil
    guard_until, sid_guard_until = 0, 0
end)

mp.observe_property("sub-text", "string", function(_, txt) record("primary", txt) end)
mp.observe_property("secondary-sub-text", "string", function(_, txt) record("secondary", txt) end)

mp.observe_property("aid", "native", function(_, value)
    if mp.get_time() < guard_until and chosen_aid and value ~= chosen_aid then
        mp.set_property_number("aid", chosen_aid)
    end
end)

local function is_candidate(id)
    for _, t in ipairs(candidates) do if t.id == id then return true end end
    return false
end

mp.observe_property("sid", "native", function(_, value)
    if chosen_sid == nil or value == nil or value == chosen_sid then return end
    if sid_guarded() then
        -- stremio changing tracks on load: revert
        if value and not is_candidate(value) then stremio_pick = value end
        mp.set_property(PROPERTY.primary, chosen_sid and tostring(chosen_sid) or "no")
    else
        -- manual change (including turning subtitles off): respect it and stop probing
        probing, slots, chosen_sid = false, {}, value
        kill_wait()
        mp.set_property("secondary-sid", "no")
        if value then mp.set_property_bool("sub-visibility", true) end
    end
end)

-- subtitle size is left to stremio's own setting (its 100% is sub-scale 0.66), unless sub_scale > 0.
if opts.sub_scale > 0 then
    mp.observe_property("sub-scale", "number", function(_, value)
        if value and math.abs(value - opts.sub_scale) > 0.001 then mp.set_property_number("sub-scale", opts.sub_scale) end
    end)
end

-- opacity: when stremio uses its default (solid) colors, soften them a bit;
-- any other color picked in stremio is respected.
local function soften_if_default(property, default, wanted)
    mp.observe_property(property, "string", function(_, value)
        if value and value:upper() == default then mp.set_property(property, wanted) end
    end)
end

if opts.sub_alpha > 0 and opts.sub_alpha < 1 then
    soften_if_default("sub-color", "#FFFFFFFF", TEXT_COLOR)
    -- stremio sets the sub-border-color alias, but change events only arrive under the real name
    soften_if_default("sub-outline-color", "#FF000000", OUTLINE_COLOR)
end
