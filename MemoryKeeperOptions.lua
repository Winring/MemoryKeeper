local frame = CreateFrame("Frame", "MemoryKeeperOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(560, 520)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

frame.TitleText:SetText("MemoryKeeper")

local intro = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
intro:SetPoint("TOPLEFT", 20, -42)
intro:SetWidth(515)
intro:SetHeight(40)
intro:SetJustifyH("LEFT")
intro:SetText("Choose what MemoryKeeper should capture and whether its screenshot notifications should be silent.")

local headerType = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
headerType:SetPoint("TOPLEFT", 35, -92)
headerType:SetText("Screenshot type")

local headerSilent = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
headerSilent:SetPoint("TOPLEFT", 350, -92)
headerSilent:SetText("Notification")

local rowDefs = {
    { label = "Achievements", key = "achievement", silentKey = "silentAchievement" },
    { label = "Achievement criteria / steps", key = "criteria", silentKey = "silentCriteria" },
    { label = "Boss kills", key = "boss", silentKey = "silentBoss" },
    { label = "Mythic+ completions", key = "mythicPlus", silentKey = "silentMythicPlus" },
    { label = "Level ups", key = "levelUp", silentKey = "silentLevelUp" },
    { label = "PvP match completion", key = "pvp", silentKey = "silentPvP" },
    { label = "Reputation updates", key = "reputation", silentKey = "silentReputation" },
    { label = "In-game cinematic scenes", key = "cinematic", silentKey = "silentCinematic" },
}

local controls = {}
local rowSpacing = 36
local startY = -115

local ACTIVE_COLOR = {1, 0.82, 0}   -- gold-ish for active label
local DISABLED_COLOR = {0.5, 0.5, 0.5} -- grey for disabled label
local NORMAL_COLOR = {1, 0.82, 0}

local function setTextColor(fontString, color)
    if fontString and fontString.SetTextColor then
        fontString:SetTextColor(color[1], color[2], color[3])
    end
end

local function RefreshRow(row)
    local db = MemoryKeeperDB or {}
    local enabled = db[row.key] == true

    row.enable:SetChecked(enabled)
    row.silent:SetChecked(db[row.silentKey] == true)

    if enabled then
        row.silent:Enable()
        setTextColor(row.silent.Text, ACTIVE_COLOR)
    else
        row.silent:Disable()
        setTextColor(row.silent.Text, DISABLED_COLOR)
    end

    -- ensure enable label stays normal color
    setTextColor(row.enable.Text, NORMAL_COLOR)
end

for i, def in ipairs(rowDefs) do
    local y = startY - (i - 1) * rowSpacing
    local row = {}

    row.enable = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    row.enable:SetPoint("TOPLEFT", 24, y)
    row.enable.Text:SetText(def.label)

    row.silent = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    row.silent:SetPoint("TOPLEFT", 350, y)
    row.silent.Text:SetText("Silent")

    row.key = def.key
    row.silentKey = def.silentKey

    controls[i] = row

    row.enable:SetScript("OnClick", function(self)
        MemoryKeeperDB = MemoryKeeperDB or {}
        MemoryKeeperDB[row.key] = self:GetChecked() == true
        -- do not modify stored silent value here; keep it as user set
        RefreshRow(row)
    end)

    row.silent:SetScript("OnClick", function(self)
        MemoryKeeperDB = MemoryKeeperDB or {}
        -- only allow changing stored silent value when parent is enabled
        if MemoryKeeperDB[row.key] then
            MemoryKeeperDB[row.silentKey] = self:GetChecked() == true
        end
        RefreshRow(row)
    end)

    RefreshRow(row)
end

local note = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
note:SetPoint("BOTTOMLEFT", 20, 70)
note:SetWidth(515)
note:SetHeight(48)
note:SetJustifyH("LEFT")
note:SetText("")
note:SetText("Screenshots are delayed slightly so Blizzard's achievement/criteria toast can appear on screen. A short cooldown prevents duplicate screenshots.\nSilent means MemoryKeeper suppresses only the screenshot confirmation notification for that category.")

local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
close:SetSize(100, 24)
close:SetPoint("BOTTOMRIGHT", -15, 12)
close:SetText(CLOSE)
close:SetScript("OnClick", function()
    frame:Hide()
end)

frame:SetScript("OnShow", function()
    for _, row in ipairs(controls) do
        RefreshRow(row)
    end
end)

function MemoryKeeper_OpenOptions()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
