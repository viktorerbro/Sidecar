local ADDON = ...

local DEFAULT_FRAMES = {
    "WorldMapFrame", "CharacterFrame", "QuestLogFrame", "ContainerFrameCombinedBags",
    "ContainerFrame1", "ContainerFrame2", "ContainerFrame3", "ContainerFrame4", "ContainerFrame5", "ContainerFrame6",
}

local db
local hooked = {}
local overlays = {}
local unlocked = false
local dragging = nil
local layoutPending = false

local function Print(msg)
    print("|cff33aaffSidecar|r: " .. msg)
end

local function IsConfigured()
    return db.mainWidth ~= nil and db.mainWidth < GetPhysicalScreenSize()
end

local function CanMove(frame)
    if frame:IsForbidden() then return false end
    return not (InCombatLockdown() and frame:IsProtected())
end

local function OffhandEdge()
    return db.side == "left" and "TOPLEFT" or "TOPRIGHT"
end

local function PlaceFrame(frame)
    local pos = db.positions[frame:GetName()]
    if not pos or not IsConfigured() or not CanMove(frame) then return end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, OffhandEdge(), pos.x, pos.y)
end

local function PlaceShownFrames()
    for name in pairs(db.positions) do
        local frame = _G[name]
        if frame and frame:IsShown() then PlaceFrame(frame) end
    end
end

-- Edit Mode and other addons lay out against UIParent, so UIParent itself must cover only the main monitor.
local function ApplyLayout()
    if not IsConfigured() then return end
    if InCombatLockdown() then
        layoutPending = true
        return
    end
    layoutPending = false

    local physW, physH = GetPhysicalScreenSize()
    local unitsPerPixel = UIParent:GetHeight() / physH
    local left = db.side == "left" and (physW - db.mainWidth) * unitsPerPixel or 0

    UIParent:ClearAllPoints()
    UIParent:SetPoint("TOPLEFT", nil, "TOPLEFT", left, 0)
    UIParent:SetPoint("BOTTOMLEFT", nil, "BOTTOMLEFT", left, 0)
    UIParent:SetWidth(db.mainWidth * unitsPerPixel)

    WorldFrame:ClearAllPoints()
    WorldFrame:SetAllPoints(UIParent)

    PlaceShownFrames()
end

local function SavePosition(frame)
    local name = frame:GetName()
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local centerX = frame:GetCenter() / ratio
    if centerX >= UIParent:GetLeft() and centerX <= UIParent:GetRight() then
        db.positions[name] = nil
        Print(name .. " is back on the main monitor.")
        return
    end
    local edgeX = db.side == "left" and UIParent:GetLeft() or UIParent:GetRight()
    db.positions[name] = {
        x = frame:GetLeft() - edgeX * ratio,
        y = frame:GetTop() - UIParent:GetTop() * ratio,
    }
end

local function StartDrag(frame)
    if not IsConfigured() or not CanMove(frame) then return end
    dragging = frame
    frame:SetMovable(true)
    frame:StartMoving()
end

local function StopDrag(frame)
    if dragging ~= frame then return end
    dragging = nil
    frame:StopMovingOrSizing()
    -- Otherwise layout-local.txt restores it too and fights our anchor.
    frame:SetUserPlaced(false)
    SavePosition(frame)
    PlaceFrame(frame)
end

local function ShowOverlay(frame)
    local overlay = overlays[frame]
    if not overlay then
        overlay = CreateFrame("Frame", nil, frame)
        overlay:SetAllPoints()
        overlay:SetFrameStrata("FULLSCREEN_DIALOG")
        overlay:EnableMouse(true)
        overlay:RegisterForDrag("LeftButton")
        local tint = overlay:CreateTexture(nil, "BACKGROUND")
        tint:SetAllPoints()
        tint:SetColorTexture(0.2, 0.6, 1, 0.35)
        local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("CENTER")
        label:SetText(frame:GetName())
        overlay:SetScript("OnDragStart", function() StartDrag(frame) end)
        overlay:SetScript("OnDragStop", function() StopDrag(frame) end)
        overlays[frame] = overlay
    end
    overlay:Show()
end

local function SetUnlocked(value)
    if value and InCombatLockdown() then
        Print("can't unlock in combat.")
        return
    end
    unlocked = value
    for frame in pairs(hooked) do
        if value and frame:IsShown() then
            ShowOverlay(frame)
        elseif overlays[frame] then
            overlays[frame]:Hide()
        end
    end
end

local function OnTrackedShow(frame)
    PlaceFrame(frame)
    -- Some panels anchor themselves after OnShow; place again once they're done.
    C_Timer.After(0, function() PlaceFrame(frame) end)
    if unlocked then ShowOverlay(frame) end
end

local function HookFrame(frame)
    if hooked[frame] or type(frame) ~= "table" or not frame.HookScript then return end
    hooked[frame] = true
    frame:HookScript("OnShow", OnTrackedShow)
end

local function HookTrackedFrames()
    for _, name in ipairs(DEFAULT_FRAMES) do
        if _G[name] then HookFrame(_G[name]) end
    end
    for name in pairs(db.extraFrames) do
        if _G[name] then HookFrame(_G[name]) end
    end
end

local function PanelUnderMouse()
    local focus = GetMouseFoci and GetMouseFoci()[1] or GetMouseFocus and GetMouseFocus()
    while focus and focus:GetParent() and focus:GetParent() ~= UIParent do
        focus = focus:GetParent()
    end
    if focus == nil or focus == WorldFrame or focus == UIParent then return nil end
    return focus
end

local function PrintHelp()
    local physW = GetPhysicalScreenSize()
    Print(("window is %d px wide, main monitor %s, second monitor on the %s."):format(
        physW, db.mainWidth and (db.mainWidth .. " px") or "not set", db.side or "?"))
    Print("/sidecar main <main monitor width px> <left|right: side the second monitor is on>")
    Print("/sidecar unlock | lock - drag tracked panels between monitors")
    Print("/sidecar grab - track the panel under the mouse")
    Print("/sidecar reset - forget all panel positions")
    Print("/sidecar off - give UIParent the whole window back (reloads)")
end

SLASH_SIDECAR1 = "/sidecar"
SlashCmdList.SIDECAR = function(msg)
    local cmd, arg1, arg2 = strsplit(" ", strtrim(msg):lower())

    if cmd == "main" then
        local width = tonumber(arg1)
        if not width or width <= 0 or width >= GetPhysicalScreenSize() or (arg2 ~= "left" and arg2 ~= "right") then
            PrintHelp()
            return
        end
        db.mainWidth, db.side = width, arg2
        ApplyLayout()
        return
    end
    if cmd == "unlock" then
        SetUnlocked(true)
        return
    end
    if cmd == "lock" then
        SetUnlocked(false)
        return
    end
    if cmd == "grab" then
        local panel = PanelUnderMouse()
        if not panel or not panel:GetName() then
            Print("no named panel under the mouse.")
            return
        end
        db.extraFrames[panel:GetName()] = true
        HookFrame(panel)
        if unlocked then ShowOverlay(panel) end
        Print("tracking " .. panel:GetName() .. ".")
        return
    end
    if cmd == "reset" then
        wipe(db.positions)
        Print("positions cleared; panels go back to Blizzard's spots next time they open.")
        return
    end
    if cmd == "off" then
        db.mainWidth = nil
        ReloadUI()
        return
    end
    PrintHelp()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg == ADDON then
            SidecarDB = SidecarDB or {}
            db = SidecarDB
            db.positions = db.positions or {}
            db.extraFrames = db.extraFrames or {}
        end
        -- Load-on-demand panels only exist once their Blizzard addon loads.
        if db then HookTrackedFrames() end
        return
    end
    if event == "PLAYER_LOGIN" then
        for _, name in ipairs({ "UpdateUIPanelPositions", "UpdateContainerFrameAnchors" }) do
            if _G[name] then hooksecurefunc(name, PlaceShownFrames) end
        end
        ApplyLayout()
        if not IsConfigured() then
            Print("not set up yet, type /sidecar")
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        SetUnlocked(false)
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if layoutPending then ApplyLayout() end
        PlaceShownFrames()
        return
    end
    ApplyLayout()
end)
