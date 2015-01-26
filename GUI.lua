--[[
AdiFocusBar - Smart focus bar for hunters.
Copyright 2010-2013 Adirelle (adirelle@gmail.com)
All rights reserved.
--]]

if select(2, UnitClass("player")) ~= "HUNTER" then return end
local addonName, ns = ...
local addon, Debug = ns.addon, ns.Debug

local LSM = LibStub('LibSharedMedia-3.0')

------------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------------


local BACKDROPS = {
	solid = {
		edgeFile = [[Interface\AddOns\AdiFocusBar\media\white16x16]], edgeSize = 2,
		borderSize = 2, borderColor = { 0, 0, 0, 0.8 }
	},
	tooltip = {
		edgeFile = [[Interface\Tooltips\UI-Tooltip-Border]], edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
		borderSize = 4, borderColor = { 1, 1, 1, 1 }
	},
	dialog = {
		edgeFile = [[Interface\DialogFrame\UI-DialogBox-Border]], edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
		borderSize = 5, borderColor = { 1, 1, 1, 1 }
	},
}

local WIDTH, HEIGHT = 350, 24

------------------------------------------------------------------------------
-- Marks
------------------------------------------------------------------------------

local function Mark_SetPosition(mark, value, text, icon)
	if value then
		local bar = mark:GetParent()
		local min, max = bar:GetMinMaxValues()
		if value > min and value < max then
			local valueToPixel = bar:GetWidth() / (max - min)
			mark:SetPoint("CENTER", bar, "LEFT", valueToPixel * (value - min), 0)
			mark:Show()
			local t = mark.Text
			if t then
				t:SetShown(not not text)
				if text then
					t:SetText(text)
				end
			end
			local i = mark.Icon
			if i then
				i:SetShown(not not icon)
				if icon then
					i:SetTexture(select(3, GetSpellInfo(icon)))
				end
			end
			return
		end
	end
	mark:Hide()
end

local function SpawnMark(bar)
	local mark = CreateFrame("Frame", nil, bar)
	mark:SetSize(2, HEIGHT)
	mark.SetPosition = Mark_SetPosition

	local line = mark:CreateTexture(nil, "BACKGROUND")
	line:SetPoint("CENTER")
	line:SetSize(2, HEIGHT)
	line:SetTexture([[Interface\Addons\AdiFocusBar\media\white16x16]])

	local text = mark:CreateFontString(nil, "OVERLAY")
	text:SetPoint("CENTER")
	local name, height, flags = _G.GameFontWhiteSmall:GetFont()
	text:SetFont(name, height, "OUTLINE")
	text:Hide()
	mark.Text = text

	local icon = mark:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("CENTER")
	icon:SetSize(HEIGHT * 0.66, HEIGHT * 0.66)
	icon:SetTexCoord(5/64, 59/64, 5/64, 59/64)
	icon:SetAlpha(0.8)
	icon:Hide()
	mark.Icon = icon

	return mark
end

local function FocusBar_GetMark(self)
	local mark = next(self.markPool) or SpawnMark(self)
	self.markPool[mark] = nil
	self.marks[mark] = true
	mark:Show()
	return mark
end

local function FocusBar_ReleaseMarks(self)
	for mark in pairs(self.marks) do
		mark:Hide()
		self.markPool[mark] = true
	end
	wipe(self.marks)
end

------------------------------------------------------------------------------
-- Bar
------------------------------------------------------------------------------

local function Bar_SetValues(bar, newValue, newMax, newMin)
	if newValue and newMax then
		local value, min, max = bar:GetValue(), bar:GetMinMaxValues()
		if min ~= (newMin or 0) or max ~= newMax then
			bar:SetMinMaxValues((newMin or 0), newMax)
		end
		if value ~= newValue then
			bar:SetValue(newValue)
		end
		if not bar:IsShown() then
			bar:Show()
		end
	elseif bar:IsShown() then
		bar:Hide()
	end
end

local function Bar_FixTexture(bar)
	local texture = bar:GetStatusBarTexture()
	local value, min, max = bar:GetValue(), bar:GetMinMaxValues()
	if max ~= min then
		texture:SetTexCoord(0, (value-min)/(max-min), 0, 1)
	end
end

local function Bar_OnValueChanged(bar)
	local value = bar:GetValue()
	addon.Text:SetFormattedText("%d", value)
	bar.Spark:SetPosition(value)
	Bar_FixTexture(bar)
end

------------------------------------------------------------------------------
-- Spell forecast
------------------------------------------------------------------------------

local function ForeCast_UpdateSpell(icon)
	local r, g, b = 1, 1, 1
	if icon.spell then
		if IsSpellInRange(icon.spellName) == 0 then
			r, g, b = 1, 0.3, 0.3
		else
			local usable, nomana = IsUsableSpell(icon.spell)
			if not usable then
				if nomana then
					r, g, b = 0.3, 0.3, 1
				else
					r, g, b = 0.5, 0.5, 0.5
				end
			end
		end
	end
	icon:SetVertexColor(r, g, b)
end

local function Forecast_Update(self, event)
	if self.spell then
		local start, duration, enabled = GetSpellCooldown(self.spell)
		local casting, _, _, _, startTime, endTime = UnitCastingInfo("player")
		if casting and (not enabled or endTime / 1000 > start + duration) then
			enabled, start, duration = 1, startTime / 1000, (endTime - startTime) / 1000
		end
		local channel, _, _, _, startTime, endTime = UnitChannelInfo("unit")
		if channel and (not enabled or endTime / 1000 > start + duration) then
			enabled, start, duration = 1, startTime / 1000, (endTime - startTime) / 1000
		end
		CooldownFrame_SetTimer(self.Cooldown, start, duration, enabled)
	else
		self.Cooldown:Hide()
	end
	self.timer = 0
end

local function Forecast_OnShow(self)
	self:RegisterEvent('SPELL_UPDATE_COOLDOWN')
	self:RegisterEvent('SPELL_UPDATE_USABLE')
	self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
	self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
	self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player")
	self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
	self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
	self:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "player")
	self:Update('OnShow')
end

local function Forecast_OnHide(self)
	self:UnregisterAllEvents()
end

local function Forecast_OnUpdate(self, elapsed)
	local alpha = self.Icon1:GetAlpha()
	if alpha < 1 then
		local alpha = min(1, alpha + elapsed / 0.25)
		self.Icon1:SetAlpha(alpha)
		self.Icon2:SetAlpha(1 - alpha)
	end
	self.timer = self.timer - elapsed
	if self.timer <= 0 then
		self.timer = 0.1
		ForeCast_UpdateSpell(self.Icon1)
		ForeCast_UpdateSpell(self.Icon2)
	end
end

local function Forecast_SetSpell(self, spell)
	if spell == self.spell then return end
	self.spell = spell
	self:Update("SetSpell")

	if self.Icon1.spell == spell then return end
	self.Icon1, self.Icon2 = self.Icon2, self.Icon1
	local icon, texture, _ = self.Icon1
	icon.spell, icon.spellName, _, texture = spell, GetSpellInfo(spell or "")
	if texture then
		icon:SetTexture(texture)
	else
		icon:SetTexture(0, 0, 0)
	end
end

------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------

local function SpawnFrameWithBorder(width, height, name, label, ...)
	local frame = CreateFrame("Frame", addonName..name, addon)
	frame.name = name
	frame:SetSize(width, height)

	frame.Border = CreateFrame("Frame", nil, frame)
	frame.Border:SetFrameLevel(frame:GetFrameLevel()-1)

	frame:SetPoint(...)

	addon:RegisterMovable(frame, function() return addon.db.profile.layout[name] end, addonName..' '..label, frame.Border)

	return frame
end

local function SetBackdrop(frame, backdrop)
	local size = backdrop.borderSize
	frame.Border:SetPoint("TOPLEFT", frame, -size, size)
	frame.Border:SetPoint("BOTTOMRIGHT", frame, size, -size)
	frame.Border:SetBackdrop(backdrop)
	frame.Border:SetBackdropColor(0, 0, 0, 0.8)
	frame.Border:SetBackdropBorderColor(unpack(backdrop.borderColor, 1, 4))
end

function addon:UpdateLook()
	local settings = self.db.profile.look

	backdrop = BACKDROPS[settings.border] or BACKDROPS.solid
	backdrop.bgFile = LSM:Fetch('background', settings.background)
	SetBackdrop(self.Bar, backdrop)
	SetBackdrop(self.Forecast, backdrop)

	local statusbar = LSM:Fetch("statusbar", settings.status)
	local r, g, b = PowerBarColor.FOCUS.r, PowerBarColor.FOCUS.g, PowerBarColor.FOCUS.b
	self.FocusBar:SetStatusBarTexture(statusbar)
	self.FocusBar:SetStatusBarColor(r, g, b)
	self.FillerBar:SetStatusBarTexture(statusbar)
	self.FillerBar:SetStatusBarColor(b, r, g)
end

function addon:LibSharedMedia_SetGlobal(event, mediatype, value)
	if mediatype == 'background' or mediatype == 'statusbar' then
		if event == 'LibSharedMedia_SetGlobal' or value == self.db.profile.look[mediatype] then
			self:UpdateLook()
		end
	end
end

function addon:SetupGUI()
	local bar = SpawnFrameWithBorder(WIDTH, HEIGHT, "Bar", "bar", "BOTTOM", self, 0, 208)
	self.Bar = bar

	local focusBar = CreateFrame("StatusBar", nil, bar)
	focusBar:SetAllPoints()
	focusBar:SetScript('OnMinMaxChanged', Bar_OnValueChanged)
	focusBar:SetScript('OnValueChanged', Bar_OnValueChanged)
	focusBar:SetScript('OnShow', Bar_OnValueChanged)
	focusBar.SetValues = Bar_SetValues
	focusBar.markPool = {}
	focusBar.marks = {}
	focusBar.GetMark = FocusBar_GetMark
	focusBar.ReleaseMarks = FocusBar_ReleaseMarks
	self.FocusBar = focusBar

	local spark = focusBar:CreateTexture(nil, "OVERLAY")
	spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
	spark:SetBlendMode('ADD')
	spark:SetSize(20, HEIGHT*2.5)
	spark.SetPosition = Mark_SetPosition
	focusBar.Spark = spark

	local fillerBar = CreateFrame("StatusBar", nil, bar)
	fillerBar:SetAllPoints(focusBar)
	fillerBar:SetScript('OnMinMaxChanged', Bar_FixTexture)
	fillerBar:SetScript('OnValueChanged', Bar_FixTexture)
	fillerBar.SetValues = Bar_SetValues
	self.FillerBar = fillerBar

	focusBar:SetFrameLevel(fillerBar:GetFrameLevel()+1)

	fillerBar:Hide()

	local text = focusBar:CreateFontString(nil, "OVERLAY", "GameFontWhite")
	text:SetAllPoints(focusBar)
	text:SetJustifyH("RIGHT")
	text:SetJustifyV("MIDDLE")
	text:SetShadowColor(0,0,0,1)
	text:SetShadowOffset(1, -1)
	self.Text = text

	local forecast = SpawnFrameWithBorder(HEIGHT, HEIGHT, "ForeCast", "forecast", "RIGHT", bar, "LEFT", -16, 0)
	forecast.timer = 0
	forecast.Update = Forecast_Update
	forecast.SetSpell = Forecast_SetSpell
	forecast:SetScript('OnShow', Forecast_OnShow)
	forecast:SetScript('OnHide', Forecast_OnHide)
	forecast:SetScript('OnEvent', Forecast_Update)
	forecast:SetScript('OnUpdate', Forecast_OnUpdate)
	self.Forecast = forecast

	local cooldown = CreateFrame("Cooldown", nil, forecast)
	cooldown:SetAllPoints()
	cooldown:SetFrameLevel(forecast:GetFrameLevel()+1)
	forecast.Cooldown = cooldown

	local icon1 = forecast:CreateTexture(nil, "OVERLAY")
	icon1:SetAllPoints()
	icon1:SetTexCoord(5/64, 59/64, 5/64, 59/64)
	forecast.Icon1 = icon1

	local icon2 = forecast:CreateTexture(nil, "OVERLAY")
	icon2:SetAllPoints()
	icon2:SetTexCoord(5/64, 59/64, 5/64, 59/64)
	icon2:SetAlpha(0)
	forecast.Icon2 = icon2

	self:SetScript('OnShow', self.OnShow)
	self:SetScript('OnHide', self.OnHide)
	self:SetScript('OnUpdate', self.OnUpdate)

	self:UpdateMovableLayout()

	LSM.RegisterCallback(self, 'LibSharedMedia_SetGlobal')
	LSM.RegisterCallback(self, 'LibSharedMedia_Registered', 'LibSharedMedia_SetGlobal')
	self:UpdateLook()
end
