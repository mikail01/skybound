--!strict
-- Analytics hooks. Funnel steps go to Roblox's onboarding funnel (visible in
-- Creator Dashboard > Analytics > Funnels); everything else is a custom
-- event. Each funnel step is logged once per player, ever.

local AnalyticsService = game:GetService("AnalyticsService")

local PlayerData = require(script.Parent.PlayerData)

local Analytics = {}

-- Order matters: this is the new-player funnel from the design doc.
Analytics.FUNNEL = table.freeze({
	"Join",
	"FirstHubAction",
	"DailyRewardClaim",
	"FirstUpgrade",
	"FirstGearEquip",
	"FirstPortalEntry",
	"FirstRunStarted",
	"First1000m",
	"FirstDeath",
	"FirstRetry",
	"FirstSecondRun",
	"FirstSessionReward",
	"ReturnNextDay",
})

function Analytics.funnel(player: Player, step: string)
	local profile = PlayerData.get(player)
	if not profile or profile.funnel[step] then
		return
	end
	profile.funnel[step] = true
	PlayerData.markDirty(player)
	local index = table.find(Analytics.FUNNEL, step)
	if not index then
		warn("[Analytics] unknown funnel step " .. step)
		return
	end
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, index, step)
	end)
end

function Analytics.event(player: Player, name: string, value: number?)
	pcall(function()
		AnalyticsService:LogCustomEvent(player, name, value or 1)
	end)
end

-- Fires once per player per flag: "first potion used", "first capsule", etc.
function Analytics.first(player: Player, flag: string)
	local profile = PlayerData.get(player)
	if not profile or profile.funnel[flag] then
		return
	end
	profile.funnel[flag] = true
	PlayerData.markDirty(player)
	Analytics.event(player, flag)
end

function Analytics.start()
	PlayerData.onLoaded(function(player, profile)
		Analytics.funnel(player, "Join")
		local today = os.time() // 86400
		if profile.lastJoinDay >= 0 and today == profile.lastJoinDay + 1 then
			Analytics.funnel(player, "ReturnNextDay")
		end
		if profile.lastJoinDay >= 0 and today > profile.lastJoinDay then
			Analytics.event(player, "ReturningPlayer", today - profile.lastJoinDay)
		end
		profile.lastJoinDay = today
		PlayerData.markDirty(player)

		-- Session-length milestones for retention tuning.
		task.spawn(function()
			for _, minutes in { 5, 10, 20, 30 } do
				local target = PlayerData.sessionStart(player) + minutes * 60
				while player.Parent and os.time() < target do
					task.wait(5)
				end
				if not player.Parent then
					return
				end
				Analytics.event(player, "Session" .. minutes .. "Min")
			end
		end)
	end)
end

return Analytics
