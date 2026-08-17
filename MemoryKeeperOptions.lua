local frame = CreateFrame("Frame", "MemoryKeeperOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(430, 450)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

frame.TitleText:SetText("MemoryKeeper")

local subtitle = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
subtitle:SetPoint("TOPLEFT", 20, -45)
subtitle:SetText("Choose which milestones should trigger screenshots.")

local function MakeCheck(label, key, y)
    local cb = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 18, y)
    cb.Text:SetText(label)
    cb:SetChecked(MemoryKeeperDB[key])
    cb:SetScript("OnClick", function(self)
        MemoryKeeperDB[key] = self:GetChecked() and true or false
    end)
    return cb
end

MakeCheck("Achievements", "achievement", -80)
MakeCheck("Achievement criteria / steps", "criteria", -125)
MakeCheck("Boss kills", "boss", -170)
MakeCheck("Mythic+ completions", "mythicPlus", -215)
MakeCheck("Level ups", "levelUp", -260)
MakeCheck("PvP match completion", "pvp", -305)
MakeCheck("Reputation updates", "reputation", -350)

local note = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
note:SetPoint("BOTTOMLEFT", 20, 40)
note:SetWidth(390)
note:SetJustifyH("LEFT")
note:SetText("Screenshots are delayed slightly so Blizzard's achievement/criteria toast can appear on screen. A short cooldown prevents duplicate screenshots.")

local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
close:SetSize(100, 24)
close:SetPoint("BOTTOMRIGHT", -15, 10)
close:SetText(CLOSE)
close:SetScript("OnClick", function()
    frame:Hide()
end)

function MemoryKeeper_OpenOptions()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
