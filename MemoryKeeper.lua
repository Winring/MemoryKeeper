local ADDON_NAME, MK = ...

local addon = CreateFrame("Frame")
local pendingTimers = {}
local lastScreenshotTime = {}

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

-- Every session baseline at PLAYER_LOGIN (and when that type is switched on)
-- reports through here, so a slow walk shows up the same way under /mk debug.
local function DebugBaseline(count, what)
    Debug(string.format("Recorded %d %s in %.1f ms", count, what, debugprofilestop()))
end

local function CanScreenshot(category)
    local lastTime = lastScreenshotTime[category] or 0
    return (GetTime() - lastTime) >= (MemoryKeeperDB.cooldown or globalDefaults.cooldown)
end

-- ActionStatus prints "Screenshot taken" from SCREENSHOT_SUCCEEDED in OnEvent.
-- Screenshot() returns before that event; 1.1.0 proved it by re-subscribing on
-- the next line and still seeing the label. Silent shots skip the display inside
-- OnEvent. Do not UnregisterEvent on ActionStatus: that steals SUCCEEDED from
-- every screenshot until we give it back, including non-silent ones, and
-- RegisterEvent/UnregisterEvent now also mark the frame with Midnight's
-- EventRegistrations forbidden aspect.
local SILENT_RELEASE_TIMEOUT = 10

local silentSkipRemaining = 0
local actionStatusWrapped = false
local silentReleaseTimer = nil

local function ReleaseSilentSkip()
    silentSkipRemaining = 0
    if silentReleaseTimer then
        silentReleaseTimer:Cancel()
        silentReleaseTimer = nil
    end
end

local function WrapActionStatus()
    if actionStatusWrapped then
        return true
    end
    if not ActionStatus then
        return false
    end

    local original = ActionStatus:GetScript("OnEvent")
    if not original and ActionStatusMixin then
        original = ActionStatusMixin.OnEvent
    end
    if not original then
        return false
    end

    ActionStatus:SetScript("OnEvent", function(self, event, ...)
        if silentSkipRemaining > 0 and (event == "SCREENSHOT_SUCCEEDED" or event == "SCREENSHOT_FAILED") then
            silentSkipRemaining = silentSkipRemaining - 1
            if silentSkipRemaining <= 0 then
                ReleaseSilentSkip()
            end
            return
        end
        original(self, event, ...)
    end)

    actionStatusWrapped = true
    return true
end

local function SuppressScreenshotNotification()
    if not WrapActionStatus() then
        return false
    end

    silentSkipRemaining = silentSkipRemaining + 1
    if silentReleaseTimer then
        silentReleaseTimer:Cancel()
    end
    -- Safety net in case the client never reports a result for this screenshot.
    silentReleaseTimer = C_Timer.NewTimer(SILENT_RELEASE_TIMEOUT, ReleaseSilentSkip)
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

-- Types may cap or raise the configured delay for a specific event. Computed
-- here so dispatch does not grow a second copy each time a type needs one.
local function ScreenshotDelay(def, event)
    local delay = MemoryKeeperDB.screenshotDelay or globalDefaults.screenshotDelay
    local maxDelay = def.maxDelay
    if def.eventMaxDelay then
        maxDelay = def.eventMaxDelay[event] or maxDelay
    end
    if maxDelay then
        delay = math.min(delay, maxDelay)
    end
    local minDelay = def.minDelay
    if def.eventMinDelay then
        minDelay = def.eventMinDelay[event] or minDelay
    end
    if minDelay then
        delay = math.max(delay, minDelay)
    end
    return delay
end

-- First-seen memories. The game will not tell us whether this character has
-- ever killed a boss, timed a key, or finished a delve story; it only knows
-- the current lockout or the run that just ended. Those firsts are stored per
-- character until the SavedVariables are wiped. Presence of a key is the whole
-- record: no screenshot flag, no timestamp.
--
-- Hidden slash commands wipe these without touching settings:
-- /mk cleandbuser this character, /mk cleandbfull every character on the account.
local STORE_BOSSES = "killedBosses"
local STORE_MYTHIC_PLUS = "completedMythicPlusRuns"
local STORE_DELVES = "completedDelveRuns"
local characterRecordStores = { STORE_BOSSES, STORE_MYTHIC_PLUS, STORE_DELVES }

local function GetCharacterRecord(storeKey)
    local guid = UnitGUID("player")
    if not guid then return nil end

    local store = MemoryKeeperDB[storeKey]
    if not store then
        store = {}
        MemoryKeeperDB[storeKey] = store
    end

    local byCharacter = store[guid]
    if not byCharacter then
        byCharacter = {}
        store[guid] = byCharacter
    end
    return byCharacter
end

local function ClearCharacterRecords()
    local guid = UnitGUID("player")
    if not guid then return false end

    for _, storeKey in ipairs(characterRecordStores) do
        local store = MemoryKeeperDB[storeKey]
        if store then
            store[guid] = nil
        end
    end
    return true
end

local function ClearAllCharacterRecords()
    for _, storeKey in ipairs(characterRecordStores) do
        MemoryKeeperDB[storeKey] = nil
    end
end

local function HasRecordedPath(storeKey, ...)
    local node = GetCharacterRecord(storeKey)
    if not node then return false end
    local count = select("#", ...)
    for i = 1, count do
        node = node[select(i, ...)]
        if not node then return false end
    end
    return true
end

local function RecordPath(storeKey, ...)
    local node = GetCharacterRecord(storeKey)
    if not node then return end
    local count = select("#", ...)
    for i = 1, count - 1 do
        local key = select(i, ...)
        local child = node[key]
        if not child then
            child = {}
            node[key] = child
        end
        node = child
    end
    node[select(count, ...)] = true
end

-- Practice keys are not a season score and must not consume the first real
-- completion at that dungeon and level.
local function GetMythicPlusRun()
    local info = C_ChallengeMode.GetChallengeCompletionInfo()
    if not info or info.practiceRun then return nil end

    local seasonID = C_MythicPlus.GetCurrentSeason()
    local mapID = info.mapChallengeModeID
    local level = info.level
    if not seasonID or seasonID == 0 or not mapID or not level then return nil end

    local name = C_ChallengeMode.GetMapUIInfo(mapID)
    return {
        seasonID = seasonID,
        mapID = mapID,
        level = level,
        name = name,
    }
end

-- Delves have no completion event of their own. The run is a scenario, and
-- HasActiveDelve() can already be false when it finishes, so identity is
-- stored on the way in. Stories of the same delve are different scenarios
-- (and historically different difficulty). instanceType "none" is the overworld;
-- a leftover run must not count Theatre Troupe.
local activeDelveRun = nil

local function IsInDelveContent()
    return C_DelvesUI.HasActiveDelve() or C_ScenarioInfo.IsTieredEntranceScenario()
end

local function ReadDelveRun()
    if not IsInDelveContent() then return nil end

    local seasonID = C_DelvesUI.GetCurrentDelvesSeasonNumber()
    local mapID = C_DelvesUI.GetDelveEntranceMapID()
    if not mapID or mapID == 0 then
        mapID = select(8, GetInstanceInfo())
    end

    local entranceType = C_DelvesUI.GetTieredEntranceType()
    if entranceType == Enum.TieredEntranceType.Invalid then
        if C_DelvesUI.IsInLair() then
            entranceType = Enum.TieredEntranceType.Lairs
        else
            entranceType = Enum.TieredEntranceType.Delve
        end
    end

    local story = C_ScenarioInfo.GetScenarioInfo()
    local scenarioID = story and story.scenarioID
    local storyName = story and story.name

    local tierInfo = C_DelvesUI.GetActiveDelveTier()
    local tier = tierInfo and tierInfo.tier

    local title = C_DelvesUI.GetDelveEntranceTitleString()
    if not title or title == "" then
        title = GetInstanceInfo()
    end

    if not seasonID or seasonID == 0 or not mapID or mapID == 0 or not tier or tier == 0
        or not scenarioID or scenarioID == 0 then
        return nil
    end

    return {
        seasonID = seasonID,
        mapID = mapID,
        entranceType = entranceType,
        scenarioID = scenarioID,
        tier = tier,
        title = title,
        storyName = storyName,
    }
end

local function RefreshActiveDelveRun()
    local run = ReadDelveRun()
    if run then
        activeDelveRun = run
    end
end

local function ClearInactiveDelveRun()
    if IsInDelveContent() then return end
    activeDelveRun = nil
end

local function GetDelveRun()
    RefreshActiveDelveRun()
    if not activeDelveRun then return nil end
    if not IsInDelveContent() and select(2, GetInstanceInfo()) == "none" then
        return nil
    end
    return activeDelveRun
end

-- Companion levels are the number on the delve companion panel. That panel
-- reads GetFriendshipReputationRanks with the companion faction ID.
-- FACTION_STANDING_CHANGED still fires for every XP tick; the level is
-- ranks.currentLevel. Journey major factions carry playerCompanionID.
-- GetMajorFactionIDs takes an expansion in Blizzard's UI, so every expansion
-- must be asked or the other expansion's companion is missing.
local companionFactionIDs = {}
local companionLevels = {}

local function NoteCompanionFaction(factionID)
    if factionID and factionID > 0 then
        companionFactionIDs[factionID] = true
    end
end

local function RefreshCompanionFactionIDs()
    wipe(companionFactionIDs)
    NoteCompanionFaction(C_DelvesUI.GetFactionForCompanion())
    local activeCompanion = C_DelvesUI.GetCompanionInfoForActivePlayer()
    if activeCompanion and activeCompanion > 0 then
        NoteCompanionFaction(C_DelvesUI.GetFactionForCompanion(activeCompanion))
    end
    local maxExpansion = LE_EXPANSION_LEVEL_CURRENT or 0
    for expansionID = 0, maxExpansion do
        local majorIDs = C_MajorFactions.GetMajorFactionIDs(expansionID)
        if majorIDs then
            for i = 1, #majorIDs do
                local data = C_MajorFactions.GetMajorFactionData(majorIDs[i])
                if data and data.playerCompanionID then
                    NoteCompanionFaction(C_DelvesUI.GetFactionForCompanion(data.playerCompanionID))
                end
            end
        end
    end
end

local function IsDelveCompanionFaction(factionID)
    if companionFactionIDs[factionID] then return true end
    if C_DelvesUI.GetFactionForCompanion() == factionID then
        companionFactionIDs[factionID] = true
        return true
    end
    return false
end

local function GetCompanionLevel(factionID)
    local ranks = C_GossipInfo.GetFriendshipReputationRanks(factionID)
    if not ranks or ranks.maxLevel == 0 then return nil end
    return ranks.currentLevel, ranks.maxLevel
end

local function BaselineCompanionLevels()
    debugprofilestart()
    RefreshCompanionFactionIDs()
    wipe(companionLevels)
    local recorded = 0
    for factionID in pairs(companionFactionIDs) do
        companionLevels[factionID] = GetCompanionLevel(factionID)
        recorded = recorded + 1
    end
    DebugBaseline(recorded, "companion levels")
end

-- FACTION_STANDING_CHANGED carries the new reputation total and fires on every
-- single point gained, so the previous rank is the only way to tell a real
-- promotion from ordinary grinding. This table is session state, not saved data.
local factionRanks = {}

-- The game has no call that hands over every faction, and the one list it does
-- offer mirrors the reputation panel, where a collapsed header hides its factions.
-- Asking about the IDs one by one reaches every faction the character has and
-- cannot be influenced by anything the panel is doing. The bound only has to stay
-- above the highest faction in the game; IDs that belong to none cost a lookup
-- returning nothing.
local MAX_FACTION_ID = 4000

-- Ranks come in two flavours the game reads differently: friendship factions
-- (Tillers) expose a numbered rank, everything else the classic
-- Hated..Exalted reaction. Paragon is left out on purpose, a refilled bar past
-- the last rank is grinding rather than a promotion. Delve companions pass the
-- friendship test, but the number on their panel is currentLevel, not a rank
-- in this list.
-- Returns a number that only moves on an actual rank change, plus its display name.
local function GetFactionRank(factionID)
    if IsDelveCompanionFaction(factionID) then return nil end

    local friendship = C_GossipInfo.GetFriendshipReputation(factionID)
    if friendship and friendship.friendshipFactionID > 0 then
        local ranks = C_GossipInfo.GetFriendshipReputationRanks(friendship.friendshipFactionID)
        if not ranks or ranks.maxLevel == 0 then return nil end
        return ranks.currentLevel, friendship.reaction
    end

    local data = C_Reputation.GetFactionDataByID(factionID)
    if not data then return nil end

    local standing = GetText("FACTION_STANDING_LABEL" .. data.reaction, UnitSex("player"))
        or ("Standing " .. data.reaction)

    return data.reaction, standing
end

-- Taken at login, and again whenever the category is switched back on, because
-- nothing is tracked while it is off and stale ranks would report a change that
-- already happened as if it were new.
local function BaselineFactionRanks()
    RefreshCompanionFactionIDs()
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

    DebugBaseline(recorded, "factions")
end

-- Official journal sets stay collected after they are finished, and a later
-- source of the same slot still fires TRANSMOG_COLLECTION_SOURCE_ADDED. The
-- previous collected set IDs are what distinguish a set that just completed
-- from one that was already done. Session state only; the event itself is the
-- first time that source is learned.
local collectedTransmogSets = {}

local function BaselineCollectedTransmogSets()
    wipe(collectedTransmogSets)
    debugprofilestart()
    local recorded = 0
    local sets = C_TransmogSets.GetAllSets()
    if sets then
        for i = 1, #sets do
            local info = sets[i]
            if info.collected then
                collectedTransmogSets[info.setID] = true
                recorded = recorded + 1
            end
        end
    end
    DebugBaseline(recorded, "completed transmog sets")
end

local function FormatTransmogSetName(info)
    if info.description and info.description ~= "" then
        return tostring(info.name) .. " (" .. tostring(info.description) .. ")"
    end
    return tostring(info.name)
end

-- Marks the set collected for this session. Names are only added when the set
-- is for this character; other class masks can complete in the background.
local function NoteNewlyCompletedTransmogSet(setID, names)
    if not setID or collectedTransmogSets[setID] then return end
    local info = C_TransmogSets.GetSetInfo(setID)
    if not info or not info.collected then return end
    collectedTransmogSets[setID] = true
    if not info.validForCharacter then return end
    names[#names + 1] = FormatTransmogSetName(info)
end

-- CRITERIA_EARNED payload is (achievementID, description, achievementAlreadyEarnedOnAccount).
-- There is no criterion ID, only the achievement the step belongs to.
local function DescribeAchievement(event, achievementID, description)
    local name = select(2, GetAchievementInfo(achievementID)) or tostring(achievementID)
    if event == "CRITERIA_EARNED" then
        return "Achievement step: " .. name .. ": " .. tostring(description)
    end
    return "Achievement: " .. name
end

local function DescribeBossKill(encounterName, difficultyID)
    local difficulty = GetDifficultyInfo(difficultyID)
    if difficulty then
        return "Boss " .. tostring(encounterName) .. ", " .. difficulty
    end
    return "Boss " .. tostring(encounterName)
end

local function DescribeMythicPlusRun(run)
    local title = run.name or tostring(run.mapID)
    return "Mythic+ " .. title .. ", +" .. tostring(run.level)
end

local function DescribeDelveRun(run)
    local kind = "Delve"
    if run.entranceType == Enum.TieredEntranceType.Lairs then
        kind = "Lair"
    end
    local title = run.title or tostring(run.mapID)
    local story = run.storyName or tostring(run.scenarioID)
    return kind .. " " .. title .. ": " .. story .. ", tier " .. tostring(run.tier)
end

local function DescribeCompanionLevel(event, factionID, updatedStanding)
    if not IsDelveCompanionFaction(factionID) then return nil end

    local data = C_Reputation.GetFactionDataByID(factionID)
    local name = data and data.name or tostring(factionID)
    local level, maxLevel = GetCompanionLevel(factionID)
    Debug(string.format("%s: companion standing %d, level %s / %s",
        name, updatedStanding or -1,
        level and tostring(level) or "?",
        maxLevel and tostring(maxLevel) or "?"))

    if not level then return nil end
    local previous = companionLevels[factionID]
    companionLevels[factionID] = level
    if previous == nil or previous == level then return nil end
    return "Delve companion: " .. tostring(name) .. ", level " .. tostring(level)
end

local function DescribePvPMatch()
    local name = GetInstanceInfo()
    if name and name ~= "" then
        return "PvP: " .. name
    end
    return "PvP match complete"
end

local function DescribeStandingChange(factionID, updatedStanding)
    -- Major factions announce their renown on their own event, so all this one
    -- would ever tell us about them is that points moved. Delve companions pass
    -- the friendship test, but their level is the companion panel's currentLevel.
    if C_Reputation.IsMajorFaction(factionID) or IsDelveCompanionFaction(factionID) then
        return nil
    end

    local data = C_Reputation.GetFactionDataByID(factionID)
    if not data then return nil end

    -- The band the new total lands in shows how far the next rank still is.
    Debug(string.format("%s: %d in band %d-%d, reaction %d",
        data.name, updatedStanding or -1, data.currentReactionThreshold,
        data.nextReactionThreshold, data.reaction))

    local rank, standing = GetFactionRank(factionID)
    if not rank then return nil end

    local previous = factionRanks[factionID]
    factionRanks[factionID] = rank
    if previous == nil or previous == rank then return nil end

    return "Reputation: " .. tostring(standing) .. " with " .. tostring(data.name)
end

local function DescribeMount(mountID)
    local name = C_MountJournal.GetMountInfoByID(mountID)
    if name and name ~= "" then
        return "Mount: " .. name
    end
    return "Mount " .. tostring(mountID)
end

-- NEW_PET_ADDED fires for every new journal slot, including a second of the
-- same species. The species becoming known is the memory; GetNumCollectedInfo
-- is already 1 when this first pet is added.
local function DescribePet(battlePetGUID)
    local speciesID, customName, _, _, _, _, _, name = C_PetJournal.GetPetInfoByPetID(battlePetGUID)
    if not speciesID then return nil end
    local numOwned = C_PetJournal.GetNumCollectedInfo(speciesID)
    if numOwned and numOwned > 1 then return nil end
    local title = name or customName or tostring(speciesID)
    return "Battle pet: " .. tostring(title)
end

-- Completing Mythic can also mark earlier variants collected. Walk the base
-- set and its variants, not only the sets that contain this source.
local function DescribeTransmogSetComplete(sourceID)
    local names = {}
    local setIDs = C_TransmogSets.GetSetsContainingSourceID(sourceID)
    local seenBase = {}
    for _, setID in ipairs(setIDs or {}) do
        local baseID = C_TransmogSets.GetBaseSetID(setID) or setID
        if not seenBase[baseID] then
            seenBase[baseID] = true
            NoteNewlyCompletedTransmogSet(baseID, names)
            local variants = C_TransmogSets.GetVariantSets(baseID)
            if variants then
                for i = 1, #variants do
                    NoteNewlyCompletedTransmogSet(variants[i].setID, names)
                end
            end
        end
        NoteNewlyCompletedTransmogSet(setID, names)
    end
    if #names == 0 then return nil end
    return "Transmog set: " .. table.concat(names, ", ")
end

local cinematicActive = false
local cinematicToken = 0
local cinematicTicker = nil

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

-- Every capture type is described exactly once here. Event registration, event
-- handling, the /mk status printout and the settings panel are all derived from
-- this list, so adding a new type means adding a single entry.
--
-- describe() receives the event name followed by the event's own payload and
-- returns the debug text for the screenshot, or nil to skip capturing entirely.
-- extraCheckboxes are shown indented under the type. remember() records state
-- even while the type is switched off. eventMaxDelay caps the screenshot delay
-- for specific events of a type that owns more than one. eventMinDelay raises
-- it when the game itself waits before showing the toast.
--
-- Types list the events they care about. The game uses one standing event for
-- classic ranks, friendship, and companion XP, so more than one type may list
-- the same event.
local captureTypes = {
    {
        key = "achievement",
        label = "Achievements",
        tooltip = "Capture a screenshot whenever this character earns an achievement.",
        dbKey = "achievement",
        silentDbKey = "silentAchievement",
        defaultEnabled = true,
        defaultSilent = false,
        extraCheckboxes = {
            {
                dbKey = "criteria",
                label = "Criteria / steps",
                tooltip = "Also photograph each completed achievement step.",
                defaultEnabled = true,
            },
        },
        eventMaxDelay = { CRITERIA_EARNED = 0.6 },
        events = { "ACHIEVEMENT_EARNED", "CRITERIA_EARNED" },
        describe = function(event, achievementID, description)
            if event == "CRITERIA_EARNED" and not MemoryKeeperDB.criteria then
                return nil
            end
            return DescribeAchievement(event, achievementID, description)
        end,
    },
    {
        key = "boss",
        label = "Boss kills",
        tooltip = "Capture a screenshot of the first kill of each boss on each difficulty.",
        dbKey = "boss",
        silentDbKey = "silentBoss",
        defaultEnabled = true,
        defaultSilent = false,
        extraCheckboxes = {
            {
                dbKey = "bossEveryKill",
                label = "Every kill",
                tooltip = "Photograph every kill instead of only the first on each difficulty.",
                defaultEnabled = false,
            },
        },
        events = { "ENCOUNTER_END" },
        describe = function(event, encounterID, encounterName, difficultyID, groupSize, success)
            if success ~= 1 then return nil end
            if not MemoryKeeperDB.bossEveryKill and HasRecordedPath(STORE_BOSSES, encounterID, difficultyID) then
                return nil
            end
            return DescribeBossKill(encounterName, difficultyID)
        end,
        remember = function(event, encounterID, encounterName, difficultyID, groupSize, success)
            if success == 1 then
                RecordPath(STORE_BOSSES, encounterID, difficultyID)
            end
        end,
    },
    {
        key = "mythicPlus",
        label = "Mythic+ completions",
        tooltip = "Capture a screenshot of the first key at each level in each dungeon, each season.",
        dbKey = "mythicPlus",
        silentDbKey = "silentMythicPlus",
        defaultEnabled = true,
        defaultSilent = false,
        extraCheckboxes = {
            {
                dbKey = "mythicPlusEveryCompletion",
                label = "Every completion",
                tooltip = "Photograph every completed key instead of only the first at each level in each dungeon.",
                defaultEnabled = false,
            },
        },
        events = { "CHALLENGE_MODE_COMPLETED" },
        describe = function()
            local run = GetMythicPlusRun()
            if not run then return nil end
            if not MemoryKeeperDB.mythicPlusEveryCompletion and HasRecordedPath(STORE_MYTHIC_PLUS, run.seasonID, run.mapID, run.level) then
                return nil
            end
            return DescribeMythicPlusRun(run)
        end,
        remember = function()
            local run = GetMythicPlusRun()
            if run then
                RecordPath(STORE_MYTHIC_PLUS, run.seasonID, run.mapID, run.level)
            end
        end,
    },
    {
        key = "delve",
        label = "Delve completions",
        tooltip = "Capture a screenshot of the first completion of each story of each delve or lair at each tier, each season.",
        dbKey = "delve",
        silentDbKey = "silentDelve",
        defaultEnabled = true,
        defaultSilent = false,
        extraCheckboxes = {
            {
                dbKey = "delveEveryCompletion",
                label = "Every completion",
                tooltip = "Photograph every completed delve or lair instead of only the first of each story at each tier.",
                defaultEnabled = false,
            },
        },
        events = { "SCENARIO_COMPLETED", "SCENARIO_UPDATE", "WALK_IN_DATA_UPDATE", "ACTIVE_DELVE_DATA_UPDATE", "PLAYER_ENTERING_WORLD" },
        describe = function(event)
            if event ~= "SCENARIO_COMPLETED" then return nil end
            local run = GetDelveRun()
            if not run then return nil end
            if not MemoryKeeperDB.delveEveryCompletion and HasRecordedPath(STORE_DELVES, run.seasonID, run.mapID, run.entranceType, run.scenarioID, run.tier) then
                return nil
            end
            return DescribeDelveRun(run)
        end,
        remember = function(event)
            if event ~= "SCENARIO_COMPLETED" then
                RefreshActiveDelveRun()
                ClearInactiveDelveRun()
                return
            end
            local run = GetDelveRun()
            if run then
                RecordPath(STORE_DELVES, run.seasonID, run.mapID, run.entranceType, run.scenarioID, run.tier)
            end
        end,
    },
    {
        key = "companion",
        label = "Delve companion levels",
        tooltip = "Capture a screenshot when Brann or Valeera gains a companion level.",
        dbKey = "companion",
        silentDbKey = "silentCompanion",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "FACTION_STANDING_CHANGED" },
        reset = BaselineCompanionLevels,
        describe = DescribeCompanionLevel,
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
        -- Event toast text fades in after 1.8s (duration 0.5). The gold bars grow from 1.5s.
        eventMinDelay = { PLAYER_LEVEL_UP = 2.4 },
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
            return DescribePvPMatch()
        end,
    },
    {
        key = "reputation",
        label = "Reputation milestones",
        tooltip = "Capture a screenshot when a classic faction standing or friendship rank changes, in either direction.",
        dbKey = "reputation",
        silentDbKey = "silentReputation",
        defaultEnabled = false,
        defaultSilent = false,
        events = { "FACTION_STANDING_CHANGED" },
        reset = BaselineFactionRanks,
        describe = function(event, factionID, updatedStanding)
            return DescribeStandingChange(factionID, updatedStanding)
        end,
    },
    {
        key = "renown",
        label = "Renown",
        tooltip = "Capture a screenshot when a major-faction or covenant renown level changes.",
        dbKey = "renown",
        silentDbKey = "silentRenown",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", "COVENANT_SANCTUM_RENOWN_LEVEL_CHANGED" },
        -- Blizzard waits 1s, then fades the banner in (label startDelay 0.5 + 0.16).
        eventMinDelay = { MAJOR_FACTION_RENOWN_LEVEL_CHANGED = 1.8 },
        describe = function(event, ...)
            if event == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
                local majorFactionID, newRenownLevel = ...
                local data = C_MajorFactions.GetMajorFactionData(majorFactionID)
                return "Renown " .. tostring(newRenownLevel) .. " with " .. tostring(data and data.name or majorFactionID)
            end
            local newRenownLevel = ...
            return "Covenant renown " .. tostring(newRenownLevel)
        end,
    },
    {
        key = "mount",
        label = "Mounts",
        tooltip = "Capture a screenshot when this account learns a new mount.",
        dbKey = "mount",
        silentDbKey = "silentMount",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "NEW_MOUNT_ADDED" },
        describe = function(event, mountID)
            return DescribeMount(mountID)
        end,
    },
    {
        key = "pet",
        label = "Battle pets",
        tooltip = "Capture a screenshot when this account collects a new battle-pet species.",
        dbKey = "pet",
        silentDbKey = "silentPet",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "NEW_PET_ADDED" },
        describe = function(event, battlePetGUID)
            return DescribePet(battlePetGUID)
        end,
    },
    {
        key = "transmogSet",
        label = "Transmog sets",
        tooltip = "Capture a screenshot when an official Collections journal set becomes complete.",
        dbKey = "transmogSet",
        silentDbKey = "silentTransmogSet",
        defaultEnabled = true,
        defaultSilent = false,
        events = { "TRANSMOG_COLLECTION_SOURCE_ADDED", "TRANSMOG_COSMETIC_COLLECTION_SOURCE_ADDED" },
        reset = BaselineCollectedTransmogSets,
        describe = function(event, sourceID)
            return DescribeTransmogSetComplete(sourceID)
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
    if def.extraCheckboxes then
        for _, extra in ipairs(def.extraCheckboxes) do
            extra.settingVariable = "MEMORYKEEPER_" .. extra.dbKey
        end
    end
    for _, event in ipairs(def.events) do
        local list = captureTypeByEvent[event]
        if not list then
            list = {}
            captureTypeByEvent[event] = list
        end
        list[#list + 1] = def
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
        if def.extraCheckboxes then
            for _, extra in ipairs(def.extraCheckboxes) do
                if MemoryKeeperDB[extra.dbKey] == nil then
                    MemoryKeeperDB[extra.dbKey] = extra.defaultEnabled
                end
            end
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

    local defs = captureTypeByEvent[event]
    if not defs then return end
    for i = 1, #defs do
        local def = defs[i]

        -- Types with a custom handler check the enabled flag themselves, because some
        -- of their events must run regardless of it.
        if def.handler then
            def.handler(def, event, ...)
        else
            -- describe() runs only while the type is on, so a first is judged against
            -- the table before remember() writes it. remember() still runs when the type
            -- is off, otherwise an event taken while it was disabled would look new later.
            local enabled = MemoryKeeperDB[def.dbKey]
            local reason
            if enabled then
                reason = def.describe(event, ...)
            end
            if def.remember then
                def.remember(event, ...)
            end
            if enabled and reason then
                QueueScreenshot(reason, ScreenshotDelay(def, event), MemoryKeeperDB[def.silentDbKey], def.key)
            end
        end
    end
end)

SLASH_MEMORYKEEPER1 = "/memorykeeper"
SLASH_MEMORYKEEPER2 = "/mk"

local function PrintStatus()
    print("|cff66ccffMemoryKeeper|r status:")
    for _, def in ipairs(captureTypes) do
        local extras = ""
        if def.extraCheckboxes then
            for _, extra in ipairs(def.extraCheckboxes) do
                extras = extras .. string.format(", %s: %s", extra.label, MemoryKeeperDB[extra.dbKey] and "YES" or "NO")
            end
        end
        print(string.format("  %s: %s, silent: %s%s",
            def.label,
            MemoryKeeperDB[def.dbKey] and "ON" or "OFF",
            MemoryKeeperDB[def.silentDbKey] and "YES" or "NO",
            extras))
    end
    print("  Cooldown:", MemoryKeeperDB.cooldown)
    print("  Screenshot delay:", MemoryKeeperDB.screenshotDelay)
    print("  Debug:", MemoryKeeperDB.debug and "ON" or "OFF")
end

SlashCmdList.MEMORYKEEPER = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "status" then
        PrintStatus()
    elseif msg == "debug" then
        MemoryKeeperDB.debug = not MemoryKeeperDB.debug
        print("|cff66ccffMemoryKeeper|r debug:", MemoryKeeperDB.debug and "ON" or "OFF")
    elseif msg == "cleandbuser" then
        if ClearCharacterRecords() then
            print("|cff66ccffMemoryKeeper|r: cleared this character's boss, Mythic+ and delve history.")
        end
    elseif msg == "cleandbfull" then
        ClearAllCharacterRecords()
        print("|cff66ccffMemoryKeeper|r: cleared boss, Mythic+ and delve history for all characters.")
    elseif MemoryKeeper_OpenOptions then
        MemoryKeeper_OpenOptions()
    end
end
