--[[
	SiK Corpse Loot Guard - Registro visible (consola servidor)
	Autor: SiK
	Descripcion: LOSS/WARN siempre visibles (una entrada por caso). DEBUG
	solo con SCLG_Config.VERBOSE_DEBUG activo, para no inundar la consola.
]]

require "SCLG_Config"
require "SCLG_Sandbox"

SCLG_Log = SCLG_Log or {}

local PREFIX = "[SiKCorpseLootGuard"

---@param level string
---@param area string
---@param message string
local function write(level, area, message)
	if not SCLG_Sandbox.isConsoleLogEnabled() then
		return
	end
	print(PREFIX .. ":" .. tostring(level) .. ":" .. tostring(area) .. "] " .. tostring(message))
end

---@param area string
---@param message string
function SCLG_Log.warn(area, message)
	write("WARN", area, message)
end

---@param area string
---@param message string
function SCLG_Log.info(area, message)
	write("INFO", area, message)
end

---@param area string
---@param message string
function SCLG_Log.debug(area, message)
	if not SCLG_Config.enableDebug() then
		return
	end
	write("DEBUG", area, message)
end
