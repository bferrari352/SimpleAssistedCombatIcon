local addonName, addon = ...
local addonTitle = C_AddOns.GetAddOnMetadata(addonName, "Title")

local GetTime           = GetTime
local GetActionInfo     = GetActionInfo
local GetBindingKey     = GetBindingKey
local GetBindingText    = GetBindingText
local InCombatLockdown  = InCombatLockdown
local FindSpellOverrideByID = FindSpellOverrideByID
local C_CVar            = C_CVar
local C_Spell           = C_Spell
local C_SpellBook       = C_SpellBook
local C_AssistedCombat  = C_AssistedCombat

local LSM = LibStub("LibSharedMedia-3.0")
local ACR = LibStub("AceConfigRegistry-3.0")
local Masque = LibStub("Masque",true)

local cacheDirty = false
local lastCacheUpdateTime = GetTime()
local BUTTONS_PER_BAR = 12
local spellBindingTextCache = {}
local RotationSpells = {}

local DefaultActionSlotMap = {
    --Default UI Slot mapping https://warcraft.wiki.gg/wiki/Action_slot
    --Eventually will look at making sure other addons work...
    { prefix = "ACTIONBUTTON",          start = 1,  last = 12,  priority = 2 },--Action Bar 1 (Main Bar)
    { prefix = "ACTIONBUTTON",          start = 13, last = 24,  priority = 9 },--Action Bar 1 (Page 2)
    { prefix = "MULTIACTIONBAR3BUTTON", start = 25, last = 36,  priority = 1 },--Action Bar 4 (Right)
    { prefix = "MULTIACTIONBAR4BUTTON", start = 37, last = 48,  priority = 1 },--Action Bar 5 (Left)
    { prefix = "MULTIACTIONBAR2BUTTON", start = 49, last = 60,  priority = 1 },--Action Bar 3 (Bottom Right)
    { prefix = "MULTIACTIONBAR1BUTTON", start = 61, last = 72,  priority = 1 },--Action Bar 2 (Bottom Left)
    { prefix = "ACTIONBUTTON",          start = 73, last = 84,  priority = 1 },--Class Bar 1
    { prefix = "ACTIONBUTTON",          start = 85, last = 96,  priority = 1 },--Class Bar 2
    { prefix = "ACTIONBUTTON",          start = 97, last = 108, priority = 1 },--Class Bar 3
    { prefix = "ACTIONBUTTON",          start = 109,last = 120, priority = 1 },--Class Bar 4
    { prefix = "ACTIONBUTTON",          start = 121,last = 132, priority = 9 },--Action Bar 1 (Skyriding)
  --{ prefix = "UNKNOWN",               start = 133,last = 144, priority = 9 },--Unknown
    { prefix = "MULTIACTIONBAR5BUTTON", start = 145,last = 156, priority = 1 },--Action Bar 6
    { prefix = "MULTIACTIONBAR6BUTTON", start = 157,last = 168, priority = 1 },--Action Bar 7
    { prefix = "MULTIACTIONBAR7BUTTON", start = 169,last = 180, priority = 1 },--Action Bar 8
}
local ActionSlotMap = DefaultActionSlotMap

local Colors = {
	UNLOCKED = CreateColor(0, 1, 0, 1.0),
	USABLE = CreateColor(1.0, 1.0, 1.0, 1.0),
	NOT_USABLE = CreateColor(0.4, 0.4, 0.4, 1.0),
	NOT_ENOUGH_MANA = CreateColor(0.5, 0.5, 1.0, 1.0),
	NOT_IN_RANGE = CreateColor(0.64, 0.15, 0.15, 1.0)
}

local frameStrata = {
    "BACKGROUND",
    "LOW",
    "MEDIUM",
    "HIGH",
    "DIALOG",
    "TOOLTIP",
}

local function IsRelevantAction(actionType, subType)
    return (actionType == "macro" and subType == "spell")
        or (actionType == "spell" and subType ~= "assistedcombat")
end

local function GetBindingForButton(button)
    if not button then return nil end

    local key = GetBindingKey(button)
    if not key then return nil end

    local text = GetBindingText(key, "KEY_")
    if not text or text == "" then return nil end

    text = text:gsub("Mouse Button ", "MB", 1)
    text = text:gsub("Middle Mouse", "MMB", 1)

    return text
end

local function GetKeyBindForSpellID(spellID)
    local OverrideSpellID = FindSpellOverrideByID(spellID)
    if spellBindingTextCache[OverrideSpellID] then
        return spellBindingTextCache[OverrideSpellID]
    end

    for _, bar in ipairs(ActionSlotMap) do
        for i = 1, BUTTONS_PER_BAR do
            local slot = bar.start + i - 1
            local button = bar.prefix .. i
            
            local actionType, id, subType = GetActionInfo(slot)

            if IsRelevantAction(actionType, subType) and id == OverrideSpellID then
                local text = GetBindingForButton(button)
                if text then
                    spellBindingTextCache[OverrideSpellID] = text
                    return text
                end
            end
        end
    end
end

local function UpdateCache()
    wipe(spellBindingTextCache)
    for _, spellID in ipairs(C_AssistedCombat.GetRotationSpells()) do
        if C_SpellBook.IsSpellInSpellBook(spellID) then
            GetKeyBindForSpellID(spellID)
        end
    end
end

local function HideLikelyMasqueRegions(frame)
    if not Masque then return end
    for _, region in ipairs({ frame:GetRegions() }) do
        if not frame.__baselineRegions[region] then
            region:Hide()
        end
    end
end

local function LoadActionSlotMap()
    table.sort(DefaultActionSlotMap, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority   -- smaller = higher priority
        end
        return a.start < b.start
    end)

    ActionSlotMap = DefaultActionSlotMap
end

AssistedCombatIconMixin = {}

function AssistedCombatIconMixin:OnLoad()
    self:RegisterEvent("PLAYER_LOGIN")
    self:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    self:RegisterEvent("UPDATE_BINDINGS")
    self:RegisterEvent("SPELL_RANGE_CHECK_UPDATE")
    self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("CVAR_UPDATE")

    self:RegisterForDrag("LeftButton")

    self.spellID = 61304
    self.lastUpdateTime = GetTime()
    self.combatUpdateInterval = C_CVar.GetCVar("assistedCombatIconUpdateRate") or 0.3
    self.updateInterval = 1

    self:SetAttribute("ignoreFramePositionManager", true)

    for _, spellID in ipairs(C_AssistedCombat.GetRotationSpells()) do
        if C_SpellBook.IsSpellInSpellBook(spellID) then
            RotationSpells[spellID] = true
        end
    end

    if Masque then

        self:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 0,
        })

        local set = {}
        for _, r in ipairs({ self:GetRegions() }) do
            set[r] = true
        end
        self.__baselineRegions = set

        self.MSQGroup = Masque:Group(addonTitle)
        Masque:AddType("SACI", {"Icon", "Cooldown","HotKey"})
        self.MSQGroup:AddButton(self,{
            Icon = self.Icon,
            Cooldown = self.Cooldown,
            --HotKey = self.Keybind, --This doesn't work as a Frame. Looking into changing to a Button to make it work..
        }, "SACI")
        
        self.MSQGroup:RegisterCallback(function(Group, Option, Value)
            if Option == "Disabled" and Value == true then
                HideLikelyMasqueRegions(self)
            end
            self:ApplyOptions()
        end)
    end
end

function AssistedCombatIconMixin:OnAddonLoaded()
    self.db = addon.db.profile
    self:ApplyOptions()

end

function AssistedCombatIconMixin:OnEvent(event, ...)
    if event == "SPELL_UPDATE_COOLDOWN" then
        self:UpdateCooldown()
    elseif event == "SPELL_RANGE_CHECK_UPDATE" then
        local spellID, inRange, checksRange = ...
        if spellID ~= self.spellID then return end
        self.spellOutOfRange = checksRange == true and inRange == false
        self:Update()
    elseif event == "PLAYER_REGEN_ENABLED" and self.db.displayMode == "IN_COMBAT" then
        self:SetShown(false)
    elseif event == "PLAYER_REGEN_DISABLED" and self.db.displayMode == "IN_COMBAT" then
        self:SetShown(true)
    elseif event == "PLAYER_TARGET_CHANGED" and self.db.displayMode == "HOSTILE_TARGET" then
        self:SetShown(UnitExists("target") and UnitCanAttack("player", "target"))
    elseif event == "UPDATE_BINDINGS" then
        lastCacheUpdateTime = GetTime()
        cacheDirty = true
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        local now = GetTime()
        if (now - lastCacheUpdateTime) < 3 and InCombatLockdown() then return end
        lastCacheUpdateTime = now

        cacheDirty = true
    elseif event == "PLAYER_LOGIN" then
        LoadActionSlotMap()
    elseif event == "CVAR_UPDATE" then 
        local arg1, arg2 = ...
        if arg1 =="assistedCombatIconUpdateRate" then
            self.combatUpdateInterval = tonumber(arg2) or self.combatUpdateInterval
        end
    end
end

function AssistedCombatIconMixin:OnShow()
    self:SetScript("OnUpdate", self.OnUpdate)
end

function AssistedCombatIconMixin:OnHide()
    self:SetScript("OnUpdate", nil)
end

function AssistedCombatIconMixin:OnUpdate()
    local now = GetTime()
    local interval = InCombatLockdown() and self.combatUpdateInterval or self.updateInterval
    if (now - self.lastUpdateTime) < tonumber(interval) then return end
    self.lastUpdateTime = now

    local doUpdate = false

    if cacheDirty then
        UpdateCache()
        cacheDirty = false
        doUpdate = true
    end

    local nextSpell = C_AssistedCombat.GetNextCastSpell()
    if nextSpell ~= self.spellID and nextSpell ~= 0 and nextSpell ~= nil then
        C_Spell.EnableSpellRangeCheck(self.spellID, false)
        self.spellID = nextSpell
        doUpdate = true
    end

    if doUpdate then 
        self:Update()
        self:UpdateCooldown()
    end
end

function AssistedCombatIconMixin:Update()
    if not self.spellID or not self:IsShown() then return end

    local db = self.db
    local spellID = self.spellID

    local text = db.Keybind.show and GetKeyBindForSpellID(spellID) or ""
    self.Keybind:SetText(text)

    self.Icon:SetTexture(C_Spell.GetSpellTexture(spellID))

    if not db.locked then
        self:SetBackdropBorderColor(Colors.UNLOCKED:GetRGBA())
    else
        local bc = db.border.color
        self:SetBackdropBorderColor(bc.r, bc.g, bc.b, db.border.show and 1 or 0)
    end

	local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID);
    local needsRangeCheck = self.spellID and C_Spell.SpellHasRange(spellID);

	if needsRangeCheck then
		C_Spell.EnableSpellRangeCheck(spellID, true)
		self.spellOutOfRange = C_Spell.IsSpellInRange(spellID) == false
    else
        self.spellOutOfRange = false
	end

	if self.spellOutOfRange then
		self.Icon:SetVertexColor(Colors.NOT_IN_RANGE:GetRGBA());
	elseif isUsable then
		self.Icon:SetVertexColor(Colors.USABLE:GetRGBA());
	elseif notEnoughMana then
		self.Icon:SetVertexColor(Colors.NOT_ENOUGH_MANA:GetRGBA());
	else
		self.Icon:SetVertexColor(Colors.NOT_USABLE:GetRGBA());
	end
end


function AssistedCombatIconMixin:ApplyOptions()

    local db = self.db
    self:ClearAllPoints()
    self:Lock(db.locked)
    self:SetSize(db.iconSize, db.iconSize)
    self:SetPoint(db.position.point, db.position.parent, db.position.point, db.position.X, db.position.Y)

    self:SetFrameStrata(frameStrata[db.position.strata])
    self:Raise()

    local kb = db.Keybind
    self.Keybind:ClearAllPoints()
    self.Keybind:SetPoint(kb.point, self, kb.point, kb.X, kb.Y)
    self.Keybind:SetTextColor(kb.fontColor.r, kb.fontColor.g, kb.fontColor.b, kb.fontColor.a)
    self.Keybind:SetFont(LSM:Fetch(LSM.MediaType.FONT, kb.font), kb.fontSize, kb.fontOutline and "OUTLINE" or "")

    if (not Masque) or (self.MSQGroup and self.MSQGroup.db.Disabled) then
        local border = db.border
        self.Icon:SetPoint("TOPLEFT", border.thickness, -border.thickness)
        self.Icon:SetPoint("BOTTOMRIGHT", -border.thickness, border.thickness)
        self.Icon:SetTexCoord(0.06,0.94,0.06,0.94)

        self:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = border.thickness,
        })
        self:SetBackdropBorderColor(border.color.r, border.color.g, border.color.b, border.show and 1 or 0)
    else
        self:ClearBackdrop()
        self.Icon:ClearAllPoints()
        self.Icon:SetAllPoints()
        self.MSQGroup:ReSkin()
    end
    
    local show =
        not db.locked or
        db.displayMode == "ALWAYS" or
        (db.displayMode == "HOSTILE_TARGET" and UnitCanAttack("player", "target")) or
        (db.displayMode == "IN_COMBAT" and InCombatLockdown())
    self:SetShown(show)

    self:Update()
end


function AssistedCombatIconMixin:UpdateCooldown()
    local spellID = self.spellID
    if not self.db.showCooldownSwipe or not spellID or spellID == 0 then return end

    if spellID == 375982 then --Temporary workaround for Primoridal Storm
        spellID = FindSpellOverrideByID(spellID)
    end
    local cdInfo = C_Spell.GetSpellCooldown(spellID)

    if cdInfo then
        self.Cooldown.currentCooldownType = COOLDOWN_TYPE_NORMAL
        self.Cooldown:SetEdgeTexture("Interface\\Cooldown\\UI-HUD-ActionBar-SecondaryCooldown")
        self.Cooldown:SetSwipeColor(0, 0, 0)
        self.Cooldown:SetDrawEdge(false)
        self.Cooldown:SetCooldown(cdInfo.startTime, cdInfo.duration, cdInfo.modRate)
    else
        self.Cooldown:Clear()
    end
end

function AssistedCombatIconMixin:Lock(lock)
    self:EnableMouse(not lock)
end

function AssistedCombatIconMixin:OnDragStart()
    if self.db.locked then return end
    self:StartMoving()
end

function AssistedCombatIconMixin:OnDragStop()
    self:StopMovingOrSizing()

    local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
    local strata = self.db.position.strata
    self.db.position = {
        strata = strata,
        point = point,
        parent = relativeTo,
        relativePoint = relativePoint,
        X = math.floor(xOfs+0.5),
        Y = math.floor(yOfs+0.5),
    }

    ACR:NotifyChange(addonName)
end


--SACIProfiler:HookMixin(AssistedCombatIconMixin,"AssistedCombatIconMixin")

-- /dump SACIProfiler:Report(5)