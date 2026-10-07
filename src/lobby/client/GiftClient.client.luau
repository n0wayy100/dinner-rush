--[[
	Dinner Rush - GiftClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.GiftClient  (LocalScript)

	THE FREE! screen (Oct 2026): a present-wrapped panel with two tabs.

	  GIFT   the daily free gift: a 7-day ladder (claim on days in a row to
	         climb it, a missed day starts over), a big present that shakes,
	         pops its lid and bursts coins when opened; locked until tomorrow
	         once claimed
	  CODES  the promo code box (was its own CODES! button)

	Opens from the owner's FREE! dock button, OpenGiftButton. Render only:
	DailyRemote "Gift" / "Redeem" -> ProfileAPI decides, and the code list
	itself never reaches the client.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(Shared:WaitForChild("UIKit"))
local DAILY = Config.Daily
if not DAILY then return end

local SfxLocal = nil
pcall(function() SfxLocal = require(Shared:WaitForChild("SfxLocal", 5)) end)

local C = UIKit.Colors
local kit = UIKit.artKit(DAILY.Art, Config.Passives and Config.Passives.Art,
	Config.Monetization and Config.Monetization.ShopArt)
local corner, stroke, label, stickerText, aspect = UIKit.corner, UIKit.stroke,
	UIKit.label, UIKit.stickerText, UIKit.aspect

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DailyRemote", 30)
if not remote then return end

local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then pcall(SfxLocal.Play, name) end
end

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function sprite(parent, slot, name)
	local img = Instance.new("ImageLabel")
	img.Name = name or slot
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Image = kit.id(slot) or ""
	img.Parent = parent
	return img
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d:%02d"):format(seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

local function bigButton(parent, text, color, slot)
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.BackgroundColor3 = color
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent
	corner(button, UDim.new(0.3, 0))
	stroke(button, 3.5, C.Choc)
	if slot then kit.skin(button, slot) end
	local t = label(button, "Text")
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.fromScale(0.5, 0.46)
	t.Size = UDim2.fromScale(0.82, 0.58)
	t.Text = text
	t.ZIndex = 4
	stickerText(t)
	UIKit.bouncy(button)
	return button, t
end

----------------------------------------------------------------
-- The panel
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Gift_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 36
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local blur = Instance.new("BlurEffect")
blur.Name = "GiftBlur"
blur.Size = 0
blur.Enabled = false
blur.Parent = Lighting

local backdrop = Instance.new("TextButton")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 1
backdrop.AutoButtonColor = false
backdrop.Text = ""
backdrop.Parent = gui

local root = Instance.new("Frame")
root.Name = "MainPanel"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.5, 0.55)
root.Size = UDim2.fromScale(0.6, 0.76)
root.BackgroundTransparency = 1
root.Parent = gui
aspect(root, 1.3)
local rootScale = Instance.new("UIScale")
rootScale.Parent = root

local panel = Instance.new("Frame")
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = C.Cream
panel.Parent = root
corner(panel, UDim.new(0, 22))
stroke(panel, 7, C.Tomato)
kit.skin(panel, "Gift_Panel")

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.AnchorPoint = Vector2.new(0.5, 0.5)
closeButton.Position = UDim2.fromScale(0.965, 0.05)
closeButton.Size = UDim2.fromScale(0.08, 0.08)
closeButton.BackgroundColor3 = C.Tomato
closeButton.Font = Enum.Font.FredokaOne
closeButton.TextScaled = true
closeButton.Text = "X"
closeButton.ZIndex = 8
stickerText(closeButton)
closeButton.Parent = root
aspect(closeButton, 1)
corner(closeButton, UDim.new(1, 0))
stroke(closeButton, 3, C.Choc)
if kit.skin(closeButton, "CloseButton") then closeButton.Text = "" end
UIKit.bouncy(closeButton)

--// the two tabs, hanging off the top edge
local tabs = {}
local function makeTab(name, x)
	local tab = Instance.new("ImageButton")
	tab.Name = name
	tab.BackgroundTransparency = 1
	tab.AnchorPoint = Vector2.new(0.5, 1)
	tab.Position = UDim2.fromScale(x, 0.135)
	tab.Size = UDim2.fromScale(0.25, 0.1)
	tab.ScaleType = Enum.ScaleType.Stretch
	tab.AutoButtonColor = false
	tab.ZIndex = 6
	tab.Parent = root
	local text = label(tab, "Text", nil, C.Choc)
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.52)
	text.Size = UDim2.fromScale(0.7, 0.55)
	text.Text = name
	text.ZIndex = 7
	tabs[name] = { Button = tab, Text = text }
	return tab
end
makeTab("GIFT", 0.23)
makeTab("CODES", 0.5)
makeTab("GROUP", 0.77)

local pages = {}
for _, name in ipairs({ "GIFT", "CODES", "GROUP" }) do
	local page = Instance.new("Frame")
	page.Name = name .. "Page"
	page.BackgroundTransparency = 1
	page.Position = UDim2.fromScale(0.07, 0.15)
	page.Size = UDim2.fromScale(0.86, 0.78)
	page.Visible = false
	page.Parent = root
	pages[name] = page
end

local currentTab = "GIFT"
local function selectTab(name)
	currentTab = name
	for tabName, tab in pairs(tabs) do
		local active = tabName == name
		tab.Button.Image = kit.id(active and "Tab_Active" or "Tab_Inactive") or ""
		tab.Button.BackgroundTransparency = tab.Button.Image ~= "" and 1 or 0
		tab.Button.BackgroundColor3 = active and C.Cream or Color3.fromRGB(205, 180, 150)
		tab.Text.TextTransparency = active and 0 or 0.25
		pages[tabName].Visible = active
	end
end
for name, tab in pairs(tabs) do
	tab.Button.Activated:Connect(function()
		sfx("ShopClick")
		selectTab(name)
	end)
end

----------------------------------------------------------------
-- GIFT page
----------------------------------------------------------------
local giftPage = pages.GIFT
local ladder = Instance.new("Frame")
ladder.BackgroundTransparency = 1
ladder.Position = UDim2.fromScale(0, 0.03) -- the LEFT half: rows 1-3, 4-6, then 7
ladder.Size = UDim2.fromScale(0.54, 0.9)
ladder.Parent = giftPage
local ladderCells = {}
for day, coins in ipairs(DAILY.GiftCoins) do
	local cell = Instance.new("Frame")
	--// 3 rows (owner layout): days 1-3, days 4-6, then the big day 7 tile
	--// spanning the whole bottom row
	local last = day == #DAILY.GiftCoins
	local row = last and 2 or (day - 1) // 3
	local col = last and 0 or (day - 1) % 3
	cell.Position = UDim2.fromScale(col * 0.34, row * 0.34)
	cell.Size = UDim2.fromScale(last and 1 or 0.31, 0.3)
	cell.BackgroundColor3 = day == #DAILY.GiftCoins and C.Mustard or C.Warm
	cell.Parent = ladder
	corner(cell, UDim.new(0.2, 0))
	local cellStroke = stroke(cell, 2.5, C.Choc)
	local dayText = label(cell, "Day", nil, C.Choc, last and 26 or 18)
	dayText.Position = UDim2.fromScale(0.05, 0.04)
	dayText.Size = UDim2.fromScale(0.9, 0.3)
	dayText.Text = "DAY " .. day
	local coin = sprite(cell, "FlyingCoin")
	coin.Position = UDim2.fromScale(0.5, 0.55)
	coin.Size = UDim2.fromScale(last and 0.2 or 0.5, last and 0.42 or 0.36)
	aspect(coin, 1)
	local amount = label(cell, "Amount", nil, C.Choc, last and 26 or 18)
	amount.Position = UDim2.fromScale(0.05, 0.72)
	amount.Size = UDim2.fromScale(0.9, 0.26)
	amount.Text = tostring(coins)
	local tick = sprite(cell, "Check_Stamp")
	tick.Position = UDim2.fromScale(0.5, 0.5)
	tick.Size = UDim2.fromScale(0.8, 0.6)
	tick.Visible = false
	tick.ZIndex = 3
	aspect(tick, 1)
	ladderCells[day] = { Frame = cell, Stroke = cellStroke, Tick = tick }
end

local stage = Instance.new("Frame")
stage.BackgroundTransparency = 1
stage.AnchorPoint = Vector2.new(0.5, 0.5)
stage.Position = UDim2.fromScale(0.78, 0.4) -- the RIGHT half
stage.Size = UDim2.fromScale(0.42, 0.6)
stage.Parent = giftPage
aspect(stage, 1)
local stageGlow = sprite(stage, "Glow_Orb")
stageGlow.Position = UDim2.fromScale(0.5, 0.55)
stageGlow.Size = UDim2.fromScale(1.3, 1.3)
stageGlow.ImageColor3 = C.Mustard
stageGlow.ImageTransparency = 0.45
local stageRays = sprite(stage, "Burst_Rays")
stageRays.Position = UDim2.fromScale(0.5, 0.55)
stageRays.Size = UDim2.fromScale(1.6, 1.6)
stageRays.ImageColor3 = C.Mustard
stageRays.ImageTransparency = 0.6
local box = Instance.new("Frame")
box.BackgroundTransparency = 1
box.AnchorPoint = Vector2.new(0.5, 0.5)
box.Position = UDim2.fromScale(0.5, 0.55)
box.Size = UDim2.fromScale(0.95, 0.95)
box.ZIndex = 3
box.Parent = stage
local boxClosed = sprite(box, "Gift_Box_Closed")
boxClosed.Position = UDim2.fromScale(0.5, 0.5)
boxClosed.Size = UDim2.fromScale(1, 1)
boxClosed.ZIndex = 3
local boxBase = sprite(box, "Gift_Box_Base")
boxBase.Position = UDim2.fromScale(0.5, 0.5)
boxBase.Size = UDim2.fromScale(1, 1)
boxBase.ZIndex = 3
boxBase.Visible = false
local boxLid = sprite(box, "Gift_Box_Lid")
boxLid.Position = UDim2.fromScale(0.5, 0.5)
boxLid.Size = UDim2.fromScale(1, 1)
boxLid.ZIndex = 4
boxLid.Visible = false
local lock = sprite(stage, "Lock_Badge")
lock.Position = UDim2.fromScale(0.78, 0.8)
lock.Size = UDim2.fromScale(0.32, 0.32)
lock.ZIndex = 6
lock.Visible = false
aspect(lock, 1)

local giftButton, giftButtonText = bigButton(giftPage, "OPEN GIFT!", C.Basil, "Claim_Button")
giftButton.Position = UDim2.fromScale(0.78, 0.82)
giftButton.Size = UDim2.fromScale(0.42, 0.14)
local giftNote = label(giftPage, "Note", nil, C.Choc, 22)
giftNote.AnchorPoint = Vector2.new(0.5, 0.5)
giftNote.Position = UDim2.fromScale(0.78, 0.95)
giftNote.Size = UDim2.fromScale(0.44, 0.06)

----------------------------------------------------------------
-- CODES page
----------------------------------------------------------------
local codesPage = pages.CODES
local codesTitle = label(codesPage, "Title", nil, C.Choc, 40)
codesTitle.AnchorPoint = Vector2.new(0.5, 0)
codesTitle.Position = UDim2.fromScale(0.5, 0.1)
codesTitle.Size = UDim2.fromScale(0.8, 0.12)
codesTitle.Text = "GOT A CODE?"
local codesHint = label(codesPage, "Hint", Enum.Font.GothamBold, C.Choc, 22)
codesHint.AnchorPoint = Vector2.new(0.5, 0)
codesHint.Position = UDim2.fromScale(0.5, 0.24)
codesHint.Size = UDim2.fromScale(0.8, 0.07)
codesHint.Text = "Find codes on our socials and updates!"

local inputFrame = Instance.new("Frame")
inputFrame.AnchorPoint = Vector2.new(0.5, 0.5)
inputFrame.Position = UDim2.fromScale(0.5, 0.46)
inputFrame.Size = UDim2.fromScale(0.78, 0.15)
inputFrame.BackgroundColor3 = C.White
inputFrame.Parent = codesPage
corner(inputFrame, UDim.new(0.3, 0))
stroke(inputFrame, 3, C.Choc)
local inputArt = sprite(inputFrame, "Code_InputBox")
inputArt.ScaleType = Enum.ScaleType.Stretch
inputArt.Position = UDim2.fromScale(0.5, 0.5)
inputArt.Size = UDim2.fromScale(1, 1)
if inputArt.Image ~= "" then inputFrame.BackgroundTransparency = 1 end
local input = Instance.new("TextBox")
input.BackgroundTransparency = 1
input.AnchorPoint = Vector2.new(0.5, 0.5)
input.Position = UDim2.fromScale(0.5, 0.5)
input.Size = UDim2.fromScale(0.86, 0.6)
input.Font = Enum.Font.FredokaOne
input.TextScaled = true
input.TextColor3 = C.Choc
input.PlaceholderText = "Type a code..."
input.PlaceholderColor3 = Color3.fromRGB(170, 155, 140)
input.Text = ""
input.ClearTextOnFocus = false
input.ZIndex = 3
input.Parent = inputFrame

local redeemButton = bigButton(codesPage, "REDEEM!", C.Basil, "Claim_Button")
redeemButton.Position = UDim2.fromScale(0.5, 0.67)
redeemButton.Size = UDim2.fromScale(0.42, 0.14)
local codeResult = label(codesPage, "Result", nil, C.Basil, 30)
codeResult.AnchorPoint = Vector2.new(0.5, 0.5)
codeResult.Position = UDim2.fromScale(0.5, 0.86)
codeResult.Size = UDim2.fromScale(0.85, 0.09)
codeResult.TextStrokeColor3 = C.Cream
codeResult.TextStrokeTransparency = 0

----------------------------------------------------------------
-- GROUP page: join the group, then pick ONE class at max level
----------------------------------------------------------------
local GROUP = DAILY.Group or { GroupId = 0, GroupName = "", Choices = {} }
local groupPage = pages.GROUP
local groupTitle = label(groupPage, "Title", nil, C.Choc, 38)
groupTitle.AnchorPoint = Vector2.new(0.5, 0)
groupTitle.Position = UDim2.fromScale(0.5, 0.03)
groupTitle.Size = UDim2.fromScale(0.9, 0.1)
groupTitle.Text = "JOIN OUR GROUP!"
local groupSub = label(groupPage, "Sub", Enum.Font.GothamBold, C.Choc, 22)
groupSub.AnchorPoint = Vector2.new(0.5, 0)
groupSub.Position = UDim2.fromScale(0.5, 0.13)
groupSub.Size = UDim2.fromScale(0.9, 0.07)
groupSub.Text = "Then pick ONE class to get at MAX LEVEL, free!"

local joinButton = bigButton(groupPage, "JOIN " .. string.upper(GROUP.GroupName or "GROUP"),
	Color3.fromRGB(74, 144, 226), nil)
joinButton.Position = UDim2.fromScale(0.5, 0.29)
joinButton.Size = UDim2.fromScale(0.6, 0.12)

local choiceCards = {}
for index, classKey in ipairs(GROUP.Choices or {}) do
	local class = Config.Classes[classKey]
	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(index == 1 and 0.28 or 0.72, 0.42)
	card.Size = UDim2.fromScale(0.4, 0.52)
	card.BackgroundColor3 = C.Warm
	card.Parent = groupPage
	corner(card, UDim.new(0, 16))
	local cardStroke = stroke(card, 3.5, C.Choc)
	local glow = sprite(card, "Glow_Orb")
	glow.Position = UDim2.fromScale(0.5, 0.33)
	glow.Size = UDim2.fromScale(0.8, 0.6)
	glow.ImageColor3 = C.Mustard
	glow.ImageTransparency = 0.5
	aspect(glow, 1)
	local icon = Instance.new("ImageLabel")
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.33)
	icon.Size = UDim2.fromScale(0.6, 0.48)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = class and class.IconId or ""
	icon.ZIndex = 2
	icon.Parent = card
	aspect(icon, 1)
	local name = label(card, "Name", nil, C.Choc, 28)
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.fromScale(0.5, 0.6)
	name.Size = UDim2.fromScale(0.9, 0.13)
	name.Text = class and string.upper(class.Display) or classKey
	local maxTag = label(card, "Max", nil, C.Mustard, 20)
	maxTag.AnchorPoint = Vector2.new(0.5, 0)
	maxTag.Position = UDim2.fromScale(0.5, 0.72)
	maxTag.Size = UDim2.fromScale(0.9, 0.08)
	maxTag.Text = "MAX LEVEL"
	maxTag.TextStrokeColor3 = C.Choc
	maxTag.TextStrokeTransparency = 0
	local pick, pickText = bigButton(card, "PICK!", C.Basil, "Claim_Button")
	pick.Position = UDim2.fromScale(0.5, 0.89)
	pick.Size = UDim2.fromScale(0.7, 0.15)
	local stamp = sprite(card, "Check_Stamp")
	stamp.Position = UDim2.fromScale(0.78, 0.18)
	stamp.Size = UDim2.fromScale(0.36, 0.28)
	stamp.Rotation = -12
	stamp.ZIndex = 5
	stamp.Visible = false
	aspect(stamp, 1)
	choiceCards[classKey] = { Card = card, Stroke = cardStroke, Pick = pick, PickText = pickText,
		Stamp = stamp, Icon = icon }
end

local groupResult = label(groupPage, "Result", nil, C.Basil, 24)
groupResult.AnchorPoint = Vector2.new(0.5, 0.5)
groupResult.Position = UDim2.fromScale(0.5, 1.02)
groupResult.Size = UDim2.fromScale(0.9, 0.06)
groupResult.TextStrokeColor3 = C.Cream
groupResult.TextStrokeTransparency = 0

----------------------------------------------------------------
-- State + actions
----------------------------------------------------------------
local state = nil
local isOpen = false
local busy = false
local resetAt = 0

local function fetch()
	local ok, result = pcall(function() return remote:InvokeServer("State") end)
	if ok and type(result) == "table" then
		state = result
		resetAt = os.clock() + (result.ResetIn or 0)
	end
end

local function renderGift()
	if not state then return end
	local step = state.GiftStep or 1
	for day, cell in pairs(ladderCells) do
		local done = state.GiftClaimedToday and day <= step or (not state.GiftClaimedToday and day < step)
		local isNext = not state.GiftClaimedToday and day == step
		cell.Tick.Visible = done
		cell.Stroke.Color = isNext and C.Basil or C.Choc
		cell.Stroke.Thickness = isNext and 4 or 2.5
	end
	local claimed = state.GiftClaimedToday
	lock.Visible = claimed
	boxClosed.Visible = true
	boxBase.Visible, boxLid.Visible = false, false
	boxClosed.ImageTransparency = claimed and 0.35 or 0
	stageGlow.ImageTransparency = claimed and 0.85 or 0.45
	giftButton.Visible = not claimed
	giftButtonText.Text = "OPEN GIFT!"
end

local function openGift()
	if busy or not state or state.GiftClaimedToday then return end
	busy = true
	local ok, success, result = pcall(function() return remote:InvokeServer("Gift") end)
	busy = false
	if not ok or not success then
		giftNote.Text = type(result) == "string" and result or "Try again!"
		return
	end
	sfx("ShopPurchase")
	giftButton.Visible = false
	--// shake, shake, POP: the lid flies, light pours out, coins burst
	for i = 1, 8 do
		box.Rotation = (i % 2 == 0 and 1 or -1) * (4 + i)
		task.wait(0.05)
	end
	box.Rotation = 0
	boxClosed.Visible = false
	boxBase.Visible, boxLid.Visible = true, true
	if boxBase.Image == "" then boxBase.Image = boxClosed.Image end
	tween(boxLid, 0.6, { Position = UDim2.fromScale(0.75, -0.9), Rotation = 40, ImageTransparency = 1 })
	tween(stageGlow, 0.3, { ImageTransparency = 0.05, Size = UDim2.fromScale(1.7, 1.7) })
	local ring = sprite(stage, "FX_Shockwave")
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(0.3, 0.3)
	ring.ImageColor3 = C.Mustard
	ring.ZIndex = 5
	tween(ring, 0.5, { Size = UDim2.fromScale(2, 2), ImageTransparency = 1 })
	task.delay(0.52, function() ring:Destroy() end)
	for _ = 1, 12 do
		local coin = sprite(stage, "FlyingCoin")
		coin.Position = UDim2.fromScale(0.5, 0.45)
		coin.Size = UDim2.fromScale(0.14, 0.14)
		coin.ZIndex = 6
		local target = UDim2.fromScale(0.5 + (math.random() - 0.5) * 1.6, -0.1 - math.random() * 0.4)
		tween(coin, 0.6, { Position = target, Rotation = math.random(-360, 360) })
		task.delay(0.55, function()
			tween(coin, 0.3, { ImageTransparency = 1 })
			task.delay(0.32, function() coin:Destroy() end)
		end)
	end
	giftNote.Text = ("+%d coins! Day %d of %d"):format(result.Coins or 0, result.Step or 1, #DAILY.GiftCoins)
	task.delay(1.6, function()
		fetch()
		renderGift()
	end)
end
giftButton.Activated:Connect(openGift)

local function redeem()
	if busy then return end
	local code = input.Text
	if code:gsub("%s", "") == "" then
		codeResult.TextColor3 = C.Tomato
		codeResult.Text = "Type a code first!"
		return
	end
	busy = true
	local ok, success, result = pcall(function() return remote:InvokeServer("Redeem", code) end)
	busy = false
	if ok and success then
		sfx("ShopPurchase")
		local parts = {}
		if (result.Coins or 0) > 0 then table.insert(parts, ("+%d coins"):format(result.Coins)) end
		if (result.Keys or 0) > 0 then table.insert(parts, ("+%d crate key"):format(result.Keys)) end
		codeResult.TextColor3 = C.Basil
		codeResult.Text = "REDEEMED! " .. table.concat(parts, "  ")
		input.Text = ""
		local s = codeResult:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", codeResult)
		s.Scale = 1.4
		tween(s, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	else
		codeResult.TextColor3 = C.Tomato
		codeResult.Text = type(result) == "string" and result or "Try again!"
		inputFrame.Rotation = 4
		tween(inputFrame, 0.25, { Rotation = 0 }, Enum.EasingStyle.Elastic)
	end
end
redeemButton.Activated:Connect(redeem)

--// GROUP: membership is only DISPLAYED here - the server re-checks it on claim
local function renderGroup()
	if not state then return end
	local comingSoon = (GROUP.GroupId or 0) == 0
	local claimed = state.GroupRewardClass or ""
	local member = state.InGroup == true
	joinButton.Visible = not member and claimed == "" and not comingSoon
	if comingSoon then
		groupSub.Text = "Coming soon!"
	elseif claimed ~= "" then
		groupSub.Text = "Thanks for joining! Enjoy your reward."
	elseif member then
		groupSub.Text = "You're in! Pick ONE class to get at MAX LEVEL:"
	else
		groupSub.Text = "Then pick ONE class to get at MAX LEVEL, free!"
	end
	for classKey, c in pairs(choiceCards) do
		local isPick = claimed == classKey
		c.Stamp.Visible = isPick
		c.Pick.Visible = claimed == "" and not comingSoon
		c.PickText.Text = member and "PICK!" or "JOIN FIRST"
		c.Pick.BackgroundColor3 = member and C.Basil or Color3.fromRGB(170, 160, 150)
		c.Stroke.Color = isPick and C.Basil or C.Choc
		c.Stroke.Thickness = isPick and 5 or 3.5
		c.Icon.ImageTransparency = (claimed ~= "" and not isPick) and 0.6 or 0
	end
end

joinButton.Activated:Connect(function()
	sfx("ShopClick")
	--// Roblox's own join prompt; the result is re-read from the server after
	local ok = pcall(function()
		game:GetService("GroupService"):PromptJoinAsync(GROUP.GroupId)
	end)
	if not ok then
		groupResult.TextColor3 = C.Choc
		groupResult.Text = ("Search \"%s\" on Roblox to join!"):format(GROUP.GroupName or "")
	end
	task.wait(0.5)
	fetch()
	renderGroup()
end)

for classKey, c in pairs(choiceCards) do
	c.Pick.Activated:Connect(function()
		if busy or not state then return end
		if not state.InGroup then
			groupResult.TextColor3 = C.Tomato
			groupResult.Text = "Join the group first!"
			return
		end
		busy = true
		local ok, success, result = pcall(function() return remote:InvokeServer("GroupClaim", classKey) end)
		busy = false
		if ok and success then
			sfx("UltimateReady")
			groupResult.TextColor3 = C.Basil
			groupResult.Text = ("%s unlocked at MAX LEVEL!"):format(Config.Classes[classKey].Display)
			--// the picked card bursts: rays, a pop, the stamp slams
			local rays = sprite(c.Card, "Burst_Rays")
			rays.Position = UDim2.fromScale(0.5, 0.33)
			rays.Size = UDim2.fromScale(0.3, 0.3)
			rays.ImageColor3 = C.Mustard
			rays.ZIndex = 1
			aspect(rays, 1)
			tween(rays, 0.6, { Size = UDim2.fromScale(1.6, 1.6), ImageTransparency = 1 })
			task.delay(0.62, function() rays:Destroy() end)
			local s = c.Card:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", c.Card)
			s.Scale = 1.12
			tween(s, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			state.GroupRewardClass = classKey
			renderGroup()
			c.Stamp.Rotation = -40
			local stampScale = Instance.new("UIScale", c.Stamp)
			stampScale.Scale = 2.4
			tween(stampScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			tween(c.Stamp, 0.2, { Rotation = -12 })
		else
			groupResult.TextColor3 = C.Tomato
			groupResult.Text = type(result) == "string" and result or "Try again!"
		end
	end)
end
input.FocusLost:Connect(function(enter) if enter then redeem() end end)

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------
local idleToken = 0
local function setOpen(open)
	isOpen = open
	if open then
		gui.Enabled = true
		blur.Enabled = true
		tween(blur, 0.3, { Size = 14 })
		tween(backdrop, 0.3, { BackgroundTransparency = 0.45 })
		rootScale.Scale = 0.85
		tween(rootScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		codeResult.Text = ""
		giftNote.Text = ""
		fetch()
		selectTab(currentTab)
		renderGift()
		renderGroup()
		groupResult.Text = ""
		idleToken += 1
		local mine = idleToken
		task.spawn(function()
			local t = 0
			while idleToken == mine and isOpen do
				local dt = RunService.RenderStepped:Wait()
				t += dt
				stageRays.Rotation = (stageRays.Rotation + dt * 15) % 360
				if state and not state.GiftClaimedToday and not busy then
					box.Position = UDim2.fromScale(0.5, 0.55 + math.sin(t * 3) * 0.02)
					box.Rotation = math.sin(t * 6) * 3
				elseif state and state.GiftClaimedToday then
					giftNote.Text = "Next gift in " .. formatTime(resetAt - os.clock())
				end
			end
		end)
	else
		idleToken += 1
		tween(blur, 0.2, { Size = 0 })
		tween(backdrop, 0.2, { BackgroundTransparency = 1 })
		task.delay(0.2, function()
			if not isOpen then
				gui.Enabled = false
				blur.Enabled = false
			end
		end)
	end
end

closeButton.Activated:Connect(function() setOpen(false) end)
backdrop.Activated:Connect(function() setOpen(false) end)

--// the owner's FREE! button (bind every copy that ever appears)
local bound = {}
local function bindOpenButton(inst)
	if inst.Name ~= "OpenGiftButton" or not inst:IsA("GuiButton") or bound[inst] then return end
	bound[inst] = true
	inst.Activated:Connect(function()
		sfx("ShopClick")
		currentTab = "GIFT"
		setOpen(not isOpen)
	end)
end
for _, inst in ipairs(playerGui:GetDescendants()) do bindOpenButton(inst) end
playerGui.DescendantAdded:Connect(bindOpenButton)

print("[Gift] free gift + codes ready")
