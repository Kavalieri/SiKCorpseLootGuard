-- SiK Corpse Loot Guard - relay acotado de diagnostico del dedicado.

require "SCLG_Config"
require "SCLG_Sandbox"
require "SCLG_Log"

if not (isServer and isServer()) or (isClient and isClient()) then return end

local subscribers = {}
local queue = {}
local head = 1
local tail = 0
local dropped = 0
local lastFlushAt = 0
local MODULE = "SiKCorpseLootGuard.Debug"

local function enabled()
	return SCLG_Sandbox.isConsoleLogEnabled() and SCLG_Sandbox.relayServerLogsToClients()
end

local function hasSubscribers()
	local count = 0
	for _ in pairs(subscribers) do count = count + 1 end
	return count > 0
end

local function enqueue(line)
	if not enabled() or not hasSubscribers() then return false end
	line = tostring(line):gsub("\r\n", "\\n"):gsub("[\r\n]", "\\n")
	if #line > 8000 then line = "[SRV][SiKCorpseLootGuard:WARN:DebugRelay] oversized line omitted bytes=" .. tostring(#line) end
	if (tail - head + 1) >= 256 then dropped = dropped + 1 return false end
	tail = tail + 1
	queue[tail] = line
	return true
end

SCLG_Log.setRelaySink(enqueue)

local function usernameOf(player)
	local ok, username = pcall(function() return player and player:getUsername() end)
	if ok and type(username) == "string" and username ~= "" then return username end
	return nil
end

local function recipients()
	local result, seen = {}, {}
	local players = getOnlinePlayers and getOnlinePlayers()
	if players then
		for i = 0, players:size() - 1 do
			local player = players:get(i)
			local username = usernameOf(player)
			if username and subscribers[username] then
				result[#result + 1] = player
				seen[username] = true
			end
		end
	end
	local stale = {}
	for username in pairs(subscribers) do if not seen[username] then stale[#stale + 1] = username end end
	for i = 1, #stale do subscribers[stale[i]] = nil end
	return result
end

local function clearQueue()
	queue, head, tail, dropped = {}, 1, 0, 0
end

local function takeBatch()
	local lines, bytes = {}, 0
	if dropped > 0 then
		local notice = "[SRV][SiKCorpseLootGuard:WARN:DebugRelay] dropped=" .. tostring(dropped)
		lines[#lines + 1], bytes, dropped = notice, #notice, 0
	end
	while head <= tail and #lines < 20 do
		local line = queue[head]
		local extra = #line + (#lines > 0 and 1 or 0)
		if #lines > 0 and bytes + extra > 12000 then break end
		queue[head], head = nil, head + 1
		lines[#lines + 1], bytes = line, bytes + extra
	end
	if head > tail then queue, head, tail = {}, 1, 0 end
	return table.concat(lines, "\n")
end

local function flush()
	local now = getTimestampMs and getTimestampMs() or 0
	if now - lastFlushAt < 250 then return end
	lastFlushAt = now
	if not enabled() then
		subscribers = {}
		clearQueue()
		return
	end
	if head > tail and dropped == 0 then return end
	local target = recipients()
	if #target == 0 then clearQueue() return end
	local payload = takeBatch()
	for i = 1, #target do pcall(sendServerCommand, target[i], MODULE, "batch", { payload = payload }) end
end

local function onClientCommand(module, command, player, args)
	if module ~= MODULE or command ~= "subscribe" then return end
	local username = usernameOf(player)
	if not username then return end
	if enabled() and args and args.enabled == true then subscribers[username] = true else subscribers[username] = nil end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(flush)
