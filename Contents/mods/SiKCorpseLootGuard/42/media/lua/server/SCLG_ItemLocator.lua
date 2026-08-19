--[[
	SiK Corpse Loot Guard - Localizador autoritativo de items desaparecidos.

	Solo se ejecuta para candidatos de perdida ya detectados. Busca el itemId
	en inventarios de jugadores online y contenedores cargados alrededor del
	cadaver para distinguir desaparicion real de un traslado legitimo. No
	conserva referencias ni modifica ningun inventario.
]]

require "SCLG_Config"
require "SCLG_Sandbox"

if not SCLG_Config.isAuthoritative() then return end

SCLG_ItemLocator = SCLG_ItemLocator or {}

local MAX_ITEMS_PER_SEARCH = 8000
local MAX_NESTED_DEPTH = 3

local function sameId(item, wanted)
	if not item or wanted == nil or not item.getID then return false end
	local ok, itemId = pcall(function() return item:getID() end)
	return ok and itemId ~= nil and tostring(itemId) == tostring(wanted)
end

local function itemsOfContainer(container)
	if not container or not container.getItems then return nil end
	local ok, items = pcall(function() return container:getItems() end)
	return ok and items or nil
end

local function nestedInventory(item)
	if not item or not item.getInventory then return nil end
	local ok, inventory = pcall(function() return item:getInventory() end)
	return ok and inventory or nil
end

local function findInItems(items, wanted, depth, budget)
	if not items or depth > MAX_NESTED_DEPTH or budget.remaining <= 0 then return nil end
	local okSize, size = pcall(function() return items:size() end)
	if not okSize or not size then return nil end
	for i = 0, size - 1 do
		if budget.remaining <= 0 then return nil end
		budget.remaining = budget.remaining - 1
		budget.visited = budget.visited + 1
		local okItem, item = pcall(function() return items:get(i) end)
		if okItem and item then
			if sameId(item, wanted) then return item end
			local childInventory = nestedInventory(item)
			local found = childInventory and findInItems(itemsOfContainer(childInventory), wanted, depth + 1, budget) or nil
			if found then return found end
		end
	end
	return nil
end

local function playerName(player)
	local result = "?"
	pcall(function() result = tostring(player:getUsername()) end)
	return result
end

local function findInPlayers(wanted, budget)
	local okPlayers, players = pcall(function() return getOnlinePlayers and getOnlinePlayers() or nil end)
	local checkedOnline = false
	if okPlayers and players then
		local okSize, size = pcall(function() return players:size() end)
		if okSize and size then
			checkedOnline = size > 0
			for i = 0, size - 1 do
				local okPlayer, player = pcall(function() return players:get(i) end)
				if okPlayer and player then
					local okInventory, inventory = pcall(function() return player:getInventory() end)
					local found = okInventory and findInItems(itemsOfContainer(inventory), wanted, 0, budget) or nil
					if found then return { kind = "player", owner = playerName(player), visited = budget.visited } end
				end
			end
		end
	end
	if not checkedOnline then
		local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
		if player then
			local inventory = player.getInventory and player:getInventory() or nil
			local found = findInItems(itemsOfContainer(inventory), wanted, 0, budget)
			if found then return { kind = "player", owner = playerName(player), visited = budget.visited } end
		end
	end
	return nil
end

local function findInObjectContainers(object, corpse, wanted, budget)
	if not object or object == corpse or budget.remaining <= 0 then return nil end
	if object.getContainer then
		local okContainer, container = pcall(function() return object:getContainer() end)
		local found = okContainer and findInItems(itemsOfContainer(container), wanted, 0, budget) or nil
		if found then return { kind = "world_container", owner = tostring(object), visited = budget.visited } end
	end
	local count = 0
	if object.getContainerCount then
		local ok, value = pcall(function() return object:getContainerCount() end)
		if ok and value then count = tonumber(value) or 0 end
	end
	for i = 0, count - 1 do
		local okContainer, container = pcall(function() return object:getContainerByIndex(i) end)
		local found = okContainer and findInItems(itemsOfContainer(container), wanted, 0, budget) or nil
		if found then return { kind = "world_container", owner = tostring(object), visited = budget.visited } end
	end
	return nil
end

local function findInWorld(corpse, x, y, z, wanted, budget)
	local cell = getCell and getCell() or nil
	if not cell or not cell.getGridSquare then return nil end
	local radius = SCLG_Sandbox.getMovementSearchRadiusTiles()
	for dx = -radius, radius do
		for dy = -radius, radius do
			if budget.remaining <= 0 then return nil end
			local okSquare, square = pcall(function()
				return cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, math.floor(z))
			end)
			if okSquare and square then
				local okObjects, objects = pcall(function() return square:getObjects() end)
				local okSize, size = pcall(function() return okObjects and objects and objects:size() or 0 end)
				if okSize and size then
					for i = 0, size - 1 do
						local okObject, object = pcall(function() return objects:get(i) end)
						local found = okObject and findInObjectContainers(object, corpse, wanted, budget) or nil
						if found then return found end
					end
				end
				local okWorld, worldObjects = pcall(function() return square:getWorldObjects() end)
				local okWorldSize, worldSize = pcall(function() return okWorld and worldObjects and worldObjects:size() or 0 end)
				if okWorldSize and worldSize then
					for i = 0, worldSize - 1 do
						local okWorldObject, worldObject = pcall(function() return worldObjects:get(i) end)
						local okItem, item = pcall(function()
							return okWorldObject and worldObject and worldObject.getItem and worldObject:getItem() or nil
						end)
						budget.remaining = budget.remaining - 1
						budget.visited = budget.visited + 1
						if okItem and sameId(item, wanted) then
							return { kind = "world_item", owner = tostring(worldObject), visited = budget.visited }
						end
					end
				end
			end
		end
	end
	return nil
end

---@param descriptor table
---@param corpse any
---@param x number
---@param y number
---@param z number
---@return table result { found, kind, owner, visited, exhausted }
function SCLG_ItemLocator.locate(descriptor, corpse, x, y, z)
	local wanted = descriptor and descriptor.itemId or nil
	if wanted == nil then
		return { found = false, kind = "unavailable", owner = "missing_item_id", visited = 0, exhausted = false }
	end
	local budget = { remaining = MAX_ITEMS_PER_SEARCH, visited = 0 }
	local result = findInPlayers(wanted, budget)
	if not result and x ~= nil and y ~= nil and z ~= nil then
		result = findInWorld(corpse, x, y, z, wanted, budget)
	end
	if result then
		result.found = true
		result.exhausted = budget.remaining <= 0
		return result
	end
	return { found = false, kind = "not_found", owner = "none", visited = budget.visited,
		exhausted = budget.remaining <= 0 }
end
