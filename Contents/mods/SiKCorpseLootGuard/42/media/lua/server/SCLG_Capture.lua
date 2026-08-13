--[[
	SiK Corpse Loot Guard - Cache de instantaneas previas a la muerte
	Autor: SiK
	Descripcion: Guarda el estado de ropa/inventario del zombie ANTES de
	que DoZombieInventory() lo reconstruya, para poder comparar en
	OnZombieDead. Solo servidor (y SP real, que ejecuta la logica de
	servidor en el mismo proceso).

	Riesgos que esto evita explicitamente (ver spec del mod):
	  - No guarda la referencia Java del zombie mas alla de lo necesario:
	    solo se queda con los datos ya extraidos (tabla plana), nunca el
	    objeto zombie en si.
	  - Limpieza por timeout (ENTRY_TTL_MS) para zombies que nunca mueren
	    (se alejan, se descarga el chunk) - evita crecimiento indefinido.
	  - Recaptura de fallback limitada (MIN_RECAPTURE_INTERVAL_MS) para no
	    reescribir el mismo zombie en cada muestreo de OnZombieUpdate.
]]

require "SCLG_Config"
require "SCLG_Log"
require "SCLG_Snapshot"

-- Ver nota identica en SCLG_Server.lua: media/lua/server/ NO filtra la
-- carga en B42, hace falta esta guarda explicita. isServer() (no
-- isClient()) para no romper singleplayer real.
if not (isServer and isServer()) then
	return
end

SCLG_Capture = SCLG_Capture or {}

--- key -> snapshot (tabla plana de SCLG_Snapshot.build + capturedAt/reason)
local cache = {}
local lastSweepAt = 0

---@return number
local function nowMs()
	if getTimestampMs then
		return getTimestampMs()
	end
	return 0
end

--- Clave de cache para un zombie. Preferimos el online ID (estable durante
--- toda la vida del zombie en MP); si no es valido (ej. muy pronto tras
--- spawn, o en algun caso SP), usamos identidad de objeto Kahlua + coords
--- redondeadas como respaldo temporal.
---@param zombie any
---@return string
local function keyForZombie(zombie)
	local okId, id = pcall(function() return zombie:getOnlineID() end)
	if okId and id and id >= 0 then
		return "oid:" .. tostring(id)
	end
	local x, y, z = 0, 0, 0
	pcall(function()
		x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
	end)
	return "obj:" .. tostring(zombie) .. ":" .. math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z)
end

--- Puntuacion de "riqueza" de una instantanea: cuanta informacion real
--- contiene. Usada para decidir si una captura nueva debe REEMPLAZAR a una
--- existente o no.
---@param snap table
---@return number
local function snapshotScore(snap)
	return #(snap.itemVisualTypes or {}) + #(snap.worn or {}) + #(snap.inventory or {}) + #(snap.attached or {})
end

--- Captura (o recaptura) el estado actual de un zombie vivo.
--- IMPORTANTE (confirmado con datos reales de pruebas): la captura por
--- golpe (OnWeaponHitCharacter, "hit") se dispara MUCHAS veces durante el
--- combate segun el zombie recibe golpes sucesivos, y cada captura
--- SOBRESCRIBIA sin mas a la anterior. Si una captura tardia (ej. justo
--- antes de morir, en pleno colapso de animacion) devolvia menos datos que
--- una anterior mas rica, se perdia la informacion buena. Ahora se compara
--- una puntuacion de "riqueza" (snapshotScore) y solo se reemplaza la
--- entrada en cache si la nueva captura es IGUAL O MAS rica que la
--- existente - nunca se sustituye una captura buena por una peor.
---@param zombie any
---@param reason string "hit" | "fallback"
function SCLG_Capture.capture(zombie, reason)
	if not zombie then
		return
	end
	local key = keyForZombie(zombie)
	local now = nowMs()

	if reason == "fallback" then
		local existing = cache[key]
		-- Si la captura existente esta completamente vacia (score 0),
		-- NO aplicamos el throttle - seguimos intentando en cada muestreo
		-- hasta conseguir una captura real. Visto en pruebas reales: un
		-- zombie recien aparecido puede tardar en tener su outfit
		-- materializado/sincronizado, y si nos quedamos con la primera
		-- captura vacia y esperamos el intervalo completo, podemos perder
		-- la ventana entera antes de que muera.
		if existing and snapshotScore(existing) > 0
			and (now - (existing.capturedAt or 0)) < SCLG_Config.MIN_RECAPTURE_INTERVAL_MS then
			return
		end
	end

	local snap = SCLG_Snapshot.build(zombie)
	snap.capturedAt = now
	snap.reason = reason

	local existing = cache[key]
	if existing then
		local existingScore = snapshotScore(existing)
		local newScore = snapshotScore(snap)
		if newScore < existingScore then
			SCLG_Log.debug("Capture", "captura mas pobre descartada, se conserva la anterior | key=" .. key
				.. " existingScore=" .. existingScore .. " newScore=" .. newScore)
			return
		end
	end

	cache[key] = snap

	SCLG_Log.debug("Capture", "captured key=" .. key .. " reason=" .. tostring(reason)
		.. " worn=" .. tostring(#snap.worn) .. " inv=" .. tostring(#snap.inventory)
		.. " attached=" .. tostring(#snap.attached) .. " visuals=" .. tostring(#snap.itemVisualTypes))
end

--- Sonda de hipotesis contexto de muerte (ver SCLG_Sandbox.isDeathContextCaptureEnabled):
--- guarda que arma llevaba el atacante en el ultimo golpe registrado antes
--- de morir el zombie, para poder correlacionar despues (en los logs de
--- LOSS) si un tipo de arma o ataque concreto aparece mas asociado a la
--- perdida de loot que otros. Se guarda SIN reemplazar el resto de la
--- captura (independiente de capture()), asi que no interfiere con la
--- logica de "no sustituir una captura buena por una peor".
---@param zombie any
---@param weaponType string|nil
function SCLG_Capture.recordDeathContextWeapon(zombie, weaponType)
	if not zombie or not weaponType then
		return
	end
	local key = keyForZombie(zombie)
	local existing = cache[key]
	if existing then
		existing.lastHitWeapon = weaponType
	end
end

--- Recupera y consume (borra) la instantanea previa de un zombie, si existe.
---@param zombie any
---@return table|nil snapshot
---@return string key
function SCLG_Capture.take(zombie)
	local key = keyForZombie(zombie)
	local snap = cache[key]
	cache[key] = nil
	return snap, key
end

---@return number
function SCLG_Capture.cacheSize()
	local n = 0
	for _ in pairs(cache) do
		n = n + 1
	end
	return n
end

--- Barrida periodica de entradas huerfanas (throttled por SWEEP_INTERVAL_MS,
--- seguro llamarla desde cualquier sitio con frecuencia).
function SCLG_Capture.sweepIfDue()
	local now = nowMs()
	if (now - lastSweepAt) < SCLG_Config.SWEEP_INTERVAL_MS then
		return
	end
	lastSweepAt = now
	local removed = 0
	for key, snap in pairs(cache) do
		if (now - (snap.capturedAt or 0)) > SCLG_Config.ENTRY_TTL_MS then
			cache[key] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		SCLG_Log.debug("Capture", "sweep removed=" .. removed .. " remaining=" .. SCLG_Capture.cacheSize())
	end
end
