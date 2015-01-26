--[[
AdiFocusBar - Smart focus bar for hunters.
Copyright 2010-2013 Adirelle (adirelle@gmail.com)
All rights reserved.
Rejuvenated for 6.0+ by theArk0s (theark0s@gmail.com)
--]]

if select(2, UnitClass("player")) ~= "HUNTER" then return end
local addonName, ns = ...
local addon, Debug = ns.addon, ns.Debug

local LSM = LibStub('LibSharedMedia-3.0')

------------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------------

local options
local function GetOptions()
	if not options then
		local levels = {
			[ns.LEVEL_NOTHING] = "Always",
			[ns.LEVEL_IN_COMBAT] = "In any combat",
			[ns.LEVEL_HIGH_HEALTH_TARGET] = "Against high-health mobs",
			[ns.LEVEL_ELITE_TARGET] = "Against elite mobs",
			[ns.LEVEL_BOSS_FIGHT] = "Against bosses",
			[ns.LEVEL_TESTMODE] = "Never"
		}
		options = {
			name = addonName,
			type = 'group',
			childGroups = 'tab',
			get = function(info)
				return addon.db.profile[info[#info]]
			end,
			args = {
				testMode = {
					name = 'Test Mode',
					type = 'toggle',
					order = 5,
					get = function() return addon.testMode end,
					set = function(_, value)
						addon.testMode = value
						addon:TestVisibility('config')
					end,
				},
				settings = {
					name = 'Settings',
					order = 10,
					type = 'group',
					set = function(info, value)
						addon.db.profile[info[#info]] = value
						addon:TestVisibility('config')
					end,
					args = {
						barThreshold = {
							name = 'Show focus bar ...',
							order = 10,
							type = 'select',
							values = levels
						},
						forecastThreshold = {
							name = 'Show spell forecast ...',
							order = 20,
							type = 'select',
							values = levels
						},
						dpsCooldownThreshold = {
							name = 'Suggest DPS cooldowns ...',
							order = 30,
							type = 'select',
							values = levels
						},
						marks = {
							name = 'Show spell marks',
							order = 40,
							type = 'toggle',
							disabled = function() return addon.db.profile.barThreshold == 5 end,
						},
					}
				},
				layout = {
					name = 'Look & Layout',
					order = 20,
					type = 'group',
					get = function(info)
						return addon.db.profile.look[info[#info]]
					end,
					set = function(info, value, ...)
						addon.db.profile.look[info[#info]] = value
						addon:UpdateLook()
					end,
					args = {
						statusbar = {
							name = "Statusbar",
							order = 10,
							type = 'select',
							control = 'LSM30_Statusbar',
							values = LSM:HashTable('statusbar'),
						},
						background = {
							name = "Background",
							order = 20,
							type = 'select',
							control = 'LSM30_Background',
							values = LSM:HashTable('background'),
						},
						border = {
							name = "Border",
							order = 30,
							type = 'select',
							values = {
								solid = 'Solid',
								tooltip = 'Tooltip',
								dialog = 'Dialog'
							}
						},
						locked = {
							name = function()
								return addon:AreMovablesLocked() and "Unlock" or "Lock"
							end,
							order = 100,
							type = 'execute',
							func = function()
								if addon:AreMovablesLocked() then
									addon:UnlockMovables()
								else
									addon:LockMovables()
								end
							end
						},
						reset = {
							name = 'Reset position',
							order = 110,
							type = 'execute',
							func = function() addon:ResetMovableLayout() end
						}
					}
				},
			},
		}
	end
	return options
end

------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------

function addon:SetupConfig()
	-- Create the config panel
	LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, GetOptions)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, addonName)

	-- Add a macro command to open it
	_G.SlashCmdList["ADIFOCUSBAR"] = function()
		InterfaceOptionsFrame_OpenToCategory(addonName)
	end
	_G.SLASH_ADIFOCUSBAR1 = "/adifocusbar"
	_G.SLASH_ADIFOCUSBAR2 = "/afb"
end
