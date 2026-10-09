--!strict
-- Achievements and titles ("discover everything", "show off"). Progress comes
-- from server-side events only. Unlocking grants a one-time reward and, for
-- some, a title the player can wear; titles are shown above the character's
-- head for everyone (a server-created BillboardGui).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Formulas = require(Shared.Formulas)
local Types = require(Shared.Types)

local Net = require(script.Parent.Parent.Lib.Net)
local PlayerData = require(script.Parent.PlayerData)
local Analytics = require(script.Parent.Analytics)

local Achievements = {}

local TITLE_GUI = "SkyboundTitle"

local function valueOf(profile: Types.Profile, kind: string): number
	if kind == "bestHeight" then
		return profile.bestHeight
	elseif kind == "runs" then
		return profile.totalRuns
	elseif kind == "gear" then
		local count = 0
		for _, owned in profile.gear.owned do
			if owned then
				count += 1
			end
		end
		return count
	end
	return profile.stats[kind] or 0
end
Achievements.valueOf = valueOf

local function titleUnlocked(profile: Types.Profile, title: string): boolean
	for _, def in Config.Achievements do
		if def.title == title and profile.achievements[def.id] then
			return true
		end
	end
	return false
end

local function applyTitle(player: Player)
	local profile = PlayerData.get(player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not profile or not head or not head:IsA("BasePart") then
		return
	end
	local existing = head:FindFirstChild(TITLE_GUI)
	if existing then
		existing:Destroy()
	end
	local title = profile.title
	if not title then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = TITLE_GUI
	gui.Size = UDim2.fromOffset(220, 34)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.Adornee = head
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = title
	label.TextColor3 = Color3.fromRGB(255, 220, 90)
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(60, 45, 100)
	stroke.Parent = label
	gui.Parent = head
end

-- Re-evaluate every locked achievement for this player.
function Achievements.check(player: Player)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	for _, def in Config.Achievements do
		if not profile.achievements[def.id] and valueOf(profile, def.kind) >= def.target then
			profile.achievements[def.id] = true
			PlayerData.grant(player, def.reward)
			Analytics.event(player, "Achievement_" .. def.id)
			Net.fire(player, "AchievementUnlocked", {
				name = def.name,
				reward = Formulas.describeReward(def.reward),
				title = def.title,
			})
			print(string.format("[Skybound] %s unlocked achievement %s", player.Name, def.id))
		end
	end
	PlayerData.markDirty(player)
end

-- Count a gameplay event (capsules, rareCapsules, potions, quests...).
function Achievements.bump(player: Player, stat: string, amount: number?)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	profile.stats[stat] = (profile.stats[stat] or 0) + (amount or 1)
	Achievements.check(player)
end

function Achievements.start()
	PlayerData.onLoaded(function(player)
		-- Retroactive: players who already reached goals unlock them now.
		Achievements.check(player)
		applyTitle(player)
	end)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 10)
			applyTitle(player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 10)
			applyTitle(player)
		end)
	end

	Net.onInvoke("EquipTitle", 0.3, function(player, title: any)
		local profile = PlayerData.get(player)
		if not profile then
			return { ok = false }
		end
		if title == nil then
			profile.title = nil
		elseif typeof(title) == "string" and titleUnlocked(profile, title) then
			profile.title = title
		else
			return { ok = false, reason = "You haven't unlocked that title." }
		end
		applyTitle(player)
		PlayerData.syncNow(player)
		return { ok = true }
	end)
end

return Achievements
