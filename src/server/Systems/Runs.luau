--!strict
-- Run lifecycle and server authority for climbing. Each player climbs in
-- their own lane. The server:
--   * tracks a "trusted height" that can only rise at a physically possible
--     rate, so teleport/fly exploits can't inflate scores;
--   * regenerates the same deterministic chunks as the client and only pays
--     for pickups that exist, haven't been taken, and are near the player;
--   * awards milestones, records and results.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Formulas = require(Shared.Formulas)
local Generator = require(Shared.Generator)
local Types = require(Shared.Types)

local Net = require(script.Parent.Parent.Lib.Net)
local PlayerData = require(script.Parent.PlayerData)
local Analytics = require(script.Parent.Analytics)
local Tutorial = require(script.Parent.Tutorial)
local Leaderboard = require(script.Parent.Leaderboard)

type Run = {
	seed: number,
	lane: number,
	origin: Vector3,
	tutorial: boolean,
	startTime: number,
	trustedY: number,
	maxY: number,
	lastCheck: number,
	strikes: number,
	lastStrike: number,
	chunks: { [number]: Types.Chunk },
	collected: { [number]: boolean },
	coins: number,
	gems: number,
	items: { string },
	worldIndex: number,
	ended: boolean,
}

local Runs = {}

local runs: { [Player]: Run } = {}
local lanesInUse: { [number]: Player } = {}
local portalDebounce: { [Player]: number } = {}
local rng = Random.new()

local AC = Config.AntiCheat
local CHUNK = Config.Generation.CHUNK_HEIGHT

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function allocateLane(player: Player): number
	local lane = 0
	while lanesInUse[lane] and lanesInUse[lane] ~= player do
		lane += 1
	end
	lanesInUse[lane] = player
	return lane
end

local function chunkFor(run: Run, index: number): Types.Chunk?
	if index < 0 then
		return nil
	end
	-- Only generate near where the player legitimately is.
	local maxIndex = math.floor(run.trustedY / CHUNK) + Config.Generation.CHUNKS_AHEAD + 1
	if index > maxIndex then
		return nil
	end
	local chunk = run.chunks[index]
	if not chunk then
		chunk = Generator.chunk(run.seed, index, run.tutorial)
		run.chunks[index] = chunk
	end
	return chunk
end

function Runs.isInRun(player: Player): boolean
	local run = runs[player]
	return run ~= nil and not run.ended
end

local function heightMeters(run: Run): number
	return math.floor(math.max(0, run.maxY) * Config.METERS_PER_STUD)
end

local function finish(player: Player, reason: string)
	local run = runs[player]
	local profile = PlayerData.get(player)
	if not run or run.ended or not profile then
		return
	end
	run.ended = true
	player:SetAttribute("InRun", false)

	local root = rootOf(player)
	if root then
		root.Anchored = true -- hold still behind the results screen
	end

	local height = heightMeters(run)
	local previousBest = profile.bestHeight
	local newRecord = height > previousBest
	if newRecord then
		profile.bestHeight = height
		Leaderboard.recordBest(player, height)
	end
	profile.totalRuns += 1
	if run.tutorial then
		profile.tutorial.firstRunDone = true
	end
	PlayerData.markDirty(player)

	Analytics.funnel(player, "FirstDeath")
	Analytics.event(player, "RunEnded_" .. reason, height)

	local nearMiss: string? = nil
	if not newRecord and previousBest - height <= math.max(300, previousBest * 0.15) then
		nearMiss = Format.meters(previousBest - height) .. " away from your personal best!"
	end
	local goal, goalReward = Formulas.nextGoal(profile)
	local result: Types.RunResult = {
		height = height,
		coins = run.coins,
		gems = run.gems,
		items = run.items,
		newRecord = newRecord,
		bestHeight = profile.bestHeight,
		nextGoal = goal .. " — " .. goalReward,
		nearMiss = nearMiss,
	}
	Net.fire(player, "RunResult", result)
	PlayerData.syncNow(player)
end

function Runs.begin(player: Player, fromPortal: boolean): boolean
	local profile = PlayerData.get(player)
	local root = rootOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not profile or not root or not character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	local existing = runs[player]
	if existing and not existing.ended then
		finish(player, "restart")
	end

	local lane = allocateLane(player)
	local origin = Config.RUN_ORIGIN + Vector3.new(lane * Config.RUN_LANE_SPACING, 0, 0)
	local seed = rng:NextInteger(1, 2 ^ 30)
	local tutorial = not profile.tutorial.firstRunDone
	local run: Run = {
		seed = seed,
		lane = lane,
		origin = origin,
		tutorial = tutorial,
		startTime = os.clock(),
		trustedY = 0,
		maxY = 0,
		lastCheck = os.clock(),
		strikes = 0,
		lastStrike = 0,
		chunks = {},
		collected = {},
		coins = 0,
		gems = 0,
		items = {},
		worldIndex = 1,
		ended = false,
	}
	runs[player] = run

	root.Anchored = false
	character:PivotTo(CFrame.new(origin + Vector3.new(0, 5, 0)))
	root.AssemblyLinearVelocity = Vector3.zero
	player:SetAttribute("InRun", true)

	if fromPortal then
		Analytics.funnel(player, "FirstPortalEntry")
		Tutorial.complete(player, "portal")
	end
	Analytics.funnel(player, "FirstRunStarted")
	if profile.totalRuns >= 1 then
		Analytics.funnel(player, "FirstSecondRun")
	end

	Net.fire(player, "RunStarted", Formulas.runInfo(profile, seed, origin, tutorial))
	return true
end

function Runs.returnToHub(player: Player)
	local run = runs[player]
	if run and not run.ended then
		finish(player, "hub")
	end
	if run then
		if lanesInUse[run.lane] == player then
			lanesInUse[run.lane] = nil
		end
		runs[player] = nil
	end
	player:SetAttribute("InRun", false)
	local character = player.Character
	local root = rootOf(player)
	if character and root then
		root.Anchored = false
		local spawn = workspace:FindFirstChild("HubSpawn", true)
		local target = if spawn and spawn:IsA("BasePart")
			then spawn.CFrame + Vector3.new(0, 4, 0)
			else CFrame.new(Config.HUB_CENTER + Vector3.new(0, 10, 0))
		character:PivotTo(target)
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

local function grantCapsule(player: Player, run: Run)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	local rarity = Formulas.rollRarity(Formulas.luck(profile), rng)
	local reward = Config.CapsuleRewards[rarity]
	PlayerData.grant(player, reward)
	run.coins += reward.coins or 0
	run.gems += reward.gems or 0
	table.insert(run.items, rarity .. " Capsule")
	Analytics.first(player, "FirstCapsuleFound")
	if rarity ~= "Common" and rarity ~= "Uncommon" then
		Analytics.first(player, "FirstRareItem")
	end
	Analytics.event(player, "Capsule_" .. rarity)
	Net.fire(player, "RewardPopup", {
		title = rarity:upper() .. " CAPSULE",
		rarity = rarity,
		text = Formulas.describeReward(reward),
	})
end

local function onCollect(player: Player, chunkIndex: any, pickupId: any)
	local run = runs[player]
	local profile = PlayerData.get(player)
	local root = rootOf(player)
	if not run or run.ended or not profile or not root then
		return
	end
	if typeof(chunkIndex) ~= "number" or typeof(pickupId) ~= "number" then
		return
	end
	if run.collected[pickupId] then
		return
	end
	local chunk = chunkFor(run, chunkIndex)
	if not chunk then
		return
	end
	local pickup: Types.PickupData? = nil
	for _, p in chunk.pickups do
		if p.id == pickupId then
			pickup = p
			break
		end
	end
	if not pickup then
		return
	end
	local world = run.origin + Vector3.new(pickup.x, pickup.y, 0)
	local range = AC.PICKUP_RANGE
	if pickup.kind == "coin" and Formulas.effectActive(profile, "magnet") then
		range += AC.MAGNET_EXTRA_RANGE
	end
	if (root.Position - world).Magnitude > range then
		return
	end
	run.collected[pickupId] = true

	if pickup.kind == "coin" then
		local mult = if Formulas.effectActive(profile, "coin")
			then Config.PotionEffects.COIN_MULTIPLIER
			else 1
		local amount = pickup.value * mult
		run.coins += amount
		PlayerData.addCoins(player, amount)
	elseif pickup.kind == "gem" then
		run.gems += 1
		PlayerData.addGems(player, 1)
	elseif pickup.kind == "potion" and pickup.potion then
		PlayerData.addPotion(player, pickup.potion, 1)
		local def = Formulas.potion(pickup.potion)
		table.insert(run.items, if def then def.name else pickup.potion)
	elseif pickup.kind == "capsule" then
		grantCapsule(player, run)
	end
end

local function validate(player: Player, run: Run, now: number)
	local root = rootOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		finish(player, "died")
		return
	end
	local dt = now - run.lastCheck
	run.lastCheck = now
	local y = root.Position.Y - run.origin.Y
	-- Trusted height can rise no faster than any legit movement allows.
	run.trustedY = math.min(y, run.trustedY + AC.MAX_RISE_SPEED * dt)
	if y > run.trustedY + AC.RISE_TOLERANCE and now - run.lastStrike > 1 then
		run.lastStrike = now
		run.strikes += 1
		if run.strikes >= AC.MAX_STRIKES then
			Analytics.event(player, "SuspiciousRun", run.strikes)
			finish(player, "invalid")
			return
		end
	end
	if run.trustedY > run.maxY then
		run.maxY = run.trustedY
	end
	-- Fell far below the best point: the client should have ended the run.
	if y < run.maxY - 220 then
		finish(player, "fell")
		return
	end

	local meters = heightMeters(run)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	if meters >= 1000 then
		Analytics.funnel(player, "First1000m")
	end
	for _, milestone in Config.Milestones do
		local key = tostring(milestone.height)
		if meters >= milestone.height and not profile.milestones[key] then
			profile.milestones[key] = true
			PlayerData.grant(player, milestone.reward)
			run.coins += milestone.reward.coins or 0
			run.gems += milestone.reward.gems or 0
			Net.fire(player, "Milestone", {
				height = milestone.height,
				reward = Formulas.describeReward(milestone.reward),
			})
		end
	end
	local _, worldIndex = Formulas.worldForHeight(meters)
	if worldIndex > run.worldIndex then
		run.worldIndex = worldIndex
		Analytics.first(player, "WorldReached_" .. Config.Worlds[worldIndex].id)
	end
end

function Runs.start()
	Net.onEvent("CollectPickup", 0, onCollect)

	Net.onEvent("EndRun", 0.5, function(player, reason: any)
		finish(player, if reason == "hazard" then "hazard" else "fell")
	end)

	Net.onEvent("ShieldUsed", 0.5, function(player)
		local profile = PlayerData.get(player)
		if profile and Runs.isInRun(player) and (profile.effects.shield or 0) > 0 then
			profile.effects.shield -= 1
			if profile.effects.shield <= 0 then
				(profile.effects :: any).shield = nil
			end
			PlayerData.markDirty(player)
		end
	end)

	Net.onInvoke("Retry", 0.5, function(player)
		local run = runs[player]
		if run and not run.ended then
			return { ok = false }
		end
		Analytics.funnel(player, "FirstRetry")
		return { ok = Runs.begin(player, false) }
	end)

	Net.onInvoke("ReturnToHub", 0.5, function(player)
		Runs.returnToHub(player)
		return { ok = true }
	end)

	PlayerData.addSnapshotField(function(player, snap)
		snap.inRun = Runs.isInRun(player)
	end)

	-- Portal: the hub builds a part named PortalTrigger.
	task.spawn(function()
		local trigger = workspace:WaitForChild("Hub"):WaitForChild("PortalTrigger") :: BasePart
		trigger.Touched:Connect(function(hit)
			local character = hit:FindFirstAncestorOfClass("Model")
			local player = character and Players:GetPlayerFromCharacter(character)
			if not player or Runs.isInRun(player) then
				return
			end
			local now = os.clock()
			if portalDebounce[player] and now - portalDebounce[player] < 2 then
				return
			end
			portalDebounce[player] = now
			Runs.begin(player, true)
		end)
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for player, run in runs do
			if not run.ended then
				validate(player, run, now)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local run = runs[player]
		if run then
			if not run.ended then
				finish(player, "left")
			end
			if lanesInUse[run.lane] == player then
				lanesInUse[run.lane] = nil
			end
		end
		runs[player] = nil
		portalDebounce[player] = nil
	end)

	-- A respawned character is always back at the hub, out of any run.
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			local run = runs[player]
			if run then
				if not run.ended then
					finish(player, "died")
				end
				if lanesInUse[run.lane] == player then
					lanesInUse[run.lane] = nil
				end
				runs[player] = nil
			end
			player:SetAttribute("InRun", false)
		end)
	end)
end

return Runs
