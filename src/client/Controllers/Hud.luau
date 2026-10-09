--!strict
-- Always-on HUD. Two modes:
--   HUB: currencies, menu buttons with READY badges, NEXT GOAL card,
--        compact playtime track, active potions.
--   RUN: height + best, run coins/gems, potions, jetpack fuel, tutorial
--        prompts, dedicated touch controls on mobile.
-- Plus shared overlays: toasts, milestone celebration, world title, reward
-- reveal, portal transition and the run results screen (RETRY / HUB).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

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
local player = Players.LocalPlayer

local Hud = {}

local root: Frame
local hubLayer: Frame
local runLayer: Frame
local coinLabel: TextLabel
local gemLabel: TextLabel
local coinPill: Frame
local gemPill: Frame
local badges: { [string]: TextLabel } = {}
local goalTitle: TextLabel
local goalReward: TextLabel
local goalFill: Frame
local goalText: TextLabel
local playtimeFill: Frame
local playtimeText: TextLabel
local playtimeNext: TextLabel
local skipButton: TextButton
local effectsList: Frame
local heightLabel: TextLabel
local bestLabel: TextLabel
local runCoins: TextLabel
local runGems: TextLabel
local fuelBack: Frame
local fuelFill: Frame
local promptLabel: TextLabel
local touchLayer: Frame
local potionBar: Frame
local potionButtons: { [string]: { button: TextButton, count: TextLabel } } = {}
local toastList: Frame
local flash: Frame
local results: Frame
local resultLines: Frame
local retryButton: TextButton
local hubButton: TextButton
local lastCoins = -1
local lastGems = -1

-- Small helpers ---------------------------------------------------------------
local function pill(
	parent: Instance,
	icon: string,
	color: Color3,
	position: UDim2
): (Frame, TextLabel)
	local frame = UI.new("Frame", {
		Size = UDim2.fromOffset(230, 62),
		Position = position,
		BackgroundColor3 = T.dark,
		BackgroundTransparency = 0.15,
		Parent = parent,
	}, { UI.corner(31), UI.stroke(UI.darker(color, 0.3), 3, true) })
	local iconFrame = UI.new("Frame", {
		Size = UDim2.fromOffset(62, 62),
		Position = UDim2.fromOffset(-8, 0),
		BackgroundColor3 = color,
		Parent = frame,
	}, { UI.corner(31), UI.stroke(UI.darker(color, 0.45), 3, true) })
	UI.label({
		Text = icon,
		Size = UDim2.fromScale(0.8, 0.8),
		Position = UDim2.fromScale(0.1, 0.1),
		Stroke = false,
		Parent = iconFrame,
	})
	local label = UI.label({
		Text = "0",
		Size = UDim2.new(1, -76, 0, 44),
		Position = UDim2.fromOffset(64, 9),
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxText = 38,
		Parent = frame,
	})
	return frame, label
end

local function menuButton(
	parent: Instance,
	text: string,
	icon: string,
	color: Color3,
	order: number,
	panel: string
)
	local button = UI.button({
		text = icon .. " " .. text,
		color = color,
		size = UDim2.fromOffset(196, 70),
		layoutOrder = order,
		parent = parent,
		textSize = 28,
	})
	badges[panel] = UI.badge(button, T.red)
	button.Activated:Connect(function()
		Bus.fire("OpenPanel", panel)
	end)
end

function Hud.toast(text: string, color: Color3?)
	local toast = UI.label({
		Text = text,
		Size = UDim2.fromOffset(520, 52),
		BackgroundTransparency = 0.1,
		BackgroundColor3 = color or T.dark,
		MaxText = 30,
		Parent = toastList,
	})
	UI.corner(26).Parent = toast
	UI.padding(6).Parent = toast
	UI.pop(toast, 0.25)
	task.delay(2.6, function()
		UI.tween(toast, 0.3, { TextTransparency = 1, BackgroundTransparency = 1 })
		local stroke = toast:FindFirstChildOfClass("UIStroke")
		if stroke then
			UI.tween(stroke, 0.3, { Transparency = 1 })
		end
		task.wait(0.3)
		toast:Destroy()
	end)
	-- Group spam: keep at most 3 visible.
	local toasts = {}
	for _, child in toastList:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(toasts, child)
		end
	end
	if #toasts > 3 then
		toasts[1]:Destroy()
	end
end

local function bigBanner(title: string, subtitle: string, color: Color3, duration: number)
	local holder = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(800, 180),
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = root,
	})
	local main = UI.label({
		Text = title,
		Size = UDim2.new(1, 0, 0, 110),
		TextColor3 = color,
		MaxText = 110,
		ZIndex = 20,
		Parent = holder,
	})
	local stroke = main:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 5
	end
	UI.label({
		Text = subtitle,
		Size = UDim2.new(1, 0, 0, 50),
		Position = UDim2.fromOffset(0, 115),
		MaxText = 42,
		ZIndex = 20,
		Parent = holder,
	})
	UI.pop(holder :: any, 0.6)
	-- Confetti.
	for _ = 1, 26 do
		local bit = UI.new("Frame", {
			Size = UDim2.fromOffset(14, 14),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundColor3 = Color3.fromHSV(math.random(), 0.6, 1),
			Rotation = math.random(0, 360),
			ZIndex = 19,
			Parent = holder,
		}, { UI.corner(4) })
		UI.tween(bit, 0.9, {
			Position = UDim2.new(0.5, math.random(-420, 420), 0.5, math.random(-220, 260)),
			Rotation = math.random(-360, 360),
			BackgroundTransparency = 1,
		}, Enum.EasingStyle.Quad)
	end
	task.delay(duration, function()
		for _, child in holder:GetDescendants() do
			if child:IsA("TextLabel") then
				UI.tween(child, 0.3, { TextTransparency = 1 })
			elseif child:IsA("UIStroke") then
				UI.tween(child, 0.3, { Transparency = 1 })
			end
		end
		task.wait(0.35)
		holder:Destroy()
	end)
end

-- Builders --------------------------------------------------------------------
local function buildHub()
	hubLayer = UI.new(
		"Frame",
		{ Name = "Hub", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = root }
	)

	local buttons = UI.new("Frame", {
		Name = "Menu",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 20, 0.5, 30),
		Size = UDim2.fromOffset(200, 530),
		BackgroundTransparency = 1,
		Parent = hubLayer,
	})
	UI.new(
		"UIListLayout",
		{ Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder, Parent = buttons }
	)
	menuButton(buttons, "DAILY", "🎁", T.pink, 1, "Daily")
	menuButton(buttons, "PLAYTIME", "⏰", T.gold, 2, "Playtime")
	menuButton(buttons, "UPGRADES", "⬆", T.purple, 3, "Upgrades")
	menuButton(buttons, "POTIONS", "🧪", T.green, 4, "Potions")
	menuButton(buttons, "GEAR", "🎒", T.blue, 5, "Gear")
	menuButton(buttons, "QUESTS", "📜", Color3.fromRGB(240, 170, 70), 6, "Quests")

	-- NEXT GOAL card.
	local goal = UI.new("Frame", {
		Name = "NextGoal",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.fromOffset(470, 132),
		BackgroundColor3 = T.dark,
		BackgroundTransparency = 0.15,
		Parent = hubLayer,
	}, { UI.corner(24), UI.stroke(T.gold, 3, true) })
	UI.label({
		Text = "NEXT GOAL",
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromOffset(0, 8),
		TextColor3 = T.gold,
		MaxText = 24,
		Parent = goal,
	})
	goalTitle = UI.label({
		Text = "",
		Size = UDim2.new(1, -30, 0, 40),
		Position = UDim2.fromOffset(15, 32),
		MaxText = 36,
		Parent = goal,
	})
	goalReward = UI.label({
		Text = "",
		Size = UDim2.new(1, -30, 0, 24),
		Position = UDim2.fromOffset(15, 72),
		TextColor3 = Color3.fromRGB(200, 240, 255),
		MaxText = 22,
		Parent = goal,
	})
	local _, fill, text =
		UI.progressBar(goal, UDim2.new(1, -40, 0, 22), UDim2.fromOffset(20, 100), T.gold)
	goalFill, goalText = fill, text

	-- Compact playtime track.
	local playtime = UI.new("TextButton", {
		Name = "Playtime",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(440, 86),
		BackgroundColor3 = T.dark,
		BackgroundTransparency = 0.15,
		AutoButtonColor = false,
		Text = "",
		Parent = hubLayer,
	}, { UI.corner(22), UI.stroke(T.gold, 3, true) })
	playtime.Activated:Connect(function()
		UI.click()
		Bus.fire("OpenPanel", "Playtime")
	end)
	UI.label({
		Text = "⏰ PLAYTIME REWARDS",
		Size = UDim2.new(0.6, 0, 0, 26),
		Position = UDim2.fromOffset(16, 8),
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxText = 22,
		Parent = playtime,
	})
	playtimeNext = UI.label({
		Text = "",
		Size = UDim2.new(0.42, -16, 0, 26),
		Position = UDim2.new(0.58, 0, 0, 8),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = T.gold,
		MaxText = 20,
		Parent = playtime,
	})
	local _, pFill, pText =
		UI.progressBar(playtime, UDim2.new(1, -32, 0, 30), UDim2.fromOffset(16, 42), T.gold)
	playtimeFill, playtimeText = pFill, pText

	skipButton = UI.button({
		text = "SKIP TUTORIAL",
		color = T.gray,
		size = UDim2.fromOffset(200, 50),
		position = UDim2.new(1, -20, 0, 90),
		anchor = Vector2.new(1, 0),
		parent = hubLayer,
		textSize = 20,
	})
	skipButton.Visible = false
	skipButton.Activated:Connect(function()
		Remotes.func("SkipTutorial"):InvokeServer()
	end)
end

local function touchZone(name: string, position: UDim2, size: UDim2, icon: string): TextButton
	local zone = UI.new("TextButton", {
		Name = name,
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.88,
		AutoButtonColor = false,
		Text = "",
		Parent = touchLayer,
	}, { UI.corner(40) })
	UI.label({
		Text = icon,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -30),
		Size = UDim2.fromOffset(120, 120),
		TextTransparency = 0.3,
		Parent = zone,
	})
	return zone
end

local function buildRun()
	runLayer = UI.new("Frame", {
		Name = "Run",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	})
	heightLabel = UI.label({
		Text = "0m",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(500, 90),
		MaxText = 90,
		Parent = runLayer,
	})
	local hStroke = heightLabel:FindFirstChildOfClass("UIStroke")
	if hStroke then
		hStroke.Thickness = 5
	end
	bestLabel = UI.label({
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 100),
		Size = UDim2.fromOffset(400, 32),
		TextColor3 = T.gold,
		MaxText = 28,
		Parent = runLayer,
	})
	promptLabel = UI.label({
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 150),
		Size = UDim2.fromOffset(820, 54),
		BackgroundColor3 = T.dark,
		BackgroundTransparency = 0.2,
		MaxText = 38,
		Visible = false,
		Parent = runLayer,
	})
	UI.corner(27).Parent = promptLabel
	UI.padding(6).Parent = promptLabel

	local coins: Frame
	coins, runCoins = pill(runLayer, "🪙", T.coin, UDim2.fromOffset(28, 20))
	local gems: Frame
	gems, runGems = pill(runLayer, "💎", T.gem, UDim2.fromOffset(28, 92))
	local _ = coins
	local _ = gems

	fuelBack = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(360, 30),
		BackgroundColor3 = T.dark,
		BackgroundTransparency = 0.2,
		Parent = runLayer,
	}, { UI.corner(15), UI.stroke(T.blue, 3, true) })
	fuelFill = UI.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(255, 160, 60),
		Parent = fuelBack,
	}, { UI.corner(15) })
	UI.label({ Text = "BOOST", Size = UDim2.fromScale(1, 0.9), MaxText = 22, Parent = fuelBack })

	-- Dedicated touch controls: big left/right zones + a boost button.
	touchLayer = UI.new("Frame", {
		Name = "Touch",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = runLayer,
	})
	local left = touchZone("Left", UDim2.new(0, 10, 0.45, 0), UDim2.new(0.34, 0, 0.55, -10), "◀")
	local right =
		touchZone("Right", UDim2.new(0.66, -10, 0.45, 0), UDim2.new(0.34, 0, 0.55, -10), "▶")
	local boost = UI.new("TextButton", {
		Name = "Boost",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -70),
		Size = UDim2.fromOffset(170, 170),
		BackgroundColor3 = Color3.fromRGB(255, 150, 60),
		BackgroundTransparency = 0.15,
		AutoButtonColor = false,
		Text = "",
		Parent = touchLayer,
	}, { UI.corner(85), UI.stroke(UI.darker(Color3.fromRGB(255, 150, 60), 0.4), 4, true) })
	UI.label({
		Text = "🚀\nBOOST",
		Size = UDim2.fromScale(0.8, 0.8),
		Position = UDim2.fromScale(0.1, 0.1),
		Parent = boost,
	})

	local held = { left = false, right = false, boost = false }
	local function report()
		Bus.fire("TouchInput", held.left, held.right, held.boost)
	end
	local function bind(button: TextButton, key: string)
		button.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				(held :: any)[key] = true
				button.BackgroundTransparency = if key == "boost" then 0 else 0.75
				report()
			end
		end)
		button.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				(held :: any)[key] = false
				button.BackgroundTransparency = if key == "boost" then 0.15 else 0.88
				report()
			end
		end)
	end
	bind(left, "left")
	bind(right, "right")
	bind(boost, "boost")

	-- Quick-use potions during a climb (keys 1-5, tap, or click).
	potionBar = UI.new("Frame", {
		Name = "Potions",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -20, 1, -24),
		Size = UDim2.fromOffset(84, 5 * 90),
		BackgroundTransparency = 1,
		Parent = runLayer,
	})
	UI.new("UIListLayout", {
		Padding = UDim.new(0, 8),
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = potionBar,
	})
	for i, def in Config.Potions do
		local button = UI.new("TextButton", {
			Name = def.id,
			Size = UDim2.fromOffset(82, 82),
			BackgroundColor3 = def.color,
			AutoButtonColor = true,
			Text = "",
			LayoutOrder = i,
			Visible = false,
			Parent = potionBar,
		}, { UI.corner(41), UI.stroke(UI.darker(def.color, 0.45), 3, true) })
		UI.label({
			Text = def.icon,
			Size = UDim2.fromScale(0.62, 0.62),
			Position = UDim2.fromScale(0.19, 0.1),
			Stroke = false,
			Parent = button,
		})
		local count = UI.label({
			Text = "",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 4, 1, 4),
			Size = UDim2.fromOffset(40, 28),
			BackgroundTransparency = 0,
			BackgroundColor3 = T.dark,
			MaxText = 20,
			Parent = button,
		})
		UI.corner(14).Parent = count
		UI.label({
			Text = tostring(i),
			Position = UDim2.fromOffset(-2, -2),
			Size = UDim2.fromOffset(24, 24),
			MaxText = 18,
			Parent = button,
		})
		potionButtons[def.id] = { button = button, count = count }
		button.Activated:Connect(function()
			Hud.usePotion(def.id)
		end)
	end
end

local function buildShared()
	local coinsFrame, coinsText = pill(root, "🪙", T.coin, UDim2.fromOffset(28, 20))
	local gemsFrame, gemsText = pill(root, "💎", T.gem, UDim2.fromOffset(28, 92))
	coinPill, coinLabel, gemPill, gemLabel = coinsFrame, coinsText, gemsFrame, gemsText

	effectsList = UI.new("Frame", {
		Name = "Effects",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 160),
		Size = UDim2.fromOffset(230, 300),
		BackgroundTransparency = 1,
		Parent = root,
	})
	UI.new("UIListLayout", {
		Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = effectsList,
	})

	toastList = UI.new("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -130),
		Size = UDim2.fromOffset(540, 200),
		BackgroundTransparency = 1,
		ZIndex = 30,
		Parent = root,
	})
	UI.new("UIListLayout", {
		Padding = UDim.new(0, 8),
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = toastList,
	})

	flash = UI.new("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(3, 3),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(200, 180, 255),
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = root,
	})

	-- Results screen.
	results = UI.new("Frame", {
		Name = "Results",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 600),
		BackgroundColor3 = T.panel,
		Visible = false,
		ZIndex = 40,
		Parent = root,
	}, { UI.corner(30), UI.stroke(T.stroke, 5, true) })
	UI.label({
		Text = "RUN COMPLETE",
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.fromOffset(0, 14),
		TextColor3 = T.blue,
		MaxText = 56,
		ZIndex = 41,
		Parent = results,
	})
	resultLines = UI.new("Frame", {
		Position = UDim2.fromOffset(30, 94),
		Size = UDim2.new(1, -60, 0, 380),
		BackgroundTransparency = 1,
		ZIndex = 41,
		Parent = results,
	})
	UI.new(
		"UIListLayout",
		{ Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = resultLines }
	)
	retryButton = UI.button({
		text = "RETRY",
		color = T.green,
		size = UDim2.fromOffset(240, 84),
		position = UDim2.new(0.5, 10, 1, -24),
		anchor = Vector2.new(0, 1),
		parent = results,
		textSize = 40,
	})
	hubButton = UI.button({
		text = "HUB",
		color = T.blue,
		size = UDim2.fromOffset(220, 84),
		position = UDim2.new(0.5, -10, 1, -24),
		anchor = Vector2.new(1, 0),
		parent = results,
		textSize = 40,
	})
	hubButton.AnchorPoint = Vector2.new(1, 1)
end

-- Results flow -----------------------------------------------------------------
local resultsOpen = false

local function hideResults()
	resultsOpen = false
	results.Visible = false
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(results) then
		GuiService.SelectedObject = nil
	end
end

local function resultLine(text: string, color: Color3?, order: number, big: boolean?)
	local line = UI.label({
		Text = text,
		Size = UDim2.new(1, 0, 0, if big then 60 else 40),
		TextColor3 = color or T.dark,
		Stroke = if color then UI.darker(color, 0.55) else Color3.new(1, 1, 1),
		MaxText = if big then 52 else 30,
		LayoutOrder = order,
		ZIndex = 41,
		Parent = resultLines,
	})
	UI.pop(line, 0.3)
	return line
end

local function showResults(result: Types.RunResult)
	resultsOpen = true
	for _, child in resultLines:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	results.Visible = true
	UI.pop(results, 0.15)
	UI.setButton(retryButton, "RETRY", T.green)
	if UserInputService.GamepadEnabled then
		GuiService.SelectedObject = retryButton
	end
	task.spawn(function()
		-- Reveal rewards one by one.
		local order = 0
		local function add(text: string, color: Color3?, big: boolean?)
			if not resultsOpen then
				return
			end
			order += 1
			resultLine(text, color, order, big)
			UI.playSound(Config.Sounds.Click, 0.3, 1 + order * 0.08)
			task.wait(0.22)
		end
		add("HEIGHT: " .. Format.meters(result.height), T.blue, true)
		if result.newRecord then
			add("⭐ NEW RECORD! ⭐", T.gold, true)
		end
		add("COINS: +" .. Format.comma(result.coins), T.coin)
		if result.gems > 0 then
			add("GEMS: +" .. Format.comma(result.gems), T.gem)
		end
		if #result.items > 0 then
			add("ITEMS FOUND: " .. #result.items, T.purple)
		end
		if result.nearMiss then
			add(result.nearMiss, T.pink)
		end
		add("NEXT: " .. result.nextGoal, T.green)
	end)
end

-- Updates ------------------------------------------------------------------------
local effectRows: { [string]: { row: Frame, text: TextLabel } } = {}
-- Active potion timers. Rows are created once per potion and reused; only
-- their text and visibility change as timers tick.
local function refreshEffects()
	for order, def in Config.Potions do
		local remaining = State.effectRemaining(def.id)
		local entry = effectRows[def.id]
		if remaining > 0 and not entry then
			local row = UI.new("Frame", {
				Name = def.id,
				Size = UDim2.fromOffset(220, 46),
				BackgroundColor3 = T.dark,
				BackgroundTransparency = 0.2,
				LayoutOrder = order,
				Parent = effectsList,
			}, { UI.corner(23), UI.stroke(def.color, 3, true) })
			local text = UI.label({
				Name = "Text",
				Text = "",
				Size = UDim2.new(1, -20, 1, -10),
				Position = UDim2.fromOffset(10, 5),
				MaxText = 28,
				Parent = row,
			})
			entry = { row = row, text = text }
			effectRows[def.id] = entry
			UI.pop(row, 0.2)
		end
		if entry then
			entry.row.Visible = remaining > 0
			entry.text.Text = def.icon
				.. " "
				.. (if def.id == "shield" then "x" .. remaining else Format.clock(remaining))
		end
	end
end

local function updateBadges(snap: Types.Snapshot)
	local profile = snap.profile
	badges.Daily.Text = if snap.dailyReady then "FREE" else ""
	badges.Daily.Visible = snap.dailyReady
	badges.Daily.BackgroundColor3 = T.green

	local elapsed = State.sessionElapsed()
	local playtimeReady = false
	for i, entry in Config.PlaytimeRewards do
		if not snap.playtimeClaimed[i] and elapsed >= entry.minutes * 60 then
			playtimeReady = true
		end
	end
	badges.Playtime.Text = "READY"
	badges.Playtime.Visible = playtimeReady
	badges.Playtime.BackgroundColor3 = T.green

	local affordable = profile.freeUpgrade
	for _, def in Config.Upgrades do
		local level = profile.upgrades[def.id] or 0
		if level < def.maxLevel and profile.coins >= Formulas.upgradeCost(def.id, level) then
			affordable = true
		end
	end
	badges.Upgrades.Text = if profile.freeUpgrade then "FREE" else "!"
	badges.Upgrades.Visible = affordable
	badges.Upgrades.BackgroundColor3 = if profile.freeUpgrade then T.green else T.red

	local potionCount = 0
	for _, count in profile.potions do
		potionCount += count
	end
	badges.Potions.Text = tostring(potionCount)
	badges.Potions.Visible = potionCount > 0
	badges.Potions.BackgroundColor3 = T.blue

	local questsReady = 0
	for _, list in { profile.quests.daily, profile.quests.weekly } do
		for _, q in list do
			for _, pool in { Config.DailyQuests, Config.WeeklyQuests } do
				for _, def in pool do
					if def.id == q.id and not q.claimed and q.progress >= def.target then
						questsReady += 1
					end
				end
			end
		end
	end
	badges.Quests.Text = tostring(questsReady)
	badges.Quests.Visible = questsReady > 0
	badges.Quests.BackgroundColor3 = T.green

	badges.Gear.Text = "NEW"
	badges.Gear.Visible = profile.gear.equipped == nil
end

local usingPotion = false
function Hud.usePotion(id: string)
	if usingPotion then
		return
	end
	local def = Formulas.potion(id)
	local profile = State.profile()
	if not def or not profile or (profile.potions[id] or 0) <= 0 then
		return
	end
	usingPotion = true
	local ok, result = pcall(function()
		return Remotes.func("UsePotion"):InvokeServer(id)
	end)
	usingPotion = false
	if ok and typeof(result) == "table" and result.ok then
		UI.playSound(Config.Sounds.Reward, 0.5, 0.8)
		Hud.toast(def.icon .. " " .. def.name .. " active!", def.color)
		local entry = potionButtons[id]
		if entry then
			UI.pop(entry.button, 0.3)
		end
	elseif ok and typeof(result) == "table" and result.reason then
		Hud.toast(result.reason, T.red)
	end
end

local function refreshPotionBar(profile: Types.Profile)
	for id, entry in potionButtons do
		local count = profile.potions[id] or 0
		entry.button.Visible = count > 0
		entry.count.Text = "x" .. count
	end
end

local function onProfile(snap: Types.Snapshot)
	local profile = snap.profile
	if lastCoins >= 0 and profile.coins > lastCoins then
		UI.pop(coinPill, 0.2)
	end
	if lastGems >= 0 and profile.gems > lastGems then
		UI.pop(gemPill, 0.2)
	end
	lastCoins, lastGems = profile.coins, profile.gems
	coinLabel.Text = Format.short(profile.coins)
	gemLabel.Text = Format.short(profile.gems)

	local goal, reward = Formulas.nextGoal(profile)
	goalTitle.Text = goal
	goalReward.Text = reward
	local target = Formulas.nextMilestone(profile.bestHeight)
	local nextWorld = Formulas.nextWorld(profile.bestHeight)
	if nextWorld and target and nextWorld.startHeight <= target then
		target = nextWorld.startHeight
	end
	if target then
		goalFill.Size = UDim2.fromScale(math.clamp(profile.bestHeight / target, 0, 1), 1)
		goalText.Text = Format.meters(profile.bestHeight) .. " / " .. Format.meters(target)
	else
		goalFill.Size = UDim2.fromScale(1, 1)
		goalText.Text = Format.meters(profile.bestHeight)
	end

	skipButton.Visible = profile.tutorial.step <= #Config.TutorialSteps
	updateBadges(snap)
	refreshEffects()
	refreshPotionBar(profile)
end

local function setMode(running: boolean)
	hubLayer.Visible = not running
	runLayer.Visible = running
	coinPill.Visible = not running
	gemPill.Visible = not running
	touchLayer.Visible = running and UserInputService.TouchEnabled
end

local tick = 0
local function heartbeat(dt: number)
	tick += dt
	if RunState.active then
		heightLabel.Text = Format.meters(RunState.height)
		if RunState.best > 0 then
			bestLabel.Text = if RunState.height > RunState.best
				then "⭐ NEW BEST!"
				else "BEST " .. Format.meters(RunState.best)
		else
			bestLabel.Text = ""
		end
		runCoins.Text = Format.comma(RunState.coins)
		runGems.Text = Format.comma(RunState.gems)
		fuelBack.Visible = RunState.hasJetpack
		if RunState.maxFuel > 0 then
			fuelFill.Size = UDim2.fromScale(math.clamp(RunState.fuel / RunState.maxFuel, 0, 1), 1)
		end
	end
	if tick < 0.5 then
		return
	end
	tick = 0
	local snap = State.snapshot
	if not snap then
		return
	end
	-- Playtime track.
	local elapsed = State.sessionElapsed()
	local nextIndex: number? = nil
	for i in Config.PlaytimeRewards do
		if not snap.playtimeClaimed[i] then
			nextIndex = i
			break
		end
	end
	if nextIndex then
		local entry = Config.PlaytimeRewards[nextIndex]
		local target = entry.minutes * 60
		playtimeFill.Size = UDim2.fromScale(math.clamp(elapsed / target, 0, 1), 1)
		if elapsed >= target then
			playtimeText.Text = "READY! TAP TO CLAIM"
		else
			playtimeText.Text = Format.clock(elapsed) .. " / " .. Format.clock(target)
		end
		playtimeNext.Text = "NEXT: " .. (entry.reward.label or "")
	else
		playtimeFill.Size = UDim2.fromScale(1, 1)
		playtimeText.Text = "ALL CLAIMED — GREAT SESSION!"
		playtimeNext.Text = ""
	end
	updateBadges(snap)
	-- Potion timers tick locally.
	refreshEffects()
end

local function portalFlash()
	flash.BackgroundTransparency = 0
	UI.tween(flash, 0.6, { BackgroundTransparency = 1 })
end

function Hud.start()
	local _, created = UI.gui("SkyboundHud", 1)
	root = created
	buildHub()
	buildRun()
	buildShared()
	setMode(false)

	Bus.on("ProfileChanged", onProfile)
	if State.snapshot then
		onProfile(State.snapshot)
	end

	Bus.on("Toast", function(text: string, color: Color3?)
		Hud.toast(text, color)
	end)
	Remotes.event("Notify").OnClientEvent:Connect(function(text: string, kind: string?)
		Hud.toast(
			text,
			if kind == "error" or kind == "hub"
				then T.red
				elseif kind == "playtime" or kind == "quest" then T.gold
				else nil
		)
	end)
	Remotes.event("Milestone").OnClientEvent
		:Connect(function(data: { height: number, reward: string })
			bigBanner(
				Format.meters(data.height) .. "!",
				"NEW HEIGHT  •  " .. data.reward,
				T.gold,
				2.2
			)
			UI.playSound(Config.Sounds.Reward, 0.6, 1.2)
		end)
	Remotes.event("RewardPopup").OnClientEvent
		:Connect(function(data: { title: string, rarity: string, text: string })
			local color = Formulas.rarityColor(data.rarity)
			local big = data.rarity == "Legendary"
				or data.rarity == "Mythic"
				or data.rarity == "Secret"
			if big then
				bigBanner(data.title, data.text, color, 2.6)
			else
				Hud.toast(data.title .. ": " .. data.text, color)
			end
		end)
	Bus.on("WorldEntered", function(name: string)
		bigBanner(name:upper(), "NEW WORLD", T.text, 2.4)
	end)
	Bus.on("RunPrompt", function(text: string)
		promptLabel.Text = text
		promptLabel.Visible = text ~= ""
		if text ~= "" then
			UI.pop(promptLabel, 0.2)
		end
	end)
	Bus.on("RunBegan", function()
		hideResults()
		setMode(true)
		promptLabel.Visible = false
		portalFlash()
	end)
	Bus.on("RunExited", function()
		hideResults()
		setMode(false)
	end)
	Remotes.event("RunResult").OnClientEvent:Connect(function(result: Types.RunResult)
		task.wait(0.5)
		showResults(result)
	end)

	local busy = false
	local function retry()
		if busy then
			return
		end
		busy = true
		local response = Remotes.func("Retry"):InvokeServer()
		busy = false
		if typeof(response) == "table" and not response.ok then
			Hud.toast("Can't retry right now.", T.red)
		end
	end
	retryButton.Activated:Connect(retry)
	hubButton.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		Remotes.func("ReturnToHub"):InvokeServer()
		busy = false
		Bus.fire("RequestHub")
	end)
	-- Potion hotkeys during a climb.
	local potionKeys = {
		[Enum.KeyCode.One] = 1,
		[Enum.KeyCode.Two] = 2,
		[Enum.KeyCode.Three] = 3,
		[Enum.KeyCode.Four] = 4,
		[Enum.KeyCode.Five] = 5,
	}
	UserInputService.InputBegan:Connect(function(input, processed)
		local index = potionKeys[input.KeyCode]
		if processed or not index or not RunState.active then
			return
		end
		local def = Config.Potions[index]
		if def then
			Hud.usePotion(def.id)
		end
	end)
	-- Fast retry: R key / gamepad Y.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not resultsOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonY then
			UI.click()
			retry()
		end
	end)

	RunService.Heartbeat:Connect(heartbeat)

	-- Friendly welcome on first join.
	task.spawn(function()
		while not State.snapshot do
			task.wait(0.2)
		end
		local snap = State.snapshot :: Types.Snapshot
		if snap.profile.tutorial.step == 1 then
			bigBanner(
				"WELCOME TO SKYBOUND!",
				"Let's get you ready for your first flight.",
				T.text,
				2.8
			)
		end
	end)
	local _ = player
end

return Hud
