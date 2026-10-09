--!strict
-- Skybound live-tuning values. Every balance number lives here so pacing can
-- be adjusted after analytics come in without touching gameplay code.
-- NOTE: replicated to clients — nothing secret here, and the server never
-- trusts a client-reported value from this file.

export type Reward = {
	coins: number?,
	gems: number?,
	potions: { [string]: number }?,
	label: string?,
}

export type UpgradeDef = {
	id: string,
	name: string,
	description: string,
	maxLevel: number,
	perLevel: number, -- value gained each level
	unit: string, -- "%" or "" for display
	baseCost: number,
	costGrowth: number,
}

export type PotionDef = {
	id: string,
	name: string,
	description: string,
	icon: string,
	color: Color3,
	duration: number, -- seconds; 0 = single-use charge
	price: number, -- coins in the Skybrew stall
}

export type PlatformDef = {
	color: Color3,
	weightEasy: number,
	weightHard: number,
}

export type GearDef = {
	id: string,
	name: string,
	description: string,
	rarity: string,
	kind: string,
	fuel: number, -- seconds of thrust at boost level 0
	thrust: number, -- upward acceleration (studs/s^2)
	maxRise: number, -- cap on upward speed while thrusting
	price: number,
}

export type WorldDef = {
	id: string,
	name: string,
	startHeight: number,
	skyTop: Color3,
	skyBottom: Color3,
	platformColor: Color3,
	accentColor: Color3,
	fogColor: Color3,
}

local Config = {}

Config.GAME_NAME = "Skybound"
Config.DATASTORE_NAME = "SkyboundData_v1"
Config.LEADERBOARD_STORE = "SkyboundBestHeight_v1"
Config.AUTOSAVE_INTERVAL = 90

-- One stud of climb = this many metres on the HUD.
Config.METERS_PER_STUD = 1

-- World layout ---------------------------------------------------------------
Config.HUB_CENTER = Vector3.new(0, 100, 0)
Config.RUN_ORIGIN = Vector3.new(4000, 800, 0) -- first run lane
Config.RUN_LANE_SPACING = 400 -- each player climbs in their own lane
Config.RUN_HALF_WIDTH = 30 -- playable area is origin.X +/- this

-- Movement -------------------------------------------------------------------
Config.Movement = table.freeze({
	GRAVITY = 140,
	JUMP_VELOCITY = 82,
	BOUNCE_PAD_MULTIPLIER = 1.75,
	MOVE_SPEED = 40,
	AIR_ACCEL = 320, -- how fast horizontal speed reaches its target
	MAX_FALL_SPEED = 160,
	CAMERA_DISTANCE = 95,
	CAMERA_FOV = 50,
	DEATH_BELOW_CAMERA = 50, -- studs below camera centre that ends the run
	JETPACK_FUEL_REFILL_ON_BOUNCE = 0.2, -- fraction of max fuel per landing
})

-- Server-side sanity limits used to reject impossible movement.
Config.AntiCheat = table.freeze({
	MAX_RISE_SPEED = 260, -- studs/s, above the best legit combination
	RISE_TOLERANCE = 30, -- studs of slack per check for lag spikes
	PICKUP_RANGE = 14, -- studs between player and pickup when collected
	MAGNET_EXTRA_RANGE = 26,
	MAX_STRIKES = 6,
})

-- Generation -----------------------------------------------------------------
Config.Generation = table.freeze({
	CHUNK_HEIGHT = 160,
	CHUNKS_AHEAD = 2,
	CHUNKS_BEHIND = 1,
	-- Gap between guaranteed platforms grows with height (studs).
	MIN_GAP_EASY = 9,
	MAX_GAP_EASY = 13,
	MIN_GAP_HARD = 14,
	MAX_GAP_HARD = 18, -- with 8% jitter must stay under the base jump apex (~24)
	MAX_HORIZONTAL_STEP = 26,
	WIDTH_EASY = 16,
	WIDTH_HARD = 8,
	DIFFICULTY_FULL_AT = 30000, -- metres where difficulty reaches 1
	TUTORIAL_HEIGHT = 300, -- studs covered by the beginner section
})

-- Platform kinds and how often they appear (weights scale with difficulty).
Config.Platforms = table.freeze({
	normal = { color = Color3.fromRGB(122, 214, 120), weightEasy = 10, weightHard = 4 },
	bounce = { color = Color3.fromRGB(255, 120, 200), weightEasy = 1, weightHard = 1.5 },
	moving = { color = Color3.fromRGB(110, 180, 255), weightEasy = 0.5, weightHard = 3 },
	breaking = { color = Color3.fromRGB(205, 160, 110), weightEasy = 0.3, weightHard = 2.5 },
	ice = { color = Color3.fromRGB(190, 240, 255), weightEasy = 0, weightHard = 1.5 },
	fake = { color = Color3.fromRGB(122, 214, 120), weightEasy = 0, weightHard = 0.8 },
} :: { [string]: PlatformDef })

-- Hazards unlock as the player climbs (metres).
Config.Hazards = table.freeze({
	SPIKE_BALL_FROM = 600,
	SPIKE_BALL_CHANCE_EASY = 0.15,
	SPIKE_BALL_CHANCE_HARD = 0.55,
	BLACK_HOLE_FROM = 2500,
	BLACK_HOLE_CHANCE = 0.18, -- per chunk
	BLACK_HOLE_PULL_RADIUS = 34,
	BLACK_HOLE_KILL_RADIUS = 4,
	BLACK_HOLE_STRENGTH = 210,
})

-- Pickups (per chunk).
Config.Pickups = table.freeze({
	COIN_CLUSTERS = 3,
	COINS_PER_CLUSTER = 5,
	COIN_VALUE = 1,
	GEM_CHANCE = 0.12,
	POTION_CHANCE = 0.1,
	CAPSULE_CHANCE = 0.22,
	RISKY_COIN_BONUS = 3, -- coins in risky routes count this many times
})

-- Loot capsules: rarity weights before Luck.
Config.Rarities = table.freeze({
	{ id = "Common", weight = 600, color = Color3.fromRGB(200, 205, 215) },
	{ id = "Uncommon", weight = 250, color = Color3.fromRGB(120, 220, 120) },
	{ id = "Rare", weight = 100, color = Color3.fromRGB(80, 160, 255) },
	{ id = "Epic", weight = 35, color = Color3.fromRGB(180, 100, 255) },
	{ id = "Legendary", weight = 12, color = Color3.fromRGB(255, 190, 60) },
	{ id = "Mythic", weight = 2.7, color = Color3.fromRGB(255, 80, 120) },
	{ id = "Secret", weight = 0.3, color = Color3.fromRGB(40, 40, 40) },
})

-- Each Luck point multiplies non-common weights by (1 + luck * LUCK_SCALE).
Config.LUCK_SCALE = 0.01

Config.CapsuleRewards = table.freeze({
	Common = { coins = 25 },
	Uncommon = { coins = 60, potions = { jump = 1 } },
	Rare = { coins = 120, gems = 2 },
	Epic = { coins = 250, gems = 5, potions = { luck = 1 } },
	Legendary = { coins = 600, gems = 15, potions = { luck = 2, coin = 1 } },
	Mythic = { coins = 1500, gems = 40, potions = { luck = 3, shield = 2 } },
	Secret = { coins = 5000, gems = 120, potions = { luck = 5, coin = 3 } },
} :: { [string]: Reward })

-- Economy -------------------------------------------------------------------
Config.Upgrades = table.freeze({
	{
		id = "jumpPower",
		name = "Jump Power",
		description = "Every bounce launches you higher.",
		maxLevel = 40,
		perLevel = 2,
		unit = "%",
		baseCost = 120,
		costGrowth = 1.22,
	},
	{
		id = "airControl",
		name = "Air Control",
		description = "Change direction faster in mid-air.",
		maxLevel = 30,
		perLevel = 4,
		unit = "%",
		baseCost = 100,
		costGrowth = 1.2,
	},
	{
		id = "luck",
		name = "Luck",
		description = "Better capsules, more gems and rarer finds.",
		maxLevel = 50,
		perLevel = 5,
		unit = "",
		baseCost = 150,
		costGrowth = 1.2,
	},
	{
		id = "boostDuration",
		name = "Boost Duration",
		description = "More jetpack fuel per run.",
		maxLevel = 30,
		perLevel = 6,
		unit = "%",
		baseCost = 130,
		costGrowth = 1.21,
	},
	{
		id = "voidResistance",
		name = "Void Resistance",
		description = "Black holes pull you less.",
		maxLevel = 25,
		perLevel = 3,
		unit = "%",
		baseCost = 200,
		costGrowth = 1.24,
	},
} :: { UpgradeDef })

Config.Potions = table.freeze({
	{
		id = "luck",
		name = "Luck Potion",
		description = "+100 Luck",
		icon = "🍀",
		color = Color3.fromRGB(90, 220, 110),
		duration = 300,
		price = 400,
	},
	{
		id = "coin",
		name = "Coin Potion",
		description = "2x Coins",
		icon = "💰",
		color = Color3.fromRGB(255, 205, 60),
		duration = 300,
		price = 500,
	},
	{
		id = "jump",
		name = "Jump Potion",
		description = "+20% Jump Power",
		icon = "🦘",
		color = Color3.fromRGB(110, 190, 255),
		duration = 300,
		price = 350,
	},
	{
		id = "magnet",
		name = "Magnet Potion",
		description = "Pulls nearby coins",
		icon = "🧲",
		color = Color3.fromRGB(240, 90, 90),
		duration = 180,
		price = 300,
	},
	{
		id = "shield",
		name = "Shield Potion",
		description = "Survive one hazard",
		icon = "🛡️",
		color = Color3.fromRGB(170, 140, 255),
		duration = 0,
		price = 600,
	},
} :: { PotionDef })

Config.PotionEffects = table.freeze({
	LUCK_BONUS = 100,
	COIN_MULTIPLIER = 2,
	JUMP_BONUS = 0.2,
	MAGNET_RADIUS = 24,
})

Config.MAX_POTION_STACK = 99

Config.Gear = table.freeze({
	{
		id = "jetpack_basic",
		name = "Starter Jetpack",
		description = "Hold BOOST for a burst of upward thrust.",
		rarity = "Common",
		kind = "jetpack",
		fuel = 1.6,
		thrust = 420,
		maxRise = 95,
		price = 0,
	},
	{
		id = "jetpack_turbo",
		name = "Turbo Jetpack",
		description = "Longer burn and stronger thrust.",
		rarity = "Rare",
		kind = "jetpack",
		fuel = 2.4,
		thrust = 520,
		maxRise = 115,
		price = 6000,
	},
} :: { GearDef })

-- Daily rewards: a 7-day cycle. Missing a day never resets progress; the
-- next claim simply continues the cycle.
Config.DailyRewards = table.freeze({
	{ coins = 500, potions = { luck = 2, jump = 1, coin = 1 }, label = "Starter Pack" },
	{ coins = 750, potions = { magnet = 1 }, label = "Coins + Magnet" },
	{ coins = 500, gems = 10, potions = { luck = 1 }, label = "Gems + Luck" },
	{ coins = 1000, potions = { shield = 2 }, label = "Shields" },
	{ coins = 1500, potions = { jump = 2, coin = 1 }, label = "Climber Kit" },
	{ coins = 2000, gems = 20, label = "Big Bundle" },
	{
		coins = 4000,
		gems = 50,
		potions = { luck = 3, coin = 2, shield = 2 },
		label = "Weekly Jackpot",
	},
} :: { Reward })

-- Playtime rewards (minutes since joining this session).
Config.PlaytimeRewards = table.freeze({
	{ minutes = 5, reward = { coins = 500, label = "500 Coins" } :: Reward },
	{
		minutes = 10,
		reward = { potions = { jump = 1, magnet = 1 }, label = "2 Potions" } :: Reward,
	},
	{ minutes = 20, reward = { gems = 15, label = "15 Gems" } :: Reward },
	{
		minutes = 30,
		reward = { coins = 1500, potions = { coin = 1 }, label = "Coin Boost" } :: Reward,
	},
	{
		minutes = 45,
		reward = { coins = 2500, potions = { shield = 1 }, label = "Shield Pack" } :: Reward,
	},
	{
		minutes = 60,
		reward = { gems = 40, potions = { luck = 2 }, label = "Lucky Bundle" } :: Reward,
	},
})

-- Height milestones (metres) and their one-time rewards.
Config.Milestones = table.freeze({
	{ height = 500, reward = { coins = 150 } :: Reward },
	{ height = 1000, reward = { coins = 300, potions = { luck = 1 } } :: Reward },
	{ height = 2500, reward = { coins = 600, gems = 5 } :: Reward },
	{ height = 5000, reward = { coins = 1200, gems = 10 } :: Reward },
	{ height = 10000, reward = { coins = 2500, gems = 20, potions = { shield = 2 } } :: Reward },
	{ height = 25000, reward = { coins = 6000, gems = 40 } :: Reward },
	{ height = 50000, reward = { coins = 15000, gems = 80 } :: Reward },
	{ height = 100000, reward = { coins = 40000, gems = 200 } :: Reward },
})

Config.Worlds = table.freeze({
	{
		id = "cloud",
		name = "Cloud Valley",
		startHeight = 0,
		skyTop = Color3.fromRGB(110, 190, 255),
		skyBottom = Color3.fromRGB(200, 235, 255),
		platformColor = Color3.fromRGB(122, 214, 120),
		accentColor = Color3.fromRGB(255, 255, 255),
		fogColor = Color3.fromRGB(205, 232, 255),
	},
	{
		id = "jungle",
		name = "Sky Jungle",
		startHeight = 5000,
		skyTop = Color3.fromRGB(90, 200, 170),
		skyBottom = Color3.fromRGB(200, 250, 200),
		platformColor = Color3.fromRGB(70, 170, 80),
		accentColor = Color3.fromRGB(255, 220, 90),
		fogColor = Color3.fromRGB(185, 240, 205),
	},
	{
		id = "lava",
		name = "Lava Heights",
		startHeight = 15000,
		skyTop = Color3.fromRGB(255, 120, 80),
		skyBottom = Color3.fromRGB(255, 210, 150),
		platformColor = Color3.fromRGB(120, 90, 85),
		accentColor = Color3.fromRGB(255, 120, 40),
		fogColor = Color3.fromRGB(255, 190, 150),
	},
	{
		id = "frozen",
		name = "Frozen Heights",
		startHeight = 35000,
		skyTop = Color3.fromRGB(150, 200, 255),
		skyBottom = Color3.fromRGB(235, 245, 255),
		platformColor = Color3.fromRGB(200, 235, 255),
		accentColor = Color3.fromRGB(120, 200, 255),
		fogColor = Color3.fromRGB(230, 242, 255),
	},
	{
		id = "cosmic",
		name = "Cosmic Heights",
		startHeight = 75000,
		skyTop = Color3.fromRGB(40, 30, 90),
		skyBottom = Color3.fromRGB(120, 80, 190),
		platformColor = Color3.fromRGB(160, 120, 255),
		accentColor = Color3.fromRGB(255, 240, 140),
		fogColor = Color3.fromRGB(90, 70, 160),
	},
	{
		id = "void",
		name = "The Void",
		startHeight = 150000,
		skyTop = Color3.fromRGB(10, 5, 25),
		skyBottom = Color3.fromRGB(60, 20, 90),
		platformColor = Color3.fromRGB(90, 60, 140),
		accentColor = Color3.fromRGB(200, 90, 255),
		fogColor = Color3.fromRGB(40, 20, 60),
	},
} :: { WorldDef })

-- Onboarding steps shown by the world-space waypoint arrows.
-- Quests. `kind` is what is tracked; "best" kinds use the best single-run
-- value, the rest add up. Daily quests draw DAILY_QUEST_COUNT from the daily
-- pool each UTC day; weekly ones draw WEEKLY_QUEST_COUNT each week.
export type QuestDef = {
	id: string,
	kind: string, -- "height" | "coins" | "runs" | "potions" | "capsules" | "gems"
	target: number,
	text: string,
	reward: Reward,
}

Config.DAILY_QUEST_COUNT = 3
Config.WEEKLY_QUEST_COUNT = 2

Config.DailyQuests = table.freeze({
	{
		id = "d_height_1500",
		kind = "height",
		target = 1500,
		text = "Reach 1,500m in one run",
		reward = { coins = 400 },
	},
	{
		id = "d_height_3000",
		kind = "height",
		target = 3000,
		text = "Reach 3,000m in one run",
		reward = { coins = 700, gems = 3 },
	},
	{
		id = "d_coins_150",
		kind = "coins",
		target = 150,
		text = "Collect 150 coins",
		reward = { coins = 300 },
	},
	{
		id = "d_coins_400",
		kind = "coins",
		target = 400,
		text = "Collect 400 coins",
		reward = { coins = 600, potions = { coin = 1 } },
	},
	{
		id = "d_runs_5",
		kind = "runs",
		target = 5,
		text = "Complete 5 runs",
		reward = { coins = 350, potions = { jump = 1 } },
	},
	{
		id = "d_potions_2",
		kind = "potions",
		target = 2,
		text = "Use 2 potions",
		reward = { coins = 300, potions = { luck = 1 } },
	},
	{
		id = "d_capsules_1",
		kind = "capsules",
		target = 1,
		text = "Open 1 capsule",
		reward = { coins = 400, gems = 2 },
	},
	{ id = "d_gems_2", kind = "gems", target = 2, text = "Find 2 gems", reward = { coins = 500 } },
} :: { QuestDef })

Config.WeeklyQuests = table.freeze({
	{
		id = "w_height_15000",
		kind = "height",
		target = 15000,
		text = "Reach 15,000m in one run",
		reward = { coins = 4000, gems = 25 },
	},
	{
		id = "w_runs_25",
		kind = "runs",
		target = 25,
		text = "Complete 25 runs",
		reward = { coins = 3000, potions = { luck = 2, shield = 1 } },
	},
	{
		id = "w_capsules_8",
		kind = "capsules",
		target = 8,
		text = "Open 8 capsules",
		reward = { coins = 3500, gems = 20 },
	},
	{
		id = "w_coins_3000",
		kind = "coins",
		target = 3000,
		text = "Collect 3,000 coins",
		reward = { coins = 5000 },
	},
	{
		id = "w_potions_10",
		kind = "potions",
		target = 10,
		text = "Use 10 potions",
		reward = { gems = 30, potions = { coin = 2 } },
	},
} :: { QuestDef })

Config.TutorialSteps = table.freeze({
	{ id = "daily", target = "DailyStand", text = "CLAIM YOUR FREE REWARD" },
	{ id = "upgrade", target = "UpgradeStation", text = "LET'S MAKE YOU STRONGER" },
	{ id = "gear", target = "GearStall", text = "EQUIP YOUR FIRST BOOST" },
	{ id = "portal", target = "Portal", text = "YOUR FIRST RUN STARTS HERE" },
})

-- Sounds: rbxasset:// files ship with every Roblox client. Swap these for
-- original uploaded audio (rbxassetid://...) when it's ready.
Config.Sounds = table.freeze({
	Bounce = "rbxasset://sounds/action_jump.mp3",
	Coin = "rbxasset://sounds/electronicpingshort.wav",
	Click = "rbxasset://sounds/button.wav",
	Reward = "rbxasset://sounds/electronicpingshort.wav",
	Death = "rbxasset://sounds/uuhhh.mp3",
	Boost = "rbxasset://sounds/action_falling.mp3",
})

return table.freeze(Config)
