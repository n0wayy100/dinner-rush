--[[
	Dinner Rush - ClassShopClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.ClassShopClient  (LocalScript)

	The CLASSES screen, reference-game layout: two floating side panels with
	the world (and the vendor) visible between them.

	  LEFT  - the card list, pinned to the left edge
	  RIGHT - the detail panel: rarity header band, big icon, LEVEL bar,
	          REQUIRED TASK block with a large progress bar, passive +
	          ultimate, and the BUY / EQUIP / UPGRADE buttons
	  BOTTOM CENTRE - wallet balance + the CLOSE button

	Render only: every number and decision comes from the server. Buttons
	send intent ("Purchase"/"Equip"/"Upgrade"); the screen re-renders when
	the server pushes a fresh profile snapshot. Courtesy-disabling (grey
	buttons) never replaces server validation.

	Progression rule drawn here: FINISH THE TASK, THEN PAY TO LEVEL.
	Task counters are written by the main game via ProfileService (future
	phase); the lobby only reads them from the snapshot.

	Follows the lobby close convention (MainPanel + CloseButton, Enabled
	AND Visible toggled). Camera focus + walk-away close as before.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local shopRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ClassShopRemote")

local SHOP = Config.ClassShop

local CREAM = Color3.fromRGB(255, 246, 233)
local WARM = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local GOLD = Color3.fromRGB(255, 200, 60)
local GREY = Color3.fromRGB(196, 188, 178)
local GREY_TEXT = Color3.fromRGB(122, 112, 102)
local BAR_BACK = Color3.fromRGB(45, 42, 40)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Small builders (panel chrome is all the same recipe)
----------------------------------------------------------------
local function stylize(frame, thickness)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or 3
	stroke.Color = CHOC
	stroke.Parent = frame
	return stroke
end

local function makeText(parent, name, font, color)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextScaled = true
	label.TextWrapped = true
	label.TextColor3 = color
	label.Text = ""
	label.Parent = parent
	return label
end

----------------------------------------------------------------
-- Skeleton: transparent full-screen root, two side panels
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ClassShop_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 30
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "MainPanel" --// lobby close convention
root.Size = UDim2.fromScale(1, 1)
root.BackgroundTransparency = 1
root.Parent = gui

----------------------------------------------------------------
-- LEFT: the card list
----------------------------------------------------------------
local leftPanel = Instance.new("Frame")
leftPanel.Name = "CardListPanel"
leftPanel.AnchorPoint = Vector2.new(0, 0.5)
leftPanel.Position = UDim2.fromScale(0.015, 0.52)
leftPanel.Size = UDim2.fromScale(0.23, 0.8)
leftPanel.BackgroundColor3 = CREAM
leftPanel.Parent = root
stylize(leftPanel)

local grad = Instance.new("UIGradient")
grad.Rotation = 90
grad.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
grad.Parent = leftPanel

--// The CLASSES sticker rides the panel's top edge
local title = makeText(root, "Title", Enum.Font.FredokaOne, CHOC)
title.AnchorPoint = Vector2.new(0, 0.5)
title.Position = UDim2.fromScale(0.03, 0.115)
title.Size = UDim2.fromScale(0.16, 0.065)
title.BackgroundTransparency = 0
title.BackgroundColor3 = MUSTARD
title.Rotation = -2
title.Text = "CLASSES"
stylize(title, 2.5)

local list = Instance.new("ScrollingFrame")
list.Name = "CardList"
list.AnchorPoint = Vector2.new(0.5, 0.5)
list.Position = UDim2.fromScale(0.5, 0.52)
list.Size = UDim2.fromScale(0.9, 0.9)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
list.CanvasSize = UDim2.fromScale(0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = leftPanel

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0.025, 0)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder --// Config order, not names
listLayout.Parent = list

----------------------------------------------------------------
-- RIGHT: the detail panel, roomy on purpose
----------------------------------------------------------------
local detail = Instance.new("Frame")
detail.Name = "DetailPanel"
detail.AnchorPoint = Vector2.new(1, 0.5)
detail.Position = UDim2.fromScale(0.985, 0.52)
detail.Size = UDim2.fromScale(0.27, 0.8)
detail.BackgroundColor3 = CREAM
detail.Parent = root
stylize(detail)

local detailGrad = Instance.new("UIGradient")
detailGrad.Rotation = 90
detailGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
detailGrad.Parent = detail

--// Rarity-coloured header band: class name + rarity live here
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.fromScale(1, 0.13)
header.BackgroundColor3 = BASIL
header.Parent = detail

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 14)
headerCorner.Parent = header

local dName = makeText(header, "ClassName", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
dName.AnchorPoint = Vector2.new(0.5, 0)
dName.Position = UDim2.fromScale(0.5, 0.1)
dName.Size = UDim2.fromScale(0.92, 0.52)
dName.TextStrokeColor3 = CHOC
dName.TextStrokeTransparency = 0.3

local dRarity = makeText(header, "Rarity", Enum.Font.GothamBold, Color3.new(1, 1, 1))
dRarity.AnchorPoint = Vector2.new(0.5, 0)
dRarity.Position = UDim2.fromScale(0.5, 0.64)
dRarity.Size = UDim2.fromScale(0.5, 0.28)
dRarity.TextTransparency = 0.15

local dIcon = Instance.new("ImageLabel")
dIcon.AnchorPoint = Vector2.new(0.5, 0)
dIcon.Position = UDim2.fromScale(0.5, 0.155)
dIcon.Size = UDim2.fromScale(0.34, 0.155)
dIcon.BackgroundColor3 = Color3.new(1, 1, 1)
dIcon.ScaleType = Enum.ScaleType.Fit
dIcon.Parent = detail
stylize(dIcon, 2)

local dInitial = makeText(dIcon, "Initial", Enum.Font.FredokaOne, CHOC)
dInitial.Size = UDim2.fromScale(1, 1)

local dFlavor = makeText(detail, "Flavor", Enum.Font.Gotham, GREY_TEXT)
dFlavor.AnchorPoint = Vector2.new(0.5, 0)
dFlavor.Position = UDim2.fromScale(0.5, 0.325)
dFlavor.Size = UDim2.fromScale(0.9, 0.05)

--// LEVEL: caption + a big gold bar with the Lv text on it
local levelCaption = makeText(detail, "LevelCaption", Enum.Font.GothamBold, CHOC)
levelCaption.AnchorPoint = Vector2.new(0.5, 0)
levelCaption.Position = UDim2.fromScale(0.5, 0.39)
levelCaption.Size = UDim2.fromScale(0.9, 0.028)
levelCaption.TextXAlignment = Enum.TextXAlignment.Left
levelCaption.Text = "LEVEL"

local levelBack = Instance.new("Frame")
levelBack.AnchorPoint = Vector2.new(0.5, 0)
levelBack.Position = UDim2.fromScale(0.5, 0.424)
levelBack.Size = UDim2.fromScale(0.9, 0.048)
levelBack.BackgroundColor3 = BAR_BACK
levelBack.BorderSizePixel = 0
levelBack.Parent = detail

local levelBackCorner = Instance.new("UICorner")
levelBackCorner.CornerRadius = UDim.new(1, 0)
levelBackCorner.Parent = levelBack

local levelFill = Instance.new("Frame")
levelFill.Size = UDim2.fromScale(0, 1)
levelFill.BackgroundColor3 = GOLD
levelFill.BorderSizePixel = 0
levelFill.Parent = levelBack

local levelFillCorner = Instance.new("UICorner")
levelFillCorner.CornerRadius = UDim.new(1, 0)
levelFillCorner.Parent = levelFill

local levelText = makeText(levelBack, "LevelText", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
levelText.Size = UDim2.fromScale(1, 0.8)
levelText.AnchorPoint = Vector2.new(0.5, 0.5)
levelText.Position = UDim2.fromScale(0.5, 0.5)
levelText.TextStrokeColor3 = CHOC
levelText.TextStrokeTransparency = 0.3

--// REQUIRED TASK: its own banded section with a LARGE progress bar
local taskHeader = makeText(detail, "TaskHeader", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
taskHeader.AnchorPoint = Vector2.new(0.5, 0)
taskHeader.Position = UDim2.fromScale(0.5, 0.502)
taskHeader.Size = UDim2.fromScale(0.9, 0.042)
taskHeader.BackgroundTransparency = 0
taskHeader.BackgroundColor3 = BASIL
taskHeader.Text = "REQUIRED TASK"
taskHeader.TextStrokeColor3 = CHOC
taskHeader.TextStrokeTransparency = 0.4
stylize(taskHeader, 2)

local taskLabel = makeText(detail, "TaskLabel", Enum.Font.GothamBold, CHOC)
taskLabel.AnchorPoint = Vector2.new(0.5, 0)
taskLabel.Position = UDim2.fromScale(0.5, 0.556)
taskLabel.Size = UDim2.fromScale(0.9, 0.038)

local taskBack = Instance.new("Frame")
taskBack.AnchorPoint = Vector2.new(0.5, 0)
taskBack.Position = UDim2.fromScale(0.5, 0.602)
taskBack.Size = UDim2.fromScale(0.9, 0.05)
taskBack.BackgroundColor3 = BAR_BACK
taskBack.BorderSizePixel = 0
taskBack.Parent = detail

local taskBackCorner = Instance.new("UICorner")
taskBackCorner.CornerRadius = UDim.new(1, 0)
taskBackCorner.Parent = taskBack

local taskFill = Instance.new("Frame")
taskFill.Size = UDim2.fromScale(0, 1)
taskFill.BackgroundColor3 = MUSTARD
taskFill.BorderSizePixel = 0
taskFill.Parent = taskBack

local taskFillCorner = Instance.new("UICorner")
taskFillCorner.CornerRadius = UDim.new(1, 0)
taskFillCorner.Parent = taskFill

local taskCount = makeText(taskBack, "TaskCount", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
taskCount.Size = UDim2.fromScale(1, 0.75)
taskCount.AnchorPoint = Vector2.new(0.5, 0.5)
taskCount.Position = UDim2.fromScale(0.5, 0.5)
taskCount.TextStrokeColor3 = CHOC
taskCount.TextStrokeTransparency = 0.3

--// Powers
local dPassive = makeText(detail, "Passive", Enum.Font.GothamMedium, CHOC)
dPassive.AnchorPoint = Vector2.new(0.5, 0)
dPassive.Position = UDim2.fromScale(0.5, 0.675)
dPassive.Size = UDim2.fromScale(0.9, 0.045)

local dUltName = makeText(detail, "UltimateName", Enum.Font.FredokaOne, TOMATO)
dUltName.AnchorPoint = Vector2.new(0.5, 0)
dUltName.Position = UDim2.fromScale(0.5, 0.726)
dUltName.Size = UDim2.fromScale(0.9, 0.05)

local dUltText = makeText(detail, "UltimateText", Enum.Font.Gotham, GREY_TEXT)
dUltText.AnchorPoint = Vector2.new(0.5, 0)
dUltText.Position = UDim2.fromScale(0.5, 0.778)
dUltText.Size = UDim2.fromScale(0.9, 0.052)

local dError = makeText(detail, "ErrorText", Enum.Font.GothamBold, TOMATO)
dError.AnchorPoint = Vector2.new(0.5, 0)
dError.Position = UDim2.fromScale(0.5, 0.834)
dError.Size = UDim2.fromScale(0.9, 0.036)

--// Buttons
local function makeButton(name)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Size = UDim2.fromScale(0.9, 0.055)
	button.BackgroundColor3 = MUSTARD
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.TextColor3 = CHOC
	button.Text = ""
	button.Parent = detail
	stylize(button, 2.5)
	return button
end

local actionBtn = makeButton("ActionButton")
local upgradeBtn = makeButton("UpgradeButton")
upgradeBtn.Visible = false

----------------------------------------------------------------
-- BOTTOM CENTRE: balance + CLOSE, reference-game style
----------------------------------------------------------------
local wallet = makeText(root, "Wallet", Enum.Font.FredokaOne, CHOC)
wallet.AnchorPoint = Vector2.new(0.5, 1)
wallet.Position = UDim2.fromScale(0.5, 0.89)
wallet.Size = UDim2.fromScale(0.16, 0.055)
wallet.BackgroundTransparency = 0
wallet.BackgroundColor3 = MUSTARD
wallet.Text = "$ 0"
stylize(wallet, 2.5)

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.AnchorPoint = Vector2.new(0.5, 1)
closeBtn.Position = UDim2.fromScale(0.5, 0.965)
closeBtn.Size = UDim2.fromScale(0.13, 0.06)
closeBtn.BackgroundColor3 = TOMATO
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextScaled = true
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "CLOSE"
closeBtn.Parent = root
stylize(closeBtn, 2.5)

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local snapshot = nil
local selectedKey = nil
local vendorRoot = nil
local cardsByKey = {}
local celebrateKey = nil
local errorSerial = 0

----------------------------------------------------------------
-- Camera focus
----------------------------------------------------------------
local savedCameraCFrame, savedCameraType = nil, nil

local function cameraFocus(on)
	if not SHOP.CameraFocus then return end
	local camera = workspace.CurrentCamera
	if not camera then return end

	if on and vendorRoot then
		if savedCameraType == nil then
			savedCameraType = camera.CameraType
			savedCameraCFrame = camera.CFrame
		end
		camera.CameraType = Enum.CameraType.Scriptable
		local look = vendorRoot.Position + Vector3.new(0, 1.5, 0)
		local from = look + vendorRoot.CFrame.LookVector * 7 + Vector3.new(0, 1, 0)
		TweenService:Create(camera,
			TweenInfo.new(SHOP.CameraTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.lookAt(from, look) }):Play()
	elseif savedCameraType ~= nil then
		camera.CameraType = savedCameraType
		camera.CFrame = savedCameraCFrame
		savedCameraType, savedCameraCFrame = nil, nil
	end
end

----------------------------------------------------------------
-- Rendering
----------------------------------------------------------------
local function stateFor(classKey)
	local owned = snapshot and snapshot.OwnedClasses[classKey]
	local equipped = snapshot and snapshot.EquippedClass == classKey
	return owned, equipped
end

local function chipTextFor(classKey)
	local class = Config.Classes[classKey]
	local owned, equipped = stateFor(classKey)
	if equipped then
		return "★ EQUIPPED", Color3.new(1, 1, 1)
	elseif owned then
		return "OWNED", Color3.new(1, 1, 1)
	elseif classKey == "Trainee" then
		return "Complete the tutorial!", Color3.fromRGB(235, 235, 235)
	end
	return ("$ %d"):format(class.Price), Color3.fromRGB(255, 236, 130)
end

local function renderCard(classKey)
	local card = cardsByKey[classKey]
	if not card then return end
	local class = Config.Classes[classKey]
	local owned = stateFor(classKey)

	local chipText, chipColor = chipTextFor(classKey)
	card.Chip.Text = chipText
	card.Chip.TextColor3 = chipColor

	local selected = selectedKey == classKey
	card.Stroke.Color = selected and Color3.new(1, 1, 1) or CHOC
	card.Stroke.Thickness = selected and 3.5 or 2

	local hasIcon = class.IconId ~= ""
	card.Icon.Visible = hasIcon
	card.Initial.Visible = not hasIcon
	card.IconBox.BackgroundColor3 = owned and Color3.new(1, 1, 1) or BAR_BACK
	card.Icon.ImageColor3 = owned and Color3.new(1, 1, 1) or Color3.fromRGB(25, 25, 25)
	card.Initial.TextColor3 = owned and CHOC or Color3.fromRGB(110, 100, 92)
end

local function renderDetail()
	local classKey = selectedKey
	if not classKey then return end
	local class = Config.Classes[classKey]
	local owned, equipped = stateFor(classKey)

	header.BackgroundColor3 = class.RarityColor
	dName.Text = class.Display
	dRarity.Text = class.Rarity
	dIcon.Image = class.IconId
	dInitial.Visible = class.IconId == ""
	dInitial.Text = string.upper(string.sub(classKey, 1, 1))
	dFlavor.Text = "\"" .. class.FlavorText .. "\""
	dPassive.Text = class.PassiveText
	dUltName.Text = class.UltimateName
	dUltText.Text = class.UltimateText

	--// Level + the task track: finish the task, then pay to level
	local track = class.UpgradeTrack
	local level = (snapshot and snapshot.ClassLevels[classKey]) or 1
	local taskDone, upgradeCost = false, 0
	local progressShown = track ~= nil

	levelCaption.Visible = progressShown
	levelBack.Visible = progressShown
	taskHeader.Visible = progressShown
	taskLabel.Visible = progressShown
	taskBack.Visible = progressShown

	if track then
		local maxLevel = #track.Steps + 1
		levelText.Text = ("Lv %d / %d"):format(level, maxLevel)
		levelFill.Size = UDim2.fromScale(math.clamp(level / maxLevel, 0, 1), 1)

		if level <= #track.Steps then
			local progress = (snapshot and snapshot.TaskProgress
				and snapshot.TaskProgress[track.Counter]) or 0
			local needed = track.Steps[level]
			taskDone = progress >= needed
			upgradeCost = track.Costs[level]

			taskLabel.Text = track.Label
			taskCount.Text = ("%d / %d"):format(math.min(progress, needed), needed)
			taskFill.Size = UDim2.fromScale(math.clamp(progress / needed, 0, 1), 1)
			taskFill.BackgroundColor3 = taskDone and BASIL or MUSTARD
		else
			taskLabel.Text = "Every task complete!"
			taskCount.Text = "MAX LEVEL"
			taskFill.Size = UDim2.fromScale(1, 1)
			taskFill.BackgroundColor3 = BASIL
		end
	end

	--// Upgrade button (owned + levelable only); stays tappable when grey
	--// so the server's reason can explain what's missing
	if owned and track then
		upgradeBtn.Visible = true
		if level > #track.Steps then
			upgradeBtn.Text = "MAX"
			upgradeBtn.BackgroundColor3 = GREY
			upgradeBtn.TextColor3 = GREY_TEXT
			upgradeBtn.AutoButtonColor = false
		else
			local ready = taskDone and snapshot and snapshot.Wallet >= upgradeCost
			upgradeBtn.Text = ("UPGRADE · $%d"):format(upgradeCost)
			upgradeBtn.BackgroundColor3 = ready and GOLD or GREY
			upgradeBtn.TextColor3 = ready and CHOC or GREY_TEXT
			upgradeBtn.AutoButtonColor = true
		end
	else
		upgradeBtn.Visible = false
	end

	--// Buttons stack at the bottom; the action button spreads out alone
	if upgradeBtn.Visible then
		actionBtn.Position = UDim2.fromScale(0.5, 0.878)
		upgradeBtn.Position = UDim2.fromScale(0.5, 0.938)
	else
		actionBtn.Position = UDim2.fromScale(0.5, 0.9)
	end

	if equipped then
		actionBtn.Text = "EQUIPPED"
		actionBtn.BackgroundColor3 = GREY
		actionBtn.TextColor3 = GREY_TEXT
		actionBtn.AutoButtonColor = false
	elseif owned then
		actionBtn.Text = "EQUIP"
		actionBtn.BackgroundColor3 = BASIL
		actionBtn.TextColor3 = Color3.new(1, 1, 1)
		actionBtn.AutoButtonColor = true
	elseif classKey == "Trainee" then
		actionBtn.Text = "Complete the tutorial!"
		actionBtn.BackgroundColor3 = GREY
		actionBtn.TextColor3 = GREY_TEXT
		actionBtn.AutoButtonColor = false
	else
		local short = snapshot and snapshot.Wallet < class.Price
		actionBtn.Text = ("BUY · $%d"):format(class.Price)
		actionBtn.BackgroundColor3 = short and GREY or MUSTARD
		actionBtn.TextColor3 = short and GREY_TEXT or CHOC
		actionBtn.AutoButtonColor = not short
	end
end

local function renderAll()
	if snapshot then
		wallet.Text = ("$ %d"):format(snapshot.Wallet)
	end
	for _, classKey in ipairs(SHOP.CardOrder) do
		renderCard(classKey)
	end
	renderDetail()
end

local function showError(text)
	errorSerial += 1
	local mySerial = errorSerial
	dError.Text = text
	task.delay(2.5, function()
		if errorSerial == mySerial then
			dError.Text = ""
		end
	end)
end

local function celebrate(classKey)
	local card = cardsByKey[classKey]
	if not card then return end
	local flash = Instance.new("Frame")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 0.1
	flash.ZIndex = 5
	flash.Parent = card.Frame
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 10)
	fc.Parent = flash
	TweenService:Create(flash,
		TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }):Play()
	task.delay(0.75, function() flash:Destroy() end)
end

----------------------------------------------------------------
-- Card construction: tall reference-style rows
----------------------------------------------------------------
local function buildCard(order, classKey)
	local class = Config.Classes[classKey]

	local frame = Instance.new("TextButton")
	frame.Name = classKey
	frame.Size = UDim2.fromScale(1, 0.17)
	frame.BackgroundColor3 = class.RarityColor
	frame.Text = ""
	frame.LayoutOrder = order
	frame.Parent = list

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 10)
	cardCorner.Parent = frame

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 2
	cardStroke.Color = CHOC
	cardStroke.Parent = frame

	local iconBox = Instance.new("Frame")
	iconBox.AnchorPoint = Vector2.new(0, 0.5)
	iconBox.Position = UDim2.fromScale(0.04, 0.5)
	iconBox.Size = UDim2.fromScale(0.18, 0.76)
	iconBox.BackgroundColor3 = Color3.new(1, 1, 1)
	iconBox.Parent = frame

	local iconBoxCorner = Instance.new("UICorner")
	iconBoxCorner.CornerRadius = UDim.new(0, 8)
	iconBoxCorner.Parent = iconBox

	local iconBoxStroke = Instance.new("UIStroke")
	iconBoxStroke.Thickness = 2
	iconBoxStroke.Color = CHOC
	iconBoxStroke.Parent = iconBox

	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.Image = class.IconId
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = iconBox

	local initial = makeText(iconBox, "Initial", Enum.Font.FredokaOne, CHOC)
	initial.Size = UDim2.fromScale(1, 1)
	initial.Text = string.upper(string.sub(classKey, 1, 1))

	local name = makeText(frame, "ClassName", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
	name.AnchorPoint = Vector2.new(0, 0.5)
	name.Position = UDim2.fromScale(0.26, 0.3)
	name.Size = UDim2.fromScale(0.7, 0.36)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextStrokeColor3 = CHOC
	name.TextStrokeTransparency = 0.35

	--// Dark pill so the state/price reads on EVERY rarity colour
	local chip = makeText(frame, "StateChip", Enum.Font.GothamBold, Color3.new(1, 1, 1))
	chip.AnchorPoint = Vector2.new(0, 0.5)
	chip.Position = UDim2.fromScale(0.26, 0.74)
	chip.Size = UDim2.fromScale(0.52, 0.26)
	chip.BackgroundTransparency = 0.15
	chip.BackgroundColor3 = CHOC

	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(1, 0)
	chipCorner.Parent = chip

	local chipPad = Instance.new("UIPadding")
	chipPad.PaddingLeft = UDim.new(0.06, 0)
	chipPad.PaddingRight = UDim.new(0.06, 0)
	chipPad.PaddingTop = UDim.new(0.08, 0)
	chipPad.PaddingBottom = UDim.new(0.08, 0)
	chipPad.Parent = chip

	frame.Activated:Connect(function()
		selectedKey = classKey
		renderAll()
	end)

	cardsByKey[classKey] = {
		Frame = frame, Stroke = cardStroke, Chip = chip,
		Icon = icon, Initial = initial, IconBox = iconBox,
	}
end

for order, classKey in ipairs(SHOP.CardOrder) do
	buildCard(order, classKey)
end

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------
local walkWatcher = nil

local function setOpen(open)
	gui.Enabled = open
	root.Visible = open
	cameraFocus(open)

	if walkWatcher then
		walkWatcher:Disconnect()
		walkWatcher = nil
	end

	if open then
		walkWatcher = RunService.Heartbeat:Connect(function()
			local character = player.Character
			local charRoot = character and character:FindFirstChild("HumanoidRootPart")
			if charRoot and vendorRoot
				and (charRoot.Position - vendorRoot.Position).Magnitude > SHOP.WalkAwayCloseStuds then
				setOpen(false)
			end
		end)
	end
end

closeBtn.Activated:Connect(function()
	setOpen(false)
end)

upgradeBtn.Activated:Connect(function()
	if not selectedKey or not snapshot then return end
	shopRemote:FireServer("Upgrade", selectedKey)
end)

actionBtn.Activated:Connect(function()
	if not selectedKey or not snapshot then return end
	local owned, equipped = stateFor(selectedKey)
	if equipped then return end

	if owned then
		shopRemote:FireServer("Equip", selectedKey)
	elseif selectedKey ~= "Trainee" then
		if snapshot.Wallet >= Config.Classes[selectedKey].Price then
			celebrateKey = selectedKey
		end
		shopRemote:FireServer("Purchase", selectedKey)
	end
end)

----------------------------------------------------------------
-- Server traffic
----------------------------------------------------------------
shopRemote.OnClientEvent:Connect(function(action, a, b, c, d)
	if action == "Open" then
		snapshot = a
		vendorRoot = b
		selectedKey = selectedKey or SHOP.CardOrder[1]
		dError.Text = ""
		renderAll()
		setOpen(true)

	elseif action == "Profile" then
		snapshot = a
		renderAll()
		if celebrateKey and snapshot.OwnedClasses[celebrateKey] then
			celebrate(celebrateKey)
			celebrateKey = nil
		end

	elseif action == "Result" then
		--// a = ok, b = reason, c = action, d = classKey
		if not a and b then
			showError(b)
			celebrateKey = nil
		elseif a and c == "Upgrade" and d then
			celebrate(d)
		end
	end
end)
