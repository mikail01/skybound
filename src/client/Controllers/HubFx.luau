--!strict
-- Client-side hub ambience so the server never animates decoration:
-- spinning portal rings that speed up as you approach, bobbing gear
-- displays, the daily chest opening, and the upgrade machine lighting up.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Lib = script.Parent.Parent:WaitForChild("Lib")
local Bus = require(Lib.Bus)
local RunState = require(Lib.RunState)

local player = Players.LocalPlayer

local HubFx = {}

local hub: Instance? = nil
local rings: { { model: Model, base: CFrame, speed: number } } = {}
local bobbers: { { model: Model, base: CFrame } } = {}
local portalSurface: BasePart? = nil
local portalParticles: ParticleEmitter? = nil
local angle = 0
local t = 0

local function collect()
	local found = workspace:WaitForChild("Hub", 30)
	if not found then
		return
	end
	hub = found
	local portal = found:WaitForChild("Portal", 10)
	if portal then
		for _, child in portal:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("Spin") then
				table.insert(rings, {
					model = child,
					base = child:GetPivot(),
					speed = child:GetAttribute("Spin") :: number,
				})
			end
		end
		local surface = portal:FindFirstChild("Surface")
		if surface and surface:IsA("BasePart") then
			portalSurface = surface
			local emitter = surface:FindFirstChildWhichIsA("ParticleEmitter", true)
			portalParticles = emitter
		end
	end
	for _, d in found:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("Bob") then
			table.insert(bobbers, { model = d, base = d:GetPivot() })
		end
	end
end

local function step(dt: number)
	if RunState.active then
		return
	end
	t += dt
	-- Portal energy intensifies as the player approaches.
	local intensity = 0
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local surface = portalSurface
	if surface and hrp and hrp:IsA("BasePart") then
		local d = (hrp.Position - surface.Position).Magnitude
		intensity = math.clamp(1 - (d - 12) / 40, 0, 1)
		surface.Transparency = 0.25 - intensity * 0.15 + math.sin(t * 3) * 0.05
	end
	if portalParticles then
		portalParticles.Rate = 18 + intensity * 50
	end
	angle += dt * (1 + intensity * 2.5)
	for _, ring in rings do
		ring.model:PivotTo(ring.base * CFrame.Angles(0, 0, angle * ring.speed))
	end
	for i, bob in bobbers do
		bob.model:PivotTo(
			bob.base
				* CFrame.new(0, math.sin(t * 2 + i) * 0.4, 0)
				* CFrame.Angles(0, t * 0.8 + i, 0)
		)
	end
end

local function openChest()
	local lid = hub and hub:FindFirstChild("ChestLid", true)
	if not lid or not lid:IsA("BasePart") then
		return
	end
	local closed = lid:GetAttribute("ClosedCFrame")
	if typeof(closed) ~= "CFrame" then
		return
	end
	local open = closed * CFrame.new(0, 1.2, 1.4) * CFrame.Angles(math.rad(-70), 0, 0)
	TweenService:Create(
		lid,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ CFrame = open }
	):Play()
	-- Sparkle burst from the chest.
	local attachment = Instance.new("Attachment")
	attachment.Parent = lid
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Color = ColorSequence.new(Color3.fromRGB(255, 220, 80), Color3.fromRGB(255, 255, 255))
	sparkles.LightEmission = 1
	sparkles.Size = NumberSequence.new(0.7, 0)
	sparkles.Speed = NumberRange.new(8, 14)
	sparkles.SpreadAngle = Vector2.new(50, 50)
	sparkles.Lifetime = NumberRange.new(0.6, 1)
	sparkles.EmissionDirection = Enum.NormalId.Top
	sparkles.Enabled = false
	sparkles.Parent = attachment
	sparkles:Emit(40)
	task.delay(2.5, function()
		TweenService:Create(lid, TweenInfo.new(0.4), { CFrame = closed }):Play()
		attachment:Destroy()
	end)
end

local function flashUpgradeLights()
	local station = hub and hub:FindFirstChild("UpgradeStation")
	if not station then
		return
	end
	for i = 1, 4 do
		local light = station:FindFirstChild("Light" .. i)
		if light and light:IsA("BasePart") then
			task.delay(i * 0.08, function()
				light.Color = Color3.fromRGB(120, 255, 160)
				task.wait(1.2)
				TweenService
					:Create(light, TweenInfo.new(0.5), { Color = Color3.fromRGB(90, 90, 120) })
					:Play()
			end)
		end
	end
end

function HubFx.start()
	task.spawn(collect)
	RunService.RenderStepped:Connect(step)
	Bus.on("DailyClaimed", openChest)
	Bus.on("UpgradeBought", flashUpgradeLights)
end

return HubFx
