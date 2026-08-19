--[[
	SiK Corpse Loot Guard - Instantanea de ropa/objetos de un zombie
	Autor: SiK
	Descripcion: Construye una tabla plana con lo que un zombie lleva
	encima (worn/attached/inventory) mas su outfit, para comparar
	"antes de morir" contra "justo despues de OnZombieDead".

	IMPORTANTE - APIs sin confirmar en scripts vanilla (investigado en la
	arbol de Lua vanilla de la 42.20, no aparecen usadas alli):
	  - zombie:getPersistentOutfitID() - no encontrada en ningun script.
	  - zombie:getOutfitName() - solo confirmada sobre IsoDeadBody (cadaver
	    YA creado), no sobre el zombie vivo.
	  - Metodo real para extraer el tipo de item de cada entrada de
	    ItemVisuals - solo se vio getLastStandString() en vanilla, no
	    aplicable aqui. Se prueban varios nombres plausibles con pcall.
	Por eso TODO lo que toca estos puntos va envuelto en pcall y si falla
	se guarda como nil/"?" en vez de romper el diagnostico. Si en las
	pruebas reales alguno de estos SI existe con otro nombre, ajustar aqui
	unicamente (un solo punto de entrada).
]]

SCLG_Snapshot = SCLG_Snapshot or {}

---@param obj any
---@param method string
---@return any|nil
local function safeCall(obj, method, ...)
	if not obj or not obj[method] then
		return nil
	end
	local ok, result = pcall(obj[method], obj, ...)
	if ok then
		return result
	end
	return nil
end

-- CLAVE (misma leccion ya documentada en GlobalStorageSiK, GS_Subcategories.lua):
-- llamar metodos sobre el item VIVO (InventoryItem) puede fallar con
-- "No implementation found" cuando ese item es una subclase moddeada (ej.
-- ropa de Authentic Z) con dispatch de metodos inestable en Kahlua. Un
-- pcall SI evita que esto rompa el mod, pero el motor sigue volcando la
-- traza completa del error Java a consola de todos modos (confirmado en
-- pruebas reales: decenas de "KahluaUtil.fail" para bodyLocationId pese al
-- pcall) - mucho ruido para un mod que se supone que es silencioso salvo
-- por perdidas reales. El SCRIPT item (zombie.scripting.objects.Item) es
-- una clase estable, nunca subclaseada por tipo de item, asi que su
-- dispatch de metodos nunca falla igual. Por eso getBodyLocation() se
-- resuelve aqui sobre el script item (via fullType), NO sobre el item vivo.
local _scriptItemCache = {}
---@param fullType string|nil
---@return any|nil
local function scriptItemFor(fullType)
	if not fullType or not getScriptManager then
		return nil
	end
	local cached = _scriptItemCache[fullType]
	if cached ~= nil then
		return cached or nil
	end
	local sm = getScriptManager()
	local ok, si = pcall(function() return sm and sm:getItem(fullType) end)
	local result = (ok and si) or false
	_scriptItemCache[fullType] = result
	return result or nil
end

--- En B42, item:getBodyLocation() puede devolver directamente un valor
--- tratable como texto (no necesariamente un objeto con :getId()) -
--- confirmado con evidencia real: incluso usando el script item (mas
--- estable que el item vivo), llamar a :getId() seguia fallando con "No
--- implementation found" en centenares de casos reales. La causa no era la
--- inestabilidad del item vivo, sino que :getId() simplemente no es un
--- metodo valido sobre lo que devuelve getBodyLocation(). Fix real: no
--- llamar NINGUN metodo sobre `loc`, usar tostring() directamente.
---@param loc any
---@return string|nil
local function bodyLocationId(loc)
	if not loc then
		return nil
	end
	local ok, s = pcall(tostring, loc)
	if ok and s then
		return s
	end
	return nil
end

local function isInstance(item, className)
	if not item or not instanceof then return false end
	local ok, result = pcall(instanceof, item, className)
	return ok and result == true
end

local function scalarModDataToken(item)
	local modData = safeCall(item, "getModData")
	if type(modData) ~= "table" then return nil, true end
	local keys = {}
	local unsupported = false
	for key, value in pairs(modData) do
		if #keys >= 32 then
			unsupported = true
			break
		end
		local valueType = type(value)
		if (type(key) == "string" or type(key) == "number")
			and (valueType == "string" or valueType == "number" or valueType == "boolean") then
			keys[#keys + 1] = tostring(key)
		else
			unsupported = true
		end
	end
	table.sort(keys)
	local values = {}
	for i = 1, #keys do
		local key = keys[i]
		local value = modData[key]
		if value == nil then
			local numericKey = tonumber(key)
			if numericKey ~= nil then value = modData[numericKey] end
		end
		local text = tostring(value):gsub("[|;=\r\n]", "_")
		if #text > 96 then text = text:sub(1, 96) .. "..." end
		values[#values + 1] = key:gsub("[|;=\r\n]", "_") .. "=" .. text
	end
	return #values > 0 and table.concat(values, ";") or nil, not unsupported
end

local function itemClass(item)
	if isInstance(item, "Food") then return "food" end
	if isInstance(item, "HandWeapon") then return "weapon" end
	if isInstance(item, "DrainableComboItem") then return "drainable" end
	if isInstance(item, "InventoryContainer") then return "container" end
	if isInstance(item, "Clothing") then return "clothing" end
	return "generic"
end

local function containerChildCount(item)
	if not isInstance(item, "InventoryContainer") then return 0 end
	local inventory = safeCall(item, "getInventory")
	local items = inventory and safeCall(inventory, "getItems") or nil
	local size = items and safeCall(items, "size") or 0
	return tonumber(size) or 0
end

--- Captura acotada del contenido de un wearable que tambien sea contenedor.
--- Es telemetria, no una receta de restauracion: cualquier contenido hace que
--- el descriptor quede fuera de una futura recuperacion automatica, pero debe
--- quedar visible para distinguir outfit original de loot añadido despues.
local function containerChildContentToken(item)
	if not isInstance(item, "InventoryContainer") then return nil, true end
	local remaining, complete = 32, true
	local function clean(value)
		return tostring(value or "?"):gsub("[|;=,%[%]{}\r\n]", "_")
	end
	local function visit(containerItem, depth)
		local inventory = safeCall(containerItem, "getInventory")
		local items = inventory and safeCall(inventory, "getItems") or nil
		local size = tonumber(items and safeCall(items, "size") or 0) or 0
		local rows = {}
		for i = 0, size - 1 do
			if remaining <= 0 then complete = false break end
			local child = nil
			if items and items.get then
				local ok, value = pcall(function() return items:get(i) end)
				if ok then child = value end
			end
			if child then
				remaining = remaining - 1
				local nestedCount = containerChildCount(child)
				local nestedToken = nil
				if nestedCount > 0 then
					if depth < 3 then nestedToken = visit(child, depth + 1) else complete = false end
				end
				local row = clean(safeCall(child, "getFullType")) .. "@"
					.. clean(safeCall(child, "getCondition")) .. "@" .. tostring(nestedCount)
				if nestedToken and nestedToken ~= "" then row = row .. "[" .. nestedToken .. "]" end
				rows[#rows + 1] = row
			end
		end
		return table.concat(rows, ",")
	end
	local tokenValue = visit(item, 1)
	return tokenValue ~= "" and tokenValue or nil, complete
end

--- Describe un InventoryItem real sin conservar su referencia Java. Ademas
--- de identificar la instancia, registra el estado que una futura
--- restauracion necesitaria para decidir si puede ser fiel. Los adaptadores
--- son deliberadamente conservadores: un contenedor con contenido, un item
--- transitorio o modData no escalar queda marcado como no elegible.
---@param item any|nil
---@param sourceCollection string|nil
---@param sourceSlot string|nil
---@return table|nil
local function describeItem(item, sourceCollection, sourceSlot)
	if not item then
		return nil
	end
	local fullType = safeCall(item, "getFullType")
	if not fullType then
		return nil
	end
	local bodyLocation = nil
	local si = scriptItemFor(fullType)
	if si and si.getBodyLocation then
		local ok, loc = pcall(function() return si:getBodyLocation() end)
		if ok and loc then
			bodyLocation = bodyLocationId(loc)
		end
	end
	local className = itemClass(item)
	local modDataToken, modDataComplete = scalarModDataToken(item)
	local childCount = containerChildCount(item)
	local childContentToken, childContentComplete = containerChildContentToken(item)
	local customName = nil
	if safeCall(item, "isCustomName") == true then customName = safeCall(item, "getName") end
	local desc = {
		fullType = fullType,
		itemId = safeCall(item, "getID"),
		bodyLocation = bodyLocation,
		sourceCollection = sourceCollection,
		sourceSlot = sourceSlot,
		itemClass = className,
		condition = safeCall(item, "getCondition"),
		conditionMax = safeCall(item, "getConditionMax"),
		favorite = safeCall(item, "isFavorite") == true,
		customName = customName,
		uses = safeCall(item, "getUses"),
		modDataToken = modDataToken,
		modDataComplete = modDataComplete,
		childCount = childCount,
		childContentToken = childContentToken,
		childContentComplete = childContentComplete,
	}
	if className == "drainable" then
		desc.usedDelta = safeCall(item, "getUsedDelta")
	elseif className == "food" then
		desc.age = safeCall(item, "getAge")
		desc.cooked = safeCall(item, "isCooked")
		desc.burnt = safeCall(item, "isBurnt")
		desc.frozen = safeCall(item, "isFrozen")
		desc.poisonPower = safeCall(item, "getPoisonPower")
	elseif className == "weapon" then
		desc.currentAmmoCount = safeCall(item, "getCurrentAmmoCount")
		desc.roundChambered = safeCall(item, "isRoundChambered")
		desc.containsClip = safeCall(item, "isContainsClip")
	elseif className == "clothing" then
		desc.dirtyness = safeCall(item, "getDirtyness")
		desc.wetness = safeCall(item, "getWetness")
	end
	local transient = fullType == "Base.Maggots" or fullType == "Base.Cockroach"
	desc.transient = transient
	local requiresRichState = className == "weapon" or className == "clothing"
		or className == "food" or className == "drainable" or className == "container"
	desc.descriptorComplete = desc.itemId ~= nil and modDataComplete and childCount == 0 and not requiresRichState
	desc.recoveryEligible = desc.descriptorComplete and not transient
	if transient then
		desc.ineligibleReason = "transient_item"
	elseif className == "weapon" then
		desc.ineligibleReason = "weapon_parts_and_mods_not_fully_serialized"
	elseif className == "clothing" then
		desc.ineligibleReason = "clothing_visual_state_not_fully_serialized"
	elseif className == "food" or className == "drainable" then
		desc.ineligibleReason = "lifecycle_state_not_safe"
	elseif className == "container" then
		desc.ineligibleReason = childCount > 0 and "container_contents_not_serialized" or "container_state_not_fully_serialized"
	elseif childCount > 0 then
		desc.ineligibleReason = "container_contents_not_serialized"
	elseif not modDataComplete then
		desc.ineligibleReason = "complex_or_truncated_moddata"
	elseif desc.itemId == nil then
		desc.ineligibleReason = "missing_item_id"
	end
	return desc
end

local function token(value)
	if value == nil then return "?" end
	return tostring(value):gsub("[|;=\r\n]", "_")
end

---@param desc table|nil
---@return string
function SCLG_Snapshot.descriptorKey(desc)
	if not desc then return "missing" end
	if desc.itemId ~= nil then return "id:" .. token(desc.itemId) end
	return table.concat({ "fallback", token(desc.fullType), token(desc.condition),
		token(desc.bodyLocation), token(desc.sourceCollection), token(desc.sourceSlot) }, "|")
end

---@param desc table|nil
---@return string
function SCLG_Snapshot.descriptorSummary(desc)
	if not desc then return "descriptor=missing" end
	return table.concat({
		"type=" .. token(desc.fullType),
		"itemId=" .. token(desc.itemId),
		"class=" .. token(desc.itemClass),
		"source=" .. token(desc.sourceCollection),
		"resolution=" .. token(desc.resolutionSource),
		"slot=" .. token(desc.sourceSlot or desc.bodyLocation),
		"condition=" .. token(desc.condition) .. "/" .. token(desc.conditionMax),
		"uses=" .. token(desc.uses),
		"usedDelta=" .. token(desc.usedDelta),
		"ammo=" .. token(desc.currentAmmoCount),
		"children=" .. token(desc.childCount),
		"childContent=" .. token(desc.childContentToken),
		"complete=" .. tostring(desc.descriptorComplete == true),
		"eligible=" .. tostring(desc.recoveryEligible == true),
		"ineligibleReason=" .. token(desc.ineligibleReason),
		"modData=" .. token(desc.modDataToken),
	}, "|")
end

---@param obj any
---@return number|nil, number|nil, number|nil
local function positionOf(obj)
	local x, y, z = safeCall(obj, "getX"), safeCall(obj, "getY"), safeCall(obj, "getZ")
	if x ~= nil and y ~= nil and z ~= nil then return x, y, z end
	local square = safeCall(obj, "getSquare")
	if square then
		return safeCall(square, "getX"), safeCall(square, "getY"), safeCall(square, "getZ")
	end
	return nil, nil, nil
end

--- Devuelve el elemento en la posicion `i` (0-indexado) de una coleccion,
--- probando los dos nombres de accesor por indice conocidos en la API de
--- B42: `get(i)` (comun en la mayoria de colecciones tipo ArrayList) y
--- `getItemByIndex(i)` (visto en algunas colecciones especificas de items,
--- ej. AttachedItems, que puede NO exponer `get` sin mas). Probar ambos
--- evita que AttachedItems se quede silenciosamente vacio si su API real
--- no es `get(i)`.
---@param coll any
---@param i number
---@return any|nil
local function indexedGet(coll, i)
	if coll.get then
		local ok, entry = pcall(function() return coll:get(i) end)
		if ok and entry then
			return entry
		end
	end
	if coll.getItemByIndex then
		local ok, entry = pcall(function() return coll:getItemByIndex(i) end)
		if ok and entry then
			return entry
		end
	end
	return nil
end

--- Convierte una coleccion Java (indexada desde 0) en una lista Lua de
--- descriptores de item, tolerando entradas envueltas (algunas colecciones
--- de "worn items" no devuelven el InventoryItem directo sino un wrapper
--- con :getItem()).
---@param coll any|nil
---@return table[]
local function collectItems(coll, sourceCollection)
	local out = {}
	if not coll or not coll.size then
		return out
	end
	local okSize, size = pcall(function() return coll:size() end)
	if not okSize or not size then
		return out
	end
	for i = 0, size - 1 do
		local entry = indexedGet(coll, i)
		if entry then
			local item = entry
			local sourceSlot = safeCall(entry, "getLocation")
			if entry.getItem then
				local okUnwrap, unwrapped = pcall(function() return entry:getItem() end)
				if okUnwrap and unwrapped then
					item = unwrapped
				end
			end
			local desc = describeItem(item, sourceCollection, sourceSlot and tostring(sourceSlot) or nil)
			if desc then
				out[#out + 1] = desc
			end
		end
	end
	return out
end

--- Tipos de item presentes en ItemVisuals (solo para diagnostico: permite
--- distinguir "solo existia como apariencia visual, nunca como
--- InventoryItem real" de una perdida real de inventario).
---@param zombie any
---@return string[]
local function resolveItemVisualType(entry)
	if not entry then return nil end
	for _, methodName in ipairs({ "getItemType", "getClothingItemName", "getFullType", "getItem" }) do
		if entry[methodName] then
			local okM, val = pcall(entry[methodName], entry)
			if okM and val then return tostring(val) end
		end
	end
	return nil
end

local function collectItemVisualTypes(zombie)
	local out = {}
	if not ItemVisuals or not ItemVisuals.new or not zombie or not zombie.getItemVisuals then
		return out
	end
	local ok, visuals = pcall(function()
		local v = ItemVisuals.new()
		zombie:getItemVisuals(v)
		return v
	end)
	if not ok or not visuals then
		return out
	end
	local okSize, size = pcall(function() return visuals:size() end)
	if not okSize or not size then
		return out
	end
	for i = 0, size - 1 do
		local okGet, entry = pcall(function() return visuals:get(i) end)
		if okGet and entry then
			local resolved = resolveItemVisualType(entry)
			out[#out + 1] = resolved or "?"
		end
	end
	return out
end

local function colorToken(color)
	if not color then return nil end
	local r = safeCall(color, "getRedFloat") or safeCall(color, "getR")
	local g = safeCall(color, "getGreenFloat") or safeCall(color, "getG")
	local b = safeCall(color, "getBlueFloat") or safeCall(color, "getB")
	local a = safeCall(color, "getAlphaFloat") or safeCall(color, "getA")
	if type(r) == "number" and type(g) == "number" and type(b) == "number" then
		return string.format("%.6f,%.6f,%.6f,%.6f", r, g, b, tonumber(a) or 1)
	end
	local ok, value = pcall(tostring, color)
	return ok and value or nil
end

local VISUAL_DESCRIPTOR_FIELDS = {
	"fullType", "itemId", "sourceCollection", "sourceSlot", "resolutionSource",
	"condition", "conditionMax", "bodyLocation", "itemClass",
	"colorTint", "hue", "baseTexture", "textureChoice", "decal",
	"totalBlood", "dirtyness", "wetness", "holes", "patches", "favorite",
	"modDataToken", "modDataComplete", "attachedSlot", "childCount",
	"childContentToken", "childContentComplete", "lastStandString",
}

local NUMERIC_VISUAL_FIELDS = {
	condition = true, conditionMax = true, hue = true, baseTexture = true,
	textureChoice = true, totalBlood = true, dirtyness = true, wetness = true,
	holes = true, patches = true, childCount = true,
}

local BOOLEAN_VISUAL_FIELDS = {
	favorite = true, modDataComplete = true, childContentComplete = true,
}

local COMPOSITION_DESCRIPTOR_FIELDS = {
	"fullType", "bodyLocation",
}

local APPEARANCE_DESCRIPTOR_FIELDS = {
	"fullType", "colorTint", "hue", "baseTexture", "textureChoice", "decal",
}

local STATE_DESCRIPTOR_FIELDS = {
	"fullType", "condition", "conditionMax", "totalBlood", "dirtyness", "wetness",
	"holes", "patches", "favorite", "modDataToken", "modDataComplete", "childCount",
	"childContentToken", "childContentComplete",
}

local function visualDescriptorCanonical(desc, fields)
	local values = {}
	fields = fields or VISUAL_DESCRIPTOR_FIELDS
	for i = 1, #fields do
		local fieldName = fields[i]
		local value = desc and desc[fieldName] or nil
		if value == nil then
			values[#values + 1] = "<nil>"
		elseif NUMERIC_VISUAL_FIELDS[fieldName] and tonumber(value) ~= nil then
			-- Evita que el mismo número sea "0.0" en Kahlua cliente y "0"
			-- tras decode/tonumber en servidor, lo que produciría un falso hash.
			values[#values + 1] = string.format("%.12g", tonumber(value))
		else
			values[#values + 1] = tostring(value)
		end
	end
	return table.concat(values, "\31")
end

local function hashDescriptorRows(descriptors, fields)
	local rows = {}
	for i = 1, #(descriptors or {}) do
		rows[#rows + 1] = visualDescriptorCanonical(descriptors[i], fields)
	end
	table.sort(rows)
	local text = table.concat(rows, "\30")
	local hash = 5381
	for i = 1, #text do hash = (hash * 33 + string.byte(text, i)) % 4294967296 end
	return string.format("%08x", hash)
end

--- Huella determinista no criptografica. Sirve para exigir estabilidad entre
--- muestras; el servidor siempre la recalcula y nunca confia en el valor que
--- declare el cliente.
function SCLG_Snapshot.visualEvidenceHash(descriptors)
	return hashDescriptorRows(descriptors, VISUAL_DESCRIPTOR_FIELDS)
end

--- Huellas separadas para no confundir una composicion distinta con sangre,
--- suciedad o dano que cambia legitimamente entre preHit y death.
function SCLG_Snapshot.visualEvidenceHashes(descriptors)
	return {
		full = hashDescriptorRows(descriptors, VISUAL_DESCRIPTOR_FIELDS),
		composition = hashDescriptorRows(descriptors, COMPOSITION_DESCRIPTOR_FIELDS),
		appearance = hashDescriptorRows(descriptors, APPEARANCE_DESCRIPTOR_FIELDS),
		state = hashDescriptorRows(descriptors, STATE_DESCRIPTOR_FIELDS),
	}
end

local function appendSegment(parts, value)
	local text = value == nil and "" or tostring(value)
	parts[#parts + 1] = tostring(#text) .. ":" .. text
end

function SCLG_Snapshot.encodeVisualEvidence(descriptors)
	local records = {}
	for i = 1, #(descriptors or {}) do
		local fields = {}
		for fieldIndex = 1, #VISUAL_DESCRIPTOR_FIELDS do
			appendSegment(fields, descriptors[i][VISUAL_DESCRIPTOR_FIELDS[fieldIndex]])
		end
		appendSegment(records, table.concat(fields))
	end
	return table.concat(records)
end

local function readSegment(raw, position, maxBytes)
	local colon = string.find(raw, ":", position, true)
	if not colon then return nil, position, "missing_length_separator" end
	local lengthText = string.sub(raw, position, colon - 1)
	if lengthText == "" or string.find(lengthText, "[^0-9]") then
		return nil, position, "invalid_length"
	end
	local length = tonumber(lengthText)
	if not length or length < 0 or (maxBytes and length > maxBytes) then
		return nil, position, "field_too_large"
	end
	local first, last = colon + 1, colon + length
	if last > #raw then return nil, position, "truncated_field" end
	return string.sub(raw, first, last), last + 1, nil
end

function SCLG_Snapshot.decodeVisualEvidence(raw, maxDescriptors, maxFieldBytes)
	if type(raw) ~= "string" then return nil, "payload_not_string" end
	local descriptors, position = {}, 1
	while position <= #raw do
		if #descriptors >= (maxDescriptors or 32) then return nil, "too_many_descriptors" end
		local record, nextPosition, recordError = readSegment(raw, position, #raw)
		if recordError then return nil, recordError end
		position = nextPosition
		local desc, fieldPosition = {}, 1
		for fieldIndex = 1, #VISUAL_DESCRIPTOR_FIELDS do
			local fieldName = VISUAL_DESCRIPTOR_FIELDS[fieldIndex]
			local value, following, fieldError = readSegment(record, fieldPosition, maxFieldBytes or 4096)
			if fieldError then return nil, fieldName .. "_" .. fieldError end
			fieldPosition = following
			if value ~= "" then
				if NUMERIC_VISUAL_FIELDS[fieldName] then
					value = tonumber(value)
					if value == nil then return nil, fieldName .. "_not_number" end
				elseif BOOLEAN_VISUAL_FIELDS[fieldName] then
					if value ~= "true" and value ~= "false" then return nil, fieldName .. "_not_boolean" end
					value = value == "true"
				end
				desc[fieldName] = value
			end
		end
		if fieldPosition <= #record then return nil, "record_has_trailing_data" end
		descriptors[#descriptors + 1] = desc
	end
	return descriptors, nil
end

--- Vuelve a evaluar en el servidor si cada descriptor contiene estado
--- suficiente. Los flags del payload cliente se ignoran y se recalculan.
function SCLG_Snapshot.assessClientVisualEvidence(descriptors)
	local complete, eligible, reasons = 0, 0, {}
	for i = 1, #(descriptors or {}) do
		local desc = descriptors[i]
		local scriptItem = scriptItemFor(desc.fullType)
		local encodedType = desc.lastStandString and string.match(desc.lastStandString, "type=([^;]+)") or nil
		local scriptBodyLocation = nil
		if scriptItem and scriptItem.getBodyLocation then
			local ok, value = pcall(function() return scriptItem:getBodyLocation() end)
			if ok then scriptBodyLocation = bodyLocationId(value) end
		end
		local function boundedNumber(value)
			local number = tonumber(value)
			return number ~= nil and number == number and math.abs(number) <= 1000000
		end
		local numericStateValid = boundedNumber(desc.condition) and boundedNumber(desc.conditionMax)
			and boundedNumber(desc.totalBlood) and boundedNumber(desc.dirtyness)
			and boundedNumber(desc.wetness) and boundedNumber(desc.holes) and boundedNumber(desc.patches)
			and (tonumber(desc.conditionMax) or 0) > 0 and (tonumber(desc.condition) or -1) >= 0
			and (tonumber(desc.condition) or 0) <= (tonumber(desc.conditionMax) or 0)
		local supportedClass = desc.itemClass == "clothing" or desc.itemClass == "container"
		local lastStandValid = encodedType == desc.fullType
			and string.find(desc.lastStandString or "", "^version=1;") ~= nil
		local resolvedItem = (desc.resolutionSource == "item_visual_inventory"
			or desc.resolutionSource == "client_item_unique_match") and desc.itemId ~= nil
		local hasCore = scriptItem ~= nil and desc.fullType ~= nil and desc.bodyLocation ~= nil
			and desc.condition ~= nil and desc.conditionMax ~= nil and supportedClass
			and desc.totalBlood ~= nil and desc.dirtyness ~= nil and desc.wetness ~= nil
			and desc.holes ~= nil and desc.patches ~= nil and desc.modDataComplete == true
			and desc.childContentComplete == true and desc.favorite ~= nil and numericStateValid
			and scriptBodyLocation == desc.bodyLocation and (lastStandValid or resolvedItem)
		local damageFree = tonumber(desc.totalBlood) == 0 and tonumber(desc.dirtyness) == 0
			and tonumber(desc.wetness) == 0 and tonumber(desc.holes) == 0 and tonumber(desc.patches) == 0
		desc.descriptorComplete = hasCore
		desc.recoveryEligible = hasCore and damageFree and (tonumber(desc.childCount) or 0) == 0
		desc.transient = desc.fullType == "Base.Maggots" or desc.fullType == "Base.Cockroach"
		if desc.descriptorComplete then complete = complete + 1 end
		if desc.recoveryEligible and not desc.transient then
			eligible = eligible + 1
		else
			if not hasCore then desc.ineligibleReason = "client_descriptor_incomplete"
			elseif not damageFree then desc.ineligibleReason = "visual_damage_locations_not_serialized"
			elseif (tonumber(desc.childCount) or 0) > 0 then desc.ineligibleReason = "container_contents_present"
			elseif desc.transient then desc.ineligibleReason = "transient_item"
			else desc.ineligibleReason = "client_descriptor_not_eligible" end
			reasons[#reasons + 1] = desc.ineligibleReason
		end
	end
	return complete, eligible, reasons
end

local function actualDescriptorPool(obj)
	local pool, seen = {}, {}
	local snapshot = SCLG_Snapshot.build and SCLG_Snapshot.build(obj) or nil
	for _, collectionName in ipairs({ "worn", "attached", "inventory" }) do
		for i = 1, #((snapshot and snapshot[collectionName]) or {}) do
			local desc = snapshot[collectionName][i]
			local identity = desc.itemId ~= nil and ("id:" .. tostring(desc.itemId))
				or (SCLG_Snapshot.descriptorKey(desc) .. ":" .. tostring(i))
			if not seen[identity] then
				seen[identity] = true
				pool[#pool + 1] = desc
			end
		end
	end
	return pool
end

local function copyDescriptor(desc)
	local copy = {}
	for key, value in pairs(desc or {}) do copy[key] = value end
	return copy
end

local function resolveActualDescriptor(pool, used, fullType, expectedBodyLocation)
	local matches = {}
	for i = 1, #pool do
		local candidate = pool[i]
		if not used[i] and candidate.fullType == fullType
			and (expectedBodyLocation == nil or candidate.bodyLocation == expectedBodyLocation
				or candidate.sourceSlot == expectedBodyLocation) then
			matches[#matches + 1] = i
		end
	end
	if #matches ~= 1 then return nil end
	used[matches[1]] = true
	return copyDescriptor(pool[matches[1]])
end

local function collectItemVisualEvidence(obj)
	local out = {}
	if not ItemVisuals or not ItemVisuals.new or not obj or not obj.getItemVisuals then return out end
	local ok, visuals = pcall(function()
		local values = ItemVisuals.new()
		obj:getItemVisuals(values)
		return values
	end)
	if not ok or not visuals then return out end
	local size = tonumber(safeCall(visuals, "size")) or 0
	local pool, used = actualDescriptorPool(obj), {}
	for i = 0, size - 1 do
		local entry = safeCall(visuals, "get", i)
		if entry then
			local fullType = resolveItemVisualType(entry)
			local inventoryItem = safeCall(entry, "getInventoryItem")
			local scriptItem = scriptItemFor(fullType)
			local expectedBodyLocation = scriptItem and bodyLocationId(safeCall(scriptItem, "getBodyLocation")) or nil
			local desc = describeItem(inventoryItem, "client_visual", nil)
			if desc then
				desc.resolutionSource = "item_visual_inventory"
			else
				desc = resolveActualDescriptor(pool, used, fullType, expectedBodyLocation)
				if desc then desc.resolutionSource = "client_item_unique_match" end
			end
			desc = desc or {
				fullType = fullType,
				bodyLocation = expectedBodyLocation,
				itemClass = nil,
				resolutionSource = "visual_only",
				modDataComplete = false,
				childCount = 0,
				childContentComplete = true,
			}
			desc.fullType = fullType or desc.fullType
			desc.colorTint = colorToken(safeCall(entry, "getTint"))
			desc.hue = safeCall(entry, "getHue")
			desc.baseTexture = safeCall(entry, "getBaseTexture")
			desc.textureChoice = safeCall(entry, "getTextureChoice")
			desc.decal = safeCall(entry, "getDecal")
			desc.totalBlood = safeCall(entry, "getTotalBlood")
			desc.holes = safeCall(entry, "getHolesNumber")
			desc.patches = safeCall(entry, "getBasicPatchesNumber")
			desc.attachedSlot = desc.sourceSlot
			-- getLastStandString() desreferencia el InventoryItem internamente.
			-- No invocarlo sobre visuales puros: pcall evitaria romper Lua, pero
			-- el motor puede imprimir igualmente una traza Java muy ruidosa.
			desc.lastStandString = inventoryItem and safeCall(entry, "getLastStandString") or nil
			out[#out + 1] = desc
		end
	end
	return out
end

--- Sonda de hipotesis (ver SCLG_Server.lua, categoria AUTHENTICZ_INSTANCE_FAIL):
--- intenta instanciar (instanceItem, la misma funcion que usa
--- DoZombieInventory() al reconstruir el cadaver desde ItemVisuals) cada
--- fullType con prefijo AuthenticZClothing. presente en `itemVisualTypes`.
--- No añade el item a ningun inventario, solo lo crea y lo descarta - igual
--- de seguro que el sondeo que ya hace CAEC_Utils.lua (mod "Categorías
--- extendidas") en su propia categorizacion, confirmado en logs reales que
--- ese mismo patron de llamada falla para varios AuthenticZClothing.* con
--- "NoSuchMethodError: Translator.getText" (fallo de motor, no de nuestro
--- codigo). Si esta misma falla ocurre tambien DENTRO de
--- DoZombieInventory() sin capturarla, explicaria perdidas silenciosas de
--- ropa Authentic Z al morir - esta sonda lo confirma con datos reales en
--- vez de dejarlo en hipotesis.
---@param itemVisualTypes string[]
---@return table[] results { fullType, ok, error }
function SCLG_Snapshot.probeAuthenticZInstantiation(itemVisualTypes)
	local results = {}
	if not instanceItem or not itemVisualTypes then
		return results
	end
	local seen = {}
	for i = 1, #itemVisualTypes do
		local fullType = itemVisualTypes[i]
		if fullType and tostring(fullType):find("^AuthenticZClothing%.") and not seen[fullType] then
			seen[fullType] = true
			local ok, itemOrErr = pcall(instanceItem, fullType)
			results[#results + 1] = {
				fullType = fullType,
				ok = ok and itemOrErr ~= nil,
				error = (not ok) and tostring(itemOrErr) or nil,
			}
		end
	end
	return results
end

--- Construye una instantanea generica a partir de un objeto y una tabla de
--- NOMBRES de metodo a usar (permite reusar toda la logica de
--- worn/attached/inventory/visuals tanto para IsoZombie como para el
--- IsoDeadBody definitivo, que exponen la misma forma de datos con algunos
--- nombres de metodo distintos - ver SCLG_Snapshot.build /
--- SCLG_Snapshot.buildFromCorpse mas abajo).
---@param obj any
---@param opts table { onlineIdMethod, outfitNameMethod, persistentOutfitIdMethod, wornMethod, attachedMethod, inventoryContainerMethod }
---@return table
function SCLG_Snapshot.buildGeneric(obj, opts)
	local snap = {
		onlineID = nil,
		outfitName = nil,
		persistentOutfitID = nil,
		worn = {},
		attached = {},
		inventory = {},
		itemVisualTypes = {},
		x = nil,
		y = nil,
		z = nil,
		sex = nil,
	}
	if not obj then
		return snap
	end

	if opts.onlineIdMethod then
		local okId, id = pcall(function() return obj[opts.onlineIdMethod](obj) end)
		if okId and id and id >= 0 then
			snap.onlineID = id
		end
	end

	-- Ver nota de cabecera: algunos de estos no confirmados sobre el zombie
	-- vivo en vanilla, envueltos en pcall en cualquier caso.
	if opts.outfitNameMethod then
		snap.outfitName = safeCall(obj, opts.outfitNameMethod)
	end
	if opts.persistentOutfitIdMethod then
		snap.persistentOutfitID = safeCall(obj, opts.persistentOutfitIdMethod)
	end

	snap.x, snap.y, snap.z = positionOf(obj)
	local female = safeCall(obj, "isFemale")
	if female ~= nil then snap.sex = female and "female" or "male" end

	if opts.wornMethod then
		local okWorn, worn = pcall(function() return obj[opts.wornMethod](obj) end)
		if okWorn then
			snap.worn = collectItems(worn, "worn")
		end
	end

	if opts.attachedMethod then
		local okAttached, attached = pcall(function() return obj[opts.attachedMethod](obj) end)
		if okAttached then
			snap.attached = collectItems(attached, "attached")
		end
	end

	if opts.inventoryContainerMethod then
		local okInv, inv = pcall(function()
			local container = obj[opts.inventoryContainerMethod](obj)
			return container and container:getItems() or nil
		end)
		if okInv then
			snap.inventory = collectItems(inv, "inventory")
		end
	end

	snap.itemVisualTypes = collectItemVisualTypes(obj)

	return snap
end

--- Construye la instantanea completa de un zombie VIVO (IsoZombie) en el
--- instante actual.
---@param zombie any
---@return table
function SCLG_Snapshot.build(zombie)
	return SCLG_Snapshot.buildGeneric(zombie, {
		onlineIdMethod = "getOnlineID",
		outfitNameMethod = "getOutfitName",
		persistentOutfitIdMethod = "getPersistentOutfitID",
		wornMethod = "getWornItems",
		attachedMethod = "getAttachedItems",
		inventoryContainerMethod = "getInventory",
	})
end

--- Construye la instantanea del cadaver DEFINITIVO (IsoDeadBody, creado
--- despues de OnZombieDead). Misma forma de datos que SCLG_Snapshot.build,
--- pero usando los nombres de metodo propios de IsoDeadBody
--- (getCharacterOnlineID en vez de getOnlineID, getContainer en vez de
--- getInventory - IsoDeadBody no tiene getPersistentOutfitID).
---@param body any IsoDeadBody
---@return table
function SCLG_Snapshot.buildFromCorpse(body)
	return SCLG_Snapshot.buildGeneric(body, {
		onlineIdMethod = "getCharacterOnlineID",
		outfitNameMethod = "getOutfitName",
		wornMethod = "getWornItems",
		attachedMethod = "getAttachedItems",
		inventoryContainerMethod = "getContainer",
	})
end

--- Solo los tipos de apariencia visual de un objeto (zombie vivo o
--- cadaver), sin el resto de la instantanea - pensado para la telemetria
--- ligera de cliente (ver SCLG_ClientVisualReport.lua), que NO debe
--- ejecutar el resto de la logica de diagnostico, solo leer lo que el
--- cliente ve.
---@param obj any
---@return string[]
function SCLG_Snapshot.visualTypesOnly(obj)
	return collectItemVisualTypes(obj)
end

--- Descriptores completos de lo que el cliente esta renderizando. Solo se
--- transportan como datos planos; no conservan referencias Java.
---@param obj any
---@return table[]
function SCLG_Snapshot.visualEvidenceOnly(obj)
	return collectItemVisualEvidence(obj)
end

---@param descriptors table[]
---@return string[]
function SCLG_Snapshot.visualEvidenceTypes(descriptors)
	local result = {}
	for i = 1, #(descriptors or {}) do result[#result + 1] = descriptors[i].fullType or "?" end
	return result
end
