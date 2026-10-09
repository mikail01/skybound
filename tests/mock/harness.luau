-- Headless playtest: boots the real Skybound server + client code in the mock
-- engine, then checks stalls and the portal end to end.

local DT = 1 / 60
local failures = {}
local function check(cond, label)
	print((cond and "  PASS " or "  FAIL ") .. label)
	if not cond then
		table.insert(failures, label)
	end
end

-- Build the Rojo tree --------------------------------------------------------
local serverCtx = { name = "server", server = true, cache = {} }
R.serverContext = serverCtx
local byPath = {}
local function ensurePath(segments, className)
	local cur = game
	for i, seg in segments do
		local found = cur:FindFirstChild(seg)
		if not found then
			if i == 1 then
				found = game:GetService(seg)
			else
				local cls = if i == #segments then className or "Folder" else "Folder"
				found = R.newInstance(cls)
				rawget(found, "__p").Name = seg
				R.setParent(found, cur)
			end
		end
		cur = found
	end
	return cur
end
local clientEntries = {}
for _, e in ENTRIES do
	local segs = string.split(e.path, "/")
	if segs[1] == "StarterPlayer" then
		table.insert(clientEntries, e)
	end
	local inst = ensurePath(segs, e.class)
	if e.code then
		R.moduleSources[inst] = { code = e.code, path = e.file }
	end
	byPath[e.path] = inst
end

-- Server boot --------------------------------------------------------------------
print("== Boot server")
R.runScript(serverCtx, byPath["ServerScriptService/Server"])
for _ = 1, 30 do
	R.frame(DT)
end
check(workspace:FindFirstChild("Hub") ~= nil, "server built workspace.Hub")

-- Player join --------------------------------------------------------------------
print("== Player joins")
local Players = game:GetService("Players")
local player = R.newInstance("Player")
rawget(player, "__p").Name = "Tester"
rawget(player, "__p").UserId = 1001
local playerGui = R.newInstance("PlayerGui")
R.setParent(playerGui, player)
local playerScripts = R.newInstance("PlayerScripts")
R.setParent(playerScripts, player)
local playerModule = R.newInstance("ModuleScript")
rawget(playerModule, "__p").Name = "PlayerModule"
rawset(playerModule, "__mock", function()
	return {
		GetControls = function()
			return {
				Enable = function() end,
				Disable = function() end,
			}
		end,
	}
end)
R.setParent(playerModule, playerScripts)

local function makeCharacter(at)
	local character = R.newInstance("Model")
	rawget(character, "__p").Name = "Tester"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(at)
	root.Parent = character
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Parent = character
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	character.PrimaryPart = root
	character.Parent = workspace
	return character, root, humanoid
end

R.setParent(player, Players)
R.spawnIn(serverCtx, function()
	R.signalFor(Players, "PlayerAdded"):Fire(player)
end)
local spawn = workspace:FindFirstChild("HubSpawn", true)
local character, root = makeCharacter(spawn.Position + Vector3.new(0, 4, 0))
rawget(player, "__p").Character = character
R.signalFor(player, "CharacterAdded"):Fire(character)

-- Client boot ------------------------------------------------------------------------
print("== Boot client")
local clientCtx = { name = "client", server = false, player = player, cache = {} }
-- Clone the client LocalScript tree into PlayerScripts, keeping module sources.
local clientRoot = byPath["StarterPlayer/StarterPlayerScripts/Client"]
local function cloneWithSources(inst, parent)
	local copy = R.newInstance(rawget(inst, "__class"))
	rawget(copy, "__p").Name = rawget(inst, "__p").Name
	if R.moduleSources[inst] then
		R.moduleSources[copy] = R.moduleSources[inst]
	end
	R.setParent(copy, parent)
	for _, c in inst:GetChildren() do
		cloneWithSources(c, copy)
	end
	return copy
end
local clientScript = cloneWithSources(clientRoot, playerScripts)
R.runScript(clientCtx, clientScript)

local function physics(dt)
	R.stepPhysics(dt, { root }, R.collidables())
end
local function run(seconds)
	for _ = 1, math.floor(seconds / DT) do
		R.frame(DT, physics)
	end
end
run(3)

local errorsAfterBoot = #R.errors
check(errorsAfterBoot == 0, "no runtime errors after server + client boot (" .. errorsAfterBoot .. ")")

-- Helpers ------------------------------------------------------------------------------
local function serverModule(name)
	local inst = byPath["ServerScriptService/Server/Systems/" .. name]
	return serverCtx.cache[inst]
end
local PlayerData = serverModule("PlayerData")
local profile = PlayerData and PlayerData.get(player)
check(profile ~= nil, "server loaded a profile for the player")

local function findGui(name)
	return playerGui:FindFirstChild(name)
end
local function findDescendant(parent, pred)
	if not parent then
		return nil
	end
	for _, d in parent:GetDescendants() do
		if pred(d) then
			return d
		end
	end
	return nil
end
local function panelVisible(title)
	local panels = findGui("SkyboundPanels")
	local root = panels and panels:FindFirstChild("Root")
	local frame = root and root:FindFirstChild(title)
	return frame ~= nil and frame.Visible == true, frame
end
local function triggerStall(modelName)
	local hub = workspace:FindFirstChild("Hub")
	local model = hub and hub:FindFirstChild(modelName)
	local prompt = model and findDescendant(model, function(d)
		return d:IsA("ProximityPrompt")
	end)
	if not prompt then
		return false
	end
	R.spawnIn(clientCtx, function()
		R.signalFor(game:GetService("ProximityPromptService"), "PromptTriggered"):Fire(prompt, player)
	end)
	run(0.5)
	return true
end
local function clickButton(frame, labelText)
	local button = findDescendant(frame, function(d)
		if not d:IsA("TextButton") then
			return false
		end
		local face = d:FindFirstChild("Face")
		local label = face and face:FindFirstChild("Label")
		return label ~= nil and string.find(label.Text, labelText, 1, true) ~= nil
	end)
	if not button then
		return false
	end
	R.signalFor(button, "Activated"):Fire()
	run(0.5)
	return true
end

-- STALLS ---------------------------------------------------------------------------------
print("== Stalls")
check(findGui("SkyboundHud") ~= nil, "HUD ScreenGui exists")
check(findGui("SkyboundPanels") ~= nil, "Panels ScreenGui exists")

for _, stall in {
	{ model = "DailyStand", panel = "🎁 DAILY REWARDS" },
	{ model = "UpgradeStation", panel = "⬆ UPGRADES" },
	{ model = "GearStall", panel = "🎒 GEAR" },
	{ model = "SkybrewStall", panel = "🧪 SKYBREW POTIONS" },
} do
	local found = triggerStall(stall.model)
	check(found, stall.model .. " has a ProximityPrompt")
	local visible = panelVisible(stall.panel)
	check(visible, stall.model .. " prompt opens the " .. stall.panel .. " panel")
end

-- Daily claim
local coinsBefore = profile and profile.coins or 0
triggerStall("DailyStand")
local _, dailyFrame = panelVisible("🎁 DAILY REWARDS")
check(clickButton(dailyFrame, "CLAIM FREE"), "daily panel shows a CLAIM FREE button")
check(profile ~= nil and profile.coins > coinsBefore, "claiming the daily reward grants coins (" .. coinsBefore .. " -> " .. (profile and profile.coins or -1) .. ")")
check(profile ~= nil and (profile.potions.luck or 0) >= 2, "daily reward grants luck potions")

-- Free upgrade
triggerStall("UpgradeStation")
local _, upgradeFrame = panelVisible("⬆ UPGRADES")
local jumpBefore = profile and profile.upgrades.jumpPower or 0
check(clickButton(upgradeFrame, "FREE"), "upgrade panel shows the FREE first upgrade")
check(profile ~= nil and profile.upgrades.jumpPower == jumpBefore + 1, "buying an upgrade raises its level")

-- Potion buy + use
triggerStall("SkybrewStall")
local _, potionFrame = panelVisible("🧪 SKYBREW POTIONS")
local luckBefore = profile and profile.potions.luck or 0
check(clickButton(potionFrame, "USE"), "potion panel shows a USE button")
check(profile ~= nil and (profile.effects.luck or 0) > 0, "using a luck potion activates the effect")
check(profile ~= nil and profile.potions.luck == luckBefore - 1, "using a potion consumes one")
local coinsBeforeBuy = profile and profile.coins or 0
check(clickButton(potionFrame, "🪙"), "potion panel shows a coin BUY button")
check(profile ~= nil and profile.coins < coinsBeforeBuy, "buying a potion spends coins")

-- Gear equip
triggerStall("GearStall")
local _, gearFrame = panelVisible("🎒 GEAR")
check(clickButton(gearFrame, "EQUIP"), "gear panel shows EQUIP for the starter jetpack")
check(profile ~= nil and profile.gear.equipped == "jetpack_basic", "equipping sets the starter jetpack")

local errorsAfterStalls = #R.errors
check(errorsAfterStalls == 0, "no runtime errors during stall interactions (" .. errorsAfterStalls .. ")")

-- PORTAL -----------------------------------------------------------------------------------
print("== Portal")
local hub = workspace:FindFirstChild("Hub")
local trigger = hub and hub:FindFirstChild("PortalTrigger")
check(trigger ~= nil, "Hub.PortalTrigger exists")
R.signalFor(trigger, "Touched"):Fire(root)
run(0.3)
check(player:GetAttribute("InRun") == true, "touching the portal starts a run")
local Config = serverCtx.cache[byPath["ReplicatedStorage/Shared/Config"]]
local origin = Config.RUN_ORIGIN
local startY = root.Position.Y - origin.Y
check(math.abs(root.Position.X - origin.X) < 40, "player was moved to the run lane")
do
	local luckBefore = profile.potions.luck or 0
	local effectBefore = profile.effects.luck or 0
	local uis = game:GetService("UserInputService")
	R.spawnIn(clientCtx, function()
		R.signalFor(uis, "InputBegan"):Fire({ KeyCode = Enum.KeyCode.One, UserInputType = Enum.UserInputType.Keyboard }, false)
	end)
	run(0.5)
	check(luckBefore > 0 and profile.potions.luck == luckBefore - 1 and (profile.effects.luck or 0) > effectBefore, "key 1 uses a Luck Potion mid-run")
	local jet = player.Character and player.Character:FindFirstChild("RunJetpack")
	check(jet ~= nil, "equipped jetpack is visible on the climber")
end
local pad = workspace:FindFirstChild("RunPads") and findDescendant(workspace.RunPads, function(d)
	return d:IsA("BasePart") and d.CanCollide
end)
check(pad ~= nil, "a solid, collidable landing pad exists at the run destination")

-- Climb for 20s with a simple bot, then steer into a gap to fall. MODE picks
-- frame timing: steady 60 FPS, uneven 24-90 FPS, or 240 FPS render with
-- 60 Hz physics.
local MODE = MODE or "jitter"
R.jitter = MODE == "jitter"
R.highFps = if MODE == "fps240" then 240 else nil
local function platformsAround()
	local list = {}
	local localRunFolder = workspace:FindFirstChild("LocalRun")
	if localRunFolder then
		for _, chunk in localRunFolder:GetChildren() do
			for _, m in chunk:GetChildren() do
				if m:IsA("Model") and string.sub(m.Name, 1, 9) == "Platform_" and m.Name ~= "Platform_fake" then
					local pos = m:GetPivot().Position - origin
					table.insert(list, { x = pos.X, top = pos.Y + 1 })
				end
			end
		end
	end
	return list, localRunFolder
end
local maxRel, minRel = -math.huge, math.huge
local localRun = nil
local lastLand = 0
local prevVy = 0
local function tick()
	if R.highFps then
		for _ = 1, 4 do
			R.frame(DT, physics)
		end
	else
		R.frame(DT, physics)
	end
end
for _ = 1, math.floor(20 / DT) do
	local list, folder = platformsAround()
	localRun = folder or localRun
	local rel = root.Position - origin
	local vy = root.AssemblyLinearVelocity.Y
	if prevVy <= 0 and vy > 20 then
		lastLand = rel.Y - 3
	end
	prevVy = vy
	-- target: lowest platform comfortably above the one we last bounced on
	local target, targetTop = rel.X, math.huge
	for _, p in list do
		if p.top > lastLand + 1 and p.top < lastLand + 21 and p.top < targetTop then
			target, targetTop = p.x, p.top
		end
	end
	R.keysDown.A = target < rel.X - 1
	R.keysDown.D = target > rel.X + 1
	tick()
	rel = root.Position - origin
	maxRel = math.max(maxRel, rel.Y)
	if player:GetAttribute("InRun") ~= true then
		break
	end
	minRel = math.min(minRel, rel.Y)
end
R.keysDown.A, R.keysDown.D = false, false
R.jitter = false
R.highFps = nil
print(string.format("     climbed to %.0f studs above the start (started at %.1f, lowest %.1f)", maxRel, startY, minRel))
check(localRun ~= nil, "client rendered the run tower")
check(maxRel > 60, "player bounces upward through the tower instead of falling")
check(root.Position.Y > origin.Y - 100, "player never fell into the void below the run")

-- Steer into the widest gap below so the bot falls and the run ends.
for _ = 1, math.floor(15 / DT) do
	local list = platformsAround()
	local rel = root.Position - origin
	local bestX, bestScore = rel.X, -1
	for x = -28, 28, 2 do
		local score = math.huge
		for _, p in list do
			if p.top < rel.Y and p.top > rel.Y - 80 then
				score = math.min(score, math.abs(p.x - x))
			end
		end
		if score > bestScore then
			bestX, bestScore = x, score
		end
	end
	R.keysDown.A = bestX < rel.X - 1
	R.keysDown.D = bestX > rel.X + 1
	tick()
	if player:GetAttribute("InRun") ~= true then
		break
	end
end
R.keysDown.A, R.keysDown.D = false, false
R.jitter = false
R.highFps = nil
run(2)
check(player:GetAttribute("InRun") ~= true, "falling off ends the run")
local hud = findGui("SkyboundHud")
local results = hud and hud.Root:FindFirstChild("Results")
check(results ~= nil and results.Visible, "run results screen is shown")
check(results ~= nil and clickButton(results, "RETRY"), "RETRY button exists")
run(0.5)
check(player:GetAttribute("InRun") == true, "RETRY starts a new run")
-- End this run and go to hub
R.spawnIn(clientCtx, function()
	game:GetService("ReplicatedStorage").Remotes.EndRun:FireServer("fell")
end)
run(1.5)
check(results ~= nil and clickButton(results, "HUB"), "HUB button exists")
run(0.5)
check(player:GetAttribute("InRun") ~= true and math.abs(root.Position.X) < 100, "HUB returns the player to the hub island")

print("== Safety net: client never confirms the run")
local remotes = game:GetService("ReplicatedStorage").Remotes
local readySignal = R.signalFor(remotes.RunReady, "OnServerEvent")
local savedHandlers = readySignal.handlers
readySignal.handlers = {} -- server stops hearing RunReady, like a broken client
readySignal.queue = nil
R.signalFor(trigger, "Touched"):Fire(root)
run(0.5)
check(player:GetAttribute("InRun") == true, "portal starts a run")
run(7)
check(player:GetAttribute("InRun") ~= true, "server ends a run the client never confirmed")
check((root.Position - workspace.Hub.HubSpawn.Position).Magnitude < 20, "player is returned to the hub spawn, not left in the void")
readySignal.handlers = savedHandlers

print("== Client never starts the climb (e.g. a client script error)")
local startedSignal = R.signalFor(remotes.RunStarted, "OnClientEvent")
local savedClient = startedSignal.handlers
startedSignal.handlers = {}
startedSignal.queue = nil
local hubPos = workspace.Hub.HubSpawn.Position
R.signalFor(trigger, "Touched"):Fire(root)
local lowestY = math.huge
for _ = 1, math.floor(8 / DT) do
	R.frame(DT, physics)
	lowestY = math.min(lowestY, root.Position.Y)
end
check(lowestY > hubPos.Y - 10, "player never leaves the hub into the void when the client can't start")
check(player:GetAttribute("InRun") ~= true, "server cancels the unstarted run")
startedSignal.handlers = savedClient

print("== Portal works again afterwards")
R.signalFor(trigger, "Touched"):Fire(root)
run(3)
check(player:GetAttribute("InRun") == true and (root.Position - origin).Magnitude < 200, "a later portal entry starts the climb normally")

print("== Leave and rejoin")
local coinsAtLeave = profile.coins
local upgradesAtLeave = profile.upgrades.jumpPower
local tutorialAtLeave = profile.tutorial.step
local equippedAtLeave = profile.gear.equipped
R.spawnIn(serverCtx, function()
	R.signalFor(Players, "PlayerRemoving"):Fire(player)
end)
run(1)
R.setParent(player, nil)
character:Destroy()
run(1)
check(PlayerData.get(player) == nil, "profile is released when the player leaves")
local player2 = R.newInstance("Player")
rawget(player2, "__p").Name = "Tester"
rawget(player2, "__p").UserId = 1001
R.setParent(R.newInstance("PlayerGui"), player2)
R.setParent(player2, Players)
R.spawnIn(serverCtx, function()
	R.signalFor(Players, "PlayerAdded"):Fire(player2)
end)
run(2)
local profile2 = PlayerData.get(player2)
check(profile2 ~= nil, "profile loads again on rejoin")
check(profile2 ~= nil and profile2.coins == coinsAtLeave, "coins persist across rejoin (" .. coinsAtLeave .. ")")
check(profile2 ~= nil and profile2.upgrades.jumpPower == upgradesAtLeave, "upgrades persist across rejoin")
check(profile2 ~= nil and profile2.tutorial.step == tutorialAtLeave, "tutorial progress persists")
check(profile2 ~= nil and profile2.gear.equipped == equippedAtLeave, "equipped gear persists")
check(profile2 ~= nil and not ((R.stores["SkyboundData_v1"] or {}).__data or {})["__none"], "datastore record exists")

print("== Summary")
print(string.format("  runtime errors: %d, warnings: %d", #R.errors, #R.warnings))
for _, e in R.errors do
	print("   - " .. e)
end
if #failures == 0 and #R.errors == 0 then
	print("  ALL CHECKS PASSED")
else
	print(string.format("  %d CHECK(S) FAILED", #failures))
end
