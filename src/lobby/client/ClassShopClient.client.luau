--[[
	Dinner Rush - ClassShopClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.ClassShopClient  (LocalScript)

	The CLASSES screen, reference-game layout: two floating side panels with
	the world (and the vendor) visible between them.

	  LEFT  - the card list, pinned to the left edge
	  RIGHT - the detail panel: rarity header band, big icon, LEVEL bar,
	          REQUIRED TASK block with a large progress bar, the passive,
	          a Q / R / T skill row (tap a tile for a readable card), and
	          the BUY / EQUIP / UPGRADE buttons
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

--// THE ART KIT (Oct 2026): the owner's original layout, skinned with the
--// Claude Design classes kit (Config.ClassShop.Art) + the shop / Staff Room
--// shared sprites. An empty slot keeps that piece's code-drawn look.
local UIKit = require(ReplicatedStorage.Shared:WaitForChild("UIKit"))
local kit = UIKit.artKit(SHOP.Art or {},
	(Config.Monetization and Config.Monetization.ShopArt) or {},
	(Config.PlayerStats and Config.PlayerStats.StaffArt) or {})

local SfxLocal = nil
pcall(function()
	SfxLocal = require(ReplicatedStorage.Shared:WaitForChild("SfxLocal", 5))
end)

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
-- Art helpers (the kit draws the piece; these keep the code's colours and
-- text working on top of it)
----------------------------------------------------------------
local DIM_TINT = Color3.fromRGB(165, 160, 155)

local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then
		pcall(SfxLocal.Play, name)
	end
end

local function artOf(obj)
	return obj:FindFirstChild("Art")
end

--// tintable art is drawn white: whatever colour the code gives the piece
--// (rarity, skill slot) becomes the art's tint
local function tintFollow(obj)
	local function apply()
		local art = artOf(obj)
		if art then art.ImageColor3 = obj.BackgroundColor3 end
	end
	obj:GetPropertyChangedSignal("BackgroundColor3"):Connect(apply)
	apply()
end

--// a label or button's OWN text draws under its art child - mirror the text
--// into a label on top and hide the original (the code keeps setting .Text)
local function textOnTop(obj, transform, box)
	local pad = obj:FindFirstChildOfClass("UIPadding")
	if pad then pad:Destroy() end --// padding would squash the art too
	box = box or {}
	local top = Instance.new("TextLabel")
	top.Name = "TextOnTop"
	top.BackgroundTransparency = 1
	top.AnchorPoint = Vector2.new(0.5, 0.5)
	top.Position = UDim2.fromScale(box.X or 0.5, box.Y or 0.46)
	top.Size = UDim2.fromScale(box.W or 0.86, box.H or 0.6)
	top.Font = obj.Font
	top.TextScaled = true
	top.TextWrapped = true
	top.TextXAlignment = obj.TextXAlignment
	top.TextStrokeColor3 = box.Stroke and CHOC or obj.TextStrokeColor3
	top.TextStrokeTransparency = box.Stroke and 0 or obj.TextStrokeTransparency
	top.ZIndex = obj.ZIndex + 1
	top.Parent = obj
	local function sync()
		top.Text = transform and transform(obj.Text) or obj.Text
		top.TextColor3 = obj.TextColor3
	end
	obj:GetPropertyChangedSignal("Text"):Connect(sync)
	obj:GetPropertyChangedSignal("TextColor3"):Connect(sync)
	sync()
	obj.TextTransparency = 1
	obj.TextStrokeTransparency = 1
	return top
end

--// buttons: the code paints them BASIL / MUSTARD / GOLD / GREY - that picks
--// the green or gold button art, greyed out when disabled
local function buttonFollow(btn)
	local function apply()
		local art = artOf(btn)
		if not art then return end
		local c = btn.BackgroundColor3
		if c == GREY then
			art.Image = kit.id("PriceButtonGreen") or art.Image
			art.ImageColor3 = DIM_TINT
		elseif c == BASIL then
			art.Image = kit.id("PriceButtonGreen") or art.Image
			art.ImageColor3 = Color3.new(1, 1, 1)
		else
			art.Image = kit.id("PriceButtonGold") or art.Image
			art.ImageColor3 = Color3.new(1, 1, 1)
		end
	end
	btn:GetPropertyChangedSignal("BackgroundColor3"):Connect(apply)
	apply()
end

--// bar fills: green art when the code paints BASIL (task done), gold
--// otherwise; hidden while too narrow for its rounded ends
local function fillFollow(fill)
	local function apply()
		local art = artOf(fill)
		if not art then return end
		art.Image = (fill.BackgroundColor3 == BASIL and kit.id("XPBarFill"))
			or kit.id("XPBarFillGold") or art.Image
		art.Visible = fill.AbsoluteSize.X > fill.AbsoluteSize.Y
	end
	fill:GetPropertyChangedSignal("BackgroundColor3"):Connect(apply)
	fill:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	apply()
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
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling --// art layers sit under their text
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
kit.skin(leftPanel, "ListPanel")

--// The CLASSES sticker rides the panel's top edge. White with a chocolate
--// outline, like the lobby's FREE!/CODES! stickers - chocolate-on-mustard
--// read as a dark smudge (owner feedback).
local title = makeText(root, "Title", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
title.AnchorPoint = Vector2.new(0, 0.5)
title.Position = UDim2.fromScale(0.03, 0.115)
title.Size = UDim2.fromScale(0.16, 0.065)
title.BackgroundTransparency = 0
title.BackgroundColor3 = MUSTARD
title.Rotation = -2
title.Text = "CLASSES"
title.TextStrokeColor3 = CHOC
title.TextStrokeTransparency = 0
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
listLayout.Padding = UDim.new(0.015, 0) --// six classes fit without scrolling
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
local detailSkinned = kit.skin(detail, "DetailPanel")

--// Rarity-coloured header band: class name + rarity live here
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.fromScale(1, 0.13)
header.BackgroundColor3 = BASIL
header.Parent = detail

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 14)
headerCorner.Parent = header
if kit.skin(header, "HeaderBand") then
	tintFollow(header) --// renderDetail paints it the rarity colour
	if detailSkinned then --// sit inside the panel art's border
		header.AnchorPoint = Vector2.new(0.5, 0)
		header.Position = UDim2.fromScale(0.5, 0.012)
		header.Size = UDim2.fromScale(0.955, 0.125)
	end
end

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

--// The class stickers are square 512s; keep their frame square too
local dIconAspect = Instance.new("UIAspectRatioConstraint")
dIconAspect.AspectRatio = 1
dIconAspect.Parent = dIcon

local dInitial = makeText(dIcon, "Initial", Enum.Font.FredokaOne, CHOC)
dInitial.Size = UDim2.fromScale(1, 1)

--// THE SHOWCASE: the big icon sits inside the glowing gold showcase frame
--// (which gently pulses), with a padlock on it while the class is locked.
--// A holder takes the icon's old spot so the art can overflow around it.
local showcaseHolder, detailLock = nil, nil
local dIconScale = Instance.new("UIScale")
dIconScale.Parent = dIcon
if kit.id("ShowcaseFrame") then
	showcaseHolder = Instance.new("Frame")
	showcaseHolder.Name = "Showcase"
	showcaseHolder.AnchorPoint = dIcon.AnchorPoint
	showcaseHolder.Position = dIcon.Position
	showcaseHolder.Size = dIcon.Size
	showcaseHolder.BackgroundTransparency = 1
	showcaseHolder.Parent = detail
	local holderAspect = Instance.new("UIAspectRatioConstraint")
	holderAspect.AspectRatio = 1
	holderAspect.Parent = showcaseHolder

	local frameArt = kit.image(showcaseHolder, "ShowcaseFrame", "Frame")
	frameArt.AnchorPoint = Vector2.new(0.5, 0.5)
	frameArt.Position = UDim2.fromScale(0.5, 0.5)
	frameArt.Size = UDim2.fromScale(1.15, 1.15)
	frameArt.ZIndex = 0
	local pulse = Instance.new("UIScale")
	pulse.Parent = frameArt
	TweenService:Create(pulse, TweenInfo.new(1.2, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true), { Scale = 1.05 }):Play()

	for _, child in ipairs(dIcon:GetChildren()) do
		if child:IsA("UIStroke") or child:IsA("UICorner") then child:Destroy() end
	end
	dIcon.BackgroundTransparency = 1
	dIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	dIcon.Position = UDim2.fromScale(0.5, 0.5)
	dIcon.Size = UDim2.fromScale(0.74, 0.74)
	dIcon.ZIndex = 1
	dIcon.Parent = showcaseHolder

	detailLock = kit.image(showcaseHolder, "PadlockClosed", "Lock")
	if detailLock then
		detailLock.AnchorPoint = Vector2.new(0.5, 0.5)
		detailLock.Position = UDim2.fromScale(0.86, 0.84)
		detailLock.Size = UDim2.fromScale(0.42, 0.42)
		detailLock.Rotation = 10
		detailLock.ZIndex = 3
		detailLock.Visible = false
	end
end


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
taskHeader.Text = "PASSIVE"
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

--// bars + the section banner in the kit's art
for _, bar in ipairs({ { levelBack, levelFill, levelText }, { taskBack, taskFill, taskCount } }) do
	local back, fill, text = bar[1], bar[2], bar[3]
	kit.skin(back, "XPBarFrame")
	if kit.skin(fill, "XPBarFillGold") then
		fillFollow(fill)
	end
	fill.ZIndex = 1
	text.ZIndex = 2
end
if kit.skin(taskHeader, "SectionBanner") then
	tintFollow(taskHeader)
	textOnTop(taskHeader, nil, { W = 0.7, H = 0.62, Y = 0.44 })
end

--// Powers
--// THE PASSIVE (owner, Oct 5 2026): sits under the PASSIVE banner, in the
--// space the old task label + task bar used (those are retired - levels
--// are bought with coins alone now)
local dPassive = makeText(detail, "Passive", Enum.Font.FredokaOne, CHOC)
dPassive.AnchorPoint = Vector2.new(0.5, 0)
dPassive.Position = UDim2.fromScale(0.5, 0.56)
dPassive.Size = UDim2.fromScale(0.86, 0.1)
local passiveCap = Instance.new("UITextSizeConstraint")
passiveCap.MaxTextSize = 26
passiveCap.Parent = dPassive
taskLabel.Visible = false
taskBack.Visible = false
--// PASSIVES MOVED TO CRATES (Oct 2026, owner): the class screen no longer
--// shows a passive at all - the banner and its line are hidden
taskHeader.Visible = false
dPassive.Visible = false

--// SKILLS: one tile per key - Q, R, then the ultimate on T. Tapping a tile
--// opens a big readable card in the middle of the screen, because a skill
--// description squeezed into a side panel is text nobody reads.
local SKILL_KEYS = Config.Skills or {}
local SLOTS = {
	{ Slot = "SkillQ", Key = SKILL_KEYS.QKey or "Q" },
	{ Slot = "SkillR", Key = SKILL_KEYS.RKey or "R" },
	{ Slot = "Ultimate", Key = SKILL_KEYS.UltKey or "T" },
}

--// Each slot has its own colour so the three read apart at a glance.
--// Main fills the tile and the card; Dark is for chips and outlines on top.
local SLOT_COLORS = {
	SkillQ = { Main = Color3.fromRGB(76, 175, 109), Dark = Color3.fromRGB(44, 120, 70) },    -- green
	SkillR = { Main = Color3.fromRGB(242, 146, 48), Dark = Color3.fromRGB(176, 94, 18) },    -- orange
	Ultimate = { Main = Color3.fromRGB(72, 138, 232), Dark = Color3.fromRGB(36, 88, 172) },  -- blue
	Locked = { Main = Color3.fromRGB(196, 188, 178), Dark = Color3.fromRGB(140, 130, 120) },
}

local skillRow = Instance.new("Frame")
skillRow.Name = "SkillRow"
skillRow.AnchorPoint = Vector2.new(0.5, 0)
skillRow.Position = UDim2.fromScale(0.5, 0.724)
skillRow.Size = UDim2.fromScale(0.9, 0.105)
skillRow.BackgroundTransparency = 1
skillRow.Parent = detail

local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Horizontal
rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
rowLayout.Padding = UDim.new(0.04, 0)
rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowLayout.Parent = skillRow

local function hasImage(id)
	return type(id) == "string" and id ~= "" and not id:match("//0$")
end

--// slot -> { Button, Icon, Glyph, Caption, Stroke, Key, Info }
local skillTiles = {}

for order, entry in ipairs(SLOTS) do
	local button = Instance.new("TextButton")
	button.Name = entry.Slot .. "Tile"
	button.Text = ""
	button.AutoButtonColor = true
	button.Size = UDim2.fromScale(0.29, 1)
	button.BackgroundColor3 = Color3.new(1, 1, 1)
	button.LayoutOrder = order
	button.Parent = skillRow
	local stroke = stylize(button, 2.5)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0.07)
	icon.Size = UDim2.fromScale(0.6, 0.6)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = button
	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.AspectRatio = 1
	iconAspect.Parent = icon

	--// Emoji or a letter when there is no icon art yet
	local glyph = makeText(button, "Glyph", Enum.Font.FredokaOne, CHOC)
	glyph.AnchorPoint = Vector2.new(0.5, 0)
	glyph.Position = UDim2.fromScale(0.5, 0.09)
	glyph.Size = UDim2.fromScale(0.8, 0.54)

	local caption = makeText(button, "Caption", Enum.Font.FredokaOne, CHOC)
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.fromScale(0.5, 0.96)
	caption.Size = UDim2.fromScale(0.92, 0.24)

	--// The key you press, pinned to the corner like a keycap
	local badge = makeText(button, "KeyBadge", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
	badge.BackgroundTransparency = 0
	badge.BackgroundColor3 = CHOC
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.fromScale(0.1, 0.1)
	badge.Size = UDim2.fromScale(0.34, 0.34)
	badge.Text = entry.Key
	badge.ZIndex = 3
	local badgeAspect = Instance.new("UIAspectRatioConstraint")
	badgeAspect.AspectRatio = 1
	badgeAspect.Parent = badge
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge

	skillTiles[entry.Slot] = {
		Button = button, Icon = icon, Glyph = glyph, Caption = caption,
		Stroke = stroke, Key = entry.Key, Info = nil,
	}

	--// the tile art is tinted the slot colour; its drawn keycap holds the key
	if kit.skin(button, "SkillTile") then
		tintFollow(button)
		--// the art is square; a non-square tile letterboxed it and left the
		--// drawn keycap away from the key letter
		local tileAspect = Instance.new("UIAspectRatioConstraint")
		tileAspect.AspectRatio = 1
		tileAspect.Parent = button
		--// some icons (every class sticker on T, some skill icons) carry their
		--// own white sticker backing - filling the tile makes that backing a
		--// clean inner card instead of a small box in a box
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.84, 0.84)
		icon.ZIndex = 2
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.5)
		--// no name on the tile (owner call) - the skill card shows it on tap
		caption.Visible = false
		badge.BackgroundTransparency = 1
		badge.Position = UDim2.fromScale(0.19, 0.18)
		badge.Size = UDim2.fromScale(0.24, 0.24)
	end

	--// the padlock on a slot this class has not unlocked yet (level gate)
	local lock = kit.image(button, "PadlockClosed", "Lock")
	if lock then
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.78, 0.78)
		lock.Size = UDim2.fromScale(0.46, 0.46)
		lock.Rotation = 10
		lock.ZIndex = 5
		lock.Visible = false
		skillTiles[entry.Slot].Lock = lock
	end
end

----------------------------------------------------------------
-- THE SKILL CARD: dims the screen, one skill, big and readable
----------------------------------------------------------------

--// The dim is itself a button, so tapping anywhere outside the card closes it
local popup = Instance.new("TextButton")
popup.Name = "SkillPopup"
popup.Text = ""
popup.AutoButtonColor = false
popup.Size = UDim2.fromScale(1, 1)
popup.BackgroundColor3 = Color3.new(0, 0, 0)
popup.BackgroundTransparency = 1
popup.ZIndex = 50
popup.Visible = false
popup.Parent = root

local card = Instance.new("Frame")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 0.5)
card.Position = UDim2.fromScale(0.5, 0.5)
card.Size = UDim2.fromScale(0.32, 0.56)
card.BackgroundColor3 = CREAM
--// Active sinks the click, so tapping the card itself does not fall
--// through to the dim behind it and close the popup
card.Active = true
card.Parent = popup
stylize(card, 4)

local cardAspect = Instance.new("UIAspectRatioConstraint")
cardAspect.AspectRatio = 0.8
cardAspect.Parent = card

local cardScale = Instance.new("UIScale")
cardScale.Parent = card

local cardGrad = Instance.new("UIGradient")
cardGrad.Rotation = 90
--// A neutral shade, not the cream WARM: a gradient multiplies the colour
--// underneath, and cream would muddy the green, orange and blue cards.
cardGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(215, 215, 215))
cardGrad.Parent = card
if kit.skin(card, "SkillCard") then
	tintFollow(card) --// openSkillPopup paints it the slot colour
end

--// GothamBold, not FredokaOne: the chunky font crushed into a small chip
--// turned "ULTIMATE - PRESS T" into an unreadable blob.
local keyChip = makeText(card, "KeyChip", Enum.Font.GothamBold, Color3.new(1, 1, 1))
keyChip.BackgroundTransparency = 0
keyChip.BackgroundColor3 = CHOC
keyChip.AnchorPoint = Vector2.new(0.5, 0)
keyChip.Position = UDim2.fromScale(0.5, 0.045)
keyChip.Size = UDim2.fromScale(0.84, 0.095)
stylize(keyChip, 2)
local chipPad = Instance.new("UIPadding")
chipPad.PaddingLeft = UDim.new(0.06, 0)
chipPad.PaddingRight = UDim.new(0.06, 0)
chipPad.PaddingTop = UDim.new(0.18, 0)
chipPad.PaddingBottom = UDim.new(0.18, 0)
chipPad.Parent = keyChip

local bigArt = Instance.new("Frame")
bigArt.Name = "Art"
bigArt.AnchorPoint = Vector2.new(0.5, 0)
bigArt.Position = UDim2.fromScale(0.5, 0.17)
bigArt.Size = UDim2.fromScale(0.42, 0.42)
bigArt.BackgroundColor3 = Color3.new(1, 1, 1)
bigArt.Parent = card
local bigArtStroke = stylize(bigArt, 3)
local bigArtAspect = Instance.new("UIAspectRatioConstraint")
bigArtAspect.AspectRatio = 1
bigArtAspect.Parent = bigArt

local bigIcon = Instance.new("ImageLabel")
bigIcon.BackgroundTransparency = 1
bigIcon.AnchorPoint = Vector2.new(0.5, 0.5)
bigIcon.Position = UDim2.fromScale(0.5, 0.5)
bigIcon.Size = UDim2.fromScale(0.86, 0.86)
bigIcon.ScaleType = Enum.ScaleType.Fit
bigIcon.Parent = bigArt

local bigGlyph = makeText(bigArt, "Glyph", Enum.Font.FredokaOne, CHOC)
bigGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
bigGlyph.Position = UDim2.fromScale(0.5, 0.5)
bigGlyph.Size = UDim2.fromScale(0.8, 0.8)

local skillName = makeText(card, "SkillName", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
skillName.TextStrokeColor3 = CHOC
skillName.TextStrokeTransparency = 0.25
skillName.AnchorPoint = Vector2.new(0.5, 0)
skillName.Position = UDim2.fromScale(0.5, 0.62)
skillName.Size = UDim2.fromScale(0.88, 0.1)

local skillText = makeText(card, "SkillText", Enum.Font.GothamBold, Color3.new(1, 1, 1))
skillText.TextStrokeColor3 = CHOC
skillText.TextStrokeTransparency = 0.6
skillText.AnchorPoint = Vector2.new(0.5, 0)
skillText.Position = UDim2.fromScale(0.5, 0.73)
skillText.Size = UDim2.fromScale(0.84, 0.1)

local gotIt = Instance.new("TextButton")
gotIt.Name = "GotIt"
gotIt.AnchorPoint = Vector2.new(0.5, 1)
gotIt.Position = UDim2.fromScale(0.5, 0.955)
gotIt.Size = UDim2.fromScale(0.58, 0.095)
gotIt.BackgroundColor3 = Color3.new(1, 1, 1)
--// GothamBold for the same reason as the key chip: FredokaOne squeezed into
--// a small button runs its letters together.
gotIt.Font = Enum.Font.GothamBold
gotIt.TextScaled = true
gotIt.TextColor3 = Color3.new(1, 1, 1)
gotIt.TextStrokeTransparency = 1
gotIt.Text = "GOT IT!"
gotIt.Parent = card
stylize(gotIt, 2.5)
local gotItPad = Instance.new("UIPadding")
gotItPad.PaddingLeft = UDim.new(0.1, 0)
gotItPad.PaddingRight = UDim.new(0.1, 0)
gotItPad.PaddingTop = UDim.new(0.2, 0)
gotItPad.PaddingBottom = UDim.new(0.2, 0)
gotItPad.Parent = gotIt

local function closeSkillPopup()
	popup.Visible = false
end

local function openSkillPopup(info)
	if not info then return end
	local colors = SLOT_COLORS[info.Locked and "Locked" or info.Slot] or SLOT_COLORS.Locked

	card.BackgroundColor3 = colors.Main
	keyChip.BackgroundColor3 = colors.Dark
	keyChip.TextColor3 = Color3.new(1, 1, 1)
	gotIt.BackgroundColor3 = colors.Dark
	if info.Locked then
		keyChip.Text = ("KEY %s"):format(info.Key)
	elseif info.IsUltimate then
		keyChip.Text = ("ULTIMATE  -  PRESS %s"):format(info.Key)
	else
		keyChip.Text = ("PRESS %s"):format(info.Key)
	end

	local useImage = hasImage(info.IconId)
	bigIcon.Visible = useImage
	bigIcon.Image = useImage and info.IconId or ""
	bigGlyph.Visible = not useImage
	bigGlyph.Text = info.Emoji or info.Letter or "?"
	bigArtStroke.Color = colors.Dark

	skillName.Text = info.Name
	skillText.Text = info.Text

	--// Pop in: the dim fades, the card springs up from slightly small
	popup.BackgroundTransparency = 1
	cardScale.Scale = 0.85
	popup.Visible = true
	TweenService:Create(popup, TweenInfo.new(0.15), { BackgroundTransparency = 0.45 }):Play()
	TweenService:Create(cardScale,
		TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

--// Lift everything on the card above the dim explicitly, so it draws on top
--// whichever ZIndexBehavior this ScreenGui ends up with.
for _, item in ipairs(card:GetDescendants()) do
	if item:IsA("GuiObject") then
		item.ZIndex = 52
	end
end
card.ZIndex = 51

popup.Activated:Connect(closeSkillPopup)
gotIt.Activated:Connect(closeSkillPopup)

for _, tile in pairs(skillTiles) do
	tile.Button.Activated:Connect(function()
		openSkillPopup(tile.Info)
	end)
end

--// What one slot shows for this class. nil = the class has nothing there.
local function skillInfoFor(classKey, class, slot, key)
	local letter = string.upper(string.sub(classKey, 1, 1))

	if slot == "Ultimate" then
		if not class.UltimateName or class.UltimateName == "" then
			return nil
		end
		--// The ultimate wears the class sticker, same as the in-game button
		return {
			Slot = slot, Key = key, Name = class.UltimateName, Text = class.UltimateText or "",
			IconId = class.IconId, Letter = letter, IsUltimate = true,
		}
	end

	local def = class[slot]
	if not def then
		return nil
	end
	return {
		Slot = slot, Key = key, Name = def.Name or def.Id or slot, Text = def.Text or "",
		IconId = def.IconId, Emoji = def.Emoji, Letter = letter,
	}
end

--// Fills the three tiles for the selected class. A class with nothing at
--// all (the Trainee) hides the row; a class with only some skills (the
--// Charmer, for now) shows the missing ones as COMING SOON.
--// level / owned: the selected class's level and whether it is owned - a
--// slot above the level (or any slot of an unowned class) shows LOCKED
local function renderSkills(classKey, class, level, owned)
	local infos, any = {}, false
	for _, entry in ipairs(SLOTS) do
		infos[entry.Slot] = skillInfoFor(classKey, class, entry.Slot, entry.Key)
		any = any or infos[entry.Slot] ~= nil
	end

	skillRow.Visible = any
	if not any then
		return
	end

	for _, entry in ipairs(SLOTS) do
		local tile = skillTiles[entry.Slot]
		local info = infos[entry.Slot]

		local colors = SLOT_COLORS[info and entry.Slot or "Locked"]
		tile.Button.BackgroundColor3 = colors.Main
		tile.Stroke.Color = CHOC
		tile.Stroke.Thickness = 2.5
		tile.Caption.TextColor3 = Color3.new(1, 1, 1)
		tile.Caption.TextStrokeColor3 = CHOC
		tile.Caption.TextStrokeTransparency = 0.3

		if info then
			local useImage = hasImage(info.IconId)
			tile.Icon.Visible = useImage
			tile.Icon.Image = useImage and info.IconId or ""
			tile.Glyph.Visible = not useImage
			tile.Glyph.Text = info.Emoji or info.Letter or "?"
			tile.Glyph.TextColor3 = Color3.new(1, 1, 1)
			tile.Caption.Text = info.Name

			--// THE LEVEL GATE: Q at 1, R at 3, the ultimate at 5
			local need = Config.SkillUnlockLevel(entry.Slot)
			local locked = not owned or (level or 1) < need
			tile.Icon.ImageColor3 = locked and Color3.fromRGB(110, 104, 98) or Color3.new(1, 1, 1)
			if tile.Lock then tile.Lock.Visible = locked end
			if locked then
				tile.Button.BackgroundColor3 = SLOT_COLORS.Locked.Main
				local why = owned and ("Unlocks at class level %d."):format(need)
					or "Buy this class to unlock it!"
				local lockedInfo = table.clone(info)
				lockedInfo.Locked = true
				lockedInfo.Text = (info.Text ~= "" and (info.Text .. " ") or "") .. why
				tile.Info = lockedInfo
			else
				tile.Info = info
			end
		else
			if tile.Lock then tile.Lock.Visible = false end
			tile.Icon.Visible = false
			tile.Glyph.Visible = true
			tile.Glyph.Text = "?"
			tile.Glyph.TextColor3 = Color3.new(1, 1, 1)
			tile.Caption.Text = "SOON"
			tile.Info = {
				Slot = entry.Slot, Key = entry.Key, Name = "COMING SOON",
				Text = "This skill is still being cooked up!", Locked = true,
			}
		end
	end
end

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
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextStrokeColor3 = CHOC
	button.TextStrokeTransparency = 0.2
	button.Text = ""
	button.Parent = detail
	stylize(button, 2.5)
	return button
end

local actionBtn = makeButton("ActionButton")
local upgradeBtn = makeButton("UpgradeButton")
upgradeBtn.Visible = false
for _, button in ipairs({ actionBtn, upgradeBtn }) do
	if kit.skin(button, "PriceButtonGreen") then
		buttonFollow(button)
		textOnTop(button, nil, { W = 0.9, H = 0.56, Y = 0.44 })
	end
end

----------------------------------------------------------------
-- BOTTOM CENTRE: balance + CLOSE, reference-game style
----------------------------------------------------------------
local wallet = makeText(root, "Wallet", Enum.Font.FredokaOne, Color3.new(1, 1, 1))
wallet.AnchorPoint = Vector2.new(0.5, 1)
wallet.Position = UDim2.fromScale(0.5, 0.89)
wallet.Size = UDim2.fromScale(0.16, 0.055)
wallet.BackgroundTransparency = 0
wallet.BackgroundColor3 = MUSTARD
wallet.Text = "$ 0"
wallet.TextStrokeColor3 = CHOC
wallet.TextStrokeTransparency = 0
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

--// the wallet pill (its coin is drawn on the left end - the "$ " goes) and
--// the red CLOSE bar, each kept at its art's shape
local walletAnim = Instance.new("UIScale")
walletAnim.Parent = wallet
if kit.skin(wallet, "WalletPill") then
	local walletAspect = Instance.new("UIAspectRatioConstraint")
	walletAspect.AspectRatio = 4
	walletAspect.Parent = wallet
	textOnTop(wallet, function(text)
		return (text:gsub("^%$%s*", ""))
	end, { X = 0.6, W = 0.66, H = 0.66, Y = 0.47, Stroke = true })
end
if kit.skin(closeBtn, "CloseBar") then
	local closeAspect = Instance.new("UIAspectRatioConstraint")
	closeAspect.AspectRatio = 3
	closeAspect.Parent = closeBtn
	textOnTop(closeBtn, nil, { W = 0.76, H = 0.56, Y = 0.44, Stroke = true })
end

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
	--// on the art the ring only shows for the selected card
	card.Stroke.Transparency = (card.Skinned and not selected) and 1 or 0
	if card.Lock then
		card.Lock.Visible = not owned
	end

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

	dPassive.Text = ""
	renderSkills(classKey, class, (snapshot and snapshot.ClassLevels[classKey]) or 1, owned)
	if detailLock then
		detailLock.Visible = not owned
	end

	--// Level: bought with coins alone (owner, Oct 5 2026 - the task gate is
	--// gone; the PASSIVE section took its place)
	local track = class.UpgradeTrack
	local level = (snapshot and snapshot.ClassLevels[classKey]) or 1
	local upgradeCost = 0
	local progressShown = track ~= nil

	levelCaption.Visible = progressShown
	levelBack.Visible = progressShown

	if track then
		local maxLevel = #track.Steps + 1
		levelText.Text = ("Lv %d / %d"):format(level, maxLevel)
		levelFill.Size = UDim2.fromScale(math.clamp(level / maxLevel, 0, 1), 1)
		if level <= #track.Steps then
			upgradeCost = track.Costs[level]
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
			local ready = snapshot and snapshot.Wallet >= upgradeCost
			upgradeBtn.Text = ("UPGRADE · $%d"):format(upgradeCost)
			upgradeBtn.BackgroundColor3 = ready and GOLD or GREY
			upgradeBtn.TextColor3 = ready and Color3.new(1, 1, 1) or GREY_TEXT
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
		actionBtn.TextColor3 = short and GREY_TEXT or Color3.new(1, 1, 1)
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

--// THE UNLOCK (a class was just bought): a big padlock appears on the
--// showcase, the gold key slides into the keyhole and turns - click - the
--// shackle pops, the pieces fall away, a burst of sparkles and confetti,
--// and the class icon pops in. Purely cosmetic: it plays AFTER the server
--// already granted the class.
local function playUnlock()
	local bodyId, shackleId = kit.id("PadlockBody"), kit.id("PadlockShackle")
	local holder = showcaseHolder or dIcon.Parent
	if not (bodyId and shackleId and holder) then return end

	local box = Instance.new("Frame")
	box.Name = "Unlock"
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromScale(0.62, 0.62)
	box.BackgroundTransparency = 1
	box.ZIndex = 5
	box.Parent = holder
	local boxAspect = Instance.new("UIAspectRatioConstraint")
	boxAspect.AspectRatio = 1
	boxAspect.Parent = box
	local boxScale = Instance.new("UIScale")
	boxScale.Scale = 0.3
	boxScale.Parent = box

	local function piece(id, name, z)
		local img = Instance.new("ImageLabel")
		img.Name = name
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Fit
		img.Image = id
		img.Size = UDim2.fromScale(1, 1)
		img.ZIndex = z
		img.Parent = box
		return img
	end
	local shackle = piece(shackleId, "Shackle", 6)
	local body = piece(bodyId, "Body", 7)
	local keyId = kit.id("PadlockKey")
	local key = nil
	if keyId then
		--// 192x96 next to the lock's 128: the key is 1.5 locks wide. Its tip
		--// (right end) lines up with the keyhole at ~(0.48, 0.62) of the lock.
		key = piece(keyId, "Key", 8)
		key.Size = UDim2.fromScale(1.5, 0.75)
		key.Position = UDim2.fromScale(-2.6, 0.245)
		key.ImageTransparency = 1
	end

	local function tween(obj, seconds, props, style, dir)
		local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad,
			dir or Enum.EasingDirection.Out), props)
		t:Play()
		return t
	end

	task.spawn(function()
		tween(boxScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back).Completed:Wait()

		if key then
			--// the key slides in and seats in the keyhole...
			tween(key, 0.12, { ImageTransparency = 0 })
			tween(key, 0.35, { Position = UDim2.fromScale(-0.895, 0.245) }).Completed:Wait()
			--// ...and turns: squash to edge-on and back, like a quarter turn
			tween(key, 0.1, { Size = UDim2.fromScale(1.5, 0.18), Position = UDim2.fromScale(-0.895, 0.53) }).Completed:Wait()
			sfx("ShopClick")
			tween(key, 0.1, { Size = UDim2.fromScale(1.5, 0.75), Position = UDim2.fromScale(-0.895, 0.245) }).Completed:Wait()
		end

		--// the lock shudders...
		for i = 1, 4 do
			tween(box, 0.05, { Rotation = (i % 2 == 0) and -8 or 8 }).Completed:Wait()
		end
		tween(box, 0.05, { Rotation = 0 })

		--// ...and the shackle pops open
		tween(shackle, 0.25, { Position = UDim2.fromScale(0.06, -0.3), Rotation = 24 }, Enum.EasingStyle.Back)
		sfx("ShopPurchase")
		task.wait(0.18)

		--// the burst: pop star, sparkles flying out, confetti
		local burst = kit.image(holder, "PopBurst", "Burst")
		if burst then
			burst.AnchorPoint = Vector2.new(0.5, 0.5)
			burst.Position = UDim2.fromScale(0.5, 0.5)
			burst.Size = UDim2.fromScale(0.2, 0.2)
			burst.ZIndex = 4
			tween(burst, 0.5, { Size = UDim2.fromScale(1.7, 1.7), Rotation = 45, ImageTransparency = 1 })
			game:GetService("Debris"):AddItem(burst, 0.6)
		end
		for i = 1, 8 do
			local sparkle = kit.image(holder, "Sparkle", "Spark")
			if sparkle then
				local angle = (i / 8) * math.pi * 2
				sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
				sparkle.Position = UDim2.fromScale(0.5, 0.5)
				sparkle.Size = UDim2.fromScale(0.2, 0.2)
				sparkle.ZIndex = 9
				tween(sparkle, 0.6, {
					Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.85, 0.5 + math.sin(angle) * 0.85),
					Size = UDim2.fromScale(0.06, 0.06),
					ImageTransparency = 1,
				})
				game:GetService("Debris"):AddItem(sparkle, 0.7)
			end
		end
		local confettiId = kit.id("Confetti")
		if confettiId then
			local at = holder.AbsolutePosition + holder.AbsoluteSize / 2
			local confetti = Instance.new("ImageLabel")
			confetti.BackgroundTransparency = 1
			confetti.Image = confettiId
			confetti.ScaleType = Enum.ScaleType.Fit
			confetti.AnchorPoint = Vector2.new(0.5, 0.5)
			confetti.Position = UDim2.fromOffset(at.X, at.Y)
			confetti.Size = UDim2.fromOffset(60, 60)
			confetti.ZIndex = 60
			confetti.Parent = gui
			tween(confetti, 1, { Size = UDim2.fromOffset(380, 380), Rotation = 90, ImageTransparency = 1 })
			game:GetService("Debris"):AddItem(confetti, 1.1)
		end

		--// the pieces tumble away, the class icon pops in
		local fall = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		for _, img in ipairs({ body, shackle, key }) do
			if img then
				TweenService:Create(img, fall, {
					Position = img.Position + UDim2.fromScale(0, 0.8),
					Rotation = img.Rotation + 30,
					ImageTransparency = 1,
				}):Play()
			end
		end
		dIconScale.Scale = 0.5
		tween(dIconScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		task.wait(0.6)
		box:Destroy()
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
	frame.Size = UDim2.fromScale(1, 0.15)
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

	local iconBoxAspect = Instance.new("UIAspectRatioConstraint")
	iconBoxAspect.AspectRatio = 1
	iconBoxAspect.Parent = iconBox

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
	name.TextStrokeTransparency = 0
	--// Card titles drop the "The " - "Chef", not "The Chef" (owner call);
	--// the detail header keeps the full display name
	name.Text = (class.Display:gsub("^The ", ""))

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

	--// ART: the card is tinted its rarity colour; the icon sits in the card's
	--// drawn slot (laid out off the card's height, which the slice scales by)
	local skinned = kit.skin(frame, "ClassCard")
	local lock = nil
	if skinned then
		tintFollow(frame)
		kit.skin(iconBox, "IconFrame")
		if kit.skin(chip, "StateChip") then
			textOnTop(chip, nil, { W = 0.88, H = 0.64, Y = 0.47 })
		end
		local function layout()
			local h = frame.AbsoluteSize.Y
			if h <= 0 then return end
			local s = h / 160 --// the art's native height
			iconBox.AnchorPoint = Vector2.new(0, 0)
			iconBox.Position = UDim2.fromOffset(31 * s, 21 * s)
			iconBox.Size = UDim2.fromOffset(101 * s, 101 * s)
			name.Position = UDim2.new(0, 150 * s, 0.3, 0)
			name.Size = UDim2.new(1, -190 * s, 0.36, 0)
			chip.Position = UDim2.new(0, 150 * s, 0.72, 0)
			chip.Size = UDim2.new(1, -205 * s, 0.28, 0)
		end
		frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		layout()

		--// the selection ring (the art replaced the old stroke)
		local ring = Instance.new("Frame")
		ring.Name = "SelectRing"
		ring.Size = UDim2.fromScale(1, 1)
		ring.BackgroundTransparency = 1
		ring.ZIndex = 5
		ring.Parent = frame
		local ringCorner = Instance.new("UICorner")
		ringCorner.CornerRadius = UDim.new(0.3, 0)
		ringCorner.Parent = ring
		cardStroke = Instance.new("UIStroke")
		cardStroke.Thickness = 3
		cardStroke.Color = Color3.new(1, 1, 1)
		cardStroke.Parent = ring

		--// the padlock on a class you don't own yet
		lock = kit.image(iconBox, "PadlockClosed", "Lock")
		if lock then
			lock.AnchorPoint = Vector2.new(0.5, 0.5)
			lock.Position = UDim2.fromScale(0.8, 0.8)
			lock.Size = UDim2.fromScale(0.56, 0.56)
			lock.Rotation = 10
			lock.ZIndex = 3
		end
	end

	--// hover lift
	local lift = Instance.new("UIScale")
	lift.Parent = frame
	frame.MouseEnter:Connect(function()
		TweenService:Create(lift, TweenInfo.new(0.12), { Scale = 1.03 }):Play()
	end)
	frame.MouseLeave:Connect(function()
		TweenService:Create(lift, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)

	frame.Activated:Connect(function()
		if selectedKey ~= classKey then
			sfx("ShopClick")
			dIconScale.Scale = 0.7
			TweenService:Create(dIconScale, TweenInfo.new(0.3, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		selectedKey = classKey
		renderAll()
	end)

	cardsByKey[classKey] = {
		Frame = frame, Stroke = cardStroke, Chip = chip,
		Icon = icon, Initial = initial, IconBox = iconBox,
		Skinned = skinned, Lock = lock,
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
	if not open then
		closeSkillPopup()
	end

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
			if celebrateKey == selectedKey then
				playUnlock() --// the padlock opens on the showcase
			end
			walletAnim.Scale = 1.2 --// the wallet thumps as the coins leave
			TweenService:Create(walletAnim, TweenInfo.new(0.3, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Scale = 1 }):Play()
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
