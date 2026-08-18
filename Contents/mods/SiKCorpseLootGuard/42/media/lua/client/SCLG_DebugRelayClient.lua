-- SiK Corpse Loot Guard - receptor cliente del log del dedicado.

require "SCLG_Sandbox"
require "SCLG_Log"

if not (isClient and isClient()) or (isServer and isServer()) then return end

local MODULE = "SiKCorpseLootGuard.Debug"
local subscribed = false
local lastSubscribeAttemptAt = 0

local function subscribe()
	if subscribed or not SCLG_Sandbox.isConsoleLogEnabled() or not SCLG_Sandbox.relayServerLogsToClients() then return end
	local now = getTimestampMs and getTimestampMs() or 0
	if lastSubscribeAttemptAt > 0 and now - lastSubscribeAttemptAt < 5000 then return end
	lastSubscribeAttemptAt = now
	local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
	if not player then return end
	local ok = pcall(sendClientCommand, player, MODULE, "subscribe", { enabled = true })
	if ok then subscribed = true end
end

local function onCreatePlayer()
	subscribed = false
	lastSubscribeAttemptAt = 0
	subscribe()
end

local function onServerCommand(module, command, args)
	if module == MODULE and command == "batch" then SCLG_Log.printRemotePayload(args and args.payload) end
end

Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(subscribe)
