-- Debug only, not for release. /mappace times every frame while the world
-- map (with the quest log) opens and closes 3 times in 20 seconds, to find what
-- makes it hitch. For each frame: its length, the time all addons and each
-- loaded addon spent in it (C_AddOnProfiler) and memory made. Prints a summary
-- per open and close, and keeps
-- the last runs in DevMapPaceDB.mapPace, which the game saves on /reload.
--   /mappace          opens and closes the map itself (out of combat)
--   /mappace manual   you press M: open/close it 3 times in the 20 seconds
--   /mappace deep     automatic, and also times the game's own map steps
--                         (each map data provider, overlay and the game's quest
--                         list), to see where the game's part of the hitch goes.
--                         Runs twice in a row: with the game's quest pins on,
--                         then with them off (the questPOI setting, put back
--                         after, or at the next login if a reload cut the run
--                         short)
--   /mappace clear    empties the saved runs
-- The automatic run closes the map from addon code, and deep puts timers on the
-- game's map: every run ends asking for a /reload (see reloadSoon), which writes
-- the results and clears the taint.

-- A vanilla addon: it uses only the game, never another addon. Its own events,
-- slash command (/mappace) and saved variables (DevMapPaceDB).
local events, handlers = CreateFrame("Frame"), {}
events:SetScript("OnEvent", function(_, event, ...)
    for _, handler in ipairs(handlers[event]) do handler(event, ...) end
end)
local function onEvent(event, handler)
    if not handlers[event] then handlers[event] = {}; events:RegisterEvent(event) end
    table.insert(handlers[event], handler)
end
-- Runs fn now, or once the fight is over.
local function afterCombat(action)
    if not InCombatLockdown() then return action() end
    local done = false
    onEvent("PLAYER_REGEN_ENABLED", function() if not done then done = true; action() end end)
end
local function store()
    _G.DevMapPaceDB = type(_G.DevMapPaceDB) == "table" and _G.DevMapPaceDB or {}
    return _G.DevMapPaceDB
end
local function command(handler)
    _G["SLASH_DEVMAPPACE1"] = "/mappace"
    SlashCmdList["DEVMAPPACE"] = function(message) handler(message or "") end
end

local Pace = {
    LENGTH = 20,          -- seconds per run
    -- seconds into the run: open, close, open, close, open, close
    STEPS = { 1, 4, 7.5, 10.5, 14, 17 },
    AFTER = 1,            -- seconds after an open or close that count towards it
    HITCH = 25,           -- ms: frames longer than this are kept in full
    RUNS = 5,             -- runs kept in the saved variables
    MAX_HITCHES = 60,     -- frames kept in full per run
}

local frame = CreateFrame("Frame")
frame:Hide()
Pace.frame = frame
local run              -- the run in progress
local spent = {}       -- "what" -> ms this frame, from the timed functions
local calls = {}       -- "what" -> times called this frame
local stacks = {}      -- "what" -> { [stack] = times }, for the functions asked to (deep)
local undo = {}        -- functions to put back when the run ends

local function report(text) print("mappace: " .. text) end

-- The end of the runs: a reload writes the results to disk and clears the map's
-- taint. Addon code can't call ReloadUI on this client, so it asks for /reload.
local function reloadSoon()
    report("saved: /reload to write the results (and clear the map's taint)")
end

local function mapPaceData()
    local root = store()
    root.mapPace = root.mapPace or { runs = {} }
    root.mapPace.runs = root.mapPace.runs or {}
    return root.mapPace
end

local function now() return debugprofilestop() end

local function mapShown()
    local worldMap = _G.WorldMapFrame
    return type(worldMap) == "table" and worldMap:IsShown() == true
end

-- Timing a function: t[key] is replaced by a timed copy until the run ends, then
-- set back to what t itself held (nil for a method it got from its mixin).
-- Errors pass through as they were; a nested call counts twice, fine here.
local function wrap(owner, key, label, keepStack)
    if type(owner) ~= "table" then return end
    local okGet, original = pcall(function() return owner[key] end)
    if not okGet or type(original) ~= "function" then return end
    local raw = rawget(owner, key)
    local function finish(startedAt, ok, ...)
        spent[label] = (spent[label] or 0) + (now() - startedAt)
        if not ok then error((...), 0) end
        return ...
    end
    local function timed(...)
        calls[label] = (calls[label] or 0) + 1
        if keepStack and debugstack then
            local callerCounts = stacks[label] or {}
            stacks[label] = callerCounts
            local trace = debugstack(2, 14, 0) or "?"
            callerCounts[trace] = (callerCounts[trace] or 0) + 1
        end
        return finish(now(), pcall(original, ...))
    end
    owner[key] = timed
    undo[#undo + 1] = function() if rawget(owner, key) == timed then owner[key] = raw end end
end

-- The game's mixin a map piece was made from, by its methods: "QuestDataProvider".
local mixinOf
local function mixinName(piece, key)
    if not mixinOf then
        mixinOf = {}
        for name, globalValue in pairs(_G) do
            if type(name) == "string" and name:find("Mixin$") and type(globalValue) == "table" then
                pcall(function() for field, method in pairs(globalValue) do
                    if type(method) == "function" then
                        local byKey = mixinOf[field] or {}
                        mixinOf[field] = byKey
                        -- the most specific mixin wins over a base one sharing the function
                        local had = byKey[method]
                        if not had or (had:find("^MapCanvas") and not name:find("^MapCanvas")) then byKey[method] = name end
                    end
                end end)
            end
        end
    end
    local method = piece[key]
    local name = mixinOf[key] and mixinOf[key][method]
    if name then return (name:gsub("Mixin$", "")) end
    local okName, frameName = pcall(function() return piece.GetName and piece:GetName() end)
    return okName and type(frameName) == "string" and frameName or tostring(piece):gsub("^table: ", "")
end

-- The game's own map steps, for /mappace deep.
local function wrapGame()
    local worldMap = _G.WorldMapFrame
    if type(worldMap) ~= "table" then return end
    for _, method in ipairs({ "OnShow", "OnHide", "OnMapChanged", "RefreshAll", "RefreshAllDataProviders", "RefreshOverlayFrames",
                         "RefreshDetailLayers", "SynchronizeDisplayState", "UpdateMaximizedSize", "UpdateSpacerFrameAnchoring" }) do
        wrap(worldMap, method, "map." .. method)
    end
    local providers = {}
    if type(worldMap.dataProviders) == "table" then
        for provider in pairs(worldMap.dataProviders) do providers[#providers + 1] = provider end
    end
    for _, provider in ipairs(providers) do
        if type(provider) == "table" then
            local name = mixinName(provider, "RefreshAllData")   -- before its methods are timed
            for _, method in ipairs({ "RefreshAllData", "OnShow", "OnHide", "OnMapChanged", "RemoveAllData" }) do
                if type(provider[method]) == "function" then wrap(provider, method, "provider." .. name .. "." .. method) end
            end
        end
    end
    -- who rebuilds the game's quest list, and how often
    wrap(worldMap, "RemoveAllPinsByTemplate", "map.RemoveAllPinsByTemplate")
    wrap(worldMap, "AcquirePin", "map.AcquirePin")
    for _, overlay in ipairs(type(worldMap.overlayFrames) == "table" and worldMap.overlayFrames or {}) do
        if type(overlay) == "table" and type(overlay.Refresh) == "function" then wrap(overlay, "Refresh", "overlay." .. mixinName(overlay, "Refresh") .. ".Refresh") end
    end
    for _, functionName in ipairs({ "QuestLogQuests_Update", "QuestMapFrame_UpdateAll", "QuestMapFrame_ShowQuestDetails",
                         "QuestMapFrame_OnShow", "QuestMapFrame_OnHide", "QuestMapFrame_UpdateQuestSessionState" }) do
        wrap(_G, functionName, "questlog." .. functionName, functionName == "QuestLogQuests_Update")
    end
    local questMapFrame = _G.QuestMapFrame
    if type(questMapFrame) == "table" then
        for _, method in ipairs({ "OnShow", "OnHide", "SetDisplayMode", "ValidateTabs", "UpdateQuestSessionState", "RefreshTabs" }) do
            wrap(questMapFrame, method, "questlog.QuestMapFrame." .. method)
        end
    end
    report(string.format("timing %d map providers, %d overlays", #providers, type(worldMap.overlayFrames) == "table" and #worldMap.overlayFrames or 0))
end


-- Nothing of another addon is timed: deep times the game's own map steps (wrapGame).
local function wrapAll() end

local function unwrapAll()
    for i = #undo, 1, -1 do undo[i]() end
    undo = {}
end

-- Every loaded addon, for the profiler.
local function addonNames()
    local out = {}
    local addonCount = C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns() or 0
    for i = 1, addonCount do
        local name = C_AddOns.GetAddOnInfo(i)
        if type(name) == "string" and (not C_AddOns.IsAddOnLoaded or C_AddOns.IsAddOnLoaded(name)) then out[#out + 1] = name end
    end
    return out
end

local function profiler()
    local profilerApi, metricEnum = _G.C_AddOnProfiler, Enum and Enum.AddOnProfilerMetric
    if not (profilerApi and metricEnum and profilerApi.GetAddOnMetric and metricEnum.LastTime) then return nil end
    if profilerApi.IsEnabled and not profilerApi.IsEnabled() then return nil end
    return profilerApi, metricEnum.LastTime
end

-- Everything known about the frame that just ended.
local function sample(frameMs)
    local current = run
    local frameSample = { t = (now() - current.start) / 1000, dt = frameMs, map = mapShown() }
    local profilerApi, metric = profiler()
    if profilerApi then
        local ok, overall = pcall(profilerApi.GetOverallMetric, metric)
        frameSample.addons = ok and type(overall) == "number" and overall or nil
        local listed, perAddon = 0, {}
        for _, name in ipairs(current.addons) do
            local addonOk, addonMs = pcall(profilerApi.GetAddOnMetric, name, metric)
            if addonOk and type(addonMs) == "number" and addonMs > 0 then
                listed = listed + addonMs
                perAddon[name] = addonMs
            end
        end
        frameSample.listed, frameSample.per = listed, perAddon
    end
    local memoryKB = collectgarbage("count")
    frameSample.kb = memoryKB - current.kb
    current.kb = memoryKB
    if next(spent) then
        frameSample.spent = spent
        spent = {}
    end
    if next(calls) then
        frameSample.calls = calls
        calls = {}
    end
    return frameSample
end

-- The whole open or close call, the game's part included.
local function act(i)
    if InCombatLockdown() then return end
    local startedAt = now()
    if i % 2 == 1 then
        if C_Map and C_Map.OpenWorldMap then pcall(C_Map.OpenWorldMap) end
        spent["call.open"] = (spent["call.open"] or 0) + (now() - startedAt)
    elseif mapShown() then
        if type(HideUIPanel) == "function" then pcall(HideUIPanel, _G.WorldMapFrame)
        else pcall(_G.WorldMapFrame.Hide, _G.WorldMapFrame) end
        spent["call.close"] = (spent["call.close"] or 0) + (now() - startedAt)
    end
end

local function formatMs(value) return value and string.format("%.1f", value) or "-" end

local function topSpent(list, count)
    local sum = {}
    for _, frameSample in ipairs(list) do
        for what, milliseconds in pairs(frameSample.spent or {}) do sum[what] = (sum[what] or 0) + milliseconds end
    end
    local keys = {}
    for key in pairs(sum) do keys[#keys + 1] = key end
    table.sort(keys, function(first, second) return sum[first] > sum[second] end)
    local parts = {}
    for i = 1, math.min(count, #keys) do parts[i] = string.format("%s %.1f", keys[i], sum[keys[i]]) end
    return table.concat(parts, ", ")
end

-- Deep: how often the game's quest list and pins were rebuilt.
local function topCalls(list)
    local sum = {}
    for _, frameSample in ipairs(list) do
        for what, count in pairs(frameSample.calls or {}) do sum[what] = (sum[what] or 0) + count end
    end
    local parts = {}
    for _, key in ipairs({ "questlog.QuestLogQuests_Update", "map.RemoveAllPinsByTemplate", "map.AcquirePin",
                         "provider.QuestDataProvider.RefreshAllData", "map.RefreshAllDataProviders" }) do
        if sum[key] then parts[#parts + 1] = string.format("%s x%d", key:gsub("^%w+%.", ""), sum[key]) end
    end
    return table.concat(parts, ", ")
end

-- A summary of the frames from an open or close up to Pace.AFTER seconds later.
local function window(finishedRun, mark)
    local list = {}
    for _, frameSample in ipairs(finishedRun.frames) do
        if frameSample.t >= mark.t and frameSample.t < mark.t + Pace.AFTER then list[#list + 1] = frameSample end
    end
    local worst, total, addons, listed, memoryKB = nil, 0, 0, 0, 0
    for _, frameSample in ipairs(list) do
        if not worst or frameSample.dt > worst.dt then worst = frameSample end
        total = total + frameSample.dt
        addons = addons + (frameSample.addons or 0)
        listed = listed + (frameSample.listed or 0)
        memoryKB = memoryKB + math.max(0, frameSample.kb or 0)
    end
    return {
        what = mark.what, t = mark.t, frames = #list,
        worst = worst and worst.dt, worstAddons = worst and worst.addons, worstListed = worst and worst.listed,
        addons = addons, listed = listed, kb = memoryKB, top = topSpent(list, finishedRun.mode == "deep" and 10 or 5),
        calls = finishedRun.mode == "deep" and topCalls(list) or nil,
    }
end

local function percentile(sorted, share)
    if #sorted == 0 then return nil end
    return sorted[math.max(1, math.ceil(#sorted * share))]
end

local function finish()
    local finishedRun = run
    run = nil
    frame:Hide()
    unwrapAll()
    local frameTimes = {}
    for i, frameSample in ipairs(finishedRun.frames) do frameTimes[i] = frameSample.dt end
    table.sort(frameTimes)
    local out = {
        when = date("%Y-%m-%d %H:%M:%S"), mode = finishedRun.mode, label = finishedRun.label, frames = #finishedRun.frames,
        median = percentile(frameTimes, 0.5), p95 = percentile(frameTimes, 0.95), p99 = percentile(frameTimes, 0.99),
        max = frameTimes[#frameTimes], over33 = 0, over50 = 0, profiler = profiler() ~= nil,
        steps = {}, hitches = {}, dt = {}, stacks = {},
    }
    for _, frameTime in ipairs(frameTimes) do
        if frameTime > 33.4 then out.over33 = out.over33 + 1 end
        if frameTime > 50 then out.over50 = out.over50 + 1 end
    end
    report(string.format("%d frames, median %sms, p95 %sms, p99 %sms, worst %sms, >33ms %d, >50ms %d%s",
        out.frames, formatMs(out.median), formatMs(out.p95), formatMs(out.p99), formatMs(out.max), out.over33, out.over50,
        out.profiler and "" or " (addon profiler off: no addon times)"))
    for _, mark in ipairs(finishedRun.marks) do
        local summary = window(finishedRun, mark)
        out.steps[#out.steps + 1] = summary
        if summary.calls and summary.calls ~= "" then report(summary.what .. " calls: " .. summary.calls) end
        report(string.format("%s at %.1fs: worst frame %sms (all addons %s, each summed %s), next %ds: all addons %sms, each summed %sms, %d KB made%s",
            summary.what, summary.t, formatMs(summary.worst), formatMs(summary.worstAddons), formatMs(summary.worstListed), Pace.AFTER, formatMs(summary.addons), formatMs(summary.listed),
            math.floor(summary.kb), summary.top ~= "" and (" | " .. summary.top) or ""))
    end
    -- the worst frames in full, and every frame's length in short
    local byLength = {}
    for _, frameSample in ipairs(finishedRun.frames) do if frameSample.dt > Pace.HITCH then byLength[#byLength + 1] = frameSample end end
    table.sort(byLength, function(first, second) return first.dt > second.dt end)
    for i = 1, math.min(Pace.MAX_HITCHES, #byLength) do out.hitches[i] = byLength[i] end
    table.sort(out.hitches, function(first, second) return first.t < second.t end)
    local parts = {}
    for i, frameSample in ipairs(finishedRun.frames) do parts[i] = string.format("%.1f", frameSample.dt) end
    out.dt = table.concat(parts, ",")
    -- the callers, most frequent first
    for label, callerCounts in pairs(stacks) do
        local list = {}
        for trace, count in pairs(callerCounts) do list[#list + 1] = { n = count, trace = trace } end
        table.sort(list, function(first, second) return first.n > second.n end)
        local keep = {}
        for i = 1, math.min(6, #list) do keep[i] = list[i] end
        out.stacks[label] = keep
    end
    stacks = {}
    local data = mapPaceData()
    if data then
        table.insert(data.runs, 1, out)
        while #data.runs > Pace.RUNS do table.remove(data.runs) end
        if not finishedRun.after then
            reloadSoon()
        end
    end
    if finishedRun.after then finishedRun.after() end
end

frame:SetScript("OnUpdate", function()
    local current = run
    if not current then frame:Hide(); return end
    local nowMs = now()
    local frameMs = nowMs - current.last
    current.last = nowMs
    current.frames[#current.frames + 1] = sample(frameMs)
    local elapsed = (nowMs - current.start) / 1000
    if current.auto then
        local nextStep = Pace.STEPS[current.step + 1]
        if nextStep and elapsed >= nextStep then
            current.step = current.step + 1
            act(current.step)
        end
    end
    local shown = mapShown()
    if shown ~= current.shown then
        current.shown = shown
        current.marks[#current.marks + 1] = { what = shown and "open" or "close", t = elapsed }
    end
    if elapsed >= Pace.LENGTH then finish() end
end)

function Pace.Start(mode, label, after)
    if run then report("already running"); return end
    local auto = mode ~= "manual"
    if auto and InCombatLockdown() then report("not in combat"); return end
    if auto and mapShown() then
        report("close the map first")
        return
    end
    wrapAll()
    if mode == "deep" then wrapGame() end
    local nowMs = now()
    run = { mode = mode, auto = auto, label = label, after = after, start = nowMs, last = nowMs, step = 0, frames = {}, marks = {}, shown = mapShown(),
            kb = collectgarbage("count"), addons = addonNames() }
    spent, calls, stacks = {}, {}, {}
    frame:Show()
    if not profiler() then report("the game's addon profiler is off: frame times only") end
    report(auto and string.format("running %ds%s, the map opens and closes 3 times", Pace.LENGTH, label and (" (" .. label .. ")") or "")
        or string.format("running %ds: open and close the map (M) 3 times", Pace.LENGTH))
    return true
end

-- Deep's second run: the game's quest pins off, put back afterwards.
local function poiBack()
    local data = mapPaceData()
    if data and data.poiWas ~= nil then
        if InCombatLockdown() then
            afterCombat(poiBack)
            return
        end
        if type(SetCVar) == "function" then pcall(SetCVar, "questPOI", data.poiWas) end
        report("the game's quest pins are back (questPOI " .. tostring(data.poiWas) .. ")")
        data.poiWas = nil
    end
end

local function secondRun()
    if InCombatLockdown() then report("combat: second run skipped"); return end
    local data = mapPaceData()
    local was = type(GetCVar) == "function" and GetCVar("questPOI") or nil
    if data and was ~= nil then data.poiWas = was end
    if type(SetCVar) == "function" then pcall(SetCVar, "questPOI", "0") end
    local started = Pace.Start("deep", "quest pins off", function()
        poiBack()
        reloadSoon()
    end)
    if not started then poiBack() end
end

-- The second run starts as soon as the first ends: its first open is a second in.
function Pace.Deep()
    if run then report("already running"); return end
    Pace.Start("deep", "quest pins on", function()
        report("first run done, the second turns the game's quest pins off")
        secondRun()
    end)
end

onEvent("PLAYER_REGEN_DISABLED", function()
    if run and run.auto then
        run.after = function() poiBack(); reloadSoon() end
        report("combat: stopped")
        finish()
    end
end)

-- A reload during the second run left the pins off.
onEvent("PLAYER_LOGIN", function() C_Timer.After(1, poiBack) end)

function Pace.Run(rest)
    rest = rest or ""
    if rest == "clear" then
        local data = mapPaceData()
        if data then data.runs = {} end
        report("saved runs cleared")
    elseif rest == "manual" then
        Pace.Start("manual")
    elseif rest == "deep" then
        Pace.Deep()
    else
        Pace.Start("auto")
    end
end

command(Pace.Run)
