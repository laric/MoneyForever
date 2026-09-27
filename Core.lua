-- MoneyForever tracks the player’s current gold, session changes, and faction-aware
-- alt totals. The database is stored in SavedVariables so account- and realm-scoped
-- character data persists between sessions.
local addonName, addonTable = "MoneyForever", {}
MoneyForever = MoneyForever or {}

local frame = CreateFrame("Frame")
local defaults = {
    version = 1,
    characters = {},
}

-- Ensure the saved-variable database exists and contains the expected structure.
-- The layout is: MoneyForeverDB.characters[realm][character] = { gold, faction, ... }
local function ensureDB()
    if type(MoneyForeverDB) ~= "table" then
        MoneyForeverDB = {}
    end

    for key, value in pairs(defaults) do
        if MoneyForeverDB[key] == nil then
            MoneyForeverDB[key] = value
        end
    end

    if type(MoneyForeverDB.characters) ~= "table" then
        MoneyForeverDB.characters = {}
    end

    return MoneyForeverDB
end

-- Normalize realm names so they can be used as stable keys without whitespace.
local function realmKey(value)
    local realm = value or GetRealmName() or "Unknown Realm"
    return string.gsub(realm, "%s+", "")
end

-- Character names are used directly as keys within each realm table and must
-- include the last name when it exists so characters with the same first name
-- remain distinct.
local function characterKey(value)
    local firstName, lastName = UnitName("player")
    if type(value) == "string" and value ~= "" then
        local firstPart, secondPart = string.match(value, "^(.-)%s+(.-)$")
        if firstPart and secondPart then
            firstName = firstPart
            lastName = secondPart
        else
            firstName = value
            lastName = ""
        end
    end

    if type(firstName) ~= "string" or firstName == "" then
        firstName = "Unknown"
    end

    if type(lastName) ~= "string" then
        lastName = ""
    end

    if lastName ~= "" then
        return firstName .. " " .. lastName
    end

    return firstName
end

-- WoW Forever exposes the character name as first and last parts directly when
-- available. When the last name is not present, it remains empty and the addon
-- stores the single name as the first name.
local function getPlayerNameParts()
    local firstName, lastName = UnitName("player")

    if type(firstName) ~= "string" or firstName == "" then
        firstName = "Unknown"
    end

    if type(lastName) ~= "string" then
        lastName = ""
    end

    return firstName, lastName
end

local function getCurrentFaction()
    local faction = UnitFactionGroup("player")
    if type(faction) ~= "string" or faction == "" then
        return "Neutral"
    end
    return faction
end

local function getCurrentRecord()
    local db = ensureDB()
    local realm = realmKey(GetRealmName())
    local name = characterKey()

    if type(db.characters[realm]) ~= "table" then
        db.characters[realm] = {}
    end

    if type(db.characters[realm][name]) ~= "table" then
        local firstName, lastName = getPlayerNameParts()
        db.characters[realm][name] = {
            gold = 0,
            faction = getCurrentFaction(),
            firstName = firstName,
            lastName = lastName,
            date = "",
            sessionStart = 0,
            sessionNet = 0,
            todayStart = 0,
            todayNet = 0,
        }
    else
        local firstName, lastName = getPlayerNameParts()
        db.characters[realm][name].firstName = firstName
        db.characters[realm][name].lastName = lastName
        db.characters[realm][name].faction = getCurrentFaction()
    end

    return db.characters[realm][name]
end

-- Format a money value from copper into a compact WoW-style string without trailing
-- zero denominations, e.g. 12 c, 5 s, or 1 g 2 s 3 c.
local function formatMoney(value)
    local absValue = math.abs(value)
    local sign = value < 0 and "-" or ""
    local gold = math.floor(absValue / 10000)
    local silver = math.floor((absValue % 10000) / 100)
    local copper = absValue % 100

    local parts = {}
    if gold > 0 then
        table.insert(parts, string.format("%d g", gold))
    end
    if silver > 0 then
        table.insert(parts, string.format("%d s", silver))
    end
    if copper > 0 or #parts == 0 then
        table.insert(parts, string.format("%d c", copper))
    end

    if #parts == 0 then
        return "0 c"
    end

    return sign .. table.concat(parts, " ")
end

-- Return a flat list of all tracked characters for sorting and faction summaries.
local function getPlayerList()
    local db = ensureDB()
    local records = {}
    local currentRealm = realmKey(GetRealmName())
    local currentName = characterKey()

    for realm, chars in pairs(db.characters) do
        if type(chars) == "table" then
            for name, data in pairs(chars) do
                if type(data) == "table" then
                    table.insert(records, {
                        realm = realm,
                        name = name,
                        gold = tonumber(data.gold) or 0,
                        faction = data.faction or getCurrentFaction(),
                        firstName = data.firstName or "",
                        lastName = data.lastName or "",
                    })
                end
            end
        end
    end

    table.sort(records, function(a, b)
        if a.gold == b.gold then
            return a.name < b.name
        end
        return a.gold > b.gold
    end)

    return records, currentRealm, currentName
end

-- Update the current character’s live data: current gold, session change, and daily change.
local function refreshCurrentRecord()
    local currentMoney = GetMoney() or 0
    local record = getCurrentRecord()
    local dateKey = date("%Y-%m-%d", time())

    if record.sessionStart == nil or record.sessionStart == 0 then
        record.sessionStart = currentMoney
        record.sessionNet = 0
    end

    record.faction = getCurrentFaction()

    if record.date ~= dateKey then
        record.date = dateKey
        record.todayStart = currentMoney
        record.todayNet = 0
    end

    record.gold = currentMoney
    record.sessionNet = currentMoney - record.sessionStart
    record.todayNet = currentMoney - record.todayStart
end

-- Public helpers used by the DataBroker display and dropdown menu.
function MoneyForever.GetCurrentGoldText()
    local record = getCurrentRecord()
    refreshCurrentRecord()
    return formatMoney(record.gold)
end

-- Collect just the records for a single faction so alts can be summed and grouped.
local function getFactionRecords(faction)
    local records, currentRealm, currentName = getPlayerList()
    local factionRecords = {}

    for _, entry in ipairs(records) do
        if entry.faction == faction then
            table.insert(factionRecords, entry)
        end
    end

    return factionRecords, currentRealm, currentName
end

local function getFactionTotal(faction)
    local total = 0
    local records = getFactionRecords(faction)

    for _, entry in ipairs(records) do
        total = total + (tonumber(entry.gold) or 0)
    end

    return total
end

local function hasFactionData(faction)
    local records = getFactionRecords(faction)
    return #records > 0
end

function MoneyForever.GetCurrentFactionTotal()
    local currentFaction = getCurrentFaction()
    return getFactionTotal(currentFaction)
end

function MoneyForever.GetSessionText()
    local record = getCurrentRecord()
    refreshCurrentRecord()
    return formatMoney(record.sessionNet)
end

function MoneyForever.GetTodayText()
    local record = getCurrentRecord()
    refreshCurrentRecord()
    return formatMoney(record.todayNet)
end

function MoneyForever.GetTooltipText()
    refreshCurrentRecord()

    local lines = {
        "MoneyForever",
        "Current: " .. MoneyForever.GetCurrentGoldText(),
        "Session: " .. MoneyForever.GetSessionText(),
        "Today: " .. MoneyForever.GetTodayText(),
        "",
    }

    local function addFactionSection(factionName, factionValue)
        if not hasFactionData(factionValue) then
            return
        end

        local records, currentRealm, currentName = getFactionRecords(factionValue)
        local names = {}

        for _, entry in ipairs(records) do
            if not (entry.realm == currentRealm and entry.name == currentName) then
                local realmName = string.gsub(entry.realm, "%s+", "")
                table.insert(names, string.format("%s-%s: %s", entry.name, realmName, formatMoney(entry.gold)))
            end
        end

        table.insert(lines, factionName .. " alts:")
        for _, line in ipairs(names) do
            table.insert(lines, line)
        end
        table.insert(lines, factionName .. " total: " .. formatMoney(getFactionTotal(factionValue)))
        table.insert(lines, "")
    end

    addFactionSection("Alliance", "Alliance")
    addFactionSection("Horde", "Horde")

    return table.concat(lines, "\n")
end

function MoneyForever.GetButtonText()
    local record = getCurrentRecord()
    refreshCurrentRecord()
    return formatMoney(record.gold)
end

local function printSummary()
    print(MoneyForever.GetTooltipText())
end

SLASH_MONEYFOREVER1 = "/moneyforever"
SLASH_MONEYFOREVER2 = "/mf"
SlashCmdList["MONEYFOREVER"] = printSummary

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" or event == "PLAYER_MONEY" or event == "PLAYER_ENTERING_WORLD" then
        refreshCurrentRecord()
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Main dropdown menu builder for the data source. Level 1 shows summary info and
-- faction entries; Level 2 expands into the alt list for the selected faction.
local function buildDropdownMenu(menuFrame, level, menuList)
    local info = UIDropDownMenu_CreateInfo()

    if level == 1 then
        info.isTitle = true
        info.text = "MoneyForever"
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Current: " .. MoneyForever.GetCurrentGoldText()
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Current faction total: " .. formatMoney(MoneyForever.GetCurrentFactionTotal())
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Session: " .. MoneyForever.GetSessionText()
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        info = UIDropDownMenu_CreateInfo()
        info.text = "Today: " .. MoneyForever.GetTodayText()
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        if hasFactionData("Alliance") then
            info = UIDropDownMenu_CreateInfo()
            info.text = "Alliance"
            info.value = "Alliance"
            info.menuList = "Alliance"
            info.hasArrow = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, level)
        end

        if hasFactionData("Horde") then
            info = UIDropDownMenu_CreateInfo()
            info.text = "Horde"
            info.value = "Horde"
            info.menuList = "Horde"
            info.hasArrow = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, level)
        end
    elseif level == 2 and (menuList == "Alliance" or menuList == "Horde") then
        local records = getFactionRecords(menuList)
        local grouped = {}

        for _, entry in ipairs(records) do
            local realm = entry.realm or "Unknown Realm"
            if not grouped[realm] then
                grouped[realm] = {}
            end
            table.insert(grouped[realm], entry)
        end

        local realmNames = {}
        for realm in pairs(grouped) do
            table.insert(realmNames, realm)
        end
        table.sort(realmNames)

        for _, realm in ipairs(realmNames) do
            local realmEntries = grouped[realm]
            table.sort(realmEntries, function(a, b)
                return (a.name or "") < (b.name or "")
            end)

            info = UIDropDownMenu_CreateInfo()
            info.isTitle = true
            info.text = realm
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, level)

            for _, entry in ipairs(realmEntries) do
                info = UIDropDownMenu_CreateInfo()
                info.text = string.format("%s: %s", entry.name, formatMoney(entry.gold))
                info.notCheckable = true
                UIDropDownMenu_AddButton(info, level)
            end
        end

        info = UIDropDownMenu_CreateInfo()
        info.text = "Total: " .. formatMoney(getFactionTotal(menuList))
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
    end
end

if LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true) then
    local LDB = LibStub:GetLibrary("LibDataBroker-1.1", true)
    MoneyForever.DropDown = CreateFrame("Frame", "MoneyForeverDropDownMenu", UIParent, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(MoneyForever.DropDown, buildDropdownMenu, "MENU")

    MoneyForever.LDB = LDB:NewDataObject("MoneyForever", {
        type = "data source",
        text = "0g 0s 0c",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        label = "MoneyForever",
        OnClick = function(self, button)
            if button == "RightButton" then
                printSummary()
                return
            end
        end,
        OnEnter = function(self)
            ToggleDropDownMenu(1, nil, MoneyForever.DropDown, self, 0, 0)
        end,
        OnLeave = function(self)
            local overSource = self:IsMouseOver()
            local overMenu = MoneyForever.DropDown and MoneyForever.DropDown:IsMouseOver()
            local overList1 = DropDownList1 and DropDownList1:IsShown() and DropDownList1:IsMouseOver()
            local overList2 = DropDownList2 and DropDownList2:IsShown() and DropDownList2:IsMouseOver()

            if not (overSource or overMenu or overList1 or overList2) then
                CloseDropDownMenus()
            end
        end,
    })

    local function updateLDB()
        if MoneyForever.LDB then
            local record = getCurrentRecord()
            refreshCurrentRecord()
            MoneyForever.LDB.text = formatMoney(record.gold)
        end
    end

    frame:SetScript("OnUpdate", function(self, elapsed)
        if not self._moneyInterval then
            self._moneyInterval = 0
        end
        self._moneyInterval = self._moneyInterval + elapsed
        if self._moneyInterval >= 1 then
            self._moneyInterval = 0
            updateLDB()
        end
    end)
end
