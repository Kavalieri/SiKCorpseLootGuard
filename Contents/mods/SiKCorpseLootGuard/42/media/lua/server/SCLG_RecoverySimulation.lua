--[[
	SiK Corpse Loot Guard - Simulador de restauracion (DRY RUN).

	Evalua que se podria restaurar y por que, pero NO llama a instanceItem,
	AddItem, Remove, send* ni ninguna API que modifique inventarios. Sus
	resultados no son ordenes pendientes: son evidencia para decidir si una
	futura recuperacion conservadora es viable.
]]

require "SCLG_Config"
require "SCLG_Sandbox"
require "SCLG_FileLog"
require "SCLG_Diagnostics"

if not SCLG_Config.isAuthoritative() then return end

SCLG_RecoverySimulation = SCLG_RecoverySimulation or {}

local function typesFromDescriptors(list)
	local result = {}
	for i = 1, #(list or {}) do
		result[#result + 1] = list[i].fullType or "?"
	end
	return result
end

local function joined(list)
	return #(list or {}) > 0 and table.concat(list, ";") or "none"
end

---@param context table
---@param category string
---@param opts table|nil
function SCLG_RecoverySimulation.evaluate(context, category, opts)
	if not SCLG_Sandbox.isRecoverySimulationEnabled() then return end
	opts = opts or {}
	local decision = "WOULD_SKIP"
	local source = "NONE"
	local confidence = "none"
	local reason = "category_not_recoverable"
	local types = {}

	if category == "LOSS_DURING_CORPSE_TRANSFER" then
		types = typesFromDescriptors(context.death and context.death.inventory)
		source = "DEATH_INVENTORY_DESCRIPTOR"
		if opts.correlationConfidence == "exact" and #types > 0 then
			decision, confidence, reason = "WOULD_RESTORE", "authoritative_descriptor", "death_inventory_known_before_transfer"
		else
			decision, confidence, reason = "NEEDS_REVIEW", "correlation_not_exact", "corpse_link_not_exact"
		end
	elseif category == "POST_ANIMATION_LOSS" then
		types = opts.missing or {}
		source = "FIRST_CORPSE_DESCRIPTOR"
		if opts.possibleLegitimateLoot then
			decision, confidence, reason = "WOULD_SKIP", "unsafe", "nearby_player_possible_loot"
		elseif #types > 0 then
			decision, confidence, reason = "WOULD_RESTORE", "same_corpse_descriptor", "items_disappeared_from_same_body"
		end
	elseif category == "LOSS_DURING_ZOMBIE_REBUILD" or category == "CLOTHING_TOTAL_LOSS" or category == "LOSS" then
		if #(opts.missing or {}) > 0 then
			types = opts.missing
			source = "SERVER_PRE_INVENTORY_DESCRIPTOR"
			decision, confidence, reason = "NEEDS_REVIEW", "authoritative_descriptor", "original_object_no_longer_available"
		else
			types = (context.pre and context.pre.itemVisualTypes) or {}
			source = "SERVER_PRE_VISUAL"
			decision, confidence, reason = "NEEDS_REVIEW", "visual_only", "fulltype_known_but_original_item_never_existed"
		end
	elseif category == "CLIENT_ONLY_VISUAL" then
		types = opts.clientTypes or {}
		source = "CLIENT_VISUAL"
		decision, confidence, reason = "WOULD_SKIP", "untrusted", "client_only_evidence"
	elseif category == "CORPSE_VISUAL_ONLY_LOSS" or category == "NAKED_VISUAL_BUT_PRESENT" then
		source = "CORPSE_INVENTORY"
		decision, confidence, reason = "WOULD_SKIP", "not_needed", "inventory_still_present"
	elseif category == "OUTFIT_REPLACED" then
		source = "MIXED_VISUAL"
		decision, confidence, reason = "WOULD_SKIP", "ambiguous", "replacement_is_not_proven_item_loss"
	elseif category == "EMPTY_POST_NO_BASELINE" or category == "EMPTY_CORPSE_SUSPECT" then
		decision, confidence, reason = "WOULD_SKIP", "none", "no_authoritative_item_source"
	elseif category == "AMBIGUOUS_CORPSE_MATCH" or category == "UNMATCHED_CORPSE" then
		decision, confidence, reason = "WOULD_SKIP", "unsafe", "corpse_identity_not_proven"
	end

	local stats = SCLG_Diagnostics.stats()
	if decision == "WOULD_RESTORE" then
		stats.recoveryWouldRestore = stats.recoveryWouldRestore + 1
	elseif decision == "NEEDS_REVIEW" then
		stats.recoveryNeedsReview = stats.recoveryNeedsReview + 1
	else
		stats.recoveryWouldSkip = stats.recoveryWouldSkip + 1
	end

	local line = SCLG_Diagnostics.casePrefix(context, "RECOVERY_SIM", category,
		SCLG_Diagnostics.priorityFor(category))
		.. " decision=" .. decision
		.. " source=" .. source
		.. " confidence=" .. confidence
		.. " reason=" .. reason
		.. " count=" .. tostring(#types)
		.. " items=" .. joined(types)
		.. " mutation=false descriptorLimit=fullType_condition_bodyLocation_only"
	SCLG_FileLog.appendRecovery(line)
	SCLG_Log.info("RecoverySimulation", line)
end
