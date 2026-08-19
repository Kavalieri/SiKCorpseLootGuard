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
require "SCLG_Snapshot"

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

local function descriptorAssessment(descriptors)
	local complete, eligible, transient, ineligible = 0, 0, 0, {}
	for i = 1, #(descriptors or {}) do
		local desc = descriptors[i]
		if desc.descriptorComplete then complete = complete + 1 end
		if desc.recoveryEligible then
			eligible = eligible + 1
		else
			if desc.transient then transient = transient + 1 end
			ineligible[#ineligible + 1] = tostring(desc.ineligibleReason or "descriptor_incomplete")
		end
	end
	return complete, eligible, transient, ineligible
end

local function descriptorSummaries(descriptors)
	local result = {}
	for i = 1, #(descriptors or {}) do
		result[#result + 1] = SCLG_Snapshot.descriptorSummary(descriptors[i])
	end
	return #result > 0 and table.concat(result, ";;") or "none"
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
	local descriptors = {}

	if category == "LOSS_DURING_CORPSE_TRANSFER" then
		descriptors = (context.death and context.death.inventory) or {}
		types = typesFromDescriptors(descriptors)
		source = "DEATH_INVENTORY_DESCRIPTOR"
		local _, eligible = descriptorAssessment(descriptors)
		if opts.correlationConfidence == "exact" and #types > 0 and eligible == #descriptors then
			decision, confidence, reason = "WOULD_RESTORE", "authoritative_descriptor", "death_inventory_known_before_transfer"
		elseif opts.correlationConfidence == "exact" and #types > 0 then
			decision, confidence, reason = "NEEDS_REVIEW", "descriptor_incomplete", "item_state_not_faithfully_reconstructable"
		else
			decision, confidence, reason = "NEEDS_REVIEW", "correlation_not_exact", "corpse_link_not_exact"
		end
	elseif category == "POST_ANIMATION_LOSS" then
		descriptors = opts.missingDescriptors or {}
		types = #descriptors > 0 and typesFromDescriptors(descriptors) or (opts.missing or {})
		source = "FIRST_CORPSE_DESCRIPTOR"
		local _, eligible, transient = descriptorAssessment(descriptors)
		if opts.possibleLegitimateLoot then
			decision, confidence, reason = "WOULD_SKIP", "unsafe", "nearby_player_possible_loot"
		elseif #descriptors == 0 and #types > 0 then
			decision, confidence, reason = "NEEDS_REVIEW", "type_only", "missing_descriptor_identity"
		elseif #types > 0 and eligible == #descriptors then
			decision, confidence, reason = "WOULD_RESTORE", "same_corpse_descriptor", "items_disappeared_from_same_body"
		elseif #types > 0 and eligible > 0 then
			decision, confidence, reason = "NEEDS_REVIEW", "mixed_descriptor_quality", "some_items_not_faithfully_reconstructable"
		elseif #types > 0 and transient == #descriptors then
			decision, confidence, reason = "WOULD_SKIP", "ineligible", "transient_or_unsupported_item_state"
		elseif #types > 0 then
			decision, confidence, reason = "NEEDS_REVIEW", "descriptor_incomplete", "item_state_not_faithfully_reconstructable"
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
		local evidence = opts.clientEvidence or {}
		descriptors = evidence.descriptors or {}
		types = #descriptors > 0 and typesFromDescriptors(descriptors) or (evidence.types or opts.clientTypes or {})
		source = "CLIENT_MULTI_SAMPLE_DESCRIPTOR"
		local blockers = evidence.blockers or {}
		if evidence.timelineComplete ~= true then
			decision, confidence, reason = "WOULD_SKIP", "incomplete_timeline", "timeline_not_complete"
		elseif #blockers > 0 then
			decision, confidence, reason = "WOULD_SKIP", "insufficient_client_evidence", blockers[1]
		elseif evidence.correlationExact == true and evidence.noCompetingCorpse == true
			and (evidence.clientSamples or 0) >= 2 and evidence.descriptorStable == true
			and evidence.compositionStable == true and evidence.appearanceStable == true
			and evidence.outfitStable == true and evidence.positionCompatible == true
			and evidence.timeCompatible == true and evidence.serverClothesEmpty == true
			and evidence.serverOutfitMissing == true and evidence.initialCorpseCandidateEmpty == true
			and evidence.confirmedClientServerDesync == true
			and (evidence.corpseEquivalentCount or 0) == 0
			and #descriptors > 0 and (evidence.descriptorComplete or 0) == #descriptors
			and (evidence.descriptorEligible or 0) == #descriptors then
			decision, confidence, reason = "WOULD_RESTORE", "exact_onlineid_consistent_samples",
				"client_outfit_never_materialized_server_side"
		else
			decision, confidence, reason = "WOULD_SKIP", "insufficient_client_evidence", "client_recovery_contract_not_satisfied"
		end
	elseif category == "CORPSE_VISUAL_ONLY_LOSS" or category == "NAKED_VISUAL_BUT_PRESENT" then
		source = "CORPSE_INVENTORY"
		decision, confidence, reason = "WOULD_SKIP", "not_needed", "inventory_still_present"
	elseif category == "OUTFIT_REPLACED" then
		source = "MIXED_VISUAL"
		decision, confidence, reason = "WOULD_SKIP", "ambiguous", "replacement_is_not_proven_item_loss"
	elseif category == "PROXIMITY_OUTFIT_MISMATCH" then
		source = "PROXIMITY_CORRELATION"
		decision, confidence, reason = "WOULD_SKIP", "unsafe", "outfit_mismatch_without_exact_identity"
	elseif category == "EMPTY_POST_NO_BASELINE" or category == "EMPTY_CORPSE_SUSPECT" then
		decision, confidence, reason = "WOULD_SKIP", "none", "no_authoritative_item_source"
	elseif category == "AMBIGUOUS_CORPSE_MATCH" or category == "UNMATCHED_CORPSE" then
		decision, confidence, reason = "WOULD_SKIP", "unsafe", "corpse_identity_not_proven"
	elseif category == "CONFIRMED_ITEM_REAPPEARED" or category == "CONFIRMED_ITEM_LATER_MOVED" then
		descriptors = opts.missingDescriptors or {}
		types = #descriptors > 0 and typesFromDescriptors(descriptors) or (opts.missing or {})
		source = "TIMELINE_CONTRADICTION"
		decision, confidence, reason = "WOULD_SKIP", "contradicted", "item_reappeared_or_was_later_located"
	end

	local stats = SCLG_Diagnostics.stats()
	local completeCount, eligibleCount, transientCount, ineligibleReasons = descriptorAssessment(descriptors)
	if decision == "WOULD_RESTORE" then
		stats.recoveryWouldRestore = stats.recoveryWouldRestore + 1
	elseif decision == "NEEDS_REVIEW" then
		stats.recoveryNeedsReview = stats.recoveryNeedsReview + 1
	else
		stats.recoveryWouldSkip = stats.recoveryWouldSkip + 1
	end
	if category == "CLIENT_ONLY_VISUAL" then
		if decision == "WOULD_RESTORE" then
			stats.clientVisualWouldRestore = (stats.clientVisualWouldRestore or 0) + 1
		else
			stats.clientVisualWouldSkip = (stats.clientVisualWouldSkip or 0) + 1
		end
	end
	local clientEvidence = opts.clientEvidence or {}

	local line = SCLG_Diagnostics.casePrefix(context, "RECOVERY_SIM", category,
		SCLG_Diagnostics.priorityFor(category))
		.. " decision=" .. decision
		.. " source=" .. source
		.. " confidence=" .. confidence
		.. " reason=" .. reason
		.. " count=" .. tostring(#types)
		.. " items=" .. joined(types)
		.. " descriptorCount=" .. tostring(#descriptors)
		.. " descriptorComplete=" .. tostring(completeCount)
		.. " descriptorEligible=" .. tostring(eligibleCount)
		.. " descriptorTransient=" .. tostring(transientCount)
		.. " ineligibleReasons=" .. joined(ineligibleReasons)
		.. " confirmedSamples=" .. tostring(opts.confirmedSamples or 0)
		.. " confirmedClientServerDesync=" .. tostring(clientEvidence.confirmedClientServerDesync == true)
		.. " clientSamples=" .. tostring(clientEvidence.clientSamples or 0)
		.. " distinctKinds=" .. tostring(clientEvidence.distinctKinds or 0)
		.. " distinctObservers=" .. tostring(clientEvidence.distinctObservers or 0)
		.. " sampleHash=" .. tostring(clientEvidence.sampleHash or "none")
		.. " compositionHash=" .. tostring(clientEvidence.compositionHash or "none")
		.. " appearanceHash=" .. tostring(clientEvidence.appearanceHash or "none")
		.. " stateHash=" .. tostring(clientEvidence.stateHash or "none")
		.. " compositionStable=" .. tostring(clientEvidence.compositionStable == true)
		.. " appearanceStable=" .. tostring(clientEvidence.appearanceStable == true)
		.. " stateStable=" .. tostring(clientEvidence.stateStable == true)
		.. " stateTransitions=" .. tostring(clientEvidence.stateTransitions or 0)
		.. " descriptorStable=" .. tostring(clientEvidence.descriptorStable == true)
		.. " outfitStable=" .. tostring(clientEvidence.outfitStable == true)
		.. " positionCompatible=" .. tostring(clientEvidence.positionCompatible == true)
		.. " timeCompatible=" .. tostring(clientEvidence.timeCompatible == true)
		.. " correlationExact=" .. tostring(clientEvidence.correlationExact == true)
		.. " noCompetingCorpse=" .. tostring(clientEvidence.noCompetingCorpse == true)
		.. " timelineComplete=" .. tostring(clientEvidence.timelineComplete == true)
		.. " corpseEquivalentCount=" .. tostring(clientEvidence.corpseEquivalentCount or 0)
		.. " lateAddedItems=" .. tostring(clientEvidence.lateAddedItems or 0)
		.. " lateAddedTypes=" .. joined(clientEvidence.lateAddedTypes)
		.. " blockers=" .. joined(clientEvidence.blockers)
		.. " descriptors=" .. descriptorSummaries(descriptors)
		.. " mutation=false descriptorMode=client_visual_plus_unique_inventory_resolution"
	SCLG_FileLog.appendRecovery(line)
	SCLG_Log.info("RecoverySimulation", line)
end
