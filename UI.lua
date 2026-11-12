-------------------------------------------------------------------------------
--  SatchelTracker  -  UI.lua
--  Standalone draggable tracker window with:
--    1. Full Mode: 3 tabs (Overall | Session | History)
--       - Overall & Session: 4 outcome rows + Damage Crits sub-row with % bars
--       - History: Recent icon strip (last 8) + chronological list of rolls
--    2. Compact Mode: Horizontal or Vertical icon + count strip
--    3. Minimap Button: Click to toggle, right-click to cycle tabs
-------------------------------------------------------------------------------
local ADDON, ns = ...

local FRAME_W        = 222
local HEADER_H       = 24
local TAB_H          = 22
local ROW_H          = 20
local SUBROW_H       = 17
local PAD            = 6
local ROW_GAP        = 3
local HIST_STRIP_H   = 22
local HIST_ROWS      = 4
local HIST_ROW_H     = 18

local ROWS = {
    {
        key   = "health",
        label = "Health",
        icon  = "Interface\\Icons\\INV_Potion_54",
        color = { 0.18, 0.80, 0.44 }, -- #2ecc71 Green
        hex   = "2ecc71",
    },
    {
        key   = "mana",
        label = "Mana",
        icon  = "Interface\\Icons\\INV_Potion_72",
        color = { 0.20, 0.60, 0.86 }, -- #3498db Blue
        hex   = "3498db",
    },
    {
        key   = "speed",
        label = "Speed",
        icon  = "Interface\\Icons\\INV_Potion_95",
        color = { 0.95, 0.77, 0.06 }, -- #f1c40f Gold
        hex   = "f1c40f",
    },
    {
        key   = "damage",
        label = "Damage",
        icon  = "Interface\\Icons\\Spell_Fire_SelfDestruct",
        color = { 0.91, 0.30, 0.24 }, -- #e74c3c Red
        hex   = "e74c3c",
    },
}

local ROW_BY_KEY = {}
for _, r in ipairs(ROWS) do ROW_BY_KEY[r.key] = r end

local function CreateBorder(f, r, g, b, a)
    local edges = {}
    local function Edge(p1, p2, w, h)
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, a)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        return t
    end
    edges.top    = Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    edges.bottom = Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    edges.left   = Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    edges.right  = Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return edges
end

local function FormatCountPct(count, total)
    local pct = (total > 0) and (count / total * 100) or 0
    return string.format("%d  |cffb0b8c4(%.1f%%)|r", count, pct), pct
end

local function FormatAgo(ts)
    if not ts then return "" end
    local diff = math.max(0, time() - ts)
    if diff < 60 then
        return diff .. "s ago"
    elseif diff < 3600 then
        return math.floor(diff / 60) .. "m ago"
    elseif diff < 86400 then
        return math.floor(diff / 3600) .. "h ago"
    else
        return math.floor(diff / 86400) .. "d ago"
    end
end

function ns.UpdateVisibility()
    if not ns.frame then return end
    if ns.ShouldShowWindow() then
        ns.frame:Show()
        ns.RefreshUI()
    else
        ns.frame:Hide()
    end
end

-------------------------------------------------------------------------------
--  Refresh UI (Full Mode + Compact Mode)
-------------------------------------------------------------------------------
function ns.RefreshUI()
    local f = ns.frame
    if not f or not ns.db then return end

    local isCompact = ns.db.compact == true
    local activeTab = ns.db.activeTab or "overall"
    local ovStats   = ns.GetStats("overall")
    local ssStats   = ns.GetStats("session")
    local ovTotal   = ns.GetTotal(ovStats)
    local ssTotal   = ns.GetTotal(ssStats)
    local hist      = ns.db.history or {}

    -- Stats source for Compact Mode & Stats Panel (if on history tab, compact shows session or overall)
    local statsMode = (activeTab == "session") and "session" or "overall"
    local stats     = (statsMode == "session") and ssStats or ovStats
    local total     = (statsMode == "session") and ssTotal or ovTotal

    if isCompact then
        f.fullRoot:Hide()
        f.compactRoot:Show()

        local vert = (ns.db.compactLayout == "vertical")
        local itemW, itemH = 44, 22
        local ctrlW = 18

        if vert then
            local cw = 64
            local ch = PAD * 2 + (#ROWS * (itemH + 2)) + 16
            f:SetSize(cw, ch)
            f.compactExpandBtn:ClearAllPoints()
            f.compactExpandBtn:SetPoint("TOPRIGHT", f.compactRoot, "TOPRIGHT", -3, -3)

            for i, rcfg in ipairs(ROWS) do
                local cell = f.compactCells[rcfg.key]
                cell:ClearAllPoints()
                cell:SetSize(cw - PAD * 2, itemH)
                cell:SetPoint("TOPLEFT", f.compactRoot, "TOPLEFT", PAD, -(16 + (i - 1) * (itemH + 2)))
            end
        else
            local cw = PAD * 2 + (#ROWS * (itemW + 4)) + ctrlW
            local ch = 28
            f:SetSize(cw, ch)
            f.compactExpandBtn:ClearAllPoints()
            f.compactExpandBtn:SetPoint("RIGHT", f.compactRoot, "RIGHT", -4, 0)

            for i, rcfg in ipairs(ROWS) do
                local cell = f.compactCells[rcfg.key]
                cell:ClearAllPoints()
                cell:SetSize(itemW, itemH)
                cell:SetPoint("LEFT", f.compactRoot, "LEFT", PAD + (i - 1) * (itemW + 4), 0)
            end
        end

        for _, rcfg in ipairs(ROWS) do
            local cell = f.compactCells[rcfg.key]
            local count = stats[rcfg.key] or 0
            if rcfg.key == "damage" and (stats.damageCrit or 0) > 0 then
                cell.text:SetFormattedText("%d|cffff7675*|r", count)
            else
                cell.text:SetText(tostring(count))
            end
        end
        return
    end

    -- Full Mode
    f.compactRoot:Hide()
    f.fullRoot:Show()

    local hasEverCrit = (ovStats.damageCrit or 0) > 0
    if activeTab == "history" or hasEverCrit then
        f:SetSize(FRAME_W, f.fullHeight)
    else
        f:SetSize(FRAME_W, f.fullHeightNoCrit)
    end

    -- Update Tab Labels
    f.tabs.overall.label:SetFormattedText("Overall (%d)", ovTotal)
    f.tabs.session.label:SetFormattedText("Session (%d)", ssTotal)
    f.tabs.history.label:SetFormattedText("History (%d)", #hist)

    for key, btn in pairs(f.tabs) do
        if key == activeTab then
            btn.bg:SetColorTexture(0.18, 0.22, 0.28, 0.95)
            btn.accent:Show()
            btn.label:SetTextColor(1, 0.84, 0.2)
        else
            btn.bg:SetColorTexture(0.09, 0.11, 0.14, 0.85)
            btn.accent:Hide()
            btn.label:SetTextColor(0.65, 0.68, 0.72)
        end
    end

    -- Lock button state
    if ns.db.locked then
        f.lockBtn.label:SetText("|cffe74c3cL|r")
    else
        f.lockBtn.label:SetText("|cff2ecc71U|r")
    end

    if activeTab == "history" then
        f.statsPanel:Hide()
        f.historyPanel:Show()

        -- 1. Update recent icon strip (up to last 8 rolls, newest on left)
        for i = 1, #f.histIcons do
            local slot = f.histIcons[i]
            local entry = hist[i]
            if entry and entry.outcome == "unknown" then
                slot.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                slot.border.top:SetColorTexture(0.90, 0.49, 0.13, 1)
                slot.border.bottom:SetColorTexture(0.90, 0.49, 0.13, 1)
                slot.border.left:SetColorTexture(0.90, 0.49, 0.13, 1)
                slot.border.right:SetColorTexture(0.90, 0.49, 0.13, 1)
                slot:Show()
            elseif entry and ROW_BY_KEY[entry.outcome] then
                local rcfg = ROW_BY_KEY[entry.outcome]
                slot.icon:SetTexture(rcfg.icon)
                if entry.isCrit then
                    slot.border.top:SetColorTexture(1, 0.35, 0.2, 1)
                    slot.border.bottom:SetColorTexture(1, 0.35, 0.2, 1)
                    slot.border.left:SetColorTexture(1, 0.35, 0.2, 1)
                    slot.border.right:SetColorTexture(1, 0.35, 0.2, 1)
                else
                    slot.border.top:SetColorTexture(rcfg.color[1], rcfg.color[2], rcfg.color[3], 0.85)
                    slot.border.bottom:SetColorTexture(rcfg.color[1], rcfg.color[2], rcfg.color[3], 0.85)
                    slot.border.left:SetColorTexture(rcfg.color[1], rcfg.color[2], rcfg.color[3], 0.85)
                    slot.border.right:SetColorTexture(rcfg.color[1], rcfg.color[2], rcfg.color[3], 0.85)
                end
                slot:Show()
            else
                slot:Hide()
            end
        end

        -- 2. Update chronological rows
        for i = 1, HIST_ROWS do
            local hrow = f.histRows[i]
            local entry = hist[i]
            if entry and entry.outcome == "unknown" then
                hrow.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                hrow.leftText:SetFormattedText("|cff7f8c8d#%d|r  |cffe67e22unknown: %s|r",
                    i, tostring(entry.conflicts or "?"))
                hrow.rightText:SetText(FormatAgo(entry.timestamp))
                hrow:Show()
            elseif entry and ROW_BY_KEY[entry.outcome] then
                local rcfg = ROW_BY_KEY[entry.outcome]
                hrow.icon:SetTexture(rcfg.icon)
                local critTag = entry.isCrit and " |cffff7675(CRIT!)|r" or ""
                hrow.leftText:SetFormattedText("|cff7f8c8d#%d|r  |cff%s%s|r%s",
                    i, rcfg.hex, rcfg.label, critTag)
                hrow.rightText:SetText(FormatAgo(entry.timestamp))
                hrow:Show()
            else
                hrow:Hide()
            end
        end
        f.histEmpty:SetShown(#hist == 0)
        return
    end

    -- Stats Panel (Overall or Session)
    f.historyPanel:Hide()
    f.statsPanel:Show()

    local barMaxW = FRAME_W - PAD * 2 - 2
    for _, rcfg in ipairs(ROWS) do
        local row = f.rows[rcfg.key]
        local count = stats[rcfg.key] or 0
        local text, pct = FormatCountPct(count, total)
        row.value:SetText(text)

        if pct > 0 then
            local w = math.max(2, math.floor(barMaxW * (pct / 100) + 0.5))
            row.fill:SetWidth(w)
            row.fill:Show()
        else
            row.fill:Hide()
        end
    end

    -- Damage Crits sub-row (hidden until the first crit ever happens!)
    if hasEverCrit then
        f.critRow:Show()
        local dmgCount  = stats.damage or 0
        local critCount = stats.damageCrit or 0
        local critText, critPct = FormatCountPct(critCount, dmgCount)
        f.critRow.value:SetText(critText)
        if critPct > 0 then
            local critMaxW = barMaxW - 10
            local w = math.max(2, math.floor(critMaxW * (critPct / 100) + 0.5))
            f.critRow.fill:SetWidth(w)
            f.critRow.fill:Show()
        else
            f.critRow.fill:Hide()
        end
    else
        f.critRow:Hide()
    end
end

-------------------------------------------------------------------------------
--  Build Main Window
-------------------------------------------------------------------------------
function ns.BuildUI()
    if ns.frame then return end

    local totalRowsH       = (#ROWS * (ROW_H + ROW_GAP)) + SUBROW_H
    local totalRowsNoCritH = (#ROWS * (ROW_H + ROW_GAP)) - ROW_GAP
    local totalH           = HEADER_H + TAB_H + PAD + totalRowsH + PAD
    local totalNoCritH     = HEADER_H + TAB_H + PAD + totalRowsNoCritH + PAD

    local f = CreateFrame("Frame", "SatchelTrackerFrame", UIParent)
    f.fullHeight       = totalH
    f.fullHeightNoCrit = totalNoCritH
    f:SetSize(FRAME_W, totalNoCritH)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")

    -- Restore saved position
    local pos = ns.db and ns.db.pos
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 280, 0)
    end

    local function StartMove(frameToMove)
        if ns.db and not ns.db.locked then
            frameToMove:StartMoving()
        end
    end
    local function StopMove(frameToMove)
        frameToMove:StopMovingOrSizing()
        if ns.db then
            local point, _, relPoint, x, y = frameToMove:GetPoint(1)
            ns.db.pos = { point = point, relPoint = relPoint, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
        end
    end

    f:SetScript("OnDragStart", StartMove)
    f:SetScript("OnDragStop", StopMove)

    -- Main background & border
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.07, 0.09, 0.90)
    CreateBorder(f, 0.25, 0.28, 0.34, 0.9)

    ---------------------------------------------------------------------------
    --  Full Mode Root
    ---------------------------------------------------------------------------
    local fullRoot = CreateFrame("Frame", nil, f)
    fullRoot:SetAllPoints()
    f.fullRoot = fullRoot

    -- Header Bar
    local hdr = CreateFrame("Frame", nil, fullRoot)
    hdr:SetPoint("TOPLEFT", 1, -1)
    hdr:SetPoint("TOPRIGHT", -1, -1)
    hdr:SetHeight(HEADER_H)

    local hdrBg = hdr:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetAllPoints()
    hdrBg:SetColorTexture(0.11, 0.13, 0.17, 0.95)

    local hdrLine = hdr:CreateTexture(nil, "BORDER")
    hdrLine:SetPoint("BOTTOMLEFT")
    hdrLine:SetPoint("BOTTOMRIGHT")
    hdrLine:SetHeight(1)
    hdrLine:SetColorTexture(0.22, 0.25, 0.30, 0.9)

    local hdrIcon = hdr:CreateTexture(nil, "ARTWORK")
    hdrIcon:SetSize(15, 15)
    hdrIcon:SetPoint("LEFT", 6, 0)
    hdrIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_SatchelofCenarius")
    hdrIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", hdrIcon, "RIGHT", 5, 0)
    title:SetText("Satchel of Potions")
    title:SetTextColor(1, 0.85, 0.25)

    -- Reset button [R]
    local resetBtn = CreateFrame("Button", nil, hdr)
    resetBtn:SetSize(16, 18)
    resetBtn:SetPoint("RIGHT", -4, 0)
    resetBtn.label = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resetBtn.label:SetPoint("CENTER")
    resetBtn.label:SetText("|cff95a5a6R|r")
    resetBtn:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            ns.ResetOverall()
            ns.ResetSession()
            ns.Print("Overall, Session, and History stats reset.")
        else
            ns.ResetSession()
            ns.Print("Session stats reset. (Shift-click R to reset Overall stats.)")
        end
    end)
    resetBtn:SetScript("OnEnter", function(self)
        resetBtn.label:SetText("|cffffffffR|r")
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Reset Stats", 1, 0.84, 0.2)
        GameTooltip:AddLine("Left-Click: Reset Current Session", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Shift-Click: Reset Overall & History", 0.95, 0.45, 0.45)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function()
        resetBtn.label:SetText("|cff95a5a6R|r")
        GameTooltip:Hide()
    end)
    f.resetBtn = resetBtn

    -- Lock button [U/L]
    local lockBtn = CreateFrame("Button", nil, hdr)
    lockBtn:SetSize(16, 18)
    lockBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
    lockBtn.label = lockBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockBtn.label:SetPoint("CENTER")
    lockBtn:SetScript("OnClick", function()
        if not ns.db then return end
        ns.db.locked = not ns.db.locked
        ns.RefreshUI()
    end)
    lockBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(ns.db and ns.db.locked and "Window Locked" or "Window Unlocked", 1, 0.84, 0.2)
        GameTooltip:AddLine("Click to toggle window lock.", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    lockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.lockBtn = lockBtn

    -- Compact mode button [C]
    local compactBtn = CreateFrame("Button", nil, hdr)
    compactBtn:SetSize(16, 18)
    compactBtn:SetPoint("RIGHT", lockBtn, "LEFT", -2, 0)
    compactBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    compactBtn.label = compactBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    compactBtn.label:SetPoint("CENTER")
    compactBtn.label:SetText("|cff5dade2C|r")
    compactBtn:SetScript("OnClick", function(_, button)
        if not ns.db then return end
        if button == "RightButton" then
            ns.db.compactLayout = (ns.db.compactLayout == "vertical") and "horizontal" or "vertical"
        end
        ns.db.compact = true
        ns.RefreshUI()
    end)
    compactBtn:SetScript("OnEnter", function(self)
        compactBtn.label:SetText("|cffffffffC|r")
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Compact Mode", 1, 0.84, 0.2)
        GameTooltip:AddLine("Left-Click: Switch to Compact View", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-Click: Flip Horizontal / Vertical", 0.65, 0.68, 0.72)
        GameTooltip:Show()
    end)
    compactBtn:SetScript("OnLeave", function()
        compactBtn.label:SetText("|cff5dade2C|r")
        GameTooltip:Hide()
    end)
    f.compactBtn = compactBtn

    ---------------------------------------------------------------------------
    --  3-Tab Bar: [ Overall ] | [ Session ] | [ History ]
    ---------------------------------------------------------------------------
    local tabBar = CreateFrame("Frame", nil, fullRoot)
    tabBar:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
    tabBar:SetHeight(TAB_H)

    local tabW = math.floor((FRAME_W - 2) / 3)
    local function CreateTab(tabKey, idx)
        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetHeight(TAB_H)
        if idx == 1 then
            btn:SetPoint("TOPLEFT", tabBar, "TOPLEFT", 0, 0)
            btn:SetWidth(tabW)
        elseif idx == 2 then
            btn:SetPoint("TOPLEFT", tabBar, "TOPLEFT", tabW, 0)
            btn:SetWidth(tabW)
        else
            btn:SetPoint("TOPLEFT", tabBar, "TOPLEFT", tabW * 2, 0)
            btn:SetPoint("TOPRIGHT", tabBar, "TOPRIGHT", 0, 0)
        end

        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()

        btn.accent = btn:CreateTexture(nil, "ARTWORK")
        btn.accent:SetPoint("BOTTOMLEFT", 0, 0)
        btn.accent:SetPoint("BOTTOMRIGHT", 0, 0)
        btn.accent:SetHeight(2)
        btn.accent:SetColorTexture(1, 0.82, 0.18, 1)

        if idx > 1 then
            local div = btn:CreateTexture(nil, "BORDER")
            div:SetPoint("TOPLEFT", 0, 0)
            div:SetPoint("BOTTOMLEFT", 0, 0)
            div:SetWidth(1)
            div:SetColorTexture(0.22, 0.25, 0.30, 0.9)
        end

        btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.label:SetPoint("CENTER", 0, 1)

        btn:SetScript("OnClick", function()
            if ns.db then
                ns.db.activeTab = tabKey
                ns.RefreshUI()
            end
        end)
        return btn
    end

    f.tabs = {
        overall = CreateTab("overall", 1),
        session = CreateTab("session", 2),
        history = CreateTab("history", 3),
    }

    ---------------------------------------------------------------------------
    --  Stats Panel (Overall & Session rows)
    ---------------------------------------------------------------------------
    local statsPanel = CreateFrame("Frame", nil, fullRoot)
    statsPanel:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    statsPanel:SetPoint("BOTTOMRIGHT", fullRoot, "BOTTOMRIGHT", 0, 0)
    f.statsPanel = statsPanel

    f.rows = {}
    local yOffset = -PAD

    for _, rcfg in ipairs(ROWS) do
        local row = CreateFrame("Frame", nil, statsPanel)
        row:SetPoint("TOPLEFT", PAD - 1, yOffset)
        row:SetPoint("TOPRIGHT", -(PAD - 1), yOffset)
        row:SetHeight(ROW_H)

        local rbg = row:CreateTexture(nil, "BACKGROUND")
        rbg:SetAllPoints()
        rbg:SetColorTexture(0.12, 0.14, 0.18, 0.85)

        local fill = row:CreateTexture(nil, "BORDER")
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMLEFT", 1, 1)
        fill:SetWidth(1)
        fill:SetColorTexture(rcfg.color[1], rcfg.color[2], rcfg.color[3], 0.32)
        row.fill = fill

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", 4, 0)
        icon:SetTexture(rcfg.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon = icon

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        lbl:SetText(rcfg.label)
        lbl:SetTextColor(rcfg.color[1], rcfg.color[2], rcfg.color[3])
        row.label = lbl

        local val = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        val:SetPoint("RIGHT", -5, 0)
        val:SetJustifyH("RIGHT")
        row.value = val

        f.rows[rcfg.key] = row
        yOffset = yOffset - (ROW_H + ROW_GAP)
    end

    -- Damage Crits Sub-Row
    local critRow = CreateFrame("Frame", nil, statsPanel)
    critRow:SetPoint("TOPLEFT", PAD + 9, yOffset)
    critRow:SetPoint("TOPRIGHT", -(PAD - 1), yOffset)
    critRow:SetHeight(SUBROW_H)

    local cbg = critRow:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints()
    cbg:SetColorTexture(0.10, 0.09, 0.12, 0.85)

    local cfill = critRow:CreateTexture(nil, "BORDER")
    cfill:SetPoint("TOPLEFT", 1, -1)
    cfill:SetPoint("BOTTOMLEFT", 1, 1)
    cfill:SetWidth(1)
    cfill:SetColorTexture(1.0, 0.45, 0.35, 0.28)
    critRow.fill = cfill

    local clbl = critRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clbl:SetPoint("LEFT", 6, 0)
    clbl:SetText("Crits")
    clbl:SetTextColor(1.0, 0.55, 0.45)
    critRow.label = clbl

    local cval = critRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cval:SetPoint("RIGHT", -5, 0)
    cval:SetJustifyH("RIGHT")
    critRow.value = cval

    f.critRow = critRow

    ---------------------------------------------------------------------------
    --  History Panel (Recent Strip + Last Rolls List)
    ---------------------------------------------------------------------------
    local historyPanel = CreateFrame("Frame", nil, fullRoot)
    historyPanel:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    historyPanel:SetPoint("BOTTOMRIGHT", fullRoot, "BOTTOMRIGHT", 0, 0)
    historyPanel:Hide()
    f.historyPanel = historyPanel

    -- Top recent icon strip (newest on left, up to 8 icons)
    local stripFrame = CreateFrame("Frame", nil, historyPanel)
    stripFrame:SetPoint("TOPLEFT", PAD - 1, -PAD)
    stripFrame:SetPoint("TOPRIGHT", -(PAD - 1), -PAD)
    stripFrame:SetHeight(HIST_STRIP_H)

    local sbg = stripFrame:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    sbg:SetColorTexture(0.10, 0.12, 0.15, 0.85)

    local stripLbl = stripFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stripLbl:SetPoint("LEFT", 5, 0)
    stripLbl:SetText("Last:")
    stripLbl:SetTextColor(0.70, 0.74, 0.80)

    f.histIcons = {}
    for i = 1, 8 do
        local slot = CreateFrame("Frame", nil, stripFrame)
        slot:SetSize(16, 16)
        slot:SetPoint("LEFT", 36 + (i - 1) * 20, 0)
        slot.icon = slot:CreateTexture(nil, "ARTWORK")
        slot.icon:SetAllPoints()
        slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        slot.border = CreateBorder(slot, 1, 1, 1, 0.8)
        f.histIcons[i] = slot
    end

    -- Chronological rows below strip
    f.histRows = {}
    local hy = -(PAD + HIST_STRIP_H + 4)
    for i = 1, HIST_ROWS do
        local hrow = CreateFrame("Frame", nil, historyPanel)
        hrow:SetPoint("TOPLEFT", PAD - 1, hy)
        hrow:SetPoint("TOPRIGHT", -(PAD - 1), hy)
        hrow:SetHeight(HIST_ROW_H)

        local hrbg = hrow:CreateTexture(nil, "BACKGROUND")
        hrbg:SetAllPoints()
        hrbg:SetColorTexture(0.12, 0.14, 0.18, (i % 2 == 1) and 0.75 or 0.45)

        local hicon = hrow:CreateTexture(nil, "ARTWORK")
        hicon:SetSize(13, 13)
        hicon:SetPoint("LEFT", 4, 0)
        hicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        hrow.icon = hicon

        local ltxt = hrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ltxt:SetPoint("LEFT", hicon, "RIGHT", 5, 0)
        ltxt:SetJustifyH("LEFT")
        hrow.leftText = ltxt

        local rtxt = hrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rtxt:SetPoint("RIGHT", -5, 0)
        rtxt:SetJustifyH("RIGHT")
        rtxt:SetTextColor(0.60, 0.65, 0.72)
        hrow.rightText = rtxt

        f.histRows[i] = hrow
        hy = hy - (HIST_ROW_H + 2)
    end

    local histEmpty = historyPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    histEmpty:SetPoint("CENTER", 0, -8)
    histEmpty:SetText("No rolls recorded yet.")
    f.histEmpty = histEmpty

    ---------------------------------------------------------------------------
    --  Compact Mode Root (Horizontal or Vertical Icon + Number strip)
    ---------------------------------------------------------------------------
    local compactRoot = CreateFrame("Frame", nil, f)
    compactRoot:SetAllPoints()
    compactRoot:Hide()
    compactRoot:EnableMouse(true)
    compactRoot:RegisterForDrag("LeftButton")
    compactRoot:SetScript("OnDragStart", function() StartMove(f) end)
    compactRoot:SetScript("OnDragStop", function() StopMove(f) end)
    f.compactRoot = compactRoot

    f.compactCells = {}
    for _, rcfg in ipairs(ROWS) do
        local cell = CreateFrame("Frame", nil, compactRoot)
        cell:EnableMouse(true)
        cell:RegisterForDrag("LeftButton")
        cell:SetScript("OnDragStart", function() StartMove(f) end)
        cell:SetScript("OnDragStop", function() StopMove(f) end)

        local cbg2 = cell:CreateTexture(nil, "BACKGROUND")
        cbg2:SetAllPoints()
        cbg2:SetColorTexture(0.12, 0.14, 0.18, 0.85)

        local cicon = cell:CreateTexture(nil, "ARTWORK")
        cicon:SetSize(16, 16)
        cicon:SetPoint("LEFT", 3, 0)
        cicon:SetTexture(rcfg.icon)
        cicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        cell.icon = cicon

        local ctxt = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ctxt:SetPoint("LEFT", cicon, "RIGHT", 4, 0)
        ctxt:SetTextColor(rcfg.color[1], rcfg.color[2], rcfg.color[3])
        cell.text = ctxt

        cell:SetScript("OnEnter", function(self)
            local mode = (ns.db and ns.db.activeTab == "session") and "session" or "overall"
            local st = ns.GetStats(mode)
            local tot = ns.GetTotal(st)
            local cnt = st[rcfg.key] or 0
            local pct = (tot > 0) and (cnt / tot * 100) or 0
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(rcfg.label .. " (" .. (mode == "session" and "Session" or "Overall") .. ")", rcfg.color[1], rcfg.color[2], rcfg.color[3])
            GameTooltip:AddDoubleLine("Count:", string.format("%d (%.1f%%)", cnt, pct), 0.85, 0.85, 0.85, 1, 1, 1)
            local ovCrits = (ns.db and ns.db.overall and ns.db.overall.damageCrit) or 0
            if rcfg.key == "damage" and ovCrits > 0 then
                local crits = st.damageCrit or 0
                local cpct = (cnt > 0) and (crits / cnt * 100) or 0
                GameTooltip:AddDoubleLine("Crits:", string.format("%d (%.1f%%)", crits, cpct), 1, 0.55, 0.45, 1, 0.55, 0.45)
            end
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.compactCells[rcfg.key] = cell
    end

    -- Expand / Flip button in Compact Mode [+]
    local expandBtn = CreateFrame("Button", nil, compactRoot)
    expandBtn:SetSize(14, 14)
    expandBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    expandBtn.label = expandBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    expandBtn.label:SetPoint("CENTER")
    expandBtn.label:SetText("|cffffcc00+|r")
    expandBtn:SetScript("OnClick", function(_, button)
        if not ns.db then return end
        if button == "RightButton" then
            ns.db.compactLayout = (ns.db.compactLayout == "vertical") and "horizontal" or "vertical"
        else
            ns.db.compact = false
        end
        ns.RefreshUI()
    end)
    expandBtn:SetScript("OnEnter", function(self)
        expandBtn.label:SetText("|cffffffff+|r")
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Compact Controls", 1, 0.84, 0.2)
        GameTooltip:AddLine("Left-Click: Expand to Full Window", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-Click: Flip Horizontal / Vertical", 0.65, 0.68, 0.72)
        GameTooltip:Show()
    end)
    expandBtn:SetScript("OnLeave", function()
        expandBtn.label:SetText("|cffffcc00+|r")
        GameTooltip:Hide()
    end)
    f.compactExpandBtn = expandBtn

    ns.frame = f
    ns.BuildMinimapButton()
    ns.UpdateVisibility()
end

-------------------------------------------------------------------------------
--  Minimap Button
-------------------------------------------------------------------------------
local function PositionMinimapButton(btn)
    if not btn or not Minimap then return end
    if btn:GetParent() ~= Minimap then return end

    local angle = (ns.db and ns.db.minimap and ns.db.minimap.angle) or 205
    local rad = math.rad(angle)
    local radius = (Minimap:GetWidth() / 2) + 5
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function ns.UpdateMinimapButton()
    local btn = ns.minimapBtn
    if not btn or not ns.db then return end
    if ns.db.minimap and ns.db.minimap.hide then
        btn:Hide()
    else
        btn:Show()
        PositionMinimapButton(btn)
    end
end

function ns.BuildMinimapButton()
    if ns.minimapBtn or not Minimap then return end

    local btn = CreateFrame("Button", "LibDBIcon10_SatchelTracker", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    btn:RegisterForDrag("LeftButton")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_SatchelofCenarius")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    btn:SetScript("OnDragStart", function(self)
        if self:GetParent() ~= Minimap then return end
        self:SetScript("OnUpdate", function(b)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
            if ns.db and ns.db.minimap then
                ns.db.minimap.angle = angle
            end
            PositionMinimapButton(b)
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(_, button)
        if not ns.db then return end
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                ns.db.compact = not ns.db.compact
                ns.RefreshUI()
            else
                local shown = ns.frame and ns.frame:IsShown()
                ns.db.manualShow = not shown
                ns.UpdateVisibility()
            end
        elseif button == "MiddleButton" then
            ns.db.compact = not ns.db.compact
            ns.RefreshUI()
        elseif button == "RightButton" then
            if IsShiftKeyDown() then
                ns.ResetSession()
                ns.Print("Current Session stats reset.")
            else
                local cur = ns.db.activeTab or "overall"
                if cur == "overall" then
                    ns.db.activeTab = "session"
                elseif cur == "session" then
                    ns.db.activeTab = "history"
                else
                    ns.db.activeTab = "overall"
                end
                ns.RefreshUI()
            end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Satchel Tracker", 1, 0.85, 0.25)

        local ov = ns.GetStats("overall")
        local ss = ns.GetStats("session")
        local ovTotal = ns.GetTotal(ov)
        local ssTotal = ns.GetTotal(ss)

        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Overall Uses:", tostring(ovTotal), 0.85, 0.85, 0.85, 1, 1, 1)
        GameTooltip:AddDoubleLine("Session Uses:", tostring(ssTotal), 0.85, 0.85, 0.85, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffcc00Left-Click:|r Toggle Tracker Window", 0.75, 0.78, 0.82)
        GameTooltip:AddLine("|cffffcc00Shift + Left-Click:|r Toggle Compact Mode", 0.75, 0.78, 0.82)
        GameTooltip:AddLine("|cffffcc00Right-Click:|r Cycle Tabs (Overall / Session / History)", 0.75, 0.78, 0.82)
        GameTooltip:AddLine("|cffffcc00Shift + Right-Click:|r Reset Session", 0.75, 0.78, 0.82)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    ns.minimapBtn = btn
    ns.UpdateMinimapButton()
end
