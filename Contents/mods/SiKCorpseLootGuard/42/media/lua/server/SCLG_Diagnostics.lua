--[[
	SiK Corpse Loot Guard - Contexto de sesion, casos y resumen unificado.

	Este modulo SOLO registra datos. No conserva objetos Java y no crea,
	borra, mueve ni restaura InventoryItem. Centraliza los contadores para
	que las fases DEATH, CORPSE y RECHECK aparezcan en el mismo resumen.
]]

require "SCLG_Config"
require "SCLG_Log"
require "SCLG_FileLog"
require "SCLG_Sandbox"

if not SCLG_Config.isAuthoritative() then return end

SCLG_Diagnostics = SCLG_Diagnostics or {}

local startedAtMs = getTimestampMs and getTimestampMs() or 0
local caseSequence = 0
local gaugeProvider = nil
local casePriorities = {}
local categoryCounts = {}

local function wallClockToken()
	local ok, value = pcall(function() return os.date("%Y%m%dT%H%M%S") end)
	if ok and value then return tostring(value) end
	return "unknown"
end

local sessionId = wallClockToken() .. "-" .. SCLG_Log.processTag() .. "-" .. tostring(startedAtMs)

local stats = {
	deathsChecked = 0,
	snapshotsHit = 0,
	snapshotsMissed = 0,
	lossesDetected = 0,
	itemsMissing = 0,
	nakedVisualButInventoryPresent = 0,
	visualDeltasDetected = 0,
	emptyCorpseSuspect = 0,
	authenticZInstanceFailures = 0,
	corpseAudits = 0,
	correlationExact = 0,
	correlationProximity = 0,
	correlationAmbiguous = 0,
	correlationUnmatched = 0,
	postAnimationLosses = 0,
	recoveryWouldRestore = 0,
	recoveryNeedsReview = 0,
	recoveryWouldSkip = 0,
	signalCases = 0,
	priority1 = 0,
	priority2 = 0,
	priority3 = 0,
	priority4 = 0,
}

local PRIORITY = {
	LOSS_DURING_CORPSE_TRANSFER = 1,
	LOSS_DURING_ZOMBIE_REBUILD = 2,
	POST_ANIMATION_LOSS = 2,
	CLOTHING_TOTAL_LOSS = 2,
	LOSS = 2,
	CLIENT_ONLY_VISUAL = 2,
	AMBIGUOUS_CORPSE_MATCH = 2,
	EMPTY_POST_NO_BASELINE = 3,
	EMPTY_CORPSE_SUSPECT = 3,
	CORPSE_VISUAL_ONLY_LOSS = 3,
	NAKED_VISUAL_BUT_PRESENT = 3,
	AUTHENTICZ_INSTANCE_FAIL = 3,
	OUTFIT_REPLACED = 4,
	VISUAL_DELTA = 4,
	CORPSE_CONTAINER_NEAR_CAPACITY = 4,
	POST_ANIMATION_DELTA_NEARBY_PLAYER = 4,
	UNMATCHED_CORPSE = 4,
	PENDING_CORPSE_EXPIRED = 4,
}

local function nowMs()
	return getTimestampMs and getTimestampMs() or 0
end

local function safeToken(value)
	if value == nil then return "?" end
	local text = tostring(value)
	text = text:gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("%s", "_")
	if #text > 512 then text = text:sub(1, 512) .. "..." end
	return text
end

local function safeDetails(value)
	if value == nil then return nil end
	return tostring(value):gsub("\r\n", "\\n"):gsub("[\r\n]", "\\n")
end

local function caseIdOf(context)
	if not context then return nil end
	return context.caseId or (context.pre and context.pre.caseId) or nil
end

local function sessionIdOf(context)
	if not context then return sessionId end
	return context.sessionId or (context.pre and context.pre.sessionId) or sessionId
end

local function identityOf(context)
	context = context or {}
	local pre = context.pre or context
	local death = context.death or {}
	local onlineID = context.onlineID
	if onlineID == nil then onlineID = death.onlineID end
	if onlineID == nil then onlineID = pre.onlineID end
	local persistentOutfitID = death.persistentOutfitID or pre.persistentOutfitID
	local x = context.x
	local y = context.y
	local z = context.z
	if x == nil then x = death.x or pre.x end
	if y == nil then y = death.y or pre.y end
	if z == nil then z = death.z or pre.z end
	return onlineID, persistentOutfitID, x, y, z
end

---@return table
function SCLG_Diagnostics.stats()
	return stats
end

---@return string
function SCLG_Diagnostics.sessionId()
	return sessionId
end

---@return string
function SCLG_Diagnostics.newCaseId()
	caseSequence = caseSequence + 1
	return sessionId .. "-" .. string.format("%06d", caseSequence)
end

---@param snapshot table
---@param existing table|nil
function SCLG_Diagnostics.attachCase(snapshot, existing)
	if not snapshot then return end
	snapshot.sessionId = (existing and existing.sessionId) or sessionId
	snapshot.caseId = (existing and existing.caseId) or SCLG_Diagnostics.newCaseId()
	snapshot.firstCapturedAt = (existing and existing.firstCapturedAt) or snapshot.capturedAt or nowMs()
	snapshot.captureCount = ((existing and existing.captureCount) or 0) + 1
end

---@param provider function
function SCLG_Diagnostics.setGaugeProvider(provider)
	gaugeProvider = provider
end

---@param category string
---@return number
function SCLG_Diagnostics.priorityFor(category)
	return PRIORITY[category] or 4
end

---@param context table|nil
---@param phase string
---@param category string
---@param priority number|nil
---@return string
function SCLG_Diagnostics.casePrefix(context, phase, category, priority)
	local onlineID, persistentOutfitID, x, y, z = identityOf(context)
	return string.format(
		"schema=2 session=%s case=%s priority=P%d phase=%s category=%s origin=%s eventMs=%s onlineID=%s persistentOutfitID=%s pos=%s,%s,%s",
		safeToken(sessionIdOf(context)), safeToken(caseIdOf(context)), priority or SCLG_Diagnostics.priorityFor(category),
		safeToken(phase), safeToken(category), SCLG_Log.processTag(), tostring(nowMs()),
		safeToken(onlineID), safeToken(persistentOutfitID), safeToken(x), safeToken(y), safeToken(z))
end

---@param context table|nil
---@param phase string
---@param category string
---@param details string|nil
function SCLG_Diagnostics.recordStage(context, phase, category, details)
	local line = SCLG_Diagnostics.casePrefix(context, phase, category, 4)
	details = safeDetails(details)
	if details and details ~= "" then line = line .. " " .. details end
	SCLG_FileLog.appendCase(line)
end

---@param context table|nil
---@param phase string
---@param category string
---@param details string|nil
---@param persistLoss boolean|nil
function SCLG_Diagnostics.recordSignal(context, phase, category, details, persistLoss)
	local priority = SCLG_Diagnostics.priorityFor(category)
	local caseId = caseIdOf(context) or SCLG_Diagnostics.newCaseId()
	if type(context) == "table" and not caseIdOf(context) then
		context.sessionId = context.sessionId or sessionId
		context.caseId = caseId
	end
	categoryCounts[category] = (categoryCounts[category] or 0) + 1
	local oldPriority = casePriorities[caseId]
	if not oldPriority then
		casePriorities[caseId] = priority
		stats.signalCases = stats.signalCases + 1
		stats["priority" .. tostring(priority)] = (stats["priority" .. tostring(priority)] or 0) + 1
	elseif priority < oldPriority then
		stats["priority" .. tostring(oldPriority)] = math.max(0, (stats["priority" .. tostring(oldPriority)] or 0) - 1)
		stats["priority" .. tostring(priority)] = (stats["priority" .. tostring(priority)] or 0) + 1
		casePriorities[caseId] = priority
	end
	local line = SCLG_Diagnostics.casePrefix(context, phase, category, priority)
	details = safeDetails(details)
	if details and details ~= "" then line = line .. " " .. details end
	SCLG_FileLog.appendCase(line)
	if persistLoss ~= false then SCLG_FileLog.appendLoss(line) end
end

local function categoriesToken()
	local names = {}
	for category in pairs(categoryCounts) do names[#names + 1] = category end
	table.sort(names)
	local values = {}
	for i = 1, #names do
		local category = names[i]
		values[#values + 1] = category .. ":" .. tostring(categoryCounts[category])
	end
	return #values > 0 and table.concat(values, ",") or "none"
end

---@return string
function SCLG_Diagnostics.summaryLine()
	local gauges = {}
	if type(gaugeProvider) == "function" then
		local ok, result = pcall(gaugeProvider)
		if ok and type(result) == "table" then gauges = result end
	end
	return string.format(
		"schema=2 session=%s uptimeMs=%d snapshots=%d/%d deathsChecked=%d primaryLosses=%d primaryItemsMissing=%d corpseAudits=%d signalCases=%d priorities=P1:%d,P2:%d,P3:%d,P4:%d correlations=exact:%d,proximity:%d,ambiguous:%d,unmatched:%d postAnimationLosses=%d recovery=restore:%d,review:%d,skip:%d categories=%s cacheSize=%s pending=%s clientReports=%s rechecks=%s",
		sessionId, math.max(0, nowMs() - startedAtMs), stats.snapshotsHit,
		stats.snapshotsHit + stats.snapshotsMissed, stats.deathsChecked, stats.lossesDetected,
		stats.itemsMissing, stats.corpseAudits, stats.signalCases,
		stats.priority1, stats.priority2, stats.priority3, stats.priority4,
		stats.correlationExact, stats.correlationProximity, stats.correlationAmbiguous, stats.correlationUnmatched,
		stats.postAnimationLosses, stats.recoveryWouldRestore, stats.recoveryNeedsReview, stats.recoveryWouldSkip,
		categoriesToken(), safeToken(gauges.cacheSize), safeToken(gauges.pending),
		safeToken(gauges.clientReports), safeToken(gauges.rechecks))
end

function SCLG_Diagnostics.writeSummaryNow()
	local line = SCLG_Diagnostics.summaryLine()
	SCLG_Log.info("Summary", line)
	SCLG_FileLog.writeSummary(line)
end

if SCLG_Sandbox.isModEnabled() then
	SCLG_FileLog.appendCase("schema=2 session=" .. sessionId .. " phase=SESSION category=START origin="
		.. SCLG_Log.processTag() .. " eventMs=" .. tostring(startedAtMs) .. " modVersion=" .. tostring(SCLG_Config.MOD_VERSION))
end
