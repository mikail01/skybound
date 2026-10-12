-- Headless check of tools/SpawnOnIsland.server.luau dropped into a foreign
-- game: its own spawn, a hub floor and a portal whose touch script
-- teleports players to a far-away climb.

local DT = 1 / 60
local failures = {}
local function check(cond, label)
	print((cond and "  PASS " or "  FAIL ") .. label)
	if not cond then
		table.insert(failures, label)
	end
end

local serverCtx = { name = "server", server = true, cache = {} }
R.serverContext = serverCtx
local Players = game:GetService("Players")

-- The other game ------------------------------------------------------------------
local hubFloor = Instance.new("Part")
hubFloor.Name = "Plaza"
hubFloor.Anchored = true
hubFloor.Size = Vector3.new(200, 2, 200)
hubFloor.CFrame = CFrame.new(0, -1, 0)
hubFloor.Parent = workspace
local oldSpawn = Instance.new("SpawnLocation")
oldSpawn.Name = "SpawnLocation"
oldSpawn.Anchored = true
oldSpawn.CFrame = CFrame.new(0, 0.5, 0)
oldSpawn.Parent = workspace
local portalModel = Instance.new("Model")
portalModel.Name = "Portal"
portalModel.Parent = workspace
local touch = Instance.new("Part")
touch.Name = "Trigger"
touch.Anchored = true
touch.CanCollide = false
touch.Size = Vector3.new(10, 12, 2)
touch.CFrame = CFrame.new(0, 6, -60)
touch.Parent = portalModel
-- Roblox adds this when a script listens to Touched; it can't be created.
local interest = R.newInstance("TouchTransmitter")
rawget(interest, "__p").Name = "TouchInterest"
R.setParent(interest, touch)
local TOWER = Vector3.new(5000, 100, 0)
local towerFloor = Instance.new("Part")
towerFloor.Name = "ClimbStart"
towerFloor.Anchored = true
towerFloor.Size = Vector3.new(40, 2, 40)
towerFloor.CFrame = CFrame.new(TOWER - Vector3.new(0, 4, 0))
towerFloor.Parent = workspace
touch.Touched:Connect(function(hit)
	local character = hit:FindFirstAncestorOfClass("Model")
	if character then
		character:PivotTo(CFrame.new(TOWER))
	end
end)

-- Drop the script in ------------------------------------------------------------
local script = Instance.new("Script")
script.Name = "SpawnOnIsland"
R.moduleSources[script] = { code = SCRIPT_SOURCE, path = "tools/SpawnOnIsland.server.luau" }
script.Parent = game:GetService("ServerScriptService")
R.runScript(serverCtx, script)
for _ = 1, 10 do
	R.frame(DT)
end

local island = workspace:FindFirstChild("SpawnIsland")
check(island ~= nil, "island is built when none was imported")
local spawn = workspace:FindFirstChild("IslandSpawn")
check(spawn ~= nil and spawn.Enabled, "island spawn exists")
check(oldSpawn.Enabled == false, "the game's own spawn is switched off")
local pitTrigger = workspace:FindFirstChild("IslandPitTrigger")
check(pitTrigger ~= nil, "the pit has a trigger")
check(
	pitTrigger ~= nil and (Vector3.new(touch.Position.X, 0, touch.Position.Z) - Vector3.new(pitTrigger.Position.X, 0, pitTrigger.Position.Z)).Magnitude < 5
		and touch.Position.Y < spawn.Position.Y,
	"the game's portal trigger moved into the pit"
)
local toPit = Vector3.new(pitTrigger.Position.X - spawn.Position.X, 0, pitTrigger.Position.Z - spawn.Position.Z)
check(toPit.Magnitude > 50 and spawn.CFrame.LookVector:Dot(toPit.Unit) > 0.95, "spawn is at the start of the path, facing the pit")

-- Player joins on the old spawn ------------------------------------------------------
local player = R.newInstance("Player")
rawget(player, "__p").Name = "Tester"
rawget(player, "__p").UserId = 7
R.setParent(R.newInstance("PlayerGui"), player)
R.setParent(player, Players)
R.spawnIn(serverCtx, function()
	R.signalFor(Players, "PlayerAdded"):Fire(player)
end)
local character = R.newInstance("Model")
rawget(character, "__p").Name = "Tester"
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.CFrame = CFrame.new(oldSpawn.Position + Vector3.new(0, 3, 0))
root.Parent = character
character.PrimaryPart = root
character.Parent = workspace
rawget(player, "__p").Character = character
R.signalFor(player, "CharacterAdded"):Fire(character)
local function physics(dt)
	R.stepPhysics(dt, { root }, R.collidables())
end
local function run(seconds)
	for _ = 1, math.floor(seconds / DT) do
		R.frame(DT, physics)
	end
end
run(1)
check(player.RespawnLocation == spawn, "players respawn on the island")
check((root.Position - spawn.Position).Magnitude < 10, "new character is on the island spawn")
check(player.PlayerGui:FindFirstChild("SpawnOnIslandNotice") ~= nil, "on-screen notice is shown")

-- The game moves the new character to its plaza a moment later ------------------------
character:PivotTo(CFrame.new(0, 3, 0))
run(1)
check((root.Position - spawn.Position).Magnitude < 10, "kept on the island when the game moves new characters")

-- Dropping into the pit starts the game's climb and the player stays there ----------
run(8)
R.spawnIn(serverCtx, function()
	R.signalFor(pitTrigger, "Touched"):Fire(root)
end)
run(0.1)
R.spawnIn(serverCtx, function()
	R.signalFor(touch, "Touched"):Fire(root)
end)
run(3)
check((root.Position - TOWER).Magnitude < 50, "jumping into the pit still starts the game's climb")

-- Run over: the game teleports the player back to its plaza --------------------------
run(5)
character:PivotTo(CFrame.new(10, 3, 10))
run(1)
check((root.Position - spawn.Position).Magnitude < 10, "back from a run lands on the island, not the old plaza")

print("== Summary")
for _, e in R.errors do
	print("   - " .. e)
end
if #failures == 0 and #R.errors == 0 then
	print("  ALL CHECKS PASSED")
else
	print(string.format("  %d CHECK(S) FAILED", #failures))
end
