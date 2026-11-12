-------------------------------------------------------------------------------
--  SatchelTracker  -  Core.lua
--  Standalone tracker for the WoW Forever trinket "Satchel of Potions"
--  (Item ID: 280766, On-Use Spell ID: 1309685).
--
--  Tracks the 4 random immediate outcomes:
--    1. Health (Greater Healing Potion effect)
--    2. Mana   (Mana Potion effect)
--    3. Speed  (Swiftness Potion movement speed buff, Spell ID: 1309728)
--    4. Damage (Self-inflicted ~216 Fire damage backfire + Crit tracking)
--
--  Features:
--    - Persistent Overall tracking across all sessions
--    - Current Session tracking that survives /reload and resets only on
--      a fresh login (after logout) or manual reset
--    - Roll History log (tracks the exact order of recent procs)
--    - Full Tabbed View (Overall / Session / History) & Compact Mode
--      (Horizontal or Vertical icon + number strip)
-------------------------------------------------------------------------------
local ADDON, ns = ...

ns.SATCHEL_ITEM_ID    = 280766
ns.SATCHEL_SPELL_ID   = 1309685
ns.SATCHEL_SPEED_BUFF = 1309728
ns.MAX_HISTORY        = 100

ns.OUTCOME_KEYS = { "health", "mana", "speed", "damage" }

ns.DEFAULTS = {
    locked           = false,
    onlyWhenEquipped = true,
    manualShow       = nil,          -- nil = follow equipment; true/false = override
    activeTab        = "overall",    -- "overall" | "session" | "history"
    compact          = false,        -- true = compact icon+number mode
    compactLayout    = "horizontal", -- "horizontal" | "vertical"
    pos              = { point = "CENTER", relPoint = "CENTER", x = 280, y = 0 },
    minimap          = { hide = false, angle = 205 },
    overall          = {
        health     = 0,
        mana       = 0,
        speed      = 0,
        damage     = 0,
        damageCrit = 0,
    },
    session          = {
        health     = 0,
        mana       = 0,
        speed      = 0,
        damage     = 0,
        damageCrit = 0,
    },
    history          = {},           -- newest first: { outcome, isCrit, timestamp }
    learnedSpells    = {},           -- child spellID -> outcome key
    debugMode        = false,        -- persists across /reload, resets to false on fresh login
    debugLog         = {},           -- saved event traces around Satchel activations while debugMode is ON
}

local issecret = issecretvalue or function() return false end
local MAX_DEBUG_TRACES = 25
local activeTrace = nil
local preEventBuffer = {} -- ring buffer of recent events while debugMode is ON

-------------------------------------------------------------------------------
--  Known child spell IDs for the 4 effects
--  Confirmed from in-game debugLog:
--    1309685 = Satchel of Potions (parent cast)
--    1309725 = Healing Potion (child cast, fires between SENT and SUCCEEDED)
--    1309726 = Mana Potion (child cast candidate)
--    1309727 = Mana Potion (child cast candidate)
--    1309728 = Speed (child cast & buff, fires between SENT and SUCCEEDED)
-------------------------------------------------------------------------------
local KNOWN_SPELLS = {
    -- Speed (Satchel of Potions Speed buff & classic Swiftness Potion)
    [1309728] = "speed",
    [2379]    = "speed",
    -- Health (Satchel of Potions Healing Potion & classic healing potion effects)
    [1309725] = "health",
    [2024]    = "health",
    [439]     = "health",
    [440]     = "health",
    [441]     = "health",
    [17534]   = "health",
    -- Mana (Satchel of Potions Mana Potion & classic restore mana effects)
    [1309726] = "mana",
    [1309727] = "mana",
    [2023]    = "mana",
    [437]     = "mana",
    [438]     = "mana",
    [17530]   = "mana",
    [17531]   = "mana",
}

local triggerSpells = {
    [ns.SATCHEL_SPELL_ID] = true,
}

-------------------------------------------------------------------------------
--  Chat helper
-------------------------------------------------------------------------------
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[SatchelTracker]|r " .. tostring(msg))
end
ns.Print = Print

local function DebugPrint(msg)
    if ns.db and ns.db.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[SatchelTracker Debug]|r " .. tostring(msg))
        if activeTrace and activeTrace.messages then
            local dt = math.floor((GetTime() - activeTrace.startTime) * 1000 + 0.5)
            table.insert(activeTrace.messages, string.format("[+%dms] %s", dt, tostring(msg)))
        end
    end
end

local function SafeStr(val)
    if issecret(val) then return "<secret>" end
    if val == nil then return "nil" end
    return tostring(val)
end

local function DescribeSpell(spellID)
    if issecret(spellID) or not spellID then return SafeStr(spellID) end
    local name = nil
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if not issecret(info) and info and not issecret(info.name) and info.name then
            name = info.name
        end
    elseif GetSpellInfo then
        local n = GetSpellInfo(spellID)
        if not issecret(n) and n then name = n end
    end
    return name and string.format("%s (%s)", tostring(spellID), name) or tostring(spellID)
end

local function SnapshotPlayerAuras()
    local list = {}
    if AuraUtil and AuraUtil.ForEachAura then
        pcall(function()
            AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
                if issecret(aura) or type(aura) ~= "table" then return end
                local sid  = (not issecret(aura.spellId) and aura.spellId) or "<secret>"
                local name = (not issecret(aura.name) and aura.name) or "<secret>"
                local id   = (not issecret(aura.auraInstanceID) and aura.auraInstanceID) or "?"
                local dur  = (not issecret(aura.duration) and aura.duration) or "?"
                table.insert(list, string.format("%s:%s(id=%s,dur=%s)", tostring(sid), tostring(name), tostring(id), tostring(dur)))
            end, true)
        end)
    end
    return list
end

local function DescribeAuraUpdateInfo(updateInfo)
    if issecret(updateInfo) or type(updateInfo) ~= "table" then return "noUpdateInfo" end
    local parts = {}
    pcall(function()
        if not issecret(updateInfo.isFullUpdate) and updateInfo.isFullUpdate then
            table.insert(parts, "fullUpdate=true")
        end
        if not issecret(updateInfo.addedAuras) and type(updateInfo.addedAuras) == "table" and #updateInfo.addedAuras > 0 then
            local added = {}
            for _, a in ipairs(updateInfo.addedAuras) do
                if not issecret(a) and type(a) == "table" then
                    local sid  = (not issecret(a.spellId) and a.spellId) or "<secret>"
                    local name = (not issecret(a.name) and a.name) or "<secret>"
                    local id   = (not issecret(a.auraInstanceID) and a.auraInstanceID) or "?"
                    table.insert(added, string.format("%s:%s(id=%s)", tostring(sid), tostring(name), tostring(id)))
                else
                    table.insert(added, "<secretAura>")
                end
            end
            table.insert(parts, "added=[" .. table.concat(added, ", ") .. "]")
        elseif issecret(updateInfo.addedAuras) then
            table.insert(parts, "added=<secret>")
        end
        if not issecret(updateInfo.updatedAuraInstanceIDs) and type(updateInfo.updatedAuraInstanceIDs) == "table" and #updateInfo.updatedAuraInstanceIDs > 0 then
            local upd = {}
            for _, id in ipairs(updateInfo.updatedAuraInstanceIDs) do
                local a = (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID and not issecret(id))
                          and C_UnitAuras.GetAuraDataByAuraInstanceID("player", id) or nil
                if not issecret(a) and type(a) == "table" then
                    local sid  = (not issecret(a.spellId) and a.spellId) or "<secret>"
                    local name = (not issecret(a.name) and a.name) or "<secret>"
                    table.insert(upd, string.format("%s:%s(id=%s)", tostring(sid), tostring(name), tostring(id)))
                else
                    table.insert(upd, "id=" .. SafeStr(id))
                end
            end
            table.insert(parts, "updated=[" .. table.concat(upd, ", ") .. "]")
        elseif issecret(updateInfo.updatedAuraInstanceIDs) then
            table.insert(parts, "updated=<secret>")
        end
        if not issecret(updateInfo.removedAuraInstanceIDs) and type(updateInfo.removedAuraInstanceIDs) == "table" and #updateInfo.removedAuraInstanceIDs > 0 then
            table.insert(parts, "removedCount=" .. tostring(#updateInfo.removedAuraInstanceIDs))
        end
    end)
    return (#parts > 0) and table.concat(parts, "; ") or "auraUpdate"
end

local function RecordDebugEvent(event, detail)
    if not (ns.db and ns.db.debugMode) then return end
    local now = GetTime()
    if activeTrace and (now - activeTrace.startTime) > 1.5 then
        activeTrace = nil
    end
    local hp  = SafeStr(UnitHealth("player")) .. "/" .. SafeStr(UnitHealthMax("player"))
    local mp  = SafeStr(UnitPower("player", 0)) .. "/" .. SafeStr(UnitPowerMax("player", 0))
    local line = string.format("%s | %s | HP=%s Mana=%s", event, detail or "", hp, mp)

    if activeTrace then
        local dt = math.floor((now - activeTrace.startTime) * 1000 + 0.5)
        table.insert(activeTrace.windowEvents, string.format("[+%dms] %s", dt, line))
    else
        table.insert(preEventBuffer, { t = now, line = line })
        while #preEventBuffer > 20 do
            table.remove(preEventBuffer, 1)
        end
    end
end

-------------------------------------------------------------------------------
--  Database initialization & helpers
-------------------------------------------------------------------------------
local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function InitDB()
    if type(SatchelTrackerDB) ~= "table" then SatchelTrackerDB = {} end
    CopyDefaults(ns.DEFAULTS, SatchelTrackerDB)
    ns.db = SatchelTrackerDB
    ns.session = ns.db.session

    -- One-time cleanup for the false fullMana:overmanaFallback roll triggered while crafting
    if not ns.db._cleanedFalseFallbackV1 then
        ns.db._cleanedFalseFallbackV1 = true
        local lastTrace = ns.db.debugLog and ns.db.debugLog[1]
        local lastHist  = ns.db.history and ns.db.history[1]
        if lastTrace and type(lastTrace.resolution) == "string"
           and lastTrace.resolution:find("overmanaFallback", 1, true)
           and lastHist and lastHist.outcome == "mana" then
            if ns.db.overall and (ns.db.overall.mana or 0) > 0 then
                ns.db.overall.mana = ns.db.overall.mana - 1
            end
            if ns.db.session and (ns.db.session.mana or 0) > 0 then
                ns.db.session.mana = ns.db.session.mana - 1
            end
            table.remove(ns.db.history, 1)
            table.remove(ns.db.debugLog, 1)
        end
    end
end

function ns.UndoLastRoll()
    if not ns.db or not ns.db.history or #ns.db.history == 0 then
        Print("No roll history to undo.")
        return false
    end
    local entry = table.remove(ns.db.history, 1)
    local outcome = entry and entry.outcome
    if outcome and ns.db.overall and ns.db.overall[outcome] ~= nil then
        ns.db.overall[outcome] = math.max(0, (ns.db.overall[outcome] or 1) - 1)
        if ns.db.session and ns.db.session[outcome] ~= nil then
            ns.db.session[outcome] = math.max(0, (ns.db.session[outcome] or 1) - 1)
        end
        if outcome == "damage" and entry.isCrit then
            ns.db.overall.damageCrit = math.max(0, (ns.db.overall.damageCrit or 1) - 1)
            if ns.db.session then
                ns.db.session.damageCrit = math.max(0, (ns.db.session.damageCrit or 1) - 1)
            end
        end
    end
    Print(string.format("Removed last recorded roll: |cffffcc00%s%s|r.",
        tostring(outcome or "unknown"):upper(),
        (entry and entry.isCrit) and " (CRIT)" or ""))
    if ns.RefreshUI then ns.RefreshUI() end
    return true
end

function ns.IsSatchelOnCooldown()
    for _, slot in ipairs({ 13, 14 }) do
        if GetInventoryItemID("player", slot) == ns.SATCHEL_ITEM_ID then
            local start, duration, enable = GetInventoryItemCooldown("player", slot)
            if not issecret(duration) and type(duration) == "number" and duration > 60 then
                return true
            end
        end
    end
    if C_Container and C_Container.GetItemCooldown then
        local start, duration, enable = C_Container.GetItemCooldown(ns.SATCHEL_ITEM_ID)
        if not issecret(duration) and type(duration) == "number" and duration > 60 then
            return true
        end
    end
    return false
end

function ns.IsSatchelEquipped()
    local t1 = GetInventoryItemID("player", 13)
    local t2 = GetInventoryItemID("player", 14)
    return t1 == ns.SATCHEL_ITEM_ID or t2 == ns.SATCHEL_ITEM_ID
end

function ns.ShouldShowWindow()
    local db = ns.db
    if not db then return false end
    if db.manualShow ~= nil then
        return db.manualShow
    end
    if db.onlyWhenEquipped then
        return ns.IsSatchelEquipped()
    end
    return true
end

function ns.GetStats(tab)
    local mode = tab or (ns.db and ns.db.activeTab) or "overall"
    if mode == "session" then
        return (ns.db and ns.db.session) or ns.DEFAULTS.session
    end
    return (ns.db and ns.db.overall) or ns.DEFAULTS.overall
end

function ns.GetTotal(stats)
    if not stats then return 0 end
    return (stats.health or 0) + (stats.mana or 0) + (stats.speed or 0) + (stats.damage or 0)
end

function ns.ResetSession()
    if ns.db and ns.db.session then
        ns.db.session.health     = 0
        ns.db.session.mana       = 0
        ns.db.session.speed      = 0
        ns.db.session.damage     = 0
        ns.db.session.damageCrit = 0
    end
    if ns.RefreshUI then ns.RefreshUI() end
end

function ns.ResetOverall()
    if ns.db then
        if ns.db.overall then
            ns.db.overall.health     = 0
            ns.db.overall.mana       = 0
            ns.db.overall.speed      = 0
            ns.db.overall.damage     = 0
            ns.db.overall.damageCrit = 0
        end
        if ns.db.history then
            wipe(ns.db.history)
        end
    end
    if ns.RefreshUI then ns.RefreshUI() end
end

-------------------------------------------------------------------------------
--  Recording outcomes
-------------------------------------------------------------------------------
local lastRecordedTime = 0

function ns.RecordOutcome(outcome, isCrit, sourceInfo)
    if not ns.db then return end
    local ov = ns.db.overall
    local ss = ns.db.session
    if ov[outcome] == nil then return end

    local now = GetTime()
    -- Hard deduplication guard: Satchel has a 10m cooldown, so never record two outcomes within 2.0s unless testing
    if sourceInfo ~= "test" and lastRecordedTime > 0 and (now - lastRecordedTime) < 2.0 then
        DebugPrint(string.format("Ignored duplicate outcome %s (%s)", tostring(outcome), tostring(sourceInfo)))
        return
    end
    lastRecordedTime = now

    ov[outcome] = (ov[outcome] or 0) + 1
    ss[outcome] = (ss[outcome] or 0) + 1

    local critFlag = (outcome == "damage" and isCrit) and true or false
    if critFlag then
        ov.damageCrit = (ov.damageCrit or 0) + 1
        ss.damageCrit = (ss.damageCrit or 0) + 1
    end

    -- Prepend to roll history (newest at index 1)
    if not ns.db.history then ns.db.history = {} end
    table.insert(ns.db.history, 1, {
        outcome   = outcome,
        isCrit    = critFlag,
        timestamp = time(),
    })
    while #ns.db.history > ns.MAX_HISTORY do
        table.remove(ns.db.history)
    end

    DebugPrint(string.format("Recorded outcome: %s%s (%s)",
        outcome:upper(),
        critFlag and " [CRIT]" or "",
        sourceInfo or "unknown"))

    if ns.RefreshUI then ns.RefreshUI(outcome) end
end

-------------------------------------------------------------------------------
--  Active trinket proc detection window & Speed Buff (1309728) detector
-------------------------------------------------------------------------------
local activeWindow = nil
local preCastSnapshot = nil -- captured on UNIT_SPELLCAST_SENT(1309685)
local preCastBuffer = nil   -- buffers same-frame child events between UNIT_SPELLCAST_SENT(1309685) and UNIT_SPELLCAST_SUCCEEDED(1309685)
local recentCombatEvent = nil
local lastSpeedAuraInstanceID = nil
local lastSpeedRecordTime = 0

local function SafeNumber(val)
    if issecret(val) or val == nil or type(val) ~= "number" then return nil end
    return val
end

-- Check if the player currently has the Satchel of Potions Speed buff (1309728)
-- or Swiftness Potion buff (2379). Returns (hasBuff, auraKey) where auraKey
-- uniquely identifies the current aura instance or expiration.
local function GetSpeedBuffState()
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        -- 1. Check the exact Satchel of Potions speed buff (1309728) first.
        -- In 12.1 combat, GetPlayerAuraBySpellID may return a secret table; non-nil still means the aura is active!
        local ok1, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, ns.SATCHEL_SPEED_BUFF)
        if ok1 and (issecret(aura) or aura ~= nil) then
            local key = "active_1309728"
            if not issecret(aura) and type(aura) == "table" then
                key = (not issecret(aura.auraInstanceID) and aura.auraInstanceID)
                   or (not issecret(aura.expirationTime) and aura.expirationTime)
                   or "active_1309728"
            end
            return true, key, ns.SATCHEL_SPEED_BUFF
        end
        -- 2. Check classic Swiftness Potion (2379)
        local ok2, aura2 = pcall(C_UnitAuras.GetPlayerAuraBySpellID, 2379)
        if ok2 and (issecret(aura2) or aura2 ~= nil) then
            local key = "active_2379"
            if not issecret(aura2) and type(aura2) == "table" then
                key = (not issecret(aura2.auraInstanceID) and aura2.auraInstanceID)
                   or (not issecret(aura2.expirationTime) and aura2.expirationTime)
                   or "active_2379"
            end
            return true, key, 2379
        end
    end

    if AuraUtil and AuraUtil.ForEachAura then
        local foundKey, foundSid = nil, nil
        pcall(function()
            AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
                if issecret(aura) or type(aura) ~= "table" then return end
                local sid = not issecret(aura.spellId) and aura.spellId
                local name = not issecret(aura.name) and aura.name
                local lname = type(name) == "string" and name:lower() or nil
                if sid == ns.SATCHEL_SPEED_BUFF or sid == 2379
                   or lname == "speed" or (lname and lname:find("swiftness")) then
                    foundKey = (not issecret(aura.auraInstanceID) and aura.auraInstanceID)
                            or (not issecret(aura.expirationTime) and aura.expirationTime)
                            or "active_aura"
                    foundSid = sid or ns.SATCHEL_SPEED_BUFF
                    return true
                end
            end, true)
        end)
        if foundKey then
            return true, foundKey, foundSid
        end
    end

    return false, nil, nil
end

-- Classify a child spellID by known table, learned table, or Satchel child spell name
local function ClassifySpell(spellID)
    if issecret(spellID) or not spellID then return nil end
    if KNOWN_SPELLS[spellID] then return KNOWN_SPELLS[spellID] end
    if ns.db and ns.db.learnedSpells and ns.db.learnedSpells[spellID] then
        return ns.db.learnedSpells[spellID]
    end

    local name = ""
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if not issecret(info) and info and not issecret(info.name) and info.name then
            name = info.name:lower()
        end
    elseif GetSpellInfo then
        local n = GetSpellInfo(spellID)
        if not issecret(n) and n then name = n:lower() end
    end

    -- Only match by spell NAME (or custom 13097xx Satchel spell range) so normal class spells
    -- cast around the same time (e.g. Fireball, Arcane Blast) are never misclassified!
    if name == "speed" or name:find("swiftness") then
        return "speed"
    elseif name:find("healing potion") or name == "greater healing potion" then
        return "health"
    elseif name:find("mana potion") or name == "restore mana" then
        return "mana"
    end

    if spellID >= 1309680 and spellID <= 1309760 and spellID ~= ns.SATCHEL_SPELL_ID then
        local desc = ""
        if C_Spell and C_Spell.GetSpellDescription then
            local d = C_Spell.GetSpellDescription(spellID)
            if not issecret(d) and d then desc = d:lower() end
        end
        local text = name .. " " .. desc
        if text:find("speed") or text:find("swiftness") then
            return "speed"
        elseif text:find("mana") then
            return "mana"
        elseif text:find("heal") or text:find("health") then
            return "health"
        elseif text:find("damage") or text:find("fire") then
            return "damage"
        end
    end
    return nil
end

local function LearnCurrentSpell(outcome)
    if not activeWindow or not activeWindow.lastSpellID then return end
    local sid = activeWindow.lastSpellID
    if not triggerSpells[sid] and ns.db and ns.db.learnedSpells then
        ns.db.learnedSpells[sid] = outcome
        DebugPrint("Learned child spellID " .. tostring(sid) .. " -> " .. outcome)
    end
end

local function ResolveWindow(outcome, isCrit, reason, isAuth)
    if not activeWindow then return end

    -- 1. First signal in this window
    if not activeWindow.outcome then
        activeWindow.outcome      = outcome
        activeWindow.firstReason  = reason
        activeWindow.isAuth       = isAuth and true or false
        activeWindow.critRecorded = (outcome == "damage" and isCrit) and true or false
        if activeTrace then
            local dt = math.floor((GetTime() - activeTrace.startTime) * 1000 + 0.5)
            activeTrace.resolution = string.format("%s%s via %s at +%dms",
                outcome:upper(),
                activeWindow.critRecorded and " (CRIT)" or "",
                tostring(reason),
                dt)
        end
        LearnCurrentSpell(outcome)
        ns.RecordOutcome(outcome, isCrit, reason)
        return
    end

    -- 2. Same outcome seen again in the 1.0s window (confirmation or crit upgrade, never double-counted)
    if not activeWindow.isConflict and activeWindow.outcome == outcome then
        if isAuth then activeWindow.isAuth = true end
        if outcome == "damage" and isCrit and not activeWindow.critRecorded then
            activeWindow.critRecorded = true
            if activeTrace then
                local dt = math.floor((GetTime() - activeTrace.startTime) * 1000 + 0.5)
                activeTrace.resolution = tostring(activeTrace.resolution) .. string.format(" -> CRIT upgraded via %s at +%dms", tostring(reason), dt)
            end
            ns.db.overall.damageCrit = (ns.db.overall.damageCrit or 0) + 1
            ns.db.session.damageCrit = (ns.db.session.damageCrit or 0) + 1
            if ns.db.history and ns.db.history[1] and ns.db.history[1].outcome == "damage" then
                ns.db.history[1].isCrit = true
            end
            DebugPrint("Upgraded current Damage proc to CRIT (" .. tostring(reason) .. ")")
            if ns.RefreshUI then ns.RefreshUI("damage") end
        elseif activeTrace then
            local dt = math.floor((GetTime() - activeTrace.startTime) * 1000 + 0.5)
            activeTrace.confirmations = activeTrace.confirmations or {}
            table.insert(activeTrace.confirmations, string.format("[+%dms] confirmed %s via %s", dt, outcome, tostring(reason)))
        end
        return
    end

    -- 2b. If an authoritative Satchel child spell (1309725 Heal, 1309726 Mana, 1309728 Speed)
    -- already locked in the outcome, ignore non-authoritative external combat hits (e.g. a mob hitting you)!
    if activeWindow.isAuth and not isAuth then
        if activeTrace then
            local dt = math.floor((GetTime() - activeTrace.startTime) * 1000 + 0.5)
            activeTrace.confirmations = activeTrace.confirmations or {}
            table.insert(activeTrace.confirmations, string.format("[+%dms] ignored external %s (%s) because %s is locked by Satchel spell", dt, tostring(outcome), tostring(reason), tostring(activeWindow.outcome)))
        end
        return
    end

    -- 3. Conflicting outcome detected within the same window!
    local ov = ns.db and ns.db.overall
    local ss = ns.db and ns.db.session
    if not activeWindow.isConflict then
        activeWindow.isConflict = true
        local orig = activeWindow.outcome
        -- Roll back the first outcome from Overall and Session so conflicting rolls are NOT counted in totals
        if ov and ov[orig] then ov[orig] = math.max(0, (ov[orig] or 1) - 1) end
        if ss and ss[orig] then ss[orig] = math.max(0, (ss[orig] or 1) - 1) end
        if activeWindow.critRecorded then
            if ov then ov.damageCrit = math.max(0, (ov.damageCrit or 1) - 1) end
            if ss then ss.damageCrit = math.max(0, (ss.damageCrit or 1) - 1) end
        end
        activeWindow.conflicts   = { orig, outcome }
        activeWindow.conflictSet = { [orig] = true, [outcome] = true }
    elseif not activeWindow.conflictSet[outcome] then
        activeWindow.conflictSet[outcome] = true
        table.insert(activeWindow.conflicts, outcome)
    else
        return -- already recorded this outcome in the conflict list
    end

    local conflictStr = table.concat(activeWindow.conflicts, "/")

    -- Replace the top history entry with "unknown: <outcome1>/<outcome2>"
    if ns.db and ns.db.history and ns.db.history[1] then
        ns.db.history[1].outcome   = "unknown"
        ns.db.history[1].conflicts = conflictStr
        ns.db.history[1].isCrit    = false
    end

    if activeTrace then
        local dt = math.floor((GetTime() - activeTrace.startTime) * 1000 + 0.5)
        activeTrace.resolution = string.format("CONFLICT (%s) - first=%s (%s), conflicting=%s (%s) at +%dms",
            conflictStr,
            tostring(activeWindow.outcome),
            tostring(activeWindow.firstReason),
            tostring(outcome),
            tostring(reason),
            dt)
    end

    if ns.db and ns.db.debugMode then
        DebugPrint(string.format("CONFLICT detected: unknown: %s (first=%s via %s, second=%s via %s). Saved to debugLog.",
            conflictStr, tostring(activeWindow.outcome), tostring(activeWindow.firstReason), tostring(outcome), tostring(reason)))
    else
        Print(string.format("|cffe67e22Conflicting proc signals detected|r (unknown: %s). Logged to History without counting in totals.", conflictStr))
    end

    if ns.RefreshUI then ns.RefreshUI("unknown") end
end

local function CheckResourceDeltas(reason)
    if not activeWindow or activeWindow.outcome then return end

    -- 1. Check Speed buff (1309728 / 2379) first
    local hasSpeed, speedKey, speedSid = GetSpeedBuffState()
    if hasSpeed then
        -- If the player has 1309728 right now (or the aura key changed since pre-cast), it's Speed!
        if speedSid == ns.SATCHEL_SPEED_BUFF or not activeWindow.speedKeyBefore or speedKey ~= activeWindow.speedKeyBefore then
            lastSpeedAuraInstanceID = speedKey
            lastSpeedRecordTime = GetTime()
            ResolveWindow("speed", false, reason .. ":speedBuff(" .. tostring(speedSid) .. ")")
            return
        end
    end

    -- 2. Check Health delta
    local hpNow = SafeNumber(UnitHealth("player"))
    if hpNow and activeWindow.hpBefore then
        local hpDelta = hpNow - activeWindow.hpBefore
        if hpDelta <= -50 then
            local isCrit = (hpDelta <= -280)
            ResolveWindow("damage", isCrit, string.format("%s:hpDelta(%d)", reason, hpDelta))
            return
        elseif hpDelta >= 50 then
            ResolveWindow("health", false, string.format("%s:hpDelta(+%d)", reason, hpDelta))
            return
        end
    end

    -- 3. Check Mana delta
    local manaNow = SafeNumber(UnitPower("player", 0))
    if manaNow and activeWindow.manaBefore then
        local manaDelta = manaNow - activeWindow.manaBefore
        if manaDelta >= 50 then
            ResolveWindow("mana", false, string.format("%s:manaDelta(+%d)", reason, manaDelta))
            return
        end
    end
end

-- Route a detected signal into activeWindow if open, or buffer it in preCastBuffer
-- if it arrived in the same frame between UNIT_SPELLCAST_SENT(1309685) and UNIT_SPELLCAST_SUCCEEDED(1309685).
local function RecordOrBufferSignal(outcome, isCrit, reason, isAuth, spellID)
    if activeWindow then
        if spellID then activeWindow.lastSpellID = spellID end
        ResolveWindow(outcome, isCrit, reason, isAuth)
    elseif preCastBuffer and (GetTime() - preCastBuffer.time) <= 0.25 then
        table.insert(preCastBuffer.signals, {
            outcome = outcome,
            isCrit  = isCrit,
            reason  = reason,
            isAuth  = isAuth,
            spellID = spellID,
        })
    end
end

local function StartDetectionWindow(triggerSpellID)
    local now = GetTime()
    -- Guard against duplicate trigger events within 0.2s
    if activeWindow and (now - activeWindow.startTime) < 0.2 then
        return
    end

    -- Use pre-cast snapshot if UNIT_SPELLCAST_SENT fired within the last 0.5s
    -- (protects against instant effects that apply in the same packet batch right before UNIT_SPELLCAST_SUCCEEDED)
    local snap = (preCastSnapshot and (now - preCastSnapshot.time) < 0.5) and preCastSnapshot or nil
    local _, currentSpeedKey = GetSpeedBuffState()

    activeWindow = {
        startTime      = now,
        hpBefore       = (snap and snap.hp) or SafeNumber(UnitHealth("player")),
        maxHp          = SafeNumber(UnitHealthMax("player")),
        manaBefore     = (snap and snap.mana) or SafeNumber(UnitPower("player", 0)),
        maxMana        = SafeNumber(UnitPowerMax("player", 0)),
        speedKeyBefore = snap and snap.speedKey or currentSpeedKey,
        outcome        = nil,
        critRecorded   = false,
        lastSpellID    = nil,
    }

    -- Start persistent debug trace in SatchelTrackerDB.debugLog if debugMode is ON
    if ns.db and ns.db.debugMode then
        if type(ns.db.debugLog) ~= "table" then ns.db.debugLog = {} end
        local preList = {}
        for _, item in ipairs(preEventBuffer) do
            if (now - item.t) <= 1.0 then
                local dt = math.floor((item.t - now) * 1000 + 0.5)
                table.insert(preList, string.format("[%dms] %s", dt, item.line))
            end
        end
        wipe(preEventBuffer)

        activeTrace = {
            startTime    = now,
            timestamp    = date("%Y-%m-%d %H:%M:%S"),
            triggerSpell = DescribeSpell(triggerSpellID),
            inCombat     = InCombatLockdown() and true or false,
            stateBefore  = {
                hp      = SafeStr(activeWindow.hpBefore) .. "/" .. SafeStr(activeWindow.maxHp),
                mana    = SafeStr(activeWindow.manaBefore) .. "/" .. SafeStr(activeWindow.maxMana),
                auras   = SnapshotPlayerAuras(),
            },
            preEvents    = preList,
            windowEvents = {},
            messages     = {},
            stateAfter   = {},
            resolution   = "unresolved",
        }
        table.insert(ns.db.debugLog, 1, activeTrace)
        while #ns.db.debugLog > MAX_DEBUG_TRACES do
            table.remove(ns.db.debugLog)
        end
    else
        activeTrace = nil
    end

    DebugPrint(string.format("Satchel activated (spell %s). Watching for outcome...", tostring(triggerSpellID)))

    -- Replay any child spell / combat text / aura signals that fired in the same frame
    -- between UNIT_SPELLCAST_SENT(1309685) and UNIT_SPELLCAST_SUCCEEDED(1309685)!
    if preCastBuffer and (now - preCastBuffer.time) <= 0.25 and #preCastBuffer.signals > 0 then
        local buffered = preCastBuffer.signals
        preCastBuffer = nil
        for _, sig in ipairs(buffered) do
            if sig.spellID then activeWindow.lastSpellID = sig.spellID end
            ResolveWindow(sig.outcome, sig.isCrit, sig.reason, sig.isAuth)
        end
    else
        preCastBuffer = nil
    end

    -- Check immediately in case 1309728 or HP/Mana delta already applied in the same packet
    CheckResourceDeltas("immediate")

    local windowRef = activeWindow
    local traceRef  = activeTrace
    C_Timer.After(0.10, function()
        if activeWindow == windowRef then CheckResourceDeltas("timer0.10s") end
    end)
    C_Timer.After(0.30, function()
        if activeWindow == windowRef then CheckResourceDeltas("timer0.30s") end
        if traceRef and traceRef.stateAfter then
            traceRef.stateAfter["300ms"] = {
                hp    = SafeStr(UnitHealth("player")) .. "/" .. SafeStr(UnitHealthMax("player")),
                mana  = SafeStr(UnitPower("player", 0)) .. "/" .. SafeStr(UnitPowerMax("player", 0)),
                auras = SnapshotPlayerAuras(),
            }
        end
    end)
    C_Timer.After(0.60, function()
        if activeWindow == windowRef then CheckResourceDeltas("timer0.60s") end
    end)
    C_Timer.After(1.00, function()
        if activeWindow == windowRef then
            pcall(function()
                if not activeWindow.outcome then
                    CheckResourceDeltas("timer1.00s")
                end
                if activeWindow and not activeWindow.outcome then
                    DebugPrint("Detection window expired at 1.0s with no outcome — ignored.")
                    if traceRef then
                        traceRef.resolution = "ignored (no outcome detected)"
                    end
                end
            end)
            if activeWindow == windowRef then
                activeWindow = nil
            end
        end
        if traceRef and traceRef.stateAfter then
            pcall(function()
                traceRef.stateAfter["1000ms"] = {
                    hp    = SafeStr(UnitHealth("player")) .. "/" .. SafeStr(UnitHealthMax("player")),
                    mana  = SafeStr(UnitPower("player", 0)) .. "/" .. SafeStr(UnitPowerMax("player", 0)),
                    auras = SnapshotPlayerAuras(),
                }
            end)
        end
        if activeTrace == traceRef then
            activeTrace = nil
        end
    end)
end

-------------------------------------------------------------------------------
--  Event handling
-------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterUnitEvent("UNIT_AURA", "player")
ev:RegisterUnitEvent("UNIT_COMBAT", "player")
ev:RegisterUnitEvent("UNIT_HEALTH", "player")
ev:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
ev:RegisterEvent("COMBAT_TEXT_UPDATE")

local function CacheItemSpell()
    if C_Item and C_Item.GetItemSpell then
        local _, sid = C_Item.GetItemSpell(ns.SATCHEL_ITEM_ID)
        if not issecret(sid) and sid then
            triggerSpells[sid] = true
        end
    end
end

ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
    -- Hard failsafe: never allow activeWindow or activeTrace to stay open past 1.2s
    if activeWindow and (GetTime() - activeWindow.startTime) > 1.2 then
        activeWindow = nil
    end
    if activeTrace and (GetTime() - activeTrace.startTime) > 1.5 then
        activeTrace = nil
    end

    if event == "ADDON_LOADED" then
        if not issecret(arg1) and arg1 == ADDON then
            InitDB()
            if ns.BuildUI then ns.BuildUI() end
            ev:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        CacheItemSpell()
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(ns.SATCHEL_ITEM_ID)
        end
        local _, speedKey = GetSpeedBuffState()
        lastSpeedAuraInstanceID = speedKey
        if ns.UpdateVisibility then ns.UpdateVisibility() end
        if ns.RefreshUI then ns.RefreshUI() end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- arg1 = isInitialLogin (true ONLY on fresh login after logout/launch, false on /reload!)
        -- arg2 = isReloadingUi  (true on /reload)
        local isInitialLogin = not issecret(arg1) and arg1
        local isReloadingUi  = not issecret(arg2) and arg2
        if isInitialLogin and ns.db then
            -- Fresh login after logging out: reset Current Session, debug mode, and manual visibility override
            ns.db.manualShow = nil
            ns.db.debugMode  = false
            ns.ResetSession()
        elseif isReloadingUi and ns.db and ns.db.debugMode then
            Print("Debug logging is |cff2ecc71ON|r.")
        end
        CacheItemSpell()
        if ns.UpdateVisibility then ns.UpdateVisibility() end
        return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
        CacheItemSpell()
        if ns.UpdateVisibility then ns.UpdateVisibility() end
        return
    end

    if event == "UNIT_SPELLCAST_SENT" then
        -- arg1 = "player", arg2 = target, arg3 = castGUID, arg4 = spellID
        -- Note: In WoW Forever, child spells (1309725 Healing Potion, 1309726 Restore Mana, 1309728 Speed)
        -- fire UNIT_SPELLCAST_SUCCEEDED in the same frame *between* UNIT_SPELLCAST_SENT(1309685)
        -- and UNIT_SPELLCAST_SUCCEEDED(1309685). However, if the player clicks the trinket while busy
        -- crafting/casting, UNIT_SPELLCAST_SENT(1309685) fires and the server rejects the cast
        -- (UNIT_SPELLCAST_SUCCEEDED(1309685) never fires). So we buffer same-frame signals in preCastBuffer
        -- and ONLY open the detection window when UNIT_SPELLCAST_SUCCEEDED(1309685) confirms the cast!
        local spellID = arg4
        if ns.db and ns.db.debugMode then
            RecordDebugEvent("UNIT_SPELLCAST_SENT", "spell=" .. DescribeSpell(spellID))
        end
        if not issecret(spellID) and spellID and triggerSpells[spellID] then
            local now = GetTime()
            local _, speedKey = GetSpeedBuffState()
            preCastSnapshot = {
                time     = now,
                hp       = SafeNumber(UnitHealth("player")),
                mana     = SafeNumber(UnitPower("player", 0)),
                speedKey = speedKey,
            }
            preCastBuffer = {
                time    = now,
                signals = {},
            }
        end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1 = unit ("player"), arg2 = castGUID, arg3 = spellID
        local spellID = arg3
        if ns.db and ns.db.debugMode then
            RecordDebugEvent("UNIT_SPELLCAST_SUCCEEDED", "spell=" .. DescribeSpell(spellID))
        end
        if issecret(spellID) or not spellID then return end

        if triggerSpells[spellID] then
            if not activeWindow and (GetTime() - lastRecordedTime) > 1.0 then
                StartDetectionWindow(spellID)
            end
            return
        end

        if activeWindow or (preCastBuffer and (GetTime() - preCastBuffer.time) <= 0.25) then
            local outcome = ClassifySpell(spellID)
            if outcome then
                local isAuth = (spellID >= 1309680 and spellID <= 1309760)
                DebugPrint(string.format("Child spell cast: %s -> %s", DescribeSpell(spellID), tostring(outcome)))
                RecordOrBufferSignal(outcome, false, "spell:" .. tostring(spellID), isAuth, spellID)
            end
        end
        return
    end

    if event == "UNIT_AURA" then
        if activeTrace and ns.db and ns.db.debugMode then
            RecordDebugEvent("UNIT_AURA", DescribeAuraUpdateInfo(arg2))
        end
        local inPreCast = (not activeWindow) and preCastBuffer and (GetTime() - preCastBuffer.time) <= 0.25
        if not activeWindow and not inPreCast then return end
        local hasSpeed, speedKey, speedSid = GetSpeedBuffState()
        if hasSpeed then
            local prevKey = (activeWindow and activeWindow.speedKeyBefore) or (preCastSnapshot and preCastSnapshot.speedKey)
            if speedSid == ns.SATCHEL_SPEED_BUFF or not prevKey or speedKey ~= prevKey then
                lastSpeedAuraInstanceID = speedKey
                lastSpeedRecordTime = GetTime()
                local isAuth = (speedSid == ns.SATCHEL_SPEED_BUFF)
                RecordOrBufferSignal("speed", false, "UNIT_AURA:" .. tostring(speedSid), isAuth)
                return
            end
        end
        return
    end

    if event == "UNIT_COMBAT" then
        local combatEvent = not issecret(arg2) and arg2 or nil
        local flagText    = not issecret(arg3) and arg3 or nil
        local amount      = SafeNumber(arg4)
        local school      = SafeNumber(arg5)
        if activeTrace and ns.db and ns.db.debugMode then
            RecordDebugEvent("UNIT_COMBAT", string.format("event=%s flag=%s amount=%s school=%s",
                SafeStr(arg2), SafeStr(arg3), SafeStr(arg4), SafeStr(arg5)))
        end

        local inPreCast = (not activeWindow) and preCastBuffer and (GetTime() - preCastBuffer.time) <= 0.15
        if activeWindow or inPreCast then
            local elapsed = activeWindow and (GetTime() - activeWindow.startTime) or 0
            if combatEvent == "HEAL" and elapsed <= 0.15 then
                DebugPrint("UNIT_COMBAT: HEAL")
                RecordOrBufferSignal("health", false, "UNIT_COMBAT:HEAL", false)
            elseif combatEvent == "ENERGIZE" and elapsed <= 0.15 then
                DebugPrint("UNIT_COMBAT: ENERGIZE")
                RecordOrBufferSignal("mana", false, "UNIT_COMBAT:ENERGIZE", false)
            elseif combatEvent == "WOUND" and school == 4 and flagText ~= "ABSORB" then
                local isCrit = (flagText == "CRITICAL") or (amount ~= nil and amount > 280)
                DebugPrint(string.format("UNIT_COMBAT: WOUND school=%s flag=%s", tostring(school), tostring(flagText)))
                RecordOrBufferSignal("damage", isCrit, "UNIT_COMBAT:WOUND", false)
            end
        end
        return
    end

    if event == "COMBAT_TEXT_UPDATE" then
        local ctype = not issecret(arg1) and arg1 or nil
        if activeTrace and ns.db and ns.db.debugMode then
            RecordDebugEvent("COMBAT_TEXT_UPDATE", "type=" .. SafeStr(arg1))
        end
        local inPreCast = (not activeWindow) and preCastBuffer and (GetTime() - preCastBuffer.time) <= 0.12
        if not activeWindow and not inPreCast then return end
        -- Satchel COMBAT_TEXT_UPDATE events always fire in the same frame (+0ms) as activation.
        -- Ignoring COMBAT_TEXT_UPDATE after 120ms prevents mob spell hits at +560ms from causing false conflicts!
        if activeWindow and (GetTime() - activeWindow.startTime) > 0.12 then return end
        if ctype == "MANA" or ctype == "ENERGIZE" or ctype == "PERIODIC_ENERGIZE" then
            DebugPrint("COMBAT_TEXT_UPDATE: " .. tostring(ctype))
            RecordOrBufferSignal("mana", false, "COMBAT_TEXT:" .. ctype, false)
        elseif ctype == "HEAL" or ctype == "HEAL_CRIT" then
            DebugPrint("COMBAT_TEXT_UPDATE: " .. tostring(ctype))
            RecordOrBufferSignal("health", false, "COMBAT_TEXT:" .. ctype, false)
        elseif ctype == "SPELL_DAMAGE_CRIT" then
            DebugPrint("COMBAT_TEXT_UPDATE: " .. tostring(ctype))
            RecordOrBufferSignal("damage", true, "COMBAT_TEXT:" .. ctype, false)
        elseif ctype == "SPELL_DAMAGE" then
            DebugPrint("COMBAT_TEXT_UPDATE: " .. tostring(ctype))
            RecordOrBufferSignal("damage", false, "COMBAT_TEXT:" .. ctype, false)
        end
        return
    end

    if event == "UNIT_HEALTH" then
        if activeTrace and ns.db and ns.db.debugMode then
            RecordDebugEvent("UNIT_HEALTH", "")
        end
        if not activeWindow then return end
        local hpNow = SafeNumber(UnitHealth("player"))
        if hpNow and activeWindow.hpBefore then
            local delta = hpNow - activeWindow.hpBefore
            if delta <= -280 and activeWindow.outcome == "damage" and not activeWindow.critRecorded then
                ResolveWindow("damage", true, "UNIT_HEALTH:critDelta")
            elseif not activeWindow.outcome and (delta <= -50 or delta >= 50) then
                CheckResourceDeltas("UNIT_HEALTH")
            end
        end
        return
    end

    if event == "UNIT_POWER_UPDATE" then
        local powerToken = not issecret(arg2) and arg2 or nil
        if activeTrace and ns.db and ns.db.debugMode then
            RecordDebugEvent("UNIT_POWER_UPDATE", "token=" .. SafeStr(arg2))
        end
        if not activeWindow or activeWindow.outcome then return end
        DebugPrint("UNIT_POWER_UPDATE: token=" .. tostring(powerToken))
        if powerToken == "MANA" then
            CheckResourceDeltas("UNIT_POWER_UPDATE")
        end
        return
    end
end)

-------------------------------------------------------------------------------
--  Slash Commands (/satchel or /st)
-------------------------------------------------------------------------------
SLASH_SATCHELTRACKER1 = "/satchel"
SLASH_SATCHELTRACKER2 = "/st"

SlashCmdList.SATCHELTRACKER = function(msg)
    local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local db = ns.db
    if not db then return end

    if cmd == "" or cmd == "toggle" or cmd == "show" then
        local currentlyShown = ns.frame and ns.frame:IsShown()
        db.manualShow = not currentlyShown
        if ns.UpdateVisibility then ns.UpdateVisibility() end
        Print(db.manualShow and "Tracker shown." or "Tracker hidden.")

    elseif cmd == "compact" or cmd == "c" then
        if rest == "v" or rest == "vertical" or rest == "vert" then
            db.compact = true
            db.compactLayout = "vertical"
        elseif rest == "h" or rest == "horizontal" or rest == "horiz" then
            db.compact = true
            db.compactLayout = "horizontal"
        else
            db.compact = not db.compact
        end
        if ns.RefreshUI then ns.RefreshUI() end
        Print(string.format("Compact mode: %s (%s)",
            db.compact and "|cff2ecc71ON|r" or "|cffe74c3cOFF|r",
            db.compactLayout))

    elseif cmd == "vertical" or cmd == "vert" then
        db.compactLayout = (db.compactLayout == "vertical") and "horizontal" or "vertical"
        if ns.RefreshUI then ns.RefreshUI() end
        Print("Compact layout: " .. db.compactLayout)

    elseif cmd == "auto" or cmd == "equip" then
        db.manualShow = nil
        db.onlyWhenEquipped = not db.onlyWhenEquipped
        if ns.UpdateVisibility then ns.UpdateVisibility() end
        Print("Only show when equipped: " .. (db.onlyWhenEquipped and "|cff2ecc71ON|r" or "|cffe74c3cOFF|r"))

    elseif cmd == "lock" then
        db.locked = not db.locked
        if ns.RefreshUI then ns.RefreshUI() end
        Print("Window " .. (db.locked and "|cffe74c3clocked|r." or "|cff2ecc71unlocked|r."))

    elseif cmd == "reset" then
        if rest == "overall" or rest == "all" then
            ns.ResetOverall()
            ns.ResetSession()
            Print("Overall, Session, and History stats reset.")
        else
            ns.ResetSession()
            Print("Current Session stats reset. (Use '/satchel reset overall' to clear all-time stats.)")
        end

    elseif cmd == "undo" then
        ns.UndoLastRoll()

    elseif cmd == "test" then
        local roll = math.random(1, 4)
        local outcome = ns.OUTCOME_KEYS[roll]
        local isCrit = (outcome == "damage") and (math.random(1, 100) <= 25) or false
        db.manualShow = true
        if ns.UpdateVisibility then ns.UpdateVisibility() end
        ns.RecordOutcome(outcome, isCrit, "test")
        Print(string.format("Simulated roll: %s%s", outcome:upper(), isCrit and " (CRIT!)" or ""))

    elseif cmd == "minimap" or cmd == "mm" then
        db.minimap.hide = not db.minimap.hide
        if ns.UpdateMinimapButton then ns.UpdateMinimapButton() end
        Print("Minimap button: " .. (db.minimap.hide and "|cffe74c3cHIDDEN|r" or "|cff2ecc71SHOWN|r"))

    elseif cmd == "debug" then
        db.debugMode = not db.debugMode
        Print("Debug logging: " .. (db.debugMode and "|cff2ecc71ON|r" or "|cffe74c3cOFF|r"))

    else
        Print("Commands:")
        Print("  |cffffcc00/satchel|r - Show / hide the tracker window")
        Print("  |cffffcc00/satchel compact [h|v]|r - Toggle compact mode (horizontal / vertical)")
        Print("  |cffffcc00/satchel minimap|r - Show / hide the minimap button")
        Print("  |cffffcc00/satchel lock|r - Lock / unlock window position")
        Print("  |cffffcc00/satchel equip|r - Toggle auto-show only when equipped")
        Print("  |cffffcc00/satchel undo|r - Remove the last recorded roll")
        Print("  |cffffcc00/satchel reset|r - Reset current session stats")
        Print("  |cffffcc00/satchel reset overall|r - Reset all-time & session stats")
        Print("  |cffffcc00/satchel test|r - Simulate a random potion roll")
        Print("  |cffffcc00/satchel debug|r - Toggle debug event output")
    end
end
