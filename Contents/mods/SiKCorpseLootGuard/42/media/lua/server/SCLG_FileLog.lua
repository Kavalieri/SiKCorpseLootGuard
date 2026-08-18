--[[
	SiK Corpse Loot Guard - Registro persistente en fichero
	Autor: SiK
	Descripcion: Ademas de la consola, guarda un historial en disco para
	poder revisarlo mas tarde sin tener que estar pendiente en directo.
	Ficheros separados (API real: getFileWriter(nombre,
	relativeToModData, append), confirmada en scripts vanilla, ej.
	forageSystem.lua):
	  - SiKCorpseLootGuard_losses.log: se abre en modo "append" y se le
	    añade una linea por cada LOSS detectado, nunca se borra sola.
	  - SiKCorpseLootGuard_summary.log: se SOBRESCRIBE cada vez con el
	    resumen mas reciente, para ver el estado actual de un vistazo sin
	    tener que leer todo el historico.
	  - SiKCorpseLootGuard_cases.log: ciclo correlacionado de todos los casos
	    (SESSION/DEATH/CORPSE/RECHECK), incluido el resultado sin anomalías.
	  - SiKCorpseLootGuard_recovery_simulation.log: decisiones DRY RUN; nunca
	    contiene acciones pendientes ni implica que se haya mutado un objeto.
	Se abre/cierra el escritor en cada llamada (los LOSS son poco
	frecuentes) en vez de mantener un handle abierto todo el rato.
]]

require "SCLG_Sandbox"

SCLG_FileLog = SCLG_FileLog or {}

local LOSSES_FILE = "SiKCorpseLootGuard_losses.log"
local SUMMARY_FILE = "SiKCorpseLootGuard_summary.log"
local SPAWNS_FILE = "SiKCorpseLootGuard_spawns.log"
local CASES_FILE = "SiKCorpseLootGuard_cases.log"
local RECOVERY_FILE = "SiKCorpseLootGuard_recovery_simulation.log"

---@return string
local function timestamp()
	local ok, s = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
	if ok and s then
		return s
	end
	return "?"
end

---@param fileName string
---@param line string
local function appendLine(fileName, line)
	if not SCLG_Sandbox.isFileLogEnabled() then return end
	local ok, writer = pcall(getFileWriter, fileName, true, true)
	if not ok or not writer then return end
	pcall(function() writer:write("[" .. timestamp() .. "] " .. tostring(line) .. "\r\n") end)
	pcall(function() writer:close() end)
end

--- Añade una linea al historial de perdidas (no se borra ni se sobrescribe).
---@param line string
function SCLG_FileLog.appendLoss(line)
	appendLine(LOSSES_FILE, line)
end

---@param line string
function SCLG_FileLog.appendCase(line)
	appendLine(CASES_FILE, line)
end

---@param line string
function SCLG_FileLog.appendRecovery(line)
	appendLine(RECOVERY_FILE, line)
end

--- Sobrescribe el fichero de resumen con el estado actual (siempre el mismo
--- fichero, siempre el ultimo dato: para consultar sin bucear en el historico).
---@param line string
function SCLG_FileLog.writeSummary(line)
	if not SCLG_Sandbox.isFileLogEnabled() then
		return
	end
	local ok, writer = pcall(getFileWriter, SUMMARY_FILE, true, false)
	if not ok or not writer then
		return
	end
	pcall(function()
		writer:write("[" .. timestamp() .. "] " .. line .. "\r\n")
	end)
	pcall(function() writer:close() end)
end

--- Añade una linea al historial de spawns de prueba solicitados (nunca se
--- borra ni se sobrescribe), para poder comparar despues cuantos zombies
--- pedidos llegaron realmente a morir a la vista de alguien.
---@param line string
function SCLG_FileLog.appendSpawn(line)
	if not SCLG_Sandbox.isFileLogEnabled() then
		return
	end
	local ok, writer = pcall(getFileWriter, SPAWNS_FILE, true, true)
	if not ok or not writer then
		return
	end
	pcall(function()
		writer:write("[" .. timestamp() .. "] " .. line .. "\r\n")
	end)
	pcall(function() writer:close() end)
end
