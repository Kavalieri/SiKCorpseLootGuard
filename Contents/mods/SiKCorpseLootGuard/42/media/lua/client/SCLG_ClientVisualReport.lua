--[[
	SiK Corpse Loot Guard - Telemetria ligera de cliente
	Autor: SiK
	Descripcion: NO ejecuta logica de diagnostico propia, NO repara nada.
	Unico proposito: leer que apariencia visual ve ESTE cliente concreto de
	un zombie y mandarsela al servidor identificada por onlineID, para que
	el servidor compare "lo que el jugador vio" contra "lo que el servidor
	registro" (ver SCLG_CorpseAudit.lua, categoria CLIENT_ONLY_VISUAL).

	CAMBIO IMPORTANTE (bug real confirmado con datos): antes solo se
	reportaba en OnZombieDead. Caso real observado: el cliente SI veia el
	zombie vestido antes de morir, pero para cuando OnZombieDead se ejecuto
	en el CLIENTE, el modelo ya habia pasado a cadaver vacio (la
	transicion de zombie->cadaver ya habia ocurrido visualmente) - el
	reporte llegaba sistematicamente demasiado tarde para ese patron de
	perdida en concreto. Ahora se reporta en 3 momentos, cada uno guardando
	solo si aporta MAS prendas que lo ya reportado (ver
	SCLG_CorpseAudit.reportClientVisual, mismo criterio "conservar lo mas
	rico" que ya usa la captura de servidor):
	  1. "preHit" - primer OnWeaponHitCharacter contra ese zombie (el
	     momento mas fiable: el zombie sigue vivo y vestido con seguridad).
	  2. "periodic" - respaldo muestreado de zombies cercanos sin golpe
	     todavia (muertes por fuego, atropello, etc.), limitado en radio y
	     frecuencia para no saturar la red en partidas grandes.
	  3. "death" - reporte final en OnZombieDead, por si los anteriores no
	     llegaron a dispararse (respaldo de respaldo).

	Carga solo en procesos con isClient() true: cliente remoto y cliente del
	host. En SP real isClient() e isServer() son ambos false; alli no hace
	falta telemetria de red porque el proceso autoritativo observa el mismo
	zombie directamente.
]]

require "SCLG_Config"
require "SCLG_Sandbox"
require "SCLG_Snapshot"
require "SCLG_Log"

if not (isClient and isClient()) then
	return
end

if not SCLG_Sandbox.isModEnabled() then
	return
end

--- onlineID -> timestamp (ms) del ultimo reporte "preHit" enviado para ese
--- zombie - REVISADO 2026-08-14 (ver SCLG_Config.CLIENT_HIT_REPORT_MIN_INTERVAL_MS):
--- antes esto era onlineID -> true, un guardian de una sola vez que impedia
--- reenviar aunque el zombie siguiera recibiendo golpes. Si el unico
--- paquete se perdia (red) o llegaba antes de que el outfit estuviera
--- materializado, ese zombie se quedaba sin dato de cliente para siempre -
--- caso real confirmado (onlineID=10410). Ahora se reintenta en cada golpe
--- siempre que haya pasado el intervalo minimo desde el ultimo envio.
local hitReported = {}
--- onlineID -> timestamp, zombies ya reportados por muestreo periodico (evita
--- reenviar el mismo zombie sin vida nueva que aportar en cada barrido).
local periodicReported = {}
--- onlineID -> { count=number, at=number }. El resumen de sistema solo anuncia
--- el primer estado util visto por el cliente o una mejora posterior. Los
--- reintentos iguales siguen disponibles en DETAIL, pero no llenan la consola.
local announcedReports = {}
local lastPeriodicScanAt = 0
local lastTrackingSweepAt = 0

---@return number
local function nowMs()
	if getTimestampMs then
		return getTimestampMs()
	end
	return 0
end

---@param zombie any
---@return number|nil
local function onlineIdOf(zombie)
	local okId, onlineID = pcall(function() return zombie:getOnlineID() end)
	if okId and onlineID and onlineID >= 0 then
		return onlineID
	end
	return nil
end

---@param zombie any
---@param onlineID number
---@param kind string "preHit"|"periodic"|"death"
local function sendReport(zombie, onlineID, kind)
	local types = SCLG_Snapshot.visualTypesOnly(zombie)
	-- Un death vacio tambien es informacion: permite distinguir en servidor
	-- "el cliente vio 0" de "no llego ningun reporte del cliente". Los barridos
	-- periodicos/preHit vacios se omiten para no generar trafico sin valor.
	if #types == 0 and kind ~= "death" then
		return
	end
	local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
	if not player then
		return
	end
	local okOutfit, outfitName = pcall(function() return zombie.getOutfitName and zombie:getOutfitName() end)
	local okPersistent, persistentOutfitID = pcall(function()
		return zombie.getPersistentOutfitID and zombie:getPersistentOutfitID()
	end)
	local okUser, username = pcall(function() return player:getUsername() end)
	local okPos, x, y, z = pcall(function() return zombie:getX(), zombie:getY(), zombie:getZ() end)
	-- Codificado como string "|"-separado: una tabla-array anidada en el
	-- payload de red puede perderse en la transmision (gotcha ya conocido
	-- y documentado en GlobalStorageSiK para este mismo motor de red).
	local ok = pcall(sendClientCommand, player, SCLG_Config.MOD_ID, "clientVisualReport", {
		onlineID = onlineID,
		types = table.concat(types, "|"),
		kind = kind,
		outfitName = (okOutfit and outfitName) and tostring(outfitName) or nil,
		persistentOutfitID = (okPersistent and persistentOutfitID) and tostring(persistentOutfitID) or nil,
		observedBy = (okUser and username) and tostring(username) or nil,
		reportedAtClientMs = nowMs(),
		x = okPos and x or nil,
		y = okPos and y or nil,
		z = okPos and z or nil,
	})
	if not ok then
		SCLG_Log.warn("ClientVisualReport", "sendClientCommand (clientVisualReport) fallo")
	else
		local announced = announcedReports[onlineID]
		local shouldAnnounce = kind ~= "periodic"
			and (not announced or #types > (announced.count or 0))
		if shouldAnnounce then
			SCLG_Log.info("ClientVisual", "report sent | onlineID=" .. tostring(onlineID)
				.. " kind=" .. tostring(kind) .. " visuals=" .. tostring(#types)
				.. " pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
			announcedReports[onlineID] = { count = #types, at = nowMs() }
		end
		if SCLG_Config.enableDebug() then
			SCLG_Log.debug("ClientVisualReport", "sent onlineID=" .. tostring(onlineID)
				.. " kind=" .. tostring(kind) .. " types=" .. tostring(#types)
				.. " pos=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
		end
	end
end

local function sweepTrackingIfDue(now)
	if (now - lastTrackingSweepAt) < SCLG_Config.SWEEP_INTERVAL_MS then return end
	lastTrackingSweepAt = now
	local cutoff = now - SCLG_Config.CLIENT_REPORT_TRACK_TTL_MS
	local staleHit, stalePeriodic, staleAnnounced = {}, {}, {}
	for onlineID, reportedAt in pairs(hitReported) do
		if reportedAt < cutoff then staleHit[#staleHit + 1] = onlineID end
	end
	for onlineID, reportedAt in pairs(periodicReported) do
		if reportedAt < cutoff then stalePeriodic[#stalePeriodic + 1] = onlineID end
	end
	for onlineID, report in pairs(announcedReports) do
		if (report.at or 0) < cutoff then staleAnnounced[#staleAnnounced + 1] = onlineID end
	end
	for i = 1, #staleHit do hitReported[staleHit[i]] = nil end
	for i = 1, #stalePeriodic do periodicReported[stalePeriodic[i]] = nil end
	for i = 1, #staleAnnounced do announcedReports[staleAnnounced[i]] = nil end
	if (#staleHit > 0 or #stalePeriodic > 0) and SCLG_Config.enableDebug() then
		SCLG_Log.debug("ClientVisualReport", "tracking sweep hit=" .. tostring(#staleHit)
			.. " periodic=" .. tostring(#stalePeriodic))
	end
end

---@param attacker any
---@param victim any
local function onWeaponHitCharacter(attacker, victim)
	if not victim then
		return
	end
	local okZombie, isZombie = pcall(function() return instanceof(victim, "IsoZombie") end)
	if not okZombie or not isZombie then
		return
	end
	local onlineID = onlineIdOf(victim)
	if not onlineID then
		return
	end
	local now = nowMs()
	local lastAt = hitReported[onlineID]
	if lastAt and (now - lastAt) < SCLG_Config.CLIENT_HIT_REPORT_MIN_INTERVAL_MS then
		return
	end
	hitReported[onlineID] = now
	sendReport(victim, onlineID, "preHit")
end

--- Muestreo de respaldo: zombies cercanos que TODAVIA no han recibido
--- ningun golpe (por lo tanto nunca dispararon onWeaponHitCharacter) -
--- cubre muertes por fuego, caida, atropello u otras causas sin golpe de
--- arma. Limitado a un radio corto y a un puñado de zombies por barrida
--- para no saturar la red en partidas con muchos jugadores/zombies.
local function periodicScan()
	local now = nowMs()
	sweepTrackingIfDue(now)
	if (now - lastPeriodicScanAt) < SCLG_Sandbox.getClientVisualScanIntervalMs() then
		return
	end
	lastPeriodicScanAt = now

	local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
	if not player then
		return
	end
	local cell = getCell and getCell()
	if not cell or not cell.getZombieList then
		return
	end
	local okList, zombies = pcall(function() return cell:getZombieList() end)
	if not okList or not zombies then
		return
	end
	local okSize, size = pcall(function() return zombies:size() end)
	if not okSize or not size then
		return
	end
	local px, py = player:getX(), player:getY()
	local radius = SCLG_Sandbox.getClientVisualScanRadiusTiles()
	local radius2 = radius * radius
	local budget = SCLG_Sandbox.getClientVisualScanBudgetPerTick()
	for i = 0, size - 1 do
		if budget <= 0 then
			break
		end
		local okGet, zombie = pcall(function() return zombies:get(i) end)
		if okGet and zombie then
			local onlineID = onlineIdOf(zombie)
			if onlineID and not hitReported[onlineID] and not periodicReported[onlineID] then
				local okPos, zx, zy = pcall(function() return zombie:getX(), zombie:getY() end)
				if okPos then
					local dx, dy = zx - px, zy - py
					if (dx * dx + dy * dy) <= radius2 then
						periodicReported[onlineID] = now
						sendReport(zombie, onlineID, "periodic")
						budget = budget - 1
					end
				end
			end
		end
	end
end

---@param zombie any
local function onZombieDead(zombie)
	if not zombie then
		return
	end
	local onlineID = onlineIdOf(zombie)
	if not onlineID then
		return
	end
	hitReported[onlineID] = nil
	periodicReported[onlineID] = nil
	sendReport(zombie, onlineID, "death")
	announcedReports[onlineID] = nil
end

Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)
Events.OnZombieDead.Add(onZombieDead)
Events.OnTick.Add(periodicScan)
