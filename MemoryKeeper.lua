local ADDON_NAME, MK = ...

local addon = CreateFrame("Frame")
local pendingTimers = {}
local lastScreenshotTime = {}
local cinematicActive = false
local cinematicToken = 0
local cinematicTicker = nil

MemoryKeeperDB = MemoryKeeperDB or {}

local globalDefaults = {
    screenshotDelay = 0.8,
    cooldown = 2.0,
    debug = false,
}

local function Debug(msg)
    if MemoryKeeperDB.debug then
        print("|cff66ccffMemoryKeeper|r:", msg)
    end
end

local function CanScreenshot(category)
    local lastTime = lastScreenshotTime[category] or 0
    return (GetTime() - lastTime) >= (MemoryKeeperDB.cooldown or globalDefaults.cooldown)
end

-- Blizzard's ActionStatus frame prints "Screenshot taken" when the client reports
-- SCREENSHOT_SUCCEEDED. The client only reports that once the image has actually
-- been written, which is several frames after Screenshot() returns, so the frame
-- has to stay unsubscribed until the result arrives rather than just across the
-- call. While it is unsubscribed we listen for the result ourselves.
local SILENT_RELEASE_TIMEOUT = 10

local screenshotWatcher = CreateFrame("Frame")
local outstandingSilentShots = 0
local silentReleaseTimer = nil

local function RestoreScreenshotNotification()
    if outstandingSilentShots == 0 then return end

    outstandingSilentShots = 0
    if silentReleaseTimer then
        silentReleaseTimer:Cancel()
        silentReleaseTimer = nil
    end

    screenshotWatcher:UnregisterEvent("SCREENSHOT_SUCCEEDED")
    screenshotWatcher:UnregisterEvent("SCREENSHOT_FAILED")

    if ActionStatus and ActionStatus.RegisterEvent then
        ActionStatus:RegisterEvent("SCREENSHOT_SUCCEEDED")
    end
end

screenshotWatcher:SetScript("OnEvent", function()
    outstandingSilentShots = outstandingSilentShots - 1
    if outstandingSilentShots <= 0 then
        RestoreScreenshotNotification()
    end
end)

local function SuppressScreenshotNotification()
    if not (ActionStatus and ActionStatus.UnregisterEvent) then return false end

    if outstandingSilentShots == 0 then
        ActionStatus:UnregisterEvent("SCREENSHOT_SUCCEEDED")
        screenshotWatcher:RegisterEvent("SCREENSHOT_SUCCEEDED")
        screenshotWatcher:RegisterEvent("SCREENSHOT_FAILED")
    end
    outstandingSilentShots = outstandingSilentShots + 1

    -- Safety net in case the client never reports a result for this screenshot.
    if silentReleaseTimer then
        silentReleaseTimer:Cancel()
    end
    silentReleaseTimer = C_Timer.NewTimer(SILENT_RELEASE_TIMEOUT, RestoreScreenshotNotification)

    return true
end

local function DoScreenshot(reason, silent, category)
    if not CanScreenshot(category) then
        Debug("Screenshot skipped due to cooldown: " .. tostring(reason))
        return
    end

    lastScreenshotTime[category] = GetTime()

    if silent then
        SuppressScreenshotNotification()
    end
    Screenshot()

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
    -- Only replace a pending screenshot from the same category.
    -- Different event types must never cancel each other.
    CancelPendingTimer(category)

    local timer = C_Timer.NewTimer(delay, function()
        pendingTimers[category] = nil
        DoScreenshot(reason, silent, category)
    end)
    pendingTimers[category] = timer
end

local function HandleCinematic(def, event)
    if event == "CINEMATIC_STOP" then
        -- Handled even when capturing is switched off, because a cinematic that
        -- started while it was on must still be able to stop its ticker.
        if not cinematicActive then return end
        cinematicActive = false
        cinematicToken = cinematicToken + 1
        if cinematicTicker then
            cinematicTicker:Cancel()
            cinematicTicker = nil
        end
        return
    end

    if not MemoryKeeperDB[def.dbKey] then return end

    -- Only capture Blizzard's in-engine cinematic scenes/cutscenes.
    if not IsInCinematicScene() then return end

    cinematicActive = true
    cinematicToken = cinematicToken + 1
    local token = cinematicToken
    local silent = MemoryKeeperDB[def.silentDbKey]

    if cinematicTicker then
        cinematicTicker:Cancel()
        cinematicTicker = nil
    end

    -- First screenshot after 2 seconds, then every 5 seconds until the cinematic ends.
    -- The token lets a newly started cinematic invalidate tickers from a previous one.
    C_Timer.After(2, function()
        if not cinematicActive or token ~= cinematicToken then return end
        DoScreenshot("In-game cinematic", silent, def.key)

        cinematicTicker = C_Timer.NewTicker(5, function()
            if not cinematicActive or token ~= cinematicToken then
                if cinematicTicker then
                    cinematicTicker:Cancel()
                    cinematicTicker = nil
                end
                return
            end
            DoScreenshot("In-game cinematic", silent, def.key)
        end)
    end)
end

-- FACTION_STANDING_CHANGED carries the new reputation total and fires on every
-- single point gained, so the previous rank is the only way to tell a real
-- promotion from ordinary grinding. This table is session state, not saved data.
local factionRanks = {}

local function GetParagonLevel(factionID)
    if not C_Reputation.IsFactionParagon(factionID) then return 0 end

    local currentValue, threshold = C_Reputation.GetFactionParagonInfo(factionID)
    if not currentValue or not threshold or threshold == 0 then return 0 end

    return math.floor(currentValue / threshold)
end

-- Ranks come in two flavours the game reads differently: friendship factions
-- (Tillers, Brann) expose a numbered rank, everything else the classic
-- Hated..Exalted reaction. Paragon levels stack on top of a maxed faction.
-- Returns a number that only moves on an actual rank change, plus its display name.
local function GetFactionRank(factionID)
    local friendship = C_GossipInfo.GetFriendshipReputation(factionID)
    if friendship and friendship.friendshipFactionID > 0 then
        local ranks = C_GossipInfo.GetFriendshipReputationRanks(friendship.friendshipFactionID)
        if not ranks or ranks.maxLevel == 0 then return nil end
        return ranks.currentLevel + GetParagonLevel(factionID), friendship.reaction
    end

    local data = C_Reputation.GetFactionDataByID(factionID)
    if not data then return nil end

    local paragonLevel = GetParagonLevel(factionID)
    local standing = GetText("FACTION_STANDING_LABEL" .. data.reaction, UnitSex("player"))
        or ("Standing " .. data.reaction)
    if paragonLevel > 0 then
        standing = standing .. " +" .. paragonLevel
    end

    return data.reaction + paragonLevel, standing
end

-- The game has no call that hands over every faction, and the one list it does
-- offer mirrors the reputation panel, where a collapsed header hides its factions.
-- Asking about the IDs one by one reaches every faction the character has and
-- cannot be influenced by anything the panel is doing. The bound only has to stay
-- above the highest faction in the game; IDs that belong to none cost a lookup
-- returning nothing.
local MAX_FACTION_ID = 4000

-- Taken at login, and again whenever the category is switched back on, because
-- nothing is tracked while it is off and stale ranks would report a change that
-- already happened as if it were new.
local function SnapshotFactionRanks()
    wipe(factionRanks)
    debugprofilestart()

    local recorded = 0
    for factionID = 1, MAX_FACTION_ID do
        if C_Reputation.GetFactionDataByID(factionID) then
            local rank = GetFactionRank(factionID)
            factionRanks[factionID] = rank
            if rank then
                recorded = recorded + 1
            end
        end
    end

    Debug(string.format("Recorded the rank of %d factions in %.1f ms", recorded, debugprofilestop()))
end

local function DescribeStandingChange(factionID, updatedStanding)
    local data = C_Reputation.GetFactionDataByID(factionID)
    if not data then return nil end

    local isMajorFaction = C_Reputation.IsMajorFaction(factionID)

    -- Reported ahead of every other exit so that any reputation gain shows up.
    -- A record still holding the pre-change total would carry the previous rank
    -- with it, which would make remembering anything unnecessary. Whether the
    -- client has already written the new total by now can only be seen in game.
    Debug(string.format("%s: event %d, record %d, reaction %d, band %d-%d, major %s",
        data.name, updatedStanding or -1, data.currentStanding, data.reaction,
        data.currentReactionThreshold, data.nextReactionThreshold, tostring(isMajorFaction)))

    -- Major factions announce their renown on their own event, so all this one
    -- would ever tell us about them is that points moved.
    if isMajorFaction then return nil end

    local rank, standing = GetFactionRank(factionID)
    if not rank then return nil end

    local previous = factionRanks[factionID]
    factionRanks[factionID] = rank
    if previous == nil or previous == rank then return nil end

    return "Reputation: " .. tostring(standing) .. " with " .. tostring(data.name)
end

-- Every capture type is described exactly once here. Event registration, event
-- handling, the /mk status printout and the settings panel are all derived from
-- this list, so adding a new type means adding a single entry.
--
-- describe() receives the event name followed by the event's own payload and
-- returns the debug text for the screenshot, or nil to skip capturing entirely.
local captureTypes = {
    {
        key = "achievement",
        label = "Achievements",
        tooltip = "Capture a screenshot whenever this character earns an achievement.",
        dbKey = "achievement",
        silentDbKey = "silentAchievement",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "ACHIEVEMENT_EARNED" },
        describe = function(event, achievementID)
            return "Achievement " .. tostring(achievementID)
        end,
    },
    {
        key = "criteria",
        label = "Achievement criteria / steps",
        tooltip = "Capture a screenshot whenever a single step of an achievement is completed.",
        dbKey = "criteria",
        silentDbKey = "silentCriteria",
        defaultEnabled = true,
        defaultSilent = false,
        maxDelay = 0.6,
        events = { "CRITERIA_EARNED" },
        describe = function(event, achievementID, description)
            -- Payload is (achievementID, description, achievementAlreadyEarnedOnAccount).
            -- There is no criterion ID, only the achievement the step belongs to.
            return "Criterion of achievement " .. tostring(achievementID) .. ": " .. tostring(description)
        end,
    },
    {
        key = "boss",
        label = "Boss kills",
        tooltip = "Capture a screenshot after a boss encounter ends in a kill.",
        dbKey = "boss",
        silentDbKey = "silentBoss",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "ENCOUNTER_END" },
        describe = function(event, encounterID, encounterName, difficultyID, groupSize, success)
            if success ~= 1 then return nil end
            return "Boss kill: " .. tostring(encounterName)
        end,
    },
    {
        key = "mythicPlus",
        label = "Mythic+ completions",
        tooltip = "Capture a screenshot when a Mythic+ dungeon is completed.",
        dbKey = "mythicPlus",
        silentDbKey = "silentMythicPlus",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "CHALLENGE_MODE_COMPLETED" },
        describe = function()
            return "Mythic+ completed"
        end,
    },
    {
        key = "levelUp",
        label = "Level ups",
        tooltip = "Capture a screenshot when this character gains a level.",
        dbKey = "levelUp",
        silentDbKey = "silentLevelUp",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "PLAYER_LEVEL_UP" },
        describe = function(event, level)
            return "Level " .. tostring(level)
        end,
    },
    {
        key = "pvp",
        label = "PvP match completion",
        tooltip = "Capture a screenshot when a battleground or arena match ends.",
        dbKey = "pvp",
        silentDbKey = "silentPvP",
        defaultEnabled = false,
        defaultSilent = false,
        events = { "PVP_MATCH_COMPLETE" },
        describe = function()
            return "PvP match complete"
        end,
    },
    {
        key = "reputation",
        label = "Reputation milestones",
        tooltip = "Capture a screenshot when a faction rank or renown level changes, in either direction.",
        dbKey = "reputation",
        silentDbKey = "silentReputation",
        defaultEnabled = false,
        defaultSilent = false,
        events = { "FACTION_STANDING_CHANGED", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "COVENANT_SANCTUM_RENOWN_LEVEL_CHANGED" },
        reset = SnapshotFactionRanks,
        describe = function(event, ...)
            if event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
                local majorFactionID, newRenownLevel = ...
                local data = C_MajorFactions.GetMajorFactionData(majorFactionID)
                return "Renown " .. tostring(newRenownLevel) .. " with " .. tostring(data and data.name or majorFactionID)
            elseif event == "COVENANT_SANCTUM_RENOWN_LEVEL_CHANGED" then
                local newRenownLevel = ...
                return "Covenant renown " .. tostring(newRenownLevel)
            end

            local factionID, updatedStanding = ...
            return DescribeStandingChange(factionID, updatedStanding)
        end,
    },
    {
        key = "cinematic",
        label = "In-game cinematic scenes",
        tooltip = "Capture a series of screenshots while an in-engine cinematic is playing.",
        dbKey = "cinematic",
        silentDbKey = "silentCinematic",
        defaultEnabled = true,
        defaultSilent = true,
        events = { "CINEMATIC_START", "CINEMATIC_STOP" },
        handler = HandleCinematic,
    },
}

local captureTypeByEvent = {}
for _, def in ipairs(captureTypes) do
    def.settingVariable = "MEMORYKEEPER_" .. def.dbKey
    def.silentSettingVariable = "MEMORYKEEPER_" .. def.silentDbKey
    for _, event in ipairs(def.events) do
        captureTypeByEvent[event] = def
    end
end

MK.captureTypes = captureTypes

local function ApplyDefaults()
    for key, value in pairs(globalDefaults) do
        if MemoryKeeperDB[key] == nil then
            MemoryKeeperDB[key] = value
        end
    end
    for _, def in ipairs(captureTypes) do
        if MemoryKeeperDB[def.dbKey] == nil then
            MemoryKeeperDB[def.dbKey] = def.defaultEnabled
        end
        if MemoryKeeperDB[def.silentDbKey] == nil then
            MemoryKeeperDB[def.silentDbKey] = def.defaultSilent
        end
    end
end

addon:RegisterEvent("ADDON_LOADED")
addon:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        ApplyDefaults()

        for registeredEvent in pairs(captureTypeByEvent) do
            self:RegisterEvent(registeredEvent)
        end
        self:RegisterEvent("PLAYER_LOGIN")

        print("|cff66ccffMemoryKeeper|r loaded. Type |cffffff00/memorykeeper|r for options.")
        return
    end

    -- Types that recognise a change by comparing against an earlier state need
    -- that state before anything can change, which is once the game data is up.
    if event == "PLAYER_LOGIN" then
        for _, def in ipairs(captureTypes) do
            if def.reset then
                def.reset()
            end
        end
        return
    end

    local def = captureTypeByEvent[event]
    if not def then return end

    -- Types with a custom handler check the enabled flag themselves, because some
    -- of their events must run regardless of it.
    if def.handler then
        def.handler(def, event, ...)
        return
    end

    if not MemoryKeeperDB[def.dbKey] then return end

    local reason = def.describe(event, ...)
    if not reason then return end

    local delay = MemoryKeeperDB.screenshotDelay or globalDefaults.screenshotDelay
    if def.maxDelay then
        delay = math.min(delay, def.maxDelay)
    end

    QueueScreenshot(reason, delay, MemoryKeeperDB[def.silentDbKey], def.key)
end)

-- Route writes through the settings object when it exists so an open settings
-- panel updates immediately instead of showing a stale checkbox.
local function SetCaptureEnabled(def, enabled)
    local setting = Settings and Settings.GetSetting and Settings.GetSetting(def.settingVariable)
    if setting then
        setting:SetValue(enabled)
    else
        MemoryKeeperDB[def.dbKey] = enabled
    end
end

SLASH_MEMORYKEEPER1 = "/memorykeeper"
SLASH_MEMORYKEEPER2 = "/mk"

local function PrintStatus()
    print("|cff66ccffMemoryKeeper|r status:")
    for _, def in ipairs(captureTypes) do
        print(string.format("  %s: %s, silent: %s",
            def.label,
            MemoryKeeperDB[def.dbKey] and "ON" or "OFF",
            MemoryKeeperDB[def.silentDbKey] and "YES" or "NO"))
    end
    print("  Cooldown:", MemoryKeeperDB.cooldown)
    print("  Screenshot delay:", MemoryKeeperDB.screenshotDelay)
    print("  Debug:", MemoryKeeperDB.debug and "ON" or "OFF")
end

SlashCmdList.MEMORYKEEPER = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "on" or msg == "off" then
        local enabled = msg == "on"
        SetCaptureEnabled(captureTypeByEvent["ACHIEVEMENT_EARNED"], enabled)
        SetCaptureEnabled(captureTypeByEvent["CRITERIA_EARNED"], enabled)
        print("|cff66ccffMemoryKeeper|r: achievement and criterion screenshots " .. (enabled and "enabled." or "disabled."))
    elseif msg == "status" then
        PrintStatus()
    elseif msg == "debug" then
        MemoryKeeperDB.debug = not MemoryKeeperDB.debug
        print("|cff66ccffMemoryKeeper|r debug:", MemoryKeeperDB.debug and "ON" or "OFF")
    elseif MemoryKeeper_OpenOptions then
        MemoryKeeper_OpenOptions()
    end
end
