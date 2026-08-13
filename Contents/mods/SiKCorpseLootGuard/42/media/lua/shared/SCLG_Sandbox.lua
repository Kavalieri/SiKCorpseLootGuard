--[[
	SiK Corpse Loot Guard - Sandbox
	Autor: SiK
	Descripcion: Getters para las opciones de sandbox (ver
	media/sandbox-options.txt). Todos los interruptores de debug/log/spawn
	pasan por aqui en vez de constantes fijas en SCLG_Config.lua, para poder
	activarlos/desactivarlos por partida sin tocar codigo.
]]

SCLG_Sandbox = SCLG_Sandbox or {}

---@return table|nil
local function vars()
	return SandboxVars and SandboxVars.SiKCorpseLootGuard or nil
end

--- Interruptor maestro: si esta desactivado, ningun otro modulo del mod
--- debe ejecutar logica (ver guardas al inicio de cada fichero server/client).
---@return boolean
function SCLG_Sandbox.isModEnabled()
	local v = vars()
	return v == nil or v.EnableMod ~= false
end

---@return boolean
function SCLG_Sandbox.isSpawnMenuEnabled()
	local v = vars()
	return v == nil or v.EnableSpawnMenu ~= false
end

---@return boolean
function SCLG_Sandbox.isFileLogEnabled()
	local v = vars()
	return v == nil or v.EnableFileLog ~= false
end

---@return boolean
function SCLG_Sandbox.isConsoleLogEnabled()
	local v = vars()
	return v == nil or v.EnableConsoleLog ~= false
end

---@return boolean
function SCLG_Sandbox.isPostAnimationRecheckEnabled()
	local v = vars()
	return v == nil or v.EnablePostAnimationRecheck ~= false
end

---@return number
function SCLG_Sandbox.getPostAnimationRecheckDelaySeconds()
	local v = vars()
	return (v and v.PostAnimationRecheckDelaySeconds) or 15
end

---@return boolean
function SCLG_Sandbox.isAuthenticZProbeEnabled()
	local v = vars()
	return v == nil or v.EnableAuthenticZProbe ~= false
end

---@return boolean
function SCLG_Sandbox.isNearbyPlayerCheckEnabled()
	local v = vars()
	return v == nil or v.EnableNearbyPlayerCheck ~= false
end

---@return boolean
function SCLG_Sandbox.isCapacityDiagnosticEnabled()
	local v = vars()
	return v == nil or v.EnableCapacityDiagnostic ~= false
end

---@return boolean
function SCLG_Sandbox.isDeathContextCaptureEnabled()
	local v = vars()
	return v == nil or v.EnableDeathContextCapture ~= false
end

---@return boolean
function SCLG_Sandbox.isFallbackCaptureEnabled()
	local v = vars()
	return v == nil or v.EnableFallbackCapture ~= false
end

---@return number
function SCLG_Sandbox.getZombieUpdateSampleRate()
	local v = vars()
	local rate = v and v.ZombieUpdateSampleRate
	return (rate and rate > 0) and rate or 40
end

---@return number
function SCLG_Sandbox.getSummaryIntervalMs()
	local v = vars()
	local minutes = (v and v.SummaryIntervalMinutes) or 5
	return minutes * 60 * 1000
end

---@return boolean
function SCLG_Sandbox.isVerboseDebug()
	local v = vars()
	return v and v.VerboseDebug == true
end

--- Cada cuanto (ms) el cliente muestrea zombies cercanos sin golpe todavia
--- (respaldo para muertes sin OnWeaponHitCharacter: fuego, atropello...).
---@return number
function SCLG_Sandbox.getClientVisualScanIntervalMs()
	local v = vars()
	local seconds = (v and v.ClientVisualScanIntervalSeconds) or 5
	return seconds * 1000
end

--- Radio (en tiles) alrededor del jugador para el muestreo periodico de
--- cliente - limitado a proposito para no procesar zombies lejanos.
---@return number
function SCLG_Sandbox.getClientVisualScanRadiusTiles()
	local v = vars()
	local radius = v and v.ClientVisualScanRadiusTiles
	return (radius and radius > 0) and radius or 15
end

--- Maximo de zombies nuevos reportados por barrida de muestreo periodico -
--- evita saturar la red en partidas con muchos zombies cercanos a la vez.
---@return number
function SCLG_Sandbox.getClientVisualScanBudgetPerTick()
	local v = vars()
	local budget = v and v.ClientVisualScanBudgetPerTick
	return (budget and budget > 0) and budget or 3
end
