--[[
	Dinner Rush - StatsClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.StatsClient  (LocalScript)

	THE STAFF ROOM (Oct 2026 rebuild) - the player STATS screen, themed as a
	diner staff room on a corkboard wall:

	  STAFF BADGE   - your avatar in a gold frame on a laminated ID card,
	                  your name, class, the three headline numbers (shifts /
	                  customers / time on floor), a LEVEL MEDAL on a spinning
	                  sunburst, and an XP bar to the next level
	  RECEIPT       - prints out of a cash register line by line: the
	                  visible lifetime stats, counting up, with Lifetime
	                  Earnings as the TOTAL
	  TROPHY SHELF  - best shifts: gold / silver / bronze trophies with a
	                  grade stamp, #4-5 as framed photos. Hover or tap one
	                  for its full card.

	REGISTRY-DRIVEN: receipt lines are the Config.PlayerStats.Registry rows
	that are not Hidden; a "money" row becomes the TOTAL. A new stat is one
	registry entry (plus an icon in StatIcons), never an edit here.

	RENDER ONLY: every number, the level and the Best Shifts ranking arrive
	computed from the server (StatsRemote "Get" -> "Stats", payload). The XP
	bar's fraction is display maths on ShiftsCompleted.

	ART: Config.PlayerStats.StaffArt + the shop kit's shared sprites, through
	ReplicatedStorage.Shared.UIKit. An empty slot = a code-drawn placeholder.

	Opens from: a Studio dock button named OpenStatsButton if one exists,
	otherwise the code-built STATS sticker. Backdrop click, X, or the opener
	again all close it.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local UIKit = require(ReplicatedStorage.Shared:WaitForChild("UIKit"))
local statsRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StatsRemote")

local SfxLocal = nil
pcall(function()
	SfxLocal = require(ReplicatedStorage.Shared:WaitForChild("SfxLocal", 5))
end)

local PS = Config.PlayerStats
local REGISTRY = PS.Registry
local ICONS = PS.StatIcons or {}
local STAMP_TEXT = PS.StampText or {}
local kit = UIKit.artKit(PS.StaffArt or {}, (Config.Monetization and Config.Monetization.ShopArt) or {})

local C = UIKit.Colors
local corner, stroke, label = UIKit.corner, UIKit.stroke, UIKit.label
local stickerText, aspect = UIKit.stickerText, UIKit.aspect

local GREY_TEXT = Color3.fromRGB(122, 112, 102)
local CHALK = Color3.fromRGB(246, 244, 232)
local INK = Color3.fromRGB(60, 52, 48)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local isOpen = false

local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then
		pcall(SfxLocal.Play, name)
	end
end

----------------------------------------------------------------
-- Formatting (display only - the numbers arrive computed)
----------------------------------------------------------------
local function fmtInt(n)
	n = math.floor(tonumber(n) or 0)
	if n >= 1e9 then
		return string.format("%.1fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif n >= 1e5 then
		return string.format("%.0fK", n / 1e3)
	end
	return UIKit.commas(n)
end

local function fmtMoney(n)
	return "$" .. fmtInt(n)
end

local function fmtDuration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then
		return ("%dm"):format(minutes)
	end
	return ("%dh %dm"):format(math.floor(minutes / 60), minutes % 60)
end

local function fmtAgo(timestamp)
	local days = math.floor(math.max(0, os.time() - (tonumber(timestamp) or 0)) / 86400)
	if days < 1 then
		return "today"
	elseif days == 1 then
		return "1 day ago"
	elseif days < 60 then
		return ("%d days ago"):format(days)
	end
	return ("%d months ago"):format(math.floor(days / 30))
end

local FORMATTERS = { int = fmtInt, money = fmtMoney, duration = fmtDuration }

local function valueFor(entry, payload)
	if entry.Source == "TaskProgress" then
		return (payload.TaskProgress and payload.TaskProgress[entry.Key]) or entry.Default
	end
	return (payload.Stats and payload.Stats[entry.Key]) or entry.Default
end

local function statIcon(parent, key, name)
	local id = ICONS[key]
	if type(id) ~= "string" or id == "" then return nil end
	local icon = Instance.new("ImageLabel")
	icon.Name = name or "Icon"
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = id
	icon.Parent = parent
	aspect(icon, 1)
	return icon
end

----------------------------------------------------------------
-- Skeleton: backdrop + the corkboard panel
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Stats_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 30
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local blur = Instance.new("BlurEffect")
blur.Name = "StatsBlur"
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
root.Position = UDim2.fromScale(0.5, 0.55)
root.Size = UDim2.fromScale(0.74, 0.76)
root.BackgroundTransparency = 1
root.Parent = gui
aspect(root, 1.55)
local rootScale = Instance.new("UIScale")
rootScale.Parent = root

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = C.Cream
panel.Parent = root
corner(panel, UDim.new(0, 22))
stroke(panel, 7, C.Wood)
kit.skin(panel, "PanelFrame")

--// the corkboard wall inside the wood frame
do
	local cork = kit.image(panel, "CorkPattern", "Cork")
	if cork then
		cork.AnchorPoint = Vector2.new(0.5, 0.5)
		cork.Position = UDim2.fromScale(0.5, 0.5)
		cork.Size = UDim2.fromScale(0.86, 0.8)
		cork.ScaleType = Enum.ScaleType.Tile
		cork.TileSize = UDim2.fromOffset(140, 140)
		cork.ImageTransparency = 0.1
		cork.ZIndex = 1
		corner(cork, UDim.new(0, 16))
	end
end

--// bistro lights over the top, like the shop (bulbs twinkle while open)
local bulbGlows = {}
do
	local lights = kit.image(root, "BistroLights", "BistroLights")
	if lights then
		lights.AnchorPoint = Vector2.new(0.5, 0)
		lights.Position = UDim2.fromScale(0.5, -0.19)
		lights.Size = UDim2.fromScale(1.02, 0.27)
		lights.ScaleType = Enum.ScaleType.Stretch
		lights.ZIndex = 2
		for i = 0, 7 do
			local x = 0.06 + i * (0.88 / 7)
			local glow = kit.image(lights, "SoftGlow", "BulbGlow" .. i)
			if glow then
				glow.AnchorPoint = Vector2.new(0.5, 0.5)
				glow.Position = UDim2.fromScale(x, 0.5 + 0.2 * (1 - (2 * x - 1) ^ 2))
				glow.Size = UDim2.fromScale(0.09, 0.6)
				glow.ImageTransparency = 0.3
				glow.ZIndex = 3
				aspect(glow, 1)
				table.insert(bulbGlows, glow)
			end
		end
	end
end

--// HEADER: the chalkboard sign, swinging on its chains
local HEADER_HOME = UDim2.fromScale(0.5, -0.1)
local header = Instance.new("Frame")
header.Name = "Header"
header.AnchorPoint = Vector2.new(0.5, 0)
header.Position = HEADER_HOME
header.Size = UDim2.fromScale(0.62, 0.24)
header.BackgroundColor3 = Color3.fromRGB(46, 84, 66)
header.ZIndex = 4
header.Parent = root
aspect(header, 4)
corner(header, UDim.new(0, 10))
stroke(header, 6, C.Wood)
kit.skin(header, "HeaderChalkboard")
local title = label(header, "Title", Enum.Font.FredokaOne, CHALK)
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.57)
title.Size = UDim2.fromScale(0.7, 0.42)
title.Text = "STAFF ROOM"
title.TextTransparency = 0.05
title.ZIndex = 5

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton" --// lobby close convention
closeButton.AnchorPoint = Vector2.new(0.5, 0.5)
closeButton.Position = UDim2.fromScale(0.985, 0.03)
closeButton.Size = UDim2.fromScale(0.08, 0.08)
closeButton.BackgroundColor3 = C.Tomato
closeButton.Font = Enum.Font.FredokaOne
closeButton.TextScaled = true
closeButton.Text = "X"
stickerText(closeButton)
closeButton.ZIndex = 8
closeButton.Parent = root
corner(closeButton, UDim.new(1, 0))
stroke(closeButton, 3, C.Choc)
aspect(closeButton, 1)
if kit.skin(closeButton, "CloseButton") then closeButton.Text = "" end
UIKit.bouncy(closeButton)

----------------------------------------------------------------
-- LEFT TOP: the STAFF BADGE
----------------------------------------------------------------
local badge = Instance.new("Frame")
badge.Name = "StaffBadge"
badge.Position = UDim2.fromScale(0.05, 0.245)
badge.Size = UDim2.fromScale(0.38, 0.37)
badge.BackgroundColor3 = C.Cream
badge.ZIndex = 3
badge.Parent = root
aspect(badge, 1.6)
corner(badge, UDim.new(0, 18))
stroke(badge, 4, C.Choc)
do --// placeholder red strip (the badge art has its own)
	local strip = Instance.new("Frame")
	strip.Name = "Placeholder"
	strip.Size = UDim2.fromScale(1, 0.26)
	strip.BackgroundColor3 = C.Tomato
	strip.ZIndex = 3
	strip.Parent = badge
	corner(strip, UDim.new(0, 18))
end
kit.skin(badge, "StaffBadge")

--// avatar in the gold frame, on a soft glow
local photoGlow = kit.image(badge, "SoftGlow", "PhotoGlow")
if photoGlow then
	photoGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	photoGlow.Position = UDim2.fromScale(0.2, 0.66)
	photoGlow.Size = UDim2.fromScale(0.46, 0.74)
	photoGlow.ImageTransparency = 0.2
	photoGlow.ZIndex = 3
	aspect(photoGlow, 1)
end
local headshot = Instance.new("ImageLabel")
headshot.Name = "Headshot"
headshot.AnchorPoint = Vector2.new(0.5, 0.5)
headshot.Position = UDim2.fromScale(0.2, 0.665)
headshot.Size = UDim2.fromScale(0.24, 0.38)
headshot.BackgroundColor3 = C.Warm
headshot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(player.UserId)
headshot.ZIndex = 4
headshot.Parent = badge
aspect(headshot, 1)
corner(headshot, UDim.new(0, 10))
local photoFrame = kit.image(badge, "PhotoFrame", "PhotoFrame")
if photoFrame then
	photoFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	photoFrame.Position = UDim2.fromScale(0.2, 0.645)
	photoFrame.Size = UDim2.fromScale(0.34, 0.54)
	photoFrame.ZIndex = 5
	aspect(photoFrame, 1)
end
local twinkles = {}
for i, spot in ipairs({ { 0.05, 0.42 }, { 0.36, 0.5 }, { 0.07, 0.92 } }) do
	local sparkle = kit.image(badge, "Sparkle", "Twinkle" .. i)
	if sparkle then
		sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
		sparkle.Position = UDim2.fromScale(spot[1], spot[2])
		sparkle.Size = UDim2.fromScale(0.07, 0.11)
		sparkle.ZIndex = 6
		aspect(sparkle, 1)
		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = sparkle
		table.insert(twinkles, scale)
	end
end

local nameText = label(badge, "PlayerName", Enum.Font.FredokaOne, C.White, 34)
nameText.Position = UDim2.fromScale(0.07, 0.17)
nameText.Size = UDim2.fromScale(0.62, 0.15)
nameText.TextXAlignment = Enum.TextXAlignment.Left
nameText.Text = player.DisplayName
nameText.ZIndex = 5
stickerText(nameText)

local classIcon = Instance.new("ImageLabel")
classIcon.Name = "ClassIcon"
classIcon.BackgroundTransparency = 1
classIcon.ScaleType = Enum.ScaleType.Fit
classIcon.Position = UDim2.fromScale(0.39, 0.42)
classIcon.Size = UDim2.fromScale(0.09, 0.14)
classIcon.ZIndex = 5
classIcon.Parent = badge
aspect(classIcon, 1)
local classText = label(badge, "ClassName", Enum.Font.FredokaOne, C.Choc, 30)
classText.Position = UDim2.fromScale(0.49, 0.43)
classText.Size = UDim2.fromScale(0.3, 0.12)
classText.TextXAlignment = Enum.TextXAlignment.Left
classText.ZIndex = 5

--// the three headline numbers, each with its icon
local quickValues = {}
do
	local quick = Instance.new("Frame")
	quick.Name = "Quick"
	quick.Position = UDim2.fromScale(0.38, 0.59)
	quick.Size = UDim2.fromScale(0.58, 0.21)
	quick.BackgroundTransparency = 1
	quick.ZIndex = 5
	quick.Parent = badge
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = quick
	local QUICK = {
		{ Key = "ShiftsCompleted", Caption = "SHIFTS", Format = fmtInt },
		{ Key = "CustomersServed", Caption = "CUSTOMERS", Format = fmtInt },
		{ Key = "TimeOnFloorSeconds", Caption = "ON FLOOR", Format = fmtDuration },
	}
	for i, q in ipairs(QUICK) do
		local chip = Instance.new("Frame")
		chip.Name = q.Key
		chip.LayoutOrder = i
		chip.Size = UDim2.fromScale(0.32, 1)
		chip.BackgroundTransparency = 1
		chip.ZIndex = 5
		chip.Parent = quick
		local icon = statIcon(chip, q.Key)
		if icon then
			icon.Position = UDim2.fromScale(0, 0.05)
			icon.Size = UDim2.fromScale(0.36, 0.6)
			icon.ZIndex = 6
		end
		local value = label(chip, "Value", Enum.Font.FredokaOne, C.Choc, 28)
		value.Position = UDim2.fromScale(icon and 0.38 or 0, 0.05)
		value.Size = UDim2.fromScale(icon and 0.62 or 1, 0.55)
		value.TextXAlignment = Enum.TextXAlignment.Left
		value.Text = "-"
		value.ZIndex = 6
		local caption = label(chip, "Caption", Enum.Font.GothamBold, GREY_TEXT, 14)
		caption.Position = UDim2.fromScale(0, 0.66)
		caption.Size = UDim2.fromScale(1, 0.3)
		caption.TextXAlignment = Enum.TextXAlignment.Left
		caption.Text = q.Caption
		caption.ZIndex = 6
		quickValues[q.Key] = { Label = value, Format = q.Format }
	end
end

--// XP bar: shifts toward the next level
local xpFrame = Instance.new("Frame")
xpFrame.Name = "XPBar"
xpFrame.Position = UDim2.fromScale(0.39, 0.84)
xpFrame.Size = UDim2.fromScale(0.44, 0.075)
xpFrame.BackgroundColor3 = C.WoodDark
xpFrame.ZIndex = 5
xpFrame.Parent = badge
corner(xpFrame, UDim.new(1, 0))
stroke(xpFrame, 2, C.Choc)
kit.skin(xpFrame, "XPBarFrame")
local xpFill = Instance.new("Frame")
xpFill.Name = "Fill"
xpFill.Size = UDim2.fromScale(0, 1)
xpFill.BackgroundColor3 = C.Basil
xpFill.ZIndex = 6
xpFill.Parent = xpFrame
corner(xpFill, UDim.new(1, 0))
kit.skin(xpFill, "XPBarFill")
local xpText = label(xpFrame, "XPText", Enum.Font.FredokaOne, C.White, 18)
xpText.AnchorPoint = Vector2.new(0.5, 0.5)
xpText.Position = UDim2.fromScale(0.5, 0.5)
xpText.Size = UDim2.fromScale(0.9, 0.8)
xpText.ZIndex = 7
stickerText(xpText)

--// the LEVEL MEDAL, on a slow sunburst, hanging off the badge corner
local medalHome = UDim2.fromScale(0.89, 0.2)
local sunburst = kit.image(badge, "Sunburst", "Sunburst")
if sunburst then
	sunburst.AnchorPoint = Vector2.new(0.5, 0.5)
	sunburst.Position = medalHome
	sunburst.Size = UDim2.fromScale(0.44, 0.8)
	sunburst.ZIndex = 6
	aspect(sunburst, 1)
end
local medal = kit.image(badge, "LevelMedal", "LevelMedal")
if not medal then
	medal = Instance.new("Frame")
	medal.Name = "LevelMedal"
	medal.BackgroundColor3 = C.Mustard
	medal.Parent = badge
	corner(medal, UDim.new(1, 0))
	stroke(medal, 3, C.Choc)
end
medal.AnchorPoint = Vector2.new(0.5, 0.5)
medal.Position = medalHome
medal.Size = UDim2.fromScale(0.2, 0.45)
medal.ZIndex = 7
aspect(medal, 384 / 448)
local medalScale = Instance.new("UIScale")
medalScale.Parent = medal
local levelText = label(medal, "Level", Enum.Font.FredokaOne, C.Choc)
levelText.AnchorPoint = Vector2.new(0.5, 0.5)
levelText.Position = UDim2.fromScale(0.5, 0.6)
levelText.Size = UDim2.fromScale(0.36, 0.2)
levelText.Text = "1"
levelText.ZIndex = 8

--// the badge sways gently on its lanyard
badge.Rotation = -1.2
TweenService:Create(badge, TweenInfo.new(2.2, Enum.EasingStyle.Sine,
	Enum.EasingDirection.InOut, -1, true), { Rotation = 1.2 }):Play()

----------------------------------------------------------------
-- RIGHT: the cash register + the RECEIPT it prints
----------------------------------------------------------------
local register = kit.image(root, "RegisterSlot", "Register")
if not register then
	register = Instance.new("Frame")
	register.Name = "Register"
	register.BackgroundColor3 = C.Tomato
	register.Parent = root
	corner(register, UDim.new(0, 12))
	stroke(register, 4, C.Choc)
end
register.AnchorPoint = Vector2.new(0.5, 0)
register.Position = UDim2.fromScale(0.73, 0.155)
register.Size = UDim2.fromScale(0.36, 0.2)
register.ZIndex = 5
aspect(register, 3)

--// the paper is clipped by a window that starts at the slot, so it looks
--// like it feeds OUT of the register
local slotClip = Instance.new("Frame")
slotClip.Name = "ReceiptWindow"
slotClip.AnchorPoint = Vector2.new(0.5, 0)
slotClip.Position = UDim2.fromScale(0.725, 0.3)
slotClip.Size = UDim2.fromScale(0.26, 0.655)
slotClip.BackgroundTransparency = 1
slotClip.ClipsDescendants = true
slotClip.ZIndex = 4
slotClip.Parent = root

local paper = Instance.new("Frame")
paper.Name = "Receipt"
paper.Size = UDim2.fromScale(1, 1)
paper.Position = UDim2.fromScale(0, 0)
paper.BackgroundColor3 = Color3.fromRGB(255, 252, 245)
paper.ZIndex = 4
paper.Parent = slotClip
stroke(paper, 2, C.Choc)
kit.skin(paper, "Receipt")

local RECEIPT_FONT = Enum.Font.RobotoMono
local function receiptText(name, y, h, text, alignment, color, font)
	local t = label(paper, name, font or RECEIPT_FONT, color or INK)
	t.Position = UDim2.fromScale(0.09, y)
	t.Size = UDim2.fromScale(0.82, h)
	t.TextXAlignment = alignment or Enum.TextXAlignment.Center
	t.Text = text or ""
	t.ZIndex = 5
	return t
end

receiptText("Shop", 0.07, 0.05, "DINNER RUSH", nil, INK, Enum.Font.FredokaOne)
local receiptDate = receiptText("Sub", 0.125, 0.032, "STAFF STATS")
receiptText("Rule1", 0.165, 0.03, "--------------------")

--// the lines: every visible registry row; a money row becomes the TOTAL
local receiptLines, totalEntry = {}, nil
do
	local y = 0.205
	for _, entry in ipairs(REGISTRY) do
		if not entry.Hidden then
			if entry.Format == "money" and not totalEntry then
				totalEntry = entry
			else
				local row = Instance.new("Frame")
				row.Name = entry.Key
				row.Position = UDim2.fromScale(0.07, y)
				row.Size = UDim2.fromScale(0.86, 0.07)
				row.BackgroundTransparency = 1
				row.ZIndex = 5
				row.Parent = paper
				local icon = statIcon(row, entry.Key)
				if icon then
					icon.Position = UDim2.fromScale(0, 0.05)
					icon.Size = UDim2.fromScale(0.16, 0.9)
					icon.ZIndex = 6
				end
				local name = label(row, "Label", RECEIPT_FONT, INK, 22)
				name.Position = UDim2.fromScale(icon and 0.18 or 0, 0.12)
				name.Size = UDim2.fromScale(icon and 0.52 or 0.7, 0.76)
				name.TextXAlignment = Enum.TextXAlignment.Left
				name.Text = entry.Label
				name.ZIndex = 6
				local value = label(row, "Value", Enum.Font.FredokaOne, C.Choc, 26)
				value.AnchorPoint = Vector2.new(1, 0)
				value.Position = UDim2.fromScale(1, 0.05)
				value.Size = UDim2.fromScale(0.3, 0.9)
				value.TextXAlignment = Enum.TextXAlignment.Right
				value.Text = "-"
				value.ZIndex = 6
				table.insert(receiptLines, { Entry = entry, Row = row, Value = value })
				y += 0.082
			end
		end
	end

	receiptText("Rule2", y + 0.005, 0.03, "--------------------")
	y += 0.045
	local totalRow = Instance.new("Frame")
	totalRow.Name = "Total"
	totalRow.Position = UDim2.fromScale(0.07, y)
	totalRow.Size = UDim2.fromScale(0.86, 0.09)
	totalRow.BackgroundTransparency = 1
	totalRow.ZIndex = 5
	totalRow.Parent = paper
	local icon = totalEntry and statIcon(totalRow, totalEntry.Key)
	if icon then
		icon.Position = UDim2.fromScale(0, 0.05)
		icon.Size = UDim2.fromScale(0.18, 0.9)
		icon.ZIndex = 6
	end
	local totalName = label(totalRow, "Label", Enum.Font.FredokaOne, INK, 24)
	totalName.Position = UDim2.fromScale(icon and 0.2 or 0, 0.1)
	totalName.Size = UDim2.fromScale(0.42, 0.8)
	totalName.TextXAlignment = Enum.TextXAlignment.Left
	totalName.Text = "TOTAL"
	totalName.ZIndex = 6
	local totalValue = label(totalRow, "Value", Enum.Font.FredokaOne, C.Basil, 34)
	totalValue.AnchorPoint = Vector2.new(1, 0)
	totalValue.Position = UDim2.fromScale(1, 0)
	totalValue.Size = UDim2.fromScale(0.42, 1)
	totalValue.TextXAlignment = Enum.TextXAlignment.Right
	totalValue.Text = "-"
	totalValue.TextStrokeColor3 = C.Choc
	totalValue.TextStrokeTransparency = 0.6
	totalValue.ZIndex = 6
	if totalEntry then
		table.insert(receiptLines, { Entry = totalEntry, Row = totalRow, Value = totalValue, Total = true })
	end
	y += 0.11

	receiptText("Thanks", y, 0.04, "THANK YOU, CHEF!")
	y += 0.055
	--// a little barcode, purely for the look
	local barcode = Instance.new("Frame")
	barcode.Name = "Barcode"
	barcode.Position = UDim2.fromScale(0.2, y)
	barcode.Size = UDim2.fromScale(0.6, 0.05)
	barcode.BackgroundTransparency = 1
	barcode.ZIndex = 5
	barcode.Parent = paper
	local x = 0
	local rng = Random.new(42)
	while x < 0.97 do
		local w = rng:NextNumber(0.008, 0.028)
		local bar = Instance.new("Frame")
		bar.Position = UDim2.fromScale(x, 0)
		bar.Size = UDim2.fromScale(w, 1)
		bar.BackgroundColor3 = INK
		bar.BorderSizePixel = 0
		bar.ZIndex = 5
		bar.Parent = barcode
		x += w + rng:NextNumber(0.01, 0.03)
	end
end

----------------------------------------------------------------
-- LEFT BOTTOM: the TROPHY SHELF (best shifts)
----------------------------------------------------------------
local shelfZone = Instance.new("Frame")
shelfZone.Name = "TrophyShelf"
shelfZone.Position = UDim2.fromScale(0.05, 0.62)
shelfZone.Size = UDim2.fromScale(0.42, 0.265)
shelfZone.BackgroundTransparency = 1
shelfZone.ZIndex = 3
shelfZone.Parent = root

local shelf = Instance.new("Frame")
shelf.Name = "Shelf"
shelf.AnchorPoint = Vector2.new(0, 1)
shelf.Position = UDim2.fromScale(0, 1)
shelf.Size = UDim2.fromScale(1, 0.3)
shelf.BackgroundColor3 = C.Wood
shelf.ZIndex = 3
shelf.Parent = shelfZone
stroke(shelf, 3, C.Choc)
corner(shelf, UDim.new(0, 8))
kit.skin(shelf, "TrophyShelf")
local SHELF_TOP = 0.77 --// where things stand (the plank's top, in zone space)

local items = Instance.new("Frame")
items.Name = "Items"
items.Size = UDim2.fromScale(1, 1)
items.BackgroundTransparency = 1
items.ZIndex = 4
items.Parent = shelfZone

--// the hover/tap card for a trophy
local tip = label(shelfZone, "Tip", Enum.Font.GothamBold, C.Cream, 18)
tip.AnchorPoint = Vector2.new(0.5, 1)
tip.Position = UDim2.fromScale(0.5, 0.08)
tip.Size = UDim2.fromScale(1, 0.16)
tip.BackgroundColor3 = C.Choc
tip.BackgroundTransparency = 0.1
tip.Visible = false
tip.ZIndex = 9
corner(tip, UDim.new(0, 10))
local tipPad = Instance.new("UIPadding")
tipPad.PaddingLeft = UDim.new(0.03, 0)
tipPad.PaddingRight = UDim.new(0.03, 0)
tipPad.Parent = tip

local function shiftCardText(entry, rank)
	return ("#%d  %s   %s · %d served · %s · %s"):format(
		rank, entry.Grade or "?", entry.Label or entry.DiffName or "",
		entry.Served or 0, fmtMoney(entry.Net), fmtAgo(entry.When))
end

local TROPHY_SLOT = { "TrophyGold", "TrophySilver", "TrophyBronze" }
local TROPHY_X = { 0.12, 0.31, 0.5 }
local PHOTO_X = { 0.72, 0.9 }
local trophyIntro = {} --// { Item, Home, Stamp } for the drop-in

local function clearShelf()
	for _, child in ipairs(items:GetChildren()) do
		child:Destroy()
	end
	table.clear(trophyIntro)
	tip.Visible = false
end

local function hoverable(item, text)
	item.MouseEnter:Connect(function()
		tip.Text = text
		tip.Visible = true
	end)
	item.MouseLeave:Connect(function()
		tip.Visible = false
	end)
	item.Activated:Connect(function() --// tap on mobile
		tip.Text = text
		tip.Visible = not tip.Visible
	end)
end

local function stampOn(parent, entry, at, size)
	local stamp = kit.image(parent, "GradeStamp", "Stamp")
	if not stamp then
		stamp = Instance.new("Frame")
		stamp.Name = "Stamp"
		stamp.BackgroundTransparency = 1
		stamp.Parent = parent
		stroke(stamp, 3, C.Tomato)
		corner(stamp, UDim.new(1, 0))
	end
	stamp.AnchorPoint = Vector2.new(0.5, 0.5)
	stamp.Position = at
	stamp.Size = size
	stamp.Rotation = -12
	stamp.ZIndex = 7
	aspect(stamp, 1)
	local word = label(stamp, "Word", Enum.Font.FredokaOne, C.Tomato)
	word.AnchorPoint = Vector2.new(0.5, 0.5)
	word.Position = UDim2.fromScale(0.5, 0.5)
	word.Size = UDim2.fromScale(0.6, 0.34)
	word.Text = STAMP_TEXT[entry.Grade or ""] or "★"
	word.ZIndex = 8
	local scale = Instance.new("UIScale")
	scale.Parent = stamp
	return stamp, scale
end

local function renderBestShifts(entries)
	clearShelf()
	if #entries == 0 then
		local empty = label(items, "Empty", Enum.Font.FredokaOne, C.White, 26)
		empty.Position = UDim2.fromScale(0.05, 0.25)
		empty.Size = UDim2.fromScale(0.9, 0.35)
		empty.Text = "Finish a shift to win your first trophy!"
		empty.ZIndex = 5
		stickerText(empty)
		return
	end

	for rank, entry in ipairs(entries) do
		if rank <= 3 then
			--// a TROPHY, standing on the plank
			local item = Instance.new("TextButton")
			item.Name = "Trophy" .. rank
			item.Text = ""
			item.BackgroundTransparency = 1
			item.AnchorPoint = Vector2.new(0.5, 1)
			local home = UDim2.fromScale(TROPHY_X[rank], SHELF_TOP)
			item.Position = home
			item.Size = UDim2.fromScale(0.17, 0.5)
			item.ZIndex = 5
			item.Parent = items
			aspect(item, 384 / 512)
			local art = kit.image(item, TROPHY_SLOT[rank], "Art")
			if art then
				art.Size = UDim2.fromScale(1, 1)
				art.ZIndex = 5
			else
				item.BackgroundTransparency = 0
				item.BackgroundColor3 = ({ C.Mustard, Color3.fromRGB(200, 205, 210), Color3.fromRGB(196, 128, 72) })[rank]
				corner(item, UDim.new(0, 8))
			end
			--// the glint: a streak that sweeps across, clipped to the trophy
			local glintClip = Instance.new("Frame")
			glintClip.Name = "Glint"
			glintClip.Size = UDim2.fromScale(1, 1)
			glintClip.BackgroundTransparency = 1
			glintClip.ClipsDescendants = true
			glintClip.ZIndex = 6
			glintClip.Parent = item
			local streak = kit.image(glintClip, "ShineStreak", "Streak")
			if streak then
				streak.AnchorPoint = Vector2.new(0.5, 0.5)
				streak.Position = UDim2.fromScale(-0.5, 0.5)
				streak.Size = UDim2.fromScale(0.5, 1.4)
				streak.ScaleType = Enum.ScaleType.Stretch
				streak.ImageTransparency = 0.2
				streak.ZIndex = 6
			end
			--// the grade stamp, inked over the cup's plaque
			local stamp, stampScale = stampOn(item, entry,
				UDim2.fromScale(0.5, 0.33), UDim2.fromScale(0.62, 0.47))
			hoverable(item, shiftCardText(entry, rank))
			table.insert(trophyIntro, {
				Item = item, Home = home, Stamp = stamp, StampScale = stampScale, Streak = streak,
			})
		else
			--// #4-5: a framed photo leaning on the shelf, pinned
			local slot = rank - 3
			local item = Instance.new("TextButton")
			item.Name = "Photo" .. rank
			item.Text = ""
			item.BackgroundTransparency = 1
			item.AnchorPoint = Vector2.new(0.5, 1)
			local home = UDim2.fromScale(PHOTO_X[slot], SHELF_TOP)
			item.Position = home
			item.Size = UDim2.fromScale(0.16, 0.36)
			item.Rotation = slot == 1 and -5 or 4
			item.ZIndex = 5
			item.Parent = items
			aspect(item, 384 / 320)
			local art = kit.image(item, "ShiftPhotoFrame", "Art")
			if art then
				art.Size = UDim2.fromScale(1, 1)
				art.ZIndex = 5
			else
				item.BackgroundTransparency = 0
				item.BackgroundColor3 = C.Wood
				corner(item, UDim.new(0, 6))
			end
			local rankText = label(item, "Rank", Enum.Font.FredokaOne, C.Choc)
			rankText.Position = UDim2.fromScale(0.2, 0.3)
			rankText.Size = UDim2.fromScale(0.3, 0.4)
			rankText.Text = "#" .. rank
			rankText.ZIndex = 6
			local stamp, stampScale = stampOn(item, entry,
				UDim2.fromScale(0.64, 0.56), UDim2.fromScale(0.42, 0.5))
			hoverable(item, shiftCardText(entry, rank))
			table.insert(trophyIntro, {
				Item = item, Home = home, Stamp = stamp, StampScale = stampScale,
			})
		end
	end
end

----------------------------------------------------------------
-- PAGES + TABS: STAFF CARD (everything above) | SHIFT LOG (below)
----------------------------------------------------------------
local cardPage = Instance.new("Frame")
cardPage.Name = "StaffCardPage"
cardPage.Size = UDim2.fromScale(1, 1)
cardPage.BackgroundTransparency = 1
cardPage.ZIndex = 3
cardPage.Parent = root
for _, piece in ipairs({ badge, register, slotClip, shelfZone }) do
	piece.Parent = cardPage
end

local logPage = Instance.new("Frame")
logPage.Name = "ShiftLogPage"
logPage.Size = UDim2.fromScale(1, 1)
logPage.BackgroundTransparency = 1
logPage.Visible = false
logPage.ZIndex = 3
logPage.Parent = root

local logList = Instance.new("ScrollingFrame")
logList.Name = "Log"
logList.Position = UDim2.fromScale(0.05, 0.245)
logList.Size = UDim2.fromScale(0.9, 0.64)
logList.BackgroundTransparency = 1
logList.BorderSizePixel = 0
logList.ScrollBarThickness = 8
logList.ScrollBarImageColor3 = C.Choc
logList.CanvasSize = UDim2.fromScale(0, 0)
logList.AutomaticCanvasSize = Enum.AutomaticSize.Y
logList.ZIndex = 3
logList.Parent = logPage
local logLayout = Instance.new("UIListLayout")
logLayout.Padding = UDim.new(0, 10)
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
logLayout.Parent = logList
local logPad = Instance.new("UIPadding")
logPad.PaddingTop = UDim.new(0, 10)
logPad.PaddingBottom = UDim.new(0, 10)
logPad.Parent = logList

local TONE_COLOR = { good = C.Basil, mid = C.Mustard, bad = C.Tomato }
local DIFF_HEX = { EASY = "#4CAF6D", NORMAL = "#E09A1E", HARD = "#E5484D" }

--// one shift = one ORDER TICKET pinned to the cork
local logTickets = {}
local function shiftTicket(entry, index)
	local ticket = Instance.new("Frame")
	ticket.Name = "Shift" .. index
	ticket.LayoutOrder = index
	ticket.Size = UDim2.new(0.96, 0, 0, 0)
	ticket.BackgroundColor3 = Color3.fromRGB(255, 251, 242)
	ticket.Rotation = (index % 2 == 0) and 0.6 or -0.6
	ticket.ZIndex = 4
	ticket.Parent = logList
	aspect(ticket, 7.2)
	corner(ticket, UDim.new(0, 10))
	stroke(ticket, 2.5, C.Choc)

	local pin = kit.image(ticket, "PushPin", "Pin")
	if pin then
		pin.AnchorPoint = Vector2.new(0.5, 0.5)
		pin.Position = UDim2.fromScale(0.025, 0.12)
		pin.Size = UDim2.fromScale(0.06, 0.42)
		pin.ZIndex = 7
		aspect(pin, 1)
	end

	--// DATE: big day, small time
	local when = tonumber(entry.When) or os.time()
	local day = label(ticket, "Date", Enum.Font.FredokaOne, C.Choc, 34)
	day.Position = UDim2.fromScale(0.035, 0.14)
	day.Size = UDim2.fromScale(0.14, 0.44)
	day.Text = string.upper(os.date("%b %d", when))
	day.ZIndex = 5
	local clock = label(ticket, "Time", Enum.Font.GothamBold, GREY_TEXT, 16)
	clock.Position = UDim2.fromScale(0.035, 0.6)
	clock.Size = UDim2.fromScale(0.14, 0.26)
	clock.Text = os.date("%I:%M %p", when):gsub("^0", "") .. " · " .. fmtAgo(when)
	clock.ZIndex = 5

	--// the perforation between the stub and the ticket
	local perf = label(ticket, "Perforation", RECEIPT_FONT, GREY_TEXT)
	perf.Position = UDim2.fromScale(0.183, 0.04)
	perf.Size = UDim2.fromScale(0.012, 0.92)
	perf.Text = "¦\n¦\n¦\n¦"
	perf.TextTransparency = 0.4
	perf.ZIndex = 5

	--// GRADE STAMP + the full grade, difficulty and map
	local stamp = kit.image(ticket, "GradeStamp", "Stamp")
	if not stamp then
		stamp = Instance.new("Frame")
		stamp.Name = "Stamp"
		stamp.BackgroundTransparency = 1
		stamp.Parent = ticket
		stroke(stamp, 3, C.Tomato)
		corner(stamp, UDim.new(1, 0))
	end
	stamp.AnchorPoint = Vector2.new(0.5, 0.5)
	stamp.Position = UDim2.fromScale(0.255, 0.5)
	stamp.Size = UDim2.fromScale(0.12, 0.86)
	stamp.Rotation = -12
	stamp.ZIndex = 5
	aspect(stamp, 1)
	local word = label(stamp, "Word", Enum.Font.FredokaOne, C.Tomato)
	word.AnchorPoint = Vector2.new(0.5, 0.5)
	word.Position = UDim2.fromScale(0.5, 0.5)
	word.Size = UDim2.fromScale(0.62, 0.34)
	word.Text = STAMP_TEXT[entry.Grade or ""] or "★"
	word.ZIndex = 6

	local grade = label(ticket, "Grade", Enum.Font.FredokaOne, TONE_COLOR[entry.Tone] or C.Mustard, 30)
	grade.Position = UDim2.fromScale(0.33, 0.1)
	grade.Size = UDim2.fromScale(0.3, 0.32)
	grade.TextXAlignment = Enum.TextXAlignment.Left
	grade.Text = entry.Grade or "?"
	grade.TextStrokeColor3 = C.Choc
	grade.TextStrokeTransparency = 0.7
	grade.ZIndex = 5

	local where = label(ticket, "Where", Enum.Font.GothamBold, GREY_TEXT, 16)
	where.Position = UDim2.fromScale(0.33, 0.44)
	where.Size = UDim2.fromScale(0.3, 0.22)
	where.TextXAlignment = Enum.TextXAlignment.Left
	where.RichText = true
	local diffName = entry.DiffName or "NORMAL"
	where.Text = ('<font color="%s">%s</font>%s'):format(DIFF_HEX[diffName] or "#E09A1E",
		string.upper(entry.Label ~= "" and entry.Label or diffName),
		(entry.Map and entry.Map ~= "") and (" · " .. entry.Map) or "")
	where.ZIndex = 5

	local titleLine = label(ticket, "Title", Enum.Font.FredokaOne, C.Choc, 18)
	titleLine.Position = UDim2.fromScale(0.33, 0.68)
	titleLine.Size = UDim2.fromScale(0.3, 0.24)
	titleLine.TextXAlignment = Enum.TextXAlignment.Left
	titleLine.RichText = true
	local titleText = (entry.Title and entry.Title ~= "") and entry.Title or ""
	if entry.MVP then
		titleText = titleText .. (titleText ~= "" and "  " or "") .. '<font color="#E09A1E">★ MVP</font>'
	end
	titleLine.Text = titleText
	titleLine.ZIndex = 5

	--// WHAT YOU GOT: four little chips (2 x 2)
	local chips = {
		{ "CustomersServed", fmtInt(entry.Served or 0) .. " served" },
		{ "PerfectCooks", fmtInt(entry.PerfectCooks or 0) .. " perfect" },
		{ "TimeOnFloorSeconds", fmtDuration(entry.Seconds or 0) },
		{ "MoneyDeposited", "+" .. fmtMoney(entry.Coins or 0), true },
	}
	for i, chip in ipairs(chips) do
		local col = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		local holder = Instance.new("Frame")
		holder.Name = "Chip" .. i
		holder.Position = UDim2.fromScale(0.65 + col * 0.17, 0.1 + row * 0.42)
		holder.Size = UDim2.fromScale(0.16, 0.38)
		holder.BackgroundTransparency = 1
		holder.ZIndex = 5
		holder.Parent = ticket
		local icon = statIcon(holder, chip[1])
		if icon then
			icon.Size = UDim2.fromScale(0.3, 0.95)
			icon.ZIndex = 6
		end
		local value = label(holder, "Value", Enum.Font.FredokaOne, chip[3] and C.Basil or C.Choc, chip[3] and 24 or 20)
		value.Position = UDim2.fromScale(icon and 0.32 or 0, 0.05)
		value.Size = UDim2.fromScale(icon and 0.68 or 1, 0.9)
		value.TextXAlignment = Enum.TextXAlignment.Left
		value.Text = chip[2]
		value.ZIndex = 6
		if chip[3] then
			value.TextStrokeColor3 = C.Choc
			value.TextStrokeTransparency = 0.6
		end
	end

	local slide = Instance.new("UIScale")
	slide.Parent = ticket
	table.insert(logTickets, slide)
	return ticket
end

local function renderLog(entries)
	for _, child in ipairs(logList:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	table.clear(logTickets)
	if #entries == 0 then
		local empty = label(logList, "Empty", Enum.Font.FredokaOne, C.White, 30)
		empty.Size = UDim2.new(0.9, 0, 0, 90)
		empty.Text = "Your shift log starts with your next shift!"
		empty.ZIndex = 5
		stickerText(empty)
		return
	end
	for index, entry in ipairs(entries) do
		shiftTicket(entry, index)
	end
end

--// EFFECT: tickets pop onto the cork one after another
local function popTickets()
	for i, scale in ipairs(logTickets) do
		scale.Scale = 0.6
		task.delay(i * 0.06, function()
			TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end)
	end
end

--// the tab row under the chalkboard (the shop kit's tab art)
local TABS = {
	{ Key = "Card", Label = "STAFF CARD", Page = cardPage, Icon = "ShiftsCompleted" },
	{ Key = "Log", Label = "SHIFT LOG", Page = logPage, Icon = "TimeOnFloorSeconds" },
}
local tabRow = Instance.new("Frame")
tabRow.Name = "Tabs"
tabRow.Position = UDim2.fromScale(0.05, 0.155)
tabRow.Size = UDim2.fromScale(0.4, 0.08)
tabRow.BackgroundTransparency = 1
tabRow.ZIndex = 5
tabRow.Parent = root
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0.03, 0)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabRow

local tabButtons = {}
local function selectTab(key)
	for _, t in ipairs(TABS) do
		local selected = t.Key == key
		t.Page.Visible = selected
		local button = tabButtons[t.Key]
		local art = button:FindFirstChild("Art")
		local want = kit.id(selected and "TabSelected" or "TabNormal")
		if art and want then
			art.Image = want
		elseif not art then
			button.BackgroundColor3 = selected and C.Mustard or C.Cream
		end
	end
	if key == "Log" then
		popTickets()
	end
end

for i, t in ipairs(TABS) do
	local tab = Instance.new("TextButton")
	tab.Name = t.Key .. "Tab"
	tab.LayoutOrder = i
	tab.Size = UDim2.fromScale(0.48, 1)
	tab.BackgroundColor3 = C.Cream
	tab.AutoButtonColor = false
	tab.Text = ""
	tab.ZIndex = 5
	tab.Parent = tabRow
	corner(tab, UDim.new(0, 12))
	stroke(tab, 3, C.Choc)
	if kit.skin(tab, "TabNormal") then
		tab.Art.ScaleType = Enum.ScaleType.Stretch --// a wider tag than the art
	end
	local icon = statIcon(tab, t.Icon)
	if icon then
		icon.Position = UDim2.fromScale(0.07, 0.2)
		icon.Size = UDim2.fromScale(0.2, 0.6)
		icon.ZIndex = 6
	end
	local text = label(tab, "Label", Enum.Font.FredokaOne, C.White, 22)
	text.Position = UDim2.fromScale(icon and 0.28 or 0.05, 0.24)
	text.Size = UDim2.fromScale(icon and 0.66 or 0.9, 0.52)
	text.Text = t.Label
	text.ZIndex = 6
	stickerText(text)
	UIKit.bouncy(tab)
	tab.Activated:Connect(function()
		sfx("ShopClick")
		selectTab(t.Key)
	end)
	tabButtons[t.Key] = tab
end

----------------------------------------------------------------
-- Rendering from the payload (raw numbers in, formatted text out)
----------------------------------------------------------------
local introPending = false
local loopToken = 0

local function setStaticValues(payload)
	classText.Text = payload.EquippedDisplay or "No class"
	classIcon.Image = payload.EquippedIcon or ""
	classIcon.Visible = (payload.EquippedIcon or "") ~= ""
	levelText.Text = tostring(payload.Level or 1)

	for key, q in pairs(quickValues) do
		q.Label.Text = q.Format((payload.Stats and payload.Stats[key]) or 0)
	end
	for _, line in ipairs(receiptLines) do
		local formatter = FORMATTERS[line.Entry.Format] or fmtInt
		line.Value.Text = formatter(valueFor(line.Entry, payload))
	end

	local perLevel = math.max(PS.LevelShiftsPerLevel or 5, 1)
	local shifts = (payload.Stats and payload.Stats.ShiftsCompleted) or 0
	local into = shifts % perLevel
	xpFill.Size = UDim2.fromScale(math.max(into / perLevel, 0.04), 1)
	xpText.Text = ("%d / %d shifts to LVL %d"):format(into, perLevel, (payload.Level or 1) + 1)
	receiptDate.Text = "STAFF STATS · " .. os.date("%b %d")
end

--// THE SHOW: the receipt prints, numbers count up, the medal pops, the XP
--// bar fills, trophies drop onto the shelf and get stamped
local function playIntro(payload)
	--// the chalkboard swings in on its chains
	header.Rotation = -10
	header.Position = HEADER_HOME - UDim2.fromScale(0, 0.2)
	TweenService:Create(header, TweenInfo.new(0.7, Enum.EasingStyle.Elastic,
		Enum.EasingDirection.Out), { Rotation = 0, Position = HEADER_HOME }):Play()

	--// the medal pops; the XP bar fills from empty
	medalScale.Scale = 0.2
	TweenService:Create(medalScale, TweenInfo.new(0.45, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
	local fillTo = xpFill.Size
	xpFill.Size = UDim2.fromScale(0.04, 1)
	TweenService:Create(xpFill, TweenInfo.new(0.9, Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out), { Size = fillTo }):Play()

	--// the headline numbers count up
	for key, q in pairs(quickValues) do
		UIKit.countUp(q.Label, (payload.Stats and payload.Stats[key]) or 0, 0.9, q.Format)
	end

	--// the receipt feeds out of the register in ticks, each line counting
	--// up as it clears the slot
	paper.Position = UDim2.fromScale(0, -1)
	for _, line in ipairs(receiptLines) do
		line.Value.Text = ""
	end
	local mine = loopToken
	task.spawn(function()
		local steps = 12
		for step = 1, steps do
			if not isOpen or loopToken ~= mine then return end
			TweenService:Create(paper, TweenInfo.new(0.07, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { Position = UDim2.fromScale(0, -1 + step / steps) }):Play()
			sfx("ShopClick")
			task.wait(0.1)
		end
		for _, line in ipairs(receiptLines) do
			if not isOpen or loopToken ~= mine then return end
			local formatter = FORMATTERS[line.Entry.Format] or fmtInt
			UIKit.countUp(line.Value, valueFor(line.Entry, payload), line.Total and 1.1 or 0.6, formatter)
			task.wait(0.12)
			if line.Total then
				sfx("ShopPurchase") --// the total lands with the chime
			end
		end
	end)

	--// trophies drop onto the shelf, then get stamped and glint
	for i, t in ipairs(trophyIntro) do
		t.Item.Position = t.Home - UDim2.fromScale(0, 0.7)
		t.StampScale.Scale = 0
		task.delay(0.5 + i * 0.18, function()
			if not isOpen then return end
			TweenService:Create(t.Item, TweenInfo.new(0.55, Enum.EasingStyle.Bounce,
				Enum.EasingDirection.Out), { Position = t.Home }):Play()
			task.wait(0.6)
			t.StampScale.Scale = 2.2
			TweenService:Create(t.StampScale, TweenInfo.new(0.28, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end)
	end
end

local function render(payload)
	setStaticValues(payload)
	renderBestShifts(payload.BestShifts or {})
	renderLog(payload.RecentShifts or {})
	if introPending then
		introPending = false
		playIntro(payload)
	end
end

----------------------------------------------------------------
-- Looping effects (only while open)
----------------------------------------------------------------
local function startLoops()
	loopToken += 1
	local mine = loopToken
	if sunburst then
		task.spawn(function()
			while isOpen and loopToken == mine do
				sunburst.Rotation = (sunburst.Rotation + 0.35) % 360
				task.wait(1 / 30)
			end
		end)
	end
	for i, scale in ipairs(twinkles) do
		task.spawn(function()
			task.wait(i * 0.5)
			while isOpen and loopToken == mine do
				local up = TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back,
					Enum.EasingDirection.Out), { Scale = 1 })
				up:Play()
				up.Completed:Wait()
				local down = TweenService:Create(scale, TweenInfo.new(0.3), { Scale = 0 })
				down:Play()
				down.Completed:Wait()
				task.wait(1 + math.random() * 1.8)
			end
		end)
	end
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
	--// the trophies glint one after another, every few seconds
	task.spawn(function()
		task.wait(2)
		while isOpen and loopToken == mine do
			for _, t in ipairs(trophyIntro) do
				if not isOpen or loopToken ~= mine then return end
				if t.Streak and t.Streak.Parent then
					t.Streak.Position = UDim2.fromScale(-0.5, 0.5)
					TweenService:Create(t.Streak, TweenInfo.new(0.5, Enum.EasingStyle.Sine,
						Enum.EasingDirection.InOut), { Position = UDim2.fromScale(1.5, 0.5) }):Play()
					task.wait(0.25)
				end
			end
			task.wait(3)
		end
	end)
end

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------
local function setOpen(open)
	if open == isOpen then return end
	isOpen = open
	if open then
		introPending = true
		selectTab("Card") --// always open on the staff card
		gui.Enabled = true
		blur.Enabled = true
		rootScale.Scale = 0.85
		backdrop.BackgroundTransparency = 1
		TweenService:Create(rootScale, TweenInfo.new(0.28, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(backdrop, TweenInfo.new(0.2), { BackgroundTransparency = 0.5 }):Play()
		TweenService:Create(blur, TweenInfo.new(0.25), { Size = 14 }):Play()
		startLoops()
		statsRemote:FireServer("Get") --// the payload's arrival plays the intro
	else
		loopToken += 1
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

backdrop.Activated:Connect(function() setOpen(false) end)
closeButton.Activated:Connect(function() setOpen(false) end)

statsRemote.OnClientEvent:Connect(function(action, payload)
	if action == "Stats" and type(payload) == "table" and isOpen then
		render(payload)
	end
end)

----------------------------------------------------------------
-- Openers. The sticker appears IMMEDIATELY (hunting for a dock button
-- first left the lobby with no visible opener for ten seconds - owner
-- feedback). If a Studio dock button named OpenStatsButton exists or
-- appears, it takes over and the sticker retires.
----------------------------------------------------------------
local stickerGui = Instance.new("ScreenGui")
stickerGui.Name = "StatsButton_UI"
stickerGui.ResetOnSpawn = false
stickerGui.DisplayOrder = 10
stickerGui.Parent = playerGui

local sticker = Instance.new("TextButton")
sticker.Name = "StatsSticker"
sticker.AnchorPoint = Vector2.new(0, 0.5)
sticker.Position = UDim2.fromScale(0.025, 0.76) --// below the SHOP! sticker (Oct 2026)
sticker.Size = UDim2.fromScale(0.085, 0.075)
sticker.BackgroundColor3 = C.Mustard
sticker.Rotation = 2
sticker.Font = Enum.Font.FredokaOne
sticker.TextScaled = true
sticker.Text = "STATS"
stickerText(sticker)
sticker.Parent = stickerGui
corner(sticker, UDim.new(0, 10))
stroke(sticker, 2.5, C.Choc)

sticker.Activated:Connect(function()
	setOpen(not isOpen)
end)

task.spawn(function()
	local waited = 0
	while waited < 10 do
		local dockButton = playerGui:FindFirstChild("OpenStatsButton", true)
		if dockButton and dockButton:IsA("GuiButton") then
			dockButton.Activated:Connect(function()
				setOpen(not isOpen)
			end)
			stickerGui:Destroy()
			print("[StatsClient] dock button found - sticker retired, opens from "
				.. dockButton:GetFullName())
			return
		end
		task.wait(0.5)
		waited += 0.5
	end
end)
