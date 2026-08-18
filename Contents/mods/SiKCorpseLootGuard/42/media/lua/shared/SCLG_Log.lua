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
local detailNoticeShown = false

local function elapsedTag()
	if not getTimestampMs then return "?" end
	return string.format("%.1fs", getTimestampMs() / 1000)
end

---@return string "SRV"|"HOST"|"CLI"|"SP"
function SCLG_Log.processTag()
	local server = isServer and isServer() or false
	local client = isClient and isClient() or false
	if server and not client then return "SRV" end
	if server and client then return "HOST" end
	if client then return "CLI" end
	return "SP"
end

---@param sink function|nil
function SCLG_Log.setRelaySink(sink)
	SCLG_Log._relaySink = sink
end

---@param payload string|nil
function SCLG_Log.printRemotePayload(payload)
	if type(payload) ~= "string" or payload == "" then return end
	for line in string.gmatch(payload .. "\n", "([^\n]*)\n") do
		if line ~= "" then print(line) end
	end
end

---@param level string
---@param area string
---@param message string
local function write(level, area, message)
	if not SCLG_Sandbox.isConsoleLogEnabled() then
		return
	end
	local origin = SCLG_Log.processTag()
	local line = "[" .. elapsedTag() .. "][" .. origin .. "] " .. PREFIX .. ":" .. tostring(level) .. ":" .. tostring(area) .. "] " .. tostring(message)
	print(line)
	if origin == "SRV" and type(SCLG_Log._relaySink) == "function" then
		pcall(SCLG_Log._relaySink, line)
	end
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
	if not detailNoticeShown then
		detailNoticeShown = true
		write("SYSTEM", area, "DETAIL sublog enabled; high-volume output may fill console.txt; use only for targeted diagnostics")
	end
	write("DETAIL", area, message)
end
