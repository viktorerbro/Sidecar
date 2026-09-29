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
local anchoringUIParent = false

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

local function IsInPanelSlot(frame)
    for _, area in ipairs({ "left", "center", "right", "doublewide", "fullscreen" }) do
        if GetUIPanel(area) == frame then return true end
    end
    return false
end

-- Blizzard closes whatever holds a UIPanel slot when another panel opens, so tracked panels give theirs up.
-- Editing UIPanelWindows would do the same but taints Forever's protected UI.
local function ReleasePanelSlot(frame)
    if not GetUIPanel or InCombatLockdown() or not IsInPanelSlot(frame) then return end
    HideUIPanel(frame, true)
    frame:Show()
end

local function PlaceShownFrames()
    for name in pairs(db.positions) do
        local frame = _G[name]
        if frame and frame:IsShown() then PlaceFrame(frame) end
    end
end

-- The scale the client would pick if the window were only the main monitor (0.64 is its floor when uiScale is off).
local function MainMonitorScale(mainHeight)
    if GetCVar("useUiScale") == "1" then
        return tonumber(GetCVar("uiScale")) or 1
    end
    return math.max(768 / mainHeight, 0.64)
end

local bubbleScale = 1
local correctedTextAnchors = setmetatable({}, { __mode = "k" })
local hookedBubbles = setmetatable({}, { __mode = "k" })

-- The game keeps anchoring the text to the speaker's head in WorldFrame units, which the bubble's scale would shrink
-- toward the screen's bottom-left, so each new anchor it writes is divided back out.
local function CorrectChatBubbleTextAnchor(content)
    local text = content.String
    local point, relativeTo, relativePoint, x, y = text:GetPoint(1)
    if relativeTo ~= WorldFrame then return end
    local corrected = correctedTextAnchors[text]
    if corrected and math.abs(corrected.x - x) < 0.01 and math.abs(corrected.y - y) < 0.01 then return end
    local scale = content:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
    corrected = corrected or {}
    corrected.x, corrected.y = x / scale, y / scale
    correctedTextAnchors[text] = corrected
    text:SetPoint(point, relativeTo, relativePoint, corrected.x, corrected.y)
end

-- Bubbles live under WorldFrame, which the client scales for the whole window's height, not UIParent's.
local function ScaleChatBubbles()
    if not C_ChatBubbles then return end
    for _, bubble in pairs(C_ChatBubbles.GetAllChatBubbles()) do
        local content = not bubble:IsForbidden() and bubble:GetChildren()
        if content and content.String and not content:IsForbidden() then
            if math.abs(content:GetScale() - bubbleScale) > 0.00001 then
                content:SetScale(bubbleScale)
            end
            if not hookedBubbles[content] then
                hookedBubbles[content] = true
                content:HookScript("OnUpdate", CorrectChatBubbleTextAnchor)
            end
            CorrectChatBubbleTextAnchor(content)
        end
    end
end

local scriptErrorsFrameCentered = false

-- The error frame has no parent, so it scales and centers on the whole window instead of the main monitor.
local function FitScriptErrorsFrame()
    if not ScriptErrorsFrame or ScriptErrorsFrame:IsForbidden() or InCombatLockdown() then return end
    ScriptErrorsFrame:SetScale(UIParent:GetEffectiveScale())
    if scriptErrorsFrameCentered then return end
    scriptErrorsFrameCentered = true
    ScriptErrorsFrame:ClearAllPoints()
    ScriptErrorsFrame:SetPoint("CENTER", UIParent, "CENTER")
end

-- Blizzard offsets the cursor from the window's bottom but anchors to UIParent's, which pushes context menus up.
local function AnchorRegionToCursorOnUIParent(region, point)
    if not IsConfigured() or region:IsForbidden() or GetAppropriateTopLevelParent() ~= UIParent then return end
    local x, y = InputUtil.GetCursorPosition(UIParent)
    region:ClearAllPoints()
    region:SetPoint(point, UIParent, "BOTTOMLEFT", x - UIParent:GetLeft(), y - UIParent:GetBottom())
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
    local mainHeight = db.mainHeight or physH
    -- The client scales for the whole window's height, which blows the HUD up when the other monitor is taller.
    local scale = MainMonitorScale(mainHeight) * mainHeight / physH
    if math.abs(UIParent:GetScale() - scale) > 0.00001 then
        UIParent:SetScale(scale)
    end

    local unitsPerPixel = 768 / (physH * scale)
    local left = db.side == "left" and (physW - db.mainWidth) * unitsPerPixel or 0

    anchoringUIParent = true
    UIParent:ClearAllPoints()
    UIParent:SetPoint("TOPLEFT", nil, "TOPLEFT", left, -(db.mainTop or 0) * unitsPerPixel)
    UIParent:SetSize(db.mainWidth * unitsPerPixel, mainHeight * unitsPerPixel)
    anchoringUIParent = false

    WorldFrame:ClearAllPoints()
    WorldFrame:SetAllPoints(UIParent)

    -- WorldFrame's effective scale is 1, so this makes bubbles follow the UI scale like the rest of the HUD.
    bubbleScale = scale
    ScaleChatBubbles()
    FitScriptErrorsFrame()
    PlaceShownFrames()
end

local function PointPosition(left, bottom, width, height, point)
    local x = point:find("LEFT") and left or point:find("RIGHT") and left + width or left + width / 2
    local y = point:find("BOTTOM") and bottom or point:find("TOP") and bottom + height or bottom + height / 2
    return x, y
end

-- StopMovingOrSizing can anchor to the screen, and Edit Mode then reuses those offsets against UIParent, which no
-- longer covers the screen. Re-anchoring to UIParent in place hands Edit Mode offsets it can save as they are.
local function AnchorToUIParentInPlace(frame)
    -- Edit Mode also calls StopMovingOrSizing on every system when it closes; only a drop has isDragging still set.
    if not IsConfigured() or frame:IsForbidden() or InCombatLockdown() or not frame.isDragging then return end
    local point, _, relativePoint = frame:GetPoint(1)
    if not point or not frame:GetLeft() then return end
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local x, y = PointPosition(frame:GetLeft(), frame:GetBottom(), frame:GetWidth(), frame:GetHeight(), point)
    local left, bottom, width, height = UIParent:GetRect()
    local parentX, parentY = PointPosition(left * ratio, bottom * ratio, width * ratio, height * ratio, relativePoint)
    frame:ClearAllPoints()
    frame:SetPoint(point, UIParent, relativePoint, x - parentX, y - parentY)
end

-- Some Edit Mode offsets are measured from the screen's bottom-left but saved against UIParent's, which sits higher
-- when the other monitor is taller.
local function ShiftAnchorByUIParentOrigin(frame, shiftX, shiftY)
    local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
    local scale = frame:GetScale()
    frame:ClearAllPoints()
    frame:SetPoint(point, relativeTo, relativePoint,
        x - (shiftX and UIParent:GetLeft() / scale or 0), y - (shiftY and UIParent:GetBottom() / scale or 0))
end

local function CorrectGridLineSnap(frame, frameInfo)
    -- LEFT and BOTTOM grid line snaps carry the line's screen position as their offset; every other snap is relative.
    if not IsConfigured() or InCombatLockdown() or frameInfo.frame ~= UIParent or frameInfo.offset == 0 then return end
    if frameInfo.point == "LEFT" then
        ShiftAnchorByUIParentOrigin(frame, true, false)
    elseif frameInfo.point == "BOTTOM" then
        ShiftAnchorByUIParentOrigin(frame, false, true)
    end
end

local correctingAnchor = false

-- BreakFrameSnap (arrow key nudges, saving buffs) saves right after its SetPoint, so only a SetPoint hook runs in time.
local function CorrectBreakFrameSnapAnchor(frame)
    if correctingAnchor or not IsConfigured() or InCombatLockdown() then return end
    local point, relativeTo, relativePoint = frame:GetPoint(1)
    if relativeTo ~= UIParent or point ~= relativePoint or (point ~= "TOPLEFT" and point ~= "TOPRIGHT") then return end
    if not debugstack(2, 4, 0):find("BreakFrameSnap") then return end
    correctingAnchor = true
    ShiftAnchorByUIParentOrigin(frame, true, true)
    correctingAnchor = false
end

local hookedEditModeFrames = {}

local function HookEditModeFrames()
    for _, frame in ipairs(EditModeManagerFrame.registeredSystemFrames) do
        if not hookedEditModeFrames[frame] then
            hookedEditModeFrames[frame] = true
            hooksecurefunc(frame, "StopMovingOrSizing", AnchorToUIParentInPlace)
            hooksecurefunc(frame, "SnapToFrame", CorrectGridLineSnap)
            hooksecurefunc(frame, "SetPoint", CorrectBreakFrameSnapAnchor)
        end
    end
end

local function SavePosition(frame)
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local edgeX = db.side == "left" and UIParent:GetLeft() or UIParent:GetRight()
    db.positions[frame:GetName()] = {
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
    ReleasePanelSlot(frame)
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

local function SetMain(width, height, side, top)
    local physW, physH = GetPhysicalScreenSize()
    if not width or width <= 0 or width >= physW or not height or height <= 0 or height > physH
        or (side ~= "left" and side ~= "right") or not top or top < 0 or top + height > physH then
        return false
    end
    db.mainWidth, db.mainHeight, db.side, db.mainTop = width, height, side, top
    ApplyLayout()
    return true
end

local function NativeSize(monitor)
    local ok, sizes = pcall(C_VideoOptions.GetGameWindowSizes, monitor, true)
    if not ok or type(sizes) ~= "table" then return nil end
    local best
    for _, size in ipairs(sizes) do
        if not best or size.x * size.y > best.x * best.y then best = size end
    end
    return best
end

-- WoW can't see how Windows arranges the monitors, only their sizes, so side and alignment stay the user's call.
local function DetectMainSize()
    if not (C_VideoOptions and C_VideoOptions.GetGameWindowSizes and GetMonitorCount) then
        return nil, "this client can't list monitors"
    end
    local physW, physH = GetPhysicalScreenSize()
    local sizes, found = {}, {}
    for i = 0, GetMonitorCount() do
        local size = NativeSize(i)
        if size and size.x < physW and size.y <= physH then
            sizes[i] = size
            tinsert(found, ("%dx%d"):format(size.x, size.y))
        end
    end
    local report = "monitors: " .. (#found > 0 and table.concat(found, ", ") or "none")
    local preferred = sizes[tonumber(GetCVar("gxMonitor")) or 0]
    for _, size in pairs(sizes) do
        for _, other in pairs(sizes) do
            -- Side by side, the two widths fill the window; prefer the monitor the game was started on.
            if size ~= other and size.x + other.x == physW and (not preferred or preferred == size) then
                return size, report
            end
        end
    end
    return preferred, report
end

local menu

local function CreateMenu()
    local f = CreateFrame("Frame", "SidecarMenu", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(320, 250)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "SidecarMenu")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Sidecar")

    local function Label(text, x, y)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText(text)
    end

    local function NumberBox(x, y)
        local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        box:SetSize(50, 20)
        box:SetPoint("TOPLEFT", x, y)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            f.apply()
        end)
        return box
    end

    local function Button(text, width, x, y, onClick)
        local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        button:SetSize(width, 22)
        button:SetPoint("TOPLEFT", x, y)
        button:SetText(text)
        button:SetScript("OnClick", onClick)
        return button
    end

    Label("Main monitor", 16, -36)
    f.width = NumberBox(130, -32)
    Label("x", 186, -36)
    f.height = NumberBox(204, -32)
    Label("Px from top", 16, -62)
    f.top = NumberBox(130, -58)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("BOTTOMLEFT", 16, 14)
    status:SetPoint("BOTTOMRIGHT", -16, 14)
    status:SetJustifyH("LEFT")
    f.status = status

    f.side = db.side or "right"
    f.apply = function()
        local width, height, top = tonumber(f.width:GetText()), tonumber(f.height:GetText()), tonumber(f.top:GetText())
        if SetMain(width, height, f.side, top) then
            status:SetText(("Main %dx%d, %d px from top, second monitor %s."):format(width, height, top, f.side))
            return
        end
        local physW, physH = GetPhysicalScreenSize()
        status:SetText(("Doesn't fit the %dx%d window."):format(physW, physH))
    end

    local function Align(fraction)
        local _, physH = GetPhysicalScreenSize()
        local height = tonumber(f.height:GetText()) or physH
        f.top:SetText(math.floor((physH - height) * fraction + 0.5))
        f.apply()
    end

    local function SetSide(side)
        f.side = side
        f.apply()
    end

    Label("Second monitor", 16, -92)
    Button("Left", 60, 130, -88, function() SetSide("left") end)
    Button("Right", 60, 196, -88, function() SetSide("right") end)
    Label("Align", 16, -120)
    Button("Top", 50, 130, -116, function() Align(0) end)
    Button("Middle", 56, 182, -116, function() Align(0.5) end)
    Button("Bottom", 56, 240, -116, function() Align(1) end)

    Button("Detect", 80, 16, -150, function()
        local size, report = DetectMainSize()
        if not size then
            status:SetText("Couldn't detect (" .. report .. "). Type the size in.")
            return
        end
        f.width:SetText(size.x)
        f.height:SetText(size.y)
        Align(0.5)
        status:SetText(status:GetText() .. "\n" .. report .. ". Now pick side and align.")
    end)
    Button("Apply", 80, 104, -150, function() f.apply() end)
    f.unlock = Button("Unlock panels", 100, 16, -178, function()
        SetUnlocked(not unlocked)
        f.unlock:SetText(unlocked and "Lock panels" or "Unlock panels")
    end)
    Button("Off", 60, 124, -178, function()
        db.mainWidth = nil
        ReloadUI()
    end)

    f:SetScript("OnShow", function()
        local physW, physH = GetPhysicalScreenSize()
        f.width:SetText(db.mainWidth or "")
        f.height:SetText(db.mainHeight or physH)
        f.top:SetText(db.mainTop or 0)
        f.side = db.side or "right"
        f.unlock:SetText(unlocked and "Lock panels" or "Unlock panels")
        status:SetText(("Window is %dx%d."):format(physW, physH))
    end)
    f:Hide()
    return f
end

local function ToggleMenu()
    menu = menu or CreateMenu()
    menu:SetShown(not menu:IsShown())
end

local function OnTrackedShow(frame)
    PlaceFrame(frame)
    -- Some panels anchor themselves after OnShow, and ShowUIPanel only claims the slot after it; act once they're done.
    C_Timer.After(0, function()
        PlaceFrame(frame)
        ReleasePanelSlot(frame)
    end)
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
    local physW, physH = GetPhysicalScreenSize()
    local main = db.mainWidth and ("%dx%d px, %d px from the top"):format(db.mainWidth, db.mainHeight or physH, db.mainTop or 0)
    Print(("window is %dx%d px, main monitor %s, second monitor on the %s."):format(
        physW, physH, main or "not set", db.side or "?"))
    Print("/sc - open the settings menu")
    Print("/sidecar main <width> <height> <left|right: side the second monitor is on> [px from window top to main monitor top]")
    Print("/sidecar unlock | lock - drag tracked panels between monitors")
    Print("/sidecar grab - track the panel under the mouse")
    Print("/sidecar reset - forget all panel positions")
    Print("/sidecar off - give UIParent the whole window back (reloads)")
end

SLASH_SIDECAR1 = "/sidecar"
SLASH_SIDECAR2 = "/sc"
SlashCmdList.SIDECAR = function(msg)
    local cmd, arg1, arg2, arg3, arg4 = strsplit(" ", strtrim(msg):lower())

    if cmd == "" then
        ToggleMenu()
        return
    end
    if cmd == "main" then
        if not SetMain(tonumber(arg1), tonumber(arg2), arg3, tonumber(arg4 or "0")) then PrintHelp() end
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
-- There is no bubble-created event; bubbles are pooled, so each new one shows up with the chat that makes it.
local bubbleEvents = {
    CHAT_MSG_SAY = true, CHAT_MSG_YELL = true, CHAT_MSG_PARTY = true, CHAT_MSG_PARTY_LEADER = true,
    CHAT_MSG_MONSTER_SAY = true, CHAT_MSG_MONSTER_YELL = true, CHAT_MSG_MONSTER_PARTY = true,
}
for event in pairs(bubbleEvents) do
    events:RegisterEvent(event)
end
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
        if arg == "Blizzard_ScriptErrorsFrame" and IsConfigured() then FitScriptErrorsFrame() end
        return
    end
    if event == "PLAYER_LOGIN" then
        for _, name in ipairs({ "UpdateUIPanelPositions", "UpdateContainerFrameAnchors" }) do
            if _G[name] then hooksecurefunc(name, PlaceShownFrames) end
        end
        -- UpdateUIParentPosition puts UIParent's TOPLEFT back on the window's corner on every loading screen. Hooking the
        -- SetPoint inside it fixes that before Edit Mode's hooks on UpdateUIParentPosition cache UIParent's rect for snapping.
        hooksecurefunc(UIParent, "SetPoint", function()
            if not anchoringUIParent then ApplyLayout() end
        end)
        -- Systems from load-on-demand addons register late, so catch them each time Edit Mode opens.
        if EditModeManagerFrame then hooksecurefunc(EditModeManagerFrame, "EnterEditMode", HookEditModeFrames) end
        if InputUtil and InputUtil.AnchorRegionToCursor then
            hooksecurefunc(InputUtil, "AnchorRegionToCursor", AnchorRegionToCursorOnUIParent)
        end
        ApplyLayout()
        if not IsConfigured() then
            Print("not set up yet, type /sc")
        end
        return
    end
    if bubbleEvents[event] then
        if IsConfigured() then C_Timer.After(0, ScaleChatBubbles) end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        SetUnlocked(false)
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if layoutPending then ApplyLayout() end
        PlaceShownFrames()
        for frame in pairs(hooked) do
            if frame:IsShown() then ReleasePanelSlot(frame) end
        end
        return
    end
    ApplyLayout()
end)
