--!strict
-- Startup self-check. A few seconds after boot it verifies the pieces the
-- core loop depends on and prints one clear report to the Output window, so
-- a Studio session immediately shows the build and anything misconfigured.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Build = require(Shared.Build)
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)

local PlayerData = require(script.Parent.PlayerData)

local Diagnostics = {}

export type Check = { name: string, ok: boolean, detail: string }

function Diagnostics.run(): { Check }
	local checks: { Check } = {}
	local function add(name: string, ok: boolean, detail: string)
		table.insert(checks, { name = name, ok = ok, detail = detail })
	end

	local hub = workspace:FindFirstChild("Hub")
	add("hub built", hub ~= nil, "workspace.Hub")
	local trigger = hub and hub:FindFirstChild("PortalTrigger")
	add(
		"portal trigger",
		trigger ~= nil and trigger:IsA("BasePart") and trigger.CanTouch,
		"Hub.PortalTrigger touchable"
	)
	local spawn = workspace:FindFirstChild("HubSpawn", true)
	add("hub spawn", spawn ~= nil and spawn:IsA("SpawnLocation"), "HubSpawn SpawnLocation")
	for _, name in { "DailyStand", "UpgradeStation", "GearStall", "SkybrewStall", "QuestBoard" } do
		local model = hub and hub:FindFirstChild(name)
		local prompt = model and model:FindFirstChildWhichIsA("ProximityPrompt", true)
		add("stall " .. name, prompt ~= nil, "has a ProximityPrompt")
	end
	add(
		"streaming off",
		not workspace.StreamingEnabled,
		if workspace.StreamingEnabled
			then "Workspace.StreamingEnabled is ON - the Rojo project should turn it off; is Rojo synced?"
			else "Workspace.StreamingEnabled = false"
	)
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local expected = #Remotes.Events + #Remotes.Functions
	local count = if folder then #folder:GetChildren() else 0
	add("remotes", count == expected, string.format("%d/%d remotes created", count, expected))
	add(
		"saving",
		PlayerData.savingEnabled(),
		if PlayerData.savingEnabled()
			then "DataStores reachable"
			else "DataStores unavailable - progress will NOT save (enable Studio API access)"
	)
	add(
		"run lane origin",
		Config.RUN_ORIGIN.Y > workspace.FallenPartsDestroyHeight + 200,
		"run lanes above the kill plane"
	)
	return checks
end

function Diagnostics.start()
	task.delay(3, function()
		local checks = Diagnostics.run()
		local failed = 0
		for _, check in checks do
			if not check.ok then
				failed += 1
				warn(
					string.format("[Skybound] self-check FAILED: %s (%s)", check.name, check.detail)
				)
			end
		end
		if failed == 0 then
			print(
				string.format(
					"[Skybound] self-check passed: %d/%d checks, build %s",
					#checks,
					#checks,
					Build.ID
				)
			)
		else
			warn(
				string.format(
					"[Skybound] self-check: %d of %d checks failed, build %s",
					failed,
					#checks,
					Build.ID
				)
			)
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("ServerBuild", Build.ID)
	end)
end

return Diagnostics
