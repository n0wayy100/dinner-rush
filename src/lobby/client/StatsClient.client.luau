--[[
	Dinner Rush - StatsClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.StatsClient  (LocalScript)

	The player STATS screen: a passport card (headshot, equipped class,
	level badge, quick numbers) over a registry-driven lifetime stat list
	and a BEST SHIFTS history column. Single panel, no tabs - a bottom tab
	row can bolt on later when there is more history to show.

	REGISTRY-DRIVEN: the rows are built by iterating
	Config.PlayerStats.Registry. Adding a stat there makes it appear here
	with its label, format, and default - this file never changes for a
	new stat. The client formats and draws; every number, the level, and
	the Best Shifts ranking arrive computed from the server.

	Opens from: a Studio dock button named OpenStatsButton if one exists
	(PanelClose convention), otherwise the code-built STATS sticker this
	script adds at the left edge. Dimmed backdrop click, X, or the sticker
	again all close it. Pop-in tween on open.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local statsRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StatsRemote")

local REGISTRY = Config.PlayerStats.Registry

local CREAM = Color3.fromRGB(255, 246, 233)
local WARM = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local GREY_TEXT = Color3.fromRGB(122, 112, 102)

local DIFF_COLOR = {
	EASY = BASIL,
	NORMAL = MUSTARD,
	HARD = TOMATO,
}
local TONE_COLOR = {
	good = BASIL,
	mid = MUSTARD,
	bad = TOMATO,
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

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
	local s = tostring(n)
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return formatted
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
		return "TODAY"
	elseif days == 1 then
		return "1 DAY AGO"
	elseif days < 60 then
		return ("%d DAYS AGO"):format(days)
	end
	return ("%d MONTHS AGO"):format(math.floor(days / 30))
end

local FORMATTERS = {
	int = fmtInt,
	money = fmtMoney,
	duration = fmtDuration,
}

----------------------------------------------------------------
-- Chrome helpers
----------------------------------------------------------------
local function stylize(frame, thickness, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 12)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or 2.5
	stroke.Color = CHOC
	stroke.Parent = frame
	return stroke
end

local function makeText(parent, font, color)
	local label = Instance.new("TextLabel")
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
-- Skeleton: backdrop + panel
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Stats_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 32
gui.Parent = playerGui

--// Dimmed backdrop; clicking it closes the panel
local backdrop = Instance.new("TextButton")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 0.45
backdrop.Text = ""
backdrop.AutoButtonColor = false
backdrop.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.64, 0.76)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local panelAspect = Instance.new("UIAspectRatioConstraint")
panelAspect.AspectRatio = 1.5
panelAspect.Parent = panel

stylize(panel, 3, 16)

local grad = Instance.new("UIGradient")
grad.Rotation = 90
grad.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
grad.Parent = panel

--// Title sticker + close
local title = makeText(panel, Enum.Font.FredokaOne, Color3.new(1, 1, 1))
title.AnchorPoint = Vector2.new(0, 0.5)
title.Position = UDim2.fromScale(0.03, 0)
title.Size = UDim2.fromScale(0.17, 0.09)
title.BackgroundTransparency = 0
title.BackgroundColor3 = MUSTARD
title.Rotation = -2
title.Text = "STATS"
title.TextStrokeColor3 = CHOC
title.TextStrokeTransparency = 0
stylize(title, 2.5, 10)

--// Rides the panel's top-right corner, sticker-style, with a high ZIndex
--// so nothing built after it (the passport card) can paint over it
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.AnchorPoint = Vector2.new(0.5, 0.5)
closeBtn.Position = UDim2.fromScale(0.99, 0.01)
closeBtn.Size = UDim2.fromScale(0.07, 0.09)
closeBtn.Rotation = 3
closeBtn.ZIndex = 10
closeBtn.BackgroundColor3 = TOMATO
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextScaled = true
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "X"
closeBtn.Parent = panel
stylize(closeBtn, 2.5, 8)

----------------------------------------------------------------
-- Passport card
----------------------------------------------------------------
local card = Instance.new("Frame")
card.Name = "Passport"
card.AnchorPoint = Vector2.new(0.5, 0)
card.Position = UDim2.fromScale(0.5, 0.035)
card.Size = UDim2.fromScale(0.94, 0.24)
card.BackgroundColor3 = CHOC
card.Parent = panel
stylize(card, 2.5, 12)

local headshot = Instance.new("ImageLabel")
headshot.AnchorPoint = Vector2.new(0, 0.5)
headshot.Position = UDim2.fromScale(0.02, 0.5)
headshot.Size = UDim2.fromScale(0.16, 0.8)
headshot.BackgroundColor3 = WARM
headshot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(player.UserId)
headshot.Parent = card
stylize(headshot, 2, 10)

local headshotAspect = Instance.new("UIAspectRatioConstraint")
headshotAspect.AspectRatio = 1
headshotAspect.Parent = headshot

local nameLabel = makeText(card, Enum.Font.FredokaOne, MUSTARD)
nameLabel.AnchorPoint = Vector2.new(0, 0)
nameLabel.Position = UDim2.fromScale(0.2, 0.1)
nameLabel.Size = UDim2.fromScale(0.42, 0.3)
nameLabel.TextXAlignment = Enum.TextXAlignment.Left
nameLabel.Text = player.Name

local classIcon = Instance.new("ImageLabel")
classIcon.AnchorPoint = Vector2.new(0, 0.5)
classIcon.Position = UDim2.fromScale(0.2, 0.62)
classIcon.Size = UDim2.fromScale(0.08, 0.32)
classIcon.BackgroundTransparency = 1
classIcon.ScaleType = Enum.ScaleType.Fit
classIcon.Parent = card

local classIconAspect = Instance.new("UIAspectRatioConstraint")
classIconAspect.AspectRatio = 1
classIconAspect.Parent = classIcon

local classLabel = makeText(card, Enum.Font.GothamBold, CREAM)
classLabel.AnchorPoint = Vector2.new(0, 0.5)
classLabel.Position = UDim2.fromScale(0.27, 0.62)
classLabel.Size = UDim2.fromScale(0.3, 0.22)
classLabel.TextXAlignment = Enum.TextXAlignment.Left

--// LVL badge, mustard pill
local levelBadge = makeText(card, Enum.Font.FredokaOne, CHOC)
levelBadge.AnchorPoint = Vector2.new(1, 0)
levelBadge.Position = UDim2.fromScale(0.975, 0.1)
levelBadge.Size = UDim2.fromScale(0.18, 0.28)
levelBadge.BackgroundTransparency = 0
levelBadge.BackgroundColor3 = MUSTARD
levelBadge.Text = "LVL 1"
stylize(levelBadge, 2, 10)

--// The quick trio on the card: shifts / dishes / time on floor
local quickHolder = Instance.new("Frame")
quickHolder.AnchorPoint = Vector2.new(1, 1)
quickHolder.Position = UDim2.fromScale(0.975, 0.9)
quickHolder.Size = UDim2.fromScale(0.36, 0.46)
quickHolder.BackgroundTransparency = 1
quickHolder.Parent = card

local quickLayout = Instance.new("UIListLayout")
quickLayout.FillDirection = Enum.FillDirection.Vertical
quickLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
quickLayout.Parent = quickHolder

local quickRows = {}
for index, caption in ipairs({ "Shifts", "Dishes", "Time On Floor" }) do
	local row = Instance.new("Frame")
	row.Size = UDim2.fromScale(1, 0.32)
	row.BackgroundTransparency = 1
	row.LayoutOrder = index
	row.Parent = quickHolder

	local label = makeText(row, Enum.Font.Gotham, CREAM)
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0, 0.5)
	label.Size = UDim2.fromScale(0.6, 0.9)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTransparency = 0.2
	label.Text = caption

	local value = makeText(row, Enum.Font.FredokaOne, MUSTARD)
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.fromScale(1, 0.5)
	value.Size = UDim2.fromScale(0.38, 1)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Text = "-"

	quickRows[caption] = value
end

----------------------------------------------------------------
-- Left: lifetime stat rows, built FROM THE REGISTRY
----------------------------------------------------------------
local statList = Instance.new("ScrollingFrame")
statList.Name = "StatList"
statList.AnchorPoint = Vector2.new(0, 1)
statList.Position = UDim2.fromScale(0.03, 0.965)
statList.Size = UDim2.fromScale(0.45, 0.65)
statList.BackgroundTransparency = 1
statList.BorderSizePixel = 0
statList.ScrollBarThickness = 6
statList.CanvasSize = UDim2.fromScale(0, 0)
statList.AutomaticCanvasSize = Enum.AutomaticSize.Y
statList.Parent = panel

local statLayout = Instance.new("UIListLayout")
statLayout.Padding = UDim.new(0.008, 0)
statLayout.SortOrder = Enum.SortOrder.LayoutOrder
statLayout.Parent = statList

local statValues = {}
for index, entry in ipairs(REGISTRY) do
	local row = Instance.new("Frame")
	row.Name = entry.Key
	row.Size = UDim2.fromScale(1, 0.115)
	--// Alternating fills keep a long list readable
	row.BackgroundColor3 = index % 2 == 0 and WARM or Color3.new(1, 1, 1)
	row.BackgroundTransparency = 0.25
	row.LayoutOrder = index
	row.Parent = statList

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 8)
	rowCorner.Parent = row

	local label = makeText(row, Enum.Font.GothamMedium, CHOC)
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0.04, 0.5)
	label.Size = UDim2.fromScale(0.6, 0.62)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = entry.Label

	local value = makeText(row, Enum.Font.FredokaOne, CHOC)
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.fromScale(0.96, 0.5)
	value.Size = UDim2.fromScale(0.32, 0.7)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Text = "-"

	statValues[entry.Key] = value
end

----------------------------------------------------------------
-- Right: BEST SHIFTS
----------------------------------------------------------------
local bestHeader = makeText(panel, Enum.Font.FredokaOne, Color3.new(1, 1, 1))
bestHeader.AnchorPoint = Vector2.new(1, 0)
bestHeader.Position = UDim2.fromScale(0.97, 0.315)
bestHeader.Size = UDim2.fromScale(0.45, 0.055)
bestHeader.BackgroundTransparency = 0
bestHeader.BackgroundColor3 = CHOC
bestHeader.Text = "★ BEST SHIFTS"
stylize(bestHeader, 2, 8)

local bestList = Instance.new("Frame")
bestList.Name = "BestShifts"
bestList.AnchorPoint = Vector2.new(1, 1)
bestList.Position = UDim2.fromScale(0.97, 0.965)
bestList.Size = UDim2.fromScale(0.45, 0.575)
bestList.BackgroundTransparency = 1
bestList.Parent = panel

local bestLayout = Instance.new("UIListLayout")
bestLayout.Padding = UDim.new(0.015, 0)
bestLayout.SortOrder = Enum.SortOrder.LayoutOrder
bestLayout.Parent = bestList

local function renderBestShifts(entries)
	for _, child in ipairs(bestList:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		local empty = makeText(bestList, Enum.Font.Gotham, GREY_TEXT)
		empty.Size = UDim2.fromScale(1, 0.2)
		empty.Text = "No shifts on record yet. Get cooking!"
		local holder = Instance.new("Frame")
		holder.Size = UDim2.fromScale(1, 0.2)
		holder.BackgroundTransparency = 1
		holder.Parent = bestList
		empty.Parent = holder
		return
	end

	for index, entry in ipairs(entries) do
		local cardFrame = Instance.new("Frame")
		cardFrame.Size = UDim2.fromScale(1, 0.185)
		cardFrame.BackgroundColor3 = Color3.new(1, 1, 1)
		cardFrame.BackgroundTransparency = 0.15
		cardFrame.LayoutOrder = index
		cardFrame.Parent = bestList
		stylize(cardFrame, 2, 8)

		--// Row 1: grade (tone colour) + difficulty label (difficulty colour)
		local grade = makeText(cardFrame, Enum.Font.FredokaOne,
			TONE_COLOR[entry.Tone] or MUSTARD)
		grade.AnchorPoint = Vector2.new(0, 0)
		grade.Position = UDim2.fromScale(0.03, 0.08)
		grade.Size = UDim2.fromScale(0.52, 0.42)
		grade.TextXAlignment = Enum.TextXAlignment.Left
		grade.TextStrokeColor3 = CHOC
		grade.TextStrokeTransparency = 0.6
		grade.Text = entry.Grade or "?"

		local diff = makeText(cardFrame, Enum.Font.GothamBold,
			DIFF_COLOR[entry.DiffName] or MUSTARD)
		diff.AnchorPoint = Vector2.new(1, 0)
		diff.Position = UDim2.fromScale(0.97, 0.1)
		diff.Size = UDim2.fromScale(0.4, 0.34)
		diff.TextXAlignment = Enum.TextXAlignment.Right
		diff.Text = entry.Label or entry.DiffName or ""

		--// Row 2: the receipts
		local detail = makeText(cardFrame, Enum.Font.Gotham, GREY_TEXT)
		detail.AnchorPoint = Vector2.new(0, 1)
		detail.Position = UDim2.fromScale(0.03, 0.9)
		detail.Size = UDim2.fromScale(0.7, 0.32)
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.Text = ("%d/%d served  ·  %s  ·  %s"):format(
			entry.Served or 0, entry.Target or 0,
			fmtMoney(entry.Net), fmtDuration(entry.Seconds))

		local ago = makeText(cardFrame, Enum.Font.GothamBold, GREY_TEXT)
		ago.AnchorPoint = Vector2.new(1, 1)
		ago.Position = UDim2.fromScale(0.97, 0.9)
		ago.Size = UDim2.fromScale(0.25, 0.28)
		ago.TextXAlignment = Enum.TextXAlignment.Right
		ago.Text = fmtAgo(entry.When)
	end
end

----------------------------------------------------------------
-- Rendering from the payload (raw numbers in, formatted text out)
----------------------------------------------------------------
local function valueFor(entry, payload)
	if entry.Source == "TaskProgress" then
		return (payload.TaskProgress and payload.TaskProgress[entry.Key]) or entry.Default
	end
	return (payload.Stats and payload.Stats[entry.Key]) or entry.Default
end

local function render(payload)
	levelBadge.Text = ("LVL %d"):format(payload.Level or 1)
	classLabel.Text = payload.EquippedDisplay or "No class"
	classIcon.Image = payload.EquippedIcon or ""
	classIcon.Visible = (payload.EquippedIcon or "") ~= ""

	for _, entry in ipairs(REGISTRY) do
		local box = statValues[entry.Key]
		if box then
			local formatter = FORMATTERS[entry.Format] or fmtInt
			box.Text = formatter(valueFor(entry, payload))
		end
	end

	quickRows["Shifts"].Text = fmtInt((payload.Stats and payload.Stats.ShiftsCompleted) or 0)
	quickRows["Dishes"].Text = fmtInt((payload.TaskProgress and payload.TaskProgress.DishesServed) or 0)
	quickRows["Time On Floor"].Text = fmtDuration((payload.Stats and payload.Stats.TimeOnFloorSeconds) or 0)

	renderBestShifts(payload.BestShifts or {})
end

----------------------------------------------------------------
-- Open / close with the pop-in
----------------------------------------------------------------
local PANEL_SIZE = UDim2.fromScale(0.64, 0.76)
local isOpen = false

local function setOpen(open)
	isOpen = open
	gui.Enabled = open
	panel.Visible = open

	if open then
		statsRemote:FireServer("Get")
		panel.Size = UDim2.fromScale(PANEL_SIZE.X.Scale * 0.85, PANEL_SIZE.Y.Scale * 0.85)
		TweenService:Create(panel,
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = PANEL_SIZE }):Play()
	end
end

backdrop.Activated:Connect(function()
	setOpen(false)
end)
closeBtn.Activated:Connect(function()
	setOpen(false)
end)

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
sticker.Position = UDim2.fromScale(0.025, 0.62)
sticker.Size = UDim2.fromScale(0.085, 0.075)
sticker.BackgroundColor3 = MUSTARD
sticker.Rotation = 2
sticker.Font = Enum.Font.FredokaOne
sticker.TextScaled = true
sticker.TextColor3 = Color3.new(1, 1, 1)
sticker.TextStrokeColor3 = CHOC
sticker.TextStrokeTransparency = 0
sticker.Text = "STATS"
sticker.Parent = stickerGui
stylize(sticker, 2.5, 10)

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
