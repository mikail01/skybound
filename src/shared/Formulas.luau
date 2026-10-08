--!strict
-- Pure game-rule helpers shared by client and server: lookups, upgrade
-- math, luck rolls and goal text. No side effects, so both sides agree on
-- every number shown and every number granted.

local Config = require(script.Parent.Config)
local Format = require(script.Parent.Format)
local Types = require(script.Parent.Types)

type Profile = Types.Profile

local Formulas = {}

local upgradeById: { [string]: Config.UpgradeDef } = {}
for _, def in Config.Upgrades do
	upgradeById[def.id] = def
end

local potionById: { [string]: Config.PotionDef } = {}
for _, def in Config.Potions do
	potionById[def.id] = def
end

local gearById: { [string]: Config.GearDef } = {}
for _, def in Config.Gear do
	gearById[def.id] = def
end

function Formulas.upgrade(id: string): Config.UpgradeDef?
	return upgradeById[id]
end

function Formulas.potion(id: string): Config.PotionDef?
	return potionById[id]
end

function Formulas.gear(id: string): Config.GearDef?
	return gearById[id]
end

function Formulas.upgradeValue(id: string, level: number): number
	local def = upgradeById[id]
	if not def then
		return 0
	end
	return level * def.perLevel
end

function Formulas.upgradeCost(id: string, level: number): number
	local def = upgradeById[id]
	if not def then
		return math.huge
	end
	return math.floor(def.baseCost * def.costGrowth ^ level / 5 + 0.5) * 5
end

function Formulas.effectActive(profile: Profile, id: string): boolean
	return (profile.effects[id] or 0) > 0
end

function Formulas.luck(profile: Profile): number
	local luck = Formulas.upgradeValue("luck", profile.upgrades.luck or 0)
	if Formulas.effectActive(profile, "luck") then
		luck += Config.PotionEffects.LUCK_BONUS
	end
	return luck
end

-- Rarity weights after Luck. Common stays fixed; everything rarer scales up.
function Formulas.rarityWeights(luck: number): { { id: string, weight: number } }
	local out = {}
	local mult = 1 + luck * Config.LUCK_SCALE
	for i, r in Config.Rarities do
		table.insert(out, { id = r.id, weight = if i == 1 then r.weight else r.weight * mult })
	end
	return out
end

function Formulas.rollRarity(luck: number, rng: Random): string
	local weights = Formulas.rarityWeights(luck)
	local total = 0
	for _, w in weights do
		total += w.weight
	end
	local roll = rng:NextNumber() * total
	for _, w in weights do
		roll -= w.weight
		if roll <= 0 then
			return w.id
		end
	end
	return weights[1].id
end

-- Chance (0-1) of each rarity, used to show players what Luck does.
function Formulas.rarityChances(luck: number): { { id: string, chance: number } }
	local weights = Formulas.rarityWeights(luck)
	local total = 0
	for _, w in weights do
		total += w.weight
	end
	local out = {}
	for _, w in weights do
		table.insert(out, { id = w.id, chance = w.weight / total })
	end
	return out
end

function Formulas.rarityColor(id: string): Color3
	for _, r in Config.Rarities do
		if r.id == id then
			return r.color
		end
	end
	return Color3.new(1, 1, 1)
end

function Formulas.worldForHeight(meters: number): (Config.WorldDef, number)
	local index = 1
	for i, world in Config.Worlds do
		if meters >= world.startHeight then
			index = i
		end
	end
	return Config.Worlds[index], index
end

function Formulas.runInfo(
	profile: Profile,
	seed: number,
	origin: Vector3,
	tutorial: boolean
): Types.RunInfo
	local jump = 1 + Formulas.upgradeValue("jumpPower", profile.upgrades.jumpPower or 0) / 100
	if Formulas.effectActive(profile, "jump") then
		jump += Config.PotionEffects.JUMP_BONUS
	end
	local air = 1 + Formulas.upgradeValue("airControl", profile.upgrades.airControl or 0) / 100
	local gear = if profile.gear.equipped then gearById[profile.gear.equipped] else nil
	local fuelMult = 1
		+ Formulas.upgradeValue("boostDuration", profile.upgrades.boostDuration or 0) / 100
	local voidRes = math.min(
		0.75,
		Formulas.upgradeValue("voidResistance", profile.upgrades.voidResistance or 0) / 100
	)
	return {
		seed = seed,
		origin = origin,
		tutorial = tutorial,
		bestHeight = profile.bestHeight,
		jumpMultiplier = jump,
		airMultiplier = air,
		fuel = if gear then gear.fuel * fuelMult else 0,
		thrust = if gear then gear.thrust else 0,
		maxRise = if gear then gear.maxRise else 0,
		hasJetpack = gear ~= nil and gear.kind == "jetpack",
		voidResistance = voidRes,
		magnet = Formulas.effectActive(profile, "magnet"),
		shield = profile.effects.shield or 0,
	}
end

function Formulas.nextMilestone(best: number): (number?, Config.Reward?)
	for _, m in Config.Milestones do
		if best < m.height then
			return m.height, m.reward
		end
	end
	return nil, nil
end

function Formulas.nextWorld(best: number): Config.WorldDef?
	for _, world in Config.Worlds do
		if best < world.startHeight then
			return world
		end
	end
	return nil
end

function Formulas.describeReward(reward: Config.Reward): string
	local parts = {}
	if reward.coins and reward.coins > 0 then
		table.insert(parts, Format.comma(reward.coins) .. " Coins")
	end
	if reward.gems and reward.gems > 0 then
		table.insert(parts, Format.comma(reward.gems) .. " Gems")
	end
	if reward.potions then
		for id, count in reward.potions do
			local def = potionById[id]
			if def then
				table.insert(parts, count .. "x " .. def.name)
			end
		end
	end
	return table.concat(parts, " + ")
end

-- The single most useful next goal for the hub "NEXT GOAL" card.
function Formulas.nextGoal(profile: Profile): (string, string)
	local height, reward = Formulas.nextMilestone(profile.bestHeight)
	local world = Formulas.nextWorld(profile.bestHeight)
	if world and height and world.startHeight <= height then
		return "Reach " .. Format.meters(world.startHeight), "Unlocks " .. world.name
	end
	if height and reward then
		return "Reach " .. Format.meters(height), Formulas.describeReward(reward)
	end
	return "Beat your best: " .. Format.meters(profile.bestHeight), "Climb the leaderboard"
end

-- Utc day number used by the daily reward system.
function Formulas.dayNumber(unix: number): number
	return unix // 86400
end

return Formulas
