--!strict
-- Menu panels: Daily Rewards, Playtime Rewards, Upgrades (with a Luck
-- explainer), Potions (inventory + Skybrew shop) and Gear. Panels open from
-- HUD buttons or from the physical stalls' ProximityPrompts (E / gamepad X /
-- tap). Every price is shown on the button itself; free claims say FREE;
-- expensive purchases ask for a second tap to confirm.

local ProximityPromptService = game:GetService("ProximityPromptService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Formulas = require(Shared.Formulas)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local Lib = script.Parent.Parent:WaitForChild("Lib")
local Bus = require(Lib.Bus)
local RunState = require(Lib.RunState)
local State = require(Lib.State)
local UI = require(Lib.UI)

local T = UI.Theme
local CONFIRM_ABOVE = 2000 -- coin prices above this need a second tap

local Panels = {}

type PanelDef = {
	panel: UI.Panel,
	refresh: () -> (),
}

local panels: { [string]: PanelDef } = {}

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if
			not child:IsA("UIGridLayout")
			and not child:IsA("UIListLayout")
			and not child:IsA("UIPadding")
		then
			child:Destroy()
		end
	end
end

local function invoke(name: string, ...: any): any
	local ok, result = pcall(function(...)
		return Remotes.func(name):InvokeServer(...)
	end, ...)
	if not ok or typeof(result) ~= "table" then
		Bus.fire("Toast", "Connection hiccup — try again.", T.red)
		return nil
	end
	if not result.ok and result.reason then
		Bus.fire("Toast", result.reason, T.red)
	end
	return result
end

-- Two-step confirm for expensive coin purchases.
local function confirmable(
	button: TextButton,
	label: string,
	price: number,
	color: Color3,
	action: () -> ()
)
	local armed = false
	button.Activated:Connect(function()
		if price <= CONFIRM_ABOVE or armed then
			armed = false
			action()
			return
		end
		armed = true
		UI.setButton(button, "CONFIRM " .. Format.short(price) .. "?", T.gold)
		task.delay(3, function()
			if armed then
				armed = false
				UI.setButton(button, label, color)
			end
		end)
	end)
end

local function rewardText(reward: Config.Reward): string
	return Formulas.describeReward(reward)
end

-- DAILY ----------------------------------------------------------------------
local function buildDaily(root: Frame)
	local panel = UI.panel(root, "🎁 DAILY REWARDS", T.pink, Vector2.new(1040, 620))
	local grid = UI.grid(panel.content, Vector2.new(225, 200), 16)
	grid.Size = UDim2.new(1, 0, 1, -60)
	local footer = UI.label({
		Text = "",
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.new(0, 0, 1, -48),
		TextColor3 = T.dark,
		Stroke = Color3.new(1, 1, 1),
		MaxText = 28,
		ZIndex = 11,
		Parent = panel.content,
	})

	local function refresh()
		local snap = State.snapshot
		if not snap then
			return
		end
		clear(grid)
		local claims = snap.profile.daily.claims
		local count = #Config.DailyRewards
		local today = claims % count + 1
		local lastClaimed = if claims > 0 then (claims - 1) % count + 1 else 0
		for day, reward in Config.DailyRewards do
			local isToday = snap.dailyReady and day == today
			local claimed = if snap.dailyReady
				then day < today
				else (claims > 0 and day <= lastClaimed)
			local isNext = not snap.dailyReady and day == today
			local card = UI.card({
				layoutOrder = day,
				color = if isToday then Color3.fromRGB(255, 236, 245) else T.panelInner,
				strokeColor = if isToday then T.pink else UI.darker(T.panelInner, 0.25),
				parent = grid,
			})
			UI.label({
				Text = "DAY " .. day,
				Size = UDim2.new(1, 0, 0, 34),
				Position = UDim2.fromOffset(0, 8),
				TextColor3 = T.pink,
				MaxText = 30,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = rewardText(reward),
				Size = UDim2.new(1, -16, 0, 80),
				Position = UDim2.fromOffset(8, 44),
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				TextWrapped = true,
				MaxText = 20,
				ZIndex = 11,
				Parent = card,
			})
			if isToday then
				local button = UI.button({
					text = "CLAIM FREE",
					color = T.green,
					size = UDim2.new(1, -20, 0, 54),
					position = UDim2.new(0, 10, 1, -62),
					parent = card,
					textSize = 24,
				})
				button.Activated:Connect(function()
					local result = invoke("ClaimDaily")
					if result and result.ok then
						UI.playSound(Config.Sounds.Reward, 0.6, 1)
						Bus.fire("DailyClaimed", result.day)
						Bus.fire(
							"Toast",
							"DAY " .. result.day .. " CLAIMED: " .. rewardText(result.reward),
							T.green
						)
					end
				end)
			else
				UI.label({
					Text = if claimed
						then "✔ CLAIMED"
						elseif isNext then "🔒 TOMORROW"
						else "🔒 LOCKED",
					Size = UDim2.new(1, -20, 0, 40),
					Position = UDim2.new(0, 10, 1, -54),
					TextColor3 = if claimed then T.green else T.gray,
					MaxText = 24,
					ZIndex = 11,
					Parent = card,
				})
			end
		end
		local streakText = "STREAK: " .. claims .. " day" .. (if claims == 1 then "" else "s")
		if snap.dailyReady then
			footer.Text = streakText .. "   •   Your free reward is ready!"
		else
			footer.Text = streakText
				.. "   •   Next reward in "
				.. Format.clock(snap.dailyNextAt - State.now())
		end
	end

	panel.onOpen = refresh
	panels.Daily = { panel = panel, refresh = refresh }
	task.spawn(function()
		while true do
			task.wait(1)
			if panel.isOpen() then
				local snap = State.snapshot
				if snap and not snap.dailyReady then
					footer.Text = "STREAK: "
						.. snap.profile.daily.claims
						.. " days   •   Next reward in "
						.. Format.clock(snap.dailyNextAt - State.now())
				end
			end
		end
	end)
end

-- PLAYTIME ----------------------------------------------------------------------
local function buildPlaytime(root: Frame)
	local panel = UI.panel(root, "⏰ PLAYTIME REWARDS", T.gold, Vector2.new(1080, 440))
	local list = UI.new("Frame", {
		Size = UDim2.new(1, 0, 1, -50),
		BackgroundTransparency = 1,
		ZIndex = 10,
		Parent = panel.content,
	})
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 12),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})
	UI.label({
		Text = "Rewards for playing this session. Leave whenever you like — they're just a bonus!",
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.new(0, 0, 1, -40),
		TextColor3 = T.dark,
		Stroke = Color3.new(1, 1, 1),
		MaxText = 22,
		ZIndex = 11,
		Parent = panel.content,
	})

	local function refresh()
		local snap = State.snapshot
		if not snap then
			return
		end
		clear(list)
		local elapsed = State.sessionElapsed()
		for i, entry in Config.PlaytimeRewards do
			local claimed = snap.playtimeClaimed[i] == true
			local ready = not claimed and elapsed >= entry.minutes * 60
			local card = UI.card({
				size = UDim2.fromOffset(158, 250),
				layoutOrder = i,
				color = if ready then Color3.fromRGB(255, 246, 220) else T.panelInner,
				strokeColor = if ready then T.gold else UI.darker(T.panelInner, 0.25),
				parent = list,
			})
			UI.label({
				Text = entry.minutes .. " MIN",
				Size = UDim2.new(1, 0, 0, 36),
				Position = UDim2.fromOffset(0, 10),
				TextColor3 = T.gold,
				MaxText = 30,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = rewardText(entry.reward),
				Size = UDim2.new(1, -14, 0, 100),
				Position = UDim2.fromOffset(7, 52),
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				TextWrapped = true,
				MaxText = 20,
				ZIndex = 11,
				Parent = card,
			})
			if ready then
				local button = UI.button({
					text = "CLAIM",
					color = T.green,
					size = UDim2.new(1, -16, 0, 56),
					position = UDim2.new(0, 8, 1, -64),
					parent = card,
					textSize = 26,
				})
				button.Activated:Connect(function()
					local result = invoke("ClaimPlaytime", i)
					if result and result.ok then
						UI.playSound(Config.Sounds.Reward, 0.6, 1.1)
						Bus.fire("Toast", "+" .. rewardText(result.reward), T.gold)
					end
				end)
			else
				UI.label({
					Text = if claimed
						then "✔ CLAIMED"
						else Format.clock(entry.minutes * 60 - elapsed),
					Size = UDim2.new(1, -16, 0, 40),
					Position = UDim2.new(0, 8, 1, -54),
					TextColor3 = if claimed then T.green else T.gray,
					MaxText = 26,
					ZIndex = 11,
					Parent = card,
				})
			end
		end
	end

	panel.onOpen = refresh
	panels.Playtime = { panel = panel, refresh = refresh }
	task.spawn(function()
		while true do
			task.wait(1)
			if panel.isOpen() then
				refresh()
			end
		end
	end)
end

-- UPGRADES ------------------------------------------------------------------------
local function buildUpgrades(root: Frame)
	local panel = UI.panel(root, "⬆ UPGRADES", T.purple, Vector2.new(1100, 660))
	local list = UI.new("ScrollingFrame", {
		Size = UDim2.new(0.66, -10, 1, 0),
		BackgroundTransparency = 1,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 8,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = panel.content,
	})
	UI.new(
		"UIListLayout",
		{ Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list }
	)
	UI.padding(4).Parent = list
	local luckCard = UI.card({
		size = UDim2.new(0.34, -10, 1, 0),
		position = UDim2.new(0.66, 10, 0, 0),
		parent = panel.content,
	})

	local function refreshLuck(profile: Types.Profile)
		clear(luckCard)
		UI.label({
			Text = "🍀 WHAT LUCK DOES",
			Size = UDim2.new(1, -20, 0, 36),
			Position = UDim2.fromOffset(10, 10),
			TextColor3 = T.green,
			MaxText = 26,
			ZIndex = 11,
			Parent = luckCard,
		})
		UI.label({
			Text = "Luck makes capsules roll rarer rewards. Your capsule odds right now:",
			Size = UDim2.new(1, -20, 0, 54),
			Position = UDim2.fromOffset(10, 48),
			TextColor3 = T.dark,
			Stroke = Color3.new(1, 1, 1),
			TextWrapped = true,
			MaxText = 18,
			ZIndex = 11,
			Parent = luckCard,
		})
		local luck = Formulas.luck(profile)
		local y = 108
		for _, entry in Formulas.rarityChances(luck) do
			local pct = entry.chance * 100
			UI.label({
				Text = string.format(
					"%s  %s%%",
					entry.id,
					if pct < 1 then string.format("%.2f", pct) else string.format("%.1f", pct)
				),
				Size = UDim2.new(1, -20, 0, 30),
				Position = UDim2.fromOffset(10, y),
				TextColor3 = Formulas.rarityColor(entry.id),
				Stroke = T.dark,
				TextXAlignment = Enum.TextXAlignment.Left,
				MaxText = 22,
				ZIndex = 11,
				Parent = luckCard,
			})
			y += 32
		end
		UI.label({
			Text = "Current Luck: " .. luck .. (if Formulas.effectActive(profile, "luck")
				then "  (potion active!)"
				else ""),
			Size = UDim2.new(1, -20, 0, 30),
			Position = UDim2.fromOffset(10, y + 10),
			TextColor3 = T.purple,
			Stroke = Color3.new(1, 1, 1),
			MaxText = 20,
			ZIndex = 11,
			Parent = luckCard,
		})
	end

	local function refresh()
		local profile = State.profile()
		if not profile then
			return
		end
		clear(list)
		for order, def in Config.Upgrades do
			local level = profile.upgrades[def.id] or 0
			local maxed = level >= def.maxLevel
			local cost = if profile.freeUpgrade then 0 else Formulas.upgradeCost(def.id, level)
			local row =
				UI.card({ size = UDim2.new(1, -8, 0, 104), layoutOrder = order, parent = list })
			UI.label({
				Text = def.name:upper(),
				Size = UDim2.new(0.5, 0, 0, 34),
				Position = UDim2.fromOffset(16, 8),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = T.purple,
				MaxText = 28,
				ZIndex = 11,
				Parent = row,
			})
			UI.label({
				Text = "LVL " .. level .. (if maxed then " (MAX)" else ""),
				Size = UDim2.new(0.2, 0, 0, 30),
				Position = UDim2.new(0.42, 0, 0, 10),
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				MaxText = 24,
				ZIndex = 11,
				Parent = row,
			})
			local current = Formulas.upgradeValue(def.id, level)
			local nextValue = Formulas.upgradeValue(def.id, level + 1)
			UI.label({
				Text = string.format(
					"%s   •   +%d%s%s",
					def.description,
					current,
					def.unit,
					if maxed then "" else string.format("  →  +%d%s", nextValue, def.unit)
				),
				Size = UDim2.new(0.66, 0, 0, 44),
				Position = UDim2.fromOffset(16, 50),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				TextWrapped = true,
				MaxText = 20,
				ZIndex = 11,
				Parent = row,
			})
			local affordable = profile.coins >= cost
			local label = if maxed
				then "MAX"
				elseif cost == 0 then "FREE"
				else "🪙 " .. Format.short(cost)
			local color = if maxed
				then T.gray
				elseif cost == 0 then T.green
				elseif affordable then T.gold
				else T.gray
			local button = UI.button({
				text = label,
				color = color,
				size = UDim2.fromOffset(200, 70),
				position = UDim2.new(1, -14, 0.5, 0),
				anchor = Vector2.new(1, 0.5),
				parent = row,
				textSize = 28,
			})
			if not maxed then
				confirmable(button, label, cost, color, function()
					local result = invoke("BuyUpgrade", def.id)
					if result and result.ok then
						UI.playSound(Config.Sounds.Reward, 0.5, 1.3)
						Bus.fire("UpgradeBought", def.id)
						Bus.fire(
							"Toast",
							def.name .. " is now level " .. result.level .. "!",
							T.purple
						)
					end
				end)
			end
		end
		refreshLuck(profile)
	end

	panel.onOpen = refresh
	panels.Upgrades = { panel = panel, refresh = refresh }
end

-- POTIONS ------------------------------------------------------------------------
local function buildPotions(root: Frame)
	local panel = UI.panel(root, "🧪 SKYBREW POTIONS", T.green, Vector2.new(1100, 640))
	local grid = UI.grid(panel.content, Vector2.new(320, 250), 14)

	local function refresh()
		local profile = State.profile()
		if not profile then
			return
		end
		clear(grid)
		for order, def in Config.Potions do
			local owned = profile.potions[def.id] or 0
			local card = UI.card({ layoutOrder = order, strokeColor = def.color, parent = grid })
			local icon = UI.new("Frame", {
				Size = UDim2.fromOffset(80, 80),
				Position = UDim2.fromOffset(14, 14),
				BackgroundColor3 = def.color,
				ZIndex = 11,
				Parent = card,
			}, { UI.corner(40), UI.stroke(UI.darker(def.color, 0.4), 3, true) })
			UI.label({
				Text = def.icon,
				Size = UDim2.fromScale(0.7, 0.7),
				Position = UDim2.fromScale(0.15, 0.15),
				Stroke = false,
				ZIndex = 12,
				Parent = icon,
			})
			UI.label({
				Text = def.name,
				Size = UDim2.new(1, -110, 0, 32),
				Position = UDim2.fromOffset(104, 14),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = UI.darker(def.color, 0.2),
				Stroke = T.dark,
				MaxText = 26,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = def.description .. "\n" .. (if def.duration > 0
					then Format.clock(def.duration)
					else "1 use"),
				Size = UDim2.new(1, -110, 0, 50),
				Position = UDim2.fromOffset(104, 48),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				MaxText = 20,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = "OWNED: " .. owned,
				Size = UDim2.new(1, -28, 0, 30),
				Position = UDim2.fromOffset(14, 104),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				MaxText = 22,
				ZIndex = 11,
				Parent = card,
			})
			local use = UI.button({
				text = if owned > 0 then "USE" else "NONE",
				color = if owned > 0 then T.green else T.gray,
				size = UDim2.new(0.5, -20, 0, 60),
				position = UDim2.new(0, 14, 1, -72),
				parent = card,
				textSize = 26,
			})
			use.Activated:Connect(function()
				if owned <= 0 then
					return
				end
				local result = invoke("UsePotion", def.id)
				if result and result.ok then
					UI.playSound(Config.Sounds.Reward, 0.5, 0.8)
					Bus.fire("PotionUsed", def.id)
					Bus.fire("Toast", def.icon .. " " .. def.name .. " active!", def.color)
				end
			end)
			local buyLabel = "🪙 " .. Format.short(def.price)
			local buy = UI.button({
				text = buyLabel,
				color = T.gold,
				size = UDim2.new(0.5, -20, 0, 60),
				position = UDim2.new(0.5, 6, 1, -72),
				parent = card,
				textSize = 24,
			})
			confirmable(buy, buyLabel, def.price, T.gold, function()
				local result = invoke("BuyPotion", def.id)
				if result and result.ok then
					UI.playSound(Config.Sounds.Coin, 0.4, 1)
				end
			end)
		end
	end

	panel.onOpen = refresh
	panels.Potions = { panel = panel, refresh = refresh }
end

-- GEAR ------------------------------------------------------------------------------
local function buildGear(root: Frame)
	local panel = UI.panel(root, "🎒 GEAR", T.blue, Vector2.new(900, 520))
	local grid = UI.grid(panel.content, Vector2.new(400, 380), 16)

	local function refresh()
		local profile = State.profile()
		if not profile then
			return
		end
		clear(grid)
		for order, def in Config.Gear do
			local owned = profile.gear.owned[def.id] == true
			local equipped = profile.gear.equipped == def.id
			local rarityColor = Formulas.rarityColor(def.rarity)
			local card = UI.card({ layoutOrder = order, strokeColor = rarityColor, parent = grid })
			UI.label({
				Text = def.name,
				Size = UDim2.new(1, -20, 0, 40),
				Position = UDim2.fromOffset(10, 12),
				TextColor3 = T.blue,
				MaxText = 32,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = def.rarity:upper(),
				Size = UDim2.new(1, -20, 0, 26),
				Position = UDim2.fromOffset(10, 52),
				TextColor3 = rarityColor,
				Stroke = T.dark,
				MaxText = 22,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = def.description,
				Size = UDim2.new(1, -30, 0, 60),
				Position = UDim2.fromOffset(15, 88),
				TextColor3 = T.dark,
				Stroke = Color3.new(1, 1, 1),
				TextWrapped = true,
				MaxText = 22,
				ZIndex = 11,
				Parent = card,
			})
			UI.label({
				Text = string.format("Fuel %.1fs   •   Thrust %d", def.fuel, def.thrust),
				Size = UDim2.new(1, -30, 0, 30),
				Position = UDim2.fromOffset(15, 160),
				TextColor3 = T.purple,
				Stroke = Color3.new(1, 1, 1),
				MaxText = 22,
				ZIndex = 11,
				Parent = card,
			})
			local label = if equipped
				then "EQUIPPED"
				elseif owned then "EQUIP"
				elseif def.price == 0 then "FREE"
				else "🪙 " .. Format.short(def.price)
			local color = if equipped
				then T.gray
				elseif owned or def.price == 0 then T.green
				else T.gold
			local button = UI.button({
				text = label,
				color = color,
				size = UDim2.new(1, -40, 0, 70),
				position = UDim2.new(0, 20, 1, -86),
				parent = card,
				textSize = 30,
			})
			if not equipped then
				confirmable(button, label, if owned then 0 else def.price, color, function()
					if not owned then
						local bought = invoke("BuyGear", def.id)
						if not bought or not bought.ok then
							return
						end
					end
					local result = invoke("EquipGear", def.id)
					if result and result.ok then
						UI.playSound(Config.Sounds.Reward, 0.5, 1.2)
						Bus.fire("Toast", def.name .. " equipped!", T.blue)
					end
				end)
			end
		end
	end

	panel.onOpen = refresh
	panels.Gear = { panel = panel, refresh = refresh }
end

function Panels.start()
	local _, root = UI.gui("SkyboundPanels", 5)
	buildDaily(root)
	buildPlaytime(root)
	buildUpgrades(root)
	buildPotions(root)
	buildGear(root)

	Bus.on("OpenPanel", function(name: string)
		local def = panels[name]
		if def then
			def.panel.open()
		end
	end)
	Bus.on("ProfileChanged", function()
		for _, def in panels do
			if def.panel.isOpen() then
				def.refresh()
			end
		end
	end)
	Bus.on("RunBegan", function()
		UI.closeAll()
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local name = prompt:GetAttribute("Panel")
		if typeof(name) == "string" and not RunState.active then
			Bus.fire("OpenPanel", name)
		end
	end)
end

return Panels
