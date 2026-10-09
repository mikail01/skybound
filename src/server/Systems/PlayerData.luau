--!strict
-- Player profile persistence: DataStore load/save with retries, session
-- locking (so two servers never write the same profile), autosave,
-- BindToClose flush, schema reconciliation, and throttled client sync.
-- If DataStores are unavailable (e.g. Studio without API access) the game
-- still runs on an in-memory profile and warns loudly that nothing saves.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Formulas = require(Shared.Formulas)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

type Profile = Types.Profile

local SCHEMA_VERSION = 1
local LOCK_EXPIRY = 30 * 60 -- a lock older than this is considered abandoned
local MAX_RETRIES = 5
local SYNC_INTERVAL = 0.25

local PlayerData = {}

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
local canSave: { [Player]: boolean } = {}
local dirty: { [Player]: boolean } = {}
local sessionStart: { [Player]: number } = {}
local loadedCallbacks: { (Player, Profile) -> () } = {}
local snapshotExtras: { (Player, any) -> () } = {}
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function defaultProfile(): Profile
	local upgrades = {}
	for _, def in Config.Upgrades do
		upgrades[def.id] = 0
	end
	local potions = {}
	for _, def in Config.Potions do
		potions[def.id] = 0
	end
	return {
		version = SCHEMA_VERSION,
		coins = 0,
		gems = 0,
		bestHeight = 0,
		totalRuns = 0,
		totalCoinsEarned = 0,
		upgrades = upgrades,
		potions = potions,
		effects = {},
		gear = { owned = {}, equipped = nil },
		daily = { claims = 0, lastDay = -1 },
		milestones = {},
		tutorial = { step = 1, firstRunDone = false },
		freeUpgrade = true,
		funnel = {},
		firstJoin = os.time(),
		lastJoinDay = -1,
		quests = { day = -1, daily = {}, week = -1, weekly = {} },
	}
end

-- Fill in fields added after a profile was first saved and drop junk types.
local function reconcile(data: any): Profile
	local fresh = defaultProfile()
	if typeof(data) ~= "table" then
		return fresh
	end
	local function merge(target: any, source: any)
		for key, value in source do
			local existing = target[key]
			if typeof(value) == "table" and typeof(existing) == "table" then
				merge(existing, value)
			elseif existing == nil or typeof(existing) == typeof(value) then
				target[key] = value
			end
		end
	end
	merge(fresh, data)
	-- Sanitise numbers that must never go negative or NaN.
	for _, key in { "coins", "gems", "bestHeight", "totalRuns", "totalCoinsEarned" } do
		local v = (fresh :: any)[key]
		if typeof(v) ~= "number" or v ~= v or v < 0 then
			(fresh :: any)[key] = 0
		end
	end
	fresh.version = SCHEMA_VERSION
	return fresh
end

local function withRetries<T>(label: string, fn: () -> T): (boolean, T?)
	local delay = 1
	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(
			string.format(
				"[PlayerData] %s failed (attempt %d): %s",
				label,
				attempt,
				tostring(result)
			)
		)
		if attempt < MAX_RETRIES then
			task.wait(delay)
			delay = math.min(delay * 2, 16)
		end
	end
	return false, nil
end

local function key(player: Player): string
	return "Player_" .. player.UserId
end

local function loadProfile(player: Player): (Profile, boolean)
	local activeStore = store
	if not activeStore then
		return defaultProfile(), false
	end
	-- Claim the session lock; wait out a lock held by another live server.
	for _ = 1, 6 do
		local stolen = false
		local blocked = false
		local ok, result = withRetries("load " .. player.Name, function()
			return activeStore:UpdateAsync(key(player), function(old: any)
				local now = os.time()
				local record = if typeof(old) == "table" then old else { data = nil, lock = nil }
				local lock = record.lock
				if lock and lock.jobId ~= jobId and now - (lock.time or 0) < LOCK_EXPIRY then
					blocked = true
					return nil -- leave untouched
				end
				stolen = lock ~= nil and lock.jobId ~= jobId
				record.lock = { jobId = jobId, time = now }
				return record
			end)
		end)
		if not ok then
			return defaultProfile(), false
		end
		if not blocked then
			if stolen then
				warn("[PlayerData] took over an expired session lock for " .. player.Name)
			end
			local record: any = result
			return reconcile(if record then record.data else nil), true
		end
		task.wait(5)
	end
	-- Still locked after ~30s: play without saving rather than risk overwriting.
	warn(
		"[PlayerData] profile still locked by another server; "
			.. player.Name
			.. " will not save this session"
	)
	return defaultProfile(), false
end

local function saveProfile(player: Player, release: boolean)
	local activeStore = store
	local profile = profiles[player]
	if not activeStore or not profile or not canSave[player] then
		return
	end
	local copy = table.clone(profile)
	withRetries("save " .. player.Name, function()
		return activeStore:UpdateAsync(key(player), function(old: any)
			local record = if typeof(old) == "table" then old else {}
			if record.lock and record.lock.jobId ~= jobId then
				-- Another server owns this profile now; never clobber it.
				return nil
			end
			record.data = copy
			record.lock = if release then nil else { jobId = jobId, time = os.time() }
			return record
		end)
	end)
end

function PlayerData.get(player: Player): Profile?
	return profiles[player]
end

function PlayerData.sessionStart(player: Player): number
	return sessionStart[player] or os.time()
end

function PlayerData.onLoaded(callback: (Player, Profile) -> ())
	table.insert(loadedCallbacks, callback)
	for player, profile in profiles do
		task.spawn(callback, player, profile)
	end
end

-- Other systems add their own fields to the client snapshot.
function PlayerData.addSnapshotField(callback: (Player, any) -> ())
	table.insert(snapshotExtras, callback)
end

function PlayerData.markDirty(player: Player)
	dirty[player] = true
end

function PlayerData.addCoins(player: Player, amount: number)
	local profile = profiles[player]
	if not profile or amount ~= amount then
		return
	end
	profile.coins = math.max(0, math.floor(profile.coins + amount))
	if amount > 0 then
		profile.totalCoinsEarned += math.floor(amount)
	end
	dirty[player] = true
end

function PlayerData.addGems(player: Player, amount: number)
	local profile = profiles[player]
	if not profile or amount ~= amount then
		return
	end
	profile.gems = math.max(0, math.floor(profile.gems + amount))
	dirty[player] = true
end

-- Spend coins atomically; returns false (and changes nothing) if short.
function PlayerData.spendCoins(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile or amount < 0 or profile.coins < amount then
		return false
	end
	profile.coins -= amount
	dirty[player] = true
	return true
end

function PlayerData.addPotion(player: Player, id: string, count: number)
	local profile = profiles[player]
	if not profile or not Formulas.potion(id) then
		return
	end
	profile.potions[id] = math.min(Config.MAX_POTION_STACK, (profile.potions[id] or 0) + count)
	dirty[player] = true
end

function PlayerData.grant(player: Player, reward: Config.Reward)
	if reward.coins then
		PlayerData.addCoins(player, reward.coins)
	end
	if reward.gems then
		PlayerData.addGems(player, reward.gems)
	end
	if reward.potions then
		for id, count in reward.potions do
			PlayerData.addPotion(player, id, count)
		end
	end
end

function PlayerData.snapshot(player: Player): any
	local profile = profiles[player]
	if not profile then
		return nil
	end
	local snap: any = {
		profile = profile,
		serverTime = os.time(),
		sessionStart = sessionStart[player],
	}
	for _, extra in snapshotExtras do
		extra(player, snap)
	end
	return snap
end

function PlayerData.syncNow(player: Player)
	dirty[player] = false
	local snap = PlayerData.snapshot(player)
	if snap then
		Remotes.event("ProfileSync"):FireClient(player, snap)
	end
end

local function onPlayerAdded(player: Player)
	sessionStart[player] = os.time()
	local profile, ok = loadProfile(player)
	if not player.Parent then
		-- Left while loading: release the lock we just took.
		if ok then
			profiles[player] = profile
			canSave[player] = true
			saveProfile(player, true)
			profiles[player] = nil
			canSave[player] = nil
		end
		return
	end
	profiles[player] = profile
	canSave[player] = ok
	if not ok and store then
		Remotes.event("Notify"):FireClient(
			player,
			"Your progress couldn't load, so it won't save this session. Try rejoining later.",
			"error"
		)
	end
	player:SetAttribute("DataLoaded", true)
	for _, callback in loadedCallbacks do
		task.spawn(callback, player, profile)
	end
	PlayerData.syncNow(player)
end

local function onPlayerRemoving(player: Player)
	saveProfile(player, true)
	profiles[player] = nil
	canSave[player] = nil
	dirty[player] = nil
	sessionStart[player] = nil
end

function PlayerData.init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DATASTORE_NAME)
	end)
	if ok then
		store = result
		if RunService:IsStudio() then
			-- Fail fast in Studio instead of retrying for every join.
			local probeOk, probeErr = pcall(function()
				return result:GetAsync("__probe")
			end)
			if not probeOk then
				store = nil
				warn(
					"[PlayerData] DataStores unavailable in Studio — progress will NOT save. "
						.. tostring(probeErr)
				)
				warn(
					"[PlayerData] Enable Game Settings > Security > 'Enable Studio Access to API Services' to test saving."
				)
			end
		end
	else
		warn("[PlayerData] DataStores unavailable — progress will NOT save. " .. tostring(result))
		if RunService:IsStudio() then
			warn(
				"[PlayerData] Enable Game Settings > Security > 'Enable Studio Access to API Services' to test saving."
			)
		end
	end
end

function PlayerData.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < SYNC_INTERVAL then
			return
		end
		accumulator = 0
		for player, isDirty in dirty do
			if isDirty and player.Parent then
				PlayerData.syncNow(player)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Config.AUTOSAVE_INTERVAL)
			for player in profiles do
				task.spawn(saveProfile, player, false)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				saveProfile(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return PlayerData
