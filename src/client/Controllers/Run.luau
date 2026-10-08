--!strict
-- The climb. Owns everything during a run on the client:
--   * input (keyboard, gamepad, dedicated touch zones),
--   * the auto-jump character controller (one-way platforms, custom
--     gravity, jetpack thrust, black-hole pull),
--   * rendering/recycling the deterministic chunks from Shared/Generator,
--   * pickup collection requests, hazards, death, side-view camera,
--   * world transitions (lighting + title).
-- The server independently validates height and pickups.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Formulas = require(Shared.Formulas)
local Generator = require(Shared.Generator)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local Lib = script.Parent.Parent:WaitForChild("Lib")
local Bus = require(Lib.Bus)
local RunState = require(Lib.RunState)
local State = require(Lib.State)
local UI = require(Lib.UI)

local M = Config.Movement
local H = Config.Generation.CHUNK_HEIGHT
local HALF = Config.RUN_HALF_WIDTH
local HAZ = Config.Hazards
local PLATFORM_THICKNESS = 2
local PLATFORM_DEPTH = 6

local player = Players.LocalPlayer

local Run = {}

type PlatformView = {
	data: Types.PlatformData,
	model: Model,
	x: number,
	squash: number,
	gone: boolean,
}

type PickupView = {
	data: Types.PickupData,
	part: BasePart,
	collected: boolean,
	x: number,
	y: number,
}

type HazardView = {
	data: Types.HazardData,
	model: Model,
	x: number,
	gone: boolean,
}

type ChunkView = {
	index: number,
	folder: Folder,
	platforms: { PlatformView },
	pickups: { PickupView },
	hazards: { HazardView },
	prompts: { { y: number, text: string } },
}

-- Run state ------------------------------------------------------------------
local info: Types.RunInfo? = nil
local active = false
local chunks: { [number]: ChunkView } = {}
local runFolder: Folder? = nil
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local vx, vy = 0, 0
local camY = 0
local maxY = 0
local fuel = 0
local iceTimer = 0
local elapsed = 0
local shieldCharges = 0
local promptIndex = 0
local worldIndex = 1
local coinMultiplier = 1
local magnet = false
local bounceKick = 0
local antiGravity: VectorForce? = nil
local align: AlignOrientation? = nil
local renderConnection: RBXScriptConnection? = nil

-- Input ------------------------------------------------------------------------
local touchLeft = false
local touchRight = false
local touchBoost = false
local gamepadX = 0
local gamepadBoost = false

local function inputAxis(): number
	local axis = 0
	if
		UserInputService:IsKeyDown(Enum.KeyCode.A)
		or UserInputService:IsKeyDown(Enum.KeyCode.Left)
		or UserInputService:IsKeyDown(Enum.KeyCode.DPadLeft)
		or touchLeft
	then
		axis -= 1
	end
	if
		UserInputService:IsKeyDown(Enum.KeyCode.D)
		or UserInputService:IsKeyDown(Enum.KeyCode.Right)
		or UserInputService:IsKeyDown(Enum.KeyCode.DPadRight)
		or touchRight
	then
		axis += 1
	end
	if math.abs(gamepadX) > 0.2 then
		axis += gamepadX
	end
	return math.clamp(axis, -1, 1)
end

local function boostHeld(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.Space)
		or UserInputService:IsKeyDown(Enum.KeyCode.W)
		or UserInputService:IsKeyDown(Enum.KeyCode.Up)
		or touchBoost
		or gamepadBoost
end

UserInputService.InputChanged:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		gamepadX = input.Position.X
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		gamepadBoost = input.Position.Z > 0.3
	end
end)
UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.ButtonA then
		gamepadBoost = true
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.ButtonA then
		gamepadBoost = false
	elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
		gamepadX = 0
	end
end)

-- Touch zones are owned by the HUD; it reports their state through the bus.
Bus.on("TouchInput", function(left: boolean, right: boolean, boost: boolean)
	touchLeft, touchRight, touchBoost = left, right, boost
end)

-- Default controls -------------------------------------------------------------
local controls: any = nil
local function setDefaultControls(enabled: boolean)
	if not controls then
		local ok, module = pcall(function()
			local playerModule = (player :: any)
				:WaitForChild("PlayerScripts")
				:WaitForChild("PlayerModule")
			return (require :: any)(playerModule):GetControls()
		end)
		if ok then
			controls = module
		end
	end
	if controls then
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

-- Visual builders ------------------------------------------------------------------
local function newPart(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function buildPlatform(data: Types.PlatformData, parent: Instance, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Platform_" .. data.kind
	local def = Config.Platforms[data.kind]
	local color = if data.kind == "normal" or data.kind == "fake"
		then Formulas.worldForHeight(data.y * Config.METERS_PER_STUD).platformColor
		else def.color
	local center = origin + Vector3.new(data.x, data.y - PLATFORM_THICKNESS / 2, 0)
	local bodyLength = math.max(1, data.width - PLATFORM_THICKNESS)
	local body = newPart({
		Name = "Body",
		Size = Vector3.new(bodyLength, PLATFORM_THICKNESS, PLATFORM_DEPTH),
		CFrame = CFrame.new(center),
		Color = UI.darker(color, 0.12),
	}, model)
	for _, side in { -1, 1 } do
		newPart({
			Name = "Cap",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(PLATFORM_DEPTH, PLATFORM_THICKNESS, PLATFORM_THICKNESS),
			CFrame = CFrame.new(center + Vector3.new(side * bodyLength / 2, 0, 0))
				* CFrame.Angles(0, math.rad(90), 0),
			Color = UI.darker(color, 0.12),
		}, model)
	end
	newPart({
		Name = "Top",
		Size = Vector3.new(data.width - 0.4, 0.5, PLATFORM_DEPTH + 0.3),
		CFrame = CFrame.new(center + Vector3.new(0, PLATFORM_THICKNESS / 2, 0)),
		Color = color:Lerp(Color3.new(1, 1, 1), 0.15),
	}, model)
	if data.kind == "bounce" then
		local pad = newPart({
			Name = "Pad",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.8, math.min(6, data.width * 0.6), math.min(6, data.width * 0.6)),
			CFrame = CFrame.new(center + Vector3.new(0, PLATFORM_THICKNESS / 2 + 0.5, 0))
				* CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(255, 240, 250),
			Material = Enum.Material.Neon,
		}, model)
		pad.Transparency = 0.1
	elseif data.kind == "breaking" then
		for i = -1, 1 do
			newPart({
				Name = "Crack",
				Size = Vector3.new(0.3, PLATFORM_THICKNESS + 0.1, PLATFORM_DEPTH + 0.4),
				CFrame = CFrame.new(center + Vector3.new(i * data.width / 4, 0, 0))
					* CFrame.Angles(0, 0, math.rad(15 * i + 8)),
				Color = Color3.fromRGB(110, 75, 50),
			}, model)
		end
	elseif data.kind == "ice" then
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") then
				child.Material = Enum.Material.Glass
				child.Transparency = 0.15
			end
		end
	elseif data.kind == "moving" then
		for _, side in { -1, 1 } do
			newPart({
				Name = "Arrow",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one * 1.1,
				CFrame = CFrame.new(
					center + Vector3.new(side * (data.width / 2 - 1.5), 0, -PLATFORM_DEPTH / 2)
				),
				Color = Color3.new(1, 1, 1),
				Material = Enum.Material.Neon,
			}, model)
		end
	elseif data.kind == "fake" then
		-- Readable tell: fake platforms are slightly see-through and shimmer.
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") then
				child.Transparency = 0.35
			end
		end
	end
	model.PrimaryPart = body
	model.Parent = parent
	return model
end

local function buildPickup(data: Types.PickupData, parent: Instance, origin: Vector3): BasePart
	local pos = origin + Vector3.new(data.x, data.y, 0)
	if data.kind == "coin" then
		local coin = newPart({
			Name = "Coin",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, 2.6, 2.6),
			CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(90), 0),
			Color = if data.risky
				then Color3.fromRGB(255, 140, 60)
				else Color3.fromRGB(255, 205, 60),
			Material = Enum.Material.SmoothPlastic,
		}, parent)
		return coin
	elseif data.kind == "gem" then
		local gem = newPart({
			Name = "Gem",
			Size = Vector3.one * 2,
			CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(45)),
			Color = Color3.fromRGB(110, 220, 255),
			Material = Enum.Material.Neon,
		}, parent)
		return gem
	elseif data.kind == "potion" then
		local def = if data.potion then Formulas.potion(data.potion) else nil
		local bottle = newPart({
			Name = "Potion",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 2.4,
			CFrame = CFrame.new(pos),
			Color = if def then def.color else Color3.new(1, 1, 1),
			Material = Enum.Material.Glass,
			Transparency = 0.1,
		}, parent)
		newPart({
			Name = "Neck",
			Size = Vector3.new(0.8, 1, 0.8),
			CFrame = CFrame.new(pos + Vector3.new(0, 1.5, 0)),
			Color = Color3.fromRGB(150, 100, 64),
		}, bottle)
		return bottle
	end
	-- Capsule.
	local capsule = newPart({
		Name = "Capsule",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 3.2,
		CFrame = CFrame.new(pos),
		Color = Color3.fromRGB(200, 120, 255),
		Material = Enum.Material.Neon,
	}, parent)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(60, 60)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Parent = capsule
	UI.label({ Text = "?", Size = UDim2.fromScale(1, 1), Parent = gui })
	return capsule
end

local function buildHazard(data: Types.HazardData, parent: Instance, origin: Vector3): Model
	local model = Instance.new("Model")
	local pos = origin + Vector3.new(data.x, data.y, 0)
	if data.kind == "spike" then
		model.Name = "SpikeBall"
		local core = newPart({
			Name = "Core",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * data.radius * 2,
			CFrame = CFrame.new(pos),
			Color = Color3.fromRGB(90, 70, 110),
		}, model)
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			newPart({
				Name = "Spike",
				Size = Vector3.one * 1.3,
				CFrame = CFrame.new(pos + Vector3.new(math.cos(a), math.sin(a), 0) * data.radius)
					* CFrame.Angles(0, 0, a + math.rad(45)),
				Color = Color3.fromRGB(255, 80, 90),
			}, model)
		end
		model.PrimaryPart = core
	else
		model.Name = "BlackHole"
		local core = newPart({
			Name = "Core",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * data.radius * 2,
			CFrame = CFrame.new(pos),
			Color = Color3.fromRGB(10, 5, 20),
		}, model)
		local disc = newPart({
			Name = "Disc",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, data.radius * 5, data.radius * 5),
			CFrame = CFrame.new(pos - Vector3.new(0, 0, 0.5)) * CFrame.Angles(0, math.rad(90), 0),
			Color = Color3.fromRGB(150, 70, 255),
			Material = Enum.Material.Neon,
			Transparency = 0.35,
		}, model)
		newPart({
			Name = "Pull",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, HAZ.BLACK_HOLE_PULL_RADIUS * 2, HAZ.BLACK_HOLE_PULL_RADIUS * 2),
			CFrame = CFrame.new(pos - Vector3.new(0, 0, 1.5)) * CFrame.Angles(0, math.rad(90), 0),
			Color = Color3.fromRGB(120, 60, 200),
			Transparency = 0.88,
		}, model)
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			newPart({
				Name = "Orbit",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one * (0.8 + (i % 3) * 0.4),
				CFrame = CFrame.new(
					pos
						+ Vector3.new(math.cos(a), math.sin(a), 0)
							* data.radius
							* (1.8 + (i % 2) * 0.8)
				),
				Color = if i % 2 == 0
					then Color3.fromRGB(200, 150, 255)
					else Color3.fromRGB(120, 110, 140),
				Material = Enum.Material.Neon,
			}, model)
		end
		local attachment = Instance.new("Attachment")
		attachment.Parent = disc
		local swirl = Instance.new("ParticleEmitter")
		swirl.Color = ColorSequence.new(Color3.fromRGB(210, 160, 255))
		swirl.LightEmission = 1
		swirl.Size = NumberSequence.new(0.6, 0)
		swirl.Lifetime = NumberRange.new(0.8, 1.2)
		swirl.Rate = 14
		swirl.Speed = NumberRange.new(-14, -10)
		swirl.SpreadAngle = Vector2.new(180, 180)
		swirl.Shape = Enum.ParticleEmitterShape.Sphere
		swirl.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		swirl.Parent = attachment
		model.PrimaryPart = core
	end
	model.Parent = parent
	return model
end

local function buildScenery(index: number, parent: Instance, origin: Vector3)
	local rng = Random.new(index * 7 + 3)
	local world = Formulas.worldForHeight(index * H * Config.METERS_PER_STUD)
	for _ = 1, 4 do
		local base = origin
			+ Vector3.new(
				rng:NextNumber(-HALF - 30, HALF + 30),
				index * H + rng:NextNumber(0, H),
				rng:NextNumber(-60, -25)
			)
		for k = 0, 3 do
			newPart({
				Name = "Cloud",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one * rng:NextNumber(6, 11),
				CFrame = CFrame.new(base + Vector3.new((k - 1.5) * 4.5, rng:NextNumber(0, 2), 0)),
				Color = world.accentColor:Lerp(Color3.new(1, 1, 1), 0.7),
				Transparency = 0.15,
			}, parent)
		end
	end
	-- Side rails: subtle pillars marking the playable edges.
	for _, side in { -1, 1 } do
		newPart({
			Name = "Rail",
			Size = Vector3.new(1, H, 1),
			CFrame = CFrame.new(origin + Vector3.new(side * (HALF + 2.5), index * H + H / 2, -4)),
			Color = world.accentColor,
			Material = Enum.Material.Neon,
			Transparency = 0.75,
		}, parent)
	end
end

local function renderChunk(index: number)
	local runInfo = info
	local folder = runFolder
	if chunks[index] or index < 0 or not runInfo or not folder then
		return
	end
	local data = Generator.chunk(runInfo.seed, index, runInfo.tutorial)
	local chunkFolder = Instance.new("Folder")
	chunkFolder.Name = "Chunk" .. index
	local view: ChunkView = {
		index = index,
		folder = chunkFolder,
		platforms = {},
		pickups = {},
		hazards = {},
		prompts = data.prompts,
	}
	for _, p in data.platforms do
		table.insert(view.platforms, {
			data = p,
			model = buildPlatform(p, chunkFolder, runInfo.origin),
			x = p.x,
			squash = 0,
			gone = false,
		})
	end
	for _, p in data.pickups do
		table.insert(view.pickups, {
			data = p,
			part = buildPickup(p, chunkFolder, runInfo.origin),
			collected = false,
			x = p.x,
			y = p.y,
		})
	end
	for _, h in data.hazards do
		table.insert(view.hazards, {
			data = h,
			model = buildHazard(h, chunkFolder, runInfo.origin),
			x = h.x,
			gone = false,
		})
	end
	buildScenery(index, chunkFolder, runInfo.origin)
	chunkFolder.Parent = folder
	chunks[index] = view
end

local function updateChunks(relY: number)
	local current = math.floor(relY / H)
	for i = current - Config.Generation.CHUNKS_BEHIND, current + Config.Generation.CHUNKS_AHEAD do
		renderChunk(i)
	end
	for index, view in chunks do
		if index < current - Config.Generation.CHUNKS_BEHIND then
			view.folder:Destroy()
			chunks[index] = nil
		end
	end
end

-- Effects ----------------------------------------------------------------------
local function burst(position: Vector3, color: Color3, count: number)
	local folder = runFolder
	if not folder then
		return
	end
	for _ = 1, count do
		local bit = newPart({
			Name = "Fx",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 0.7,
			CFrame = CFrame.new(position),
			Color = color,
			Material = Enum.Material.Neon,
		}, folder)
		local dir =
			Vector3.new(math.random() - 0.5, math.random() - 0.3, (math.random() - 0.5) * 0.3).Unit
		local tween = TweenService:Create(
			bit,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				CFrame = CFrame.new(position + dir * 4),
				Size = Vector3.one * 0.05,
				Transparency = 1,
			}
		)
		tween:Play()
		tween.Completed:Once(function()
			bit:Destroy()
		end)
	end
end

local function breakPlatform(view: PlatformView)
	view.gone = true
	for _, child in view.model:GetChildren() do
		if child:IsA("BasePart") then
			local drop = child.CFrame
				* CFrame.new(math.random(-2, 2), -12, 0)
				* CFrame.Angles(math.random(), 0, math.random())
			local tween = TweenService:Create(
				child,
				TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{
					CFrame = drop,
					Transparency = 1,
				}
			)
			tween:Play()
		end
	end
	task.delay(0.7, function()
		view.model:Destroy()
	end)
end

local function poofPlatform(view: PlatformView)
	view.gone = true
	local pos = view.model:GetPivot().Position
	burst(pos, Color3.new(1, 1, 1), 10)
	view.model:Destroy()
end

local function setLightingForWorld(world: Config.WorldDef, instant: boolean)
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	local time = if instant then 0 else 2.5
	if atmosphere then
		TweenService:Create(atmosphere, TweenInfo.new(time), {
			Color = world.fogColor,
			Decay = world.skyTop,
		}):Play()
	end
	local grade = Lighting:FindFirstChild("SkyboundGrade")
	if grade and grade:IsA("ColorCorrectionEffect") then
		TweenService:Create(grade, TweenInfo.new(time), {
			TintColor = Color3.new(1, 1, 1):Lerp(world.skyBottom, 0.15),
		}):Play()
	end
end

local hubAtmosphere: { Color: Color3, Decay: Color3 }? = nil
local function restoreHubLighting()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere and hubAtmosphere then
		atmosphere.Color = hubAtmosphere.Color
		atmosphere.Decay = hubAtmosphere.Decay
	end
	local grade = Lighting:FindFirstChild("SkyboundGrade")
	if grade and grade:IsA("ColorCorrectionEffect") then
		grade.TintColor = Color3.new(1, 1, 1)
	end
end

-- Character ----------------------------------------------------------------------
local function setupCharacter(): boolean
	local character = player.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not hum then
		return false
	end
	root = hrp
	humanoid = hum
	for _, name in { "RunAntiGravity", "RunAlign" } do
		local old = hrp:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	hum.PlatformStand = true
	hum.AutoRotate = false
	local attachment = hrp:FindFirstChild("RunAttachment") :: Attachment?
	if not attachment then
		local a = Instance.new("Attachment")
		a.Name = "RunAttachment"
		a.Parent = hrp
		attachment = a
	end
	local force = Instance.new("VectorForce")
	force.Name = "RunAntiGravity"
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Attachment0 = attachment
	force.Parent = hrp
	antiGravity = force
	local orient = Instance.new("AlignOrientation")
	orient.Name = "RunAlign"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.RigidityEnabled = true
	orient.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, 1))
	orient.Parent = hrp
	align = orient
	return true
end

local function releaseCharacter()
	if antiGravity then
		antiGravity:Destroy()
		antiGravity = nil
	end
	if align then
		align:Destroy()
		align = nil
	end
	local hum = humanoid
	if hum and hum.Parent then
		hum.PlatformStand = false
		hum.AutoRotate = true
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

-- Lifecycle ------------------------------------------------------------------------
local function clearWorld()
	if runFolder then
		runFolder:Destroy()
		runFolder = nil
	end
	chunks = {}
end

local function stopLoop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function die(reason: string)
	if not active then
		return
	end
	active = false
	RunState.active = false
	stopLoop()
	UI.playSound(Config.Sounds.Death, 0.5)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		burst(root.Position, Color3.fromRGB(255, 255, 255), 14)
	end
	Remotes.event("EndRun"):FireServer(reason)
	Bus.fire("RunDied", reason)
end

local function collect(chunk: ChunkView, view: PickupView)
	view.collected = true
	local pos = view.part.Position
	Remotes.event("CollectPickup"):FireServer(chunk.index, view.data.id)
	if view.data.kind == "coin" then
		RunState.coins += view.data.value * coinMultiplier
		burst(pos, Color3.fromRGB(255, 215, 80), 4)
		UI.playSound(Config.Sounds.Coin, 0.25, 1.2 + math.random() * 0.2)
		Bus.fire("CoinCollected")
	elseif view.data.kind == "gem" then
		RunState.gems += 1
		burst(pos, Color3.fromRGB(110, 220, 255), 10)
		UI.playSound(Config.Sounds.Reward, 0.4, 1.5)
	elseif view.data.kind == "potion" then
		burst(pos, view.part.Color, 10)
		UI.playSound(Config.Sounds.Reward, 0.4, 0.9)
		local def = if view.data.potion then Formulas.potion(view.data.potion) else nil
		if def then
			Bus.fire("Toast", "+1 " .. def.name, def.color)
		end
	else
		burst(pos, Color3.fromRGB(220, 150, 255), 16)
		UI.playSound(Config.Sounds.Reward, 0.5, 0.7)
	end
	view.part:Destroy()
end

local function step(dt: number)
	local runInfo = info
	local hrp = root
	if not active or not runInfo or not hrp or not hrp.Parent then
		return
	end
	dt = math.min(dt, 1 / 20)
	elapsed += dt
	local origin = runInfo.origin
	local rel = hrp.Position - origin
	local hum = humanoid
	local footOffset = if hum and hum.RigType == Enum.HumanoidRigType.R15
		then hum.HipHeight + hrp.Size.Y / 2
		else hrp.Size.Y / 2 + 2
	local footY = rel.Y - footOffset

	-- Horizontal.
	local axis = inputAxis()
	local accel = M.AIR_ACCEL * runInfo.airMultiplier * (if iceTimer > 0 then 0.25 else 1)
	iceTimer = math.max(0, iceTimer - dt)
	local target = axis * M.MOVE_SPEED
	if vx < target then
		vx = math.min(target, vx + accel * dt)
	else
		vx = math.max(target, vx - accel * dt)
	end

	-- Vertical: custom gravity + jetpack.
	vy -= M.GRAVITY * dt
	local boosting = false
	if runInfo.hasJetpack and boostHeld() and fuel > 0 then
		boosting = true
		fuel = math.max(0, fuel - dt)
		if vy < runInfo.maxRise then
			vy = math.min(runInfo.maxRise, vy + (runInfo.thrust + M.GRAVITY) * dt)
		end
	end
	RunState.boosting = boosting

	-- Hazards.
	for _, chunk in chunks do
		for _, hz in chunk.hazards do
			if not hz.gone then
				local hx = hz.data.x
				if hz.data.moveRange > 0 then
					hx += math.sin(elapsed * hz.data.moveSpeed + hz.data.phase) * hz.data.moveRange
					if hx ~= hz.x then
						hz.model:PivotTo(CFrame.new(origin + Vector3.new(hx, hz.data.y, 0)))
						hz.x = hx
					end
				end
				local offset = Vector3.new(hx - rel.X, hz.data.y - rel.Y, 0)
				local dist = offset.Magnitude
				if hz.data.kind == "blackhole" then
					if dist < HAZ.BLACK_HOLE_PULL_RADIUS and dist > 0.01 then
						local pull = HAZ.BLACK_HOLE_STRENGTH
							* (1 - dist / HAZ.BLACK_HOLE_PULL_RADIUS)
							* (1 - runInfo.voidResistance)
						local dir = offset.Unit
						vx += dir.X * pull * dt
						vy += dir.Y * pull * dt
						Bus.fire("BlackHoleNear", 1 - dist / HAZ.BLACK_HOLE_PULL_RADIUS)
					end
					if dist < hz.data.radius + 1 then
						if shieldCharges > 0 then
							shieldCharges -= 1
							Remotes.event("ShieldUsed"):FireServer()
							vy = M.JUMP_VELOCITY * 1.4
							Bus.fire("Toast", "SHIELD SAVED YOU!", Color3.fromRGB(170, 140, 255))
						else
							die("hazard")
							return
						end
					end
				elseif dist < hz.data.radius + 1.6 then
					if shieldCharges > 0 then
						shieldCharges -= 1
						hz.gone = true
						burst(hz.model:GetPivot().Position, Color3.fromRGB(255, 90, 90), 14)
						hz.model:Destroy()
						Remotes.event("ShieldUsed"):FireServer()
						vy = math.max(vy, M.JUMP_VELOCITY)
						Bus.fire("Toast", "SHIELD SAVED YOU!", Color3.fromRGB(170, 140, 255))
					else
						die("hazard")
						return
					end
				end
			end
		end
	end

	vy = math.max(vy, -M.MAX_FALL_SPEED)

	-- Platforms: one-way, bounce when falling through the top surface.
	local nextFoot = footY + vy * dt
	local bounced = false
	if vy <= 0 then
		for _, chunk in chunks do
			if bounced then
				break
			end
			for _, view in chunk.platforms do
				if not view.gone then
					local top = view.data.y
					if
						footY >= top - 0.6
						and nextFoot <= top + 0.1
						and math.abs(rel.X - view.x) <= view.data.width / 2 + 1
					then
						local kind = view.data.kind
						if kind == "fake" then
							poofPlatform(view)
						else
							local mult = if kind == "bounce" then M.BOUNCE_PAD_MULTIPLIER else 1
							vy = M.JUMP_VELOCITY * runInfo.jumpMultiplier * mult
							view.squash = 1
							bounced = true
							bounceKick = if kind == "bounce" then 1.6 else 0.6
							fuel = math.min(
								runInfo.fuel,
								fuel + runInfo.fuel * M.JETPACK_FUEL_REFILL_ON_BOUNCE
							)
							UI.playSound(
								Config.Sounds.Bounce,
								if kind == "bounce" then 0.5 else 0.25,
								if kind == "bounce" then 1.3 else 1
							)
							if kind == "bounce" then
								burst(
									origin + Vector3.new(view.x, top, 0),
									Color3.fromRGB(255, 150, 210),
									10
								)
							elseif kind == "breaking" then
								breakPlatform(view)
							elseif kind == "ice" then
								iceTimer = 0.7
								burst(
									origin + Vector3.new(view.x, top, 0),
									Color3.fromRGB(220, 250, 255),
									6
								)
							end
							Bus.fire("Landed", kind)
							break
						end
					end
				end
			end
		end
	end

	-- Moving platforms + squash animation.
	for _, chunk in chunks do
		for _, view in chunk.platforms do
			if not view.gone and (view.data.moveRange > 0 or view.squash > 0) then
				local x = view.data.x
				if view.data.moveRange > 0 then
					x += math.sin(elapsed * view.data.moveSpeed + view.data.phase) * view.data.moveRange
					x = math.clamp(x, -HALF + view.data.width / 2, HALF - view.data.width / 2)
				end
				view.x = x
				view.squash = math.max(0, view.squash - dt * 6)
				local dip = -math.sin(view.squash * math.pi) * 0.8
				view.model:PivotTo(
					CFrame.new(
						origin + Vector3.new(x, view.data.y - PLATFORM_THICKNESS / 2 + dip, 0)
					)
				)
			end
		end
	end

	-- Walls.
	if (rel.X < -HALF and vx < 0) or (rel.X > HALF and vx > 0) then
		vx = 0
	end
	local correction = if rel.X < -HALF - 0.5 then 20 elseif rel.X > HALF + 0.5 then -20 else 0

	hrp.AssemblyLinearVelocity = Vector3.new(vx + correction, vy, -rel.Z * 10)
	local force = antiGravity
	if force then
		force.Force = Vector3.new(0, hrp.AssemblyMass * workspace.Gravity, 0)
	end
	local orient = align
	if orient then
		orient.CFrame = CFrame.Angles(0, math.rad(-vx / M.MOVE_SPEED * 35), 0)
			* CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, 1))
	end

	-- Pickups (+ magnet).
	local magnetRadius = if magnet then Config.PotionEffects.MAGNET_RADIUS else 0
	for _, chunk in chunks do
		for _, view in chunk.pickups do
			if not view.collected then
				local dx, dy = view.x - rel.X, view.y - rel.Y
				local dist = math.sqrt(dx * dx + dy * dy)
				if view.data.kind == "coin" and dist < magnetRadius and dist > 0.1 then
					local move = math.min(dist, dt * 70)
					view.x -= dx / dist * move
					view.y -= dy / dist * move
					dist -= move
				end
				if dist < 3.6 then
					collect(chunk, view)
				elseif view.data.kind == "coin" then
					view.part.CFrame = CFrame.new(origin + Vector3.new(view.x, view.y, 0))
						* CFrame.Angles(0, elapsed * 3 + view.data.id, 0)
						* CFrame.Angles(0, math.rad(90), 0)
				elseif view.data.kind == "capsule" or view.data.kind == "gem" then
					view.part.CFrame = CFrame.new(
						origin
							+ Vector3.new(
								view.x,
								view.y + math.sin(elapsed * 2 + view.data.id) * 0.5,
								0
							)
					) * CFrame.Angles(0, elapsed, math.rad(45))
				end
			end
		end
	end

	-- Height, camera, chunks.
	if rel.Y > maxY then
		maxY = rel.Y
	end
	local meters = math.floor(math.max(0, maxY) * Config.METERS_PER_STUD)
	RunState.height = meters
	RunState.fuel = fuel
	RunState.shield = shieldCharges

	local world, index = Formulas.worldForHeight(meters)
	if index ~= worldIndex then
		worldIndex = index
		RunState.worldName = world.name
		setLightingForWorld(world, false)
		Bus.fire("WorldEntered", world.name)
	end

	for _, chunk in chunks do
		for i = promptIndex + 1, #chunk.prompts do
			local prompt = chunk.prompts[i]
			if rel.Y >= prompt.y then
				promptIndex = i
				Bus.fire("RunPrompt", prompt.text)
			end
		end
	end

	updateChunks(rel.Y)

	local desired = rel.Y + 6
	if desired > camY then
		camY += (desired - camY) * math.min(1, dt * 8)
	end
	bounceKick = math.max(0, bounceKick - dt * 5)
	local camera = workspace.CurrentCamera
	camera.CFrame = CFrame.lookAt(
		origin + Vector3.new(0, camY - bounceKick * 0.4, M.CAMERA_DISTANCE),
		origin + Vector3.new(0, camY - bounceKick * 0.4, 0)
	)

	if rel.Y < camY - M.DEATH_BELOW_CAMERA then
		die("fell")
	end
end

local function buildBestMarker(origin: Vector3, best: number)
	if best <= 0 or not runFolder then
		return
	end
	local y = best / Config.METERS_PER_STUD
	local model = Instance.new("Model")
	model.Name = "BestMarker"
	for i = -6, 6 do
		newPart({
			Name = "Dash",
			Size = Vector3.new(2.6, 0.4, 0.4),
			CFrame = CFrame.new(origin + Vector3.new(i * 5, y, -2)),
			Color = Color3.fromRGB(255, 210, 80),
			Material = Enum.Material.Neon,
		}, model)
	end
	local anchor = newPart({
		Name = "Anchor",
		Size = Vector3.one,
		Transparency = 1,
		CFrame = CFrame.new(origin + Vector3.new(HALF - 4, y + 2.5, 0)),
	}, model)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 40)
	gui.LightInfluence = 0
	gui.Parent = anchor
	UI.label({
		Text = "YOUR BEST",
		Size = UDim2.fromScale(1, 1),
		TextColor3 = Color3.fromRGB(255, 220, 90),
		Parent = gui,
	})
	model.Parent = runFolder
end

local function applyProfileModifiers()
	local profile = State.profile()
	local runInfo = info
	if not profile or not runInfo then
		return
	end
	-- Potions used mid-run take effect immediately.
	local fresh = Formulas.runInfo(profile, runInfo.seed, runInfo.origin, runInfo.tutorial)
	runInfo.jumpMultiplier = fresh.jumpMultiplier
	magnet = fresh.magnet
	shieldCharges = fresh.shield
	coinMultiplier = if Formulas.effectActive(profile, "coin")
		then Config.PotionEffects.COIN_MULTIPLIER
		else 1
end

local function begin(runInfo: Types.RunInfo)
	stopLoop()
	clearWorld()
	if not hubAtmosphere then
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if atmosphere then
			hubAtmosphere = { Color = atmosphere.Color, Decay = atmosphere.Decay }
		end
	end
	info = runInfo
	local folder = Instance.new("Folder")
	folder.Name = "LocalRun"
	folder.Parent = workspace
	runFolder = folder
	vx, vy = 0, M.JUMP_VELOCITY * runInfo.jumpMultiplier
	camY = 6
	maxY = 0
	fuel = runInfo.fuel
	iceTimer = 0
	elapsed = 0
	promptIndex = 0
	worldIndex = 1
	magnet = runInfo.magnet
	shieldCharges = runInfo.shield
	coinMultiplier = 1
	RunState.active = true
	RunState.height = 0
	RunState.best = runInfo.bestHeight
	RunState.coins = 0
	RunState.gems = 0
	RunState.fuel = fuel
	RunState.maxFuel = runInfo.fuel
	RunState.hasJetpack = runInfo.hasJetpack
	RunState.worldName = Config.Worlds[1].name
	applyProfileModifiers()

	setDefaultControls(false)
	if not setupCharacter() then
		return
	end
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = M.CAMERA_FOV
	setLightingForWorld(Config.Worlds[1], true)
	updateChunks(0)
	buildBestMarker(runInfo.origin, runInfo.bestHeight)
	active = true
	renderConnection = RunService.RenderStepped:Connect(step)
	Bus.fire("RunBegan", runInfo)
end

local function exitToHub()
	active = false
	RunState.active = false
	stopLoop()
	clearWorld()
	releaseCharacter()
	restoreHubLighting()
	setDefaultControls(true)
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	info = nil
	Bus.fire("RunExited")
end

function Run.start()
	Remotes.event("RunStarted").OnClientEvent:Connect(function(runInfo: Types.RunInfo)
		begin(runInfo)
	end)
	Remotes.event("RunResult").OnClientEvent:Connect(function()
		-- The server can end a run on its own (e.g. invalid movement).
		if active then
			active = false
			RunState.active = false
			stopLoop()
		end
	end)
	Bus.on("ProfileChanged", function()
		if active then
			applyProfileModifiers()
		end
	end)
	Bus.on("RequestHub", exitToHub)
	player.CharacterAdded:Connect(function()
		if info then
			exitToHub()
		end
	end)
end

return Run
