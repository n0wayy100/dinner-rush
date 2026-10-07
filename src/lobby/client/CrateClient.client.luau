--[[
	Dinner Rush - CrateClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.CrateClient  (LocalScript)

	THE PASSIVE CRATE screen (Oct 2026) - a FULL-SCREEN takeover (owner
	reference: a "style spin" screen). Opens from a Studio dock button named
	OpenCratesButton if one exists, otherwise the code-built CRATES sticker.

	  TOP CENTRE    "CURRENT PASSIVE:" + the selected passive's name, rarity
	                and what it does
	  CENTRE        the hero: that passive's rarity card on spinning rays
	  LEFT          your passives (owned first), each with EQUIP; BACK below
	  RIGHT         the odds, one bar per rarity (always on screen - paid
	                random items must show them BEFORE opening); tap a bar to
	                see the passives inside; the two pity bars; the SKIP
	                ANIMATION toggle; your coins
	  BOTTOM        the crate + OPEN <price> + crates opened

	RENDER ONLY. "Open" asks CrateServer, which pays, rolls and saves; this
	script plays the opening for the result it was handed:
	  drop + shake (the glow teases the rarity) -> the bow flies, the lid
	  blasts off (poof + shockwave + screen shake) -> a light pillar -> the
	  card rises and flips -> rays, sparkles, twinkles; Epic adds a swirl and
	  a shine sweep, Legendary adds fireworks, confetti and a lobby shout.
	  SKIP ANIMATION jumps straight to the flip.

	Art: Config.Passives.Art (+ the shop's coin, price button and pattern).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(Shared:WaitForChild("UIKit"))
local P = Config.Passives
if not P or not P.Art then return end

local SfxLocal = nil
pcall(function()
	SfxLocal = require(Shared:WaitForChild("SfxLocal", 5))
end)

local C = UIKit.Colors
local kit = UIKit.artKit(P.Art, Config.Monetization and Config.Monetization.ShopArt)
local corner, stroke, label, stickerText, aspect = UIKit.corner, UIKit.stroke,
	UIKit.label, UIKit.stickerText, UIKit.aspect

local NIGHT = Color3.fromRGB(34, 24, 18)        --// the takeover's backdrop
local NIGHT_DEEP = Color3.fromRGB(18, 12, 9)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
local crateRemote = remotes and remotes:WaitForChild("CrateRemote", 30)
local shoutRemote = remotes and remotes:WaitForChild("CrateShout", 30)
if not crateRemote then
	warn("[Crates] CrateRemote missing - is CrateServer synced?")
	return
end

local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary" }
local function rarityColor(rarity)
	local info = P.Rarities[rarity]
	return info and info.Color or C.Cream
end

local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then
		pcall(SfxLocal.Play, name)
	end
end

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

--// a plain centred sprite from the art kit (Fit), always an ImageLabel
local function sprite(parent, slot, name)
	local image = Instance.new("ImageLabel")
	image.Name = name or slot
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Image = kit.id(slot) or ""
	image.Parent = parent
	return image
end

--// plays a 4-column flipbook of 256px cells, then removes the sprite
local function playSheet(image, frames, fps)
	image.ImageRectSize = Vector2.new(256, 256)
	task.spawn(function()
		for i = 0, frames - 1 do
			if not image.Parent then return end
			image.ImageRectOffset = Vector2.new((i % 4) * 256, math.floor(i / 4) * 256)
			task.wait(1 / fps)
		end
		image:Destroy()
	end)
end

local function spinForever(image, degreesPerSecond)
	task.spawn(function()
		while image.Parent do
			image.Rotation = (image.Rotation + degreesPerSecond * RunService.RenderStepped:Wait()) % 360
		end
	end)
end

local function walletValue()
	local stats = player:FindFirstChild("leaderstats")
	return stats and stats:FindFirstChild("Wallet")
end

local BLUE = Color3.fromRGB(74, 144, 226)

--// which button art goes with which colour (Prompt 6 buttons)
local function buttonSlot(color)
	if color == C.Basil then return "Button_Green" end
	if color == C.Tomato then return "Button_Red" end
	if color == BLUE then return "Button_Blue" end
	return nil
end

--// a chunky sticker button: the uploaded button art when there is one for
--// its colour, else colour + chocolate outline; white letters on top
local function stickerButton(parent, name, text, color)
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = color
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent
	corner(button, UDim.new(0.25, 0))
	stroke(button, 3.5, C.Choc)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 205))
	grad.Parent = button
	local slot = buttonSlot(color)
	if slot then kit.skin(button, slot) end
	local t = label(button, "Text")
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.fromScale(0.5, 0.46) --// a touch high: the art has a bottom lip
	t.Size = UDim2.fromScale(0.86, 0.58)
	t.Text = text
	t.ZIndex = 3
	stickerText(t)
	UIKit.bouncy(button)
	return button, t
end

--// recolour a button: swap its art if it has some, else its fill
local function setButtonColor(button, color)
	local art = button:FindFirstChild("Art")
	local slot = buttonSlot(color)
	if art and slot then
		art.Image = kit.id(slot) or art.Image
	else
		button.BackgroundColor3 = color
	end
end

----------------------------------------------------------------
-- State (mirrors the server; refreshed after every action)
----------------------------------------------------------------
local state = {
	Price = P.CratePrice, Wallet = 0, Owned = {}, Equipped = "",
	PityEpic = 0, PityLegendary = 0, Opened = 0, Restricted = false,
}
local selectedKey = nil
local busy = false
local isOpen = false


----------------------------------------------------------------
-- The takeover
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Crates_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 36
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local screen = Instance.new("Frame") --// plain Frame: ScrollingFrames do not draw inside a CanvasGroup
screen.Name = "Screen"
screen.Size = UDim2.fromScale(1, 1)
screen.BackgroundTransparency = 1
screen.Parent = gui
local screenScale = Instance.new("UIScale")
screenScale.Parent = screen
do
	--// the backdrop is its OWN frame: a UIGradient parented straight to a
	--// Frame tints everything inside it (it went near-black)
	local back = Instance.new("Frame")
	back.Name = "Backdrop"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.new(1, 1, 1)
	back.Parent = screen
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(NIGHT, NIGHT_DEEP)
	grad.Parent = back
	--// the storeroom illustration, dimmed a little so the menus pop
	local backgroundId = kit.id("Crates_Background")
	if backgroundId then
		local art = Instance.new("ImageLabel")
		art.Name = "Storeroom"
		art.BackgroundTransparency = 1
		art.Size = UDim2.fromScale(1, 1)
		art.Image = backgroundId
		art.ScaleType = Enum.ScaleType.Crop
		art.ImageColor3 = Color3.fromRGB(185, 175, 165)
		art.Parent = screen
	end
	--// the quiet food-doodle tile from the shop, barely there (no storeroom)
	local patternId = not backgroundId and kit.id("PanelPattern")
	if patternId then
		local pattern = Instance.new("ImageLabel")
		pattern.Name = "Pattern"
		pattern.BackgroundTransparency = 1
		pattern.Size = UDim2.fromScale(1, 1)
		pattern.Image = patternId
		pattern.ScaleType = Enum.ScaleType.Tile
		pattern.TileSize = UDim2.fromOffset(220, 220)
		pattern.ImageTransparency = 0.93
		pattern.Parent = screen
	end
	local vignette = sprite(screen, "FX_Vignette")
	vignette.ScaleType = Enum.ScaleType.Stretch
	vignette.Position = UDim2.fromScale(0.5, 0.5)
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.ImageTransparency = 0.2

	--// the two wood boards the side columns sit on
	for _, spec in ipairs({
		{ Name = "LeftBoard", X = 0.01, Y = 0.055, W = 0.225, H = 0.79 },
		{ Name = "RightBoard", X = 0.725, Y = 0.03, W = 0.265, H = 0.735 },
	}) do
		local board = Instance.new("Frame")
		board.Name = spec.Name
		board.BackgroundTransparency = 1
		board.Position = UDim2.fromScale(spec.X, spec.Y)
		board.Size = UDim2.fromScale(spec.W, spec.H)
		board.Parent = screen
		kit.skin(board, "Side_Panel")
	end
end

--// a small notice line (errors, "equipped!")
local notice = label(screen, "Notice", nil, C.Tomato, 28)
notice.AnchorPoint = Vector2.new(0.5, 0.5)
notice.Position = UDim2.fromScale(0.5, 0.805)
notice.Size = UDim2.fromScale(0.4, 0.04)
notice.TextStrokeColor3 = C.Choc
notice.TextStrokeTransparency = 0
notice.ZIndex = 20
local noticeToken = 0
local function flashNotice(text, color)
	noticeToken += 1
	local mine = noticeToken
	notice.Text = text
	notice.TextColor3 = color or C.Tomato
	notice.TextTransparency = 0
	notice.TextStrokeTransparency = 0
	task.delay(2.5, function()
		if noticeToken == mine then
			tween(notice, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
	end)
end

--// the spotlight falls from the top onto the hero (drawn first = behind)
local heroSpot = sprite(screen, "Spotlight_Cone")
heroSpot.ScaleType = Enum.ScaleType.Stretch
heroSpot.AnchorPoint = Vector2.new(0.5, 0)
heroSpot.Position = UDim2.fromScale(0.5, 0)
heroSpot.Size = UDim2.fromScale(0.34, 0.8)
heroSpot.ImageTransparency = 0.55

----------------------------------------------------------------
-- TOP CENTRE: the selected passive in words
----------------------------------------------------------------
local heading = label(screen, "Heading", nil, C.White, 30)
heading.AnchorPoint = Vector2.new(0.5, 0)
heading.Position = UDim2.fromScale(0.5, 0.03)
heading.Size = UDim2.fromScale(0.3, 0.035)
stickerText(heading)

local plaque = sprite(screen, "Name_Plaque")
plaque.Position = UDim2.fromScale(0.5, 0.125)
plaque.Size = UDim2.fromScale(0.46, 0.115)

local heroName = label(screen, "HeroName", nil, C.White, 80)
heroName.AnchorPoint = Vector2.new(0.5, 0)
heroName.Position = UDim2.fromScale(0.5, 0.09)
heroName.Size = UDim2.fromScale(0.34, 0.07)
heroName.ZIndex = 2
stickerText(heroName)

local heroRarity = label(screen, "HeroRarity", nil, C.White, 30)
heroRarity.AnchorPoint = Vector2.new(0.5, 0)
heroRarity.Position = UDim2.fromScale(0.5, 0.19)
heroRarity.Size = UDim2.fromScale(0.2, 0.035)
heroRarity.TextStrokeColor3 = C.Choc
heroRarity.TextStrokeTransparency = 0

local heroDesc = label(screen, "HeroDesc", Enum.Font.GothamBold, C.White, 26)
heroDesc.AnchorPoint = Vector2.new(0.5, 0)
heroDesc.Position = UDim2.fromScale(0.5, 0.228)
heroDesc.Size = UDim2.fromScale(0.36, 0.06)
heroDesc.TextStrokeColor3 = C.Choc
heroDesc.TextStrokeTransparency = 0.3

----------------------------------------------------------------
-- CENTRE: the hero card on spinning light
----------------------------------------------------------------
local hero = Instance.new("Frame")
hero.Name = "Hero"
hero.BackgroundTransparency = 1
hero.AnchorPoint = Vector2.new(0.5, 0.5)
hero.Position = UDim2.fromScale(0.5, 0.52)
hero.Size = UDim2.fromScale(0.44, 0.44)
hero.Parent = screen
aspect(hero, 1)

local heroSwirl = sprite(hero, "FX_Swirl")
heroSwirl.Position = UDim2.fromScale(0.5, 0.5)
heroSwirl.Size = UDim2.fromScale(1.45, 1.45)
heroSwirl.ImageTransparency = 0.75
local heroRays = sprite(hero, "Burst_Rays")
heroRays.Position = UDim2.fromScale(0.5, 0.5)
heroRays.Size = UDim2.fromScale(1.35, 1.35)
heroRays.ImageTransparency = 0.35
local heroGlow = sprite(hero, "Glow_Orb")
heroGlow.Position = UDim2.fromScale(0.5, 0.5)
heroGlow.Size = UDim2.fromScale(1, 1)
heroGlow.ImageTransparency = 0.3
local heroSparkles = sprite(hero, "Burst_Sparkles")
heroSparkles.Position = UDim2.fromScale(0.5, 0.5)
heroSparkles.Size = UDim2.fromScale(1.15, 1.15)
heroSparkles.ImageTransparency = 0.2

local heroPedestal = sprite(hero, "Hero_Pedestal")
heroPedestal.Position = UDim2.fromScale(0.5, 0.86)
heroPedestal.Size = UDim2.fromScale(0.9, 0.45)
heroPedestal.ZIndex = 3

local HERO_W, HERO_H = 0.58, 0.58 * 880 / 640
local heroCard = Instance.new("ImageLabel")
heroCard.Name = "Card"
heroCard.BackgroundTransparency = 1
heroCard.AnchorPoint = Vector2.new(0.5, 0.5)
heroCard.Position = UDim2.fromScale(0.5, 0.44)
heroCard.Size = UDim2.fromScale(HERO_W, HERO_H)
heroCard.ScaleType = Enum.ScaleType.Stretch
heroCard.ZIndex = 4
heroCard.Parent = hero
local heroIcon = Instance.new("ImageLabel")
heroIcon.BackgroundTransparency = 1
heroIcon.AnchorPoint = Vector2.new(0.5, 0.5)
heroIcon.Position = UDim2.fromScale(0.5, 0.41)
heroIcon.Size = UDim2.fromScale(0.72, 0.5)
heroIcon.ScaleType = Enum.ScaleType.Fit
heroIcon.ZIndex = 5
heroIcon.Parent = heroCard
local heroCardName = label(heroCard, "Name", nil, C.Choc)
heroCardName.AnchorPoint = Vector2.new(0.5, 0.5)
heroCardName.Position = UDim2.fromScale(0.5, 0.87)
heroCardName.Size = UDim2.fromScale(0.8, 0.12)
heroCardName.ZIndex = 5
local heroShine = sprite(heroCard, "Shine_Sweep")
heroShine.Size = UDim2.fromScale(0.6, 1.4)
heroShine.Position = UDim2.fromScale(-0.5, 0.5)
heroShine.ImageTransparency = 0.25
heroShine.ZIndex = 6
heroCard.ClipsDescendants = true
--// no passive at all yet: the crate sits on the stage instead
local heroCrate = sprite(hero, "Crate_Closed")
heroCrate.Position = UDim2.fromScale(0.5, 0.52)
heroCrate.Size = UDim2.fromScale(0.8, 0.8)
heroCrate.ZIndex = 4

local heroEquip = stickerButton(screen, "HeroEquip", "EQUIP", C.Basil)
heroEquip.AnchorPoint = Vector2.new(0.5, 0.5)
heroEquip.Position = UDim2.fromScale(0.5, 0.745)
heroEquip.Size = UDim2.fromScale(0.13, 0.055)

----------------------------------------------------------------
-- BOTTOM: the crate, OPEN, crates opened
----------------------------------------------------------------
local openButton, openText = stickerButton(screen, "OpenButton", "", C.Basil)
openButton.AnchorPoint = Vector2.new(0.5, 1)
openButton.Position = UDim2.fromScale(0.5, 0.93)
openButton.Size = UDim2.fromScale(0.22, 0.1)
openText.Size = UDim2.fromScale(0.56, 0.62)
openText.Position = UDim2.fromScale(0.38, 0.5)
openText.Text = "OPEN"
local openCoin = sprite(openButton, "FlyingCoin")
openCoin.Position = UDim2.fromScale(0.7, 0.5)
openCoin.Size = UDim2.fromScale(0.14, 0.62)
openCoin.ZIndex = 3
local priceText = label(openButton, "Price")
priceText.AnchorPoint = Vector2.new(0, 0.5)
priceText.Position = UDim2.fromScale(0.77, 0.5)
priceText.Size = UDim2.fromScale(0.2, 0.55)
priceText.TextXAlignment = Enum.TextXAlignment.Left
priceText.Text = tostring(P.CratePrice)
priceText.ZIndex = 3
stickerText(priceText)

local sideCrate = sprite(screen, "Crate_Closed")
sideCrate.Position = UDim2.fromScale(0.355, 0.875)
sideCrate.Size = UDim2.fromScale(0.09, 0.11)

local openedLine = label(screen, "Opened", nil, C.White, 26)
openedLine.AnchorPoint = Vector2.new(0.5, 0)
openedLine.Position = UDim2.fromScale(0.5, 0.94)
openedLine.Size = UDim2.fromScale(0.25, 0.035)
stickerText(openedLine)

local restrictedLine = label(screen, "Restricted", nil, C.White, 28)
restrictedLine.AnchorPoint = Vector2.new(0.5, 1)
restrictedLine.Position = UDim2.fromScale(0.5, 0.93)
restrictedLine.Size = UDim2.fromScale(0.4, 0.08)
restrictedLine.Text = "Crates are not available for your account. Your passives still work!"
restrictedLine.Visible = false
stickerText(restrictedLine)

----------------------------------------------------------------
-- LEFT: your passives + BACK
----------------------------------------------------------------
local listTitle = label(screen, "ListTitle", nil, C.White, 30)
listTitle.Position = UDim2.fromScale(0.02, 0.07)
listTitle.Size = UDim2.fromScale(0.2, 0.04)
listTitle.TextXAlignment = Enum.TextXAlignment.Left
stickerText(listTitle)

local list = Instance.new("ScrollingFrame")
list.Name = "List"
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.Position = UDim2.fromScale(0.02, 0.12)
list.Size = UDim2.fromScale(0.2, 0.7)
list.ScrollBarThickness = 6
list.ScrollBarImageColor3 = C.Mustard
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.ScrollingDirection = Enum.ScrollingDirection.Y
list.Parent = screen
local renderListLater = nil --// set once renderList exists
--// rows are sized in pixels, so rebuild them when the list changes width
local lastListWidth = 0
list:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local width = list.AbsoluteSize.X
	if math.abs(width - lastListWidth) > 4 and renderListLater then
		lastListWidth = width
		renderListLater()
	end
end)
local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 8)
listLayout.Parent = list
do
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = list
end

local backButton = stickerButton(screen, "BackButton", "BACK", C.Tomato)
backButton.AnchorPoint = Vector2.new(0, 1)
backButton.Position = UDim2.fromScale(0.02, 0.95)
backButton.Size = UDim2.fromScale(0.13, 0.08)

----------------------------------------------------------------
-- RIGHT: odds bars, the inside list, pity, skip, coins
----------------------------------------------------------------
local oddsHeader = label(screen, "OddsHeader", nil, C.White, 26)
oddsHeader.AnchorPoint = Vector2.new(1, 0)
oddsHeader.Position = UDim2.fromScale(0.975, 0.05)
oddsHeader.Size = UDim2.fromScale(0.245, 0.035)
oddsHeader.Text = "Tap a rarity to see what's inside!"
stickerText(oddsHeader)

local insideBox = Instance.new("Frame")
insideBox.Name = "Inside"
insideBox.AnchorPoint = Vector2.new(1, 0)
insideBox.Position = UDim2.fromScale(0.975, 0.445) --// a popup over the pity bars
insideBox.Size = UDim2.fromScale(0.245, 0.27)
insideBox.BackgroundColor3 = NIGHT_DEEP
insideBox.BackgroundTransparency = 0.04
insideBox.ZIndex = 10
insideBox.Visible = false
insideBox.Parent = screen
corner(insideBox, UDim.new(0, 12))
local insideStroke = stroke(insideBox, 3, C.Mustard)
local insideText = label(insideBox, "Text", Enum.Font.GothamBold, C.White, 22)
insideText.AnchorPoint = Vector2.new(0.5, 0.5)
insideText.Position = UDim2.fromScale(0.5, 0.5)
insideText.Size = UDim2.fromScale(0.92, 0.84)

local openRarity = nil
for index, rarity in ipairs(RARITY_ORDER) do
	local keys = {}
	for _, key in ipairs(P.Order) do
		if P.List[key] and P.List[key].Rarity == rarity then
			table.insert(keys, P.List[key].Display)
		end
	end
	local weight = P.Rarities[rarity].Weight
	local color = rarityColor(rarity)

	local row = Instance.new("TextButton")
	row.Name = "Odds" .. rarity
	row.AnchorPoint = Vector2.new(1, 0)
	row.Position = UDim2.fromScale(0.975, 0.095 + (index - 1) * 0.085)
	row.Size = UDim2.fromScale(0.245, 0.07)
	row.BackgroundColor3 = color
	row.AutoButtonColor = false
	row.Text = ""
	row.Parent = screen
	corner(row, UDim.new(0.2, 0))
	stroke(row, 3.5, C.Choc)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170))
	grad.Parent = row
	--// the glossy plate art, tinted to the rarity
	if kit.skin(row, "Odds_BarPlate") then
		row.Art.ImageColor3 = color
	end
	UIKit.bouncy(row)

	local gem = sprite(row, "Gem_" .. rarity)
	gem.Position = UDim2.fromScale(0.09, 0.5)
	gem.Size = UDim2.fromScale(0.14, 0.82)
	gem.ZIndex = 3
	local text = label(row, "Text")
	text.AnchorPoint = Vector2.new(0, 0.5)
	text.Position = UDim2.fromScale(0.18, 0.5)
	text.Size = UDim2.fromScale(0.66, 0.56)
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Text = ("%s  [%s%%]"):format(string.upper(rarity), tostring(weight))
	text.ZIndex = 3
	stickerText(text)
	local arrow = label(row, "Arrow")
	arrow.AnchorPoint = Vector2.new(1, 0.5)
	arrow.Position = UDim2.fromScale(0.96, 0.5)
	arrow.Size = UDim2.fromScale(0.1, 0.5)
	arrow.Text = "<"
	arrow.ZIndex = 3
	stickerText(arrow)

	row.Activated:Connect(function()
		sfx("ShopClick")
		if openRarity == rarity then
			openRarity = nil
			insideBox.Visible = false
			return
		end
		openRarity = rarity
		insideStroke.Color = color
		insideText.Text = ("%s:\n%s"):format(string.upper(rarity), table.concat(keys, ", "))
		insideBox.Visible = true
	end)
end


--// pity bars
local function pityBar(order, captionText, gemSlot, fillColor)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(1, 0)
	--// bigger and spaced out, still inside the right board (ends ~0.765)
	row.Position = UDim2.fromScale(0.97, 0.46 + (order - 1) * 0.145)
	row.Size = UDim2.fromScale(0.235, 0.105)
	row.Parent = screen

	local gem = sprite(row, gemSlot)
	gem.Position = UDim2.fromScale(0.065, 0.68)
	gem.Size = UDim2.fromScale(0.13, 0.62)

	local caption = label(row, "Caption", nil, C.White, 26)
	caption.Position = UDim2.fromScale(0.07, 0)
	caption.Size = UDim2.fromScale(0.91, 0.38)
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.Text = captionText
	stickerText(caption)
	caption.TextColor3 = fillColor --// purple for Epic, gold for Legendary

	local frame = Instance.new("Frame")
	frame.Name = "Bar"
	frame.BackgroundColor3 = C.Choc
	frame.Position = UDim2.fromScale(0.15, 0.45)
	frame.Size = UDim2.fromScale(0.85, 0.48)
	frame.Parent = row
	corner(frame, UDim.new(1, 0))
	local frameArt = sprite(frame, "Pity_BarFrame")
	frameArt.ScaleType = Enum.ScaleType.Stretch
	frameArt.AnchorPoint = Vector2.new(0, 0)
	frameArt.Size = UDim2.fromScale(1, 1)
	frameArt.ZIndex = 3
	if frameArt.Image ~= "" then frame.BackgroundTransparency = 1 end

	--// THE FILL: code-drawn so it sits dead-centre in the track (the fill
	--// image's own padding left it off-centre) and takes this bar's rarity
	--// colour - purple for Epic, gold for Legendary. Above the frame art.
	local TRACK_X, TRACK_W, TRACK_H = 0.035, 0.93, 0.44
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(TRACK_X, 0.5)
	fill.Size = UDim2.fromScale(0, TRACK_H)
	fill.BackgroundColor3 = fillColor
	fill.ZIndex = 4
	fill.Parent = frame
	corner(fill, UDim.new(1, 0))
	local fillGrad = Instance.new("UIGradient")
	fillGrad.Rotation = 90
	fillGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190))
	fillGrad.Parent = fill
	local shineStripe = Instance.new("Frame")
	shineStripe.AnchorPoint = Vector2.new(0.5, 0)
	shineStripe.Position = UDim2.fromScale(0.5, 0.14)
	shineStripe.Size = UDim2.new(1, -8, 0.24, 0)
	shineStripe.BackgroundColor3 = Color3.new(1, 1, 1)
	shineStripe.BackgroundTransparency = 0.45
	shineStripe.ZIndex = 5
	shineStripe.Parent = fill
	corner(shineStripe, UDim.new(1, 0))

	local count = label(row, "Count", nil, C.White, 22)
	count.AnchorPoint = Vector2.new(0.5, 0.5)
	count.Position = UDim2.fromScale(0.575, 0.69)
	count.Size = UDim2.fromScale(0.55, 0.3)
	count.ZIndex = 4
	stickerText(count)

	return function(progress, remaining)
		local width = TRACK_W * math.clamp(progress, 0, 1)
		--// never thinner than a rounded nub once there is any progress
		if progress > 0 then width = math.max(width, 0.06) end
		fill.Visible = progress > 0
		tween(fill, 0.4, { Size = UDim2.fromScale(width, TRACK_H) })
		count.Text = remaining <= 1 and "NEXT ONE!" or ("%d more"):format(remaining)
	end
end
local setEpicBar = pityBar(1, "EPIC OR BETTER GUARANTEED", "Gem_Epic", rarityColor("Epic"))
local setLegendaryBar = pityBar(2, "LEGENDARY GUARANTEED", "Gem_Legendary", rarityColor("Legendary"))


local coinPill = Instance.new("Frame")
coinPill.Name = "Coins"
coinPill.AnchorPoint = Vector2.new(1, 1)
coinPill.Position = UDim2.fromScale(0.975, 0.95)
coinPill.Size = UDim2.fromScale(0.2, 0.07)
coinPill.BackgroundColor3 = C.Basil
coinPill.Parent = screen
corner(coinPill, UDim.new(0.3, 0))
stroke(coinPill, 3.5, C.Choc)
kit.skin(coinPill, "Coin_Pill")
local coinIcon = sprite(coinPill, "FlyingCoin")
coinIcon.Position = UDim2.fromScale(0.12, 0.5)
coinIcon.Size = UDim2.fromScale(0.18, 0.75)
local coinText = label(coinPill, "Text")
coinText.AnchorPoint = Vector2.new(1, 0.5)
coinText.Position = UDim2.fromScale(0.93, 0.5)
coinText.Size = UDim2.fromScale(0.7, 0.6)
coinText.TextXAlignment = Enum.TextXAlignment.Right
stickerText(coinText)

----------------------------------------------------------------
-- Rendering
----------------------------------------------------------------
local function coins()
	local wallet = walletValue()
	return wallet and wallet.Value or state.Wallet or 0
end

--// THE CENTRE IS THE CRATE'S (owner spec): it always shows the crate on
--// the pedestal; passives are read from the list's (i) instead. The top
--// line names what you have equipped.
local function renderHero()
	local equippedPassive = state.Equipped ~= "" and P.List[state.Equipped]
	heading.Text = (state.Opened or 0) > 0 and "OPEN A CRATE!" or "OPEN YOUR FIRST CRATE!"
	heroName.Text = "Passive Crates"
	if equippedPassive then
		heroRarity.Text = "EQUIPPED: " .. string.upper(equippedPassive.Display)
		heroRarity.TextColor3 = rarityColor(equippedPassive.Rarity)
		heroRarity.Size = UDim2.fromScale(0.34, 0.035)
	else
		heroRarity.Text = ""
	end
	heroDesc.Text = "Every crate holds one passive. Tap the i on a passive to read it."
	heroCard.Visible = false
	heroCrate.Visible = true
	heroEquip.Visible = false
	heroSwirl.Visible = false
	for _, fx in ipairs({ heroRays, heroGlow, heroSparkles, heroSwirl, heroSpot }) do
		fx.ImageColor3 = C.Mustard
	end
end

----------------------------------------------------------------
-- THE READ-IT CARD (owner spec): tap a passive's (i) in the list and its
-- card pops out beside the list - never in the crate's space. Tap anywhere
-- else (or the X) to put it away.
----------------------------------------------------------------
local infoCatcher = Instance.new("TextButton")
infoCatcher.Name = "InfoCatcher"
infoCatcher.Size = UDim2.fromScale(1, 1)
infoCatcher.BackgroundTransparency = 1
infoCatcher.Text = ""
infoCatcher.Visible = false
infoCatcher.ZIndex = 30
infoCatcher.Parent = screen

local infoPop = Instance.new("Frame")
infoPop.Name = "InfoPop"
infoPop.AnchorPoint = Vector2.new(0, 0.5)
infoPop.Position = UDim2.fromScale(0.245, 0.45)
infoPop.Size = UDim2.fromScale(0.19, 0.6)
infoPop.BackgroundTransparency = 1
infoPop.Visible = false
infoPop.ZIndex = 31
infoPop.Parent = screen
local infoScale = Instance.new("UIScale")
infoScale.Parent = infoPop
do
	local board = Instance.new("Frame")
	board.Size = UDim2.fromScale(1, 1)
	board.BackgroundColor3 = NIGHT
	board.ZIndex = 31
	board.Parent = infoPop
	corner(board, UDim.new(0, 16))
	stroke(board, 3, C.Mustard)
	kit.skin(board, "Side_Panel")
end
local infoCard = Instance.new("ImageLabel")
infoCard.BackgroundTransparency = 1
infoCard.AnchorPoint = Vector2.new(0.5, 0)
infoCard.Position = UDim2.fromScale(0.5, 0.06)
infoCard.Size = UDim2.fromScale(0.62, 0.48)
infoCard.ScaleType = Enum.ScaleType.Stretch
infoCard.ZIndex = 32
infoCard.Parent = infoPop
aspect(infoCard, 640 / 880)
local infoIcon = Instance.new("ImageLabel")
infoIcon.BackgroundTransparency = 1
infoIcon.AnchorPoint = Vector2.new(0.5, 0.5)
infoIcon.Position = UDim2.fromScale(0.5, 0.41)
infoIcon.Size = UDim2.fromScale(0.72, 0.5)
infoIcon.ScaleType = Enum.ScaleType.Fit
infoIcon.ZIndex = 33
infoIcon.Parent = infoCard
local infoName = label(infoPop, "Name", nil, C.White, 30)
infoName.AnchorPoint = Vector2.new(0.5, 0)
infoName.Position = UDim2.fromScale(0.5, 0.56)
infoName.Size = UDim2.fromScale(0.88, 0.08)
infoName.ZIndex = 32
stickerText(infoName)
local infoRarity = label(infoPop, "Rarity", nil, C.White, 22)
infoRarity.AnchorPoint = Vector2.new(0.5, 0)
infoRarity.Position = UDim2.fromScale(0.5, 0.645)
infoRarity.Size = UDim2.fromScale(0.6, 0.055)
infoRarity.TextStrokeColor3 = C.Choc
infoRarity.TextStrokeTransparency = 0
infoRarity.ZIndex = 32
local infoDesc = label(infoPop, "Desc", Enum.Font.GothamBold, C.Cream, 22)
infoDesc.AnchorPoint = Vector2.new(0.5, 0)
infoDesc.Position = UDim2.fromScale(0.5, 0.72)
infoDesc.Size = UDim2.fromScale(0.86, 0.22)
infoDesc.ZIndex = 32
local infoClose = Instance.new("TextButton")
infoClose.AnchorPoint = Vector2.new(0.5, 0.5)
infoClose.Position = UDim2.fromScale(0.95, 0.04)
infoClose.Size = UDim2.fromScale(0.16, 0.16)
infoClose.BackgroundColor3 = C.Tomato
infoClose.Text = "X"
infoClose.Font = Enum.Font.FredokaOne
infoClose.TextScaled = true
infoClose.ZIndex = 34
stickerText(infoClose)
infoClose.Parent = infoPop
aspect(infoClose, 1)
corner(infoClose, UDim.new(1, 0))
stroke(infoClose, 3, C.Choc)

local function hideInfo()
	infoPop.Visible = false
	infoCatcher.Visible = false
end
infoCatcher.Activated:Connect(hideInfo)
infoClose.Activated:Connect(hideInfo)

local function selectPassive(key)
	local passive = key and P.List[key]
	if not passive or state.Owned[key] ~= true then return end
	selectedKey = key
	infoCard.Image = kit.id("Card_" .. passive.Rarity) or ""
	infoIcon.Image = passive.Icon or ""
	infoName.Text = passive.Display
	infoRarity.Text = string.upper(passive.Rarity)
	infoRarity.TextColor3 = rarityColor(passive.Rarity)
	infoDesc.Text = passive.Description
	infoCatcher.Visible = true
	infoPop.Visible = true
	infoScale.Scale = 0.85
	tween(infoScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

local equip -- defined below

local function buildRow(key, index)
	local passive = P.List[key]
	local owned = state.Owned[key] == true
	local equipped = state.Equipped == key
	local color = rarityColor(passive.Rarity)

	local row = Instance.new("TextButton")
	row.Name = key
	row.LayoutOrder = index
	--// PIXEL height from the list width (a 0-height row + aspect constraint
	--// resolved to 0x0 - every row was invisible)
	local rowWidth = math.max(60, list.AbsoluteSize.X - 18)
	row.Size = UDim2.new(1, 0, 0, math.floor(rowWidth / 2.5))
	row.BackgroundColor3 = owned and NIGHT or NIGHT_DEEP
	row.BackgroundTransparency = owned and 0.1 or 0.4
	row.AutoButtonColor = false
	row.Text = ""
	row.Parent = list
	corner(row, UDim.new(0, 12))
	stroke(row, 3, owned and color or Color3.fromRGB(80, 70, 62))
	--// the wood tile art; missing passives sit dimmer, owned ones wear
	--// their rarity gem in the corner
	if kit.skin(row, "List_Row") then
		row.Art.ImageTransparency = owned and 0 or 0.35
	end

	local thumb = Instance.new("ImageLabel")
	thumb.BackgroundTransparency = 1
	thumb.AnchorPoint = Vector2.new(0, 0.5)
	thumb.Position = UDim2.fromScale(0.03, 0.5)
	thumb.Size = UDim2.fromScale(0.3, 0.86)
	thumb.ScaleType = Enum.ScaleType.Stretch
	thumb.Image = kit.id(owned and ("Card_" .. passive.Rarity) or "Card_Locked") or ""
	thumb.Parent = row
	if owned then
		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.41)
		icon.Size = UDim2.fromScale(0.75, 0.5)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = passive.Icon or ""
		icon.Parent = thumb
		--// the rarity gem pinned to the mini card's corner
		local gem = sprite(thumb, "Gem_" .. passive.Rarity)
		gem.Position = UDim2.fromScale(0.88, 0.1)
		gem.Size = UDim2.fromScale(0.4, 0.22)
		gem.ZIndex = 3
	end

	local name = label(row, "Name", nil, owned and C.White or Color3.fromRGB(150, 140, 130), 26)
	name.Position = UDim2.fromScale(0.37, 0.1)
	name.Size = UDim2.fromScale(owned and 0.46 or 0.6, 0.38)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = owned and passive.Display or "???"
	if owned then stickerText(name) end

	--// THE READ-IT ICON: tap the (i) to pop this passive's card out
	if owned then
		local infoButton = Instance.new("ImageButton")
		infoButton.Name = "Info"
		infoButton.BackgroundTransparency = 1
		infoButton.AnchorPoint = Vector2.new(0.5, 0.5)
		infoButton.Position = UDim2.fromScale(0.9, 0.29)
		infoButton.Size = UDim2.fromScale(0.15, 0.4)
		infoButton.ScaleType = Enum.ScaleType.Fit
		infoButton.Image = kit.id("Odds_Button") or ""
		infoButton.ZIndex = 4
		infoButton.Parent = row
		aspect(infoButton, 1)
		UIKit.bouncy(infoButton)
		infoButton.Activated:Connect(function()
			sfx("ShopClick")
			selectPassive(key)
		end)
	end

	if owned then
		local button, text = stickerButton(row, "Equip", equipped and "EQUIPPED" or "EQUIP",
			equipped and C.Basil or BLUE)
		button.Position = UDim2.fromScale(0.37, 0.52)
		button.Size = UDim2.fromScale(0.58, 0.36)
		text.Size = UDim2.fromScale(0.9, 0.7)
		button.Activated:Connect(function()
			if equipped then
				selectPassive(key)
			else
				equip(key)
			end
		end)
	else
		local tag = label(row, "Rarity", nil, color, 20)
		tag.Position = UDim2.fromScale(0.37, 0.55)
		tag.Size = UDim2.fromScale(0.6, 0.3)
		tag.TextXAlignment = Enum.TextXAlignment.Left
		tag.Text = string.upper(passive.Rarity)
		tag.TextStrokeColor3 = C.Choc
		tag.TextStrokeTransparency = 0
	end

	row.Activated:Connect(function()
		sfx("ShopClick")
		selectPassive(key)
	end)
end

local function renderList()
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	--// owned first (by rarity, best on top), then the ones still to find
	local ordered, ownedCount = {}, 0
	for index, key in ipairs(P.Order) do
		if P.List[key] then
			local owned = state.Owned[key] == true
			if owned then ownedCount += 1 end
			table.insert(ordered, {
				Key = key,
				Owned = owned,
				Rank = P.Rarities[P.List[key].Rarity].Order,
				Index = index,
			})
		end
	end
	table.sort(ordered, function(a, b)
		if a.Owned ~= b.Owned then return a.Owned end
		if a.Owned and a.Rank ~= b.Rank then return a.Rank > b.Rank end
		return a.Index < b.Index
	end)
	for position, entry in ipairs(ordered) do
		buildRow(entry.Key, position)
	end
	listTitle.Text = ("YOUR PASSIVES  %d/%d"):format(ownedCount, #ordered)
end

renderListLater = function()
	if isOpen then renderList() end
end

local function renderBottom()
	local have = coins()
	coinText.Text = UIKit.commas(have)
	local canAfford = have >= state.Price
	openText.TextTransparency = canAfford and 0 or 0.35
	priceText.TextColor3 = canAfford and C.White or Color3.fromRGB(255, 190, 190)
	openedLine.Text = ("CRATES OPENED: %s"):format(UIKit.commas(state.Opened or 0))

	openButton.Visible = not state.Restricted
	sideCrate.Visible = not state.Restricted
	restrictedLine.Visible = state.Restricted

	setEpicBar(state.PityEpic / P.PityEpic, math.max(1, P.PityEpic - state.PityEpic))
	setLegendaryBar(state.PityLegendary / P.PityLegendary,
		math.max(1, P.PityLegendary - state.PityLegendary))
end

local function refresh()
	local ok, result = pcall(function()
		return crateRemote:InvokeServer("State")
	end)
	if ok and type(result) == "table" then
		state = result
		state.Owned = state.Owned or {}
	end
	if selectedKey == nil and state.Equipped ~= "" then
		selectedKey = state.Equipped
	end
	renderHero()
	renderList()
	renderBottom()
end

equip = function(key)
	if busy then return end
	local target = (key == state.Equipped) and "" or key
	local ok, success, reason = pcall(function()
		return crateRemote:InvokeServer("Equip", target)
	end)
	if ok and success then
		sfx("ShopClick")
		flashNotice(target == "" and "Unequipped" or (P.List[target].Display .. " equipped!"), C.Basil)
		selectedKey = key
		refresh()
	else
		flashNotice(type(reason) == "string" and reason or "Could not equip that")
	end
end

heroEquip.Activated:Connect(function()
	if selectedKey then equip(selectedKey) end
end)

----------------------------------------------------------------
-- THE OPENING (its own full-screen gui above everything)
----------------------------------------------------------------
local fxGui = Instance.new("ScreenGui")
fxGui.Name = "CrateOpening_UI"
fxGui.ResetOnSpawn = false
fxGui.IgnoreGuiInset = true
fxGui.Enabled = false
fxGui.DisplayOrder = 70
fxGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
fxGui.Parent = playerGui

local function shake(target, seconds, strength)
	local base = target.Position
	local untilT = os.clock() + seconds
	task.spawn(function()
		while os.clock() < untilT and target.Parent do
			local fade = (untilT - os.clock()) / seconds
			target.Position = base + UDim2.fromOffset(
				math.random(-strength, strength) * fade, math.random(-strength, strength) * fade)
			RunService.RenderStepped:Wait()
		end
		if target.Parent then target.Position = base end
	end)
end

local function confettiBurst(parent, count, colors)
	local id = kit.id("FX_Confetti_Sheet")
	if not id then return end
	for _ = 1, count do
		local piece = Instance.new("ImageLabel")
		piece.BackgroundTransparency = 1
		piece.Image = id
		piece.ImageRectSize = Vector2.new(256, 256)
		local cell = math.random(0, 7)
		piece.ImageRectOffset = Vector2.new((cell % 4) * 256, math.floor(cell / 4) * 256)
		piece.ImageColor3 = colors[math.random(#colors)]
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		local size = math.random(26, 46)
		piece.Size = UDim2.fromOffset(size, size)
		piece.Rotation = math.random(0, 360)
		piece.ZIndex = 40
		local startX = math.random()
		piece.Position = UDim2.fromScale(startX, -0.05)
		piece.Parent = parent
		local seconds = math.random(20, 34) / 10
		tween(piece, seconds, {
			Position = UDim2.fromScale(startX + (math.random() - 0.5) * 0.25, 1.1),
			Rotation = piece.Rotation + math.random(-540, 540),
		}, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
		task.delay(seconds, function() piece:Destroy() end)
	end
end

local function twinkleAround(parent, count, color, spread)
	for _ = 1, count do
		task.delay(math.random() * 1.2, function()
			if not parent.Parent then return end
			local twinkle = sprite(parent, "FX_Twinkle_Sheet")
			twinkle.ImageColor3 = color
			twinkle.Position = UDim2.fromScale(0.5 + (math.random() - 0.5) * spread,
				0.5 + (math.random() - 0.5) * spread)
			local size = math.random(14, 26) / 100
			twinkle.Size = UDim2.fromScale(size, size)
			twinkle.ZIndex = 30
			playSheet(twinkle, 16, 24)
		end)
	end
end

local function playOpening(result, quick)
	local passive = P.List[result.Key]
	local rarity = result.Rarity
	local color = rarityColor(rarity)
	local order = P.Rarities[rarity].Order
	local big = order >= 3     --// Epic+
	local legendary = order >= 4

	for _, child in ipairs(fxGui:GetChildren()) do child:Destroy() end
	fxGui.Enabled = true

	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.Parent = fxGui
	tween(dim, 0.3, { BackgroundTransparency = 0.3 })
	local vignette = sprite(fxGui, "FX_Vignette")
	vignette.ScaleType = Enum.ScaleType.Stretch
	vignette.Position = UDim2.fromScale(0.5, 0.5)
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.ImageTransparency = 1
	tween(vignette, 0.4, { ImageTransparency = 0 })

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.BackgroundTransparency = 1
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.47)
	stage.Size = UDim2.fromScale(0.62, 0.62)
	stage.Parent = fxGui
	aspect(stage, 1)

	local glow = sprite(stage, "Glow_Orb")
	glow.Position = UDim2.fromScale(0.5, 0.55)
	glow.Size = UDim2.fromScale(0.5, 0.5)
	glow.ImageColor3 = C.Mustard
	glow.ImageTransparency = 0.6
	glow.ZIndex = 2

	if not quick then
		--// the crate, layered: base, lid, bow (all the same square)
		local crate = Instance.new("Frame")
		crate.BackgroundTransparency = 1
		crate.AnchorPoint = Vector2.new(0.5, 0.5)
		crate.Position = UDim2.fromScale(0.5, -0.6)
		crate.Size = UDim2.fromScale(0.62, 0.62)
		crate.ZIndex = 5
		crate.Parent = stage
		local base = sprite(crate, "Crate_Base")
		base.Position = UDim2.fromScale(0.5, 0.5)
		base.Size = UDim2.fromScale(1, 1)
		base.ZIndex = 5
		local lid = sprite(crate, "Crate_LidNoBow")
		lid.Position = UDim2.fromScale(0.5, 0.5)
		lid.Size = UDim2.fromScale(1, 1)
		lid.ZIndex = 6
		local bow = sprite(crate, "Crate_Bow")
		bow.Position = UDim2.fromScale(0.5, 0.3)
		bow.Size = UDim2.fromScale(0.5, 0.5)
		bow.ZIndex = 7

		--// 1. DROP in with a bounce
		sfx("ShopClick")
		tween(crate, 0.6, { Position = UDim2.fromScale(0.5, 0.55) }, Enum.EasingStyle.Bounce)
		task.wait(0.65)

		--// 2. SHAKE + THE RARITY ROULETTE (owner spec): the glow starts WHITE,
		--// then flashes blue / purple / gold faster and faster while the crate
		--// shakes harder - and the LAST flash is the rarity you actually got.
		local SHAKE = 2.4
		glow.ImageColor3 = Color3.new(1, 1, 1)
		tween(glow, SHAKE, { Size = UDim2.fromScale(1.25, 1.25), ImageTransparency = 0.12 })
		local roulette = Instance.new("ImageLabel") --// a ring that pulses with each flash
		roulette.BackgroundTransparency = 1
		roulette.AnchorPoint = Vector2.new(0.5, 0.5)
		roulette.Position = UDim2.fromScale(0.5, 0.55)
		roulette.Size = UDim2.fromScale(0.75, 0.75)
		roulette.ScaleType = Enum.ScaleType.Fit
		roulette.Image = kit.id("FX_Shockwave") or ""
		roulette.ImageColor3 = Color3.new(1, 1, 1)
		roulette.ImageTransparency = 0.4
		roulette.ZIndex = 3
		roulette.Parent = stage
		task.spawn(function()
			local cycle = { "Rare", "Epic", "Legendary" }
			local started = os.clock()
			task.wait(0.45) --// a beat of plain white first
			local gap, i = 0.24, 0
			local stopAt = SHAKE - 0.4
			while os.clock() - started < stopAt do
				i += 1
				local flashColor = rarityColor(cycle[(i - 1) % #cycle + 1])
				glow.ImageColor3 = flashColor
				roulette.ImageColor3 = flashColor
				roulette.ImageTransparency = 0.1
				roulette.Size = UDim2.fromScale(0.65, 0.65)
				tween(roulette, gap, { Size = UDim2.fromScale(0.85, 0.85), ImageTransparency = 0.5 })
				sfx("ShopClick")
				task.wait(gap)
				gap = math.max(0.07, gap * 0.86)
			end
			--// THE LAST FLASH: the real rarity, held, with a big pulse
			glow.ImageColor3 = color
			roulette.ImageColor3 = color
			roulette.ImageTransparency = 0
			roulette.Size = UDim2.fromScale(0.6, 0.6)
			tween(roulette, 0.4, { Size = UDim2.fromScale(1.3, 1.3), ImageTransparency = 0.35 },
				Enum.EasingStyle.Back)
			tween(glow, 0.3, { Size = UDim2.fromScale(1.45, 1.45), ImageTransparency = 0.02 })
			if big then
				local swirl = sprite(stage, "FX_Swirl")
				swirl.Position = UDim2.fromScale(0.5, 0.55)
				swirl.Size = UDim2.fromScale(0.2, 0.2)
				swirl.ImageColor3 = color
				swirl.ImageTransparency = 1
				swirl.ZIndex = 1
				tween(swirl, 0.4, { Size = UDim2.fromScale(1.5, 1.5), ImageTransparency = 0.2 })
				spinForever(swirl, legendary and 260 or 180)
			end
		end)
		local shakeStart = os.clock()
		while os.clock() - shakeStart < SHAKE do
			local t = (os.clock() - shakeStart) / SHAKE
			local amount = 2 + t * t * (legendary and 14 or 9)
			crate.Rotation = (math.random() * 2 - 1) * amount
			crate.Position = UDim2.new(0.5, (math.random() * 2 - 1) * amount, 0.55,
				(math.random() * 2 - 1) * amount * 0.5)
			task.wait(0.03)
		end
		crate.Rotation = 0
		crate.Position = UDim2.fromScale(0.5, 0.55)

		--// 3. POP: the bow flies, the lid blasts off, poof + shockwave + flash
		sfx(legendary and "UltimateReady" or "AnswerRight")
		tween(bow, 0.7, { Position = UDim2.fromScale(-0.4, -0.9), Rotation = -540, ImageTransparency = 1 })
		task.wait(0.08)
		tween(lid, 0.6, { Position = UDim2.fromScale(0.75, -1.1), Rotation = 35, ImageTransparency = 1 })
		local poof = sprite(stage, "FX_Poof_Sheet")
		poof.Position = UDim2.fromScale(0.5, 0.42)
		poof.Size = UDim2.fromScale(0.7, 0.7)
		poof.ZIndex = 9
		playSheet(poof, 16, 30)
		tween(roulette, 0.3, { ImageTransparency = 1 }) --// the roulette ring hands over to the blast
		local ring = sprite(stage, "FX_Shockwave")
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.Size = UDim2.fromScale(0.15, 0.15)
		ring.ImageColor3 = color
		ring.ZIndex = 8
		tween(ring, 0.55, { Size = UDim2.fromScale(1.9, 1.9), ImageTransparency = 1 })
		local flash = Instance.new("Frame")
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = Color3.new(1, 1, 1)
		flash.BackgroundTransparency = big and 0.1 or 0.45
		flash.ZIndex = 50
		flash.Parent = fxGui
		tween(flash, 0.45, { BackgroundTransparency = 1 })
		shake(stage, big and 0.5 or 0.3, big and 18 or 9)

		--// 4. LIGHT PILLAR out of the open crate
		local pillar = sprite(stage, "FX_LightPillar")
		pillar.ScaleType = Enum.ScaleType.Stretch
		pillar.AnchorPoint = Vector2.new(0.5, 1)
		pillar.Position = UDim2.fromScale(0.5, 0.6)
		pillar.Size = UDim2.fromScale(0.3, 0)
		pillar.ImageColor3 = color
		pillar.ZIndex = 4
		tween(pillar, 0.35, { Size = UDim2.fromScale(0.34, 1.6) })
		task.wait(0.45)
		tween(crate, 0.4, { Size = UDim2.fromScale(0.4, 0.4), Position = UDim2.fromScale(0.5, 0.95) })
		tween(base, 0.4, { ImageTransparency = 1 })
		tween(pillar, 0.7, { ImageTransparency = 1 })
	else
		glow.ImageColor3 = color
		tween(glow, 0.3, { Size = UDim2.fromScale(1.2, 1.2), ImageTransparency = 0.15 })
	end

	--// 5. THE CARD rises out of the light, back first
	local rays = sprite(stage, "Burst_Rays")
	rays.Position = UDim2.fromScale(0.5, 0.45)
	rays.Size = UDim2.fromScale(0.2, 0.2)
	rays.ImageColor3 = color
	rays.ImageTransparency = 0.25
	rays.ZIndex = 3
	tween(rays, 0.5, { Size = UDim2.fromScale(1.6, 1.6) }, Enum.EasingStyle.Back)
	spinForever(rays, 30)
	local sparkles = sprite(stage, "Burst_Sparkles")
	sparkles.Position = UDim2.fromScale(0.5, 0.45)
	sparkles.Size = UDim2.fromScale(0.3, 0.3)
	sparkles.ImageColor3 = color
	sparkles.ZIndex = 3
	tween(sparkles, 0.6, { Size = UDim2.fromScale(1.15, 1.15) }, Enum.EasingStyle.Back)
	spinForever(sparkles, -18)

	local CARD_W, CARD_H = 0.36, 0.36 * 880 / 640
	local card = Instance.new("ImageLabel")
	card.Name = "Card"
	card.BackgroundTransparency = 1
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.75)
	card.Size = UDim2.fromScale(0, 0)
	card.ScaleType = Enum.ScaleType.Stretch
	card.Image = kit.id("Card_Back") or ""
	card.ZIndex = 10
	card.ClipsDescendants = true
	card.Parent = stage
	tween(card, quick and 0.3 or 0.5,
		{ Size = UDim2.fromScale(CARD_W, CARD_H), Position = UDim2.fromScale(0.5, 0.45) },
		Enum.EasingStyle.Back)
	task.wait(quick and 0.35 or 0.75)

	--// the FLIP: squash to nothing, swap to the face, spring back
	tween(card, 0.16, { Size = UDim2.fromScale(0, CARD_H) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.wait(0.16)
	card.Image = kit.id("Card_" .. rarity) or ""
	local icon = Instance.new("ImageLabel")
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.41)
	icon.Size = UDim2.fromScale(0.72, 0.5)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = passive.Icon or ""
	icon.ZIndex = 11
	icon.Parent = card
	local cardName = label(card, "Name", nil, C.Choc)
	cardName.AnchorPoint = Vector2.new(0.5, 0.5)
	cardName.Position = UDim2.fromScale(0.5, 0.87)
	cardName.Size = UDim2.fromScale(0.8, 0.12)
	cardName.Text = passive.Display
	cardName.ZIndex = 11
	tween(card, 0.22, { Size = UDim2.fromScale(CARD_W, CARD_H) }, Enum.EasingStyle.Back)
	sfx("ShopPurchase")

	if big then
		local shine = sprite(card, "Shine_Sweep")
		shine.Size = UDim2.fromScale(0.6, 1.4)
		shine.Position = UDim2.fromScale(-0.4, 0.5)
		shine.ImageTransparency = 0.2
		shine.ZIndex = 12
		task.spawn(function()
			while shine.Parent do
				shine.Position = UDim2.fromScale(-0.4, 0.5)
				tween(shine, 0.7, { Position = UDim2.fromScale(1.4, 0.5) }, Enum.EasingStyle.Sine)
				task.wait(legendary and 1.4 or 2.4)
			end
		end)
	end

	twinkleAround(stage, big and 10 or 5, color, 0.8)

	--// the rarity ribbon + the words
	local ribbon = sprite(stage, "Rarity_Ribbon")
	ribbon.Position = UDim2.fromScale(0.5, 0.86)
	ribbon.Size = UDim2.fromScale(0, 0.12)
	ribbon.ImageColor3 = color
	ribbon.ZIndex = 13
	local ribbonText = label(ribbon, "Text")
	ribbonText.AnchorPoint = Vector2.new(0.5, 0.5)
	ribbonText.Position = UDim2.fromScale(0.5, 0.42)
	ribbonText.Size = UDim2.fromScale(0.62, 0.5)
	ribbonText.Text = string.upper(rarity) .. "!"
	ribbonText.ZIndex = 14
	stickerText(ribbonText)
	tween(ribbon, 0.35, { Size = UDim2.fromScale(0.62, 0.15) }, Enum.EasingStyle.Back)

	local words = Instance.new("Frame")
	words.BackgroundTransparency = 1
	words.AnchorPoint = Vector2.new(0.5, 0)
	words.Position = UDim2.fromScale(0.5, 0.8)
	words.Size = UDim2.fromScale(0.6, 0.16)
	words.Parent = fxGui
	local desc = label(words, "Desc", nil, C.White, 30)
	desc.Size = UDim2.fromScale(1, 0.5)
	desc.Text = passive.Description
	stickerText(desc)
	local extra = label(words, "Extra", nil, C.Mustard, 26)
	extra.Position = UDim2.fromScale(0, 0.52)
	extra.Size = UDim2.fromScale(1, 0.42)
	extra.TextStrokeColor3 = C.Choc
	extra.TextStrokeTransparency = 0
	if result.Duplicate then
		extra.Text = ("DUPLICATE!  +%d coins back"):format(result.Refund or 0)
	elseif result.AutoEquipped then
		extra.Text = "NEW!  Equipped and ready for your next shift"
		extra.TextColor3 = C.Basil
	else
		extra.Text = "NEW!  Equip it from your passives"
		extra.TextColor3 = C.Basil
	end
	desc.TextTransparency, extra.TextTransparency = 1, 1
	tween(desc, 0.4, { TextTransparency = 0 })
	task.delay(0.25, function() tween(extra, 0.4, { TextTransparency = 0 }) end)

	--// 6. LEGENDARY (and a little for Epic): fireworks + confetti
	local palette = { color, C.Mustard, C.Tomato, C.Basil, C.Cream }
	if legendary then
		shake(stage, 0.6, 12)
		confettiBurst(fxGui, 70, palette)
		for i = 1, 7 do
			task.delay(i * 0.25, function()
				if not fxGui.Enabled then return end
				local boom = sprite(fxGui, "FX_Firework_Sheet")
				boom.Position = UDim2.fromScale(0.15 + math.random() * 0.7, 0.12 + math.random() * 0.45)
				local s = math.random(22, 34) / 100
				boom.Size = UDim2.fromScale(s, s)
				boom.ImageColor3 = palette[math.random(#palette)]
				boom.ZIndex = 35
				aspect(boom, 1)
				playSheet(boom, 16, 22)
			end)
		end
	elseif big then
		confettiBurst(fxGui, 24, palette)
	end

	--// 7. tap to continue
	local tapHint = label(fxGui, "Tap", nil, C.White, 24)
	tapHint.AnchorPoint = Vector2.new(0.5, 1)
	tapHint.Position = UDim2.fromScale(0.5, 0.985)
	tapHint.Size = UDim2.fromScale(0.4, 0.04)
	tapHint.Text = "Tap to continue"
	tapHint.TextTransparency = 1
	stickerText(tapHint)
	task.wait(quick and 0.5 or 1.2)
	task.spawn(function()
		while tapHint.Parent do
			tween(tapHint, 0.6, { TextTransparency = 0 })
			task.wait(0.9)
			if not tapHint.Parent then break end
			tween(tapHint, 0.6, { TextTransparency = 0.6 })
			task.wait(0.9)
		end
	end)

	local catcher = Instance.new("TextButton")
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.BackgroundTransparency = 1
	catcher.Text = ""
	catcher.ZIndex = 60
	catcher.Parent = fxGui
	local closed = Instance.new("BindableEvent")
	catcher.Activated:Connect(function() closed:Fire() end)
	closed.Event:Wait()
	closed:Destroy()

	fxGui.Enabled = false
	for _, child in ipairs(fxGui:GetChildren()) do child:Destroy() end
end

----------------------------------------------------------------
-- OPEN
----------------------------------------------------------------
openButton.Activated:Connect(function()
	if busy or state.Restricted then return end
	local have = coins()
	if have < state.Price then
		flashNotice(("Need %d more coins!"):format(state.Price - have))
		return
	end
	busy = true
	local ok, success, result = pcall(function()
		return crateRemote:InvokeServer("Open")
	end)
	if not ok or not success then
		flashNotice(type(result) == "string" and result or "Try again in a moment!")
		busy = false
		return
	end
	gui.Enabled = false
	playOpening(result, false)
	selectedKey = result.Key
	refresh()
	gui.Enabled = isOpen
	busy = false
	selectPassive(result.Key)
end)

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------
local idleToken = 0
local function setOpen(open)
	if busy then return end
	isOpen = open
	if open then
		gui.Enabled = true
		--// pop in: the whole screen springs up from slightly small
		screenScale.Scale = 0.94
		tween(screenScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		insideBox.Visible = false
		openRarity = nil
		refresh()
		--// idle life: the light turns, the card floats, the shine passes
		idleToken += 1
		local mine = idleToken
		task.spawn(function()
			local t, shineAt, moteAt = 0, 1.5, 0
			while idleToken == mine and isOpen do
				local dt = RunService.RenderStepped:Wait()
				t += dt
				heroRays.Rotation = (heroRays.Rotation + dt * 14) % 360
				heroSparkles.Rotation = (heroSparkles.Rotation - dt * 8) % 360
				heroSwirl.Rotation = (heroSwirl.Rotation + dt * 40) % 360
				heroGlow.ImageTransparency = 0.3 + math.sin(t * 2.6) * 0.12
				heroCard.Position = UDim2.fromScale(0.5, 0.44 + math.sin(t * 1.8) * 0.015)
				heroCard.Rotation = math.sin(t * 1.1) * 1.5
				heroCrate.Position = UDim2.fromScale(0.5, 0.52 + math.sin(t * 2.2) * 0.02)
				sideCrate.Rotation = math.sin(t * 3) * 4
				--// dust motes drifting up through the spotlight
				if t >= moteAt then
					moteAt = t + 0.28
					local mote = sprite(screen, "Glow_Orb")
					local size = math.random(6, 14)
					mote.Size = UDim2.fromOffset(size, size)
					mote.Position = UDim2.fromScale(0.42 + math.random() * 0.16, 0.74)
					mote.ImageColor3 = heroSpot.ImageColor3
					mote.ImageTransparency = 0.2
					mote.ZIndex = 2
					local seconds = math.random(30, 50) / 10
					tween(mote, seconds, {
						Position = UDim2.fromScale(0.4 + math.random() * 0.2, 0.2),
						ImageTransparency = 1,
					}, Enum.EasingStyle.Sine)
					task.delay(seconds, function() mote:Destroy() end)
				end
				if heroShine.Visible and t >= shineAt then
					shineAt = t + 3
					heroShine.Position = UDim2.fromScale(-0.5, 0.5)
					tween(heroShine, 0.8, { Position = UDim2.fromScale(1.5, 0.5) }, Enum.EasingStyle.Sine)
				end
			end
		end)
	else
		idleToken += 1
		tween(screenScale, 0.15, { Scale = 0.96 })
		task.delay(0.15, function()
			if not isOpen then gui.Enabled = false end
		end)
	end
end

backButton.Activated:Connect(function() setOpen(false) end)

do
	local wallet = walletValue()
	if wallet then
		wallet.Changed:Connect(function()
			if isOpen then renderBottom() end
		end)
	end
end

----------------------------------------------------------------
-- The lobby-wide LEGENDARY shout
----------------------------------------------------------------
if shoutRemote then
	local shoutGui = Instance.new("ScreenGui")
	shoutGui.Name = "CrateShout_UI"
	shoutGui.ResetOnSpawn = false
	shoutGui.DisplayOrder = 65
	shoutGui.Parent = playerGui
	shoutRemote.OnClientEvent:Connect(function(kind, who, key)
		if kind ~= "Legendary" or not P.List[key] then return end
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0)
		bar.Position = UDim2.fromScale(0.5, -0.15)
		bar.Size = UDim2.fromScale(0.5, 0.08)
		bar.BackgroundColor3 = rarityColor("Legendary")
		bar.Parent = shoutGui
		corner(bar, UDim.new(0.4, 0))
		stroke(bar, 4, C.Choc)
		local crown = sprite(bar, "Gem_Legendary")
		crown.Position = UDim2.fromScale(0.07, 0.5)
		crown.Size = UDim2.fromScale(0.1, 0.85)
		local text = label(bar, "Text")
		text.AnchorPoint = Vector2.new(0.5, 0.5)
		text.Position = UDim2.fromScale(0.55, 0.5)
		text.Size = UDim2.fromScale(0.8, 0.6)
		text.Text = ("%s pulled a LEGENDARY %s!"):format(tostring(who), P.List[key].Display)
		stickerText(text)
		tween(bar, 0.5, { Position = UDim2.fromScale(0.5, 0.03) }, Enum.EasingStyle.Back)
		task.delay(5, function()
			tween(bar, 0.4, { Position = UDim2.fromScale(0.5, -0.15) })
			task.delay(0.45, function() bar:Destroy() end)
		end)
	end)
end

----------------------------------------------------------------
-- Openers: a Studio dock button named OpenCratesButton, else the sticker
----------------------------------------------------------------
local stickerGui = Instance.new("ScreenGui")
stickerGui.Name = "CratesButton_UI"
stickerGui.ResetOnSpawn = false
stickerGui.DisplayOrder = 10
stickerGui.Parent = playerGui

local sticker = Instance.new("TextButton")
sticker.Name = "CratesSticker"
sticker.AnchorPoint = Vector2.new(0, 0.5)
sticker.Position = UDim2.fromScale(0.025, 0.855) --// below the STATS sticker
sticker.Size = UDim2.fromScale(0.085, 0.075)
sticker.BackgroundColor3 = C.Tomato
sticker.Rotation = -2
sticker.Font = Enum.Font.FredokaOne
sticker.TextScaled = true
sticker.Text = "CRATES"
stickerText(sticker)
sticker.Parent = stickerGui
corner(sticker, UDim.new(0, 10))
stroke(sticker, 2.5, C.Choc)
--// the owner's CRATES art (Button_Crates) replaces the text sticker
do
	local artId = kit.id("Button_Crates")
	if artId then
		sticker.Text = ""
		sticker.BackgroundTransparency = 1
		sticker.Rotation = 0
		for _, child in ipairs(sticker:GetChildren()) do
			if child:IsA("UIStroke") or child:IsA("UICorner") then child:Destroy() end
		end
		sticker.Size = UDim2.fromScale(0.1, 0.14)
		sticker.Position = UDim2.fromScale(0.012, 0.875)
		aspect(sticker, 1)
		local art = Instance.new("ImageLabel")
		art.Name = "Art"
		art.BackgroundTransparency = 1
		art.Size = UDim2.fromScale(1, 1)
		art.ScaleType = Enum.ScaleType.Fit
		art.Image = artId
		art.Parent = sticker
	end
end
UIKit.bouncy(sticker)
sticker.Activated:Connect(function()
	sfx("ShopClick")
	setOpen(not isOpen)
end)

local bound = {}
local function bindOpenButton(inst)
	if inst.Name ~= "OpenCratesButton" or not inst:IsA("GuiButton") or bound[inst] then return end
	bound[inst] = true
	inst.Activated:Connect(function()
		sfx("ShopClick")
		setOpen(not isOpen)
	end)
	if stickerGui.Parent then stickerGui:Destroy() end
	print(("[Crates] opens from %s"):format(inst:GetFullName()))
end
for _, inst in ipairs(playerGui:GetDescendants()) do
	bindOpenButton(inst)
end
playerGui.DescendantAdded:Connect(bindOpenButton)

print("[Crates] ready")
