--[[
	SiK Corpse Loot Guard - Diagnostico de perdida de loot al morir un zombie
	Autor: SiK
	Fecha: 2026-07-31
	Descripcion: v0.1.0 SOLO DIAGNOSTICO. No crea, borra ni mueve ningun
	objeto. Captura el estado de ropa/inventario del zombie antes de morir
	(OnWeaponHitCharacter como via principal; OnZombieUpdate muestreado como
	respaldo para fuego/caidas/otras muertes) y lo compara justo despues de
	OnZombieDead, cuando DoZombieInventory() ya vacio y reconstruyo el
	inventario desde la apariencia visual. Si el resultado tiene menos
	objetos de los que deberia, se registra UNA entrada LOSS por caso.

	Carga: server-side (y SP real, que ejecuta esta logica en el mismo
	proceso). No toca ningun fichero de Authentic Z ni de ningun otro mod.
]]

require "SCLG_Config"
require "SCLG_Sandbox"
require "SCLG_Log"
require "SCLG_Capture"
require "SCLG_Snapshot"
require "SCLG_FileLog"
require "SCLG_Diagnostics"
require "SCLG_CorpseAudit"
require "SCLG_RecoverySimulation"

-- IMPORTANTE: en B42, la carpeta media/lua/server/ es solo organizativa -
-- el motor carga estos ficheros en TODOS los procesos (servidor dedicado,
-- cliente remoto Y singleplayer real), no solo en el servidor. Confirmado
-- con evidencia real: esta misma logica se estaba ejecutando tambien en el
-- cliente, duplicando el trabajo y generando lecturas inconsistentes.
-- Guarda explicita necesaria.
--
-- CORREGIDO (el comentario anterior decia lo contrario y era un bug real):
-- en singleplayer real, isServer() e isClient() dan AMBOS false - NO ambos
-- true como se creia antes (gotcha ya documentado y corregido en este mismo
-- proyecto para GlobalStorageSiK, ver GlobalStorageSiK.isAuthoritative() en
-- GS_Config.lua). Con la guarda anterior (`not isServer()`), en SP real
-- isServer() es false, asi que la guarda hacia `return` SIEMPRE y el mod
-- entero quedaba mudo en SP puro - nunca se habria detectado ninguna muerte
-- en ese modo. La guarda correcta es la misma que usa GlobalStorageSiK: solo
-- excluir al cliente remoto puro (isClient()=true, isServer()=false); todo
-- lo demas (servidor dedicado, SP real con ambos false, host LAN con ambos
-- true) es un proceso autoritativo donde SI debe correr esta logica. Este
-- mod es standalone (no depende de GlobalStorageSiK); la comprobacion vive
-- en SCLG_Config para que Server, Capture y CorpseAudit no puedan divergir.
if not SCLG_Config.isAuthoritative() then
	return
end

-- Interruptor maestro (sandbox SiKCorpseLootGuard.EnableMod): si esta
-- desactivado, no se registra NINGUN evento ni se ejecuta logica alguna.
if not SCLG_Sandbox.isModEnabled() then
	SCLG_Log.info("Server", "SiK Corpse Loot Guard desactivado por sandbox (EnableMod=false), no se registra ningun evento")
	return
end

local stats = SCLG_Diagnostics.stats()
local lastSummaryAt = 0

---@return number
local function nowMs()
	if getTimestampMs then
		return getTimestampMs()
	end
	return 0
end

--- Cuenta cuantas veces aparece cada fullType en una lista de descriptores.
--- IMPORTANTE: antes se usaba un simple set de presencia (fullType SI/NO),
--- lo que fallaba si el zombie llevaba 2 unidades del mismo tipo y el
--- cadaver reconstruido solo tenia 1 - el tipo "estaba presente" asi que no
--- se detectaba nada, pese a faltar una unidad de verdad. Contando
--- cantidades por tipo se detecta tambien esa perdida parcial.
---@param list table[] lista de descriptores { fullType=... }
---@return table<string, number>
local function fullTypeCounts(list)
	local counts = {}
	for i = 1, #list do
		local ft = list[i].fullType
		if ft then
			counts[ft] = (counts[ft] or 0) + 1
		end
	end
	return counts
end

--- Para cada fullType de `preList`, calcula cuantas unidades faltan en
--- `postCounts` (preCount - postCount, nunca negativo). Devuelve una lista
--- de fullTypes que representa cada unidad que falta (un fullType con 2
--- unidades perdidas aparece 2 veces en la lista, asi que
--- table.concat(...) sigue reflejando el numero real de unidades perdidas).
---@param preList table[]
---@param postCounts table<string, number>
---@return string[]
local function missingFrom(preList, postCounts)
	local preCounts = fullTypeCounts(preList)
	local missing = {}
	for ft, preCount in pairs(preCounts) do
		local deficit = preCount - (postCounts[ft] or 0)
		for _ = 1, deficit do
			missing[#missing + 1] = ft
		end
	end
	return missing
end

--- Version de missingFrom() para listas de STRINGS planos (itemVisualTypes
--- no son descriptores {fullType=...}, son strings directamente).
---@param preList string[]
---@param postList string[]
---@return string[]
local function missingStrings(preList, postList)
	local preCounts, postCounts = {}, {}
	for i = 1, #preList do preCounts[preList[i]] = (preCounts[preList[i]] or 0) + 1 end
	for i = 1, #postList do postCounts[postList[i]] = (postCounts[postList[i]] or 0) + 1 end
	local missing = {}
	for v, preCount in pairs(preCounts) do
		local deficit = preCount - (postCounts[v] or 0)
		for _ = 1, deficit do
			missing[#missing + 1] = v
		end
	end
	return missing
end

--- Accesorios que se desprenden con normalidad durante el combate (gafas,
--- sombreros, gorras...) - una ausencia visual parcial de SOLO estos tipos
--- no deberia sorprender a nadie revisando el log.
local DROPPABLE_PATTERNS = { "glasses", "hat", "cap", "hood", "mask", "helmet" }
---@param typeName string
---@return boolean
local function isDroppableAccessory(typeName)
	local lower = tostring(typeName):lower()
	for i = 1, #DROPPABLE_PATTERNS do
		if lower:find(DROPPABLE_PATTERNS[i], 1, true) then
			return true
		end
	end
	return false
end

---@param pre table snapshot previo
---@return boolean
local function looksAuthenticZ(pre)
	if pre.outfitName and tostring(pre.outfitName):find("Authentic") then
		return true
	end
	for _, entry in ipairs(pre.worn or {}) do
		if entry.fullType and tostring(entry.fullType):find("^AuthenticZClothing%.") then
			return true
		end
	end
	for _, entry in ipairs(pre.inventory or {}) do
		if entry.fullType and tostring(entry.fullType):find("^AuthenticZClothing%.") then
			return true
		end
	end
	return false
end

--- Sonda de hipotesis tipo de muerte/animacion (ver
--- SCLG_Sandbox.isDeathContextCaptureEnabled): recoge estado del zombie en
--- el instante de morir (agachado/caido) que podria correlacionar con
--- animaciones de muerte especiales (desmembramiento, ataque furtivo...)
--- que quizas no pasen por el mismo camino de reconstruccion de inventario
--- que una muerte normal. Nombres de metodo sin confirmar en vanilla (igual
--- criterio que el resto del mod): se prueban con pcall y degradan a "?".
--- BUG REAL encontrado (reportado): zombie:isFallen() no existe en este
--- build - el pcall SI evita que el error interrumpa el flujo (okF queda
--- false, degrada a "?" correctamente), pero el motor Kahlua vuelca el
--- stack trace del fallo interno a la consola de todas formas, en CADA
--- muerte de zombie con esta captura activa - mismo gotcha ya documentado
--- (pcall no suprime el log del motor, ver hasTag/getDaysFresh en items
--- moddeados). Solucion: no llamar a un metodo que no existe, en vez de
--- confiar en que el pcall oculte el ruido - no lo hace.
---@param zombie any
---@return string
local function describeDeathContext(zombie)
	local crawling = "?"
	local okC, c = pcall(function() return zombie:isCrawling() end)
	if okC then crawling = tostring(c) end
	return "crawling=" .. crawling .. " fallen=?"
end

local function writeSummaryNow()
	lastSummaryAt = nowMs()
	SCLG_Diagnostics.writeSummaryNow()
end

---@param zombie any
local function emitSummaryIfDue()
	local now = nowMs()
	if (now - lastSummaryAt) < SCLG_Sandbox.getSummaryIntervalMs() then
		return
	end
	writeSummaryNow()
end

local lastHousekeepingAt = 0
local function onHousekeepingTick()
	local now = nowMs()
	if (now - lastHousekeepingAt) < 1000 then return end
	lastHousekeepingAt = now
	SCLG_Capture.sweepIfDue()
	SCLG_CorpseAudit.sweepIfDue()
	emitSummaryIfDue()
end

---@param zombie any
local function onZombieDead(zombie)
	if not zombie then
		return
	end
	stats.deathsChecked = stats.deathsChecked + 1

	local pre, key = SCLG_Capture.take(zombie)
	local post = nil
	local snapshotFound = pre ~= nil
	if not pre then
		stats.snapshotsMissed = stats.snapshotsMissed + 1
		post = SCLG_Snapshot.build(zombie)
		post.capturedAt = nowMs()
		SCLG_Diagnostics.attachCase(post, nil)
		pre = {
			sessionId = post.sessionId, caseId = post.caseId, capturedAt = post.capturedAt,
			firstCapturedAt = post.capturedAt, captureCount = 0, reason = "missed",
			onlineID = post.onlineID, outfitName = nil, persistentOutfitID = post.persistentOutfitID,
			x = post.x, y = post.y, z = post.z, sex = post.sex,
			worn = {}, inventory = {}, attached = {}, itemVisualTypes = {},
		}
		SCLG_Diagnostics.recordStage(pre, "DEATH", "SNAPSHOT_MISSED",
			"captureKey=" .. tostring(key) .. " snapshotFound=false")
		SCLG_Log.info("Server", "onZombieDead | session=" .. tostring(pre.sessionId)
			.. " case=" .. tostring(pre.caseId) .. " key=" .. tostring(key)
			.. " snapshotFound=false")
	else
		stats.snapshotsHit = stats.snapshotsHit + 1
		post = SCLG_Snapshot.build(zombie)
		post.sessionId = pre.sessionId
		post.caseId = pre.caseId
	end

	-- Entrega el estado DEATH (este mismo `post`) al auditor de cadaver
	-- definitivo, que lo comparara mas tarde contra el IsoDeadBody real
	-- (Events.OnDeadBodySpawn) - el IsoZombie que auditamos aqui NO es el
	-- objeto final que ve el jugador. Ver SCLG_CorpseAudit.lua.
	SCLG_CorpseAudit.registerDeathStage(pre, post, zombie)
	SCLG_Diagnostics.recordStage({ pre = pre, death = post, onlineID = post.onlineID,
		x = post.x, y = post.y, z = post.z }, "DEATH", "DEATH_CAPTURED", string.format(
		"snapshotFound=%s captureReason=%s captureCount=%s captureTransitions=%s latestCaptureScore=%s latestCaptureOutfit=%s ageFromFirstCaptureMs=%s preVisuals=%d deathInventory=%d deathVisuals=%d",
		tostring(snapshotFound), tostring(pre.reason), tostring(pre.captureCount),
		tostring(#(pre.captureTimeline or {})), tostring(pre.latestCapture and pre.latestCapture.score or "?"),
		tostring(pre.latestCapture and pre.latestCapture.outfitName or "?"),
		tostring(nowMs() - (pre.firstCapturedAt or nowMs())),
		#(pre.itemVisualTypes or {}), #(post.inventory or {}), #(post.itemVisualTypes or {})))

	-- fullTypes en crudo, para el log detallado (ver punto 3 del pivote:
	-- necesitamos saber los VALORES concretos que devuelve ItemVisual, no
	-- solo cuantos hay).
	---@param list table[]
	---@return string
	local function fullTypesOf(list)
		local out = {}
		for i = 1, #list do out[i] = list[i].fullType or "?" end
		return #out > 0 and table.concat(out, ";") or "(ninguno)"
	end
	local function visualTypesJoined(list)
		return (#(list or {}) > 0) and table.concat(list, ";") or "(ninguno)"
	end

	-- Traza detallada por CADA muerte (no solo el resumen cada 5 minutos, que
	-- esconde demasiado durante la fase de pruebas). Bajar a debug() mas
	-- adelante cuando el patron ya este confirmado y esto deje de hacer falta.
	SCLG_Log.debug("Server", string.format(
		"onZombieDead | onlineID=%s snapshotFound=%s preWorn=%d preInventory=%d preAttached=%d postWorn=%d postInventory=%d postAttached=%d preVisuals=%d postVisuals=%d",
		tostring(pre.onlineID), tostring(snapshotFound), #pre.worn, #pre.inventory, #pre.attached, #post.worn, #post.inventory, #post.attached,
		#(pre.itemVisualTypes or {}), #(post.itemVisualTypes or {})))
	SCLG_Log.debug("Server", string.format(
		"onZombieDead types | onlineID=%s preVisualTypes=%s postVisualTypes=%s postInventoryTypes=%s",
		tostring(pre.onlineID), visualTypesJoined(pre.itemVisualTypes), visualTypesJoined(post.itemVisualTypes),
		fullTypesOf(post.inventory)))

	-- PIVOTE (confirmado con datos reales de 19 muertes de prueba): antes de
	-- morir, el zombie vivo casi SIEMPRE tiene preWorn=0 y preInventory=0 -
	-- los InventoryItem reales no existen todavia, solo la apariencia visual
	-- (ItemVisuals). Los objetos reales se generan DURANTE
	-- DoZombieInventory(), al morir. Por eso preVisualCount, no
	-- preWornCount, es la señal PRINCIPAL de "deberia tener algo".
	--
	-- Tambien: postWorn y postInventory contienen basicamente los MISMOS
	-- objetos (las prendas puestas tambien forman parte del inventario del
	-- cadaver) - sumarlos duplicaba el conteo. post.inventory es la
	-- coleccion CANONICA para el recuento; worn/attached quedan solo como
	-- info de estado/ubicacion en el log, no se suman.
	local postCounts = fullTypeCounts(post.inventory)
	local postTotalCount = #post.inventory

	-- preCombined (worn+inventory+attached DEL ZOMBIE VIVO) es secundario:
	-- normalmente vacio segun el pivote de arriba, pero cuando SI tiene
	-- datos (ej. objetos ya presentes antes de que el zombie muera, algun
	-- caso especial) sigue siendo una señal valida de perdida parcial.
	local preCombined = {}
	for _, e in ipairs(pre.worn) do preCombined[#preCombined + 1] = e end
	for _, e in ipairs(pre.inventory) do preCombined[#preCombined + 1] = e end
	for _, e in ipairs(pre.attached) do preCombined[#preCombined + 1] = e end

	local preWornCount = #pre.worn
	local preInvCount = #pre.inventory
	local preVisualCount = #(pre.itemVisualTypes or {})
	local postVisualCount = #(post.itemVisualTypes or {})

	local missingAll = missingFrom(preCombined, postCounts)

	local deathContextStr = ""
	if SCLG_Sandbox.isDeathContextCaptureEnabled() then
		deathContextStr = string.format(" weapon=%s %s", tostring(pre.lastHitWeapon), describeDeathContext(zombie))
	end

	-- Sonda de hipotesis Authentic Z (ver SCLG_Snapshot.probeAuthenticZInstantiation):
	-- si el zombie llevaba ropa AuthenticZClothing visualmente, comprueba si
	-- instanceItem() falla para esos fullTypes con el mismo error de motor
	-- confirmado en el mod CAEC (NoSuchMethodError: Translator.getText). Si
	-- falla aqui tambien, es evidencia directa de que ese es el mecanismo
	-- real de la perdida silenciosa, no solo una sospecha por nombre de mod.
	if preVisualCount > 0 and SCLG_Sandbox.isAuthenticZProbeEnabled() then
		local probeResults = SCLG_Snapshot.probeAuthenticZInstantiation(pre.itemVisualTypes)
		for i = 1, #probeResults do
			local r = probeResults[i]
			if not r.ok then
				stats.authenticZInstanceFailures = (stats.authenticZInstanceFailures or 0) + 1
				local probeLine = string.format(
					"onlineID=%s fullType=%s error=%s%s (instanceItem() fallo para este item Authentic Z - misma clase de fallo confirmada en el mod CAEC para AuthenticZClothing.*, evidencia directa de la causa de la perdida)",
					tostring(pre.onlineID), r.fullType, tostring(r.error), deathContextStr)
				SCLG_Log.warn("AUTHENTICZ_INSTANCE_FAIL", probeLine)
				SCLG_Diagnostics.recordSignal(pre, "DEATH", "AUTHENTICZ_INSTANCE_FAIL", probeLine, true)
			elseif SCLG_Config.enableDebug() then
				SCLG_Log.debug("AuthenticZProbe", "instanceItem OK para " .. r.fullType)
			end
		end
	end

	-- Perdida total confirmada: la apariencia visual antes de morir decia
	-- que debia llevar algo encima, y el inventario reconstruido del
	-- cadaver se ha quedado completamente vacio.
	local confirmedTotalLoss = preVisualCount > 0 and postTotalCount == 0
	local hasPartialLoss = #missingAll > 0

	-- Señal distinta: el cadaver puede aparecer VISUALMENTE desnudo
	-- (itemVisualTypes vacio, lo que ve el jugador) mientras el inventario
	-- real del cadaver SI conserva objetos (postTotalCount > 0). Explicaria
	-- por que un jugador reporta "el zombi murio desnudo" sin que haya
	-- perdida real de items - seria un problema de RENDERIZADO del cadaver.
	-- Desde aqui hasta el final de la funcion, este mismo caso (si se
	-- confirma) tambien se cuenta como CLOTHING_TOTAL_LOSS mas abajo (ver
	-- clothingTotalLoss) - dos lineas de log distintas para el MISMO evento,
	-- correlables por onlineID: esta da el detalle de renderizado
	-- (preVisuals/postVisuals/postInventory), la de CLOTHING_TOTAL_LOSS lo
	-- cuenta formalmente en lossesDetected con posicion/outfit/contexto.
	local nakedVisualButInventoryPresent = preVisualCount > 0 and postVisualCount == 0 and postTotalCount > 0
	if nakedVisualButInventoryPresent then
		stats.nakedVisualButInventoryPresent = stats.nakedVisualButInventoryPresent + 1
		local visualLine = string.format(
			"onlineID=%s preVisuals=%d postVisuals=%d postInventory=%d (cadaver parece desnudo pero SI conserva objetos en inventario)",
			tostring(pre.onlineID), preVisualCount, postVisualCount, postTotalCount)
		SCLG_Log.warn("NAKED_VISUAL_BUT_PRESENT", visualLine)
		SCLG_Diagnostics.recordSignal(pre, "DEATH", "NAKED_VISUAL_BUT_PRESENT", visualLine, true)
		SCLG_RecoverySimulation.evaluate({ pre = pre, death = post }, "NAKED_VISUAL_BUT_PRESENT")
	end

	-- Delta visual PARCIAL: no es perdida total ni desnudez visual, solo
	-- falta ALGUNA apariencia previa en la reconstruida (ej. gafas que se
	-- caen en combate). Informativo, no cuenta como LOSS - evita falsos
	-- positivos por accesorios que se desprenden con normalidad. Marca los
	-- casos donde TODO lo que falta es un accesorio desprendible conocido.
	if not confirmedTotalLoss and not nakedVisualButInventoryPresent
		and preVisualCount > 0 and postVisualCount < preVisualCount then
		local missingVisuals = missingStrings(pre.itemVisualTypes or {}, post.itemVisualTypes or {})
		if #missingVisuals > 0 then
			stats.visualDeltasDetected = stats.visualDeltasDetected + 1
			local allDroppable = true
			for i = 1, #missingVisuals do
				if not isDroppableAccessory(missingVisuals[i]) then
					allDroppable = false
					break
				end
			end
			local deltaLine = string.format(
				"onlineID=%s preVisuals=%d postVisuals=%d missingVisuals=%s allExpectedDroppable=%s",
				tostring(pre.onlineID), preVisualCount, postVisualCount,
				table.concat(missingVisuals, ";"), tostring(allDroppable))
			SCLG_Log.info("VISUAL_DELTA", deltaLine)
			SCLG_Diagnostics.recordSignal(pre, "DEATH", "VISUAL_DELTA", deltaLine, false)
		end
	end

	-- CIEGO CONOCIDO (confirmado con casos reales onlineID=10993/11049):
	-- si la captura previa TAMBIEN estaba vacia (preVisuals=0), confirmedTotalLoss
	-- no se dispara (compara "vacio contra vacio") aunque el jugador viera
	-- al zombie vestido antes de morir. Probablemente la captura se tomo
	-- demasiado pronto, antes de que el servidor materializase/sincronizase
	-- el outfit. Este caso se marca aparte, SIEMPRE que el cadaver quede
	-- totalmente vacio, tenga o no datos previos, para no depender de que
	-- la captura previa haya llegado a tiempo.
	local totallyEmptyCorpse = postTotalCount == 0 and postVisualCount == 0
	local emptyCorpseSuspect = totallyEmptyCorpse and not confirmedTotalLoss
	if emptyCorpseSuspect then
		stats.emptyCorpseSuspect = stats.emptyCorpseSuspect + 1
		local x, y, z = 0, 0, 0
		pcall(function()
			x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
		end)
		local sex = "?"
		pcall(function() sex = zombie:isFemale() and "female" or "male" end)
		local suspectLine = string.format(
			"onlineID=%s outfit=%s persistentOutfitID=%s sex=%s pos=%d,%d,%d preVisuals=%d preWorn=%d preInventory=%d "
			.. "(cadaver totalmente vacio; snapshot previo tambien vacio - posible captura demasiado temprana o outfit no materializado a tiempo)",
			tostring(pre.onlineID), tostring(pre.outfitName), tostring(pre.persistentOutfitID), sex,
			math.floor(x), math.floor(y), math.floor(z), preVisualCount, preWornCount, preInvCount)
		SCLG_Log.warn("EMPTY_CORPSE_SUSPECT", suspectLine)
		SCLG_Diagnostics.recordSignal(pre, "DEATH", "EMPTY_CORPSE_SUSPECT", suspectLine, true)
		SCLG_RecoverySimulation.evaluate({ pre = pre, death = post }, "EMPTY_CORPSE_SUSPECT")
	end

	-- BUG REAL encontrado (caso confirmado onlineID=29981: preVisuals=9,
	-- postVisuals=0, postInventory=1 [Base.Shotgun] - 9 prendas vistas por el
	-- cliente, cero conservadas, solo sobrevive un arma vinculada sin
	-- relacion con la ropa): esta puerta antes solo miraba confirmedTotalLoss
	-- (exige postTotalCount==0 exacto) y hasPartialLoss (exige preCombined,
	-- que el "PIVOTE" de arriba ya documenta como casi SIEMPRE vacio para un
	-- zombie vivo) - ninguna de las dos se activaba cuando sobrevive un
	-- objeto NO relacionado con la ropa (arma, herramienta...) mientras la
	-- capa visual completa desaparece. nakedVisualButInventoryPresent SI
	-- detectaba el patron (linea NAKED_VISUAL_BUT_PRESENT de arriba), pero
	-- quedaba fuera de lossesDetected - de ahi que el propio caso capturado
	-- no contara como perdida formal pese a ser inequivoco. Se cuenta aparte
	-- de confirmedTotalLoss (son mutuamente excluyentes: nakedVisualButInventoryPresent
	-- exige postTotalCount>0, confirmedTotalLoss exige postTotalCount==0).
	local clothingTotalLoss = nakedVisualButInventoryPresent

	if confirmedTotalLoss or hasPartialLoss or clothingTotalLoss then
		stats.lossesDetected = stats.lossesDetected + 1
		stats.itemsMissing = stats.itemsMissing + #missingAll

		local x, y, z = 0, 0, 0
		pcall(function()
			x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
		end)

		local lossCategory = (clothingTotalLoss and not confirmedTotalLoss) and "CLOTHING_TOTAL_LOSS" or "LOSS"
		local lossLine = string.format(
			"onlineID=%s outfit=%s persistentOutfitID=%s pos=%d,%d,%d "
			.. "preVisuals=%d preInventory=%d preWorn=%d postInventory=%d missing=%s authenticSuspect=%s%s%s%s",
			tostring(pre.onlineID), tostring(pre.outfitName), tostring(pre.persistentOutfitID),
			math.floor(x), math.floor(y), math.floor(z),
			preVisualCount, preInvCount, preWornCount, postTotalCount,
			(#missingAll > 0 and table.concat(missingAll, ";") or "(ninguno identificado, perdida total de ropa)"),
			tostring(looksAuthenticZ(pre)),
			confirmedTotalLoss and " totalLoss=true" or "",
			clothingTotalLoss and " clothingTotalLoss=true" or "",
			deathContextStr)
		SCLG_Log.warn(lossCategory, lossLine)
		SCLG_Diagnostics.recordSignal(pre, "DEATH", lossCategory, lossLine, true)
		SCLG_RecoverySimulation.evaluate({ pre = pre, death = post }, lossCategory, { missing = missingAll })
	elseif SCLG_Config.enableDebug() then
		SCLG_Log.debug("Server", "onZombieDead sin perdidas, key=" .. tostring(key)
			.. " preVisuals=" .. tostring(preVisualCount) .. " postTotal=" .. tostring(postTotalCount))
	end

	-- Fase de diagnostico: resumen actualizado en CADA muerte procesada (no
	-- solo cada 5 min) para poder revisar el fichero justo despues de cada
	-- prueba sin esperar al intervalo. Volver a emitSummaryIfDue(zombie) mas
	-- adelante cuando el patron ya este confirmado y esto deje de hacer falta.
	writeSummaryNow()
end

---@param attacker any
---@param victim any
local function onWeaponHitCharacter(attacker, victim)
	if not victim then
		return
	end
	local okIsZombie, isZombie = pcall(function() return instanceof(victim, "IsoZombie") end)
	if not okIsZombie or not isZombie then
		return
	end
	SCLG_Capture.capture(victim, "hit")
	if SCLG_Sandbox.isDeathContextCaptureEnabled() and attacker then
		local okW, weapon = pcall(function()
			local item = attacker.getPrimaryHandItem and attacker:getPrimaryHandItem()
			return item and item:getFullType() or nil
		end)
		if okW and weapon then
			SCLG_Capture.recordDeathContextWeapon(victim, weapon)
		end
	end
	SCLG_Capture.sweepIfDue()
	SCLG_CorpseAudit.sweepIfDue()
end

-- Respaldo para muertes que no pasan por OnWeaponHitCharacter (fuego,
-- caidas, otras causas). Muestreado agresivamente (ver
-- SCLG_Config.ZOMBIE_UPDATE_SAMPLE_RATE) porque este evento se dispara por
-- zombie y por tick - sin muestreo penalizaria el rendimiento con muchos
-- zombies en pantalla.
local zombieUpdateCounter = 0
---@param zombie any
local function onZombieUpdate(zombie)
	zombieUpdateCounter = zombieUpdateCounter + 1
	if (zombieUpdateCounter % SCLG_Sandbox.getZombieUpdateSampleRate()) ~= 0 then
		return
	end
	if not zombie then
		return
	end
	SCLG_Capture.capture(zombie, "fallback")
	SCLG_Capture.sweepIfDue()
end

Events.OnZombieDead.Add(onZombieDead)
Events.OnTick.Add(onHousekeepingTick)

if Events.OnWeaponHitCharacter then
	Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)
else
	SCLG_Log.warn("Server", "Events.OnWeaponHitCharacter no existe en esta build - la captura por golpe queda deshabilitada, solo funcionara el respaldo OnZombieUpdate (muertes por fuego/caida cubiertas, cuerpo a cuerpo/arma de fuego NO)")
end

if not SCLG_Sandbox.isFallbackCaptureEnabled() then
	SCLG_Log.info("Server", "Captura de respaldo (OnZombieUpdate) desactivada por sandbox - solo se capturaran zombies golpeados directamente")
elseif Events.OnZombieUpdate then
	Events.OnZombieUpdate.Add(onZombieUpdate)
else
	SCLG_Log.warn("Server", "Events.OnZombieUpdate no existe en esta build - sin respaldo para fuego/caidas, solo se capturaran zombies golpeados directamente")
end

--- Recibe la telemetria ligera de cliente (ver SCLG_ClientVisualReport.lua):
--- SOLO lo que el cliente vio como apariencia visual de un zombie/cadaver,
--- identificado por onlineID. El cliente NO ejecuta logica de diagnostico
--- propia, solo lee y manda este dato - toda la clasificacion sigue
--- pasando aqui, en el servidor.
---@param module string
---@param command string
---@param player any
---@param args table
local function finitePayloadNumber(value, absoluteLimit)
	return type(value) == "number" and value == value
		and math.abs(value) <= (absoluteLimit or 10000000)
end

local function onClientCommand(module, command, player, args)
	if module ~= SCLG_Config.MOD_ID then
		return
	end
	if command == "clientVisualReport" then
		if type(args) ~= "table" or type(args.onlineID) ~= "number"
			or args.onlineID < 0 or args.onlineID > 2147483647 then
			return
		end
		local rawTypes = type(args.types) == "string" and args.types or ""
		if #rawTypes > SCLG_Config.CLIENT_REPORT_MAX_BYTES then
			SCLG_Log.warn("Network", "clientVisualReport rechazado: payload demasiado grande bytes=" .. tostring(#rawTypes))
			return
		end
		local types = {}
		if rawTypes ~= "" then
			for t in string.gmatch(rawTypes, "[^|]+") do
				if #t > SCLG_Config.CLIENT_REPORT_MAX_TYPE_BYTES
					or #types >= SCLG_Config.CLIENT_REPORT_MAX_TYPES then
					SCLG_Log.warn("Network", "clientVisualReport rechazado: lista/tipo fuera de limite")
					return
				end
				types[#types + 1] = t
			end
		end
		local rawDescriptors = type(args.descriptors) == "string" and args.descriptors or ""
		if #rawDescriptors > SCLG_Config.CLIENT_REPORT_MAX_DESCRIPTOR_BYTES then
			SCLG_Log.warn("Network", "clientVisualReport rechazado: descriptores demasiado grandes bytes="
				.. tostring(#rawDescriptors))
			return
		end
		local descriptors = {}
		local serverHashes = {}
		local descriptorComplete, descriptorEligible = 0, 0
		if rawDescriptors ~= "" then
			local decoded, decodeError = SCLG_Snapshot.decodeVisualEvidence(rawDescriptors,
				SCLG_Config.CLIENT_REPORT_MAX_DESCRIPTORS,
				SCLG_Config.CLIENT_REPORT_MAX_DESCRIPTOR_FIELD_BYTES)
			if not decoded then
				SCLG_Log.warn("Network", "clientVisualReport rechazado: descriptor invalido reason="
					.. tostring(decodeError))
				return
			end
			descriptors = decoded
			if #descriptors ~= #types then
				SCLG_Log.warn("Network", "clientVisualReport rechazado: tipos/descriptores no coinciden types="
					.. tostring(#types) .. " descriptors=" .. tostring(#descriptors))
				return
			end
			local typeCopy, descriptorTypeCopy = {}, {}
			for i = 1, #types do typeCopy[i] = types[i] end
			for i = 1, #descriptors do descriptorTypeCopy[i] = tostring(descriptors[i].fullType or "?") end
			table.sort(typeCopy)
			table.sort(descriptorTypeCopy)
			for i = 1, #typeCopy do
				if typeCopy[i] ~= descriptorTypeCopy[i] then
					SCLG_Log.warn("Network", "clientVisualReport rechazado: fullType descriptor no coincide")
					return
				end
			end
			serverHashes = SCLG_Snapshot.visualEvidenceHashes(descriptors)
			local serverSampleHash = serverHashes.full
			if type(args.sampleHash) ~= "string" or #args.sampleHash > 32
				or args.sampleHash ~= serverSampleHash then
				SCLG_Log.warn("Network", "clientVisualReport rechazado: sampleHash no coincide")
				return
			end
			for _, hashField in ipairs({ "compositionHash", "appearanceHash", "stateHash" }) do
				local expected = serverHashes[string.gsub(hashField, "Hash$", "")]
				if type(args[hashField]) ~= "string" or #args[hashField] > 32
					or args[hashField] ~= expected then
					SCLG_Log.warn("Network", "clientVisualReport rechazado: " .. hashField .. " no coincide")
					return
				end
			end
			descriptorComplete, descriptorEligible = SCLG_Snapshot.assessClientVisualEvidence(descriptors)
		elseif args.sampleHash ~= nil or args.compositionHash ~= nil
			or args.appearanceHash ~= nil or args.stateHash ~= nil then
			return
		end
		local allowedKinds = { preHit = true, periodic = true, death = true }
		if not allowedKinds[args.kind] then return end
		local observedBy = "?"
		local observerSteamID = "?"
		local observerX, observerY, observerZ = nil, nil, nil
		pcall(function()
			observedBy = player and player:getUsername() or "?"
			if player and player.getSteamID then observerSteamID = tostring(player:getSteamID()) end
			if player then observerX, observerY, observerZ = player:getX(), player:getY(), player:getZ() end
		end)
		local reportX = finitePayloadNumber(args.x) and args.x or nil
		local reportY = finitePayloadNumber(args.y) and args.y or nil
		local reportZ = finitePayloadNumber(args.z, 10000) and args.z or nil
		local observerClaimDistance = math.huge
		local observerWithinClaim = false
		if observerX ~= nil and observerY ~= nil and reportX ~= nil and reportY ~= nil
			and math.floor(observerZ or 0) == math.floor(reportZ or 0) then
			local dx, dy = observerX - reportX, observerY - reportY
			observerClaimDistance = math.sqrt(dx * dx + dy * dy)
			observerWithinClaim = observerClaimDistance <= SCLG_Config.CLIENT_REPORT_OBSERVER_RADIUS_TILES
		end
		SCLG_CorpseAudit.reportClientVisual(args.onlineID, types, {
			kind = args.kind,
			outfitName = type(args.outfitName) == "string" and args.outfitName:sub(1, 256) or nil,
			persistentOutfitID = type(args.persistentOutfitID) == "string" and args.persistentOutfitID:sub(1, 128) or nil,
			observedBy = tostring(observedBy),
			observerSteamID = observerSteamID,
			reportedAtClientMs = type(args.reportedAtClientMs) == "number" and args.reportedAtClientMs or nil,
			x = reportX, y = reportY, z = reportZ,
			observerX = observerX, observerY = observerY, observerZ = observerZ,
			observerClaimDistance = observerClaimDistance,
			observerWithinClaim = observerWithinClaim,
			descriptors = descriptors,
			sampleHash = serverHashes.full,
			compositionHash = serverHashes.composition,
			appearanceHash = serverHashes.appearance,
			stateHash = serverHashes.state,
			descriptorComplete = descriptorComplete,
			descriptorEligible = descriptorEligible,
		})
	elseif command == "spawnAttempt" then
		-- Registro de un spawn de prueba pedido desde el menu SCLG Spawn
		-- Test (ver SCLG_SpawnHordeUI.lua) - permite comparar despues
		-- cuantos spawns pedidos llegaron realmente a procesarse como
		-- muerte, para investigar zombies que se piden pero no aparecen.
		if type(args) ~= "table" then
			return
		end
		local access = ""
		pcall(function() access = tostring(player and player:getAccessLevel() or ""):lower() end)
		if access ~= "admin" and access ~= "moderator" then
			SCLG_Log.warn("Network", "spawnAttempt rechazado: permiso insuficiente")
			return
		end
		SCLG_FileLog.appendSpawn(string.format(
			"label=%s outfit=%s count=%s pos=%s,%s,%s",
			tostring(args.label), tostring(args.outfit), tostring(args.count),
			tostring(args.x), tostring(args.y), tostring(args.z)))
	end
end
Events.OnClientCommand.Add(onClientCommand)

SCLG_Diagnostics.setGaugeProvider(function()
	local audit = SCLG_CorpseAudit.gauges and SCLG_CorpseAudit.gauges() or {}
	return {
		cacheSize = SCLG_Capture.cacheSize(),
		pending = audit.pending,
		clientReports = audit.clientReports,
		rechecks = audit.rechecks,
		earlyBodies = audit.earlyBodies,
		bodyClaims = audit.bodyClaims,
	}
end)

SCLG_Log.info("Server", "SiK Corpse Loot Guard v" .. SCLG_Config.MOD_VERSION
	.. " cargado (diagnostico + simulacion DRY RUN, sin reparacion). session="
	.. SCLG_Diagnostics.sessionId() .. " ficheros: losses, summary, cases y recovery_simulation en Zomboid/Lua")
