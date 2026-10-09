--!strict
-- Daily and weekly quests ("master specific objectives"). Progress is tracked
-- on the server from real gameplay events; the client only displays it and
-- asks to claim. Quest picks are deterministic per UTC day / week, so every
-- player gets the same set and a rejoin never rerolls them.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Formulas = require(Shared.Formulas)
local Types = require(Shared.Types)

local Net = require(script.Parent.Parent.Lib.Net)
local PlayerData = require(script.Parent.PlayerData)
local Analytics = require(script.Parent.Analytics)

local Quests = {}

local BEST_KINDS = { height = true }

local function pick(pool: { Config.QuestDef }, count: number, seed: number): { Types.QuestProgress }
	local indices = {}
	for i in pool do
		table.insert(indices, i)
	end
	local rng = Random.new(seed)
	for i = #indices, 2, -1 do
		local j = rng:NextInteger(1, i)
		indices[i], indices[j] = indices[j], indices[i]
	end
	local out = {}
	for i = 1, math.min(count, #indices) do
		table.insert(out, { id = pool[indices[i]].id, progress = 0, claimed = false })
	end
	return out
end

local defs: { [string]: Config.QuestDef } = {}
for _, q in Config.DailyQuests do
	defs[q.id] = q
end
for _, q in Config.WeeklyQuests do
	defs[q.id] = q
end

function Quests.def(id: string): Config.QuestDef?
	return defs[id]
end

-- Roll over to today's / this week's quests if needed. Returns true if changed.
local function refresh(profile: Types.Profile): boolean
	local now = os.time()
	local day = Formulas.dayNumber(now)
	local week = day // 7
	local changed = false
	if profile.quests.day ~= day then
		profile.quests.day = day
		profile.quests.daily = pick(Config.DailyQuests, Config.DAILY_QUEST_COUNT, day * 31 + 7)
		changed = true
	end
	if profile.quests.week ~= week then
		profile.quests.week = week
		profile.quests.weekly = pick(Config.WeeklyQuests, Config.WEEKLY_QUEST_COUNT, week * 131 + 3)
		changed = true
	end
	return changed
end

-- Record gameplay. Additive kinds add `amount`; "best" kinds keep the max.
function Quests.record(player: Player, kind: string, amount: number)
	local profile = PlayerData.get(player)
	if not profile or amount <= 0 then
		return
	end
	refresh(profile)
	local completedNow = 0
	for _, list in { profile.quests.daily, profile.quests.weekly } do
		for _, q in list do
			local def = defs[q.id]
			if def and def.kind == kind and not q.claimed and q.progress < def.target then
				if BEST_KINDS[kind] then
					q.progress = math.max(q.progress, math.floor(amount))
				else
					q.progress = math.min(def.target, q.progress + math.floor(amount))
				end
				if q.progress >= def.target then
					q.progress = def.target
					completedNow += 1
				end
			end
		end
	end
	if completedNow > 0 then
		Net.fire(
			player,
			"Notify",
			if completedNow == 1
				then "QUEST COMPLETE! Claim it at the Quest Board."
				else completedNow .. " QUESTS COMPLETE!",
			"quest"
		)
	end
	PlayerData.markDirty(player)
end

function Quests.start()
	PlayerData.onLoaded(function(player, profile)
		if refresh(profile) then
			PlayerData.markDirty(player)
		end
	end)

	-- Day rollover while online.
	task.spawn(function()
		while true do
			task.wait(30)
			for _, player in game:GetService("Players"):GetPlayers() do
				local profile = PlayerData.get(player)
				if profile and refresh(profile) then
					PlayerData.markDirty(player)
				end
			end
		end
	end)

	Net.onInvoke("ClaimQuest", 0.3, function(player, scope: any, index: any)
		local profile = PlayerData.get(player)
		if not profile or (scope ~= "daily" and scope ~= "weekly") or typeof(index) ~= "number" then
			return { ok = false }
		end
		refresh(profile)
		local list = if scope == "daily" then profile.quests.daily else profile.quests.weekly
		local q = list[index]
		local def = q and defs[q.id]
		if not q or not def then
			return { ok = false }
		end
		if q.claimed then
			return { ok = false, reason = "Already claimed." }
		end
		if q.progress < def.target then
			return { ok = false, reason = "Not finished yet." }
		end
		q.claimed = true
		PlayerData.grant(player, def.reward)
		Analytics.event(player, "QuestClaimed_" .. def.id)
		Analytics.first(player, "FirstQuestClaimed")
		PlayerData.syncNow(player)
		return { ok = true, reward = def.reward }
	end)
end

return Quests
