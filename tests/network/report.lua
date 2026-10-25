-- prints how far playback got and why it ended
local pos, duration = 0, 0
mp.observe_property("time-pos", "number", function(_, v) if v then pos = v end end)
mp.observe_property("duration", "number", function(_, v) if v then duration = v end end)
mp.register_event("end-file", function(e)
    print(("RESULT pos=%.2f duration=%.2f reason=%s error=%s"):format(pos, duration, tostring(e.reason), tostring(e.error)))
end)
