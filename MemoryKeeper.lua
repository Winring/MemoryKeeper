local ADDON_NAME = "MemoryKeeper"
local addon = CreateFrame("Frame")
local pendingTimers = {}
local lastScreenshotTime = {}
local recentCriteria = {}
local recentAchievements = {}
local cinematicActive = false
local cinematicToken = 0
local cinematicTicker = nil

MemoryKeeperDB = MemoryKeeperDB or {}

local defaults = {
    achievement = true,
    criteria = true,
    boss = true,
    mythicPlus = true,
    levelUp = true,
    pvp = false,
    reputation = false,
    cinematic = true,
    screenshotDelay = 0.8,
    cooldown = 2.0,
    debug = false,

    -- Per-category screenshot notification behavior.
    -- false = normal "Screenshot taken" notification, true = silent.
    silentAchievement = false,
    silentCriteria = false,
    silentBoss = false,
    silentMythicPlus = false,
    silentLevelUp = false,
    silentPvP = false,
    silentReputation = false,
    silentCinematic = true,
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

local function CanScreenshot(category)
    category = category or "general"
    local lastTime = lastScreenshotTime[category] or 0
    return (GetTime() - lastTime) >= (MemoryKeeperDB.cooldown or 2.0)
end

local function DoScreenshot(reason, silent, category)
    category = category or "general"

    if not CanScreenshot(category) then
        Debug("Screenshot skipped due to cooldown: " .. tostring(reason))
        return
    end

    lastScreenshotTime[category] = GetTime()

    if silent and ActionStatus and ActionStatus.UnregisterEvent then
        ActionStatus:UnregisterEvent("SCREENSHOT_SUCCEEDED")
        Screenshot()
        ActionStatus:RegisterEvent("SCREENSHOT_SUCCEEDED")
    else
        Screenshot()
    end

    Debug("Screenshot: " .. tostring(reason) .. " (category=" .. tostring(category) .. ", silent=" .. tostring(silent) .. ")")
end

local function CancelPendingTimer(category)
    local timer = pendingTimers[category]
    if timer and timer.Cancel then
        timer:Cancel()
    end
    pendingTimers[category] = nil
end

local function QueueScreenshot(reason, delay, silent, category)
    category = category or "general"
    delay = delay or MemoryKeeperDB.screenshotDelay or 0.8

    -- Only replace a pending screenshot from the same category.
    -- Different event types must never cancel each other.
    CancelPendingTimer(category)

    local timer = C_Timer.NewTimer(delay, function()
        pendingTimers[category] = nil
        DoScreenshot(reason, silent, category)
    end)
    pendingTimers[category] = timer
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
        self:RegisterEvent("FACTION_STANDING_CHANGED")
        self:RegisterEvent("MAJOR_FACTION_RENOWN_LEVEL_CHANGED")
        self:RegisterEvent("COVENANT_SANCTUM_RENOWN_LEVEL_CHANGED")
        self:RegisterEvent("CINEMATIC_START")
        self:RegisterEvent("CINEMATIC_STOP")

        print("|cff66ccffMemoryKeeper|r loaded. Type |cffffff00/memorykeeper|r for options.")
        return
    end

    if event == "ACHIEVEMENT_EARNED" then
        if not MemoryKeeperDB.achievement then return end
        local achievementID = ...
        if not IsNewAchievement(achievementID) then return end

        QueueScreenshot("Achievement " .. tostring(achievementID), MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentAchievement, "achievement")
        return
    end

    if event == "CRITERIA_EARNED" then
        if not MemoryKeeperDB.criteria then return end
        local criteriaID = ...
        if not IsNewCriteria(criteriaID) then return end

        QueueScreenshot("Achievement criterion " .. tostring(criteriaID), math.min(MemoryKeeperDB.screenshotDelay, 0.6), MemoryKeeperDB.silentCriteria, "criteria")
        return
    end

    if event == "ENCOUNTER_END" then
        if not MemoryKeeperDB.boss then return end
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        if success == 1 then
            QueueScreenshot("Boss kill: " .. tostring(encounterName), MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentBoss, "boss")
        end
        return
    end

    if event == "CHALLENGE_MODE_COMPLETED" then
        if not MemoryKeeperDB.mythicPlus then return end
        QueueScreenshot("Mythic+ completed", MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentMythicPlus, "mythicPlus")
        return
    end

    if event == "PLAYER_LEVEL_UP" then
        if not MemoryKeeperDB.levelUp then return end
        local level = ...
        QueueScreenshot("Level " .. tostring(level), MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentLevelUp, "levelUp")
        return
    end

    if event == "PVP_MATCH_COMPLETE" then
        if not MemoryKeeperDB.pvp then return end
        QueueScreenshot("PvP match complete", MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentPvP, "pvp")
        return
    end

    if event == "FACTION_STANDING_CHANGED" then
        -- Fires when a faction's standing/reaction changes (for example Friendly -> Honored),
        -- not for every individual reputation point gained.
        if not MemoryKeeperDB.reputation then return end
        local factionID, updatedStanding = ...
        QueueScreenshot("Reputation standing changed", MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentReputation, "reputation")
        return
    end

    if event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
        -- Fires when a major faction's renown level changes.
        if not MemoryKeeperDB.reputation then return end
        local majorFactionID, newRenownLevel, oldRenownLevel = ...
        QueueScreenshot("Major faction renown level changed", MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentReputation, "reputation")
        return
    end

    if event == "COVENANT_SANCTUM_RENOWN_LEVEL_CHANGED" then
        -- Legacy covenant renown progression event, retained for compatibility.
        if not MemoryKeeperDB.reputation then return end
        local newRenownLevel, oldRenownLevel = ...
        QueueScreenshot("Covenant renown level changed", MemoryKeeperDB.screenshotDelay, MemoryKeeperDB.silentReputation, "reputation")
        return
    end

    if event == "CINEMATIC_START" then
        -- Only capture Blizzard's in-engine cinematic scenes/cutscenes.
        if not MemoryKeeperDB.cinematic or not IsInCinematicScene() then return end

        cinematicActive = true
        cinematicToken = cinematicToken + 1
        local token = cinematicToken

        -- Cancel any existing cinematic ticker to avoid duplicates
        if cinematicTicker then
            cinematicTicker:Cancel()
            cinematicTicker = nil
        end

        -- First screenshot after 2 seconds, then every 5 seconds while cinematicActive
        C_Timer.After(2, function()
            if not cinematicActive or token ~= cinematicToken then return end
            DoScreenshot("In-game cinematic", MemoryKeeperDB.silentCinematic, "cinematic")

            -- Start a repeating ticker for subsequent screenshots every 5 seconds.
            -- Use token to ensure we can cancel/ignore stale tickers.
            cinematicTicker = C_Timer.NewTicker(5, function()
                if not cinematicActive or token ~= cinematicToken then
                    if cinematicTicker then
                        cinematicTicker:Cancel()
                        cinematicTicker = nil
                    end
                    return
                end
                DoScreenshot("In-game cinematic", MemoryKeeperDB.silentCinematic, "cinematic")
            end)
        end)
        return
    end

    if event == "CINEMATIC_STOP" then
        if not cinematicActive then return end
        cinematicActive = false
        cinematicToken = cinematicToken + 1
        if cinematicTicker then
            cinematicTicker:Cancel()
            cinematicTicker = nil
        end
        return
    end
end)

SLASH_MEMORYKEEPER1 = "/memorykeeper"
SLASH_MEMORYKEEPER2 = "/mk"

local function PrintStatus()
    print("|cff66ccffMemoryKeeper|r status:")
    print("  Achievements:", MemoryKeeperDB.achievement and "ON" or "OFF", "silent:", MemoryKeeperDB.silentAchievement and "YES" or "NO")
    print("  Criteria:", MemoryKeeperDB.criteria and "ON" or "OFF", "silent:", MemoryKeeperDB.silentCriteria and "YES" or "NO")
    print("  Bosses:", MemoryKeeperDB.boss and "ON" or "OFF", "silent:", MemoryKeeperDB.silentBoss and "YES" or "NO")
    print("  Mythic+:", MemoryKeeperDB.mythicPlus and "ON" or "OFF", "silent:", MemoryKeeperDB.silentMythicPlus and "YES" or "NO")
    print("  Level up:", MemoryKeeperDB.levelUp and "ON" or "OFF", "silent:", MemoryKeeperDB.silentLevelUp and "YES" or "NO")
    print("  PvP:", MemoryKeeperDB.pvp and "ON" or "OFF", "silent:", MemoryKeeperDB.silentPvP and "YES" or "NO")
    print("  Reputation:", MemoryKeeperDB.reputation and "ON" or "OFF", "silent:", MemoryKeeperDB.silentReputation and "YES" or "NO")
    print("  Cinematic:", MemoryKeeperDB.cinematic and "ON" or "OFF", "silent:", MemoryKeeperDB.silentCinematic and "YES" or "NO")
    print("  Cooldown:", MemoryKeeperDB.cooldown)
    print("  Screenshot delay:", MemoryKeeperDB.screenshotDelay)
    print("  Debug:", MemoryKeeperDB.debug and "ON" or "OFF")
end

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
        PrintStatus()
    elseif msg == "debug" then
        MemoryKeeperDB.debug = not MemoryKeeperDB.debug
        print("|cff66ccffMemoryKeeper|r debug:", MemoryKeeperDB.debug and "ON" or "OFF")
    else
        if MemoryKeeper_OpenOptions then
            MemoryKeeper_OpenOptions()
        end
    end
end
