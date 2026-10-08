--!strict
-- Deterministic procedural tower generation. Client and server both call
-- Generator.chunk(seed, index) and get identical layouts: the client renders
-- them, the server uses them to validate pickups.
--
-- Fairness guarantee: every chunk has a "spine" of solid platforms whose
-- vertical gaps stay below the base jump apex and whose horizontal steps stay
-- within MAX_HORIZONTAL_STEP, and the last spine platform of each chunk steers
-- toward the first spine platform of the next. Hazards are placed away from
-- the spine. Coordinates are relative to the run origin (x = lane offset,
-- y = studs above the start).

local Config = require(script.Parent.Config)
local Types = require(script.Parent.Types)

type Chunk = Types.Chunk
type PlatformData = Types.PlatformData
type PickupData = Types.PickupData
type HazardData = Types.HazardData

local Gen = Config.Generation
local Haz = Config.Hazards
local Pick = Config.Pickups
local HALF = Config.RUN_HALF_WIDTH

local Generator = {}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function rngFor(seed: number, index: number, salt: number): Random
	return Random.new((seed * 7919 + index * 104729 + salt * 31) % 2147483647)
end

function Generator.difficulty(chunkIndex: number): number
	local meters = chunkIndex * Gen.CHUNK_HEIGHT * Config.METERS_PER_STUD
	return math.clamp(meters / Gen.DIFFICULTY_FULL_AT, 0, 1)
end

-- X position of the first spine platform of a chunk (shared with the
-- previous chunk so it can steer toward it).
local function entryX(seed: number, index: number): number
	if index == 0 then
		return 0
	end
	return rngFor(seed, index, 1):NextNumber(-HALF + 8, HALF - 8)
end

local function pickKind(rng: Random, d: number, allowFake: boolean): string
	local total = 0
	local weights: { { kind: string, w: number } } = {}
	for kind, def in Config.Platforms do
		if kind ~= "fake" or allowFake then
			local w = lerp(def.weightEasy, def.weightHard, d)
			if w > 0 then
				table.insert(weights, { kind = kind :: string, w = w })
				total += w
			end
		end
	end
	table.sort(weights, function(a, b)
		return a.kind < b.kind
	end)
	local roll = rng:NextNumber() * total
	for _, entry in weights do
		roll -= entry.w
		if roll <= 0 then
			return entry.kind
		end
	end
	return "normal"
end

local function tutorialChunk(): Chunk
	local platforms: { PlatformData } = {}
	local pickups: { PickupData } = {}
	local hazards: { HazardData } = {}
	local nextId = 0
	local function plat(kind: string, x: number, y: number, width: number, moveRange: number?)
		nextId += 1
		table.insert(platforms, {
			id = nextId,
			kind = kind,
			x = x,
			y = y,
			width = width,
			moveRange = moveRange or 0,
			moveSpeed = 0.8,
			phase = 0,
		})
	end
	local function pickup(kind: string, x: number, y: number, potion: string?)
		nextId += 1
		table.insert(pickups, {
			id = nextId,
			kind = kind,
			x = x,
			y = y,
			value = 1,
			potion = potion,
			risky = false,
		})
	end

	-- 1. Big safe start + side-to-side practice.
	plat("normal", 0, 0, HALF * 2)
	plat("normal", -14, 12, 22)
	plat("normal", 14, 24, 22)
	-- 2. A simple gap.
	plat("normal", -6, 38, 20)
	-- 3. Coin cluster.
	plat("normal", 10, 50, 20)
	for i = 0, 4 do
		pickup("coin", 10 + (i - 2) * 3.5, 56 + math.sin(i / 4 * math.pi) * 3)
	end
	plat("normal", -8, 62, 20)
	-- 4. Bounce pad + boost.
	plat("bounce", 0, 74, 16)
	plat("normal", 6, 110, 18)
	-- 5. Very obvious hazard, safe route to the side.
	nextId += 1
	table.insert(hazards, {
		id = nextId,
		kind = "spike",
		x = 14,
		y = 124,
		radius = 3,
		moveRange = 0,
		moveSpeed = 0,
		phase = 0,
	})
	plat("normal", -12, 122, 18)
	-- 6. First potion.
	plat("normal", 0, 136, 18)
	pickup("potion", 0, 142, "luck")
	plat("normal", 0, 150, HALF * 2) -- full width: any next-chunk entry is reachable

	return {
		index = 0,
		platforms = platforms,
		pickups = pickups,
		hazards = hazards,
		prompts = {
			{ y = 0, text = "MOVE LEFT AND RIGHT" },
			{ y = 30, text = "LAND ON THE NEXT PLATFORM" },
			{ y = 46, text = "COLLECT COINS" },
			{ y = 66, text = "PINK PADS LAUNCH YOU — HOLD BOOST FOR THRUST" },
			{ y = 112, text = "WATCH OUT!" },
			{ y = 130, text = "POTIONS GIVE TEMPORARY BONUSES" },
			{ y = 156, text = "" },
		},
		spine = #platforms,
	}
end

function Generator.chunk(seed: number, index: number, tutorial: boolean): Chunk
	if index == 0 and tutorial then
		return tutorialChunk()
	end

	local rng = rngFor(seed, index, 0)
	local d = Generator.difficulty(index)
	local chunkStart = index * Gen.CHUNK_HEIGHT
	local platforms: { PlatformData } = {}
	local pickups: { PickupData } = {}
	local hazards: { HazardData } = {}
	local nextId = index * 1000

	local function newId(): number
		nextId += 1
		return nextId
	end

	local meters = chunkStart * Config.METERS_PER_STUD

	-- Spine: the guaranteed route. Each step is limited so that, including
	-- moving-platform travel, the next platform is always within jump reach,
	-- and every platform stays close enough to the next chunk's entry that the
	-- remaining steps can still get there.
	local targetGap = lerp(
		rng:NextNumber(Gen.MIN_GAP_EASY, Gen.MAX_GAP_EASY),
		rng:NextNumber(Gen.MIN_GAP_HARD, Gen.MAX_GAP_HARD),
		d
	)
	local count = math.max(4, math.ceil(Gen.CHUNK_HEIGHT / targetGap))
	local gap = Gen.CHUNK_HEIGHT / count
	local width = lerp(Gen.WIDTH_EASY, Gen.WIDTH_HARD, d)
	local maxRange = 4 + 5 * d
	local step = Gen.MAX_HORIZONTAL_STEP
	local exitX = entryX(seed, index + 1)
	local spine: { PlatformData } = {}
	local prevX, prevRange = 0, 0
	for i = 0, count - 1 do
		local y = chunkStart + i * gap
		if i > 0 then
			y += rng:NextNumber(-0.08, 0.08) * gap
		end
		local first = i == 0
		local w = if index == 0 and first then HALF * 2 else width * rng:NextNumber(0.85, 1.15)
		local kind = if index == 0 and first then "normal" else pickKind(rng, d, false)
		if first and kind == "moving" then
			kind = "normal" -- chunk entries sit exactly where the previous chunk aimed
		end
		local range = if kind == "moving" then rng:NextNumber(3, maxRange) else 0
		local x
		if first then
			x = entryX(seed, index)
		else
			local budget = step - prevRange - range
			local reachExit = (step - 2 * maxRange) * (count - i)
			local lo = math.max(prevX - budget, exitX - reachExit, -HALF + w / 2)
			local hi = math.min(prevX + budget, exitX + reachExit, HALF - w / 2)
			x = if lo <= hi
				then rng:NextNumber(lo, hi)
				else math.clamp(exitX, -HALF + w / 2, HALF - w / 2)
		end
		local platform: PlatformData = {
			id = newId(),
			kind = kind,
			x = x,
			y = y,
			width = w,
			moveRange = range,
			moveSpeed = if kind == "moving" then rng:NextNumber(0.6, 0.9 + 0.8 * d) else 0,
			phase = rng:NextNumber(0, math.pi * 2),
		}
		table.insert(platforms, platform)
		table.insert(spine, platform)
		prevX, prevRange = x, range
	end

	-- Black hole: only on the side away from the route, or not at all.
	local blackHoleX: number? = nil
	local blackHoleY = chunkStart + Gen.CHUNK_HEIGHT * 0.5
	if meters >= Haz.BLACK_HOLE_FROM and rng:NextNumber() < Haz.BLACK_HOLE_CHANCE then
		local sum, n = 0, 0
		for _, p in spine do
			if math.abs(p.y - blackHoleY) < Haz.BLACK_HOLE_PULL_RADIUS then
				sum += p.x
				n += 1
			end
		end
		local candidate = if n > 0 and sum / n > 0 then -HALF + 4 else HALF - 4
		local clear = true
		for _, p in spine do
			if math.abs(p.y - blackHoleY) < Haz.BLACK_HOLE_PULL_RADIUS then
				local edge = math.abs(p.x - candidate) - p.width / 2 - p.moveRange
				if edge < 16 then
					clear = false
				end
			end
		end
		if clear then
			blackHoleX = candidate
		end
	end

	-- Extra side platforms (some are decoys at higher difficulty).
	local extras = rng:NextInteger(2, 4)
	for _ = 1, extras do
		local w = width * rng:NextNumber(0.8, 1.1)
		table.insert(platforms, {
			id = newId(),
			kind = pickKind(rng, d, true),
			x = rng:NextNumber(-HALF + w / 2, HALF - w / 2),
			y = chunkStart + rng:NextNumber(gap * 0.5, Gen.CHUNK_HEIGHT - gap * 0.5),
			width = w,
			moveRange = 0,
			moveSpeed = 0,
			phase = 0,
		})
	end

	-- Spike balls between spine platforms, kept away from the route.
	local spikeChance = if meters >= Haz.SPIKE_BALL_FROM
		then lerp(Haz.SPIKE_BALL_CHANCE_EASY, Haz.SPIKE_BALL_CHANCE_HARD, d)
		else 0
	for i = 2, #spine - 1 do
		if rng:NextNumber() < spikeChance then
			local a, b = spine[i], spine[i + 1]
			local midX = (a.x + b.x) / 2
			local hx = if midX > 0
				then midX - rng:NextNumber(18, 24)
				else midX + rng:NextNumber(18, 24)
			hx = math.clamp(hx, -HALF + 3, HALF - 3)
			local hy = (a.y + b.y) / 2
			local spikeRange = if rng:NextNumber() < d then rng:NextNumber(2, 5) else 0
			local clearA = math.abs(hx - a.x) - a.width / 2 - a.moveRange - spikeRange
			local clearB = math.abs(hx - b.x) - b.width / 2 - b.moveRange - spikeRange
			if clearA > 7 and clearB > 7 then
				table.insert(hazards, {
					id = newId(),
					kind = "spike",
					x = hx,
					y = hy,
					radius = 2.6,
					moveRange = spikeRange,
					moveSpeed = rng:NextNumber(0.8, 1.6),
					phase = rng:NextNumber(0, math.pi * 2),
				})
				-- Risk/reward: a bonus coin arc right next to the hazard.
				if rng:NextNumber() < 0.6 then
					for k = -1, 1 do
						table.insert(pickups, {
							id = newId(),
							kind = "coin",
							x = hx + (if hx > 0 then -5 else 5),
							y = hy + k * 3.5,
							value = Pick.RISKY_COIN_BONUS,
							risky = true,
						})
					end
				end
			end
		end
	end

	if blackHoleX then
		table.insert(hazards, {
			id = newId(),
			kind = "blackhole",
			x = blackHoleX,
			y = blackHoleY,
			radius = Haz.BLACK_HOLE_KILL_RADIUS,
			moveRange = 0,
			moveSpeed = 0,
			phase = 0,
		})
		-- Valuable bait near the black hole.
		table.insert(pickups, {
			id = newId(),
			kind = "capsule",
			x = blackHoleX * 0.55,
			y = blackHoleY + 10,
			value = 1,
			risky = true,
		})
	end

	-- Coin clusters above random spine platforms.
	for _ = 1, Pick.COIN_CLUSTERS do
		local p = spine[rng:NextInteger(1, #spine)]
		for k = 0, Pick.COINS_PER_CLUSTER - 1 do
			local t = k / (Pick.COINS_PER_CLUSTER - 1)
			table.insert(pickups, {
				id = newId(),
				kind = "coin",
				x = math.clamp(p.x + (t - 0.5) * 12, -HALF + 1, HALF - 1),
				y = p.y + 5 + math.sin(t * math.pi) * 4,
				value = Pick.COIN_VALUE,
				risky = false,
			})
		end
	end

	local function placeSpecial(kind: string, potion: string?)
		local p = spine[rng:NextInteger(2, #spine)]
		table.insert(pickups, {
			id = newId(),
			kind = kind,
			x = p.x,
			y = p.y + 8,
			value = 1,
			potion = potion,
			risky = false,
		})
	end
	if rng:NextNumber() < Pick.GEM_CHANCE then
		placeSpecial("gem", nil)
	end
	if rng:NextNumber() < Pick.POTION_CHANCE then
		local pool = { "luck", "coin", "jump", "magnet" }
		placeSpecial("potion", pool[rng:NextInteger(1, #pool)])
	end
	if index > 0 and rng:NextNumber() < Pick.CAPSULE_CHANCE then
		-- Capsules sit off the main route: reaching one is a choice.
		local p = spine[rng:NextInteger(2, #spine)]
		local cx = if p.x > 0 then p.x - 20 else p.x + 20
		table.insert(pickups, {
			id = newId(),
			kind = "capsule",
			x = math.clamp(cx, -HALF + 3, HALF - 3),
			y = p.y + 6,
			value = 1,
			risky = true,
		})
	end

	return {
		index = index,
		platforms = platforms,
		pickups = pickups,
		hazards = hazards,
		prompts = {},
		spine = #spine,
	}
end

return Generator
