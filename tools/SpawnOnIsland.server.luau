-- Drop-in Script: makes everyone spawn on the imported floating island
-- (FloatingIslandMap) in ANY place, whatever other scripts it runs.
-- Put it in ServerScriptService as a Script (not a LocalScript).

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local NAME = "FloatingIslandMap"

local function isIsland(m)
	return m:IsA("Model")
		and (string.find(m.Name, NAME, 1, true) ~= nil or m:FindFirstChild("Spawn_Pad", true) ~= nil)
end

-- The island: in the Workspace, or moved to ServerStorage by the setup script.
local island
for _, container in { workspace, ServerStorage } do
	for _, child in container:GetChildren() do
		if isIsland(child) then
			island = child
			break
		end
	end
	if island then
		break
	end
end
if not island then
	warn("[SpawnOnIsland] no " .. NAME .. " found in Workspace or ServerStorage")
	return
end
if island.Parent ~= workspace then
	island.Parent = workspace
end
for _, d in island:GetDescendants() do
	if d:IsA("BasePart") then
		d.Anchored = true
		if string.sub(d.Name, -8) == "_Outline" then
			d.CanCollide = false
		end
	end
end

-- Where to stand: on top of the spawn pad, else the middle of the island.
local pad = island:FindFirstChild("Spawn_Pad", true)
local spawnTop
if pad and pad:IsA("BasePart") then
	spawnTop = pad.Position + Vector3.new(0, pad.Size.Y / 2, 0)
else
	local cf, size = island:GetBoundingBox()
	spawnTop = cf.Position + Vector3.new(0, size.Y / 2, 0)
end

local spawn = Instance.new("SpawnLocation")
spawn.Name = "IslandSpawn"
spawn.Anchored = true
spawn.Neutral = true
spawn.Duration = 0
spawn.Size = Vector3.new(10, 1, 10)
spawn.Transparency = 1
spawn.CanCollide = false
spawn.CFrame = CFrame.new(spawnTop + Vector3.new(0, 0.6, 0))
local decal = spawn:FindFirstChildOfClass("Decal")
if decal then
	decal:Destroy()
end
spawn.Parent = workspace

-- A solid floor under the spawn, in case the pad mesh has coarse collision.
local floor = Instance.new("Part")
floor.Name = "IslandSpawnFloor"
floor.Anchored = true
floor.Size = Vector3.new(14, 1, 14)
floor.Transparency = 1
floor.CFrame = CFrame.new(spawnTop - Vector3.new(0, 0.5, 0))
floor.Parent = workspace

-- Every other SpawnLocation is switched off, now and if one appears later.
local function disable(d)
	if d:IsA("SpawnLocation") and d ~= spawn then
		d.Enabled = false
	end
end
for _, d in workspace:GetDescendants() do
	disable(d)
end
workspace.DescendantAdded:Connect(disable)

local target = CFrame.new(spawnTop + Vector3.new(0, 4, 0))
local function onCharacter(character)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	character:PivotTo(target)
	-- Other scripts may move new characters to their own hub; win that race.
	for _, delay in { 0.5, 1.5, 3 } do
		task.delay(delay, function()
			if character.Parent and (root.Position - target.Position).Magnitude > 60 then
				character:PivotTo(target)
			end
		end)
	end
end
local function onPlayer(player)
	player.RespawnLocation = spawn
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end
print("[SpawnOnIsland] players spawn on " .. island:GetFullName())
