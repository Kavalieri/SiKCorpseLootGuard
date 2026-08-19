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
require "SCLG_ItemLocator"
require "SCLG_CaseNotificationServer"

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
--- onlineID -> timeline acotada { first=, richest=, latest=, transitions={} }
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
local GROUND_RECHECK_SCAN_INTERVAL_MS = 250
local MAX_TIMELINE_BODIES_PER_PASS = 8
local EARLY_BODY_TTL_MS = 5000
local MAX_EARLY_BODIES = 256
local earlyBodies = {}
local earlyBodySequence = 0
--- Identidad efimera de cada IsoDeadBody ya asignado. No conserva la
--- referencia Java: impide que el fallback vuelva a auditar el mismo cuerpo
--- contra otra muerte cercana durante la ventana diagnostica.
local bodyClaims = {}

local function timelineCaseId(entry, fallbackKey)
	return tostring((entry and entry.caseId) or fallbackKey or "?")
end

local function timelineKeysForCase(caseId)
	local keys = {}
	local wanted = tostring(caseId or "?")
	for key, queued in pairs(groundRecheckQueue) do
		if tostring((queued and queued.caseId) or key) == wanted then keys[#keys + 1] = key end
	end
	return keys
end

local function hasTimelineForCase(caseId)
	return #timelineKeysForCase(caseId) > 0
end

--- Retira todas las referencias Java asociadas al caso. Aunque DEV3 impide
--- crear duplicados, la limpieza por caseId hace el cierre idempotente y
--- tambien sanea cualquier entrada antigua/huérfana que sobreviviera en la
--- misma sesion por una ruta excepcional.
local function removeTimelinesForCase(caseId)
	local keys = timelineKeysForCase(caseId)
	for i = 1, #keys do groundRecheckQueue[keys[i]] = nil end
	return #keys
end

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
--- NO debe borrar el preHit: se conserva el reporte con MAS prendas y,
--- ademas, hasta 16 muestras planas para verificar estabilidad de huella,
--- outfit, observador y tipo de evento sin retener objetos Java.
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
			"reportClientVisual recibido | onlineID=%s kind=%s observedBy=%s steamID=%s types=%d descriptors=%d sampleHash=%s compositionHash=%s appearanceHash=%s stateHash=%s complete=%s eligible=%s observerDistance=%s observerValid=%s outfitName=%s persistentOutfitID=%s clientMs=%s serverMs=%s pos=%s,%s,%s",
			tostring(onlineID), tostring(extra.kind), tostring(extra.observedBy), tostring(extra.observerSteamID), #types,
			#(extra.descriptors or {}), tostring(extra.sampleHash), tostring(extra.compositionHash),
			tostring(extra.appearanceHash), tostring(extra.stateHash), tostring(extra.descriptorComplete),
			tostring(extra.descriptorEligible), tostring(extra.observerClaimDistance),
			tostring(extra.observerWithinClaim == true),
			tostring(extra.outfitName), tostring(extra.persistentOutfitID),
			tostring(extra.reportedAtClientMs), tostring(nowMs()), tostring(extra.x), tostring(extra.y), tostring(extra.z)))
	end
	clientReportSequence = clientReportSequence + 1
	local receivedAt = nowMs()
	local reportId = SCLG_Diagnostics.sessionId() .. "-CLI-" .. string.format("%06d", clientReportSequence)
	local observation = {
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
		observerX = extra.observerX, observerY = extra.observerY, observerZ = extra.observerZ,
		observerClaimDistance = extra.observerClaimDistance,
		observerWithinClaim = extra.observerWithinClaim == true,
		descriptors = extra.descriptors or {},
		sampleHash = extra.sampleHash,
		compositionHash = extra.compositionHash,
		appearanceHash = extra.appearanceHash,
		stateHash = extra.stateHash,
		descriptorComplete = extra.descriptorComplete or 0,
		descriptorEligible = extra.descriptorEligible or 0,
	}
	local timeline = clientReports[onlineID]
	if not timeline then
		timeline = { transitions = {}, samples = {}, receivedCount = 0 }
		clientReports[onlineID] = timeline
	end
	timeline.receivedCount = (timeline.receivedCount or 0) + 1
	timeline.samples = timeline.samples or {}
	timeline.samples[#timeline.samples + 1] = observation
	if #timeline.samples > 16 then table.remove(timeline.samples, 1) end
	timeline.first = timeline.first or observation
	timeline.latest = observation
	if not timeline.richest or #(observation.types or {}) > #(timeline.richest.types or {}) then
		timeline.richest = observation
	end
	local previous = timeline.transitions[#timeline.transitions]
	local signature = tostring(observation.kind) .. "|" .. tostring(observation.persistentOutfitID)
		.. "|" .. tostring(observation.outfitName) .. "|" .. tostring(observation.sampleHash)
		.. "|" .. table.concat(observation.types or {}, ";")
	if not previous or previous.signature ~= signature then
		observation.signature = signature
		timeline.transitions[#timeline.transitions + 1] = observation
		if #timeline.transitions > 8 then table.remove(timeline.transitions, 1) end
	else
		previous.reportedAt = observation.reportedAt
		previous.reportedAtClientMs = observation.reportedAtClientMs
		previous.x, previous.y, previous.z = observation.x, observation.y, observation.z
		previous.kind = observation.kind
		previous.reportId = observation.reportId
	end
	timeline.reportedAt = receivedAt
	for _, queued in pairs(groundRecheckQueue) do
		if queued.onlineID == onlineID and queued.clientTimeline == timeline
			and receivedAt >= (queued.startedAt or receivedAt) then
			local stats = SCLG_Diagnostics.stats()
			stats.clientReportsLateLinked = (stats.clientReportsLateLinked or 0) + 1
			SCLG_Diagnostics.recordStage(queued.entry, "CLIENT_LINK", "CLIENT_REPORT_LATE_LINKED",
				"reportId=" .. reportId .. " kind=" .. tostring(observation.kind)
				.. " sampleHash=" .. tostring(observation.sampleHash)
				.. " compositionHash=" .. tostring(observation.compositionHash)
				.. " appearanceHash=" .. tostring(observation.appearanceHash)
				.. " stateHash=" .. tostring(observation.stateHash))
			break
		end
	end
	SCLG_Diagnostics.recordStage({
		sessionId = SCLG_Diagnostics.sessionId(), caseId = reportId, onlineID = onlineID,
		persistentOutfitID = extra.persistentOutfitID, x = extra.x, y = extra.y, z = extra.z,
	}, "CLIENT", "VISUAL_REPORT_ACCEPTED", "sourceOrigin=CLI kind=" .. tostring(extra.kind)
		.. " observedBy=" .. tostring(extra.observedBy) .. " steamID=" .. tostring(extra.observerSteamID)
		.. " types=" .. tostring(#types) .. " clientMs=" .. tostring(extra.reportedAtClientMs)
		.. " descriptors=" .. tostring(#(extra.descriptors or {}))
		.. " descriptorComplete=" .. tostring(extra.descriptorComplete or 0)
		.. " descriptorEligible=" .. tostring(extra.descriptorEligible or 0)
		.. " sampleHash=" .. tostring(extra.sampleHash)
		.. " compositionHash=" .. tostring(extra.compositionHash)
		.. " appearanceHash=" .. tostring(extra.appearanceHash)
		.. " stateHash=" .. tostring(extra.stateHash)
		.. " observerDistance=" .. tostring(extra.observerClaimDistance)
		.. " observerValid=" .. tostring(extra.observerWithinClaim == true)
		.. " serverReceivedMs=" .. tostring(receivedAt))
end

local function reportDistance2(report, entry)
	if not report or report.x == nil or report.y == nil then return math.huge end
	local dx, dy = report.x - (entry.x or report.x), report.y - (entry.y or report.y)
	return dx * dx + dy * dy
end

--- Selecciona la observacion cliente mas compatible con ESTA muerte. No se
--- limita a "la mas rica": persistentOutfitID, posicion y tiempo pesan mas,
--- evitando asociar un onlineID reutilizado a otro zombie.
local function selectClientReport(entry, timelineOverride)
	local timeline = timelineOverride or (entry.onlineID and clientReports[entry.onlineID] or nil)
	if not timeline then return nil, nil end
	local candidates = {}
	for i = 1, #(timeline.transitions or {}) do candidates[#candidates + 1] = timeline.transitions[i] end
	if #candidates == 0 then
		if timeline.first then candidates[#candidates + 1] = timeline.first end
		if timeline.richest and timeline.richest ~= timeline.first then candidates[#candidates + 1] = timeline.richest end
		if timeline.latest and timeline.latest ~= timeline.first and timeline.latest ~= timeline.richest then
			candidates[#candidates + 1] = timeline.latest
		end
	end
	local wantedPid = tostring((entry.death and entry.death.persistentOutfitID)
		or (entry.pre and entry.pre.persistentOutfitID) or "?")
	local best, bestScore = nil, -math.huge
	for i = 1, #candidates do
		local report = candidates[i]
		local score = math.min(20, #(report.types or {}))
		score = score + math.min(40, (report.descriptorComplete or 0) * 8)
			+ math.min(20, (report.descriptorEligible or 0) * 4)
		if report.kind == "death" then score = score + 6
		elseif report.kind == "preHit" then score = score + 4 end
		local reportPid = tostring(report.persistentOutfitID or "?")
		if wantedPid ~= "?" and reportPid == wantedPid then score = score + 100 end
		local distance2 = reportDistance2(report, entry)
		if distance2 <= 9 then score = score + 40
		elseif distance2 <= 100 then score = score + 20 end
		local ageMs = math.abs((entry.registeredAt or nowMs()) - (report.reportedAt or 0))
		if ageMs <= 5000 then score = score + 30
		elseif ageMs <= 30000 then score = score + 15 end
		if score > bestScore or (score == bestScore and best
			and (report.reportedAt or 0) > (best.reportedAt or 0)) then
			best, bestScore = report, score
		end
	end
	return best, timeline
end

local function countKeys(values)
	local count = 0
	for _ in pairs(values or {}) do count = count + 1 end
	return count
end

local function collectionCount(snapshot)
	if not snapshot then return 0 end
	return #(snapshot.worn or {}) + #(snapshot.attached or {}) + #(snapshot.inventory or {})
end

--- Consolida varias observaciones cliente sin elevarlas por si solas a
--- autoridad. Solo una correlacion exacta con un servidor y cadaver vacios
--- puede llegar a ser elegible, y aun debera sobrevivir toda la timeline.
local function buildClientRecoveryEvidence(entry, corpse, correlation, selected, timeline)
	local evidence = {
		clientSamples = 0,
		receivedSamples = timeline and (timeline.receivedCount or 0) or 0,
		distinctKinds = 0,
		distinctObservers = 0,
		descriptorComplete = selected and (selected.descriptorComplete or 0) or 0,
		descriptorEligible = selected and (selected.descriptorEligible or 0) or 0,
		descriptors = selected and (selected.descriptors or {}) or {},
		types = selected and (selected.types or {}) or {},
		sampleHash = selected and selected.sampleHash or nil,
		compositionHash = selected and selected.compositionHash or nil,
		appearanceHash = selected and selected.appearanceHash or nil,
		stateHash = selected and selected.stateHash or nil,
		outfitName = selected and selected.outfitName or nil,
		correlationExact = correlation and correlation.method == "onlineID"
			and correlation.confidence == "exact" and tonumber(correlation.candidates) == 1,
		noCompetingCorpse = correlation and tonumber(correlation.candidates) == 1,
		serverClothesEmpty = collectionCount(entry.pre) == 0 and collectionCount(entry.death) == 0
			and #(entry.pre.itemVisualTypes or {}) == 0 and #(entry.death.itemVisualTypes or {}) == 0,
		serverOutfitMissing = entry.pre.outfitName == nil and entry.death.outfitName == nil,
		initialCorpseCandidateEmpty = collectionCount(corpse) == 0 and #(corpse.itemVisualTypes or {}) == 0,
		timelineComplete = false,
		corpseEquivalentCount = 0,
		lateAddedItems = 0,
		lateAddedTypes = {},
		blockers = {},
	}
	if not selected or not selected.sampleHash or not selected.compositionHash
		or not selected.appearanceHash or not selected.stateHash
		or #(selected.descriptors or {}) == 0 then
		evidence.blockers[#evidence.blockers + 1] = "missing_client_descriptors"
		return evidence
	end

	local kinds, observers = {}, {}
	local compositionStable, appearanceStable, stateStable, outfitStable = true, true, true, true
	local stateHashes = {}
	local nearDeathSample = false
	local samples = (timeline and timeline.samples) or {}
	for i = 1, #samples do
		local sample = samples[i]
		local ageMs = math.abs((entry.registeredAt or nowMs()) - (sample.reportedAt or 0))
		local temporallyCompatible = ageMs <= SCLG_Config.CLIENT_RECOVERY_MAX_REPORT_AGE_MS
		if temporallyCompatible and sample.compositionHash then
			if sample.compositionHash ~= selected.compositionHash then compositionStable = false end
			if sample.appearanceHash ~= selected.appearanceHash then appearanceStable = false end
			if sample.stateHash ~= selected.stateHash then stateStable = false end
			stateHashes[tostring(sample.stateHash or "?")] = true
			if tostring(sample.outfitName or "?") ~= tostring(selected.outfitName or "?") then outfitStable = false end
		end
		if temporallyCompatible and sample.compositionHash == selected.compositionHash
			and sample.appearanceHash == selected.appearanceHash
			and tostring(sample.outfitName or "?") == tostring(selected.outfitName or "?")
			and sample.observerWithinClaim == true then
			evidence.clientSamples = evidence.clientSamples + 1
			kinds[tostring(sample.kind or "?")] = true
			observers[tostring(sample.observerSteamID or sample.observedBy or "?")] = true
			local sameZ = math.floor(sample.z or 0) == math.floor(entry.z or 0)
			if sameZ and reportDistance2(sample, entry)
				<= (SCLG_Config.CLIENT_RECOVERY_MAX_DEATH_DISTANCE_TILES ^ 2) then
				nearDeathSample = true
			end
		end
	end
	evidence.distinctKinds = countKeys(kinds)
	evidence.distinctObservers = countKeys(observers)
	evidence.kinds = kinds
	evidence.compositionStable = compositionStable
	evidence.appearanceStable = appearanceStable
	evidence.stateStable = stateStable
	evidence.stateTransitions = countKeys(stateHashes)
	evidence.descriptorStable = compositionStable and appearanceStable
	evidence.typesStable = compositionStable
	evidence.outfitStable = outfitStable and type(evidence.outfitName) == "string"
		and evidence.outfitName ~= "" and evidence.outfitName ~= "?"
	evidence.positionCompatible = nearDeathSample
	evidence.timeCompatible = evidence.clientSamples > 0
	evidence.preferredKinds = evidence.distinctKinds >= 2 and (kinds.preHit == true or kinds.death == true)
	evidence.confirmedClientServerDesync = #evidence.types > 0 and evidence.serverClothesEmpty
		and evidence.initialCorpseCandidateEmpty

	if not evidence.correlationExact then evidence.blockers[#evidence.blockers + 1] = "correlation_not_exact_onlineid" end
	if not evidence.noCompetingCorpse then evidence.blockers[#evidence.blockers + 1] = "competing_corpse" end
	if evidence.clientSamples < 2 then evidence.blockers[#evidence.blockers + 1] = "insufficient_consistent_client_samples" end
	if not evidence.preferredKinds then evidence.blockers[#evidence.blockers + 1] = "insufficient_distinct_sample_kinds" end
	if not evidence.compositionStable then evidence.blockers[#evidence.blockers + 1] = "client_composition_changed" end
	if not evidence.appearanceStable then evidence.blockers[#evidence.blockers + 1] = "client_appearance_changed" end
	if not evidence.outfitStable then evidence.blockers[#evidence.blockers + 1] = "client_outfit_changed_or_missing" end
	if not evidence.positionCompatible then evidence.blockers[#evidence.blockers + 1] = "client_position_not_compatible" end
	if not evidence.timeCompatible then evidence.blockers[#evidence.blockers + 1] = "client_time_not_compatible" end
	if not evidence.serverClothesEmpty then evidence.blockers[#evidence.blockers + 1] = "server_had_clothing_or_inventory" end
	if not evidence.serverOutfitMissing then evidence.blockers[#evidence.blockers + 1] = "server_outfit_name_present" end
	if not evidence.initialCorpseCandidateEmpty then evidence.blockers[#evidence.blockers + 1] = "corpse_had_clothing_or_inventory" end
	if evidence.descriptorComplete ~= #evidence.descriptors then evidence.blockers[#evidence.blockers + 1] = "client_descriptor_incomplete" end
	if evidence.descriptorEligible ~= #evidence.descriptors then evidence.blockers[#evidence.blockers + 1] = "client_descriptor_not_recovery_eligible" end
	return evidence
end

---@param a table|nil
---@param b table|nil
---@return number
local function dist2(a, bx, by)
	if not a then return math.huge end
	local dx, dy = (a.x or 0) - bx, (a.y or 0) - by
	return dx * dx + dy * dy
end

local function bodyIdentity(body)
	local okId, onlineID = pcall(function()
		return body.getCharacterOnlineID and body:getCharacterOnlineID() or nil
	end)
	-- El onlineID identifica al zombie, no al objeto cadáver durante toda la
	-- sesión: el motor puede reutilizarlo.  La reclamación exclusiva combina
	-- esa señal con la identidad física para no bloquear un cadáver futuro.
	local onlineToken = okId and onlineID and onlineID >= 0 and tostring(onlineID) or "?"
	local x, y, z, objectIndex = "?", "?", "?", "?"
	pcall(function()
		local square = body.getSquare and body:getSquare() or nil
		if square then x, y, z = square:getX(), square:getY(), square:getZ() end
	end)
	pcall(function()
		if body.getStaticMovingObjectIndex then objectIndex = body:getStaticMovingObjectIndex() end
	end)
	local okRef, reference = pcall(tostring, body)
	return "oid:" .. onlineToken .. ":pos:" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
		.. ":idx:" .. tostring(objectIndex) .. ":ref:" .. tostring(okRef and reference or "?")
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
	local candidateRows = {}
	local bodyOutfit = nil
	pcall(function() bodyOutfit = body.getOutfitName and body:getOutfitName() or nil end)
	for key, entry in pairs(pending) do
		if math.floor(entry.z or 0) == math.floor(bz or 0) then
			local d = dist2(entry, bx, by)
			if d <= (radius * radius) then
				candidates = candidates + 1
				local entryOutfit = (entry.death and entry.death.outfitName) or (entry.pre and entry.pre.outfitName)
				candidateRows[#candidateRows + 1] = { key = key, entry = entry, distance2 = d,
					ageMs = nowMs() - (entry.registeredAt or nowMs()),
					outfitMatch = bodyOutfit ~= nil and entryOutfit ~= nil and tostring(bodyOutfit) == tostring(entryOutfit) }
				if d < bestDist then bestKey, bestEntry, bestDist = key, entry, d end
			end
		end
	end
	table.sort(candidateRows, function(a, b)
		if a.outfitMatch ~= b.outfitMatch then return a.outfitMatch == true end
		if a.distance2 ~= b.distance2 then return a.distance2 < b.distance2 end
		return a.ageMs < b.ageMs
	end)
	local candidateTokens = {}
	for i = 1, math.min(8, #candidateRows) do
		local row = candidateRows[i]
		candidateTokens[#candidateTokens + 1] = tostring(row.entry.caseId) .. "@"
			.. string.format("%.2f", math.sqrt(row.distance2)) .. ":" .. tostring(row.ageMs)
			.. ":outfit=" .. tostring(row.outfitMatch)
	end
	local candidateDetails = #candidateTokens > 0 and table.concat(candidateTokens, ",") or "none"
	if candidates == 1 then
		return bestEntry, bestKey, { method = "position", confidence = "unique_proximity", candidates = 1,
			distance = math.sqrt(bestDist), bodyX = bx, bodyY = by, bodyZ = bz, candidateDetails = candidateDetails }
	end
	if candidates > 1 then
		local first, second = candidateRows[1], candidateRows[2]
		local uniquelyScored = first and ((first.outfitMatch and not second.outfitMatch)
			or (first.distance2 <= 0.25 and (second.distance2 - first.distance2) >= 2.25))
		if uniquelyScored then
			return first.entry, first.key, { method = "scored_position", confidence = "high_proximity",
				candidates = candidates, distance = math.sqrt(first.distance2), bodyX = bx, bodyY = by,
				bodyZ = bz, candidateDetails = candidateDetails }
		end
		return nil, nil, { method = "position", confidence = "ambiguous", candidates = candidates,
			distance = math.sqrt(bestDist), bodyX = bx, bodyY = by, bodyZ = bz, nearest = bestEntry,
			candidateDetails = candidateDetails }
	end
	return nil, nil, { method = "position", confidence = "unmatched", candidates = 0,
		bodyX = bx, bodyY = by, bodyZ = bz, candidateDetails = candidateDetails }
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

	local clientReport, clientTimeline = selectClientReport(entry)
	local clientTypes = clientReport and clientReport.types or {}
	entry.clientObservation = clientReport
	entry.clientReportTimeline = clientTimeline
	local clientRecoveryEvidence = buildClientRecoveryEvidence(entry, corpse, correlation, clientReport, clientTimeline)
	entry.clientRecoveryEvidence = clientRecoveryEvidence
	entry.correlation = correlation

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
	elseif preVisualCount > 0 and corpseVisualCount > 0 and overlapCount(entry.pre.itemVisualTypes, corpse.itemVisualTypes) == 0
		and correlation.method == "onlineID" and correlation.confidence == "exact" then
		-- NUEVA categoria (2026-08-14, pedida tras revisar casos reales de
		-- zombies con outfit completamente distinto al morir sin quedar
		-- vacios, ej. onlineID=10396/10388): el cadaver NO esta vacio, pero
		-- ninguna prenda visual de antes de morir sigue presente despues -
		-- el motor materializo un conjunto totalmente distinto, no solo
		-- perdio objetos sueltos. Categoria separada de las de perdida
		-- porque aqui no hay perdida cuantitativa, solo sustitucion.
		category = "OUTFIT_REPLACED"
	elseif preVisualCount > 0 and corpseVisualCount > 0
		and overlapCount(entry.pre.itemVisualTypes, corpse.itemVisualTypes) == 0 then
		-- Sin onlineID exacto, un outfit totalmente distinto demuestra antes una
		-- posible correlacion equivocada que una sustitucion real del motor.
		category = "PROXIMITY_OUTFIT_MISMATCH"
	end
	entry.auditCategory = category

	local auditDetails = string.format(
		"source=%s correlation=%s confidence=%s candidates=%s distance=%s bodyKey=%s candidateDetails=%s ageDeathToCorpseMs=%s preVisuals=%d deathInventory=%d corpseInventory=%d corpseVisuals=%d",
		tostring(sourceLabel), tostring(correlation.method), tostring(correlation.confidence),
		tostring(correlation.candidates), tostring(correlation.distance), tostring(correlation.bodyKey),
		tostring(correlation.candidateDetails),
		tostring(nowMs() - (entry.registeredAt or nowMs())), preVisualCount, deathTotal, corpseTotal, corpseVisualCount)
	SCLG_Diagnostics.stats().corpseAudits = SCLG_Diagnostics.stats().corpseAudits + 1

	-- Resumen compacto siempre visible: permite comparar lo observado por el
	-- cliente con cada fase autoritativa sin activar el DETAIL de alto volumen.
	-- "received + 0" es distinto de "missing + 0" y diagnostica si el cliente
	-- vio realmente un zombie vacio o si nunca llego un reporte.
	SCLG_Log.info("ClientServerCompare", string.format(
		"case=%s onlineID=%s clientReport=%s clientKind=%s clientVisuals=%d clientDescriptors=%d descriptorComplete=%d descriptorEligible=%d clientSamples=%d sampleHash=%s compositionHash=%s appearanceHash=%s stateHash=%s stateTransitions=%d clientReceived=%d clientTransitions=%d serverPreVisuals=%d deathInventory=%d corpseInventory=%d corpseVisuals=%d correlation=%s confidence=%s source=%s reportId=%s observer=%s",
		tostring(entry.caseId), tostring(entry.onlineID), clientReport and "received" or "missing",
		tostring(clientReport and clientReport.kind or "?"), #clientTypes,
		#(clientRecoveryEvidence.descriptors or {}), clientRecoveryEvidence.descriptorComplete or 0,
		clientRecoveryEvidence.descriptorEligible or 0, clientRecoveryEvidence.clientSamples or 0,
		tostring(clientRecoveryEvidence.sampleHash),
		tostring(clientRecoveryEvidence.compositionHash), tostring(clientRecoveryEvidence.appearanceHash),
		tostring(clientRecoveryEvidence.stateHash), clientRecoveryEvidence.stateTransitions or 0,
		clientTimeline and (clientTimeline.receivedCount or 0) or 0,
		clientTimeline and #(clientTimeline.transitions or {}) or 0, preVisualCount,
		deathTotal, corpseTotal, corpseVisualCount, tostring(correlation.method),
		tostring(correlation.confidence), tostring(sourceLabel),
		tostring(clientReport and clientReport.reportId or "none"),
		tostring(clientReport and clientReport.observedBy or "unknown")))
	if clientReport then
		SCLG_Diagnostics.recordStage(entry, "CLIENT_LINK", "CLIENT_REPORT_LINKED",
			"reportId=" .. tostring(clientReport.reportId) .. " kind=" .. tostring(clientReport.kind)
			.. " visuals=" .. tostring(#clientTypes) .. " received="
			.. tostring(clientTimeline and clientTimeline.receivedCount or 0) .. " transitions="
			.. tostring(clientTimeline and #(clientTimeline.transitions or {}) or 0)
			.. " distance=" .. tostring(math.sqrt(reportDistance2(clientReport, entry)))
			.. " clientSamples=" .. tostring(clientRecoveryEvidence.clientSamples)
			.. " distinctKinds=" .. tostring(clientRecoveryEvidence.distinctKinds)
			.. " descriptors=" .. tostring(#(clientRecoveryEvidence.descriptors or {}))
			.. " descriptorComplete=" .. tostring(clientRecoveryEvidence.descriptorComplete)
			.. " descriptorEligible=" .. tostring(clientRecoveryEvidence.descriptorEligible)
			.. " sampleHash=" .. tostring(clientRecoveryEvidence.sampleHash)
			.. " compositionHash=" .. tostring(clientRecoveryEvidence.compositionHash)
			.. " appearanceHash=" .. tostring(clientRecoveryEvidence.appearanceHash)
			.. " stateHash=" .. tostring(clientRecoveryEvidence.stateHash)
			.. " stateTransitions=" .. tostring(clientRecoveryEvidence.stateTransitions or 0)
			.. " blockers=" .. joined(clientRecoveryEvidence.blockers))
	end

	if category then
		-- Patron que demuestra definitivamente una perdida real (pedido
		-- explicitamente): el cliente SI vio ropa antes de morir, el
		-- servidor NUNCA la tuvo en su propio ItemVisuals, y el cadaver
		-- final no tiene nada - confirma que la desincronizacion ocurrio
		-- ANTES de OnZombieDead, no durante la reconstruccion del cadaver.
		local confirmedClientServerDesync = clientRecoveryEvidence.confirmedClientServerDesync == true
		local line = string.format(
			"%s preVisualTypes=%s deathInventoryTypes=%s corpseInventoryTypes=%s corpseVisualTypes=%s clientVisualTypes=%s clientReportId=%s clientReportKind=%s clientObservedBy=%s clientSteamID=%s clientReportedAtMs=%s clientReceivedAtMs=%s clientPos=%s,%s,%s clientOutfitName=%s clientPersistentOutfitID=%s serverPreOutfitName=%s serverPrePersistentOutfitID=%s serverDeathOutfitName=%s serverDeathPersistentOutfitID=%s corpseOutfitName=%s confirmedClientServerDesync=%s clientSamples=%s distinctKinds=%s descriptorCount=%s descriptorComplete=%s descriptorEligible=%s sampleHash=%s compositionHash=%s appearanceHash=%s stateHash=%s stateTransitions=%s descriptorStable=%s outfitStable=%s positionCompatible=%s timeCompatible=%s blockers=%s",
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
			tostring(confirmedClientServerDesync), tostring(clientRecoveryEvidence.clientSamples),
			tostring(clientRecoveryEvidence.distinctKinds), tostring(#(clientRecoveryEvidence.descriptors or {})),
			tostring(clientRecoveryEvidence.descriptorComplete), tostring(clientRecoveryEvidence.descriptorEligible),
			tostring(clientRecoveryEvidence.sampleHash), tostring(clientRecoveryEvidence.compositionHash),
			tostring(clientRecoveryEvidence.appearanceHash), tostring(clientRecoveryEvidence.stateHash),
			tostring(clientRecoveryEvidence.stateTransitions or 0),
			tostring(clientRecoveryEvidence.descriptorStable == true),
			tostring(clientRecoveryEvidence.outfitStable == true), tostring(clientRecoveryEvidence.positionCompatible == true),
			tostring(clientRecoveryEvidence.timeCompatible == true), joined(clientRecoveryEvidence.blockers))
		SCLG_Log.warn(category, line)
		SCLG_Diagnostics.recordSignal(entry, "CORPSE", category, line, true)
		-- CLIENT_ONLY_VISUAL se decide al cerrar la timeline: antes aun no
		-- sabemos si las prendas aparecieron tarde ni que loot legitimo se
		-- añadió al cuerpo. El resto conserva su evaluacion inmediata.
		if category ~= "CLIENT_ONLY_VISUAL" then
			SCLG_RecoverySimulation.evaluate(entry, category, {
				correlationConfidence = correlation.confidence,
				clientTypes = clientTypes,
			})
		else
			if SCLG_Sandbox.isRecoverySimulationEnabled() then
				SCLG_Diagnostics.stats().clientVisualCandidates =
					(SCLG_Diagnostics.stats().clientVisualCandidates or 0) + 1
			end
			SCLG_Diagnostics.recordStage(entry, "RECOVERY_SIM", "CLIENT_VISUAL_RECOVERY_PENDING",
				"decision=PENDING_TIMELINE mutation=false sampleHash="
				.. tostring(clientRecoveryEvidence.sampleHash)
				.. " compositionHash=" .. tostring(clientRecoveryEvidence.compositionHash)
				.. " appearanceHash=" .. tostring(clientRecoveryEvidence.appearanceHash)
				.. " stateHash=" .. tostring(clientRecoveryEvidence.stateHash))
		end
		if category == "LOSS_DURING_CORPSE_TRANSFER" or category == "LOSS_DURING_ZOMBIE_REBUILD" then
			SCLG_CaseNotificationServer.notify(entry, clientReport, "confirmed",
				math.max(deathTotal, preVisualCount))
		elseif category == "CLIENT_ONLY_VISUAL" or category == "EMPTY_POST_NO_BASELINE" then
			SCLG_CaseNotificationServer.notify(entry, clientReport, "candidate",
				math.max(#clientTypes, preVisualCount))
		end
	elseif SCLG_Config.enableDebug() then
		SCLG_Log.debug("CorpseAudit", "auditCorpse sin categoria | onlineID=" .. tostring(entry.onlineID)
			.. " preVisuals=" .. preVisualCount .. " deathTotal=" .. deathTotal .. " corpseTotal=" .. corpseTotal)
	end
	if not category then
		SCLG_Diagnostics.recordStage(entry, "CORPSE", "OK", auditDetails)
	end
	if entry.onlineID and category ~= "CLIENT_ONLY_VISUAL" then clientReports[entry.onlineID] = nil end
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
		return false, { confidence = "invalid" }
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

	local bodyKey = bodyIdentity(body)
	local entry, key, correlation = findPendingFor(body)
	local existingClaim = bodyClaims[bodyKey]
	if existingClaim then
		if entry and tostring(entry.caseId) ~= tostring(existingClaim.caseId) then
			existingClaim.rejectedCases = existingClaim.rejectedCases or {}
			if not existingClaim.rejectedCases[tostring(entry.caseId)] then
				existingClaim.rejectedCases[tostring(entry.caseId)] = true
				local stats = SCLG_Diagnostics.stats()
				stats.bodyClaimDuplicateRejected = (stats.bodyClaimDuplicateRejected or 0) + 1
				SCLG_Diagnostics.recordStage(entry, "CORRELATION", "BODY_ALREADY_CLAIMED",
					"bodyKey=" .. bodyKey .. " claimedCase=" .. tostring(existingClaim.caseId)
					.. " attemptedCase=" .. tostring(entry.caseId)
					.. " originalCorrelation=" .. tostring(existingClaim.correlation)
					.. " attemptedCorrelation=" .. tostring(correlation and correlation.confidence))
			end
		end
		return false, { method = "claimed", confidence = "duplicate_body_rejected", candidates = 0,
			bodyKey = bodyKey, claimedCase = existingClaim.caseId }
	end
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
					.. " candidateDetails=" .. tostring(correlation.candidateDetails)
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
		return false, correlation
	end
	bodyClaims[bodyKey] = {
		caseId = entry.caseId,
		claimedAt = nowMs(),
		correlation = correlation and correlation.confidence or "?",
		rejectedCases = {},
	}
	correlation.bodyKey = bodyKey
	SCLG_Diagnostics.recordStage(entry, "CORRELATION", "BODY_CLAIMED",
		"bodyKey=" .. bodyKey .. " source=" .. tostring(sourceLabel)
		.. " correlation=" .. tostring(correlation.method)
		.. " confidence=" .. tostring(correlation.confidence))
	pending[key] = nil
	if correlation.confidence == "exact" then
		SCLG_Diagnostics.stats().correlationExact = SCLG_Diagnostics.stats().correlationExact + 1
	elseif correlation.confidence == "unique_proximity" or correlation.confidence == "high_proximity" then
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
		local maxSeconds = SCLG_Sandbox.getTimelineMaxSeconds()
		local configuredSeconds = SCLG_Sandbox.getPostAnimationRecheckDelaySeconds()
		local rawOffsets = { 1000, 3000, 7000, configuredSeconds * 1000, maxSeconds * 1000 }
		local checkpoints, seenOffsets = {}, {}
		for i = 1, #rawOffsets do
			local offset = math.min(maxSeconds * 1000, math.max(500, rawOffsets[i]))
			if not seenOffsets[offset] then
				checkpoints[#checkpoints + 1] = offset
				seenOffsets[offset] = true
			end
		end
		table.sort(checkpoints)
		local timelineKey = timelineCaseId(entry, key)
		local stats = SCLG_Diagnostics.stats()
		if hasTimelineForCase(timelineKey) then
			stats.timelineDuplicateRejected = (stats.timelineDuplicateRejected or 0) + 1
			SCLG_Diagnostics.recordStage(entry, "TIMELINE", "TIMELINE_DUPLICATE_REJECTED",
				"source=" .. tostring(sourceLabel) .. " caseId=" .. timelineKey)
			SCLG_Log.warn("CorpseTimeline", "timeline duplicada rechazada case=" .. timelineKey)
		else
			groundRecheckQueue[timelineKey] = {
				caseId = timelineKey,
				body = body,
				entry = entry,
				onlineID = entry.onlineID,
				firstCorpse = corpse,
				lastCorpse = corpse,
				correlation = correlation,
				clientTimeline = entry.clientReportTimeline,
				startedAt = nowMs(),
				checkpoints = checkpoints,
				checkpointIndex = 1,
				candidates = {},
				confirmed = {},
				moved = {},
				lateAdded = {},
				candidateEquivalentSeen = 0,
				dueAt = nowMs() + checkpoints[1],
			}
			stats.timelinesStarted = (stats.timelinesStarted or 0) + 1
			SCLG_Diagnostics.recordStage(entry, "TIMELINE", "TIMELINE_STARTED",
				"source=" .. tostring(sourceLabel) .. " checkpointsMs=" .. table.concat(checkpoints, ",")
				.. " baselineInventory=" .. tostring(#(corpse.inventory or {}))
				.. " baselineVisuals=" .. tostring(#(corpse.itemVisualTypes or {})))
		end
	elseif entry.auditCategory == "CLIENT_ONLY_VISUAL" then
		-- Sin timeline no se puede demostrar que el outfit nunca aparecio
		-- despues. Se conserva una decision explicita y segura en el DRY RUN.
		SCLG_RecoverySimulation.evaluate(entry, "CLIENT_ONLY_VISUAL", {
			clientEvidence = entry.clientRecoveryEvidence,
		})
		if entry.onlineID and clientReports[entry.onlineID] == entry.clientReportTimeline then
			clientReports[entry.onlineID] = nil
		end
	end
	SCLG_Diagnostics.writeSummaryNow()
	return true, correlation
end

---@param body any IsoDeadBody
local function onDeadBodySpawn(body)
	local stats = SCLG_Diagnostics.stats()
	stats.bodyEventsSeen = (stats.bodyEventsSeen or 0) + 1
	local matched = processDeadBody(body, "event")
	if matched then
		stats.bodyEventsMatched = (stats.bodyEventsMatched or 0) + 1
		return
	end
	earlyBodySequence = earlyBodySequence + 1
	earlyBodies[#earlyBodies + 1] = { body = body, seenAt = nowMs(), sequence = earlyBodySequence }
	stats.bodyEventsQueued = (stats.bodyEventsQueued or 0) + 1
	while #earlyBodies > MAX_EARLY_BODIES do table.remove(earlyBodies, 1) end
end

local function processEarlyBodies()
	if #earlyBodies == 0 then return end
	local now = nowMs()
	local keep = {}
	local budget = MAX_TIMELINE_BODIES_PER_PASS
	for i = 1, #earlyBodies do
		local queued = earlyBodies[i]
		if (now - queued.seenAt) <= EARLY_BODY_TTL_MS then
			if budget > 0 then
				budget = budget - 1
				local matched = processDeadBody(queued.body, "event_retry")
				if matched then
					local stats = SCLG_Diagnostics.stats()
					stats.bodyEventsMatched = (stats.bodyEventsMatched or 0) + 1
				else
					keep[#keep + 1] = queued
				end
			else
				keep[#keep + 1] = queued
			end
		else
			local stats = SCLG_Diagnostics.stats()
			stats.bodyEventsExpired = (stats.bodyEventsExpired or 0) + 1
		end
	end
	earlyBodies = keep
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
									if okGet and body then
										local matched = processDeadBody(body, "scan")
										if matched then
											local stats = SCLG_Diagnostics.stats()
											stats.scanMatches = (stats.scanMatches or 0) + 1
										end
									end
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

local function fallbackBase(desc)
	return table.concat({ tostring(desc.fullType or "?"), tostring(desc.condition or "?"),
		tostring(desc.bodyLocation or "?"), tostring(desc.sourceCollection or "?") }, "|")
end

--- Devuelve los descriptores del baseline ausentes AHORA. itemId es la
--- identidad primaria; solo cae a multiset de tipo/estado si el motor no
--- expuso ID para una instancia concreta.
local function missingDescriptors(baseline, current)
	local currentIds, currentFallback = {}, {}
	for i = 1, #(current or {}) do
		local desc = current[i]
		if desc.itemId ~= nil then
			currentIds[tostring(desc.itemId)] = true
		else
			local base = fallbackBase(desc)
			currentFallback[base] = (currentFallback[base] or 0) + 1
		end
	end
	local missing, fallbackSeen = {}, {}
	for i = 1, #(baseline or {}) do
		local desc = baseline[i]
		local key, absent
		if desc.itemId ~= nil then
			key = "id:" .. tostring(desc.itemId)
			absent = not currentIds[tostring(desc.itemId)]
		else
			local base = fallbackBase(desc)
			fallbackSeen[base] = (fallbackSeen[base] or 0) + 1
			key = "fallback:" .. base .. "#" .. tostring(fallbackSeen[base])
			absent = fallbackSeen[base] > (currentFallback[base] or 0)
		end
		if absent then missing[#missing + 1] = { key = key, descriptor = desc } end
	end
	return missing
end

local function descriptorTypes(entries)
	local result = {}
	for i = 1, #(entries or {}) do
		local desc = entries[i].descriptor or entries[i]
		result[#result + 1] = desc.fullType or "?"
	end
	return result
end

local function descriptorDetails(entries)
	local result = {}
	for i = 1, #(entries or {}) do
		local desc = entries[i].descriptor or entries[i]
		result[#result + 1] = SCLG_Snapshot.descriptorSummary(desc)
	end
	return #result > 0 and table.concat(result, ";;") or "none"
end

local function tableCount(values)
	local count = 0
	for _ in pairs(values or {}) do count = count + 1 end
	return count
end

local function addBlocker(evidence, blocker)
	for i = 1, #(evidence.blockers or {}) do
		if evidence.blockers[i] == blocker then return end
	end
	evidence.blockers = evidence.blockers or {}
	evidence.blockers[#evidence.blockers + 1] = blocker
end

local function candidateEquivalentCount(types, corpse)
	local wanted, present = {}, {}
	for i = 1, #(types or {}) do wanted[types[i]] = (wanted[types[i]] or 0) + 1 end
	for i = 1, #(corpse.inventory or {}) do
		local fullType = corpse.inventory[i].fullType
		if fullType then present[fullType] = (present[fullType] or 0) + 1 end
	end
	for i = 1, #(corpse.itemVisualTypes or {}) do
		local fullType = corpse.itemVisualTypes[i]
		if fullType then present[fullType] = math.max(present[fullType] or 0, 1) end
	end
	local count = 0
	for fullType, wantedCount in pairs(wanted) do count = count + math.min(wantedCount, present[fullType] or 0) end
	return count
end

local function trackLateAdded(queued, corpse)
	local additions = missingDescriptors(corpse.inventory or {}, queued.firstCorpse.inventory or {})
	local newCount = 0
	for i = 1, #additions do
		local addition = additions[i]
		local key = addition.key
		local known = queued.lateAdded[key]
		if not known then
			known = { descriptor = addition.descriptor, firstSeenAt = nowMs(), appearances = 0 }
			queued.lateAdded[key] = known
			newCount = newCount + 1
		end
		known.lastSeenAt = nowMs()
		known.appearances = (known.appearances or 0) + 1
	end
	return newCount, #additions
end

local function lateAddedSummary(queued)
	local types, details = {}, {}
	for _, row in pairs(queued.lateAdded or {}) do
		types[#types + 1] = tostring(row.descriptor.fullType or "?")
		details[#details + 1] = SCLG_Snapshot.descriptorSummary(row.descriptor)
	end
	table.sort(types)
	table.sort(details)
	return types, (#details > 0 and table.concat(details, ";;") or "none")
end

local function finalizeClientVisualRecovery(queued, timelineComplete, terminalReason)
	if queued.entry.auditCategory ~= "CLIENT_ONLY_VISUAL" then return end
	local selected, currentTimeline = selectClientReport(queued.entry, queued.clientTimeline)
	local evidence = buildClientRecoveryEvidence(queued.entry, queued.firstCorpse,
		queued.correlation, selected, currentTimeline) or { blockers = {} }
	queued.entry.clientObservation = selected or queued.entry.clientObservation
	queued.entry.clientRecoveryEvidence = evidence
	if evidence.recoveryEvaluated == true then return end
	local lateTypes, lateDetails = lateAddedSummary(queued)
	evidence.timelineComplete = timelineComplete == true
	-- Una muestra death tardía puede ser más rica que la disponible al abrir
	-- la timeline. Recalcular contra el último cadáver evita declarar
	-- recuperable una prenda que sí terminó materializándose después.
	local latestEquivalent = candidateEquivalentCount(evidence.types,
		queued.lastCorpse or queued.firstCorpse)
	evidence.corpseEquivalentCount = math.max(queued.candidateEquivalentSeen or 0, latestEquivalent)
	evidence.lateAddedItems = #lateTypes
	evidence.lateAddedTypes = lateTypes
	evidence.lateAddedDetails = lateDetails
	if evidence.corpseEquivalentCount > 0 then addBlocker(evidence, "candidate_clothing_materialized_on_corpse") end
	if terminalReason then addBlocker(evidence, terminalReason) end
	local stats = SCLG_Diagnostics.stats()
	stats.clientVisualLateAddedItems = (stats.clientVisualLateAddedItems or 0) + #lateTypes
	SCLG_Diagnostics.recordStage(queued.entry, "TIMELINE", "CLIENT_ONLY_VISUAL_RECOVERY_EVALUATED",
		"confirmedClientServerDesync=" .. tostring(evidence.confirmedClientServerDesync == true)
		.. " clientSamples=" .. tostring(evidence.clientSamples or 0)
		.. " descriptorComplete=" .. tostring(evidence.descriptorComplete or 0)
		.. " descriptorEligible=" .. tostring(evidence.descriptorEligible or 0)
		.. " sampleHash=" .. tostring(evidence.sampleHash)
		.. " compositionHash=" .. tostring(evidence.compositionHash)
		.. " appearanceHash=" .. tostring(evidence.appearanceHash)
		.. " stateHash=" .. tostring(evidence.stateHash)
		.. " stateTransitions=" .. tostring(evidence.stateTransitions or 0)
		.. " timelineComplete=" .. tostring(evidence.timelineComplete == true)
		.. " terminalReason=" .. tostring(terminalReason or "complete")
		.. " candidateEquivalentSeen=" .. tostring(evidence.corpseEquivalentCount)
		.. " lateAddedItems=" .. tostring(#lateTypes)
		.. " lateAddedTypes=" .. joined(lateTypes)
		.. " lateAddedDescriptors=" .. lateDetails
		.. " blockers=" .. joined(evidence.blockers))
	SCLG_RecoverySimulation.evaluate(queued.entry, "CLIENT_ONLY_VISUAL", {
		clientEvidence = evidence,
	})
	evidence.recoveryEvaluated = true
	if queued.onlineID and clientReports[queued.onlineID] == queued.clientTimeline then
		clientReports[queued.onlineID] = nil
	end
end

--- Procesa un checkpoint del mismo IsoDeadBody. Retorna true cuando la
--- linea temporal termino y su referencia Java puede liberarse.
local function auditGroundTimeline(queued)
	local body = queued.body
	local okSquare, square = pcall(function() return body.getSquare and body:getSquare() or nil end)
	if not okSquare or not square then
		SCLG_Diagnostics.recordStage(queued.entry, "TIMELINE", "BODY_UNAVAILABLE",
			"ageMs=" .. tostring(nowMs() - queued.startedAt) .. " reason=despawn_or_chunk_unloaded")
		local stats = SCLG_Diagnostics.stats()
		stats.timelinesBodyUnavailable = (stats.timelinesBodyUnavailable or 0) + 1
		finalizeClientVisualRecovery(queued, false, "timeline_body_unavailable")
		return true
	end

	local nowCorpse = SCLG_Snapshot.buildFromCorpse(body)
	queued.lastCorpse = nowCorpse
	local lateAddedNow, lateAddedPresent = 0, 0
	if queued.entry.auditCategory == "CLIENT_ONLY_VISUAL" then
		lateAddedNow, lateAddedPresent = trackLateAdded(queued, nowCorpse)
		queued.candidateEquivalentSeen = math.max(queued.candidateEquivalentSeen or 0,
			candidateEquivalentCount((queued.entry.clientRecoveryEvidence or {}).types, nowCorpse))
	end
	local missing = missingDescriptors(queued.firstCorpse.inventory, nowCorpse.inventory)
	local missingNow = {}
	for i = 1, #missing do missingNow[missing[i].key] = missing[i] end
	local okXY, bx, by, bz = pcall(function() return square:getX(), square:getY(), square:getZ() end)
	local nearbyPlayer = SCLG_Sandbox.isNearbyPlayerCheckEnabled() and okXY and hasNearbyPlayer(bx, by, bz)
	local newlyConfirmed, movedNow = {}, {}

	for i = 1, #missing do
		local item = missing[i]
		local locator = { found = false, kind = "disabled", owner = "none", visited = 0, exhausted = false }
		if SCLG_Sandbox.isMovementSearchEnabled() and okXY then
			locator = SCLG_ItemLocator.locate(item.descriptor, body, bx, by, bz)
		end
		if locator.found then
			if not queued.moved[item.key] then
				queued.moved[item.key] = true
				movedNow[#movedNow + 1] = item
				local details = "item=" .. SCLG_Snapshot.descriptorSummary(item.descriptor)
					.. " movedTo=" .. tostring(locator.kind) .. " owner=" .. tostring(locator.owner)
					.. " searched=" .. tostring(locator.visited)
				if queued.confirmed[item.key] then
					local stats = SCLG_Diagnostics.stats()
					stats.timelineContradictions = (stats.timelineContradictions or 0) + 1
					SCLG_Diagnostics.recordSignal(queued.entry, "TIMELINE", "CONFIRMED_ITEM_LATER_MOVED",
						details, true)
					SCLG_RecoverySimulation.evaluate(queued.entry, "CONFIRMED_ITEM_LATER_MOVED", {
						missingDescriptors = { item.descriptor }, missing = { item.descriptor.fullType or "?" },
					})
					queued.confirmed[item.key] = nil
				else
					SCLG_Diagnostics.recordSignal(queued.entry, "TIMELINE", "ITEM_MOVED_AFTER_CORPSE", details, false)
				end
			end
			queued.candidates[item.key] = nil
		else
			local candidate = queued.candidates[item.key]
			if not candidate then
				candidate = { descriptor = item.descriptor, consecutive = 0, firstMissingAt = nowMs(),
					nearbyAtOpen = nearbyPlayer == true, searchExhausted = locator.exhausted == true }
				queued.candidates[item.key] = candidate
				local stats = SCLG_Diagnostics.stats()
				stats.timelineCandidatesOpened = (stats.timelineCandidatesOpened or 0) + 1
				SCLG_Diagnostics.recordStage(queued.entry, "TIMELINE", "MISSING_CANDIDATE_OPENED",
					"checkpoint=" .. tostring(queued.checkpointIndex) .. " nearby=" .. tostring(nearbyPlayer == true)
					.. " searched=" .. tostring(locator.visited) .. " exhausted=" .. tostring(locator.exhausted == true)
					.. " item=" .. SCLG_Snapshot.descriptorSummary(item.descriptor))
				SCLG_CaseNotificationServer.notify(queued.entry, queued.entry.clientObservation, "candidate", 1)
			end
			candidate.consecutive = candidate.consecutive + 1
			candidate.lastMissingAt = nowMs()
			candidate.nearbyAtConfirm = nearbyPlayer == true
			candidate.searchExhausted = candidate.searchExhausted or locator.exhausted == true
			if candidate.consecutive >= SCLG_Sandbox.getTimelineConfirmationSamples()
				and not queued.confirmed[item.key] then
				queued.confirmed[item.key] = candidate
				newlyConfirmed[#newlyConfirmed + 1] = item
			end
		end
	end

	local candidateKeys = {}
	for key in pairs(queued.candidates) do candidateKeys[#candidateKeys + 1] = key end
	for i = 1, #candidateKeys do
		local key = candidateKeys[i]
		if not missingNow[key] and not queued.moved[key] then
			local candidate = queued.candidates[key]
			if queued.confirmed[key] then
				local stats = SCLG_Diagnostics.stats()
				stats.timelineContradictions = (stats.timelineContradictions or 0) + 1
				SCLG_Diagnostics.recordSignal(queued.entry, "TIMELINE", "CONFIRMED_ITEM_REAPPEARED",
					"item=" .. SCLG_Snapshot.descriptorSummary(candidate.descriptor), true)
				SCLG_RecoverySimulation.evaluate(queued.entry, "CONFIRMED_ITEM_REAPPEARED", {
					missingDescriptors = { candidate.descriptor }, missing = { candidate.descriptor.fullType or "?" },
				})
				queued.confirmed[key] = nil
			else
				local stats = SCLG_Diagnostics.stats()
				stats.timelineCandidatesCancelled = (stats.timelineCandidatesCancelled or 0) + 1
				SCLG_Diagnostics.recordStage(queued.entry, "TIMELINE", "MISSING_CANCELLED_REAPPEARED",
					"consecutive=" .. tostring(candidate.consecutive)
					.. " item=" .. SCLG_Snapshot.descriptorSummary(candidate.descriptor))
			end
			queued.candidates[key] = nil
		end
	end

	if #movedNow > 0 then
		local stats = SCLG_Diagnostics.stats()
		stats.timelineItemsMoved = (stats.timelineItemsMoved or 0) + #movedNow
		SCLG_CaseNotificationServer.notify(queued.entry, queued.entry.clientObservation, "moved", #movedNow)
	end
	if #newlyConfirmed > 0 then
		local types = descriptorTypes(newlyConfirmed)
		local details = "checkpoint=" .. tostring(queued.checkpointIndex)
			.. " ageMs=" .. tostring(nowMs() - queued.startedAt)
			.. " baselineInventory=" .. tostring(#(queued.firstCorpse.inventory or {}))
			.. " nowInventory=" .. tostring(#(nowCorpse.inventory or {}))
			.. " baselineVisuals=" .. tostring(#(queued.firstCorpse.itemVisualTypes or {}))
			.. " nowVisuals=" .. tostring(#(nowCorpse.itemVisualTypes or {}))
			.. " missing=" .. table.concat(types, ";")
			.. " possibleLegitimateLoot=" .. tostring(nearbyPlayer == true)
			.. " descriptors=" .. descriptorDetails(newlyConfirmed)
		SCLG_Log.warn("POST_ANIMATION_LOSS", details)
		local stats = SCLG_Diagnostics.stats()
		stats.postAnimationLosses = stats.postAnimationLosses + 1
		stats.timelineItemsConfirmed = (stats.timelineItemsConfirmed or 0) + #newlyConfirmed
		SCLG_Diagnostics.recordSignal(queued.entry, "TIMELINE", "POST_ANIMATION_LOSS", details, true)
		SCLG_RecoverySimulation.evaluate(queued.entry, "POST_ANIMATION_LOSS", {
			missing = types,
			missingDescriptors = (function()
				local result = {}
				for i = 1, #newlyConfirmed do result[#result + 1] = newlyConfirmed[i].descriptor end
				return result
			end)(),
			possibleLegitimateLoot = nearbyPlayer == true,
			confirmedSamples = SCLG_Sandbox.getTimelineConfirmationSamples(),
		})
		SCLG_CaseNotificationServer.notify(queued.entry, queued.entry.clientObservation, "confirmed", #newlyConfirmed)
	end

	SCLG_Diagnostics.recordStage(queued.entry, "TIMELINE", "TIMELINE_CHECKPOINT",
		"checkpoint=" .. tostring(queued.checkpointIndex) .. " ageMs=" .. tostring(nowMs() - queued.startedAt)
		.. " inventory=" .. tostring(#(nowCorpse.inventory or {}))
		.. " visuals=" .. tostring(#(nowCorpse.itemVisualTypes or {}))
		.. " missingNow=" .. tostring(#missing) .. " candidates=" .. tostring(tableCount(queued.candidates))
		.. " confirmed=" .. tostring(tableCount(queued.confirmed)) .. " moved=" .. tostring(tableCount(queued.moved))
		.. " lateAddedNow=" .. tostring(lateAddedNow) .. " lateAddedPresent=" .. tostring(lateAddedPresent)
		.. " lateAddedEver=" .. tostring(tableCount(queued.lateAdded))
		.. " clientCandidateEquivalentSeen=" .. tostring(queued.candidateEquivalentSeen or 0)
		.. " nearby=" .. tostring(nearbyPlayer == true))

	queued.checkpointIndex = queued.checkpointIndex + 1
	if queued.checkpointIndex <= #queued.checkpoints then
		queued.dueAt = queued.startedAt + queued.checkpoints[queued.checkpointIndex]
		return false
	end
	local unconfirmed = 0
	for key, candidate in pairs(queued.candidates) do
		if not queued.confirmed[key] and not queued.moved[key]
			and candidate.consecutive < SCLG_Sandbox.getTimelineConfirmationSamples() then
			unconfirmed = unconfirmed + 1
		end
	end
	queued.extraPasses = queued.extraPasses or 0
	if unconfirmed > 0 and queued.extraPasses < SCLG_Sandbox.getTimelineConfirmationSamples() then
		queued.extraPasses = queued.extraPasses + 1
		queued.dueAt = nowMs() + 2000
		return false
	end
	local stats = SCLG_Diagnostics.stats()
	stats.timelinesCompleted = (stats.timelinesCompleted or 0) + 1
	finalizeClientVisualRecovery(queued, true, nil)
	SCLG_Diagnostics.recordStage(queued.entry, "TIMELINE", "TIMELINE_COMPLETE",
		"ageMs=" .. tostring(nowMs() - queued.startedAt)
		.. " confirmed=" .. tostring(tableCount(queued.confirmed))
		.. " moved=" .. tostring(tableCount(queued.moved))
		.. " unresolved=" .. tostring(unconfirmed))
	return true
end

--- Procesa la linea temporal (throttled, seguro llamarla en cada tick).
--- Cada entrada tiene checkpoints y pases extra estrictamente acotados; al
--- completarse, quedar inaccesible o fallar, se libera su referencia Java.
function SCLG_CorpseAudit.processGroundRechecks()
	processEarlyBodies()
	if not SCLG_Sandbox.isPostAnimationRecheckEnabled() then
		local queuedCases = {}
		for key, queued in pairs(groundRecheckQueue) do
			queuedCases[#queuedCases + 1] = { key = key, queued = queued }
		end
		local cancelled = 0
		for i = 1, #queuedCases do
			local item = queuedCases[i]
			if groundRecheckQueue[item.key] == item.queued then
				local caseId = timelineCaseId(item.queued.entry, item.key)
				local removed = removeTimelinesForCase(caseId)
				if removed > 0 then
					cancelled = cancelled + 1
					local stats = SCLG_Diagnostics.stats()
					stats.timelinesCancelled = (stats.timelinesCancelled or 0) + 1
					SCLG_Diagnostics.recordStage(item.queued.entry, "TIMELINE", "TIMELINE_CANCELLED",
						"reason=sandbox_disabled removedEntries=" .. tostring(removed))
					finalizeClientVisualRecovery(item.queued, false, "timeline_cancelled")
				end
			end
		end
		if cancelled > 0 then SCLG_Diagnostics.writeSummaryNow() end
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
			if #due >= MAX_TIMELINE_BODIES_PER_PASS then break end
		end
	end
	for i = 1, #due do
		local item = due[i]
		-- La foto `due` puede contener una entrada que una finalizacion previa
		-- ya retiro por caseId. No procesarla de nuevo ni duplicar completed.
		if groundRecheckQueue[item.key] == item.queued then
			local ok, completeOrError = pcall(auditGroundTimeline, item.queued)
			local caseId = timelineCaseId(item.queued.entry, item.key)
			if not ok then
				local removed = removeTimelinesForCase(caseId)
				local stats = SCLG_Diagnostics.stats()
				stats.timelinesFailed = (stats.timelinesFailed or 0) + 1
				SCLG_Diagnostics.recordSignal(item.queued.entry, "TIMELINE", "TIMELINE_PROCESSING_FAILED",
					"error=" .. tostring(completeOrError) .. " removedEntries=" .. tostring(removed), false)
				finalizeClientVisualRecovery(item.queued, false, "timeline_processing_failed")
				SCLG_Log.warn("CorpseTimeline", "checkpoint fallo; timeline liberada case="
					.. caseId .. " error=" .. tostring(completeOrError))
				SCLG_Diagnostics.writeSummaryNow()
			elseif completeOrError then
				local removed = removeTimelinesForCase(caseId)
				if removed > 1 then
					SCLG_Log.warn("CorpseTimeline", "limpieza retiro timelines duplicadas case="
						.. caseId .. " count=" .. tostring(removed))
				end
				-- Escribir DESPUES de retirar la cola: DEV2 escribia dentro de
				-- auditGroundTimeline y el ultimo caso aparecia a la vez como
				-- completed y active aunque se eliminase inmediatamente despues.
				SCLG_Diagnostics.writeSummaryNow()
			end
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
	local pendingCount, reportCount, recheckCount, bodyClaimCount = 0, 0, 0, 0
	for _ in pairs(pending) do pendingCount = pendingCount + 1 end
	for _ in pairs(clientReports) do reportCount = reportCount + 1 end
	for _ in pairs(groundRecheckQueue) do recheckCount = recheckCount + 1 end
	for _ in pairs(bodyClaims) do bodyClaimCount = bodyClaimCount + 1 end
	return { pending = pendingCount, clientReports = reportCount, rechecks = recheckCount,
		earlyBodies = #earlyBodies, bodyClaims = bodyClaimCount }
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
