--!strict
-- Hub onboarding progress. Other systems call Tutorial.complete(player, id)
-- when the player does the thing; the step only advances if it was the
-- current one, so doing things out of order never breaks the flow.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local Net = require(script.Parent.Parent.Lib.Net)
local PlayerData = require(script.Parent.PlayerData)
local Analytics = require(script.Parent.Analytics)

local Tutorial = {}

local DONE = #Config.TutorialSteps + 1

function Tutorial.isActive(player: Player): boolean
	local profile = PlayerData.get(player)
	return profile ~= nil and profile.tutorial.step < DONE
end

function Tutorial.complete(player: Player, id: string)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	local current = Config.TutorialSteps[profile.tutorial.step]
	if not current then
		return
	end
	if profile.tutorial.step == 1 then
		Analytics.event(player, "TutorialStarted")
	end
	-- Advance past this step and any later steps already satisfied.
	local index = nil
	for i, step in Config.TutorialSteps do
		if step.id == id then
			index = i
		end
	end
	if index and index >= profile.tutorial.step then
		profile.tutorial.step = index + 1
		Analytics.funnel(player, "FirstHubAction")
		if profile.tutorial.step == DONE then
			Analytics.event(player, "TutorialCompleted")
		end
		PlayerData.markDirty(player)
	end
end

function Tutorial.start()
	Net.onInvoke("SkipTutorial", 1, function(player)
		local profile = PlayerData.get(player)
		if not profile then
			return { ok = false }
		end
		profile.tutorial.step = DONE
		-- Skipping still hands over the starter jetpack so nobody misses it.
		profile.gear.owned.jetpack_basic = true
		profile.gear.equipped = profile.gear.equipped or "jetpack_basic"
		PlayerData.markDirty(player)
		Analytics.event(player, "TutorialSkipped")
		return { ok = true }
	end)
end

return Tutorial
