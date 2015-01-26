--[[
AdiFocusBar - Smart focus bar for hunters.
Copyright 2010-2013 Adirelle (adirelle@gmail.com)
All rights reserved.
--]]

if select(2, UnitClass("player")) ~= "HUNTER" then return end
local addonName, ns = ...

-- Setup the debugging facility
if AdiDebug then
	ns.Debug = AdiDebug:GetSink(addonName)
else
	ns.Debug = function() end
end
local Debug = ns.Debug

-- Create the initial frame
local addon = CreateFrame("Frame", addonName, UIParent)
addon:SetAllPoints()
ns.addon = addon

-- Create the initial frame
addon:SetScript('OnEvent', function(self, event, ...)
	return self[event](self, event, ...)
end)

------------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------------

-- Conditions
ns.LEVEL_NOTHING = 1
ns.LEVEL_IN_COMBAT = 2
ns.LEVEL_HIGH_HEALTH_TARGET = 3
ns.LEVEL_ELITE_TARGET = 4
ns.LEVEL_BOSS_FIGHT = 5
ns.LEVEL_TESTMODE = 6

local DEFAULTS = {
	-- Logic settings
	barThreshold = ns.LEVEL_IN_COMBAT,
	forecastThreshold = ns.LEVEL_ELITE_TARGET,
	dpsCooldownThreshold = ns.LEVEL_BOSS_FIGHT ,
	marks = true,
	-- Layout settings
	layout = { ['*'] = {} },
	-- Look settings
	look = {
		statusbar = 'Bantobar',
		background = 'Solid',
		border = 'solid',
	}
}

addon:RegisterEvent('ADDON_LOADED')
function addon:ADDON_LOADED(event, name)
	if name ~= addonName then return end
	self:UnregisterEvent("ADDON_LOADED")

	LibStub('LibMovable-1.0'):Embed(self)

	self.db = LibStub('AceDB-3.0'):New("AdiFocusBarDB", { profile = DEFAULTS }, true)
	self.db.RegisterCallback(self, "OnProfileChanged", "Reconfigure")
	self.db.RegisterCallback(self, "OnProfileCopied", "Reconfigure")
	self.db.RegisterCallback(self, "OnProfileReset", "Reconfigure")

	self:SetupGUI()
	self:SetupConfig()
	self:Hide()

	self:TestVisibility(event)
end

function addon:Reconfigure()
	self:UpdateLayout()
	self:SPELLS_CHANGED('Reconfigure')
end

------------------------------------------------------------------------------
-- Activation
------------------------------------------------------------------------------

function addon:TestVisibility(event)
	local specGroup = GetSpecialization()
	local spec = specGroup and GetSpecializationInfo(specGroup)
	if not spec then
		Debug('No specialization')
		self:Hide()
		return
	end
	local level = ns.LEVEL_NOTHING
	if UnitAffectingCombat("player") then
		self.testMode = false
		level = ns.LEVEL_IN_COMBAT
		if UnitExists("boss1") then
			level = ns.LEVEL_BOSS_FIGHT
		elseif UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target") then
			if UnitClassification("target") == "worldboss" then
				level = ns.LEVEL_BOSS_FIGHT
			elseif strmatch(UnitClassification("target") or "", "elite") then
				level = ns.LEVEL_ELITE_TARGET
			elseif UnitHealthMax("target") >= 10 * UnitHealthMax("player") then
				level = ns.LEVEL_HIGH_HEALTH_TARGET
			end
		end
	elseif self.testMode then
		level = ns.LEVEL_TESTMODE
	end
	local showBar = level >= addon.db.profile.barThreshold
	local showForecast = level >= addon.db.profile.forecastThreshold
	local useDPSCooldowns = level >= addon.db.profile.dpsCooldownThreshold
	self.Bar:SetShown(showBar)
	self.Forecast:SetShown(showForecast)
	if self.useDPSCooldowns ~= useDPSCooldowns then
		self.useDPSCooldowns = useDPSCooldowns
	end
	self:SetShown(showBar or showForecast)
	if event == 'PLAYER_REGEN_ENABLED' then
		self:WipeTTLs()
	end
end
addon.PLAYER_TARGET_CHANGED = addon.TestVisibility
addon.PLAYER_REGEN_DISABLED = addon.TestVisibility
addon.PLAYER_REGEN_ENABLED = addon.TestVisibility

function addon:OnShow()
	self:RegisterEvent('UNIT_HEALTH_FREQUENT')
	self:RegisterUnitEvent('UNIT_POWER_FREQUENT', 'player')
	self:RegisterUnitEvent('UNIT_MAXPOWER', 'player')
	self:RegisterUnitEvent('UNIT_STATS', 'player')
	self:RegisterEvent('UNIT_AURA')
	self:RegisterEvent('SPELLS_CHANGED')
	self:RegisterEvent('PLAYER_TALENT_UPDATE')
	self:RegisterUnitEvent('UNIT_SPELLCAST_START', 'player')
	self:RegisterUnitEvent('UNIT_SPELLCAST_STOP', 'player')
	self:RegisterUnitEvent('UNIT_SPELLCAST_SUCCEEDED', 'player')
	self:RegisterEvent('SPELL_UPDATE_COOLDOWN')
	self:RegisterEvent('UPDATE_MOUSEOVER_UNIT')

	self:SPELLS_CHANGED()
	self:Update("OnShow")
end

function addon:OnHide()
	self:UnregisterAllEvents()
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
end
