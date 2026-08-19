-- Notificaciones visuales de casos diagnosticados. No muta inventarios.

require "SCLG_Config"
require "SCLG_Sandbox"

local dedicated = isServer and isServer() and not (isClient and isClient())
if dedicated or not SCLG_Sandbox.isModEnabled() then return end

SCLG_CaseNotificationClient = SCLG_CaseNotificationClient or {}

local function translated(key, fallback, ...)
	if getText then
		local ok, value = pcall(getText, key, ...)
		if ok and value and value ~= key then return value end
	end
	return fallback
end

---@param args table
function SCLG_CaseNotificationClient.show(args)
	if not SCLG_Sandbox.showCaseNotifications() then return end
	args = args or {}
	local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
	if not player then return end
	local shortCase = tostring(args.shortCase or "?")
	local count = tostring(args.count or 0)
	local message
	if args.state == "confirmed" then
		message = translated("IGUI_SCLG_CaseConfirmed",
			"SCLG: confirmed loss (" .. count .. ") - case " .. shortCase, count, shortCase)
		if HaloTextHelper and HaloTextHelper.addBadText then
			HaloTextHelper.addBadText(player, message)
		elseif player.Say then
			player:Say(message)
		end
	elseif args.state == "moved" then
		message = translated("IGUI_SCLG_CaseMoved",
			"SCLG: item movement confirmed - case " .. shortCase, shortCase)
		if HaloTextHelper and HaloTextHelper.addGoodText then
			HaloTextHelper.addGoodText(player, message)
		elseif player.Say then
			player:Say(message)
		end
	else
		message = translated("IGUI_SCLG_CaseCandidate",
			"SCLG: possible loss detected - check corpse " .. shortCase, shortCase)
		if player.Say then player:Say(message) end
	end
end

local function onServerCommand(module, command, args)
	if module == SCLG_Config.MOD_ID and command == "caseNotification" then
		SCLG_CaseNotificationClient.show(args)
	end
end

Events.OnServerCommand.Add(onServerCommand)
