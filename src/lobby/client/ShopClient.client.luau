--[[
	Dinner Rush - ShopClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.ShopClient  (LocalScript)

	The Robux SHOP (Oct 2026). Opens from the lobby's OpenShopButton (the
	SHOP! sticker under CODES!) and from the + on the coin pill.

	  COINS  - a featured "best value" pack on top, the other packs below
	  PASSES - the game passes, side by side

	RENDER ONLY - this script cannot give anything. A price button only asks
	the server to open Roblox's purchase window (PurchaseRemote "Prompt");
	the server (ServerStorage.Shared.Purchases) checks the item, Roblox takes
	the payment, and the server grants it from Roblox's receipt. Prices are
	read live from Roblox, "OWNED" from the server's Pass_<Key> attributes,
	the coin count from leaderstats - all display.

	ART SLOTS: every frame, banner, button and item checks
	Config.Monetization.ShopArt / each item's Image. Empty = the code-drawn
	placeholder; an asset id = that piece becomes the art. Frames are
	9-SLICED with a border that scales with the panel (SliceScale follows the
	frame's on-screen size vs the art's real Size), and plain art is drawn
	with Fit so it never squashes. No code change needed to reskin.

	EFFECTS (all client-side, cosmetic): background blur, the awning drops
	in, a slow sunburst behind the featured pack, floating items, twinkles,
	a shine sweep, card hover lift, page slides, and a coin shower into the
	counter when a purchase lands.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MON = Config.Monetization
if not MON then return end
local ART = MON.ShopArt or {}

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
local BASIL_DARK = Color3.fromRGB(48, 128, 76)
local WOOD = Color3.fromRGB(150, 98, 56)
local WOOD_DARK = Color3.fromRGB(110, 70, 38)
local GREY = Color3.fromRGB(190, 182, 172)
local GREY_DARK = Color3.fromRGB(140, 132, 122)
local WHITE = Color3.new(1, 1, 1)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local isOpen = false

----------------------------------------------------------------
-- Small builders
----------------------------------------------------------------
local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then
		pcall(SfxLocal.Play, name)
	end
end

local function corner(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, 14)
	c.Parent = obj
	return c
end

local function stroke(obj, thickness, color)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 3
	s.Color = color or CHOC
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = obj
	return s
end

local function label(parent, name, font, color, maxSize)
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Font = font or Enum.Font.FredokaOne
	t.TextColor3 = color or CHOC
	t.TextScaled = true
	t.TextWrapped = true
	t.Text = ""
	t.Parent = parent
	if maxSize then
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = maxSize
		cap.Parent = t
	end
	return t
end

--// white letters with a chocolate outline - the lobby sticker look
local function stickerText(t)
	t.TextColor3 = WHITE
	t.TextStrokeColor3 = CHOC
	t.TextStrokeTransparency = 0
end

local function aspect(obj, ratio)
	local a = Instance.new("UIAspectRatioConstraint")
	a.AspectRatio = ratio
	a.Parent = obj
	return a
end

local function commas(n)
	local s = tostring(math.floor(n or 0))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function artId(slot)
	local entry = ART[slot]
	local id = entry and entry.Image
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

--// SWAP A PIECE TO ITS ART: the code-drawn look (stroke, corner, gradient,
--// and anything built into a child named "Placeholder") steps aside and the
--// image fills the frame. Sliced art keeps its border in proportion to the
--// frame's on-screen size; plain art is drawn with Fit so it never squashes.
local function skin(frame, slot)
	local entry = ART[slot]
	local id = artId(slot)
	if not id then return false end
	frame.BackgroundTransparency = 1
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("UIStroke") or child:IsA("UICorner") or child:IsA("UIGradient")
			or child.Name == "Placeholder" then
			child:Destroy()
		end
	end
	local image = Instance.new("ImageLabel")
	image.Name = "Art"
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromScale(1, 1)
	image.ZIndex = 0 --// behind the live text and buttons
	image.Image = id
	if entry.Slice then
		local s = entry.Slice
		image.ScaleType = Enum.ScaleType.Slice
		image.SliceCenter = Rect.new(s[1], s[2], s[3], s[4])
		local nativeW = entry.Size and entry.Size[1] or 512
		local nativeH = entry.Size and entry.Size[2] or 512
		local function rescale()
			local size = frame.AbsoluteSize
			if size.X > 0 and size.Y > 0 then
				image.SliceScale = math.clamp(math.min(size.X / nativeW, size.Y / nativeH), 0.05, 4)
			end
		end
		frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)
		rescale()
	else
		image.ScaleType = Enum.ScaleType.Fit
	end
	image.Parent = frame
	if frame:IsA("TextButton") then
		frame.AutoButtonColor = false
	end
	return true
end

--// hover grows a little, a press squashes - every button feels pressable
local QUICK = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local function bouncy(button)
	local scale = Instance.new("UIScale")
	scale.Parent = button
	button.MouseEnter:Connect(function()
		TweenService:Create(scale, QUICK, { Scale = 1.06 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, QUICK, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, QUICK, { Scale = 0.94 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, QUICK, { Scale = 1.06 }):Play()
	end)
	button.Activated:Connect(function()
		sfx("ShopClick")
	end)
	return scale
end

--// big item art: the uploaded image, else the emoji placeholder
local function itemArt(parent, def)
	if type(def.Image) == "string" and def.Image ~= "" then
		local image = Instance.new("ImageLabel")
		image.Name = "ItemArt"
		image.BackgroundTransparency = 1
		image.ScaleType = Enum.ScaleType.Fit
		image.Image = def.Image
		image.Parent = parent
		return image
	end
	local emoji = label(parent, "ItemArt", Enum.Font.FredokaOne, CHOC)
	emoji.Text = def.Emoji or "🎁"
	return emoji
end

--// an effect/decoration sprite from the art kit, or nil when its slot is empty
local function fxImage(parent, slot, name)
	local id = artId(slot)
	if not id then return nil end
	local image = Instance.new("ImageLabel")
	image.Name = name or slot
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.Image = id
	image.Parent = parent
	return image
end

--// EFFECT: the item bobs gently, forever (cheap; stops mattering when hidden)
local function floatArt(art, delaySeconds)
	local base = art.Position
	task.delay(delaySeconds or 0, function()
		TweenService:Create(art, TweenInfo.new(1.4, Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut, -1, true),
			{ Position = base - UDim2.fromScale(0, 0.03) }):Play()
	end)
end

----------------------------------------------------------------
-- Skeleton
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Shop_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

--// EFFECT: the lobby blurs behind the shop (a local-only Lighting effect)
local blur = Instance.new("BlurEffect")
blur.Name = "ShopBlur"
blur.Size = 0
blur.Enabled = false
blur.Parent = Lighting

local backdrop = Instance.new("TextButton")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 1
backdrop.AutoButtonColor = false
backdrop.Text = ""
backdrop.Parent = gui

local root = Instance.new("Frame")
root.Name = "MainPanel" --// lobby close convention
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.54, 0.56) --// nudged right: clear of the lobby button column
root.Size = UDim2.fromScale(0.7, 0.72)
root.BackgroundTransparency = 1
root.Parent = gui
aspect(root, 1.55)
local rootScale = Instance.new("UIScale")
rootScale.Parent = root

--// the menu-board panel: wood border, mustard inner trim, cream inside
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = CREAM
panel.Parent = root
corner(panel, UDim.new(0, 22))
stroke(panel, 7, WOOD)
local panelGrad = Instance.new("UIGradient")
panelGrad.Rotation = 90
panelGrad.Color = ColorSequence.new(WHITE, WARM)
panelGrad.Parent = panel
do
	local trim = Instance.new("Frame")
	trim.Name = "Placeholder"
	trim.AnchorPoint = Vector2.new(0.5, 0.5)
	trim.Position = UDim2.fromScale(0.5, 0.5)
	trim.Size = UDim2.new(1, -14, 1, -14)
	trim.BackgroundTransparency = 1
	trim.Parent = panel
	corner(trim, UDim.new(0, 18))
	stroke(trim, 2, MUSTARD)
	for _, at in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
		local bolt = Instance.new("Frame")
		bolt.AnchorPoint = Vector2.new(0.5, 0.5)
		bolt.Position = UDim2.new(at[1], at[1] == 0 and 10 or -10, at[2], at[2] == 0 and 10 or -10)
		bolt.Size = UDim2.fromOffset(12, 12)
		bolt.BackgroundColor3 = MUSTARD
		bolt.Parent = trim
		corner(bolt, UDim.new(1, 0))
		stroke(bolt, 2, WOOD_DARK)
	end
end
skin(panel, "PanelFrame")

--// DECOR: a quiet diner-check tile across the panel's cream inside
do
	local pattern = fxImage(panel, "PanelPattern", "Pattern")
	if pattern then
		pattern.AnchorPoint = Vector2.new(0.5, 0.5)
		pattern.Position = UDim2.fromScale(0.5, 0.5)
		pattern.Size = UDim2.fromScale(0.86, 0.8) --// inside the wood border
		pattern.ScaleType = Enum.ScaleType.Tile
		pattern.TileSize = UDim2.fromOffset(110, 110)
		pattern.ImageTransparency = 0.35
		pattern.ZIndex = 1
		corner(pattern, UDim.new(0, 16))
	end
end

--// DECOR: bistro lights draped over the top, behind the awning (the bulbs
--// twinkle while the shop is open - see startLoops)
local bulbGlows = {}
do
	local lights = fxImage(root, "BistroLights", "BistroLights")
	if lights then
		lights.AnchorPoint = Vector2.new(0.5, 0)
		lights.Position = UDim2.fromScale(0.5, -0.19)
		lights.Size = UDim2.fromScale(1.02, 0.27)
		lights.ScaleType = Enum.ScaleType.Stretch
		lights.ZIndex = 2
		--// a soft glow on each of the 8 bulbs, along the cord's sag
		for i = 0, 7 do
			local x = 0.06 + i * (0.88 / 7)
			local y = 0.5 + 0.2 * (1 - (2 * x - 1) ^ 2)
			local glow = fxImage(lights, "SoftGlow", "BulbGlow" .. i)
			if glow then
				glow.AnchorPoint = Vector2.new(0.5, 0.5)
				glow.Position = UDim2.fromScale(x, y)
				glow.Size = UDim2.fromScale(0.09, 0.6)
				glow.ImageTransparency = 0.3
				glow.ZIndex = 3
				aspect(glow, 1)
				table.insert(bulbGlows, glow)
			end
		end
	end
end

--// DECOR: food doodles peeking round the frame, each with a gentle wiggle
local steam = nil
do
	local DOODLES = {
		--// tucked onto the frame (smaller, never over the lobby buttons)
		{ "CornerDoodleBurger", 0.015, 0.6, -12 },
		{ "CornerDoodleDonut", 0.04, 0.955, 10 },
		{ "CornerDoodleTomato", 0.96, 0.955, -8 },
		{ "CornerDoodleCoffee", 0.985, 0.44, 9 },
	}
	for i, d in ipairs(DOODLES) do
		local doodle = fxImage(root, d[1])
		if doodle then
			doodle.AnchorPoint = Vector2.new(0.5, 0.5)
			doodle.Position = UDim2.fromScale(d[2], d[3])
			doodle.Size = UDim2.fromScale(0.08, 0.12)
			doodle.Rotation = d[4]
			doodle.ZIndex = 7
			aspect(doodle, 1)
			TweenService:Create(doodle, TweenInfo.new(1.3 + i * 0.2, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut, -1, true), { Rotation = d[4] + (d[4] > 0 and -10 or 10) }):Play()
			if d[1] == "CornerDoodleCoffee" then
				steam = fxImage(root, "SteamWisp", "Steam")
				if steam then
					steam.AnchorPoint = Vector2.new(0.5, 1)
					steam.Position = UDim2.fromScale(d[2] - 0.005, d[3] - 0.07)
					steam.Size = UDim2.fromScale(0.04, 0.12)
					steam.ZIndex = 7
				end
			end
		end
	end
end

--// HEADER: the striped awning over the top edge, with the SHOP plate
local headerArt = artId("HeaderBanner") ~= nil
local HEADER_HOME = headerArt and UDim2.fromScale(0.5, -0.1) or UDim2.fromScale(0.5, -0.06)
local header = Instance.new("Frame")
header.Name = "Header"
header.AnchorPoint = Vector2.new(0.5, 0)
header.Position = HEADER_HOME
header.Size = headerArt and UDim2.fromScale(1.04, 0.27) or UDim2.fromScale(1.04, 0.2)
header.BackgroundTransparency = 1
header.ZIndex = 3
header.Parent = root
do
	local deco = Instance.new("Frame")
	deco.Name = "Placeholder"
	deco.Size = UDim2.fromScale(1, 1)
	deco.BackgroundTransparency = 1
	deco.ZIndex = 3
	deco.Parent = header

	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.Size = UDim2.fromScale(1, 0.14)
	rail.BackgroundColor3 = WOOD
	rail.ZIndex = 4
	rail.Parent = deco
	corner(rail, UDim.new(0, 8))
	stroke(rail, 3, CHOC)

	local cloth = Instance.new("Frame")
	cloth.Name = "Stripes"
	cloth.Position = UDim2.fromScale(0, 0.1)
	cloth.Size = UDim2.fromScale(1, 0.58)
	cloth.BackgroundTransparency = 1
	cloth.ClipsDescendants = true
	cloth.ZIndex = 3
	cloth.Parent = deco
	local stripes = 14
	for i = 1, stripes do
		local s = Instance.new("Frame")
		s.Position = UDim2.fromScale((i - 1) / stripes, 0)
		s.Size = UDim2.fromScale(1 / stripes + 0.002, 1)
		s.BorderSizePixel = 0
		s.BackgroundColor3 = (i % 2 == 1) and TOMATO or WHITE
		s.ZIndex = 3
		s.Parent = cloth
		local scallop = Instance.new("Frame")
		scallop.AnchorPoint = Vector2.new(0.5, 0.5)
		scallop.Position = UDim2.new((i - 0.5) / stripes, 0, 0.68, 0)
		scallop.Size = UDim2.fromScale(1 / stripes, 0.3)
		scallop.BorderSizePixel = 0
		scallop.BackgroundColor3 = s.BackgroundColor3
		scallop.ZIndex = 3
		scallop.Parent = deco
		corner(scallop, UDim.new(1, 0))
	end

	local plate = Instance.new("Frame")
	plate.Name = "TitlePlate"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.42)
	plate.Size = UDim2.fromScale(0.26, 0.56)
	plate.BackgroundColor3 = CREAM
	plate.ZIndex = 5
	plate.Parent = deco
	corner(plate, UDim.new(0, 14))
	stroke(plate, 3, CHOC)
end
skin(header, "HeaderBanner")

--// the title sits on the code plate, or on the art's own blank plate
local titleText = label(header, "Title", Enum.Font.FredokaOne, TOMATO)
titleText.AnchorPoint = Vector2.new(0.5, 0.5)
if headerArt then
	titleText.Position = UDim2.fromScale(0.5, 0.56) --// the art plate's centre
	titleText.Size = UDim2.fromScale(1, 0.32)
	aspect(titleText, 3.6)
else
	titleText.Position = UDim2.fromScale(0.5, 0.42)
	titleText.Size = UDim2.fromScale(0.22, 0.44)
end
titleText.Text = "SHOP"
titleText.TextStrokeColor3 = CHOC
titleText.TextStrokeTransparency = 0
titleText.ZIndex = 6

--// CLOSE: round tomato X on the top-right corner
local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton" --// lobby close convention
closeButton.AnchorPoint = Vector2.new(0.5, 0.5)
closeButton.Position = UDim2.fromScale(0.985, 0.03)
closeButton.Size = UDim2.fromScale(0.08, 0.08)
closeButton.BackgroundColor3 = TOMATO
closeButton.Font = Enum.Font.FredokaOne
closeButton.TextScaled = true
closeButton.Text = "X"
closeButton.TextColor3 = WHITE
closeButton.TextStrokeColor3 = CHOC
closeButton.TextStrokeTransparency = 0
closeButton.ZIndex = 8
closeButton.Parent = root
corner(closeButton, UDim.new(1, 0))
stroke(closeButton, 3, CHOC)
aspect(closeButton, 1)
if skin(closeButton, "CloseButton") then closeButton.Text = "" end
bouncy(closeButton)

--// COIN PILL (right end of the tab row): wallet + a + that opens Coins
local pill = Instance.new("Frame")
pill.Name = "CoinPill"
pill.AnchorPoint = Vector2.new(1, 0)
pill.Position = UDim2.fromScale(0.95, 0.18)
pill.Size = UDim2.fromScale(0.22, 0.075)
pill.BackgroundColor3 = CREAM
pill.ZIndex = 4
pill.Parent = root
corner(pill, UDim.new(1, 0))
stroke(pill, 3, CHOC)
local pillScale = Instance.new("UIScale")
pillScale.Parent = pill
--// the coin icon is ART, not the 🪙 emoji - FredokaOne can't draw that one
--// (it rendered as an empty box)
local pillCoin = fxImage(pill, "FlyingCoin", "CoinIcon")
if pillCoin then
	pillCoin.AnchorPoint = Vector2.new(0, 0.5)
	pillCoin.Position = UDim2.fromScale(0.05, 0.5)
	pillCoin.Size = UDim2.fromScale(0.18, 0.78)
	pillCoin.ZIndex = 5
	aspect(pillCoin, 1)
end
local coinText = label(pill, "Coins", Enum.Font.FredokaOne, CHOC, 30)
coinText.Position = UDim2.fromScale(pillCoin and 0.22 or 0.07, 0.1)
coinText.Size = UDim2.fromScale(pillCoin and 0.52 or 0.66, 0.8)
coinText.TextXAlignment = Enum.TextXAlignment.Left
coinText.Text = "-"
coinText.ZIndex = 5
local plus = Instance.new("TextButton")
plus.Name = "AddCoins"
plus.AnchorPoint = Vector2.new(1, 0.5)
plus.Position = UDim2.fromScale(0.97, 0.5)
plus.Size = UDim2.fromScale(0.24, 0.84)
plus.BackgroundColor3 = MUSTARD
plus.Font = Enum.Font.FredokaOne
plus.TextScaled = true
plus.Text = "+"
plus.TextColor3 = WHITE
plus.TextStrokeColor3 = CHOC
plus.TextStrokeTransparency = 0
plus.ZIndex = 5
plus.Parent = pill
corner(plus, UDim.new(1, 0))
stroke(plus, 2, CHOC)
aspect(plus, 1)
bouncy(plus)

--// CONTENT: one page per tab, under the tab row
local CONTENT_HOME = UDim2.fromScale(0.5, 0.29)
local content = Instance.new("Frame")
content.Name = "Content"
content.AnchorPoint = Vector2.new(0.5, 0)
content.Position = CONTENT_HOME
content.Size = UDim2.fromScale(0.88, 0.635)
content.BackgroundTransparency = 1
content.ZIndex = 2
content.Parent = root

--// TOAST: a short line that pops under the panel
local toast = label(root, "Toast", Enum.Font.FredokaOne, WHITE, 30)
toast.AnchorPoint = Vector2.new(0.5, 0.5)
toast.Position = UDim2.fromScale(0.5, 1.05)
toast.Size = UDim2.fromScale(0.5, 0.08)
toast.BackgroundColor3 = BASIL
toast.BackgroundTransparency = 0
toast.Visible = false
toast.ZIndex = 9
stickerText(toast)
corner(toast, UDim.new(1, 0))
stroke(toast, 3, CHOC)
local toastScale = Instance.new("UIScale")
toastScale.Parent = toast
local toastToken = 0
local function showToast(text, color)
	toastToken += 1
	local mine = toastToken
	toast.Text = text
	toast.BackgroundColor3 = color or BASIL
	toast.Visible = true
	toast.Rotation = -2
	toastScale.Scale = 0.6
	TweenService:Create(toastScale, TweenInfo.new(0.25, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(2.4, function()
		if toastToken == mine then toast.Visible = false end
	end)
end

----------------------------------------------------------------
-- Prices (live from Roblox, display only) + ownership
----------------------------------------------------------------
local priceCache = {} --// [kind:id] = robux (false = lookup failed)
local function fetchPrice(kind, id, onPrice)
	local key = kind .. ":" .. id
	if priceCache[key] ~= nil then
		onPrice(priceCache[key])
		return
	end
	task.spawn(function()
		local infoType = kind == "pass" and Enum.InfoType.GamePass or Enum.InfoType.Product
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, infoType)
		local price = ok and info and info.PriceInRobux or false
		priceCache[key] = price
		onPrice(price)
	end)
end

local function ownsPass(passKey)
	return player:GetAttribute("Pass_" .. passKey) == true --// display only
end

----------------------------------------------------------------
-- The purchase remote (the server's - it may arrive a moment late)
----------------------------------------------------------------
local purchaseRemote = nil
local refreshAll -- forward declared (built with the cards below)
local onServerMessage

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	purchaseRemote = remotes and remotes:WaitForChild("PurchaseRemote", 30)
	if purchaseRemote then
		purchaseRemote.OnClientEvent:Connect(function(...)
			onServerMessage(...)
		end)
	else
		warn("[Shop] no PurchaseRemote - is the lobby's PurchaseBoot running?")
	end
end)

local lastAsk = 0
local lastBuyButton = nil --// where the coin shower starts from
local function askToBuy(key, def, fromButton)
	if (def.Id or 0) <= 0 then
		showToast("Coming soon!", MUSTARD)
		return
	end
	if not purchaseRemote then
		showToast("The shop is still loading...", MUSTARD)
		return
	end
	if os.clock() - lastAsk < 1 then return end
	lastAsk = os.clock()
	lastBuyButton = fromButton
	--// ONLY asks for Roblox's purchase window. The server decides; Roblox pays.
	purchaseRemote:FireServer("Prompt", key)
end

----------------------------------------------------------------
-- Cards
----------------------------------------------------------------
local cards = {} --// every card's refresh function

--// the price pill: green to buy, grey when not on sale yet, OWNED when done
local function priceButton(parent, kind, key, def)
	local holder = Instance.new("Frame")
	holder.Name = "PriceHolder"
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	--// the darker "lip" under the pill that makes it look pressable
	local lip = Instance.new("Frame")
	lip.Name = "Lip"
	lip.Position = UDim2.fromScale(0, 0.12)
	lip.Size = UDim2.fromScale(1, 1)
	lip.BackgroundColor3 = BASIL_DARK
	lip.Parent = holder
	corner(lip, UDim.new(1, 0))

	local button = Instance.new("TextButton")
	button.Name = "Buy"
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = BASIL
	button.AutoButtonColor = false
	button.Text = "" --// the price lives in its own label ABOVE the art; a
	                 --// button's own text would render underneath its art
	button.ZIndex = 2
	button.Parent = holder
	corner(button, UDim.new(1, 0))
	stroke(button, 3, CHOC)
	local skinned = skin(button, "PriceButtonGreen")
	if skinned then lip:Destroy() end
	bouncy(button)

	--// no UIPadding on the button itself - padding would squash the art too
	local priceText = label(button, "PriceText", Enum.Font.FredokaOne, WHITE, 30)
	priceText.AnchorPoint = Vector2.new(0.5, 0.5)
	priceText.Position = UDim2.fromScale(0.5, 0.44)
	priceText.Size = UDim2.fromScale(0.82, 0.56)
	priceText.Text = "..."
	priceText.ZIndex = 3
	stickerText(priceText)

	button.Activated:Connect(function()
		if kind == "pass" and ownsPass(key) then return end
		askToBuy(key, def, button)
	end)

	--// the art is green; "not on sale yet" greys it with a tint
	local art = button:FindFirstChild("Art")
	local function tint(color)
		if art then art.ImageColor3 = color end
	end

	local function refresh()
		if kind == "pass" and ownsPass(key) then
			priceText.Text = "OWNED ✓"
			tint(Color3.fromRGB(200, 220, 200))
			if not skinned then
				button.BackgroundColor3 = BASIL_DARK
				lip.BackgroundColor3 = CHOC
			end
			return
		end
		if (def.Id or 0) <= 0 then
			priceText.Text = "SOON"
			tint(Color3.fromRGB(165, 160, 155))
			if not skinned then
				button.BackgroundColor3 = GREY
				lip.BackgroundColor3 = GREY_DARK
			end
			return
		end
		tint(WHITE)
		if not skinned then
			button.BackgroundColor3 = BASIL
			lip.BackgroundColor3 = BASIL_DARK
		end
		fetchPrice(kind, def.Id, function(price)
			priceText.Text = price and ("R$ " .. commas(price)) or "BUY"
		end)
	end
	table.insert(cards, refresh)
	return holder
end

--// the framed menu card every item sits on; it lifts a little on hover
local function cardFrame(parent, name)
	local card = Instance.new("Frame")
	card.Name = name
	card.BackgroundColor3 = CREAM
	card.Parent = parent
	corner(card, UDim.new(0, 16))
	stroke(card, 4, WOOD)
	local inner = Instance.new("Frame")
	inner.Name = "Placeholder"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.new(1, -10, 1, -10)
	inner.BackgroundTransparency = 1
	inner.Parent = card
	corner(inner, UDim.new(0, 12))
	stroke(inner, 2, MUSTARD)
	local glow = Instance.new("Frame")
	glow.Name = "Spotlight"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.BackgroundColor3 = WHITE
	glow.BackgroundTransparency = 0.25
	glow.Parent = inner
	corner(glow, UDim.new(1, 0))
	skin(card, "ItemCard")

	--// the art kit's soft glow replaces the code spotlight (callers place it)
	local glowArt = fxImage(card, "SoftGlow", "Spotlight")
	if glowArt then
		if glow.Parent then glow:Destroy() end
		glow = glowArt
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.ZIndex = 1
		aspect(glow, 1)
	end

	local lift = Instance.new("UIScale")
	lift.Parent = card
	card.MouseEnter:Connect(function()
		TweenService:Create(lift, QUICK, { Scale = 1.03 }):Play()
	end)
	card.MouseLeave:Connect(function()
		TweenService:Create(lift, QUICK, { Scale = 1 }):Play()
	end)
	return card, glow
end

--// a live sticker on the art (e.g. "2x" on the 2x Coins badge)
local function badgeSticker(parent, text)
	local sticker = label(parent, "Badge", Enum.Font.FredokaOne, WHITE)
	sticker.AnchorPoint = Vector2.new(0.5, 0.5)
	sticker.BackgroundTransparency = 0
	sticker.BackgroundColor3 = TOMATO
	sticker.Rotation = 12
	sticker.Text = text
	sticker.ZIndex = 4
	stickerText(sticker)
	corner(sticker, UDim.new(1, 0))
	stroke(sticker, 3, CHOC)
	aspect(sticker, 1.3)
	return sticker
end

--// a regular card: art on top, name, detail line, price pill
local function smallCard(parent, kind, key, def, order)
	local card, glow = cardFrame(parent, key)
	card.LayoutOrder = order
	glow.Position = UDim2.fromScale(0.5, 0.31)
	glow.Size = UDim2.fromScale(0.86, 0.56)

	local art = itemArt(card, def)
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.28)
	art.Size = UDim2.fromScale(0.58, 0.36)
	art.ZIndex = 2
	floatArt(art, order * 0.25)

	if def.Badge then
		local sticker = badgeSticker(card, def.Badge)
		sticker.Position = UDim2.fromScale(0.74, 0.16)
		sticker.Size = UDim2.fromScale(0.26, 0.12)
	end

	local nameText = label(card, "ItemName", Enum.Font.FredokaOne, CHOC, 28)
	nameText.Position = UDim2.fromScale(0.08, 0.48)
	nameText.Size = UDim2.fromScale(0.84, 0.12)
	nameText.Text = def.Display
	nameText.ZIndex = 2

	local detail = label(card, "Detail", Enum.Font.GothamBold, WOOD_DARK, 20)
	detail.Position = UDim2.fromScale(0.1, 0.6)
	detail.Size = UDim2.fromScale(0.8, 0.1)
	detail.Text = def.Coins and (commas(def.Coins) .. " coins") or (def.Description or "")
	detail.ZIndex = 2

	local price = priceButton(card, kind, key, def)
	price.AnchorPoint = Vector2.new(0.5, 1)
	price.Position = UDim2.fromScale(0.5, 0.94)
	price.Size = UDim2.fromScale(0.82, 0.2) --// was squashed
	price.ZIndex = 2

	--// EFFECT: an owned pass gets the OWNED stamp slammed across its art
	if kind == "pass" then
		local stamp = fxImage(card, "OwnedStamp", "OwnedStamp")
		if not stamp then
			stamp = Instance.new("Frame")
			stamp.Name = "OwnedStamp"
			stamp.BackgroundTransparency = 1
			stamp.Parent = card
			stroke(stamp, 4, BASIL)
			corner(stamp, UDim.new(0, 10))
		end
		stamp.AnchorPoint = Vector2.new(0.5, 0.5)
		stamp.Position = UDim2.fromScale(0.5, 0.34)
		stamp.Size = UDim2.fromScale(0.86, 0.22)
		stamp.Rotation = -10
		stamp.ZIndex = 4
		stamp.Visible = false
		aspect(stamp, 2)
		local stampText = label(stamp, "Text", Enum.Font.FredokaOne, BASIL)
		stampText.AnchorPoint = Vector2.new(0.5, 0.5)
		stampText.Position = UDim2.fromScale(0.5, 0.5)
		stampText.Size = UDim2.fromScale(0.7, 0.5)
		stampText.Text = "OWNED"
		stampText.ZIndex = 5
		local stampScale = Instance.new("UIScale")
		stampScale.Parent = stamp

		table.insert(cards, function()
			local owned = ownsPass(key)
			if owned and not stamp.Visible and isOpen then
				--// the slam: big and late, then thumps down into place
				stampScale.Scale = 2.2
				TweenService:Create(stampScale, TweenInfo.new(0.3, Enum.EasingStyle.Back,
					Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
			stamp.Visible = owned
		end)
	end
	return card
end

--// sort a Config table into a list by Order
local function sorted(tbl)
	local list = {}
	for key, def in pairs(tbl) do
		table.insert(list, { Key = key, Def = def })
	end
	table.sort(list, function(a, b)
		return (a.Def.Order or 99) < (b.Def.Order or 99)
	end)
	return list
end

----------------------------------------------------------------
-- COINS page: the featured best-value pack + a row of the rest
----------------------------------------------------------------
local pages = {}

local coinsPage = Instance.new("Frame")
coinsPage.Name = "CoinsPage"
coinsPage.Size = UDim2.fromScale(1, 1)
coinsPage.BackgroundTransparency = 1
coinsPage.Parent = content
pages.Coins = coinsPage

local featuredEntry, rowEntries = nil, {}
for _, entry in ipairs(sorted(MON.Products)) do
	if entry.Def.Featured and not featuredEntry then
		featuredEntry = entry
	else
		table.insert(rowEntries, entry)
	end
end

local shineGradient, rays, twinkles = nil, nil, {}
local shineStreak = nil
local featuredPriceScale = nil
if featuredEntry then
	local def = featuredEntry.Def
	local card, glow = cardFrame(coinsPage, featuredEntry.Key)
	card.Size = UDim2.fromScale(1, 0.5)
	card.ClipsDescendants = true
	glow.Position = UDim2.fromScale(0.36, 0.5)
	glow.Size = UDim2.fromScale(0.38, 1.05)

	--// EFFECT: a slow sunburst behind the pack (the art kit's, else code rays)
	rays = fxImage(card, "Sunburst", "Sunburst") or Instance.new("Frame")
	rays.Name = "Sunburst"
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.36, 0.5)
	rays.Size = UDim2.fromScale(0.56, 1.8)
	rays.BackgroundTransparency = 1
	rays.ZIndex = 1
	rays.Parent = card
	aspect(rays, 1)
	for i = 0, (rays:IsA("ImageLabel") and -1 or 7) do
		local ray = Instance.new("Frame")
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Size = UDim2.fromScale(0.09, 1)
		ray.BackgroundColor3 = (i % 2 == 0) and MUSTARD or WHITE
		ray.Rotation = i * 22.5
		ray.BorderSizePixel = 0
		ray.ZIndex = 1
		ray.Parent = rays
		local fade = Instance.new("UIGradient")
		fade.Rotation = 90
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		})
		fade.Parent = ray
	end

	--// the ribbon hanging on the left
	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.Position = UDim2.fromScale(0.025, -0.02)
	ribbon.Size = UDim2.fromScale(0.14, 0.86)
	ribbon.BackgroundColor3 = TOMATO
	ribbon.ZIndex = 3
	ribbon.Parent = card
	corner(ribbon, UDim.new(0, 8))
	stroke(ribbon, 3, MUSTARD)
	if skin(ribbon, "ValueRibbon") then
		aspect(ribbon, 256 / 384)
	end
	local ribbonText = label(ribbon, "Text", Enum.Font.FredokaOne, WHITE, 30)
	ribbonText.Position = UDim2.fromScale(0.1, 0.14)
	ribbonText.Size = UDim2.fromScale(0.8, 0.56)
	ribbonText.Text = MON.FeaturedRibbonText or "BEST VALUE!"
	ribbonText.ZIndex = 4
	stickerText(ribbonText)
	ribbon.Rotation = -2
	TweenService:Create(ribbon, TweenInfo.new(1.6, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true), { Rotation = 2 }):Play()

	local art = itemArt(card, def)
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.36, 0.5)
	art.Size = UDim2.fromScale(0.26, 0.8)
	art.ZIndex = 2
	floatArt(art, 0)

	--// EFFECT: twinkling sparkles around the pack
	local spots = { { 0.25, 0.2 }, { 0.48, 0.15 }, { 0.23, 0.78 }, { 0.5, 0.8 }, { 0.46, 0.5 } }
	for i, spot in ipairs(spots) do
		local star = fxImage(card, "Sparkle", "Twinkle" .. i)
		if star then
			aspect(star, 1)
		else
			star = label(card, "Twinkle" .. i, Enum.Font.FredokaOne, i % 2 == 0 and MUSTARD or WHITE)
			star.Text = "✦"
			star.TextStrokeColor3 = CHOC
			star.TextStrokeTransparency = 0.4
		end
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Position = UDim2.fromScale(spot[1], spot[2])
		star.Size = UDim2.fromScale(0.06, 0.2)
		star.ZIndex = 3
		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = star
		table.insert(twinkles, scale)
	end

	local nameText = label(card, "ItemName", Enum.Font.FredokaOne, CHOC, 42)
	nameText.Position = UDim2.fromScale(0.54, 0.14)
	nameText.Size = UDim2.fromScale(0.42, 0.22)
	nameText.Text = def.Display
	nameText.ZIndex = 2

	local detail = label(card, "Detail", Enum.Font.FredokaOne, WOOD_DARK, 32)
	detail.Position = UDim2.fromScale(0.56, 0.37)
	detail.Size = UDim2.fromScale(0.38, 0.16)
	detail.Text = commas(def.Coins or 0) .. " coins"
	detail.ZIndex = 2

	local price = priceButton(card, "product", featuredEntry.Key, def)
	price.Position = UDim2.fromScale(0.57, 0.58)
	price.Size = UDim2.fromScale(0.36, 0.25)
	price.ZIndex = 2
	--// EFFECT: the best-value button breathes
	featuredPriceScale = Instance.new("UIScale")
	featuredPriceScale.Parent = price
	TweenService:Create(featuredPriceScale, TweenInfo.new(0.9, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true), { Scale = 1.05 }):Play()

	--// EFFECT: a light streak sweeps across the card (the art kit's streak,
	--// else a code gradient band)
	shineStreak = fxImage(card, "ShineStreak", "Shine")
	if shineStreak then
		shineStreak.AnchorPoint = Vector2.new(0.5, 0.5)
		shineStreak.Position = UDim2.fromScale(-0.3, 0.5)
		shineStreak.Size = UDim2.fromScale(0.25, 1.6)
		shineStreak.ScaleType = Enum.ScaleType.Stretch
		shineStreak.ImageTransparency = 0.25
		shineStreak.ZIndex = 5
	end
	local shine = Instance.new("Frame")
	shine.Name = "ShineBand"
	shine.Size = UDim2.fromScale(1, 1)
	shine.BackgroundColor3 = WHITE
	shine.BackgroundTransparency = shineStreak and 1 or 0
	shine.ZIndex = 5
	shine.Parent = card
	shineGradient = Instance.new("UIGradient")
	shineGradient.Rotation = 20
	shineGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.45, 1),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	shineGradient.Offset = Vector2.new(-1, 0)
	shineGradient.Parent = shine
end

local row = Instance.new("Frame")
row.Name = "Row"
row.Position = UDim2.fromScale(0, featuredEntry and 0.55 or 0)
row.Size = UDim2.fromScale(1, featuredEntry and 0.43 or 1) --// a margin above the frame bottom
row.BackgroundTransparency = 1
row.Parent = coinsPage
local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Horizontal
rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowLayout.Padding = UDim.new(0.02, 0)
rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowLayout.Parent = row
local rowWidth = math.min(0.32, (1 - 0.02 * math.max(#rowEntries - 1, 0)) / math.max(#rowEntries, 1))
for i, entry in ipairs(rowEntries) do
	local card = smallCard(row, "product", entry.Key, entry.Def, i)
	card.Size = UDim2.fromScale(rowWidth, 1)
end

----------------------------------------------------------------
-- PASSES page: the passes side by side
----------------------------------------------------------------
local passesPage = Instance.new("Frame")
passesPage.Name = "PassesPage"
passesPage.Size = UDim2.fromScale(1, 1)
passesPage.BackgroundTransparency = 1
passesPage.Visible = false
passesPage.Parent = content
pages.Passes = passesPage

local passLayout = Instance.new("UIListLayout")
passLayout.FillDirection = Enum.FillDirection.Horizontal
passLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
passLayout.VerticalAlignment = Enum.VerticalAlignment.Center
passLayout.Padding = UDim.new(0.05, 0)
passLayout.SortOrder = Enum.SortOrder.LayoutOrder
passLayout.Parent = passesPage
local passList = sorted(MON.GamePasses)
local passWidth = math.min(0.36, (1 - 0.05 * math.max(#passList - 1, 0)) / math.max(#passList, 1))
for i, entry in ipairs(passList) do
	local card = smallCard(passesPage, "pass", entry.Key, entry.Def, i)
	card.Size = UDim2.fromScale(passWidth, 0.96)
end

----------------------------------------------------------------
-- TABS: a row of top tabs over the content (the tab art is shaped for it)
----------------------------------------------------------------
local TABS = {
	{ Key = "Coins", Label = "COINS", Emoji = "🪙", Icon = "TabIconCoins" },
	{ Key = "Passes", Label = "PASSES", Emoji = "🎟️", Icon = "TabIconPasses" },
}

local tabRow = Instance.new("Frame")
tabRow.Name = "Tabs"
tabRow.Position = UDim2.fromScale(0.06, 0.16)
tabRow.Size = UDim2.fromScale(0.6, 0.12) --// bigger, easier-to-hit tabs
tabRow.BackgroundTransparency = 1
tabRow.ZIndex = 4
tabRow.Parent = root
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0.015, 0)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
tabLayout.Parent = tabRow

local tabButtons = {}
local currentTab = "Coins"

local function setTabLook(tab, selected)
	local art = tab:FindFirstChild("Art")
	local want = artId(selected and "TabSelected" or "TabNormal")
	if art and want then
		art.Image = want
	elseif not art then
		tab.BackgroundColor3 = selected and MUSTARD or CREAM
	end
end

local function selectTab(key, animate)
	local changed = key ~= currentTab
	currentTab = key
	for pageKey, page in pairs(pages) do
		page.Visible = pageKey == key
		if pageKey == key and animate and changed then
			--// EFFECT: the new page slides up into place
			page.Position = UDim2.fromScale(0, 0.06)
			TweenService:Create(page, TweenInfo.new(0.22, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { Position = UDim2.fromScale(0, 0) }):Play()
		end
	end
	for tabKey, tab in pairs(tabButtons) do
		setTabLook(tab, tabKey == key)
	end
end

for i, def in ipairs(TABS) do
	local tab = Instance.new("TextButton")
	tab.Name = def.Key .. "Tab"
	tab.LayoutOrder = i
	tab.Size = UDim2.fromScale(0.36, 1)
	tab.BackgroundColor3 = CREAM
	tab.AutoButtonColor = false
	tab.Text = ""
	tab.ZIndex = 4
	tab.Parent = tabRow
	corner(tab, UDim.new(0, 14))
	stroke(tab, 3, CHOC)
	aspect(tab, 2)
	skin(tab, "TabNormal")

	local iconId = artId(def.Icon)
	local icon
	if iconId then
		icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = iconId
		icon.Parent = tab
	else
		icon = label(tab, "Icon", Enum.Font.FredokaOne, CHOC)
		icon.Text = def.Emoji
	end
	icon.Position = UDim2.fromScale(0.1, 0.18)
	icon.Size = UDim2.fromScale(0.28, 0.62)
	icon.ZIndex = 5

	local tabText = label(tab, "Label", Enum.Font.FredokaOne, WHITE, 26)
	tabText.Position = UDim2.fromScale(0.4, 0.24)
	tabText.Size = UDim2.fromScale(0.52, 0.5)
	tabText.Text = def.Label
	tabText.ZIndex = 5
	stickerText(tabText)

	bouncy(tab)
	tab.Activated:Connect(function()
		selectTab(def.Key, true)
	end)
	tabButtons[def.Key] = tab
end

----------------------------------------------------------------
-- Coins readout (leaderstats.Wallet is the server's mirror)
----------------------------------------------------------------
local function walletValue()
	local stats = player:FindFirstChild("leaderstats")
	return stats and stats:FindFirstChild("Wallet")
end

local shownCoins = nil
local function popPill()
	pillScale.Scale = 1.25
	TweenService:Create(pillScale, TweenInfo.new(0.3, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function refreshCoins(pop)
	local wallet = walletValue()
	local amount = wallet and wallet.Value
	coinText.Text = amount and commas(amount) or "-"
	if pop and shownCoins and amount and amount > shownCoins then
		coinText.TextColor3 = BASIL
		task.delay(0.6, function() coinText.TextColor3 = CHOC end)
	end
	shownCoins = amount
end

task.spawn(function()
	local stats = player:WaitForChild("leaderstats", 30)
	local wallet = stats and stats:WaitForChild("Wallet", 30)
	if wallet then
		wallet.Changed:Connect(function() refreshCoins(true) end)
	end
	refreshCoins(false)
end)

refreshAll = function()
	for _, refresh in ipairs(cards) do
		refresh()
	end
	refreshCoins(false)
end

player.AttributeChanged:Connect(function(attribute)
	if string.sub(attribute, 1, 5) == "Pass_" then
		refreshAll()
	end
end)

----------------------------------------------------------------
-- EFFECT: the coin shower - coins burst out of the button you pressed and
-- fly into the coin counter, which pops when they land
----------------------------------------------------------------
local function coinShower(fromGui, symbol)
	if not gui.Enabled then return end
	local inset = Vector2.zero --// IgnoreGuiInset: AbsolutePosition is screen space
	local function centre(g)
		return g.AbsolutePosition + g.AbsoluteSize / 2 + inset
	end
	local startAt = fromGui and fromGui.Parent and centre(fromGui) or centre(pill)
	local endAt = centre(pill)
	--// real coins for coins, sparkles for a pass
	local coinArt = symbol and artId("Sparkle") or (artId("FlyingCoin") or artId("TabIconCoins"))
	for i = 1, 12 do
		local coin
		if coinArt then
			coin = Instance.new("ImageLabel")
			coin.BackgroundTransparency = 1
			coin.Image = coinArt
			coin.ScaleType = Enum.ScaleType.Fit
		else
			coin = Instance.new("TextLabel")
			coin.BackgroundTransparency = 1
			coin.Font = Enum.Font.FredokaOne
			coin.TextScaled = true
			coin.Text = symbol or "🪙"
			coin.TextColor3 = MUSTARD
			coin.TextStrokeColor3 = CHOC
			coin.TextStrokeTransparency = 0.3
		end
		coin.AnchorPoint = Vector2.new(0.5, 0.5)
		coin.Size = UDim2.fromOffset(34, 34)
		coin.Position = UDim2.fromOffset(startAt.X, startAt.Y)
		coin.ZIndex = 20
		coin.Parent = gui
		local angle = math.random() * math.pi * 2
		local burst = startAt + Vector2.new(math.cos(angle), math.sin(angle)) * math.random(40, 110)
		task.delay(i * 0.035, function()
			local out = TweenService:Create(coin, TweenInfo.new(0.25, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { Position = UDim2.fromOffset(burst.X, burst.Y) })
			out:Play()
			out.Completed:Wait()
			local fly = TweenService:Create(coin, TweenInfo.new(0.45, Enum.EasingStyle.Quad,
				Enum.EasingDirection.In), {
					Position = UDim2.fromOffset(endAt.X, endAt.Y),
					Size = UDim2.fromOffset(18, 18),
				})
			fly:Play()
			fly.Completed:Wait()
			coin:Destroy()
			popPill()
		end)
	end
end

--// EFFECT: confetti bursts out of the button you pressed, and a pop star
--// flares behind the toast
local popBurst = fxImage(root, "PopBurst", "PopBurst")
if popBurst then
	popBurst.AnchorPoint = Vector2.new(0.5, 0.5)
	popBurst.Position = toast.Position
	popBurst.Size = UDim2.fromScale(0.3, 0.3)
	popBurst.ZIndex = 8 --// just under the toast
	popBurst.Visible = false
	aspect(popBurst, 1)
end

local function celebrate(fromGui)
	if not gui.Enabled then return end
	local id = artId("Confetti")
	if id then
		local at = (fromGui and fromGui.Parent) and (fromGui.AbsolutePosition + fromGui.AbsoluteSize / 2)
			or (root.AbsolutePosition + root.AbsoluteSize / 2)
		for burst = 1, 2 do
			local confetti = Instance.new("ImageLabel")
			confetti.Name = "Confetti"
			confetti.BackgroundTransparency = 1
			confetti.Image = id
			confetti.ScaleType = Enum.ScaleType.Fit
			confetti.AnchorPoint = Vector2.new(0.5, 0.5)
			confetti.Position = UDim2.fromOffset(at.X, at.Y)
			confetti.Size = UDim2.fromOffset(60, 60)
			confetti.Rotation = burst * 45
			confetti.ZIndex = 19
			confetti.Parent = gui
			local grow = TweenService:Create(confetti, TweenInfo.new(1, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(380 - burst * 60, 380 - burst * 60),
					Rotation = confetti.Rotation + (burst == 1 and 90 or -70),
					ImageTransparency = 1,
				})
			grow:Play()
			grow.Completed:Connect(function() confetti:Destroy() end)
		end
	end
	if popBurst then
		popBurst.Visible = true
		popBurst.Rotation = 0
		local scale = popBurst:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = popBurst
		scale.Scale = 0.2
		TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(popBurst, TweenInfo.new(2.4, Enum.EasingStyle.Linear),
			{ Rotation = 40 }):Play()
		local mine = toastToken
		task.delay(2.4, function()
			if toastToken == mine then popBurst.Visible = false end
		end)
	end
end

onServerMessage = function(action, key)
	if action == "ProductGranted" then
		local def = MON.Products[key]
		sfx("ShopPurchase")
		showToast(def and def.Coins and ("+" .. commas(def.Coins) .. " coins!") or "Thank you!", BASIL)
		coinShower(lastBuyButton)
		celebrate(lastBuyButton)
		refreshCoins(true)
	elseif action == "PassOwned" then
		local def = MON.GamePasses[key]
		sfx("ShopPurchase")
		showToast(("You own %s!"):format(def and def.Display or "it"), BASIL)
		coinShower(lastBuyButton, "✦")
		celebrate(lastBuyButton)
		refreshAll() --// the OWNED stamp slams down here
	end
end

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------
local loopToken = 0

--// the looping effects run only while the shop is open
local function startLoops()
	loopToken += 1
	local mine = loopToken
	if shineStreak then
		task.spawn(function()
			while isOpen and loopToken == mine do
				shineStreak.Position = UDim2.fromScale(-0.3, 0.5)
				local sweep = TweenService:Create(shineStreak,
					TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Position = UDim2.fromScale(1.3, 0.5) })
				sweep:Play()
				sweep.Completed:Wait()
				task.wait(2)
			end
		end)
	elseif shineGradient then
		task.spawn(function()
			while isOpen and loopToken == mine do
				shineGradient.Offset = Vector2.new(-1, 0)
				local sweep = TweenService:Create(shineGradient,
					TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Offset = Vector2.new(1, 0) })
				sweep:Play()
				sweep.Completed:Wait()
				task.wait(2)
			end
		end)
	end
	--// the bistro bulbs twinkle out of step with each other
	for i, glow in ipairs(bulbGlows) do
		task.spawn(function()
			task.wait(i * 0.17)
			while isOpen and loopToken == mine do
				local dim = TweenService:Create(glow, TweenInfo.new(0.5 + math.random() * 0.6,
					Enum.EasingStyle.Sine), { ImageTransparency = 0.75 })
				dim:Play()
				dim.Completed:Wait()
				local bright = TweenService:Create(glow, TweenInfo.new(0.5 + math.random() * 0.6,
					Enum.EasingStyle.Sine), { ImageTransparency = 0.2 })
				bright:Play()
				bright.Completed:Wait()
			end
		end)
	end
	--// steam curls up off the coffee and fades, over and over
	if steam then
		local home = steam.Position
		task.spawn(function()
			while isOpen and loopToken == mine do
				steam.Position = home
				steam.ImageTransparency = 0.15
				local rise = TweenService:Create(steam, TweenInfo.new(1.8, Enum.EasingStyle.Sine,
					Enum.EasingDirection.Out), {
						Position = home - UDim2.fromScale(0, 0.06),
						ImageTransparency = 1,
					})
				rise:Play()
				rise.Completed:Wait()
				task.wait(0.4)
			end
		end)
	end
	if rays then
		task.spawn(function()
			while isOpen and loopToken == mine do
				rays.Rotation = (rays.Rotation + 0.4) % 360
				task.wait(1 / 30)
			end
		end)
	end
	for i, scale in ipairs(twinkles) do
		task.spawn(function()
			task.wait(i * 0.4)
			while isOpen and loopToken == mine do
				local up = TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back,
					Enum.EasingDirection.Out), { Scale = 1 })
				up:Play()
				up.Completed:Wait()
				local down = TweenService:Create(scale, TweenInfo.new(0.3), { Scale = 0 })
				down:Play()
				down.Completed:Wait()
				task.wait(0.8 + math.random() * 1.6)
			end
		end)
	end
end

local function setOpen(open)
	if open == isOpen then return end
	isOpen = open
	if open then
		refreshAll()
		selectTab(currentTab, false)
		gui.Enabled = true
		blur.Enabled = true
		rootScale.Scale = 0.85
		backdrop.BackgroundTransparency = 1
		TweenService:Create(rootScale, TweenInfo.new(0.28, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(backdrop, TweenInfo.new(0.2), { BackgroundTransparency = 0.5 }):Play()
		TweenService:Create(blur, TweenInfo.new(0.25), { Size = 14 }):Play()
		--// EFFECT: the awning drops in from above
		header.Position = HEADER_HOME - UDim2.fromScale(0, 0.25)
		TweenService:Create(header, TweenInfo.new(0.45, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Position = HEADER_HOME }):Play()
		startLoops()
	else
		TweenService:Create(backdrop, TweenInfo.new(0.15), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(blur, TweenInfo.new(0.15), { Size = 0 }):Play()
		local shrink = TweenService:Create(rootScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad,
			Enum.EasingDirection.In), { Scale = 0.88 })
		shrink:Play()
		shrink.Completed:Connect(function()
			if not isOpen then
				gui.Enabled = false
				blur.Enabled = false
			end
		end)
	end
end

closeButton.Activated:Connect(function() setOpen(false) end)
backdrop.Activated:Connect(function() setOpen(false) end)
plus.Activated:Connect(function() selectTab("Coins", true) end)

--// THE SHOP! STICKER: OpenShopButton lives in a Studio-built ScreenGui, which
--// can be re-cloned on respawn - bind every copy that ever appears.
local bound = {}
local function bindOpenButton(inst)
	if inst.Name ~= "OpenShopButton" or not inst:IsA("GuiButton") or bound[inst] then return end
	bound[inst] = true
	inst.Activated:Connect(function()
		sfx("ShopClick")
		setOpen(not isOpen)
	end)
	print(("[Shop] opens from %s"):format(inst:GetFullName()))
end
for _, inst in ipairs(playerGui:GetDescendants()) do
	bindOpenButton(inst)
end
playerGui.DescendantAdded:Connect(bindOpenButton)

selectTab("Coins", false)
print("[Shop] ready")
