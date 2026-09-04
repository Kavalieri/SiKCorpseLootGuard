require "SCLG_Config"

SCLGSiK = SCLGSiK or {}
SCLGSiK.API = SCLGSiK.API or {}

local API = SCLGSiK.API
local API_VERSION = "1.0.0-dev1"
local MAX_ITEMS = 256
local MAX_TEXT_BYTES = 512
local MAX_DEPTH = 6

local capabilities = {
	Snapshot = "1.0.0",
	Events = "1.0.0",
	Diagnostics = "1.0.0",
}

local eventIds = {
	["snapshot-captured"] = true,
	["audit-completed"] = true,
	["case-opened"] = true,
}

local listeners = {}
local nextListenerId = 0

local snapshotScalarFields = {
	"onlineID", "outfitName", "persistentOutfitID", "x", "y", "z", "sex",
}

local descriptorFields = {
	"fullType", "itemId", "bodyLocation", "sourceCollection", "sourceSlot",
	"itemClass", "condition", "conditionMax", "favorite", "customName", "uses",
	"usedDelta", "age", "cooked", "burnt", "frozen", "poisonPower",
	"currentAmmoCount", "roundChambered", "containsClip", "dirtyness", "wetness",
	"modDataToken", "modDataComplete", "childCount", "childContentToken",
	"childContentComplete", "descriptorComplete", "recoveryEligible", "transient",
	"ineligibleReason", "resolutionSource", "colorTint", "hue", "baseTexture",
	"textureChoice", "decal", "totalBlood", "holes", "patches", "attachedSlot",
	"lastStandString",
}

local function boundedText(value)
	if value == nil then return nil end
	local text = tostring(value)
	if #text > MAX_TEXT_BYTES then return string.sub(text, 1, MAX_TEXT_BYTES) end
	return text
end

local function scalar(value)
	local kind = type(value)
	if kind == "string" then return boundedText(value) end
	if kind == "number" or kind == "boolean" then return value end
	return nil
end

local function copyFields(source, fieldNames)
	local result = {}
	for index = 1, #fieldNames do
		local name = fieldNames[index]
		local value = scalar(source and source[name])
		if value ~= nil then result[name] = value end
	end
	return result
end

local function copyList(source, mapper)
	local result = {}
	if type(source) ~= "table" then return result end
	local count = math.min(#source, MAX_ITEMS)
	for index = 1, count do result[index] = mapper(source[index]) end
	return result
end

local function copyPortable(value, depth, budget)
	local valueType = type(value)
	if valueType == "string" then return boundedText(value), budget end
	if valueType == "number" or valueType == "boolean" then return value, budget end
	if valueType ~= "table" or depth >= MAX_DEPTH or budget <= 0 then return nil, budget end
	local result = {}
	for key, child in pairs(value) do
		if budget <= 0 then break end
		local keyType = type(key)
		if keyType == "string" or keyType == "number" then
			local copied
			copied, budget = copyPortable(child, depth + 1, budget - 1)
			if copied ~= nil then result[key] = copied end
		end
	end
	return result, budget
end

local function semanticVersion(value)
	if type(value) ~= "string" then return nil end
	local major, minor, patch = string.match(value, "^(%d+)%.(%d+)%.(%d+)")
	if not major then return nil end
	return tonumber(major), tonumber(minor), tonumber(patch)
end

local function versionAtLeast(current, minimum)
	local currentMajor, currentMinor, currentPatch = semanticVersion(current)
	local minimumMajor, minimumMinor, minimumPatch = semanticVersion(minimum)
	if not currentMajor or not minimumMajor then return false end
	if currentMajor ~= minimumMajor then return currentMajor > minimumMajor end
	if currentMinor ~= minimumMinor then return currentMinor > minimumMinor end
	return currentPatch >= minimumPatch
end

API.Capabilities = API.Capabilities or {}

function API.Capabilities.describe()
	local entries = {}
	for name, version in pairs(capabilities) do
		entries[#entries + 1] = { name = name, version = version }
	end
	table.sort(entries, function(left, right) return left.name < right.name end)
	return {
		api = "SCLGSiK.API",
		apiVersion = API_VERSION,
		productVersion = SCLG_Config.MOD_VERSION,
		diagnosticOnly = true,
		capabilities = entries,
	}
end

function API.Capabilities.has(name, minimumVersion)
	local current = capabilities[name]
	if not current then return false, "capability_unavailable" end
	if minimumVersion and not versionAtLeast(current, minimumVersion) then
		return false, "capability_version_too_old"
	end
	return true
end

API.Snapshot = API.Snapshot or {}

function API.Snapshot.normalize(snapshot)
	if type(snapshot) ~= "table" then return nil, "snapshot_required" end
	local result = copyFields(snapshot, snapshotScalarFields)
	result.worn = copyList(snapshot.worn, function(value) return copyFields(value, descriptorFields) end)
	result.attached = copyList(snapshot.attached, function(value) return copyFields(value, descriptorFields) end)
	result.inventory = copyList(snapshot.inventory, function(value) return copyFields(value, descriptorFields) end)
	result.itemVisualTypes = copyList(snapshot.itemVisualTypes, boundedText)
	result.truncated = #(snapshot.worn or {}) > MAX_ITEMS
		or #(snapshot.attached or {}) > MAX_ITEMS
		or #(snapshot.inventory or {}) > MAX_ITEMS
		or #(snapshot.itemVisualTypes or {}) > MAX_ITEMS
	return result
end

local function appendFingerprint(parts, value)
	local text = boundedText(value) or "?"
	parts[#parts + 1] = tostring(#text) .. ":" .. text
end

function API.Snapshot.fingerprint(snapshot)
	local normalized, err = API.Snapshot.normalize(snapshot)
	if not normalized then return nil, err end
	local parts = {}
	for index = 1, #snapshotScalarFields do
		appendFingerprint(parts, normalized[snapshotScalarFields[index]])
	end
	for _, collectionName in ipairs({ "worn", "attached", "inventory" }) do
		local rows = {}
		for index = 1, #normalized[collectionName] do
			local descriptor = normalized[collectionName][index]
			rows[#rows + 1] = tostring(descriptor.itemId or "?") .. "|"
				.. tostring(descriptor.fullType or "?") .. "|"
				.. tostring(descriptor.sourceSlot or descriptor.bodyLocation or "?")
		end
		table.sort(rows)
		appendFingerprint(parts, collectionName)
		appendFingerprint(parts, table.concat(rows, "\30"))
	end
	local text = table.concat(parts, "\31")
	local hash = 5381
	for index = 1, #text do hash = (hash * 33 + string.byte(text, index)) % 4294967296 end
	return string.format("%08x", hash)
end

API.Events = API.Events or {}

function API.Events.subscribe(eventId, handler)
	if not eventIds[eventId] then return nil, "unknown_event" end
	if type(handler) ~= "function" then return nil, "handler_required" end
	nextListenerId = nextListenerId + 1
	local token = {
		id = nextListenerId,
		eventId = eventId,
	}
	listeners[token.id] = { token = token, handler = handler }
	function token:dispose()
		if self.disposed then return false end
		self.disposed = true
		listeners[self.id] = nil
		return true
	end
	return token
end

function API.Events.unsubscribe(token)
	if type(token) ~= "table" or type(token.dispose) ~= "function" then
		return nil, "invalid_subscription"
	end
	return token:dispose()
end

API.Diagnostics = API.Diagnostics or {}

function API.Diagnostics.session()
	local authoritative = false
	if type(SCLG_Config.isAuthoritative) == "function" then
		local ok, result = pcall(SCLG_Config.isAuthoritative)
		authoritative = ok and result == true
	end
	return {
		product = SCLG_Config.MOD_ID,
		productVersion = SCLG_Config.MOD_VERSION,
		apiVersion = API_VERSION,
		authoritative = authoritative,
		diagnosticOnly = true,
	}
end

function API.Diagnostics.copyPayload(payload)
	if type(payload) ~= "table" then return nil, "payload_required" end
	local copy = copyPortable(payload, 0, MAX_ITEMS)
	return copy
end

-- Product-owned emitter. It is intentionally outside SCLGSiK.API: consumers
-- can observe diagnostic events but cannot impersonate the authoritative mod.
function SCLGSiK.emitDiagnosticEvent(eventId, payload)
	if not eventIds[eventId] then return nil, "unknown_event" end
	local copied, err = API.Diagnostics.copyPayload(payload or {})
	if not copied then return nil, err end
	local snapshot = {}
	for _, listener in pairs(listeners) do
		if listener.token.eventId == eventId then snapshot[#snapshot + 1] = listener end
	end
	table.sort(snapshot, function(left, right) return left.token.id < right.token.id end)
	for index = 1, #snapshot do
		local listener = snapshot[index]
		if not listener.token.disposed then pcall(listener.handler, copied, eventId) end
	end
	return true
end

return API
