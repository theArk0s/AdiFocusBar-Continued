--[[
AdiFocusBar - Smart focus bar for hunters.
Copyright 2010-2013 Adirelle (adirelle@gmail.com)
All rights reserved.
--]]

if select(2, UnitClass("player")) ~= "HUNTER" then return end
local addonName, ns = ...
local addon, Debug = ns.addon, ns.Debug

------------------------------------------------------------------------------
-- Logic
------------------------------------------------------------------------------

local BASE_REGEN = 4.0
local FILLER_GAIN = 14
local GCD_DURATION = 1

-- Upvalues
local fillerShot
local now, hasteFactor = GetTime(), 1
local focus, focusMax = 0, 100
local targetHealthRatio = 1
local targetTimeToLive = 0
local fillerCastingTime = 2
local currentCast, currentCastEndTime = nil, 0
local lastCastSpell, lastCastTime = nil, 0
local lastDireBeast = 0
local focusDump, focusDumpCastingTime
local bloodlustTimeleft

local EstimatePassiveIncome

local zeroMT = { __index = function(t,k) t[k] = 0 return 0 end }
local _cooldowns = setmetatable({}, zeroMT)
local _auras = setmetatable({}, zeroMT)
local costs = setmetatable({}, zeroMT)
local known = {}
local ttls = {}

local cooldowns = setmetatable({}, { __index = function(t, k) return max(0, _cooldowns[k] - now) end})
local auras = setmetatable({}, { __index = function(t, k) return max(0, _auras[k] - now) end})

local function CountTicks(expires, interval, delay)
	if expires and expires > 0 and delay > 0 then
		return floor((expires - now) / interval) - floor((expires - (now + delay)) / interval)
	else
		return 0
	end
end

local function EstimatePassiveIncome_Basic(delay)
	if not delay or delay <= 0 then return 0 end
	return BASE_REGEN * hasteFactor * delay
		+ 5 * CountTicks(_auras.Fervor, 2, delay)
		+ 5 * CountTicks(_auras.DireBeast, 2 / (1.0 + GetMeleeHaste() / 100), delay)
end

—-[[
local function EstimatePassiveIncome_ViperVenom(delay)
	if not delay or delay < 0 then return 0 end
	return EstimatePassiveIncome_Basic(delay)
		+ 3 * CountTicks(_auras.SerpentSting, 3, delay)
end
—-]]

local function EstimatePassiveIncome_RapidRecuperation(delay)
	if not delay or delay < 0 then return 0 end
	return EstimatePassiveIncome_Basic(delay)
		+ 12 * CountTicks(_auras.RapidFire, 3, delay)
end

-- S = [S]pell ids
local S = setmetatable({
	AimedShot       =  19434,
	ArcaneShot      =   3044,
	BestialWrath    =  19574,
	BlackArrow      =   3674,
	BloodFury       =  20572,
	CarefulAim      =  34483,
	ChimeraShot     =  53209,
	CobraShot       =  77767,
	Crows           = 131894,
	DireBeast       = 120679,
	ExplosiveShot   =  53301,
	Fervor          =  82726,
	Fire            =  82926,
	FocusFire       =  82692,
	FreeAimedShot   =  82928,
	Frenzy          =  19623,
	GlaiveToss      = 117050,
	KillCommand     =  34026,
	KillShot        =  53351,
	MasterMarksman  =  34487,
	PowerShot       = 109259,
	Rabid           =  53401,
	RapidFire       =   3045,
	Stampede        = 121818,
	SteadyFocus     =  53224,
	SteadyShot      =  56641,
	FocusingShot	= 152245,

	-- Bloodlust & debuff
	AncientHysteria      =  90355,
	Bloodlust            =   2825,
	Heroism              =  32182,
	Sated                =  57724,
	TimeWrap             =  80353,
	TemporalDisplacement =  80354,
	DrumsOfRage          = 146555
}, { __index = function(t, k)
	if k ~= nil then
		error("Unlisted spell: "..k)
	end
end})

-- N = spell [N]ames
local N = setmetatable({}, {__index = function(t, k)
	local v = k and GetSpellInfo(tonumber(k) or S[k]) or nil
	t[k] = v
	return v
end})

-- Export these tables
ns.SpellIDS = S
ns.SpellNames = N

-- Spells with a focus cost
local costySpells = {
	AimedShot       = true,
	ArcaneShot      = true,
	BestialWrath    = true,
	BlackArrow      = true,
	ChimeraShot     = true,
	Crows           = true,
	ExplosiveShot   = true,
	GlaiveToss      = true,
	KillCommand     = true,
	PowerShot       = true,
}
ns.CostySpells = costySpells

-- Spells considered as DPS cooldowns
local dpsCooldowns = {
	[S.RapidFire] = true,
	[S.Stampede] = true,
	[S.AncientHysteria] = true,
	[S.BloodFury] = true,
}

-- Spells of the GCD (in priority order)
local offGCD = {
	"Fervor",
	"Rabid",
	"BloodFury",
	"AncientHysteria",
	"RapidFire",
	"Stampede",
}

local GetCastingTime
do
	local outOfGCD = {}
	for i, spell in ipairs(offGCD) do
		outOfGCD[S[spell]] = true
	end
	function GetCastingTime(id)
		if not id or outOfGCD[id] then
			return 0
		else
			return max((select(7, GetSpellInfo(id)) or 0) / 1000, GCD_DURATION)
		end
	end
end

local function GetCost(spell)
	if spell == S.CobraShot or spell == S.SteadyShot or spell == S.FocusingShot or spell == N.CobraShot or spell == N.SteadyShot or spell == N.FocusingShot then
		return -FILLER_GAIN
	elseif spell == S.Fervor or spell == N.Fervor then
		return -50
	elseif spell then
		return select(4, GetSpellInfo(spell)) or 0
	end
end

local function BuildCostGetter(name)
	local id = S[name]
	return function() return GetCost(id) end
end

local function BuildAuraGetter(unit, name)
	local filter = (unit == "target") and "PLAYER|HARMFUL" or "PLAYER|HELPFUL"
	return function()
		local expires = select(7, UnitAura(unit, N[name], nil, filter))
		return expires == 0 and math.huge or expires or 0
	end
end

local function BuildCooldownGetter(name)
	local id = S[name]
	return function()
		local start, duration, enable = GetSpellCooldown(id)
		if enable == 1 and start and duration and duration > GCD_DURATION then
			return start + duration
		else
			return 0
		end
	end
end

local GetSpellDefs
GetSpellDefs = function()
	local spells = {}

	local spellMeta = { __index = {
		Aura = function(self, unit, ...)
			local num = select('#', ...)
			if num == 0 then return self:Aura(unit, self.name) end
			if not self.aura then
				self.aura = {}
			end
			for i = 1, num do
				local name = select(i, ...)
				self.aura[name] = BuildAuraGetter(unit, name)
			end
			return self
		end,
		Cost = function(self, spell)
			self.cost = BuildCostGetter(spell or self.name)
			return self
		end,
		Cooldown = function(self, ...)
			local num = select('#', ...)
			if num == 0 then return self:Cooldown(self.name) end
			if not self.cooldown then
				self.cooldown = {}
			end
			for i = 1, num do
				local name = select(i, ...)
				self.cooldown[name] = BuildCooldownGetter(name)
			end
			return self
		end,
		UseASAP = function(self)
			local name, id = self.name, S[self.name]
			if self.cost and self.cooldown and self.cooldown[name] then
				return self:UseWhen(function() return costs[name], cooldowns[name], id end)
			elseif self.cost then
				return self:UseWhen(function() return costs[name], 0, id end)
			elseif self.cooldown and self.cooldown[name] then
				return self:UseWhen(function() return 0, cooldowns[name], id end)
			else
				return self:UseWhen(function() return 0, 0, id end)
			end
			return self
		end,
		UseWhen = function(self, f)
			self.when = f
			return self
		end
	}}

	local function Spell(name, passiveToCheck)
		local spell = setmetatable({ name = name }, spellMeta)
		local id = S[passiveToCheck or name]
		spell.isAvailable = function() return IsPlayerSpell(id) or IsSpellKnown(id) or IsSpellKnown(id, true)  end
		spells[name] = spell
		return spell
	end

	Spell('CarefulAim')

	Spell('KillShot'):Cooldown():UseWhen(function()
		if targetHealthRatio <= 0.2 then
			return 0, cooldowns.KillShot, S.KillShot
		end
	end)

	Spell('BlackArrow'):Cooldown():Cost():Aura('target'):UseWhen(function()
		if targetTimeToLive < 20 then return end
		local timeLeft = max(0, auras.BlackArrow-1)
		if lastCastSpell == S.BlackArrow then
			timeLeft = lastCastTime + 20
		end
		return costs.BlackArrow, max(timeLeft, cooldowns.BlackArrow), S.BlackArrow
	end)

	Spell('KillCommand'):Cooldown():Cost():UseASAP()

	Spell('ChimeraShot'):Cooldown():Cost():UseASAP()

	Spell('ExplosiveShot'):Cooldown():Cost():UseASAP()

	Spell('BloodFury'):Aura('player'):Cooldown():UseASAP()

--[[
	Spell('SerpentSting'):Aura('target'):Cost():UseWhen(function()
		if targetTimeToLive < 15 then return end
		local timeLeft = max(0, auras.SerpentSting - 1.5)
		if timeLeft > 5 or lastCastSpell == S.SerpentSting or lastCastSpell == S.ChimeraShot or currentCast == S.CobraShot then
			return
		elseif timeLeft > 0 then
			if known.ChimeraShot and cooldowns.ChimeraShot < timeLeft then
				return costs.ChimeraShot, max(timeLeft, cooldowns.ChimeraShot), S.ChimeraShot
			elseif known.CobraShot and timeLeft > fillerCastingTime then
				return -FILLER_GAIN, timeLeft - fillerCastingTime, S.CobraShot
			end
		end
		return costs.SerpentSting, timeLeft, S.SerpentSting
	end)
--]]

	Spell('SteadyFocus'):Aura('player'):UseWhen(function()
		if auras.SteadyFocus < 6.5 and (currentCast == S.SteadyShot or lastCastSpell == S.SteadyShot) then
			return -FILLER_GAIN, 0, S.SteadyShot
		else
			return -FILLER_GAIN, max(0, auras.SteadyFocus - fillerCastingTime * 2 - 1) , S.SteadyShot
		end
	end)

	Spell('GlaiveToss'):Cooldown():Cost():UseASAP()

	Spell('PowerShot'):Cooldown():Cost():UseASAP()

	Spell('AimedShot'):Cost():UseWhen(function()
		return costs.AimedShot, 0, S.AimedShot
	end)

	Spell('FreeAimedShot', 'MasterMarksman'):Aura('player', 'Fire'):UseWhen(function()
		if auras.Fire > 0 then
			return 0, 0, S.FreeAimedShot
		end
	end)

	Spell('ArcaneShot'):Cost():UseASAP()

	Spell('SteadyShot'):Cost():UseASAP()

	Spell('CobraShot'):Cost():UseASAP()

	Spell(‘FocusingShot'):Cost():UseASAP()

--[[
	Spell('AspectOfTheHawk'):Aura('player', 'AspectOfTheHawk', 'AspectOfTheIronHawk'):UseWhen(function()
		if auras.AspectOfTheHawk == 0 and auras.AspectOfTheIronHawk == 0 then
			return 0, 0, known.AspectOfTheIronHawk and S.AspectOfTheIronHawk or S.AspectOfTheHawk
		end
	end)
--]]

	Spell('FocusFire'):Aura('player', 'Frenzy', 'FocusFire'):Aura('pet', 'BestialWrath'):UseWhen(function()
		local stack = select(4, UnitAura("player", N.Frenzy, nil, "HELPFUL|PLAYER")) or 0
		if stack < 5 then return end
		return 0, max(
			min(auras.FocusFire, auras.Frenzy),
			auras.BestialWrath
		), S.FocusFire
	end)

	Spell('Fervor'):Aura('player'):Cooldown():UseWhen(function()
		if focus < focusMax - 60 and UnitPower("pet", SPELL_POWER_FOCUS) < UnitPowerMax("pet", SPELL_POWER_FOCUS) - 50 then
			return -50, max(cooldowns.Fervor, auras.Fervor), S.Fervor
		end
	end)

	Spell('DireBeast'):Cooldown():UseWhen(function()
		return 0, max(cooldowns.DireBeast, auras.DireBeast), S.DireBeast
	end).aura = { DireBeast = function() return lastDireBeast+15 end }

	Spell('BestialWrath'):Cooldown('BestialWrath', 'KillCommand'):Aura('pet', 'BestialWrath'):UseWhen(function()
		return 60, max(cooldowns.BestialWrath, cooldowns.KillCommand, auras.BestialWrath), S.BestialWrath
	end)

	Spell('Stampede'):Cooldown():UseASAP()

	Spell('RapidFire'):Cooldown():Aura('player', 'RapidFire', 'AncientHysteria', 'Bloodlust', 'Heroism', 'TimeWrap', 'DrumsOfRage'):UseWhen(function()
		return 0, max(cooldowns.RapidFire, auras.RapidFire, bloodlustTimeleft), S.RapidFire
	end)

	Spell('AncientHysteria'):Cooldown():Aura('player', 'RapidFire', 'AncientHysteria', 'Bloodlust', 'Heroism', 'TimeWrap', 'DrumsOfRage', 'Sated', 'TemporalDisplacement'):UseWhen(function()
		return 0, max(cooldowns.AncientHysteria, bloodlustTimeleft, auras.RapidFire, auras.Sated, auras.TemporalDisplacement), S.AncientHysteria
	end)

	Spell('Rabid'):Cooldown():Aura('pet', 'Rabid', 'BestialWrath'):UseWhen(function()
		local autocastable, autostate = GetSpellAutocast(S.Rabid)
		if autocastable and autostate then
			return
		end
		return 0, max(cooldowns.BestialWrath, cooldowns.Rabid, auras.Rabid), S.Rabid
	end)
--[[
	Spell('Crows'):Cost():Cooldown():Aura('target'):UseWhen(function()
		if targetTimeToLive < 30 then return end
		return costs.Crows, max(cooldowns.Crows, auras.Crows), S.Crows
	end)
--]]

	Spell('Crows'):Cooldown():UseASAP()

	GetSpellDefs = function() return spells end

	return spells
end

local specRotation = { rotations = {} }
local rotationsBySpec = {
	-- Beast Mastery
	[253] = {
		selector = function() return auras.BestialWrath > 0 and "BestialWrath" or "default" end,
		rotations = {
			default = {
				"KillShot",
				"BestialWrath",
				"Crows",
				"KillCommand",
				"GlaiveToss",
				"PowerShot",
				"DireBeast",
				"FocusFire",
				“FocusingShot”,
			},
			BestialWrath = {
				"KillShot",
				"KillCommand",
				"GlaiveToss",
				"Crows",
				"ArcaneShot",
				“FocusingShot”,
			},
			offGCD = offGCD
		},
	},
	-- Marksmanship
	[254] = {
		selector = function()
			return known.CarefulAim and targetHealthRatio >= 0.8 and "CarefulAim" or "default"
		end,
		rotations = {
			default = {
				"SteadyFocus",
				"Crows",
				"ChimeraShot",
				"FreeAimedShot",
				"KillShot",
				"GlaiveToss",
				"PowerShot",
				"DireBeast",
				“FocusingShot”,
			},
			CarefulAim = {
				"SteadyFocus",
				"ChimeraShot",
				"AimedShot",
				"SteadyShot",
				“FocusingShot”,
			},
			offGCD = offGCD
		}
	},
	-- Survival
	[255] = {
		selector = function() return "default" end,
		rotations = {
			default = {
				"Crows",
				"BlackArrow",
				"KillShot",
				"ExplosiveShot",
				"GlaiveToss",
				"PowerShot",
				"DireBeast",
				“FocusingShot”,
			},
			offGCD = offGCD
		},
	}
}

local updaters = {
	costs = {},
	cooldowns = {},
	auras = {}
}
local calculate = {}

local updateTimer = 0
local spec

local function IncludeSpell(defs, spell)
	local def = defs[spell]
	if not def then
		error("Unknwon spell "..spell)
	elseif def.isAvailable() then
		if not known[spell] then
			known[spell] = S[spell]
			calculate[spell] = def.when
		end
		if def.cost then
			updaters.costs[spell] = def.cost
		end
		if def.cooldown then
			for k, v in pairs(def.cooldown) do
				if not updaters.cooldowns[k] then
					updaters.cooldowns[k] = v
				end
			end
		end
		if def.aura then
			for k, v in pairs(def.aura) do
				if not updaters.auras[k] then
					updaters.auras[k] = v
				end
			end
		end
		return true
	end
end

function addon:SPELLS_CHANGED(event)
	local specGroup = GetSpecialization()
	spec = specGroup and GetSpecializationInfo(specGroup)
	if not spec then return end

	-- Cleanup previous data
	wipe(known)
	wipe(calculate)
	wipe(updaters.costs)
	wipe(updaters.cooldowns)
	wipe(updaters.auras)
	wipe(specRotation.rotations)
	wipe(_auras)
	wipe(_cooldowns)
	wipe(costs)

	local defs = GetSpellDefs()

	-- Build rotation order depending on available spells
	local currentRotation = rotationsBySpec[spec]
	specRotation.selector = currentRotation.selector
	for rotationName, spells in pairs(currentRotation.rotations) do
		local actualRotation = {}
		specRotation.rotations[rotationName] = actualRotation
		for rank, spell in ipairs(spells) do
			if IncludeSpell(defs, spell) then
				tinsert(actualRotation, spell)
			end
		end
		Debug(rotationName, 'rotation:', unpack(actualRotation))
	end

	-- Common spells
	IncludeSpell(defs, 'ArcaneShot')
	IncludeSpell(defs, 'CobraShot')
	IncludeSpell(defs, 'SteadyShot')
	IncludeSpell(defs, 'Fervor')
	IncludeSpell(defs, 'CarefulAim')
	IncludeSpell(defs, ‘FocusingShot)

	-- Estimating income
--[[
	if known.SerpentSting and IsPlayerSpell(118976) then
		EstimatePassiveIncome = EstimatePassiveIncome_ViperVenom
	elseif known.RapidFire and IsPlayerSpell(53232) then
--]]

	if known.RapidFire and IsPlayerSpell(53232) then
		EstimatePassiveIncome = EstimatePassiveIncome_RapidRecuperation
	else
		EstimatePassiveIncome = EstimatePassiveIncome_Basic
	end

	fillerShot = known.CobraShot or known.SteadyShot or known.FocusingShot
	focusDump, focusDumpCastingTime = "ArcaneShot", 1

	self:UNIT_AURA(event, "player")
	self:SPELL_UPDATE_COOLDOWN(event)

	updateTimer = 0
end
addon.PLAYER_TALENT_UPDATE = addon.SPELLS_CHANGED

local function InGCDForecast(prediction, beforeNextAction)
	local twoFillerLimit = beforeNextAction + 2 * fillerCastingTime
	local gcdLimit = beforeNextAction + GCD_DURATION
	local minPool, maxTime = 10, math.huge
	local candidate

	for i, name in ipairs(specRotation.rotations[specRotation.selector()]) do
		local cost, timeLeft, spell = calculate[name]()
		if spell then
			if timeLeft < maxTime then
				maxTime, candidate = timeLeft, spell
			end
			local income = EstimatePassiveIncome(timeLeft)
			minPool = minPool + max(0, cost - income)
			if timeLeft <= twoFillerLimit and prediction + income < cost then
				return fillerShot, max(beforeNextAction, timeLeft - fillerCastingTime)
			elseif timeLeft <= gcdLimit then
				return spell, max(beforeNextAction, timeLeft)
			end
		end
	end

	if maxTime >= beforeNextAction + focusDumpCastingTime - 0.1 and prediction >= minPool + costs[focusDump] then
		return S[focusDump], maxTime - GCD_DURATION
	end

	local fillerLimit = beforeNextAction + fillerCastingTime
	if maxTime >= fillerLimit - 0.1 and prediction + EstimatePassiveIncome(fillerLimit) + FILLER_GAIN <= focusMax then
		return fillerShot, maxTime - fillerCastingTime
	end

	return candidate, maxTime
end

local function SpellForecast(prediction, beforeNextAction)
	local candidate, candidateTime = InGCDForecast(prediction, beforeNextAction)
	for rank, name in ipairs(specRotation.rotations.offGCD) do
		local _, timeLeft, spell = calculate[name]()
		if spell and (addon.useDPSCooldowns or not dpsCooldowns[spell]) then
			if timeLeft < beforeNextAction and currentCast then
				timeLeft = beforeNextAction
			end
			if spell and timeLeft <= candidateTime then
				candidateTime, candidate = timeLeft, spell
				break
			end
		end
	end
	if candidate == fillerShot and known.Fervor and cooldowns.Fervor <= candidateTime and focus <= focusMax - 50 then
		return S.Fervor
	end
	return candidate
end

function addon:Update(event)
	if not spec then return end

	-- Refresh some upvalues
	now = GetTime()
	hasteFactor = 1.0 + GetRangedHaste() / 100
	fillerCastingTime = max(select(7, GetSpellInfo(fillerShot)) / 1000,  GCD_DURATION)
	bloodlustTimeleft = max(auras.AncientHysteria, auras.Bloodlust, auras.Heroism, auras.TimeWrap, auras.DrumsOfRage)

	-- Update the focus upvalues
	focusMax = UnitPowerMax("player", SPELL_POWER_FOCUS)
	focus = self.testMode and ((now*10) % focusMax) or UnitPower("player", SPELL_POWER_FOCUS)

	-- Get the GCD status
	local beforeNextAction
	local gcdStart, gcdDuration, gcdEnable = GetSpellCooldown(S.ArcaneShot)
	if gcdEnable == 1 and gcdStart and gcdDuration and gcdDuration <= GCD_DURATION then
		beforeNextAction = max(gcdStart + gcdDuration - now, 0)
	else
		beforeNextAction = 0
		lastCastSpell = nil -- the GCD of the last spell is done, forget it
	end

	-- Check for a valid target
	local hasTarget = UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")

	-- Update target health upvalue
	targetHealthRatio = hasTarget and (UnitHealth("target") / UnitHealthMax("target")) or 1

	-- Update target time to live
	local guid = hasTarget and UnitGUID("target")
	if not ttls[guid] then
		self:UpdateTTL(event, 'target')
	end
	local ttlData = guid and ttls[guid]
	targetTimeToLive = ttlData and (ttlData.estimatedDeath - now) or math.huge

	-- Check current casting
	local _, startTime, endTime, prediction
	currentCast, _, _, _, startTime, endTime = UnitCastingInfo("player")
	currentCastEndTime = currentCast and max(startTime / 1000 + GCD_DURATION, endTime / 1000) or 0
	if currentCast then
		beforeNextAction = max(beforeNextAction, currentCastEndTime - now)
		prediction = focus - GetCost(currentCast)
	else
		prediction = focus
	end

	-- Marksmanship: use AimedShot as a focus dump with 50% or more haste (CHECK THIS)
	if known.AimedShot then
		local aimedShotCastingTime = GetCastingTime(S.AimedShot)
		if aimedShotCastingTime < 2.5 / 1.5 then
			focusDump, focusDumpCastingTime = "AimedShot", max(1, aimedShotCastingTime)
		else
			focusDump, focusDumpCastingTime = "ArcaneShot", 1
		end
	end

	-- Update the FocusBar
	if self.FocusBar:IsVisible() then
		local nextActionFocus = prediction + EstimatePassiveIncome(beforeNextAction)
		self.FocusBar:SetValues(focus, focusMax)
		self.FocusBar:ReleaseMarks()
		self.FillerBar:SetValues(nextActionFocus > focus and nextActionFocus or nil, focusMax)

		if hasTarget and addon.db.profile.marks then
			-- Update the position of spell marks
			local position = 0
			for i, name in ipairs(specRotation.rotations[specRotation.selector()]) do
				if costySpells[name] then
					local cost, timeLeft, spell = calculate[name]()
					if cost and timeLeft then
						local delta = EstimatePassiveIncome(timeLeft)
						local pos = position + cost - delta
						if pos > 0 and pos < focusMax then
							local countdown = timeLeft and timeLeft > 0 and timeLeft < 9 and format("%.1g", timeLeft) or nil
							self.FocusBar:GetMark():SetPosition(pos, countdown, spell)
						end
						position = position + max(0, cost - EstimatePassiveIncome(timeLeft + GetCastingTime(spell)))
					end
				end
			end
		end
	end

	-- Update the spell forecast
	if self.Forecast:IsVisible() then
		self.Forecast:SetSpell(hasTarget and SpellForecast(prediction, beforeNextAction) or nil)
	end
end

function addon:OnUpdate(elapsed)
	updateTimer = updateTimer - elapsed
	if updateTimer <= 0 then
		updateTimer = updateTimer + 0.2
		self:Update("OnUpdate")
	end
end

function addon:UpdateTTL(event, unit)
	local guid = UnitGUID(unit)
	if not guid then return end

	-- Clear data about non-existant, dead or non-attackable units
	if not UnitExists(unit) or not UnitCanAttack('player', unit) or UnitIsDeadOrGhost(unit) then
		if ttls[guid] then
			ttls[guid] = nil
		end
		return
	end

	local data = ttls[guid]
	if not data then
		-- First seen
		data = {
			estimatedDeath = math.huge,
			measures = {}
		}
		ttls[guid] = data
	elseif now - data.lastSeen < 0.5 then
		-- Update only once every 0.5 seconds
		return
	end

	-- Insert our measure
	data.lastSeen = now
	data.measures[now] = UnitHealth(unit)

	-- Calculate the time and health averages
	local timeSum, healthSum, n = 0.0, 0.0, 0
	for t, h in pairs(data.measures) do
		if now - t > 30 then
			-- Remove measures older than 30 seconds
			data.measures[t] = nil
		else
			timeSum = timeSum + t
			healthSum = healthSum + h
			n = n + 1
		end
	end
	if n > 1 then
		-- Calculate the covariance and variance of time
		local avgTime, avgHealth = timeSum / n, healthSum / n
		local covSum, varSum = 0.0, 0.0
		for t, h in pairs(data.measures) do
			local dt = t - avgTime
			covSum = covSum + dt * (h - avgHealth)
			varSum = varSum + dt * dt
		end
		if covSum == 0 or varSum == 0 then
			-- Health isn't changing
			data.estimatedDeath = math.huge
		else
			-- Simplified formula to calculate the estimated death time
			local estTime = avgTime - avgHealth / (covSum / varSum)
			data.estimatedDeath = estTime > now and estTime or math.huge
		end
	else
		-- Only one measure, can get anything from that
		data.estimatedDeath = math.huge
	end
	Debug('UpdateTTL', event, unit, UnitName(unit), n, data.estimatedDeath - now)
end

function addon:WipeTTLs()
	wipe(ttls)
end

function addon:SPELL_UPDATE_COOLDOWN()
	for name, func in pairs(updaters.cooldowns) do
		local value = func()
		if _cooldowns[name] ~= value then
			updateTimer, _cooldowns[name] = 0, value
		end
	end
end

function addon:UNIT_AURA(_, unit)
	if unit == "player" or unit == "target" or unit == "pet" then
		for name, func in pairs(updaters.auras) do
			local value = func()
			if _auras[name] ~= value then
				updateTimer, _auras[name] = 0, value
			end
		end
		if unit == "player" then
			for name, func in pairs(updaters.costs) do
				local value = func()
				if costs[name] ~= value then
					updateTimer, costs[name] = 0, value
				end
			end
		end
	end
end

function addon:UNIT_STATS(_, unit)
	if unit == "player" then
		updateTimer = 0
	end
end

function addon:UNIT_POWER_FREQUENT(event, unit, powerType)
	if unit == "player" and powerType == "FOCUS" then
		updateTimer = 0
	end
end
addon.UNIT_MAXPOWER = addon.UNIT_POWER_FREQUENT

function addon:UNIT_HEALTH_FREQUENT(event, unit)
	self:UpdateTTL(event, unit)
	if unit == 'target' then
		updateTimer = 0
	end
end

function addon:UPDATE_MOUSEOVER_UNIT(event)
	self:UpdateTTL(event, "mouseover")
end

function addon:UNIT_SPELLCAST_SUCCEEDED(event, unit, _, _, _, spellId)
	if unit == "player" then
		if spellId == 75 then return end -- Ignore auto shots
		lastCastSpell, lastCastTime = spellId, GetTime()
		if lastCastSpell == S.DireBeast then
			lastDireBeast = lastCastTime
		end
		updateTimer = 0
	end
end

function addon:UNIT_SPELLCAST_START(event, unit, _, _, _, spellId)
	if unit == "player" and (spellId == S.CobraShot or spellId == S.SteadyShot) then
		updateTimer = 0
	end
end
addon.UNIT_SPELLCAST_STOP = addon.UNIT_SPELLCAST_START
