-- Enruta cada aviso al observador que aporto la telemetria o, si no existe,
-- al jugador online mas cercano. En SP usa directamente el cliente local.

require "SCLG_Config"
require "SCLG_Sandbox"

if not SCLG_Config.isAuthoritative() then return end

SCLG_CaseNotificationServer = SCLG_CaseNotificationServer or {}

local sent = {}
local notificationCount = 0

local function nowMs()
	return getTimestampMs and getTimestampMs() or 0
end

local function sweepSentIfDue()
	notificationCount = notificationCount + 1
	if (notificationCount % 100) ~= 0 then return end
	local cutoff = nowMs() - (10 * 60 * 1000)
	local stale = {}
	for key, sentAt in pairs(sent) do
		if sentAt < cutoff then stale[#stale + 1] = key end
	end
	for i = 1, #stale do sent[stale[i]] = nil end
end

local function shortCaseId(context)
	local caseId = tostring(context and (context.caseId or (context.pre and context.pre.caseId)) or "?")
	return #caseId > 6 and caseId:sub(-6) or caseId
end

local function playerIdentity(player)
	local username, steamID = "?", "?"
	pcall(function() username = tostring(player:getUsername()) end)
	pcall(function() if player.getSteamID then steamID = tostring(player:getSteamID()) end end)
	return username, steamID
end

local function positionOf(context)
	context = context or {}
	local death = context.death or {}
	local pre = context.pre or context
	return context.x or death.x or pre.x, context.y or death.y or pre.y, context.z or death.z or pre.z
end

local function recipients(context, observation)
	local result = {}
	local okPlayers, players = pcall(function() return getOnlinePlayers and getOnlinePlayers() or nil end)
	if not okPlayers or not players then return result end
	local okSize, size = pcall(function() return players:size() end)
	if not okSize or not size then return result end
	local wantedUser = observation and tostring(observation.observedBy or "") or ""
	local wantedSteam = observation and tostring(observation.observerSteamID or "") or ""
	local x, y, z = positionOf(context)
	local nearest, nearestDistance = nil, math.huge
	for i = 0, size - 1 do
		local okPlayer, player = pcall(function() return players:get(i) end)
		if okPlayer and player then
			local username, steamID = playerIdentity(player)
			if (wantedSteam ~= "" and wantedSteam ~= "?" and steamID == wantedSteam)
				or (wantedUser ~= "" and wantedUser ~= "?" and username == wantedUser) then
				result[1] = player
				return result
			end
			if x ~= nil and y ~= nil and z ~= nil then
				local okPos, px, py, pz = pcall(function() return player:getX(), player:getY(), player:getZ() end)
				if okPos and math.floor(pz or 0) == math.floor(z or 0) then
					local dx, dy = px - x, py - y
					local distance = dx * dx + dy * dy
					if distance < nearestDistance then nearest, nearestDistance = player, distance end
				end
			end
		end
	end
	if nearest and nearestDistance <= (30 * 30) then result[1] = nearest end
	return result
end

---@param context table
---@param observation table|nil
---@param state string candidate|confirmed|moved
---@param count number
function SCLG_CaseNotificationServer.notify(context, observation, state, count)
	if not SCLG_Sandbox.showCaseNotifications() then return end
	local caseId = tostring(context and (context.caseId or (context.pre and context.pre.caseId)) or "?")
	local notificationKey = caseId .. ":" .. tostring(state)
	if sent[notificationKey] then return end
	sweepSentIfDue()
	sent[notificationKey] = nowMs()
	local payload = { state = state, count = tonumber(count) or 0, shortCase = shortCaseId(context) }
	if not (isServer and isServer()) and not (isClient and isClient()) then
		if SCLG_CaseNotificationClient and SCLG_CaseNotificationClient.show then
			SCLG_CaseNotificationClient.show(payload)
		else
			local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
			if player and player.Say then
				player:Say("SCLG: " .. tostring(state) .. " case " .. tostring(payload.shortCase))
			end
		end
		return
	end
	local target = recipients(context, observation)
	for i = 1, #target do
		pcall(sendServerCommand, target[i], SCLG_Config.MOD_ID, "caseNotification", payload)
	end
end
