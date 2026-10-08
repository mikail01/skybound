--!strict
-- Builds the floating hub island, its stalls, the portal and the lighting
-- entirely from code, in a chunky toy-like style: rounded shapes (balls and
-- cylinders), bright smooth materials, strong silhouettes. Everything lands
-- in workspace.Hub. Interactables get a ProximityPrompt with a "Panel"
-- attribute; the client opens the matching UI panel.

local Lighting = game:GetService("Lighting")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local Hub = {}

local CENTER = Config.HUB_CENTER
local TOP = CENTER.Y -- walkable surface height
local ISLAND_RADIUS = 78
local rng = Random.new(20261008)

local C = {
	grass = Color3.fromRGB(116, 214, 98),
	grassDark = Color3.fromRGB(88, 180, 80),
	dirt = Color3.fromRGB(176, 122, 82),
	rock = Color3.fromRGB(150, 140, 160),
	rockDark = Color3.fromRGB(115, 105, 130),
	path = Color3.fromRGB(245, 222, 170),
	wood = Color3.fromRGB(196, 140, 90),
	woodDark = Color3.fromRGB(150, 100, 64),
	white = Color3.fromRGB(255, 255, 255),
	cloud = Color3.fromRGB(250, 252, 255),
	trunk = Color3.fromRGB(150, 98, 64),
	leaf = Color3.fromRGB(90, 200, 110),
	leafPink = Color3.fromRGB(255, 160, 210),
	stone = Color3.fromRGB(170, 175, 205),
	portal = Color3.fromRGB(140, 110, 255),
	portalGlow = Color3.fromRGB(120, 230, 255),
	gold = Color3.fromRGB(255, 200, 70),
}

local hubFolder: Model

local function part(props: { [string]: any }, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent or hubFolder
	return p
end

local function ball(
	diameter: number,
	pos: Vector3,
	color: Color3,
	parent: Instance?,
	collide: boolean?
): Part
	return part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * diameter,
		CFrame = CFrame.new(pos),
		Color = color,
		CanCollide = collide ~= false,
	}, parent)
end

-- Vertical cylinder (Roblox cylinders point along X, so rotate onto Y).
local function cylinder(
	height: number,
	diameter: number,
	pos: Vector3,
	color: Color3,
	parent: Instance?
): Part
	return part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, diameter, diameter),
		CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
	}, parent)
end

local function model(name: string, parent: Instance?): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent or hubFolder
	return m
end

local function billboard(
	adornee: BasePart,
	title: string,
	subtitle: string?,
	color: Color3,
	offset: number
)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromScale(10, 3)
	gui.StudsOffset = Vector3.new(0, offset, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 140
	gui.LightInfluence = 0
	gui.Adornee = adornee
	gui.Parent = adornee

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, if subtitle then 0.62 else 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = title
	label.TextColor3 = C.white
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = color:Lerp(Color3.new(0, 0, 0), 0.45)
	stroke.Parent = label

	if subtitle then
		local tag = Instance.new("TextLabel")
		tag.Name = "Subtitle"
		tag.AnchorPoint = Vector2.new(0.5, 0)
		tag.Position = UDim2.fromScale(0.5, 0.64)
		tag.Size = UDim2.fromScale(0.42, 0.36)
		tag.BackgroundColor3 = color
		tag.Font = Enum.Font.FredokaOne
		tag.TextScaled = true
		tag.Text = subtitle
		tag.TextColor3 = C.white
		tag.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = tag
		local tagStroke = Instance.new("UIStroke")
		tagStroke.Thickness = 2
		tagStroke.Color = color:Lerp(Color3.new(0, 0, 0), 0.4)
		tagStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		tagStroke.Parent = tag
	end
end

local function prompt(parent: BasePart, objectText: string, panel: string)
	local p = Instance.new("ProximityPrompt")
	p.ActionText = "Open"
	p.ObjectText = objectText
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.MaxActivationDistance = 13
	p.RequiresLineOfSight = false
	p.HoldDuration = 0
	p:SetAttribute("Panel", panel)
	p.Parent = parent
end

local function sign(parent: Instance, cf: CFrame, text: string, color: Color3)
	local board = part({
		Name = "Sign",
		Size = Vector3.new(11, 2.6, 0.6),
		CFrame = cf,
		Color = color,
	}, parent)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(440, 104)
	gui.LightInfluence = 0
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = C.white
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = color:Lerp(Color3.new(0, 0, 0), 0.5)
	stroke.Parent = label
end

-- Generic market stall. `cf` sits on the ground; its LookVector faces the
-- customer side.
local function stall(
	name: string,
	cf: CFrame,
	color: Color3,
	title: string,
	panel: string,
	tag: string?
): (Model, Part)
	local m = model(name)
	part({
		Name = "Floor",
		Size = Vector3.new(16, 1, 11),
		CFrame = cf * CFrame.new(0, 0.5, 0),
		Color = C.wood,
	}, m)
	local counter = part({
		Name = "Counter",
		Size = Vector3.new(14, 3.6, 3),
		CFrame = cf * CFrame.new(0, 2.8, -3.5),
		Color = color,
	}, m)
	part({
		Name = "CounterTop",
		Size = Vector3.new(14.6, 0.6, 3.6),
		CFrame = cf * CFrame.new(0, 4.9, -3.5),
		Color = C.woodDark,
	}, m)
	for _, x in { -7, 7 } do
		for _, z in { -4.8, 4.8 } do
			local post = cylinder(10, 1.2, Vector3.zero, C.woodDark, m)
			post.CFrame = cf * CFrame.new(x, 5.5, z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end
	-- Striped awning, tilted toward the customer.
	for i = 0, 6 do
		local stripe = part({
			Name = "Awning",
			Size = Vector3.new(2.5, 0.7, 12.5),
			Color = if i % 2 == 0 then color else C.white,
		}, m)
		stripe.CFrame = cf
			* CFrame.new(-7.5 + i * 2.5, 11.2, -0.5)
			* CFrame.Angles(math.rad(-12), 0, 0)
	end
	-- Scalloped awning edge: little balls along the front.
	for i = 0, 7 do
		local scallop = ball(1.5, Vector3.zero, if i % 2 == 0 then color else C.white, m, false)
		scallop.CFrame = cf * CFrame.new(-7.8 + i * 2.23, 9.9, -6.7)
	end
	sign(m, cf * CFrame.new(0, 13.4, -5.2) * CFrame.Angles(0, math.rad(180), 0), title, color)
	billboard(counter, title, tag, if tag then Color3.fromRGB(80, 200, 90) else color, 12)
	prompt(counter, title, panel)
	m.PrimaryPart = counter
	return m, counter
end

local function tree(pos: Vector3, scale: number, leafColor: Color3)
	local m = model("Tree")
	cylinder(7 * scale, 2 * scale, pos + Vector3.new(0, 3.5 * scale, 0), C.trunk, m)
	ball(7.5 * scale, pos + Vector3.new(0, 8.5 * scale, 0), leafColor, m)
	ball(5.5 * scale, pos + Vector3.new(2.4 * scale, 7.4 * scale, 1 * scale), leafColor, m)
	ball(5 * scale, pos + Vector3.new(-2.2 * scale, 7.8 * scale, -1.2 * scale), leafColor, m)
	ball(
		4.5 * scale,
		pos + Vector3.new(0.4 * scale, 11.4 * scale, 0.3 * scale),
		leafColor:Lerp(C.white, 0.15),
		m
	)
end

local function flower(pos: Vector3, color: Color3)
	local m = model("Flower")
	local stem = cylinder(2.4, 0.35, pos + Vector3.new(0, 1.2, 0), C.grassDark, m)
	stem.CanCollide = false
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2
		ball(1.1, pos + Vector3.new(math.cos(a) * 0.65, 2.6, math.sin(a) * 0.65), color, m, false)
	end
	ball(0.8, pos + Vector3.new(0, 2.65, 0), C.gold, m, false)
end

local function bush(pos: Vector3, size: number)
	local m = model("Bush")
	ball(size, pos + Vector3.new(0, size * 0.35, 0), C.grassDark, m, false)
	ball(size * 0.75, pos + Vector3.new(size * 0.45, size * 0.25, 0.3), C.grass, m, false)
	ball(size * 0.7, pos + Vector3.new(-size * 0.42, size * 0.22, -0.2), C.grass, m, false)
end

local function cloud(pos: Vector3, scale: number)
	local m = model("Cloud")
	for i = 0, 4 do
		local b = ball(
			(5 + rng:NextNumber() * 4) * scale,
			pos
				+ Vector3.new(
					(i - 2) * 3.2 * scale,
					rng:NextNumber() * 1.5 * scale,
					rng:NextNumber() * 2 * scale
				),
			C.cloud,
			m,
			false
		)
		b.Transparency = 0.05
		b.CastShadow = false
	end
end

local function island()
	-- Grass top and dirt rim.
	cylinder(4, ISLAND_RADIUS * 2, CENTER - Vector3.new(0, 2, 0), C.grass).Name = "Ground"
	cylinder(5, ISLAND_RADIUS * 2 - 2, CENTER - Vector3.new(0, 5.5, 0), C.dirt)
	-- Rounded rocky underside built from overlapping balls.
	for ring = 0, 4 do
		local radius = ISLAND_RADIUS * (1 - ring * 0.2) - 6
		local depth = 10 + ring * 9
		local count = math.max(1, math.floor(radius / 5))
		for i = 1, count do
			local a = i / count * math.pi * 2 + ring
			local size = 22 - ring * 2 + rng:NextNumber() * 6
			ball(
				size,
				CENTER
					+ Vector3.new(math.cos(a) * radius * 0.85, -depth, math.sin(a) * radius * 0.85),
				if (i + ring) % 3 == 0 then C.rockDark else C.rock
			)
		end
	end
	ball(30, CENTER - Vector3.new(0, 50, 0), C.rockDark)
	-- Grass lip: chunky balls around the rim.
	for i = 1, 48 do
		local a = i / 48 * math.pi * 2
		ball(
			5 + rng:NextNumber() * 2,
			CENTER
				+ Vector3.new(
					math.cos(a) * (ISLAND_RADIUS - 1),
					-1.5,
					math.sin(a) * (ISLAND_RADIUS - 1)
				),
			C.grass,
			nil,
			false
		)
	end
	-- Low fence ring so nobody walks off by accident.
	for i = 1, 64 do
		local a = i / 64 * math.pi * 2
		local p = CENTER
			+ Vector3.new(math.cos(a) * (ISLAND_RADIUS - 4), 1.6, math.sin(a) * (ISLAND_RADIUS - 4))
		local post = cylinder(3.2, 0.9, p, C.wood)
		post.Name = "Fence"
		local nextA = (i + 1) / 64 * math.pi * 2
		local q = CENTER
			+ Vector3.new(
				math.cos(nextA) * (ISLAND_RADIUS - 4),
				2.4,
				math.sin(nextA) * (ISLAND_RADIUS - 4)
			)
		local mid = (p + Vector3.new(0, 0.8, 0) + q) / 2
		part({
			Name = "Fence",
			Size = Vector3.new(0.5, 0.6, (q - p).Magnitude),
			CFrame = CFrame.lookAt(mid, q),
			Color = C.woodDark,
		})
	end
	-- Invisible wall above the fence (prevents accidental falls, allows view).
	for i = 1, 32 do
		local a = i / 32 * math.pi * 2
		part({
			Name = "EdgeWall",
			Size = Vector3.new(16, 30, 1),
			CFrame = CFrame.lookAt(
				CENTER
					+ Vector3.new(
						math.cos(a) * (ISLAND_RADIUS - 3),
						15,
						math.sin(a) * (ISLAND_RADIUS - 3)
					),
				CENTER + Vector3.new(0, 15, 0)
			),
			Transparency = 1,
			CastShadow = false,
		})
	end
end

local function pathTo(from: Vector3, to: Vector3)
	local dist = (to - from).Magnitude
	local steps = math.floor(dist / 4)
	for i = 0, steps do
		local p = from:Lerp(to, i / math.max(steps, 1))
		local tile =
			cylinder(0.3, 4.2 + rng:NextNumber() * 0.8, Vector3.new(p.X, TOP + 0.05, p.Z), C.path)
		tile.Name = "Path"
		tile.CanCollide = false
	end
end

local function spawnPad()
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HubSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CFrame =
		CFrame.lookAt(CENTER + Vector3.new(0, 0.6, 42), CENTER + Vector3.new(0, 0.6, -40))
	spawn.Duration = 0
	spawn.Parent = hubFolder
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
	local pad = cylinder(1, 14, CENTER + Vector3.new(0, 0.3, 42), Color3.fromRGB(255, 236, 140))
	pad.Name = "SpawnPad"
	cylinder(1.1, 10, CENTER + Vector3.new(0, 0.35, 42), Color3.fromRGB(255, 255, 220)).Name =
		"SpawnPad"
end

local function portal()
	local m = model("Portal")
	local base = CENTER + Vector3.new(0, 0, -50)
	-- Stepped round base.
	cylinder(1.4, 30, base + Vector3.new(0, 0.7, 0), C.stone, m)
	cylinder(1.4, 24, base + Vector3.new(0, 2.1, 0), C.stone:Lerp(C.white, 0.2), m)
	local center = base + Vector3.new(0, 15, 0)
	-- Chunky stone frame.
	local segments = 18
	for i = 0, segments - 1 do
		local a = i / segments * math.pi * 2
		local p = center + Vector3.new(math.cos(a) * 12.5, math.sin(a) * 12.5, 0)
		if math.sin(a) < -0.8 then
			continue -- leave the bottom open so players walk straight in
		end
		local block = part({
			Name = "Frame",
			Size = Vector3.new(4.6, 4.6, 5),
			CFrame = CFrame.new(p) * CFrame.Angles(0, 0, a),
			Color = if i % 2 == 0 then C.stone else C.stone:Lerp(C.portal, 0.25),
		}, m)
		block.Material = Enum.Material.SmoothPlastic
		if i % 3 == 0 then
			local crystal = ball(2.2, p + Vector3.new(0, 0, -2.6), C.portalGlow, m, false)
			crystal.Material = Enum.Material.Neon
		end
	end
	-- Energy surface.
	local surface = part({
		Name = "Surface",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 22, 22),
		CFrame = CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0),
		Color = C.portal,
		Material = Enum.Material.Neon,
		Transparency = 0.25,
		CanCollide = false,
	}, m)
	local light = Instance.new("PointLight")
	light.Color = C.portalGlow
	light.Range = 30
	light.Brightness = 2
	light.Parent = surface
	local attachment = Instance.new("Attachment")
	attachment.Parent = surface
	local particles = Instance.new("ParticleEmitter")
	particles.Name = "Sparkles"
	particles.Color = ColorSequence.new(C.portalGlow, C.white)
	particles.LightEmission = 1
	particles.Size =
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0) })
	particles.Lifetime = NumberRange.new(1, 1.8)
	particles.Rate = 18
	particles.Speed = NumberRange.new(2, 5)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Parent = attachment
	-- Floating rings (spun by the client so they cost the server nothing).
	for r = 1, 2 do
		local ring = model("Ring" .. r, m)
		ring:SetAttribute("Spin", if r == 1 then 0.6 else -0.9)
		local pivot = part({
			Name = "Pivot",
			Size = Vector3.one,
			CFrame = CFrame.new(center),
			Transparency = 1,
			CanCollide = false,
		}, ring)
		ring.PrimaryPart = pivot
		local radius = if r == 1 then 16 else 18.5
		for i = 0, 11 do
			local a = i / 12 * math.pi * 2
			local orb = ball(
				if r == 1 then 1.4 else 1,
				center
					+ Vector3.new(
						math.cos(a) * radius,
						math.sin(a) * radius,
						if r == 1 then 0 else 1.5
					),
				if r == 1 then C.portalGlow else C.gold,
				ring,
				false
			)
			orb.Material = Enum.Material.Neon
		end
	end
	-- Trigger lives directly in Hub so the run system can find it.
	part({
		Name = "PortalTrigger",
		Size = Vector3.new(16, 20, 4),
		CFrame = CFrame.new(base + Vector3.new(0, 12, 0)),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	billboard(surface, "PLAY", "ENTER PORTAL", C.portal, 15)
	m.PrimaryPart = surface
end

local function dailyStand()
	local cf = CFrame.lookAt(CENTER + Vector3.new(-34, 0, 16), CENTER + Vector3.new(0, 0, 30))
	local m =
		stall("DailyStand", cf, Color3.fromRGB(255, 120, 150), "DAILY REWARD", "Daily", "FREE")
	-- Treasure chest on the counter.
	local chestBase = cf * CFrame.new(0, 6.4, -3.5)
	part({ Name = "Chest", Size = Vector3.new(4.6, 2.6, 3), CFrame = chestBase, Color = C.wood }, m)
	part({
		Name = "ChestBand",
		Size = Vector3.new(4.8, 0.5, 3.2),
		CFrame = chestBase * CFrame.new(0, 0.4, 0),
		Color = C.gold,
	}, m)
	local lid = part({
		Name = "ChestLid",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4.6, 3, 3),
		CFrame = chestBase * CFrame.new(0, 1.3, 0),
		Color = C.woodDark,
	}, m)
	lid:SetAttribute("ClosedCFrame", lid.CFrame)
	part({
		Name = "ChestLock",
		Size = Vector3.new(0.9, 1.1, 0.4),
		CFrame = chestBase * CFrame.new(0, 0.6, -1.6),
		Color = C.gold,
	}, m)
end

local function upgradeStation()
	local m = model("UpgradeStation")
	local pos = CENTER + Vector3.new(34, 0, 16)
	local cf = CFrame.lookAt(pos, CENTER + Vector3.new(0, 0, 30))
	cylinder(1, 16, pos + Vector3.new(0, 0.5, 0), C.stone, m)
	local body = part({
		Name = "Body",
		Size = Vector3.new(9, 10, 7),
		CFrame = cf * CFrame.new(0, 6, 0),
		Color = Color3.fromRGB(130, 110, 255),
	}, m)
	ball(8.5, (cf * CFrame.new(0, 11.5, 0)).Position, Color3.fromRGB(160, 145, 255), m)
	local screen = part({
		Name = "Screen",
		Size = Vector3.new(6, 4, 0.4),
		CFrame = cf * CFrame.new(0, 7.5, -3.6),
		Color = Color3.fromRGB(40, 40, 70),
	}, m)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.LightInfluence = 0
	gui.CanvasSize = Vector2.new(300, 200)
	gui.Parent = screen
	local arrow = Instance.new("TextLabel")
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromScale(1, 1)
	arrow.Font = Enum.Font.FredokaOne
	arrow.TextScaled = true
	arrow.Text = "⬆ LVL UP"
	arrow.TextColor3 = Color3.fromRGB(120, 255, 160)
	arrow.Parent = gui
	for i = 1, 4 do
		local light = ball(
			1.3,
			(cf * CFrame.new(-3 + (i - 1) * 2, 3, -3.6)).Position,
			Color3.fromRGB(90, 90, 120),
			m,
			false
		)
		light.Name = "Light" .. i
		light.Material = Enum.Material.Neon
	end
	for _, side in { -1, 1 } do
		local pipe = cylinder(6, 1.4, Vector3.zero, Color3.fromRGB(255, 200, 80), m)
		pipe.CFrame = cf * CFrame.new(side * 5.2, 5, 0) * CFrame.Angles(0, 0, math.rad(90))
	end
	billboard(body, "UPGRADES", nil, Color3.fromRGB(130, 110, 255), 11)
	prompt(body, "Upgrades", "Upgrades")
	m.PrimaryPart = body
end

local function gearStall()
	local cf = CFrame.lookAt(CENTER + Vector3.new(-40, 0, -22), CENTER + Vector3.new(0, 0, -10))
	local m = stall("GearStall", cf, Color3.fromRGB(80, 170, 255), "GEAR", "Gear")
	for i, x in { -3.5, 3.5 } do
		local display = model("Jetpack" .. i, m)
		display:SetAttribute("Bob", true)
		local base = cf * CFrame.new(x, 7.4, -3.5)
		local tankColor = if i == 1
			then Color3.fromRGB(230, 90, 90)
			else Color3.fromRGB(255, 200, 70)
		local pivot = part({
			Name = "Pivot",
			Size = Vector3.one,
			CFrame = base,
			Transparency = 1,
			CanCollide = false,
		}, display)
		display.PrimaryPart = pivot
		for _, side in { -0.8, 0.8 } do
			local tank = cylinder(3, 1.4, Vector3.zero, tankColor, display)
			tank.CFrame = base * CFrame.new(side, 0, 0) * CFrame.Angles(0, 0, math.rad(90))
			tank.CanCollide = false
			local cap =
				ball(1.4, (base * CFrame.new(side, 1.5, 0)).Position, tankColor, display, false)
			cap.Name = "Cap"
			local flame = ball(
				0.9,
				(base * CFrame.new(side, -1.9, 0)).Position,
				Color3.fromRGB(255, 160, 40),
				display,
				false
			)
			flame.Material = Enum.Material.Neon
		end
	end
end

local function potionStall()
	local cf = CFrame.lookAt(CENTER + Vector3.new(40, 0, -22), CENTER + Vector3.new(0, 0, -10))
	local m = stall("SkybrewStall", cf, Color3.fromRGB(110, 210, 130), "SKYBREW", "Potions")
	for i, def in Config.Potions do
		local x = -5.6 + (i - 1) * 2.8
		local base = (cf * CFrame.new(x, 6.2, -3.5)).Position
		local bottle = ball(1.9, base, def.color, m, false)
		bottle.Material = Enum.Material.Glass
		bottle.Transparency = 0.15
		cylinder(0.9, 0.7, base + Vector3.new(0, 1.2, 0), def.color:Lerp(C.white, 0.5), m).CanCollide =
			false
		cylinder(0.5, 0.8, base + Vector3.new(0, 1.8, 0), C.woodDark, m).CanCollide = false
	end
	-- Bubbling cauldron beside the stall.
	local cauldronPos = (cf * CFrame.new(10.5, 0, -2)).Position
	cylinder(3.5, 5, cauldronPos + Vector3.new(0, 1.75, 0), Color3.fromRGB(60, 55, 75), m)
	local brew =
		cylinder(0.3, 4.2, cauldronPos + Vector3.new(0, 3.5, 0), Color3.fromRGB(120, 255, 140), m)
	brew.Material = Enum.Material.Neon
	local attachment = Instance.new("Attachment")
	attachment.Parent = brew
	local bubbles = Instance.new("ParticleEmitter")
	bubbles.Color = ColorSequence.new(Color3.fromRGB(170, 255, 180))
	bubbles.LightEmission = 0.6
	bubbles.Size = NumberSequence.new(0.4, 0)
	bubbles.Lifetime = NumberRange.new(0.8, 1.4)
	bubbles.Rate = 6
	bubbles.Speed = NumberRange.new(2, 3)
	bubbles.SpreadAngle = Vector2.new(15, 15)
	bubbles.Parent = attachment
end

local function leaderboardBoard()
	local m = model("Leaderboard")
	local pos = CENTER + Vector3.new(50, 0, 46)
	local cf = CFrame.lookAt(pos, CENTER + Vector3.new(0, 0, 20))
	for _, x in { -6, 6 } do
		local post = cylinder(15, 1.4, Vector3.zero, C.woodDark, m)
		post.CFrame = cf * CFrame.new(x, 7.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	end
	local board = part({
		Name = "Board",
		Size = Vector3.new(14, 11, 0.8),
		CFrame = cf * CFrame.new(0, 9, 0),
		Color = Color3.fromRGB(60, 70, 120),
	}, m)
	ball(2.6, (cf * CFrame.new(0, 15.6, 0)).Position, C.gold, m)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.CanvasSize = Vector2.new(560, 440)
	gui.Parent = board
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 60)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "🏆 HIGHEST CLIMBERS"
	title.TextColor3 = C.gold
	title.Parent = gui
	local list = Instance.new("Frame")
	list.Name = "LeaderboardList"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(20, 66)
	list.Size = UDim2.new(1, -40, 1, -76)
	list.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	for i = 1, 10 do
		local row = Instance.new("TextLabel")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0.1, 0)
		row.Font = Enum.Font.FredokaOne
		row.TextScaled = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = C.white
		row.Text = string.format("%d.  —", i)
		row.Parent = list
	end
end

local function decorate()
	local blocked = {
		Vector3.new(0, 0, 42), -- spawn
		Vector3.new(0, 0, -50), -- portal
		Vector3.new(-34, 0, 16),
		Vector3.new(34, 0, 16),
		Vector3.new(-40, 0, -22),
		Vector3.new(40, 0, -22),
		Vector3.new(50, 0, 46),
	}
	local function free(offset: Vector3, radius: number): boolean
		if math.abs(offset.X) < 7 then
			return false -- main path
		end
		for _, b in blocked do
			if (offset - b).Magnitude < radius then
				return false
			end
		end
		return offset.Magnitude < ISLAND_RADIUS - 9
	end
	local placedTrees = 0
	for _ = 1, 80 do
		if placedTrees >= 12 then
			break
		end
		local a = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(40, ISLAND_RADIUS - 10)
		local offset = Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if free(offset, 18) then
			placedTrees += 1
			tree(
				Vector3.new(CENTER.X + offset.X, TOP, CENTER.Z + offset.Z),
				rng:NextNumber(0.9, 1.4),
				if rng:NextNumber() < 0.3 then C.leafPink else C.leaf
			)
		end
	end
	local flowerColors = {
		Color3.fromRGB(255, 120, 150),
		Color3.fromRGB(255, 220, 90),
		Color3.fromRGB(150, 130, 255),
		Color3.fromRGB(255, 255, 255),
	}
	for _ = 1, 70 do
		local a = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(10, ISLAND_RADIUS - 8)
		local offset = Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if free(offset, 11) then
			flower(
				Vector3.new(CENTER.X + offset.X, TOP, CENTER.Z + offset.Z),
				flowerColors[rng:NextInteger(1, #flowerColors)]
			)
		end
	end
	for _ = 1, 25 do
		local a = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(20, ISLAND_RADIUS - 8)
		local offset = Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if free(offset, 12) then
			bush(Vector3.new(CENTER.X + offset.X, TOP, CENTER.Z + offset.Z), rng:NextNumber(3, 5))
		end
	end
	-- Floating mini islands and clouds around the hub.
	for i = 1, 7 do
		local a = i / 7 * math.pi * 2 + 0.3
		local r = ISLAND_RADIUS + rng:NextNumber(30, 70)
		local p = CENTER + Vector3.new(math.cos(a) * r, rng:NextNumber(-25, 20), math.sin(a) * r)
		local size = rng:NextNumber(10, 18)
		cylinder(2.5, size, p, C.grass)
		ball(size * 0.9, p - Vector3.new(0, size * 0.35, 0), C.rock)
		if rng:NextNumber() < 0.6 then
			tree(p + Vector3.new(0, 1.2, 0), 0.7, C.leaf)
		end
	end
	for _ = 1, 18 do
		local a = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(ISLAND_RADIUS + 20, ISLAND_RADIUS + 160)
		cloud(
			CENTER + Vector3.new(math.cos(a) * r, rng:NextNumber(-60, 40), math.sin(a) * r),
			rng:NextNumber(1, 2.4)
		)
	end
end

local function lighting()
	Lighting.ClockTime = 14
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(110, 110, 130)
	Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 190)
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.5
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") or child:IsA("PostEffect") or child:IsA("Sky") then
			child:Destroy()
		end
	end
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.3
	atmosphere.Offset = 0.2
	atmosphere.Color = Color3.fromRGB(205, 232, 255)
	atmosphere.Decay = Color3.fromRGB(110, 180, 255)
	atmosphere.Glare = 0.2
	atmosphere.Haze = 1.2
	atmosphere.Parent = Lighting
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.5
	bloom.Size = 24
	bloom.Threshold = 0.95
	bloom.Parent = Lighting
	local color = Instance.new("ColorCorrectionEffect")
	color.Name = "SkyboundGrade"
	color.Saturation = 0.15
	color.Contrast = 0.05
	color.Parent = Lighting
end

function Hub.init()
	-- Clear the default template pieces so the hub floats in open sky.
	for _, name in { "Baseplate", "SpawnLocation" } do
		local existing = workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
	local old = workspace:FindFirstChild("Hub")
	if old then
		old:Destroy()
	end
	hubFolder = Instance.new("Model")
	hubFolder.Name = "Hub"

	lighting()
	island()
	spawnPad()
	portal()
	dailyStand()
	upgradeStation()
	gearStall()
	potionStall()
	leaderboardBoard()
	pathTo(CENTER + Vector3.new(0, 0, 36), CENTER + Vector3.new(0, 0, -36))
	pathTo(CENTER + Vector3.new(0, 0, 22), CENTER + Vector3.new(-26, 0, 14))
	pathTo(CENTER + Vector3.new(0, 0, 22), CENTER + Vector3.new(26, 0, 14))
	pathTo(CENTER + Vector3.new(0, 0, -16), CENTER + Vector3.new(-32, 0, -20))
	pathTo(CENTER + Vector3.new(0, 0, -16), CENTER + Vector3.new(32, 0, -20))
	decorate()

	hubFolder.Parent = workspace
end

return Hub
