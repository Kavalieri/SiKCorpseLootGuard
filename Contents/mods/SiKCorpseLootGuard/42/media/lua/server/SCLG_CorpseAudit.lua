--[[
	SiK Corpse Loot Guard - Auditoria del IsoDeadBody definitivo
	Autor: SiK
	Descripcion: OnZombieDead audita el IsoZombie (PRE/DEATH), pero el
	cadaver definitivo que ve el jugador es un IsoDeadBody CREADO DESPUES,
	con su propia representacion (DeadBodyAtlas). Este modulo recoge el
	estado DEATH calculado por SCLG_Server.lua y lo compara, mas tarde,
	contra el IsoDeadBody real via Events.OnDeadBodySpawn, con un respaldo
	de escaneo REAL (scanForUnauditedCorpses, IsoGridSquare:getDeadBodys()
	sobre la casilla de cada muerte pendiente) por si ese evento no llegara
	a dispararse en el servidor - CORREGIDO 2026-08-14: este comentario
	prometia el respaldo desde el principio pero la implementacion real
	solo tenia el evento, sin ningun escaneo; confirmado revisando el
	codigo (no una suposicion) y ya implementado.

	IMPORTANTE - APIs de IsoDeadBody SIN CONFIRMAR en vanilla (investigado
	en el arbol de Lua vanilla de la 42.20): getCharacterOnlineID,
	getContainer, getWornItems, getAttachedItems, getItemVisuals,
	getOutfitName NO aparecen usados en ningun script vanilla (pueden
	existir igualmente via Java sin uso propio en Lua vanilla). Confirmados
	SI: getModData(), getSquare(), isAnimal(), getItem(),
	getStaticMovingObjectIndex(). Por eso:
	  - TODA llamada a estos metodos va protegida (si el metodo no existe,
	    obj[metodo] es nil, y SCLG_Snapshot.buildGeneric ya degrada con
	    pcall sin romper nada).
	  - La correlacion body<->zombie usa POSICION como respaldo (via
	    getSquare(), confirmado) si getCharacterOnlineID no da resultado.
	  - Se registra UNA VEZ que metodos existen realmente sobre el primer
	    IsoDeadBody visto, para poder ajustar esto con datos reales.
]]

require "SCLG_Config"
require "SCLG_Sandbox"
require "SCLG_Log"
require "SCLG_Snapshot"
require "SCLG_FileLog"
require "SCLG_Diagnostics"
require "SCLG_RecoverySimulation"

-- media/lua/server/ NO filtra la carga en B42. Usar la misma fuente de
-- autoridad que el orquestador: SP real tambien debe cargar este modulo.
if not SCLG_Config.isAuthoritative() then
	return
end

-- Este fichero registra su propio evento (OnDeadBodySpawn) de forma
-- independiente de SCLG_Server.lua, asi que necesita su PROPIA comprobacion
-- del interruptor maestro - el "return" temprano de SCLG_Server.lua no basta
-- para impedir que este fichero se registre tambien.
if not SCLG_Sandbox.isModEnabled() then
	return
end

SCLG_CorpseAudit = SCLG_CorpseAudit or {}

--- onlineID (o clave de respaldo) -> { pre=, death=, x=,y=,z=, registeredAt= }
local pending = {}
--- onlineID -> { types = {...}, reportedAt = }
local clientReports = {}
local clientReportSequence = 0
local lastSweepAt = 0
local loggedCorpseApiOnce = false
local ambiguousLoggedAt = {}

--- Cola de recomprobacion tardia (ver SCLG_Sandbox.isPostAnimationRecheckEnabled):
--- key -> { body=IsoDeadBody, onlineID=, firstCorpse=snapshot, dueAt= }.
--- Se conserva la referencia Java del IsoDeadBody durante la ventana de
--- espera (unos segundos, configurable) para poder releer sus objetos mas
--- tarde - a diferencia de `pending`/`cache` en otros modulos, aqui SI hace
--- falta guardar el objeto real porque no hay otra forma de re-consultarlo.
local groundRecheckQueue = {}
local lastGroundRecheckScanAt = 0
local GROUND_RECHECK_SCAN_INTERVAL_MS = 1000

---@return number
local function nowMs()
	if getTimestampMs then
		return getTimestampMs()
	end
	return 0
end

--- Registra el estado DEATH (calculado en SCLG_Server.lua justo despues de
--- OnZombieDead) para compararlo mas tarde contra el IsoDeadBody real.
---@param pre table snapshot previo (visual, ver SCLG_Snapshot.build)
---@param death table snapshot en OnZombieDead
---@param zombie any IsoZombie (solo para leer posicion, no se guarda la referencia)
function SCLG_CorpseAudit.registerDeathStage(pre, death, zombie)
	if not zombie then
		return
	end
	local x, y, z = 0, 0, 0
	pcall(function()
		x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
	end)
	local resolvedOnlineID = death.onlineID or pre.onlineID
	death.onlineID = resolvedOnlineID
	local key = resolvedOnlineID and ("oid:" .. tostring(resolvedOnlineID))
		or ("case:" .. tostring(pre.caseId or (math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z))))
	pending[key] = {
		pre = pre,
		death = death,
		sessionId = pre.sessionId,
		caseId = pre.caseId,
		onlineID = resolvedOnlineID,
		x = x, y = y, z = z,
		registeredAt = nowMs(),
	}
end

--- Guarda lo que el CLIENTE vio (apariencia visual) para un zombie/cadaver
--- concreto por onlineID - telemetria ligera, no ejecuta logica propia.
--- CAMBIO IMPORTANTE (reportado con datos reales): el cliente ahora reporta
--- en dos momentos - "preHit" (primer OnWeaponHitCharacter contra ese
--- zombie, con el modelo TODAVIA vestido) y "death"/"periodic" (respaldo
--- para muertes sin golpe, ej. fuego/atropello). Si el reporte de muerte
--- llega DESPUES y mas pobre que el de preHit (el caso real que motivo
--- esto: al ejecutar OnZombieDead el cliente ya veia el cadaver vacio),
--- NO debe borrar el preHit - se conserva siempre el reporte con MAS
--- prendas vistas, igual criterio que SCLG_Capture.capture() en servidor.
---@param onlineID number
---@param types string[]
---@param extra table|nil
function SCLG_CorpseAudit.reportClientVisual(onlineID, types, extra)
	if not onlineID then
		return
	end
	extra = extra or {}
	types = types or {}
	-- Log SIEMPRE que llega un reporte (pedido explicito tras revisar el
	-- caso onlineID=10410, 2026-08-14): antes esto guardaba en silencio y no
	-- habia forma de saber, mirando el log, si el reporte de cliente para un
	-- cadaver concreto habia llegado o no - solo se podia inferir por
	-- ausencia en la linea de auditoria final. gateado por debug para no
	-- generar ruido en partidas grandes (esto puede llegar muy a menudo).
	if SCLG_Config.enableDebug() then
		SCLG_Log.debug("CorpseAudit", string.format(
			"reportClientVisual recibido | onlineID=%s kind=%s observedBy=%s steamID=%s types=%d outfitName=%s persistentOutfitID=%s clientMs=%s serverMs=%s pos=%s,%s,%s",
			tostring(onlineID), tostring(extra.kind), tostring(extra.observedBy), tostring(extra.observerSteamID), #types,
			tostring(extra.outfitName), tostring(extra.persistentOutfitID),
			tostring(extra.reportedAtClientMs), tostring(nowMs()), tostring(extra.x), tostring(extra.y), tostring(extra.z)))
	end
	local existing = clientReports[onlineID]
	if existing then
		local existingCount = #(existing.types or {})
		if existingCount > 0 and #types <= existingCount then
			return
		end
	end
	clientReportSequence = clientReportSequence + 1
	local receivedAt = nowMs()
	local reportId = SCLG_Diagnostics.sessionId() .. "-CLI-" .. string.format("%06d", clientReportSequence)
	clientReports[onlineID] = {
		types = types,
		reportedAt = receivedAt,
		reportId = reportId,
		kind = extra.kind,
		outfitName = extra.outfitName,
		persistentOutfitID = extra.persistentOutfitID,
		observedBy = extra.observedBy,
		observerSteamID = extra.observerSteamID,
		reportedAtClientMs = extra.reportedAtClientMs,
		x = extra.x, y = extra.y, z = extra.z,
	}
	SCLG_Diagnostics.recordStage({
		sessionId = SCLG_Diagnostics.sessionId(), caseId = reportId, onlineID = onlineID,
		persistentOutfitID = extra.persistentOutfitID, x = extra.x, y = extra.y, z = extra.z,
	}, "CLIENT", "VISUAL_REPORT_ACCEPTED", "sourceOrigin=CLI kind=" .. tostring(extra.kind)
		.. " observedBy=" .. tostring(extra.observedBy) .. " steamID=" .. tostring(extra.observerSteamID)
		.. " types=" .. tostring(#types) .. " clientMs=" .. tostring(extra.reportedAtClientMs)
		.. " serverReceivedMs=" .. tostring(receivedAt))
end

---@param a table|nil
---@param b table|nil
---@return number
local function dist2(a, bx, by)
	if not a then return math.huge end
	local dx, dy = (a.x or 0) - bx, (a.y or 0) - by
	return dx * dx + dy * dy
end

--- Busca la entrada pendiente que mejor corresponde a un IsoDeadBody dado,
--- por onlineID si es posible y si no por posicion (respaldo).
---@param body any
---@return table|nil entry
---@return string|nil key
---@return table correlation
local function findPendingFor(body)
	local okId, bodyOnlineId = pcall(function() return body.getCharacterOnlineID and body:getCharacterOnlineID() or nil end)
	if okId and bodyOnlineId and bodyOnlineId >= 0 then
		local key = "oid:" .. tostring(bodyOnlineId)
		if pending[key] then
			return pending[key], key, { method = "onlineID", confidence = "exact", candidates = 1, distance = 0 }
		end
	end

	-- Respaldo por posicion: el cadaver aparece en la misma baldosa (o muy
	-- cerca) de donde murio el zombie, dentro de una ventana de tiempo
	-- corta. Buscamos la entrada pendiente mas cercana dentro del radio.
	local okSq, square = pcall(function() return body.getSquare and body:getSquare() or nil end)
	if not okSq or not square then
		return nil, nil, { method = "none", confidence = "unmatched", candidates = 0 }
	end
	local okXY, bx, by, bz = pcall(function() return square:getX(), square:getY(), square:getZ() end)
	if not okXY then
		return nil, nil, { method = "none", confidence = "unmatched", candidates = 0 }
	end
	local radius = SCLG_Config.CORPSE_MATCH_RADIUS_TILES
	local bestKey, bestEntry, bestDist = nil, nil, (radius * radius) + 1
	local candidates = 0
	for key, entry in pairs(pending) do
		if math.floor(entry.z or 0) == math.floor(bz or 0) then
			local d = dist2(entry, bx, by)
			if d <= (radius * radius) then
				candidates = candidates + 1
				if d < bestDist then bestKey, bestEntry, bestDist = key, entry, d end
			end
		end
	end
	if candidates == 1 then
		return bestEntry, bestKey, { method = "position", confidence = "unique_proximity", candidates = 1,
			distance = math.sqrt(bestDist), bodyX = bx, bodyY = by, bodyZ = bz }
	end
	if candidates > 1 then
		return nil, nil, { method = "position", confidence = "ambiguous", candidates = candidates,
			distance = math.sqrt(bestDist), bodyX = bx, bodyY = by, bodyZ = bz, nearest = bestEntry }
	end
	return nil, nil, { method = "position", confidence = "unmatched", candidates = 0,
		bodyX = bx, bodyY = by, bodyZ = bz }
end

---@param list string[]
---@return string
local function joined(list)
	return (#(list or {}) > 0) and table.concat(list, ";") or "(ninguno)"
end

--- Numero de elementos EN COMUN entre dos listas de fullType (interseccion,
--- ignorando cantidad/duplicados - solo nos interesa "hay algo compartido o
--- no"). Usado para detectar cambio COMPLETO de outfit (ver categoria
--- OUTFIT_REPLACED mas abajo) sin falsos positivos por orden distinto.
---@param a string[]
---@param b string[]
---@return number
local function overlapCount(a, b)
	local setA = {}
	for i = 1, #(a or {}) do
		setA[a[i]] = true
	end
	local n = 0
	for i = 1, #(b or {}) do
		if setA[b[i]] then
			n = n + 1
		end
	end
	return n
end

--- Clasifica y registra el resultado de auditar un cadaver definitivo
--- contra su estado previo (PRE visual + DEATH).
---@param entry table { pre, death, onlineID }
---@param corpse table snapshot de SCLG_Snapshot.buildFromCorpse
---@param correlation table
---@param sourceLabel string
local function auditCorpse(entry, corpse, correlation, sourceLabel)
	local preVisualCount = #(entry.pre.itemVisualTypes or {})
	local deathTotal = #(entry.death.inventory or {})
	local corpseTotal = #(corpse.inventory or {})
	local corpseVisualCount = #(corpse.itemVisualTypes or {})

	local clientReport = entry.onlineID and clientReports[entry.onlineID] or nil
	local clientTypes = clientReport and clientReport.types or {}

	local category = nil
	if preVisualCount > 0 and deathTotal == 0 and corpseTotal == 0 then
		category = "LOSS_DURING_ZOMBIE_REBUILD"
	elseif deathTotal > 0 and corpseTotal == 0 then
		category = "LOSS_DURING_CORPSE_TRANSFER"
	elseif corpseTotal > 0 and corpseVisualCount == 0 then
		category = "CORPSE_VISUAL_ONLY_LOSS"
	elseif preVisualCount == 0 and deathTotal == 0 and corpseTotal == 0 and #clientTypes > 0 then
		category = "CLIENT_ONLY_VISUAL"
	elseif preVisualCount == 0 and deathTotal == 0 and corpseTotal == 0 then
		category = "EMPTY_POST_NO_BASELINE"
	elseif preVisualCount > 0 and corpseVisualCount > 0 and overlapCount(entry.pre.itemVisualTypes, corpse.itemVisualTypes) == 0 then
		-- NUEVA categoria (2026-08-14, pedida tras revisar casos reales de
		-- zombies con outfit completamente distinto al morir sin quedar
		-- vacios, ej. onlineID=10396/10388): el cadaver NO esta vacio, pero
		-- ninguna prenda visual de antes de morir sigue presente despues -
		-- el motor materializo un conjunto totalmente distinto, no solo
		-- perdio objetos sueltos. Categoria separada de las de perdida
		-- porque aqui no hay perdida cuantitativa, solo sustitucion.
		category = "OUTFIT_REPLACED"
	end

	local auditDetails = string.format(
		"source=%s correlation=%s confidence=%s candidates=%s distance=%s ageDeathToCorpseMs=%s preVisuals=%d deathInventory=%d corpseInventory=%d corpseVisuals=%d",
		tostring(sourceLabel), tostring(correlation.method), tostring(correlation.confidence),
		tostring(correlation.candidates), tostring(correlation.distance),
		tostring(nowMs() - (entry.registeredAt or nowMs())), preVisualCount, deathTotal, corpseTotal, corpseVisualCount)
	SCLG_Diagnostics.stats().corpseAudits = SCLG_Diagnostics.stats().corpseAudits + 1

	-- Resumen compacto siempre visible: permite comparar lo observado por el
	-- cliente con cada fase autoritativa sin activar el DETAIL de alto volumen.
	-- "received + 0" es distinto de "missing + 0" y diagnostica si el cliente
	-- vio realmente un zombie vacio o si nunca llego un reporte.
	SCLG_Log.info("ClientServerCompare", string.format(
		"case=%s onlineID=%s clientReport=%s clientKind=%s clientVisuals=%d serverPreVisuals=%d deathInventory=%d corpseInventory=%d corpseVisuals=%d correlation=%s confidence=%s source=%s reportId=%s observer=%s",
		tostring(entry.caseId), tostring(entry.onlineID), clientReport and "received" or "missing",
		tostring(clientReport and clientReport.kind or "?"), #clientTypes, preVisualCount,
		deathTotal, corpseTotal, corpseVisualCount, tostring(correlation.method),
		tostring(correlation.confidence), tostring(sourceLabel),
		tostring(clientReport and clientReport.reportId or "none"),
		tostring(clientReport and clientReport.observedBy or "unknown")))

	if category then
		-- Patron que demuestra definitivamente una perdida real (pedido
		-- explicitamente): el cliente SI vio ropa antes de morir, el
		-- servidor NUNCA la tuvo en su propio ItemVisuals, y el cadaver
		-- final no tiene nada - confirma que la desincronizacion ocurrio
		-- ANTES de OnZombieDead, no durante la reconstruccion del cadaver.
		local confirmedClientServerDesync = (#clientTypes > 0) and (preVisualCount == 0) and (corpseTotal == 0)
		local line = string.format(
			"%s preVisualTypes=%s deathInventoryTypes=%s corpseInventoryTypes=%s corpseVisualTypes=%s clientVisualTypes=%s clientReportId=%s clientReportKind=%s clientObservedBy=%s clientSteamID=%s clientReportedAtMs=%s clientReceivedAtMs=%s clientPos=%s,%s,%s clientOutfitName=%s clientPersistentOutfitID=%s serverPreOutfitName=%s serverPrePersistentOutfitID=%s serverDeathOutfitName=%s serverDeathPersistentOutfitID=%s corpseOutfitName=%s confirmedClientServerDesync=%s",
			auditDetails,
			joined(entry.pre.itemVisualTypes), joined((function()
				local out = {}
				for i = 1, #(entry.death.inventory or {}) do out[i] = entry.death.inventory[i].fullType or "?" end
				return out
			end)()),
			joined((function()
				local out = {}
				for i = 1, #(corpse.inventory or {}) do out[i] = corpse.inventory[i].fullType or "?" end
				return out
			end)()),
			joined(corpse.itemVisualTypes), joined(clientTypes),
			tostring(clientReport and clientReport.reportId or "?"),
			tostring(clientReport and clientReport.kind or "?"),
			tostring(clientReport and clientReport.observedBy or "?"),
			tostring(clientReport and clientReport.observerSteamID or "?"),
			tostring(clientReport and clientReport.reportedAtClientMs or "?"),
			tostring(clientReport and clientReport.reportedAt or "?"),
			tostring(clientReport and clientReport.x or "?"),
			tostring(clientReport and clientReport.y or "?"),
			tostring(clientReport and clientReport.z or "?"),
			tostring(clientReport and clientReport.outfitName or "?"),
			tostring(clientReport and clientReport.persistentOutfitID or "?"),
			-- Registrados AHORA (pedido explicito tras revisar el informe del
			-- 2026-08-14): el propio SCLG_Snapshot.build ya capturaba
			-- outfitName/persistentOutfitID del lado servidor en pre/death,
			-- pero no se volcaban en esta linea - solo se veian los del
			-- cliente, dejando la mitad de la comparacion "antes/despues"
			-- invisible en el log.
			tostring(entry.pre.outfitName), tostring(entry.pre.persistentOutfitID),
			tostring(entry.death.outfitName), tostring(entry.death.persistentOutfitID),
			tostring(corpse.outfitName),
			tostring(confirmedClientServerDesync))
		SCLG_Log.warn(category, line)
		SCLG_Diagnostics.recordSignal(entry, "CORPSE", category, line, true)
		SCLG_RecoverySimulation.evaluate(entry, category, {
			correlationConfidence = correlation.confidence,
			clientTypes = clientTypes,
		})
	elseif SCLG_Config.enableDebug() then
		SCLG_Log.debug("CorpseAudit", "auditCorpse sin categoria | onlineID=" .. tostring(entry.onlineID)
			.. " preVisuals=" .. preVisualCount .. " deathTotal=" .. deathTotal .. " corpseTotal=" .. corpseTotal)
	end
	if not category then
		SCLG_Diagnostics.recordStage(entry, "CORPSE", "OK", auditDetails)
	end
	if entry.onlineID then clientReports[entry.onlineID] = nil end
end

--- Sonda de hipotesis capacidad/peso (ver SCLG_Sandbox.isCapacityDiagnosticEnabled):
--- si DoZombieInventory() reconstruye mas objetos/peso de los que el
--- contenedor del cadaver admite, el motor podria descartar items en
--- silencio por limite de capacidad - exactamente el mismo sintoma que el
--- resto de perdidas que investiga este mod, pero por una causa distinta
--- (limite duro, no fallo de instanciacion). Se registra el estado de
--- capacidad SIEMPRE que el cadaver tenga contenido, para poder comparar
--- despues casos con perdida contra casos sin ella y ver si la capacidad
--- estaba al limite en los primeros y no en los segundos.
---@param body any IsoDeadBody
---@param entry table
local function logContainerCapacityInfo(body, entry)
	local okContainer, container = pcall(function() return body.getContainer and body:getContainer() or nil end)
	if not okContainer or not container then
		return
	end
	local capacity, weight, maxWeight = nil, nil, nil
	for _, methodName in ipairs({ "getCapacity" }) do
		if container[methodName] then
			local ok, val = pcall(container[methodName], container)
			if ok then capacity = val end
		end
	end
	for _, methodName in ipairs({ "getCapacityWeight", "getContainerWeight" }) do
		if container[methodName] then
			local ok, val = pcall(container[methodName], container)
			if ok then weight = val end
		end
	end
	for _, methodName in ipairs({ "getMaxWeight" }) do
		if container[methodName] then
			local ok, val = pcall(container[methodName], container)
			if ok then maxWeight = val end
		end
	end
	local okCount, itemCount = pcall(function()
		local items = container:getItems()
		return items and items:size() or 0
	end)
	if not okCount then
		itemCount = nil
	end
	local nearLimit = (maxWeight and weight and maxWeight > 0 and (weight / maxWeight) >= 0.9)
	local line = string.format(
		"onlineID=%s items=%s capacity=%s weight=%s maxWeight=%s nearLimit=%s",
		tostring(entry.onlineID), tostring(itemCount), tostring(capacity), tostring(weight), tostring(maxWeight), tostring(nearLimit == true))
	if nearLimit then
		SCLG_Log.warn("CORPSE_CONTAINER_NEAR_CAPACITY", line)
		SCLG_Diagnostics.recordSignal(entry, "CORPSE", "CORPSE_CONTAINER_NEAR_CAPACITY", line, true)
	elseif SCLG_Config.enableDebug() then
		SCLG_Log.debug("CapacityProbe", line)
	end
end

--- Logica compartida de auditoria de un IsoDeadBody ya localizado - llamada
--- tanto desde el evento OnDeadBodySpawn (camino normal) como desde
--- scanForUnauditedCorpses (respaldo, ver mas abajo). Idempotente: si el
--- cadaver ya no tiene entrada pendiente asociada (porque el evento ya lo
--- proceso antes que el escaneo, o viceversa), no hace nada.
---@param body any IsoDeadBody
---@param sourceLabel string "event" | "scan" - solo para el log de diagnostico
local function processDeadBody(body, sourceLabel)
	if not body then
		return
	end

	if not loggedCorpseApiOnce then
		loggedCorpseApiOnce = true
		SCLG_Log.info("CorpseAudit", string.format(
			"IsoDeadBody API detectada | getCharacterOnlineID=%s getContainer=%s getWornItems=%s getAttachedItems=%s getItemVisuals=%s getOutfitName=%s getSquare=%s",
			tostring(body.getCharacterOnlineID ~= nil), tostring(body.getContainer ~= nil),
			tostring(body.getWornItems ~= nil), tostring(body.getAttachedItems ~= nil),
			tostring(body.getItemVisuals ~= nil), tostring(body.getOutfitName ~= nil),
			tostring(body.getSquare ~= nil)))
	end

	local entry, key, correlation = findPendingFor(body)
	if not entry then
		if correlation and correlation.confidence == "ambiguous" then
			local ambiguityKey = tostring(correlation.bodyX) .. "," .. tostring(correlation.bodyY) .. "," .. tostring(correlation.bodyZ)
			if not ambiguousLoggedAt[ambiguityKey] then
				ambiguousLoggedAt[ambiguityKey] = nowMs()
				local nearest = correlation.nearest or {
					caseId = SCLG_Diagnostics.newCaseId(), sessionId = SCLG_Diagnostics.sessionId(),
					x = correlation.bodyX, y = correlation.bodyY, z = correlation.bodyZ,
				}
				local details = "source=" .. tostring(sourceLabel) .. " correlation=position confidence=ambiguous candidates="
					.. tostring(correlation.candidates) .. " nearestDistance=" .. tostring(correlation.distance)
				SCLG_Diagnostics.stats().correlationAmbiguous = SCLG_Diagnostics.stats().correlationAmbiguous + 1
				SCLG_Diagnostics.recordSignal(nearest, "CORRELATION", "AMBIGUOUS_CORPSE_MATCH", details, true)
				SCLG_RecoverySimulation.evaluate(nearest, "AMBIGUOUS_CORPSE_MATCH")
				SCLG_Diagnostics.writeSummaryNow()
			end
		end
		-- Normal y esperado para cadaveres que no seguimos (ya existian,
		-- de otro origen, ya procesados por la otra via evento/escaneo,
		-- etc) - no es un fallo, solo debug.
		SCLG_Log.debug("CorpseAudit", "IsoDeadBody (" .. tostring(sourceLabel) .. ") sin entrada pendiente correlacionada")
		return
	end
	pending[key] = nil
	if correlation.confidence == "exact" then
		SCLG_Diagnostics.stats().correlationExact = SCLG_Diagnostics.stats().correlationExact + 1
	elseif correlation.confidence == "unique_proximity" then
		SCLG_Diagnostics.stats().correlationProximity = SCLG_Diagnostics.stats().correlationProximity + 1
	end

	local corpse = SCLG_Snapshot.buildFromCorpse(body)
	corpse.sessionId = entry.sessionId
	corpse.caseId = entry.caseId
	auditCorpse(entry, corpse, correlation, sourceLabel)

	if SCLG_Sandbox.isCapacityDiagnosticEnabled() then
		logContainerCapacityInfo(body, entry)
	end

	-- Programa una segunda comprobacion mas tarde (ver
	-- SCLG_Sandbox.isPostAnimationRecheckEnabled): la audit de arriba compara
	-- justo al crearse el IsoDeadBody, pero el usuario ha visto perdidas que
	-- ocurren DESPUES, con el cadaver ya asentado en el suelo tras terminar
	-- la animacion de muerte. Guardamos la referencia del cuerpo y el
	-- snapshot de este primer chequeo para comparar contra el mismo cadaver
	-- unos segundos despues.
	if SCLG_Sandbox.isPostAnimationRecheckEnabled() then
		groundRecheckQueue[key] = {
			body = body,
			entry = entry,
			onlineID = entry.onlineID,
			firstCorpse = corpse,
			correlation = correlation,
			dueAt = nowMs() + (SCLG_Sandbox.getPostAnimationRecheckDelaySeconds() * 1000),
		}
	end
	SCLG_Diagnostics.writeSummaryNow()
end

---@param body any IsoDeadBody
local function onDeadBodySpawn(body)
	processDeadBody(body, "event")
end

--- Escaneo de respaldo REAL (2026-08-14, antes solo existia como intencion
--- en el comentario de cabecera de este fichero, sin implementacion - ver
--- README de diagnostico): por si Events.OnDeadBodySpawn no llega a
--- dispararse en este build/entorno (confirmable buscando el aviso "no
--- existe en esta build" en el log al arrancar), revisa periodicamente la
--- MISMA casilla donde murio cada zombie pendiente por si su IsoDeadBody ya
--- existe en el mundo, usando IsoGridSquare:getDeadBodys() (API confirmada
--- en vanilla, ver ISVehicleMenu.lua). Throttled y limitado a entradas
--- "death stage" con un margen de espera (CORPSE_SCAN_MIN_AGE_MS) antes de
--- intentarlo, para dar tiempo de sobra a que el evento normal actue
--- primero si SI existe - este escaneo es la red de seguridad, no el
--- camino principal.
local lastScanFallbackAt = 0
local fallbackScanCursor = 1
function SCLG_CorpseAudit.scanForUnauditedCorpses()
	local now = nowMs()
	if (now - lastScanFallbackAt) < SCLG_Config.CORPSE_SCAN_FALLBACK_INTERVAL_MS then
		return
	end
	lastScanFallbackAt = now

	local cell = getCell and getCell() or nil
	if not cell or not cell.getGridSquare then
		return
	end

	-- CRASH REAL (confirmado con traza real, 2026-08-14): processDeadBody
	-- (mas abajo) puede borrar una entrada de `pending` DISTINTA a la que el
	-- bucle esta recorriendo ahora mismo (via el respaldo por posicion de
	-- findPendingFor) - mutar la tabla mientras se itera con pairs() sobre
	-- ELLA MISMA no es seguro en Kahlua (a diferencia de Lua estandar, que sí
	-- garantiza poder borrar la clave YA visitada), y rompe el iterador:
	-- "attempted index: registeredAt of non-table: null" en la siguiente
	-- vuelta. Fix: sacar una foto en un array plano ANTES de tocar nada:
	-- pending puede mutar libremente despues sin afectar a este bucle, que ya
	-- no depende de su identidad.
	local snapshot = {}
	for key, entry in pairs(pending) do
		snapshot[#snapshot + 1] = { key = key, entry = entry }
	end

	if #snapshot == 0 then
		fallbackScanCursor = 1
		return
	end
	if fallbackScanCursor > #snapshot then fallbackScanCursor = 1 end
	local maxEntries = math.min(#snapshot, SCLG_Config.CORPSE_SCAN_MAX_PENDING_PER_PASS)
	local snapshotIndex = fallbackScanCursor
	for _ = 1, maxEntries do
		local key, entry = snapshot[snapshotIndex].key, snapshot[snapshotIndex].entry
		if pending[key] and (now - (entry.registeredAt or 0)) >= SCLG_Config.CORPSE_SCAN_MIN_AGE_MS then
			local radius = SCLG_Config.CORPSE_MATCH_RADIUS_TILES
			for dx = -radius, radius do
				for dy = -radius, radius do
					if pending[key] then
						local okSq, square = pcall(function()
							return cell:getGridSquare(math.floor(entry.x) + dx, math.floor(entry.y) + dy, math.floor(entry.z))
						end)
						if okSq and square and square.getDeadBodys then
							local okBodies, bodies = pcall(function() return square:getDeadBodys() end)
							local okSize, size = pcall(function() return okBodies and bodies and bodies:size() or 0 end)
							if okSize and size and size > 0 then
								for bodyIndex = 0, size - 1 do
									local okGet, body = pcall(function() return bodies:get(bodyIndex) end)
									if okGet and body then processDeadBody(body, "scan") end
								end
							end
						end
					end
				end
			end
			-- Si pending[key] seguia existiendo tras processDeadBody (no se
			-- encontro ningun IsoDeadBody real todavia en esa casilla), se deja
			-- para el siguiente barrido - sweepIfDue() ya limpia por TTL si el
			-- cadaver nunca llega a materializarse.
		end
		snapshotIndex = snapshotIndex + 1
		if snapshotIndex > #snapshot then snapshotIndex = 1 end
	end
	fallbackScanCursor = snapshotIndex
end

--- Radio (en tiles) dentro del cual se considera que un jugador podria
--- haber saqueado legitimamente el cadaver entre las dos comprobaciones -
--- ver SCLG_Sandbox.isNearbyPlayerCheckEnabled.
local NEARBY_PLAYER_RADIUS_TILES = 3

--- Comprueba si algun jugador online esta lo bastante cerca de una
--- posicion como para haber podido saquear el cadaver el mismo (evita
--- falsos positivos en POST_ANIMATION_LOSS: sin esto, un jugador saqueando
--- el cadaver justo cuando salta la recomprobacion se registraria como si
--- fuera el propio bug).
---@param x number
---@param y number
---@param z number
---@return boolean
local function hasNearbyPlayer(x, y, z)
	local okGetPlayers, players = pcall(function() return getOnlinePlayers() end)
	if not okGetPlayers then players = nil end
	local function isNear(player)
		if not player then return false end
		local okPos, px, py, pz = pcall(function() return player:getX(), player:getY(), player:getZ() end)
		if not okPos or math.floor(pz or 0) ~= math.floor(z or 0) then return false end
		local dx, dy = px - x, py - y
		return (dx * dx + dy * dy) <= (NEARBY_PLAYER_RADIUS_TILES * NEARBY_PLAYER_RADIUS_TILES)
	end
	if not players then
		local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
		return isNear(player)
	end
	local okSize, size = pcall(function() return players:size() end)
	if not okSize or not size then
		return false
	end
	for i = 0, size - 1 do
		local okP, player = pcall(function() return players:get(i) end)
		if okP and isNear(player) then return true end
	end
	return false
end

--- Compara el estado del cadaver ahora contra el primer snapshot tomado en
--- OnDeadBodySpawn, y registra una perdida "post-animacion" si ha perdido
--- objetos entre medias sin que nada mas lo haya saqueado (ver
--- SCLG_CorpseAudit.processGroundRechecks mas abajo, unico llamador).
---@param queued table { body, onlineID, firstCorpse }
local function auditGroundRecheck(queued)
	local body = queued.body

	-- Distingue "el cadaver ya no existe" (despawn por limpieza del juego,
	-- descarga de chunk, etc - no es el bug que buscamos) de "el cadaver
	-- sigue ahi pero con menos objetos" (la señal real). Sin esto, un
	-- despawn normal se habria contado igual que una perdida real.
	local okSquare, square = pcall(function() return body.getSquare and body:getSquare() or nil end)
	if not okSquare or not square then
		SCLG_Diagnostics.recordStage(queued.entry, "RECHECK", "BODY_UNAVAILABLE",
			"reason=despawn_or_chunk_unloaded")
		SCLG_Diagnostics.writeSummaryNow()
		if SCLG_Config.enableDebug() then
			SCLG_Log.debug("CorpseAudit", "auditGroundRecheck: cadaver ya no tiene square (probable despawn/descarga de chunk), no cuenta como perdida | onlineID="
				.. tostring(queued.onlineID))
		end
		return
	end

	local nowCorpse = SCLG_Snapshot.buildFromCorpse(body)

	local firstTotal = #(queued.firstCorpse.inventory or {})
	local nowTotal = #(nowCorpse.inventory or {})
	local firstVisual = #(queued.firstCorpse.itemVisualTypes or {})
	local nowVisual = #(nowCorpse.itemVisualTypes or {})

	if firstTotal > 0 and nowTotal < firstTotal then
		local firstTypes, nowCounts = {}, {}
		for i = 1, #(queued.firstCorpse.inventory or {}) do
			local ft = queued.firstCorpse.inventory[i].fullType or "?"
			firstTypes[#firstTypes + 1] = ft
		end
		for i = 1, #(nowCorpse.inventory or {}) do
			local ft = nowCorpse.inventory[i].fullType or "?"
			nowCounts[ft] = (nowCounts[ft] or 0) + 1
		end
		local missing = {}
		local firstCounts = {}
		for i = 1, #firstTypes do firstCounts[firstTypes[i]] = (firstCounts[firstTypes[i]] or 0) + 1 end
		for ft, preCount in pairs(firstCounts) do
			local deficit = preCount - (nowCounts[ft] or 0)
			for _ = 1, deficit do missing[#missing + 1] = ft end
		end

		local okXY, bx, by, bz = pcall(function() return square:getX(), square:getY(), square:getZ() end)
		local nearbyPlayer = SCLG_Sandbox.isNearbyPlayerCheckEnabled() and okXY and hasNearbyPlayer(bx, by, bz)

		local line = string.format(
			"onlineID=%s firstCheckInventory=%d nowInventory=%d firstCheckVisuals=%d nowVisuals=%d missing=%s possibleLegitimateLoot=%s",
			tostring(queued.onlineID), firstTotal, nowTotal, firstVisual, nowVisual,
			(#missing > 0 and table.concat(missing, ";") or "(ninguno identificado)"),
			tostring(nearbyPlayer == true))

		if nearbyPlayer then
			-- Un jugador estaba lo bastante cerca como para haberlo saqueado
			-- el mismo: se registra como informativo, NO como LOSS, para no
			-- inflar los contadores con looteo legitimo.
			SCLG_Log.info("POST_ANIMATION_DELTA_NEARBY_PLAYER", line)
			SCLG_Diagnostics.recordSignal(queued.entry, "RECHECK", "POST_ANIMATION_DELTA_NEARBY_PLAYER", line, false)
			SCLG_RecoverySimulation.evaluate(queued.entry, "POST_ANIMATION_LOSS", {
				missing = missing, possibleLegitimateLoot = true,
			})
		else
			SCLG_Log.warn("POST_ANIMATION_LOSS", line)
			SCLG_Diagnostics.stats().postAnimationLosses = SCLG_Diagnostics.stats().postAnimationLosses + 1
			SCLG_Diagnostics.recordSignal(queued.entry, "RECHECK", "POST_ANIMATION_LOSS", line, true)
			SCLG_RecoverySimulation.evaluate(queued.entry, "POST_ANIMATION_LOSS", {
				missing = missing, possibleLegitimateLoot = false,
			})
		end
	else
		SCLG_Diagnostics.recordStage(queued.entry, "RECHECK", "OK",
			"firstInventory=" .. tostring(firstTotal) .. " nowInventory=" .. tostring(nowTotal)
			.. " firstVisuals=" .. tostring(firstVisual) .. " nowVisuals=" .. tostring(nowVisual))
		if SCLG_Config.enableDebug() then
			SCLG_Log.debug("CorpseAudit", "auditGroundRecheck sin perdidas | onlineID=" .. tostring(queued.onlineID)
				.. " firstTotal=" .. firstTotal .. " nowTotal=" .. nowTotal)
		end
	end
	SCLG_Diagnostics.writeSummaryNow()
end

--- Procesa la cola de recomprobacion tardia (throttled, seguro llamarla en
--- cada tick). Cuando una entrada vence, compara y la retira de la cola -
--- una unica recomprobacion por cadaver, no reintentos indefinidos.
function SCLG_CorpseAudit.processGroundRechecks()
	if not SCLG_Sandbox.isPostAnimationRecheckEnabled() then
		return
	end
	local now = nowMs()
	if (now - lastGroundRecheckScanAt) < GROUND_RECHECK_SCAN_INTERVAL_MS then
		return
	end
	lastGroundRecheckScanAt = now
	local due = {}
	for key, queued in pairs(groundRecheckQueue) do
		if now >= queued.dueAt then
			due[#due + 1] = { key = key, queued = queued }
		end
	end
	for i = 1, #due do
		groundRecheckQueue[due[i].key] = nil
		local ok, err = pcall(auditGroundRecheck, due[i].queued)
		if not ok then
			SCLG_Log.debug("CorpseAudit", "auditGroundRecheck fallo (cadaver probablemente descargado): " .. tostring(err))
		end
	end
end

--- Barrida de entradas "death stage" que nunca llegaron a correlacionarse
--- con un IsoDeadBody (cadaver no creado, chunk descargado, etc).
function SCLG_CorpseAudit.sweepIfDue()
	local now = nowMs()
	if (now - lastSweepAt) < SCLG_Config.SWEEP_INTERVAL_MS then
		return
	end
	lastSweepAt = now
	local removedPending, removedReports = 0, 0
	local stalePending, staleReports, staleAmbiguities = {}, {}, {}
	for key, entry in pairs(pending) do
		if (now - (entry.registeredAt or 0)) > SCLG_Config.CORPSE_AUDIT_TTL_MS then
			stalePending[#stalePending + 1] = { key = key, entry = entry }
		end
	end
	for onlineID, report in pairs(clientReports) do
		if (now - (report.reportedAt or 0)) > SCLG_Config.CORPSE_AUDIT_TTL_MS then
			staleReports[#staleReports + 1] = onlineID
		end
	end
	for key, loggedAt in pairs(ambiguousLoggedAt) do
		if (now - loggedAt) > SCLG_Config.CORPSE_AUDIT_TTL_MS then staleAmbiguities[#staleAmbiguities + 1] = key end
	end
	for i = 1, #stalePending do
		local item = stalePending[i]
		pending[item.key] = nil
		removedPending = removedPending + 1
		SCLG_Diagnostics.stats().correlationUnmatched = SCLG_Diagnostics.stats().correlationUnmatched + 1
		local details = "captureKey=" .. tostring(item.key) .. " ageMs="
			.. tostring(now - (item.entry.registeredAt or now)) .. " reason=no_corpse_correlated_before_ttl"
		SCLG_Diagnostics.recordSignal(item.entry, "CORRELATION", "PENDING_CORPSE_EXPIRED", details, true)
		SCLG_RecoverySimulation.evaluate(item.entry, "UNMATCHED_CORPSE")
	end
	for i = 1, #staleReports do clientReports[staleReports[i]] = nil removedReports = removedReports + 1 end
	for i = 1, #staleAmbiguities do ambiguousLoggedAt[staleAmbiguities[i]] = nil end
	if (removedPending > 0 or removedReports > 0) and SCLG_Config.enableDebug() then
		SCLG_Log.debug("CorpseAudit", "sweep removedPending=" .. removedPending .. " removedReports=" .. removedReports)
	end
	if removedPending > 0 then SCLG_Diagnostics.writeSummaryNow() end
end

---@return table
function SCLG_CorpseAudit.gauges()
	local pendingCount, reportCount, recheckCount = 0, 0, 0
	for _ in pairs(pending) do pendingCount = pendingCount + 1 end
	for _ in pairs(clientReports) do reportCount = reportCount + 1 end
	for _ in pairs(groundRecheckQueue) do recheckCount = recheckCount + 1 end
	return { pending = pendingCount, clientReports = reportCount, rechecks = recheckCount }
end

if Events.OnDeadBodySpawn then
	Events.OnDeadBodySpawn.Add(onDeadBodySpawn)
else
	SCLG_Log.warn("CorpseAudit", "Events.OnDeadBodySpawn no existe en esta build - no se podra auditar el IsoDeadBody definitivo por evento, se depende por completo del escaneo de respaldo (scanForUnauditedCorpses)")
end

-- Motor de la recomprobacion tardia (ver SCLG_CorpseAudit.processGroundRechecks):
-- throttled internamente a GROUND_RECHECK_SCAN_INTERVAL_MS, seguro colgarlo
-- de OnTick pese a dispararse muy a menudo.
Events.OnTick.Add(SCLG_CorpseAudit.processGroundRechecks)

-- Escaneo de respaldo (ver SCLG_CorpseAudit.scanForUnauditedCorpses): SIEMPRE
-- activo, no solo cuando falta el evento - da igual que OnDeadBodySpawn SI
-- exista, este barrido es idempotente (processDeadBody no hace nada si la
-- entrada pendiente ya se consumio) y sirve de red de seguridad adicional
-- para cadaveres que el evento pudiera perder por cualquier otro motivo.
Events.OnTick.Add(SCLG_CorpseAudit.scanForUnauditedCorpses)
