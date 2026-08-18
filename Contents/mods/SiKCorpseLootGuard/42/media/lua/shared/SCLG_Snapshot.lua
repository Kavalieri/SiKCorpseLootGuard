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

--- Describe un InventoryItem real con los campos que nos interesan.
---@param item any|nil
---@return table|nil
local function describeItem(item)
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
	return {
		fullType = fullType,
		itemId = safeCall(item, "getID"),
		bodyLocation = bodyLocation,
		condition = safeCall(item, "getCondition"),
		conditionMax = safeCall(item, "getConditionMax"),
		favorite = safeCall(item, "isFavorite") == true,
	}
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
local function collectItems(coll)
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
			if entry.getItem then
				local okUnwrap, unwrapped = pcall(function() return entry:getItem() end)
				if okUnwrap and unwrapped then
					item = unwrapped
				end
			end
			local desc = describeItem(item)
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
			local resolved = nil
			for _, methodName in ipairs({ "getItemType", "getClothingItemName", "getFullType", "getItem" }) do
				if entry[methodName] then
					local okM, val = pcall(entry[methodName], entry)
					if okM and val then
						resolved = tostring(val)
						break
					end
				end
			end
			out[#out + 1] = resolved or "?"
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
			snap.worn = collectItems(worn)
		end
	end

	if opts.attachedMethod then
		local okAttached, attached = pcall(function() return obj[opts.attachedMethod](obj) end)
		if okAttached then
			snap.attached = collectItems(attached)
		end
	end

	if opts.inventoryContainerMethod then
		local okInv, inv = pcall(function()
			local container = obj[opts.inventoryContainerMethod](obj)
			return container and container:getItems() or nil
		end)
		if okInv then
			snap.inventory = collectItems(inv)
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
