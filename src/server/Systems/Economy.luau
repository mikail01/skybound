--!strict
-- Coin-based purchases and item use: stat upgrades, potions (buy + use +
-- timed effects) and movement gear. Every price and effect comes from
-- Config; the client only sends ids and the server validates everything.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Formulas = require(Shared.Formulas)

local Net = require(script.Parent.Parent.Lib.Net)
local PlayerData = require(script.Parent.PlayerData)
local Analytics = require(script.Parent.Analytics)
local Tutorial = require(script.Parent.Tutorial)
local Quests = require(script.Parent.Quests)
local Achievements = require(script.Parent.Achievements)

local Economy = {}

local MAX_SHIELD_CHARGES = 3

function Economy.start()
	Net.onInvoke("BuyUpgrade", 0.15, function(player, id: any)
		local profile = PlayerData.get(player)
		if not profile or typeof(id) ~= "string" then
			return { ok = false }
		end
		local def = Formulas.upgrade(id)
		if not def then
			return { ok = false }
		end
		local level = profile.upgrades[id] or 0
		if level >= def.maxLevel then
			return { ok = false, reason = "Maxed out!" }
		end
		local free = profile.freeUpgrade
		local cost = if free then 0 else Formulas.upgradeCost(id, level)
		if not PlayerData.spendCoins(player, cost) then
			return { ok = false, reason = "Not enough coins." }
		end
		profile.freeUpgrade = false
		profile.upgrades[id] = level + 1
		Analytics.funnel(player, "FirstUpgrade")
		Analytics.event(player, "UpgradeBought_" .. id, level + 1)
		Tutorial.complete(player, "upgrade")
		PlayerData.syncNow(player)
		return { ok = true, level = level + 1, free = free }
	end)

	Net.onInvoke("BuyPotion", 0.15, function(player, id: any)
		local profile = PlayerData.get(player)
		if not profile or typeof(id) ~= "string" then
			return { ok = false }
		end
		local def = Formulas.potion(id)
		if not def then
			return { ok = false }
		end
		if (profile.potions[id] or 0) >= Config.MAX_POTION_STACK then
			return { ok = false, reason = "You can't carry more." }
		end
		if not PlayerData.spendCoins(player, def.price) then
			return { ok = false, reason = "Not enough coins." }
		end
		PlayerData.addPotion(player, id, 1)
		Analytics.event(player, "PotionBought_" .. id)
		PlayerData.syncNow(player)
		return { ok = true }
	end)

	Net.onInvoke("UsePotion", 0.3, function(player, id: any)
		local profile = PlayerData.get(player)
		if not profile or typeof(id) ~= "string" then
			return { ok = false }
		end
		local def = Formulas.potion(id)
		if not def or (profile.potions[id] or 0) <= 0 then
			return { ok = false, reason = "You don't have that potion." }
		end
		if def.duration == 0 then
			-- Charge-based (shield).
			if (profile.effects[id] or 0) >= MAX_SHIELD_CHARGES then
				return { ok = false, reason = "Shield is already full." }
			end
			profile.effects[id] = (profile.effects[id] or 0) + 1
		else
			-- Using another potion of the same type extends the timer.
			profile.effects[id] = (profile.effects[id] or 0) + def.duration
		end
		profile.potions[id] -= 1
		Analytics.first(player, "FirstPotionUsed")
		Quests.record(player, "potions", 1)
		Achievements.bump(player, "potions")
		Analytics.event(player, "PotionUsed_" .. id)
		PlayerData.syncNow(player)
		return { ok = true }
	end)

	Net.onInvoke("BuyGear", 0.3, function(player, id: any)
		local profile = PlayerData.get(player)
		if not profile or typeof(id) ~= "string" then
			return { ok = false }
		end
		local def = Formulas.gear(id)
		if not def then
			return { ok = false }
		end
		if profile.gear.owned[id] then
			return { ok = false, reason = "Already owned." }
		end
		if not PlayerData.spendCoins(player, def.price) then
			return { ok = false, reason = "Not enough coins." }
		end
		profile.gear.owned[id] = true
		Achievements.check(player)
		Analytics.event(player, "GearBought_" .. id)
		PlayerData.syncNow(player)
		return { ok = true }
	end)

	Net.onInvoke("EquipGear", 0.2, function(player, id: any)
		local profile = PlayerData.get(player)
		if not profile then
			return { ok = false }
		end
		if id == nil then
			profile.gear.equipped = nil
			PlayerData.syncNow(player)
			return { ok = true }
		end
		if typeof(id) ~= "string" or not profile.gear.owned[id] then
			return { ok = false, reason = "You don't own that." }
		end
		profile.gear.equipped = id
		Analytics.funnel(player, "FirstGearEquip")
		Tutorial.complete(player, "gear")
		PlayerData.syncNow(player)
		return { ok = true }
	end)

	-- The starter jetpack is free for everyone.
	PlayerData.onLoaded(function(_, profile)
		profile.gear.owned.jetpack_basic = true
	end)

	-- Tick timed potion effects only while the player is online.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in game:GetService("Players"):GetPlayers() do
				local profile = PlayerData.get(player)
				if profile then
					for id, remaining in profile.effects do
						local def = Formulas.potion(id)
						if def and def.duration > 0 and remaining > 0 then
							profile.effects[id] = remaining - 1
							if remaining - 1 <= 0 then
								profile.effects[id] = nil
								PlayerData.markDirty(player)
							end
						end
					end
				end
			end
		end
	end)
end

return Economy
