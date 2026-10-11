--!strict
-- Turns the imported floating island (FloatingIslandMap.glb, brought in with
-- Studio's 3D Importer) into the hub's world. Hub calls build() and then puts
-- its stalls, boards, spawn and portal trigger on the spots this module
-- returns, so everything the code-built hub has also works on the map.
--
-- The map is authored in its own units. The numbers below were measured from
-- the .glb; at runtime three reference meshes tell us where the importer put
-- the map, how big it made it and which way round it is, so it does not
-- matter where (or at what size) it was imported.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local HubMap = {}

export type Layout = {
	map: Model,
	portal: Model,
	studsPerUnit: number,
	radius: number, -- walkable radius in studs
	toWorld: (x: number, y: number, z: number) -> Vector3,
	spawn: CFrame,
	daily: CFrame,
	upgrade: CFrame,
	gear: CFrame,
	potions: CFrame,
	quests: CFrame,
	leaderboard: CFrame,
}

-- Bounding-box centres (map units) of the meshes used to locate the map.
local REF_GRASS = "Island_Grass"
local REF_POINTS = {
	Island_Grass = Vector3.new(0.081, 21.696, 0),
	Island_Plateau = Vector3.new(25.999, 29.052, -19.533),
	Spawn_Pad = Vector3.new(17.752, 28.559, -7.89),
}
local GRASS_WIDTH = 80 -- X extent of Island_Grass in map units
local MAP_RADIUS = 39.3 -- walkable rim

-- Walkable heights (map units).
local LOW = 23.83 -- south meadow
local TERRACE = 28.16 -- raised north half
local PAD = 29.03 -- spawn pad top
local PLATEAU = 31.12 -- portal plateau

-- Where things go: ground point (x, height, z) and the point they face.
type Spot = { x: number, y: number, z: number, faceX: number, faceZ: number }
local SPOTS: { [string]: Spot } = {
	spawn = { x = 17.75, y = PAD, z = -7.89, faceX = 8, faceZ = -14 },
	daily = { x = 8, y = TERRACE, z = -14, faceX = 17.75, faceZ = -7.89 },
	upgrade = { x = 33.5, y = TERRACE, z = -7, faceX = 17.75, faceZ = -7.89 },
	gear = { x = 25.5, y = LOW, z = 6, faceX = 17.5, faceZ = 3 },
	potions = { x = -16, y = LOW, z = 2, faceX = 0, faceZ = 6 },
	quests = { x = -11, y = LOW, z = 18, faceX = 0, faceZ = 12 },
	leaderboard = { x = 16, y = LOW, z = 21, faceX = 5, faceZ = 12 },
}

-- Stairs between levels: from a point on the upper level to one below.
local STAIRS = {
	{ top = Vector3.new(17.6, TERRACE, -2.3), bottom = Vector3.new(17.6, LOW, 3.6) }, -- spawn -> meadow
	{ top = Vector3.new(-21, TERRACE, -3.3), bottom = Vector3.new(-21, LOW, 2.8) }, -- west path
	{ top = Vector3.new(21.3, PLATEAU, -12), bottom = Vector3.new(19.3, PAD, -9.6) }, -- pad -> portal
}

-- The portal's round base and the direction you walk through the arch.
local PORTAL_BASE = Vector3.new(28.7, PLATEAU, -20)
local PORTAL_VORTEX = Vector3.new(28, 37.9, -20.5)
local PORTAL_FACING = Vector3.new(0.407, 0, 0.914)

-- Meshes that are pure decoration: no collision, no touch, ignored by rays.
-- Paths and water sit a hair above solid ground, so they need none either.
local DECOR_PREFIXES = {
	"Plants_",
	"Island_Paths",
	"Water_",
	"Props_Butterflies",
	"Props_Mushrooms",
	"Props_Squirrel",
	"Props_SteppingStones",
	"Portal_Vortex",
	"Portal_Label",
	"Portal_Gems",
	"VFX_",
}
-- Meshes people stand on or bump into. These want precise collision, which
-- only Studio can set (see tools/setup_island.luau).
local SOLID_PREFIXES = { "Island_", "Spawn_", "Props_", "Tree_", "Portal_" }

local function startsWith(name: string, prefix: string): boolean
	return string.sub(name, 1, #prefix) == prefix
end

local function isDecor(name: string): boolean
	if string.sub(name, -8) == "_Outline" then
		return true
	end
	for _, prefix in DECOR_PREFIXES do
		if startsWith(name, prefix) then
			return true
		end
	end
	return false
end

local function isSolid(name: string): boolean
	for _, prefix in SOLID_PREFIXES do
		if startsWith(name, prefix) then
			return true
		end
	end
	return false
end

type Frame = {
	origin: Vector3, -- world position of the grass reference point
	ax: Vector3, -- world offset of +1 map unit along X
	az: Vector3, -- world offset of +1 map unit along Z
	unit: number, -- studs per map unit
}

-- Bounds of all meshes in the .glb, for imports whose mesh names changed.
local GLB_CENTER = Vector3.new(0.058, 25.487, -0.004)
local GLB_WIDTH = 80.685

-- A mesh by its .glb name. Importers sometimes rename meshes (".001",
-- "_Mesh", a model of that name around the part), so match loosely.
local function refPart(map: Instance, name: string): BasePart?
	local exact = map:FindFirstChild(name, true)
	if exact and exact:IsA("BasePart") then
		return exact
	end
	if exact and exact:IsA("Model") then
		for _, d in exact:GetDescendants() do
			if d:IsA("BasePart") and not string.find(string.lower(d.Name), "outline", 1, true) then
				return d
			end
		end
	end
	local key = string.lower(name)
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") then
			local n = string.lower(d.Name)
			if string.sub(n, 1, #key) == key and not string.find(n, "outline", 1, true) then
				return d
			end
		end
	end
	return nil
end

local function looksLikeMap(m: Instance): boolean
	return string.find(string.lower(m.Name), string.lower(Config.HUB_MAP_NAME), 1, true) ~= nil
		or refPart(m, REF_GRASS) ~= nil
end

-- The imported model, wherever it was left: by name first, else the
-- outermost model holding the island mesh.
function HubMap.find(): Model?
	local containers = { ServerStorage, ReplicatedStorage, workspace }
	for _, container in containers do
		local found = container:FindFirstChild(Config.HUB_MAP_NAME, true)
		if found and found:IsA("Model") then
			return found
		end
	end
	for _, container in containers do
		for _, d in container:GetDescendants() do
			if
				d:IsA("Model")
				and d.Name ~= "Hub"
				and not d:FindFirstAncestor("Hub")
				-- outermost: Workspace itself counts as a Model, so allow it
				and not (d.Parent and d.Parent ~= workspace and d.Parent:IsA("Model"))
				and looksLikeMap(d)
			then
				return d
			end
		end
	end
	return nil
end

-- Solve how map (x, z) maps onto the world from three known meshes. This is
-- a 2x2 linear map, so a rotated or mirrored import still lines up. When
-- those meshes can't be found, fall back to the model's bounding box.
local function measure(map: Model): Frame?
	local grass = refPart(map, REF_GRASS)
	local plateau = refPart(map, "Island_Plateau")
	local pad = refPart(map, "Spawn_Pad")
	if grass and plateau and pad then
		local g = REF_POINTS.Island_Grass
		local a = REF_POINTS.Island_Plateau - g
		local b = REF_POINTS.Spawn_Pad - g
		local wa = plateau.Position - grass.Position
		local wb = pad.Position - grass.Position
		local det = a.X * b.Z - b.X * a.Z
		-- Columns of the inverse of [a b] (in X/Z), applied to the world vectors.
		local ax = (wa * b.Z - wb * a.Z) / det
		local az = (wb * a.X - wa * b.X) / det
		ax = Vector3.new(ax.X, 0, ax.Z)
		az = Vector3.new(az.X, 0, az.Z)
		local unit = grass.Size.X / GRASS_WIDTH
		if unit > 0 and ax.Magnitude > 0 and az.Magnitude > 0 then
			return { origin = grass.Position, ax = ax, az = az, unit = unit }
		end
	end
	local cf, size = map:GetBoundingBox()
	local unit = size.X / GLB_WIDTH
	if unit <= 0 then
		return nil
	end
	local origin = cf.Position + (REF_POINTS.Island_Grass - GLB_CENTER) * unit
	return {
		origin = origin,
		ax = Vector3.new(unit, 0, 0),
		az = Vector3.new(0, 0, unit),
		unit = unit,
	}
end

local function worldOf(frame: Frame, p: Vector3): Vector3
	local g = REF_POINTS.Island_Grass
	return frame.origin
		+ frame.ax * (p.X - g.X)
		+ frame.az * (p.Z - g.Z)
		+ Vector3.new(0, (p.Y - g.Y) * frame.unit, 0)
end

local function flatDirection(frame: Frame, x: number, z: number): Vector3
	local d = frame.ax * x + frame.az * z
	return if d.Magnitude > 0 then d.Unit else Vector3.new(0, 0, -1)
end

local function prepareParts(map: Model): { string }
	local coarse = {}
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			if isDecor(d.Name) then
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				if string.sub(d.Name, -8) == "_Outline" then
					d.CastShadow = false
				end
			else
				d.CanTouch = false
				if
					d:IsA("MeshPart")
					and isSolid(d.Name)
					and d.CollisionFidelity ~= Enum.CollisionFidelity.PreciseConvexDecomposition
				then
					table.insert(coarse, d.Name)
				end
			end
		end
	end
	return coarse
end

local function newPart(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.WoodPlanks
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function fxPart(name: string, cf: CFrame, size: Vector3, parent: Instance): Part
	return newPart({
		Name = name,
		CFrame = cf,
		Size = size,
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		CastShadow = false,
		Material = Enum.Material.SmoothPlastic,
	}, parent)
end

-- Wooden stairs, solid blocks rising from the lower ground to the upper.
local function stairs(top: Vector3, bottom: Vector3, width: number, parent: Instance)
	local m = Instance.new("Model")
	m.Name = "Stairs"
	m.Parent = parent
	local rise = top.Y - bottom.Y
	local flat = Vector3.new(top.X - bottom.X, 0, top.Z - bottom.Z)
	local run = flat.Magnitude
	if rise <= 0 or run <= 0 then
		return
	end
	local steps = math.max(2, math.ceil(rise / 1.1))
	local tread = run / steps
	local dir = flat.Unit
	local wood = Color3.fromRGB(196, 140, 90)
	local woodDark = Color3.fromRGB(150, 100, 64)
	for i = 1, steps do
		local height = rise * i / steps
		local along = (i - 0.5) * tread
		local foot = bottom + dir * along
		newPart({
			Name = "Step",
			Size = Vector3.new(width, height + 1, tread + 0.05),
			CFrame = CFrame.lookAt(foot, foot + dir) * CFrame.new(0, height / 2 - 0.5, 0),
			Color = if i % 2 == 0 then wood else wood:Lerp(woodDark, 0.25),
		}, m)
	end
	-- Side rails so the stairs read clearly from a distance.
	local slope = CFrame.lookAt(bottom, top)
	for _, side in { -1, 1 } do
		newPart({
			Name = "Rail",
			Size = Vector3.new(0.6, 0.6, (top - bottom).Magnitude),
			CFrame = slope
				* CFrame.new(side * (width / 2 + 0.3), 2.6, -(top - bottom).Magnitude / 2),
			Color = woodDark,
			CanCollide = false,
		}, m)
		for _, at in { 0.04, 0.96 } do
			local p = bottom:Lerp(top, at)
			local right = slope.RightVector * side * (width / 2 + 0.3)
			newPart({
				Name = "Post",
				Size = Vector3.new(0.7, 3, 0.7),
				CFrame = CFrame.new(p + right + Vector3.new(0, 1.5, 0)),
				Color = woodDark,
			}, m)
		end
	end
end

local function emitter(props: { [string]: any }, parent: Instance): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.LightEmission = 1
	e.LightInfluence = 0
	for key, value in props do
		(e :: any)[key] = value
	end
	e.Parent = parent
	return e
end

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

-- Particles and lights described by the map's VFX_* markers.
local function effects(frame: Frame, portal: Model, parent: Instance)
	local u = frame.unit
	local folder = Instance.new("Folder")
	folder.Name = "MapFx"
	folder.Parent = parent

	local vortex = portal:FindFirstChild("Surface")
	if vortex and vortex:IsA("BasePart") then
		emitter({
			Name = "Sparkles",
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, hex("#b06cff")),
				ColorSequenceKeypoint.new(0.5, hex("#ffffff")),
				ColorSequenceKeypoint.new(1, hex("#aef4ff")),
			}),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2 * u),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.15, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Lifetime = NumberRange.new(0.7, 1.1),
			Rate = 20,
			Speed = NumberRange.new(1.5 * u, 2.5 * u),
			Shape = Enum.ParticleEmitterShape.Sphere,
			ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
			RotSpeed = NumberRange.new(-180, 180),
		}, vortex)
		local light = Instance.new("PointLight")
		light.Color = hex("#b06cff")
		light.Range = math.min(60, 9 * u)
		light.Brightness = 2
		light.Parent = vortex
	end

	-- Crystal glow rising from the plateau crystals.
	for i, p in
		{
			Vector3.new(20.92, 31.12, -16.06),
			Vector3.new(36.74, 31.12, -22.24),
			Vector3.new(32.01, 31.12, -27.05),
		}
	do
		local holder =
			fxPart("CrystalGlow" .. i, CFrame.new(worldOf(frame, p)), Vector3.one, folder)
		emitter({
			Color = ColorSequence.new(hex("#d6b4ff")),
			Size = NumberSequence.new(0.15 * u, 0),
			Lifetime = NumberRange.new(1.2),
			Rate = 6,
			Speed = NumberRange.new(0.5 * u),
			SpreadAngle = Vector2.new(25, 25),
			EmissionDirection = Enum.NormalId.Top,
		}, holder)
	end

	-- Mist where the waterfall lands.
	local mist = fxPart(
		"WaterfallMist",
		CFrame.new(worldOf(frame, Vector3.new(1.87, 24.6, -3.6))),
		Vector3.new(4 * u, 0.5, 2 * u),
		folder
	)
	emitter({
		Color = ColorSequence.new(hex("#7fe9ff"), hex("#ffffff")),
		Size = NumberSequence.new(0.12 * u, 0.25 * u),
		Transparency = NumberSequence.new(0.3, 1),
		Lifetime = NumberRange.new(0.5, 0.8),
		Rate = 20,
		Speed = NumberRange.new(0.6 * u, 1.2 * u),
		SpreadAngle = Vector2.new(70, 70),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -3 * u, 0),
		LightEmission = 0.4,
	}, mist)

	-- Golden sparkles drifting up over the whole island.
	local sparkleArea = fxPart(
		"AmbientSparkles",
		CFrame.new(worldOf(frame, Vector3.new(0, LOW + 1.5, 0))),
		Vector3.new(67 * u, 2 * u, 67 * u),
		folder
	)
	emitter({
		Color = ColorSequence.new(hex("#ffd34d"), hex("#ffffff")),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.12 * u),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(2),
		Rate = 6,
		Speed = NumberRange.new(0.3 * u, 0.7 * u),
		EmissionDirection = Enum.NormalId.Top,
	}, sparkleArea)

	-- Fireflies around the lantern by the pond, plus the lantern's own glow.
	local lanternTop = worldOf(frame, Vector3.new(16.17, 29.6, 26.04))
	local lantern = fxPart("LanternGlow", CFrame.new(lanternTop), Vector3.one, folder)
	local lanternLight = Instance.new("PointLight")
	lanternLight.Color = Color3.fromRGB(255, 200, 120)
	lanternLight.Range = math.min(60, 7 * u)
	lanternLight.Brightness = 1.5
	lanternLight.Parent = lantern
	local fireflies = fxPart(
		"Fireflies",
		CFrame.new(worldOf(frame, Vector3.new(16.17, LOW + 2.5, 26.04))),
		Vector3.new(11 * u, 3 * u, 11 * u),
		folder
	)
	emitter({
		Color = ColorSequence.new(hex("#d8ff6a")),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.1 * u),
			NumberSequenceKeypoint.new(0.7, 0.1 * u),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(3, 5),
		Rate = 1.5,
		Speed = NumberRange.new(0.2 * u, 0.5 * u),
		SpreadAngle = Vector2.new(180, 180),
		RotSpeed = NumberRange.new(-30, 30),
	}, fireflies)

	-- Soft glow under the island.
	local under = fxPart(
		"UndersideGlow",
		CFrame.new(worldOf(frame, Vector3.new(0, 6, 0))),
		Vector3.one,
		folder
	)
	local underLight = Instance.new("PointLight")
	underLight.Color = Color3.fromRGB(170, 220, 255)
	underLight.Range = math.min(60, 20 * u)
	underLight.Brightness = 1
	underLight.Shadows = false
	underLight.Parent = under
end

-- Invisible ring that stops people walking off the island by accident.
local function edgeWalls(center: Vector3, radius: number, parent: Instance)
	local count = math.max(24, math.ceil(radius * math.pi * 2 / 14))
	for i = 1, count do
		local a = i / count * math.pi * 2
		local at = center + Vector3.new(math.cos(a) * radius, 15, math.sin(a) * radius)
		newPart({
			Name = "EdgeWall",
			Size = Vector3.new(radius * math.pi * 2 / count + 2, 40, 1),
			CFrame = CFrame.lookAt(at, center + Vector3.new(0, 15, 0)),
			Transparency = 1,
			CastShadow = false,
			CanQuery = false,
			Material = Enum.Material.SmoothPlastic,
		}, parent)
	end
end

local place: (map: Model, frame: Frame, parent: Instance, center: Vector3) -> Layout

-- Clones the map into `parent`, sizes it, centres its meadow on `center`
-- and returns where everything goes. nil if the map can't be understood.
function HubMap.build(source: Model, parent: Instance, center: Vector3): Layout?
	local wasArchivable = source.Archivable
	source.Archivable = true
	local map = source:Clone()
	source.Archivable = wasArchivable
	if not map then
		warn("[Skybound] could not copy " .. source.Name .. "; using the code-built hub")
		return nil
	end
	map.Name = "IslandMap"

	local frame = measure(map)
	if not frame then
		warn("[Skybound] could not measure " .. source.Name .. "; using the code-built hub")
		map:Destroy()
		return nil
	end
	if source:IsDescendantOf(workspace) then
		source:Destroy() -- the hub owns it now; don't leave a second copy
	end

	local wanted = Config.HUB_MAP_SCALE
	if math.abs(frame.unit - wanted) > 0.01 then
		map:ScaleTo(map:GetScale() * wanted / frame.unit)
		frame = measure(map) :: Frame
	end
	-- Put the middle of the meadow (map 0, LOW, 0) on the hub centre.
	local delta = center - worldOf(frame, Vector3.new(0, LOW, 0))
	map:PivotTo(map:GetPivot() + delta)
	frame = measure(map) :: Frame
	return place(map, frame, parent, center)
end

-- Puts everything on a map that is already sized and centred.
function place(map: Model, frame: Frame, parent: Instance, center: Vector3): Layout
	local coarse = prepareParts(map)
	map.Parent = parent

	local function toWorld(x: number, y: number, z: number): Vector3
		return worldOf(frame, Vector3.new(x, y, z))
	end
	local function spot(name: string): CFrame
		local s = SPOTS[name]
		local at = toWorld(s.x, s.y, s.z)
		local face = toWorld(s.faceX, s.y, s.faceZ)
		return CFrame.lookAt(at, face)
	end

	-- The map's portal becomes Hub.Portal (the tutorial and effects look
	-- for it there); its vortex is the "Surface" the client animates.
	local portal = map:FindFirstChild("Portal", true)
	if not portal or not portal:IsA("Model") then
		local m = Instance.new("Model")
		m.Name = "Portal"
		portal = m
	end
	local portalModel = portal :: Model
	portalModel.Parent = parent
	local base = toWorld(PORTAL_BASE.X, PORTAL_BASE.Y, PORTAL_BASE.Z)
	local facing = flatDirection(frame, PORTAL_FACING.X, PORTAL_FACING.Z)
	local vortex = portalModel:FindFirstChild("Portal_Vortex", true)
	if vortex and vortex:IsA("BasePart") then
		vortex.Name = "Surface"
		vortex.Transparency = 0.25
	elseif not portalModel:FindFirstChild("Surface") then
		-- Built from triangles: add a glowing disc the client can animate.
		local at = toWorld(PORTAL_VORTEX.X, PORTAL_VORTEX.Y, PORTAL_VORTEX.Z)
		newPart({
			Name = "Surface",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 6.5 * frame.unit, 6.5 * frame.unit),
			CFrame = CFrame.lookAt(at, at + facing) * CFrame.Angles(0, math.rad(90), 0),
			Color = Color3.fromRGB(176, 108, 255),
			Material = Enum.Material.Neon,
			Transparency = 0.25,
			CanCollide = false,
			CanTouch = false,
			CanQuery = false,
			CastShadow = false,
		}, portalModel)
	end
	local vortexCenter = toWorld(PORTAL_VORTEX.X, PORTAL_VORTEX.Y, PORTAL_VORTEX.Z)
	portalModel.WorldPivot = CFrame.lookAt(vortexCenter, vortexCenter + facing)
	portalModel:SetAttribute("GroundY", base.Y)

	-- Step on the portal's base and you're in. The trigger stays a direct
	-- child of the hub so the run system can find it.
	newPart({
		Name = "PortalTrigger",
		Size = Vector3.new(12 * frame.unit, 13 * frame.unit, 12 * frame.unit),
		CFrame = CFrame.lookAt(base, base + facing) * CFrame.new(0, 6.5 * frame.unit, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Material = Enum.Material.SmoothPlastic,
	}, parent)

	-- A guaranteed solid floor on the spawn pad (the pad itself may be thin
	-- triangles or a mesh with coarse collision).
	local padSpot = SPOTS.spawn
	local padTop = toWorld(padSpot.x, padSpot.y, padSpot.z)
	newPart({
		Name = "SpawnFloor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1, 10 * frame.unit, 10 * frame.unit),
		CFrame = CFrame.new(padTop - Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Transparency = 1,
		CastShadow = false,
		CanQuery = false,
		Material = Enum.Material.SmoothPlastic,
	}, parent)

	for _, s in STAIRS do
		stairs(
			toWorld(s.top.X, s.top.Y, s.top.Z),
			toWorld(s.bottom.X, s.bottom.Y, s.bottom.Z),
			3 * frame.unit,
			parent
		)
	end
	effects(frame, portalModel, parent)
	local radius = MAP_RADIUS * frame.unit
	edgeWalls(Vector3.new(center.X, toWorld(0, LOW, 0).Y, center.Z), radius, parent)

	if #coarse > 0 then
		warn(
			string.format(
				"[Skybound] %d island meshes don't use precise collision, so walking on them may feel"
					.. " off. Run tools/setup_island.luau in the Studio command bar once. (%s)",
				#coarse,
				table.concat(coarse, ", ", 1, math.min(#coarse, 6))
			)
		)
	end

	return {
		map = map,
		portal = portalModel,
		studsPerUnit = frame.unit,
		radius = radius,
		toWorld = toWorld,
		spawn = spot("spawn"),
		daily = spot("daily"),
		upgrade = spot("upgrade"),
		gear = spot("gear"),
		potions = spot("potions"),
		quests = spot("quests"),
		leaderboard = spot("leaderboard"),
	}
end

-- One flat triangle from two wedges (thin, so it reads as a surface).
local function triangle(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	props: { [string]: any },
	parent: Instance
)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-6 or bc.Magnitude < 1e-6 then
		return
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	if height < 0.002 then
		return
	end
	for i, depth in { math.abs(ab:Dot(back)), math.abs(ac:Dot(back)) } do
		if depth >= 0.002 then
			local w = Instance.new("WedgePart")
			w.Anchored = true
			w.TopSurface = Enum.SurfaceType.Smooth
			w.BottomSurface = Enum.SurfaceType.Smooth
			w.Material = Enum.Material.SmoothPlastic
			w.Size = Vector3.new(0.15, height, depth)
			w.CFrame = if i == 1
				then CFrame.fromMatrix((a + b) / 2, right, up, back)
				else CFrame.fromMatrix((a + c) / 2, -right, up, -back)
			for key, value in props do
				(w :: any)[key] = value
			end
			w.Parent = parent
		end
	end
end

local function numbers(s: string): { number }
	local out = {}
	for token in string.gmatch(s, "%-?%d+") do
		table.insert(out, tonumber(token) :: number)
	end
	return out
end

-- Rebuilds the island from baked triangle data (Lib/IslandMesh), so it
-- needs no 3D import at all: it syncs into Studio with the rest of the code.
function HubMap.buildBaked(parent: Instance, center: Vector3): Layout?
	local lib = script.Parent.Parent:FindFirstChild("Lib")
	local dataModule = lib and lib:FindFirstChild("IslandMesh")
	if not dataModule or not dataModule:IsA("ModuleScript") then
		return nil
	end
	local data = (require :: any)(dataModule)
	local u = Config.HUB_MAP_SCALE
	local g = REF_POINTS.Island_Grass
	local frame: Frame = {
		origin = center + Vector3.new(g.X * u, (g.Y - LOW) * u, g.Z * u),
		ax = Vector3.new(u, 0, 0),
		az = Vector3.new(0, 0, u),
		unit = u,
	}
	local palette: { Color3 } = {}
	for i, hex in data.palette do
		palette[i] = Color3.fromHex(hex)
	end

	local map = Instance.new("Model")
	map.Name = "IslandMap"
	local groups: { [string]: Model } = {}
	for _, mesh in data.meshes do
		local groupName = string.match(mesh.name, "^[^_]+") or mesh.name
		local group = groups[groupName]
		if not group then
			group = Instance.new("Model")
			group.Name = groupName
			group.Parent = map
			groups[groupName] = group
		end
		local holder = Instance.new("Model")
		holder.Name = mesh.name
		holder.Parent = group
		local v = numbers(mesh.verts)
		local t = numbers(mesh.tris)
		local function vertex(i: number): Vector3
			local k = (i - 1) * 3
			return worldOf(frame, Vector3.new(v[k + 1], v[k + 2], v[k + 3]) / 100)
		end
		local decor = isDecor(mesh.name)
		for k = 1, #t, 4 do
			triangle(vertex(t[k]), vertex(t[k + 1]), vertex(t[k + 2]), {
				Name = mesh.name,
				Color = palette[t[k + 3]],
				CastShadow = not decor,
			}, holder)
		end
	end
	return place(map, frame, parent, center)
end

return HubMap
