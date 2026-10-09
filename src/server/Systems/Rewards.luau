--!strict
-- Daily rewards ("come back tomorrow") and playtime rewards ("stay and play
-- naturally"). Daily claims never reset the streak for missing a day — the
-- cycle simply continues. Playtime rewards are per session and are claimed
-- manually, so they never interrupt a run.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Formulas = require(Shared.Formulas)

local Net = require(script.Parent.Parent.Lib.Net)
local PlayerData = require(script.Parent.PlayerData)
local Analytics = require(script.Parent.Analytics)
local Tutorial = require(script.Parent.Tutorial)

local Rewards = {}

local playtimeClaimed: { [Player]: { [number]: boolean } } = {}
local playtimeNotified: { [Player]: { [number]: boolean } } = {}

local function dailyState(player: Player): (boolean, number)
	local profile = PlayerData.get(player)
	if not profile then
		return false, 0
	end
	local now = os.time()
	local today = Formulas.dayNumber(now)
	local ready = profile.daily.lastDay < today
	local nextAt = if ready then now else (today + 1) * 86400
	return ready, nextAt
end

function Rewards.dailyIndex(claims: number): number
	return claims % #Config.DailyRewards + 1
end

function Rewards.start()
	PlayerData.addSnapshotField(function(player, snap)
		local ready, nextAt = dailyState(player)
		snap.dailyReady = ready
		snap.dailyNextAt = nextAt
		-- Send a dense true/false array: remotes drop entries from tables
		-- with gaps in their numeric keys (e.g. only reward 2 claimed).
		local claimed = playtimeClaimed[player] or {}
		local dense = {}
		for i in Config.PlaytimeRewards do
			dense[i] = claimed[i] == true
		end
		snap.playtimeClaimed = dense
	end)

	PlayerData.onLoaded(function(player)
		playtimeClaimed[player] = {}
		playtimeNotified[player] = {}
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		playtimeClaimed[player] = nil
		playtimeNotified[player] = nil
	end)

	Net.onInvoke("ClaimDaily", 1, function(player)
		local profile = PlayerData.get(player)
		local ready = dailyState(player)
		if not profile or not ready then
			return { ok = false, reason = "Come back tomorrow!" }
		end
		local index = Rewards.dailyIndex(profile.daily.claims)
		local reward = Config.DailyRewards[index]
		profile.daily.claims += 1
		profile.daily.lastDay = Formulas.dayNumber(os.time())
		PlayerData.grant(player, reward)
		Analytics.funnel(player, "DailyRewardClaim")
		Analytics.event(player, "DailyRewardClaimed", index)
		Tutorial.complete(player, "daily")
		PlayerData.syncNow(player)
		return { ok = true, day = index, reward = reward }
	end)

	Net.onInvoke("ClaimPlaytime", 0.5, function(player, index: any)
		local claimed = playtimeClaimed[player]
		if not claimed or typeof(index) ~= "number" or index ~= math.floor(index) then
			return { ok = false }
		end
		local entry = Config.PlaytimeRewards[index]
		if not entry or claimed[index] then
			return { ok = false, reason = "Already claimed." }
		end
		local elapsed = os.time() - PlayerData.sessionStart(player)
		if elapsed < entry.minutes * 60 then
			return { ok = false, reason = "Not ready yet." }
		end
		claimed[index] = true
		PlayerData.grant(player, entry.reward)
		Analytics.funnel(player, "FirstSessionReward")
		Analytics.event(player, "PlaytimeRewardClaimed", entry.minutes)
		PlayerData.syncNow(player)
		return { ok = true, reward = entry.reward }
	end)

	-- Gentle "ready" notice, once per reward.
	task.spawn(function()
		while true do
			task.wait(5)
			for player, notified in playtimeNotified do
				local elapsed = os.time() - PlayerData.sessionStart(player)
				for i, entry in Config.PlaytimeRewards do
					if not notified[i] and elapsed >= entry.minutes * 60 then
						notified[i] = true
						Net.fire(player, "Notify", "PLAYTIME REWARD READY!", "playtime")
					end
				end
			end
		end
	end)
end

return Rewards
