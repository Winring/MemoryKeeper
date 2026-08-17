local ADDON_NAME = "MemoryKeeper"
local addon = CreateFrame("Frame")
local pendingTimers = {}
local lastScreenshotTime = 0
local recentCriteria = {}
local recentAchievements = {}

MemoryKeeperDB = MemoryKeeperDB or {}

local defaults = {
    achievement = true,
    criteria = true,
    boss = true,
    mythicPlus = true,
    levelUp = true,
    pvp = false,
    reputation = false,
    screenshotDelay = 0.8,
    cooldown = 2.0,
    debug = false,
}

local function CopyDefaults(target, source)
    for k, v in pairs(source) do
        if target[k] == nil then
            target[k] = v
        end
    end
end

CopyDefaults(MemoryKeeperDB, defaults)

local function Debug(msg)
    if MemoryKeeperDB.debug then
        print("|cff66ccffMemoryKeeper|r:", msg)
    end
end

local function CanScreenshot()
    return (GetTime() - lastScreenshotTime) >= (MemoryKeeperDB.cooldown or 2.0)
end

local function DoScreenshot(reason)
    if not CanScreenshot() then
        Debug("Screenshot skipped due to cooldown: " .. tostring(reason))
        return
    end

    lastScreenshotTime = GetTime()
    Screenshot()
    Debug("Screenshot: " .. tostring(reason))
end

local function QueueScreenshot(reason, delay)
    delay = delay or MemoryKeeperDB.screenshotDelay or 0.8

    -- Cancel an existing pending timer for the same general burst.
    for i = #pendingTimers, 1, -1 do
        if pendingTimers[i] and pendingTimers[i].Cancel then
            pendingTimers[i]:Cancel()
        end
        table.remove(pendingTimers, i)
    end

    local timer = C_Timer.NewTimer(delay, function()
        DoScreenshot(reason)
    end)
    table.insert(pendingTimers, timer)
end

local function IsNewAchievement(id)
    if not id then return true end
    if recentAchievements[id] and (GetTime() - recentAchievements[id]) < 3 then
        return false
    end
    recentAchievements[id] = GetTime()
    return true
end

local function IsNewCriteria(id)
    if not id then return true end
    if recentCriteria[id] and (GetTime() - recentCriteria[id]) < 3 then
        return false
    end
    recentCriteria[id] = GetTime()
    return true
end

addon:RegisterEvent("ADDON_LOADED")
addon:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        CopyDefaults(MemoryKeeperDB, defaults)

        self:RegisterEvent("ACHIEVEMENT_EARNED")
        self:RegisterEvent("CRITERIA_EARNED")
        self:RegisterEvent("ENCOUNTER_END")
        self:RegisterEvent("CHALLENGE_MODE_COMPLETED")
        self:RegisterEvent("PLAYER_LEVEL_UP")
        self:RegisterEvent("PVP_MATCH_COMPLETE")
        self:RegisterEvent("UPDATE_FACTION")

        print("|cff66ccffMemoryKeeper|r loaded. Type |cffffff00/memorykeeper|r for options.")
        return
    end

    if event == "ACHIEVEMENT_EARNED" then
        if not MemoryKeeperDB.achievement then return end
        local achievementID = ...
        if not IsNewAchievement(achievementID) then return end

        -- Prefer the full achievement toast over a criterion toast
        -- if both events are generated for the same action.
        QueueScreenshot("Achievement " .. tostring(achievementID), MemoryKeeperDB.screenshotDelay)
        return
    end

    if event == "CRITERIA_EARNED" then
        if not MemoryKeeperDB.criteria then return end
        local criteriaID = ...
        if not IsNewCriteria(criteriaID) then return end

        QueueScreenshot("Achievement criterion " .. tostring(criteriaID), math.min(MemoryKeeperDB.screenshotDelay, 0.6))
        return
    end

    if event == "ENCOUNTER_END" then
        if not MemoryKeeperDB.boss then return end
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        if success == 1 then
            QueueScreenshot("Boss kill: " .. tostring(encounterName), MemoryKeeperDB.screenshotDelay)
        end
        return
    end

    if event == "CHALLENGE_MODE_COMPLETED" then
        if not MemoryKeeperDB.mythicPlus then return end
        QueueScreenshot("Mythic+ completed", MemoryKeeperDB.screenshotDelay)
        return
    end

    if event == "PLAYER_LEVEL_UP" then
        if not MemoryKeeperDB.levelUp then return end
        local level = ...
        QueueScreenshot("Level " .. tostring(level), MemoryKeeperDB.screenshotDelay)
        return
    end

    if event == "PVP_MATCH_COMPLETE" then
        if not MemoryKeeperDB.pvp then return end
        QueueScreenshot("PvP match complete", MemoryKeeperDB.screenshotDelay)
        return
    end

    if event == "UPDATE_FACTION" then
        -- This event fires frequently, so reputation screenshots are intentionally
        -- opt-in and debounced by the normal screenshot cooldown.
        if not MemoryKeeperDB.reputation then return end
        QueueScreenshot("Reputation update", MemoryKeeperDB.screenshotDelay)
        return
    end
end)

SLASH_MEMORYKEEPER1 = "/memorykeeper"
SLASH_MEMORYKEEPER2 = "/mk"

SlashCmdList.MEMORYKEEPER = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "on" then
        MemoryKeeperDB.achievement = true
        MemoryKeeperDB.criteria = true
        print("|cff66ccffMemoryKeeper|r: achievement and criterion screenshots enabled.")
    elseif msg == "off" then
        MemoryKeeperDB.achievement = false
        MemoryKeeperDB.criteria = false
        print("|cff66ccffMemoryKeeper|r: achievement and criterion screenshots disabled.")
    elseif msg == "status" then
        print("|cff66ccffMemoryKeeper|r status:")
        print("  Achievements:", MemoryKeeperDB.achievement and "ON" or "OFF")
        print("  Criteria:", MemoryKeeperDB.criteria and "ON" or "OFF")
        print("  Bosses:", MemoryKeeperDB.boss and "ON" or "OFF")
        print("  Mythic+:", MemoryKeeperDB.mythicPlus and "ON" or "OFF")
        print("  Level up:", MemoryKeeperDB.levelUp and "ON" or "OFF")
        print("  PvP:", MemoryKeeperDB.pvp and "ON" or "OFF")
        print("  Reputation:", MemoryKeeperDB.reputation and "ON" or "OFF")
    elseif msg == "debug" then
        MemoryKeeperDB.debug = not MemoryKeeperDB.debug
        print("|cff66ccffMemoryKeeper|r debug:", MemoryKeeperDB.debug and "ON" or "OFF")
    else
        if MemoryKeeper_OpenOptions then
            MemoryKeeper_OpenOptions()
        end
    end
end
