--!strict
-- Best-height leaderboards: in-server leaderstats plus a global
-- OrderedDataStore shown on the hub board. Friends/weekly boards can be
-- added as extra OrderedDataStores keyed by week number.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Format = require(Shared.Format)

local PlayerData = require(script.Parent.PlayerData)

local Leaderboard = {}

local REFRESH_INTERVAL = 120
local TOP_COUNT = 10

local ordered: OrderedDataStore? = nil
local pendingWrites: { [number]: number } = {}

local function setStat(player: Player, height: number)
	local stats = player:FindFirstChild("leaderstats")
	local best = stats and stats:FindFirstChild("Best")
	if best and best:IsA("IntValue") then
		best.Value = height
	end
end

function Leaderboard.recordBest(player: Player, height: number)
	setStat(player, height)
	pendingWrites[player.UserId] = height
end

local function flushWrites()
	local store = ordered
	if not store then
		return
	end
	for userId, height in pendingWrites do
		pendingWrites[userId] = nil
		pcall(function()
			store:UpdateAsync(tostring(userId), function(old: any): any
				if typeof(old) == "number" and old >= height then
					return nil
				end
				return math.floor(height)
			end)
		end)
	end
end

local function refreshBoard()
	local store = ordered
	local hub = workspace:FindFirstChild("Hub")
	local list = hub and hub:FindFirstChild("LeaderboardList", true)
	if not store or not list then
		return
	end
	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, TOP_COUNT)
	end)
	if not ok or not pages then
		return
	end
	local entries = (pages :: DataStorePages):GetCurrentPage()
	for i = 1, TOP_COUNT do
		local row = list:FindFirstChild("Row" .. i)
		if row and row:IsA("TextLabel") then
			local entry = entries[i]
			if entry then
				local userId = tonumber(entry.key) or 0
				local nameOk, name = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				row.Text = string.format(
					"%d.  %s   %s",
					i,
					if nameOk then name else "Player",
					Format.meters(entry.value)
				)
			else
				row.Text = string.format("%d.  —", i)
			end
		end
	end
end

function Leaderboard.init()
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(Config.LEADERBOARD_STORE)
	end)
	if ok then
		ordered = store
	end
end

function Leaderboard.start()
	Players.PlayerAdded:Connect(function(player)
		local stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		local best = Instance.new("IntValue")
		best.Name = "Best"
		best.Parent = stats
		stats.Parent = player
	end)
	for _, player in Players:GetPlayers() do
		if not player:FindFirstChild("leaderstats") then
			local stats = Instance.new("Folder")
			stats.Name = "leaderstats"
			local best = Instance.new("IntValue")
			best.Name = "Best"
			best.Parent = stats
			stats.Parent = player
		end
	end
	PlayerData.onLoaded(function(player, profile)
		setStat(player, profile.bestHeight)
	end)

	task.spawn(function()
		while true do
			flushWrites()
			refreshBoard()
			task.wait(REFRESH_INTERVAL)
		end
	end)
	game:BindToClose(flushWrites)
end

return Leaderboard
