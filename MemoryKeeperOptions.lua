local ADDON_NAME, MK = ...

local SILENT_LABEL = "Silent notification"
local SILENT_TOOLTIP = "Suppress only the \"Screenshot taken\" confirmation for this type. The screenshot is still saved."

local settingsCategory

local function BuildSettingsPanel()
    local category = Settings.RegisterVerticalLayoutCategory("MemoryKeeper")

    for _, def in ipairs(MK.captureTypes) do
        local enableSetting = Settings.RegisterAddOnSetting(category, def.settingVariable, def.dbKey,
            MemoryKeeperDB, Settings.VarType.Boolean, def.label, def.defaultEnabled)
        local enableInitializer = Settings.CreateCheckbox(category, enableSetting, def.tooltip)

        local silentSetting = Settings.RegisterAddOnSetting(category, def.silentSettingVariable, def.silentDbKey,
            MemoryKeeperDB, Settings.VarType.Boolean, SILENT_LABEL, def.defaultSilent)
        local silentInitializer = Settings.CreateCheckbox(category, silentSetting, SILENT_TOOLTIP)

        silentInitializer:Indent()
        silentInitializer:SetParentInitializer(enableInitializer, function()
            return enableSetting:GetValue()
        end)
    end

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

EventUtil.ContinueOnAddOnLoaded(ADDON_NAME, BuildSettingsPanel)

function MemoryKeeper_OpenOptions()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end
