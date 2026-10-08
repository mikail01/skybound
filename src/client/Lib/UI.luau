--!strict
-- Chunky cartoon UI kit: rounded corners, thick strokes, soft drop shadows,
-- bouncy buttons and quick scale/fade panel animations. Layouts are built in
-- offsets on a 1600x900 design canvas and scaled to the real screen by a
-- single UIScale, so phones, tablets, PCs and TVs all get readable sizes.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local UI = {}

UI.Theme = table.freeze({
	font = Enum.Font.FredokaOne,
	text = Color3.fromRGB(255, 255, 255),
	dark = Color3.fromRGB(45, 40, 70),
	panel = Color3.fromRGB(250, 246, 255),
	panelInner = Color3.fromRGB(236, 230, 252),
	stroke = Color3.fromRGB(60, 45, 100),
	blue = Color3.fromRGB(80, 170, 255),
	green = Color3.fromRGB(90, 210, 100),
	pink = Color3.fromRGB(255, 110, 160),
	purple = Color3.fromRGB(150, 110, 255),
	gold = Color3.fromRGB(255, 196, 60),
	red = Color3.fromRGB(240, 85, 85),
	gray = Color3.fromRGB(160, 160, 180),
	coin = Color3.fromRGB(255, 205, 60),
	gem = Color3.fromRGB(110, 220, 255),
})

local T = UI.Theme
local DESIGN_HEIGHT = 900

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local function darker(c: Color3, amount: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), amount)
end
UI.darker = darker

function UI.new(className: string, props: { [string]: any }?, children: { any }?): any
	local inst = Instance.new(className)
	if props then
		local parent = props.Parent
		for key, value in props do
			if key ~= "Parent" then
				(inst :: any)[key] = value
			end
		end
		if children then
			for _, child in children do
				child.Parent = inst
			end
		end
		if parent then
			inst.Parent = parent
		end
	elseif children then
		for _, child in children do
			child.Parent = inst
		end
	end
	return inst
end

function UI.corner(radius: number?): any
	return UI.new("UICorner", { CornerRadius = UDim.new(0, radius or 16) })
end

function UI.stroke(color: Color3?, thickness: number?, border: boolean?): any
	return UI.new("UIStroke", {
		Color = color or T.stroke,
		Thickness = thickness or 3,
		ApplyStrokeMode = if border
			then Enum.ApplyStrokeMode.Border
			else Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

function UI.padding(px: number): UIPadding
	return UI.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

function UI.label(props: { [string]: any }): TextLabel
	local label = UI.new("TextLabel", {
		BackgroundTransparency = 1,
		Font = T.font,
		TextColor3 = T.text,
		TextScaled = true,
	})
	for key, value in props do
		if key ~= "Parent" and key ~= "Stroke" then
			(label :: any)[key] = value
		end
	end
	if props.Stroke ~= false then
		local s =
			UI.stroke(if typeof(props.Stroke) == "Color3" then props.Stroke else T.stroke, 2.5)
		s.Parent = label
	end
	UI.new("UITextSizeConstraint", { MaxTextSize = props.MaxText or 64, Parent = label })
	label.Parent = props.Parent
	return label
end

local clickSound: Sound? = nil
function UI.playSound(id: string, volume: number?, pitch: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume or 0.5
	sound.PlaybackSpeed = pitch or 1
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(5, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

function UI.click()
	if not clickSound then
		UI.playSound(Config.Sounds.Click, 0.35, 1.1)
	end
end

function UI.tween(
	inst: Instance,
	time: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	dir: Enum.EasingDirection?
): Tween
	local tween = TweenService:Create(
		inst,
		TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
		props
	)
	tween:Play()
	return tween
end

-- Quick "pop" emphasis on any GuiObject via a UIScale child.
function UI.pop(inst: GuiObject, amount: number?)
	local scale = inst:FindFirstChild("PopScale") :: UIScale?
	if not scale then
		local created = Instance.new("UIScale")
		created.Name = "PopScale"
		created.Parent = inst
		scale = created
	end
	local s = scale :: UIScale
	s.Scale = 1 + (amount or 0.15)
	UI.tween(s, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
end

export type ButtonOptions = {
	text: string,
	color: Color3?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	parent: Instance?,
	textSize: number?,
	layoutOrder: number?,
}

-- Chunky 3D-looking button: a darker "base" under a raised face that
-- presses down on click.
function UI.button(opts: ButtonOptions): TextButton
	local color = opts.color or T.green
	local button = UI.new("TextButton", {
		Name = opts.text,
		AutoButtonColor = false,
		BackgroundColor3 = darker(color, 0.3),
		Size = opts.size or UDim2.fromOffset(200, 64),
		Position = opts.position or UDim2.new(),
		AnchorPoint = opts.anchor or Vector2.zero,
		Text = "",
		LayoutOrder = opts.layoutOrder or 0,
		Selectable = true,
	}, { UI.corner(16) })
	local face = UI.new("Frame", {
		Name = "Face",
		BackgroundColor3 = color,
		Size = UDim2.new(1, 0, 1, -6),
		Position = UDim2.fromOffset(0, 0),
		Parent = button,
	}, {
		UI.corner(16),
		UI.new("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(215, 215, 215)),
			Rotation = 90,
		}),
	})
	UI.stroke(darker(color, 0.45), 3, true).Parent = button
	UI.label({
		Name = "Label",
		Text = opts.text,
		Size = UDim2.new(1, -16, 1, -12),
		Position = UDim2.fromOffset(8, 4),
		MaxText = opts.textSize or 30,
		Stroke = darker(color, 0.55),
		Parent = face,
	})
	local scale = UI.new("UIScale", { Parent = button })
	button.MouseEnter:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1.05 })
	end)
	button.MouseLeave:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1 })
		face.Position = UDim2.fromOffset(0, 0)
	end)
	button.SelectionGained:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1.06 })
	end)
	button.SelectionLost:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		face.Position = UDim2.fromOffset(0, 4)
	end)
	button.MouseButton1Up:Connect(function()
		face.Position = UDim2.fromOffset(0, 0)
	end)
	button.Activated:Connect(function()
		UI.click()
		UI.tween(scale, 0.08, { Scale = 0.94 }).Completed:Once(function()
			UI.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	end)
	button.Parent = opts.parent
	return button
end

function UI.setButton(button: TextButton, text: string, color: Color3?)
	local face = button:FindFirstChild("Face") :: Frame
	local label = face:FindFirstChild("Label") :: TextLabel
	label.Text = text
	if color then
		face.BackgroundColor3 = color
		button.BackgroundColor3 = darker(color, 0.3)
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = darker(color, 0.45)
		end
		local labelStroke = label:FindFirstChildOfClass("UIStroke")
		if labelStroke then
			labelStroke.Color = darker(color, 0.55)
		end
	end
end

-- Small red/green notification badge on a corner of `parent`.
function UI.badge(parent: GuiObject, color: Color3?): TextLabel
	local badge = UI.label({
		Name = "Badge",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(58, 28),
		BackgroundTransparency = 0,
		BackgroundColor3 = color or T.red,
		MaxText = 20,
		Visible = false,
		ZIndex = 5,
		Parent = parent,
	})
	UI.corner(14).Parent = badge
	return badge
end

function UI.gui(name: string, order: number): (ScreenGui, Frame)
	local gui = UI.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = order,
		Parent = playerGui,
	})
	-- Design canvas: 1600 wide-ish at 900 tall, scaled to fit.
	local root = UI.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = gui,
	})
	local scale = UI.new("UIScale", { Parent = root })
	local function resize()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1600, 900)
		local inset = GuiService:GetGuiInset()
		local usable = Vector2.new(viewport.X, viewport.Y - inset.Y)
		local s = math.clamp(usable.Y / DESIGN_HEIGHT, 0.45, 1.6)
		-- Keep the canvas from being wider than the screen on portrait phones.
		if usable.X / s < 1000 then
			s = usable.X / 1000
		end
		scale.Scale = s
		root.Size = UDim2.fromOffset(usable.X / s, usable.Y / s)
		root.Position = UDim2.new(0.5, 0, 0.5, inset.Y / 2)
	end
	resize()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize)
	end
	return gui, root
end

export type Panel = {
	frame: Frame,
	content: Frame,
	title: TextLabel,
	isOpen: () -> boolean,
	open: () -> (),
	close: () -> (),
	onOpen: (() -> ())?,
}

local openPanel: Panel? = nil

function UI.closeAll()
	if openPanel then
		openPanel.close()
	end
end

function UI.anyOpen(): boolean
	return openPanel ~= nil
end

-- Modal-ish panel. Only one is open at a time.
function UI.panel(root: Frame, titleText: string, color: Color3, size: Vector2): Panel
	local frame = UI.new("Frame", {
		Name = titleText,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = T.panel,
		Visible = false,
		ZIndex = 10,
		Parent = root,
	}, { UI.corner(28), UI.stroke(T.stroke, 5, true) })
	local scale = UI.new("UIScale", { Parent = frame })
	local header = UI.new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 78),
		BackgroundColor3 = color,
		ZIndex = 10,
		Parent = frame,
	}, { UI.corner(28) })
	-- Square off the header's bottom corners.
	UI.new("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 1, -28),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = header,
	})
	local title = UI.label({
		Text = titleText,
		Size = UDim2.new(1, -160, 0, 56),
		Position = UDim2.fromOffset(28, 11),
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxText = 46,
		ZIndex = 11,
		Stroke = darker(color, 0.5),
		Parent = header,
	})
	local content = UI.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(24, 96),
		Size = UDim2.new(1, -48, 1, -116),
		ZIndex = 10,
		Parent = frame,
	})
	local closeButton = UI.button({
		text = "X",
		color = T.red,
		size = UDim2.fromOffset(60, 60),
		position = UDim2.new(1, -16, 0, 10),
		anchor = Vector2.new(1, 0),
		parent = header,
	})
	closeButton.ZIndex = 12

	local panel: Panel
	local isOpen = false
	panel = {
		frame = frame,
		content = content,
		title = title,
		isOpen = function()
			return isOpen
		end,
		open = function()
			if isOpen then
				return
			end
			if openPanel and openPanel ~= panel then
				openPanel.close()
			end
			isOpen = true
			openPanel = panel
			frame.Visible = true
			scale.Scale = 0.85
			frame.Position = UDim2.fromScale(0.5, 0.55)
			UI.tween(scale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			UI.tween(frame, 0.18, { Position = UDim2.fromScale(0.5, 0.52) })
			if panel.onOpen then
				panel.onOpen()
			end
			if UserInputService.GamepadEnabled then
				GuiService.SelectedObject = closeButton
			end
		end,
		close = function()
			if not isOpen then
				return
			end
			isOpen = false
			if openPanel == panel then
				openPanel = nil
			end
			UI.tween(scale, 0.12, { Scale = 0.9 }).Completed:Once(function()
				if not isOpen then
					frame.Visible = false
				end
			end)
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(frame) then
				GuiService.SelectedObject = nil
			end
		end,
		onOpen = nil,
	}
	closeButton.Activated:Connect(panel.close)
	return panel
end

-- Escape / gamepad B closes the open panel.
UserInputService.InputBegan:Connect(function(input, processed)
	if
		input.KeyCode == Enum.KeyCode.ButtonB
		or (not processed and input.KeyCode == Enum.KeyCode.Escape)
	then
		UI.closeAll()
	end
end)

-- Rounded inset card used inside panels.
function UI.card(props: { [string]: any }): Frame
	local card = UI.new("Frame", {
		BackgroundColor3 = props.color or T.panelInner,
		Size = props.size or UDim2.fromOffset(200, 200),
		Position = props.position or UDim2.new(),
		LayoutOrder = props.layoutOrder or 0,
		ZIndex = 10,
	}, {
		UI.corner(props.radius or 20),
		UI.stroke(props.strokeColor or darker(T.panelInner, 0.25), 3, true),
	})
	card.Parent = props.parent
	return card
end

function UI.progressBar(
	parent: Instance,
	size: UDim2,
	position: UDim2,
	color: Color3
): (Frame, Frame, TextLabel)
	local back = UI.new("Frame", {
		Size = size,
		Position = position,
		BackgroundColor3 = darker(T.panelInner, 0.2),
		ZIndex = 10,
		Parent = parent,
	}, { UI.corner(100), UI.stroke(T.stroke, 2.5, true) })
	local fill = UI.new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		ZIndex = 10,
		Parent = back,
	}, { UI.corner(100) })
	local text = UI.label({
		Size = UDim2.fromScale(1, 0.9),
		Position = UDim2.fromScale(0, 0.05),
		Text = "",
		MaxText = 24,
		ZIndex = 11,
		Parent = back,
	})
	return back, fill, text
end

function UI.grid(parent: Instance, cell: Vector2, padding: number): ScrollingFrame
	local scroller = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = T.stroke,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = parent,
	})
	UI.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(cell.X, cell.Y),
		CellPadding = UDim2.fromOffset(padding, padding),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = scroller,
	})
	UI.padding(6).Parent = scroller
	return scroller
end

return UI
