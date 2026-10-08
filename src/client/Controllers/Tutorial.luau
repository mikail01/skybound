--!strict
-- World-space onboarding guidance. While the hub tutorial is active it shows:
--   * a big bouncing arrow + label above the current objective,
--   * a glowing ring on the ground at the objective,
--   * a chevron at the player's feet pointing the way (hidden once close).
-- Only one objective is ever marked, and everything disappears once the
-- tutorial is done, so the hub never gets cluttered with arrows.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local Lib = script.Parent.Parent:WaitForChild("Lib")
local Bus = require(Lib.Bus)
local RunState = require(Lib.RunState)
local State = require(Lib.State)
local UI = require(Lib.UI)

local player = Players.LocalPlayer
local GUIDE_COLOR = Color3.fromRGB(255, 220, 70)
local CLOSE_ENOUGH = 14

local Tutorial = {}

local folder: Folder? = nil
local marker: Part? = nil
local ring: Part? = nil
local chevron: Model? = nil
local label: TextLabel? = nil
local currentTarget: Model? = nil
local t = 0

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = GUIDE_COLOR
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function build()
	local f = Instance.new("Folder")
	f.Name = "TutorialGuide"
	f.Parent = workspace
	folder = f

	local m = part({ Name = "Marker", Size = Vector3.one, Transparency = 1 }, f)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(360, 190)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = m
	label = UI.label({
		Text = "",
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundTransparency = 0.1,
		BackgroundColor3 = UI.Theme.dark,
		MaxText = 30,
		Parent = gui,
	})
	UI.corner(28).Parent = label :: any
	UI.padding(8).Parent = label :: any
	UI.label({
		Text = "⬇",
		Size = UDim2.new(1, 0, 0, 120),
		Position = UDim2.fromOffset(0, 62),
		TextColor3 = GUIDE_COLOR,
		MaxText = 120,
		Parent = gui,
	})
	marker = m

	ring = part({
		Name = "Ring",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 12, 12),
		Transparency = 0.45,
	}, f)

	local c = Instance.new("Model")
	c.Name = "Chevron"
	local pivot = part({ Name = "Pivot", Size = Vector3.one * 0.2, Transparency = 1 }, c)
	c.PrimaryPart = pivot
	for _, side in { -1, 1 } do
		local arm = part({ Name = "Arm", Size = Vector3.new(0.6, 0.3, 3.2) }, c)
		arm.CFrame = CFrame.new(side * 0.9, 0, 0.7) * CFrame.Angles(0, math.rad(side * -40), 0)
	end
	-- Store arm offsets relative to the pivot so PivotTo keeps the shape.
	pivot.CFrame = CFrame.new()
	c.WorldPivot = CFrame.new()
	c.Parent = f
	chevron = c
end

local function destroy()
	if folder then
		folder:Destroy()
	end
	folder, marker, ring, chevron, label, currentTarget = nil, nil, nil, nil, nil, nil
end

local function targetFor(step: number): (Model?, string?)
	local def = Config.TutorialSteps[step]
	local hub = workspace:FindFirstChild("Hub")
	if not def or not hub then
		return nil, nil
	end
	local target = hub:FindFirstChild(def.target)
	if target and target:IsA("Model") then
		return target, def.text
	end
	return nil, nil
end

local function update(dt: number)
	t += dt
	local profile = State.profile()
	local step = if profile then profile.tutorial.step else 99
	local target, text = targetFor(step)
	if not target or RunState.active then
		if folder then
			destroy()
		end
		return
	end
	if not folder then
		build()
	end
	if target ~= currentTarget then
		currentTarget = target
		if label then
			label.Text = text or ""
			UI.pop(label, 0.3)
		end
	end
	local pivot = target:GetPivot().Position
	local groundY = Config.HUB_CENTER.Y + 0.15
	if marker then
		marker.CFrame = CFrame.new(pivot.X, pivot.Y + 16 + math.sin(t * 3) * 1.2, pivot.Z)
	end
	if ring then
		local pulse = 1 + math.sin(t * 4) * 0.08
		ring.Size = Vector3.new(0.2, 13 * pulse, 13 * pulse)
		ring.CFrame = CFrame.new(pivot.X, groundY, pivot.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if chevron and hrp and hrp:IsA("BasePart") then
		local from = Vector3.new(hrp.Position.X, groundY + 0.3, hrp.Position.Z)
		local flatTarget = Vector3.new(pivot.X, from.Y, pivot.Z)
		local distance = (flatTarget - from).Magnitude
		local show = distance > CLOSE_ENOUGH
		for _, child in chevron:GetChildren() do
			if child:IsA("BasePart") and child.Name == "Arm" then
				child.Transparency = if show then 0.1 else 1
			end
		end
		if show then
			local dir = (flatTarget - from).Unit
			local ahead = from + dir * (4 + math.sin(t * 5) * 0.6)
			chevron:PivotTo(CFrame.lookAt(ahead, ahead - dir))
		end
	end
end

function Tutorial.start()
	RunService.RenderStepped:Connect(update)
	Bus.on("RunBegan", destroy)
end

return Tutorial
