package.path = "Contents/mods/SiKCorpseLootGuard/42/media/lua/shared/?.lua;" .. package.path

function isClient() return false end
function isServer() return false end

require "SCLGSiK_API"

assert(SCLGSiK and SCLGSiK.API)
assert(SCLG == nil or SCLG.API == nil)
assert(package.loaded["SCLG_API"] == nil)

local capabilities = SCLGSiK.API.Capabilities.describe()
assert(capabilities.api == "SCLGSiK.API")
assert(capabilities.diagnosticOnly == true)
assert(SCLGSiK.API.Capabilities.has("Snapshot", "1.0.0"))
assert(not SCLGSiK.API.Capabilities.has("Repair"))

local source = {
	onlineID = 42,
	outfitName = "Test",
	worn = {
		{ fullType = "Base.Shirt", itemId = 10, condition = 8, private = {} },
	},
	attached = {},
	inventory = {},
	itemVisualTypes = { "Base.Shirt" },
	privateCache = { forbidden = true },
}

local normalized = assert(SCLGSiK.API.Snapshot.normalize(source))
assert(normalized.worn[1].fullType == "Base.Shirt")
assert(normalized.worn[1].private == nil)
assert(normalized.privateCache == nil)
local first = assert(SCLGSiK.API.Snapshot.fingerprint(source))
local second = assert(SCLGSiK.API.Snapshot.fingerprint(source))
assert(first == second)

local calls = 0
local token = assert(SCLGSiK.API.Events.subscribe("audit-completed", function(payload, eventId)
	calls = calls + 1
	assert(eventId == "audit-completed")
	assert(payload.caseId == "case-1")
end))
assert(SCLGSiK.emitDiagnosticEvent("audit-completed", { caseId = "case-1" }))
assert(calls == 1)
assert(token:dispose())
assert(SCLGSiK.emitDiagnosticEvent("audit-completed", { caseId = "case-2" }))
assert(calls == 1)

print("sclgsik_api_contract: OK")
