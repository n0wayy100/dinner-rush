--[[
	Dinner Rush - ShiftReportClient
	StarterPlayer.StarterPlayerScripts.Client.ShiftReportClient  (LocalScript)

	The end-of-shift report card. Render only: the server computed every
	number, the emergencies line, and the verdict (ShiftReportRemote fires
	one "Show" payload to everyone at shift end). Nothing here derives a
	stat - it prints what it was handed.

	When payload.Awards is present the AWARDS CEREMONY plays first (see
	the section below): title cards for the whole crew, then the MVP
	crown - the report card waits its turn behind the theatre.

	The fun is the drumroll: rows reveal one by one (payload.RowReveal
	apart), then the verdict stamp slams in - rotated, thick-bordered,
	coloured by GradeTone ("good" basil / "mid" mustard / "bad" tomato).
	A failed shift prints its reason under the stamp; if someone put water
	on a grease fire, the team gets the receipt too.

	Sits at DisplayOrder 60 - above HudClient's centre overlay (50), which
	is also disabled while the panel is up and restored on dismiss.
	Auto-dismisses after payload.AutoDismiss; the X dismisses early.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local reportRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ShiftReportRemote")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SCORE = Config.Score

local CREAM = Color3.fromRGB(255, 246, 233)
local WARM = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)

local TONE_COLOR = {
	good = BASIL,
	mid = MUSTARD,
	bad = TOMATO,
}

----------------------------------------------------------------
-- Panel: built once, filled per report
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ShiftReport_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 60 --// above the HUD's centre overlay (50)
gui.Enabled = false
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.47)
panel.Size = UDim2.fromScale(0.56, 0.68)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = CHOC
stroke.Parent = panel

local grad = Instance.new("UIGradient")
grad.Rotation = 90
grad.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
grad.Parent = panel

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.fromScale(0.5, 0.025)
title.Size = UDim2.fromScale(0.7, 0.09)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.TextColor3 = CHOC
title.Text = "SHIFT REPORT"
title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.fromScale(0.975, 0.025)
closeBtn.Size = UDim2.fromScale(0.08, 0.08)
closeBtn.BackgroundColor3 = TOMATO
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextScaled = true
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "X"
closeBtn.Parent = panel

local cbc = Instance.new("UICorner")
cbc.CornerRadius = UDim.new(0, 8)
cbc.Parent = closeBtn

local cbs = Instance.new("UIStroke")
cbs.Thickness = 2
cbs.Color = CHOC
cbs.Parent = closeBtn

local rowsHolder = Instance.new("Frame")
rowsHolder.Name = "Rows"
rowsHolder.AnchorPoint = Vector2.new(0.5, 0)
rowsHolder.Position = UDim2.fromScale(0.5, 0.13)
rowsHolder.Size = UDim2.fromScale(0.9, 0.56)
rowsHolder.BackgroundTransparency = 1
rowsHolder.Parent = panel

local rowsLayout = Instance.new("UIListLayout")
rowsLayout.FillDirection = Enum.FillDirection.Vertical
rowsLayout.Padding = UDim.new(0.012, 0)
rowsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowsLayout.Parent = rowsHolder

--// The stamp: rotated, thick border, slams in last with a bounce
local stamp = Instance.new("TextLabel")
stamp.Name = "Stamp"
stamp.AnchorPoint = Vector2.new(0.5, 0.5)
stamp.Position = UDim2.fromScale(0.5, 0.81)
stamp.Size = UDim2.fromScale(0, 0) --// grows in on reveal
stamp.Rotation = -8
stamp.BackgroundColor3 = TOMATO
stamp.Font = Enum.Font.FredokaOne
stamp.TextScaled = true
stamp.TextColor3 = Color3.new(1, 1, 1)
stamp.Text = ""
stamp.Visible = false
stamp.Parent = panel

local stampCorner = Instance.new("UICorner")
stampCorner.CornerRadius = UDim.new(0, 10)
stampCorner.Parent = stamp

local stampStroke = Instance.new("UIStroke")
stampStroke.Thickness = 4
stampStroke.Color = CHOC
stampStroke.Parent = stamp

local stampPad = Instance.new("UIPadding")
stampPad.PaddingLeft = UDim.new(0.06, 0)
stampPad.PaddingRight = UDim.new(0.06, 0)
stampPad.PaddingTop = UDim.new(0.08, 0)
stampPad.PaddingBottom = UDim.new(0.08, 0)
stampPad.Parent = stamp

--// The receipts under the stamp: failure reason and/or the water incident
local receipts = Instance.new("TextLabel")
receipts.Name = "Receipts"
receipts.AnchorPoint = Vector2.new(0.5, 0)
receipts.Position = UDim2.fromScale(0.5, 0.9)
receipts.Size = UDim2.fromScale(0.9, 0.08)
receipts.BackgroundTransparency = 1
receipts.Font = Enum.Font.FredokaOne
receipts.TextScaled = true
receipts.TextWrapped = true
receipts.TextColor3 = CHOC
receipts.TextTransparency = 0.25
receipts.Text = ""
receipts.Visible = false
receipts.Parent = panel

----------------------------------------------------------------
-- Rows
----------------------------------------------------------------
local STAMP_SIZE = UDim2.fromScale(0.55, 0.16)

local function clearRows()
	for _, child in ipairs(rowsHolder:GetChildren()) do
		if child:IsA("CanvasGroup") then
			child:Destroy()
		end
	end
end

--// A hidden row; revealRow fades and slides it in
local function buildRow(order, labelText, valueText, valueColor)
	local row = Instance.new("CanvasGroup")
	row.Size = UDim2.fromScale(1, 0.098)
	row.GroupTransparency = 1
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = rowsHolder

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0.02, 0.5)
	label.Size = UDim2.fromScale(0.55, 0.95)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = CHOC
	label.Text = labelText
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.fromScale(0.98, 0.5)
	value.Size = UDim2.fromScale(0.41, 0.95)
	value.BackgroundTransparency = 1
	value.Font = Enum.Font.FredokaOne
	value.TextScaled = true
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextColor3 = valueColor or CHOC
	value.Text = valueText
	value.Parent = row

	return row
end

local function revealRow(row)
	TweenService:Create(row,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ GroupTransparency = 0 }):Play()
end

----------------------------------------------------------------
-- Show / dismiss
----------------------------------------------------------------
local seq = 0
local hiddenIntro = nil --// HudClient's centre overlay, restored on dismiss

local function dismiss()
	seq += 1
	gui.Enabled = false
	if hiddenIntro and hiddenIntro.Parent then
		hiddenIntro.Enabled = true
	end
	hiddenIntro = nil
end

closeBtn.Activated:Connect(dismiss)

local function showReport(payload)
	seq += 1
	local mySeq = seq

	clearRows()
	stamp.Visible = false
	stamp.Size = UDim2.fromScale(0, 0)
	receipts.Visible = false

	--// The HUD's own end overlay would fight the panel in the same spot
	local intro = playerGui:FindFirstChild("ShiftIntro")
	if intro and intro:IsA("ScreenGui") and intro.Enabled then
		intro.Enabled = false
		hiddenIntro = intro
	end

	local netPositive = (payload.Net or 0) >= 0
	local rows = {
		--// Owner ruling: the plain count, no "/ target" framing - the
		--// grade stamp already does the judging
		buildRow(1, "Parties served", tostring(payload.Served or 0)),
		buildRow(2, "Walkouts", tostring(payload.Walkouts or 0),
			(payload.Walkouts or 0) > 0 and TOMATO or CHOC),
		buildRow(3, "Perfect cooks", tostring(payload.PerfectCooks or 0),
			(payload.PerfectCooks or 0) > 0 and BASIL or CHOC),
		buildRow(4, "Burnt dishes", tostring(payload.BurntDishes or 0),
			(payload.BurntDishes or 0) > 0 and TOMATO or CHOC),
		buildRow(5, "Emergencies", payload.EmergenciesLine or "No emergencies!"),
		buildRow(6, "Money earned", "$" .. tostring(payload.Earned or 0)),
		buildRow(7, "Supplies spent", "$" .. tostring(payload.Spent or 0)),
		buildRow(8, "Net", ("%s$%d"):format(netPositive and "+" or "-",
			math.abs(payload.Net or 0)), netPositive and BASIL or TOMATO),
		buildRow(9, "Final reputation", tostring(payload.Reputation or 0)),
	}

	gui.Enabled = true

	--// The drumroll
	task.spawn(function()
		for _, row in ipairs(rows) do
			if seq ~= mySeq then return end
			revealRow(row)
			task.wait(payload.RowReveal or 0.35)
		end

		if seq ~= mySeq then return end

		--// The stamp slams in
		stamp.Text = payload.Grade or "?"
		stamp.BackgroundColor3 = TONE_COLOR[payload.GradeTone] or TOMATO
		stamp.Visible = true
		TweenService:Create(stamp,
			TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = STAMP_SIZE }):Play()

		--// The receipts
		local lines = {}
		if payload.FailReason and payload.FailReason ~= "" then
			table.insert(lines, payload.FailReason)
		end
		if (payload.WaterIncidents or 0) > 0 then
			table.insert(lines, (payload.WaterIncidents or 0) == 1
				and "(and someone put water on a grease fire)"
				or ("(and someone put water on a grease fire... x%d)"):format(payload.WaterIncidents))
		end
		if #lines > 0 then
			receipts.Text = table.concat(lines, "  ")
			receipts.Visible = true
		end
	end)

	--// Auto-dismiss; the X gets there sooner if anyone is impatient
	task.delay(payload.AutoDismiss or 12, function()
		if seq == mySeq then
			dismiss()
		end
	end)
end

----------------------------------------------------------------
-- THE AWARDS CEREMONY (before the report card). The hidden shift
-- score's reveal: one title card per player - avatar, name, title -
-- popping in one by one, then the MVP crown with its receipt lines.
-- Tap anywhere to hurry a phase along. Everything here is printed
-- verbatim from the server's awards payload; the point math never
-- reached the client at all.
----------------------------------------------------------------
local awardsGui = Instance.new("ScreenGui")
awardsGui.Name = "ShiftAwards_UI"
awardsGui.ResetOnSpawn = false
awardsGui.IgnoreGuiInset = true
awardsGui.DisplayOrder = 65 --// above the report (60)
awardsGui.Enabled = false
awardsGui.Parent = playerGui

local dim = Instance.new("Frame")
dim.Size = UDim2.fromScale(1, 1)
dim.BackgroundColor3 = CHOC
dim.BackgroundTransparency = 0.3
dim.BorderSizePixel = 0
dim.Parent = awardsGui

--// Tap anywhere = hurry
local ceremonyCatcher = Instance.new("TextButton")
ceremonyCatcher.Size = UDim2.fromScale(1, 1)
ceremonyCatcher.BackgroundTransparency = 1
ceremonyCatcher.Text = ""
ceremonyCatcher.Parent = awardsGui

local awardsHeader = Instance.new("TextLabel")
awardsHeader.AnchorPoint = Vector2.new(0.5, 0)
awardsHeader.Position = UDim2.fromScale(0.5, 0.08)
awardsHeader.Size = UDim2.fromScale(0.8, 0.1)
awardsHeader.BackgroundTransparency = 1
awardsHeader.Font = Enum.Font.FredokaOne
awardsHeader.TextScaled = true
awardsHeader.TextColor3 = CREAM
awardsHeader.TextStrokeColor3 = CHOC
awardsHeader.TextStrokeTransparency = 0
awardsHeader.Text = ""
awardsHeader.Parent = awardsGui

local tapHint = Instance.new("TextLabel")
tapHint.AnchorPoint = Vector2.new(0.5, 1)
tapHint.Position = UDim2.fromScale(0.5, 0.97)
tapHint.Size = UDim2.fromScale(0.5, 0.04)
tapHint.BackgroundTransparency = 1
tapHint.Font = Enum.Font.FredokaOne
tapHint.TextScaled = true
tapHint.TextColor3 = CREAM
tapHint.TextTransparency = 0.35
tapHint.Text = "tap to continue"
tapHint.Parent = awardsGui

local cardsHolder = Instance.new("Frame")
cardsHolder.AnchorPoint = Vector2.new(0.5, 0.5)
cardsHolder.Position = UDim2.fromScale(0.5, 0.52)
cardsHolder.Size = UDim2.fromScale(0.96, 0.48)
cardsHolder.BackgroundTransparency = 1
cardsHolder.Parent = awardsGui

local cardsLayout = Instance.new("UIListLayout")
cardsLayout.FillDirection = Enum.FillDirection.Horizontal
cardsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
cardsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
cardsLayout.SortOrder = Enum.SortOrder.LayoutOrder
cardsLayout.Padding = UDim.new(0.012, 0)
cardsLayout.Parent = cardsHolder

local function avatarUrl(userId)
	return ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(userId)
end

--// One title card: avatar in a circle, name, emoji, title
local function buildTitleCard(order, entry)
	local card = Instance.new("Frame")
	card.Size = UDim2.fromScale(0.155, 1)
	card.LayoutOrder = order
	card.BackgroundColor3 = CREAM
	card.Parent = cardsHolder

	local scale = Instance.new("UIScale")
	scale.Scale = 0 --// pops in on reveal
	scale.Parent = card

	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 14)
	cc.Parent = card

	local cs = Instance.new("UIStroke")
	cs.Thickness = 3
	cs.Color = CHOC
	cs.Parent = card

	local cg = Instance.new("UIGradient")
	cg.Rotation = 90
	cg.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
	cg.Parent = card

	local avatar = Instance.new("ImageLabel")
	avatar.AnchorPoint = Vector2.new(0.5, 0)
	avatar.Position = UDim2.fromScale(0.5, 0.06)
	avatar.Size = UDim2.fromScale(0.66, 0.4)
	avatar.BackgroundColor3 = WARM
	avatar.Image = avatarUrl(entry.UserId)
	avatar.Parent = card

	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = avatar

	local ac = Instance.new("UICorner")
	ac.CornerRadius = UDim.new(1, 0)
	ac.Parent = avatar

	local as = Instance.new("UIStroke")
	as.Thickness = 2
	as.Color = CHOC
	as.Parent = avatar

	local name = Instance.new("TextLabel")
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.fromScale(0.5, 0.5)
	name.Size = UDim2.fromScale(0.92, 0.12)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = CHOC
	name.Text = entry.Name or "?"
	name.Parent = card

	local emoji = Instance.new("TextLabel")
	emoji.AnchorPoint = Vector2.new(0.5, 0)
	emoji.Position = UDim2.fromScale(0.5, 0.63)
	emoji.Size = UDim2.fromScale(0.9, 0.17)
	emoji.BackgroundTransparency = 1
	emoji.Font = Enum.Font.FredokaOne
	emoji.TextScaled = true
	emoji.Text = entry.Emoji or "🌟"
	emoji.Parent = card

	local titleText = Instance.new("TextLabel")
	titleText.AnchorPoint = Vector2.new(0.5, 0)
	titleText.Position = UDim2.fromScale(0.5, 0.81)
	titleText.Size = UDim2.fromScale(0.94, 0.13)
	titleText.BackgroundTransparency = 1
	titleText.Font = Enum.Font.FredokaOne
	titleText.TextScaled = true
	titleText.TextColor3 = TOMATO
	titleText.Text = entry.Title or ""
	titleText.Parent = card

	return scale
end

--// The MVP screen: crown, big avatar, name, receipt lines
local mvpFrame = Instance.new("Frame")
mvpFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mvpFrame.Position = UDim2.fromScale(0.5, 0.54)
mvpFrame.Size = UDim2.fromScale(0.34, 0.66)
mvpFrame.BackgroundColor3 = CREAM
mvpFrame.Visible = false
mvpFrame.Parent = awardsGui

local mvpScale = Instance.new("UIScale")
mvpScale.Parent = mvpFrame

local mc = Instance.new("UICorner")
mc.CornerRadius = UDim.new(0, 16)
mc.Parent = mvpFrame

local ms = Instance.new("UIStroke")
ms.Thickness = 5
ms.Color = MUSTARD --// the gold frame
ms.Parent = mvpFrame

local mg = Instance.new("UIGradient")
mg.Rotation = 90
mg.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
mg.Parent = mvpFrame

local crown = Instance.new("TextLabel")
crown.AnchorPoint = Vector2.new(0.5, 0)
crown.Position = UDim2.fromScale(0.5, 0.02)
crown.Size = UDim2.fromScale(0.5, 0.14)
crown.BackgroundTransparency = 1
crown.Font = Enum.Font.FredokaOne
crown.TextScaled = true
crown.Text = "👑"
crown.Parent = mvpFrame

local mvpAvatar = Instance.new("ImageLabel")
mvpAvatar.AnchorPoint = Vector2.new(0.5, 0)
mvpAvatar.Position = UDim2.fromScale(0.5, 0.17)
mvpAvatar.Size = UDim2.fromScale(0.42, 0.34)
mvpAvatar.BackgroundColor3 = WARM
mvpAvatar.Parent = mvpFrame

local mar = Instance.new("UIAspectRatioConstraint")
mar.AspectRatio = 1
mar.Parent = mvpAvatar

local mac = Instance.new("UICorner")
mac.CornerRadius = UDim.new(1, 0)
mac.Parent = mvpAvatar

local mas = Instance.new("UIStroke")
mas.Thickness = 3
mas.Color = MUSTARD
mas.Parent = mvpAvatar

local mvpBanner = Instance.new("TextLabel")
mvpBanner.AnchorPoint = Vector2.new(0.5, 0)
mvpBanner.Position = UDim2.fromScale(0.5, 0.53)
mvpBanner.Size = UDim2.fromScale(0.8, 0.12)
mvpBanner.BackgroundTransparency = 1
mvpBanner.Font = Enum.Font.FredokaOne
mvpBanner.TextScaled = true
mvpBanner.TextColor3 = TOMATO
mvpBanner.Text = "MVP!"
mvpBanner.Parent = mvpFrame

local mvpName = Instance.new("TextLabel")
mvpName.AnchorPoint = Vector2.new(0.5, 0)
mvpName.Position = UDim2.fromScale(0.5, 0.66)
mvpName.Size = UDim2.fromScale(0.9, 0.11)
mvpName.BackgroundTransparency = 1
mvpName.Font = Enum.Font.FredokaOne
mvpName.TextScaled = true
mvpName.TextColor3 = CHOC
mvpName.Text = ""
mvpName.Parent = mvpFrame

local mvpReceipts = Instance.new("TextLabel")
mvpReceipts.AnchorPoint = Vector2.new(0.5, 0)
mvpReceipts.Position = UDim2.fromScale(0.5, 0.78)
mvpReceipts.Size = UDim2.fromScale(0.9, 0.18)
mvpReceipts.BackgroundTransparency = 1
mvpReceipts.Font = Enum.Font.FredokaOne
mvpReceipts.TextScaled = true
mvpReceipts.TextWrapped = true
mvpReceipts.TextColor3 = CHOC
mvpReceipts.TextTransparency = 0.2
mvpReceipts.Text = ""
mvpReceipts.Parent = mvpFrame

local ceremonySeq = 0
local ceremonyTapped = false

ceremonyCatcher.Activated:Connect(function()
	ceremonyTapped = true
end)

--// Wait that a tap (or a newer ceremony) cuts short
local function ceremonyWait(seconds, mySeq)
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if ceremonySeq ~= mySeq or ceremonyTapped then return end
		task.wait(0.05)
	end
end

local function endCeremony()
	awardsGui.Enabled = false
	mvpFrame.Visible = false
end

local function runCeremony(awards, done)
	ceremonySeq += 1
	local mySeq = ceremonySeq
	ceremonyTapped = false

	--// Same courtesy showReport extends: the HUD's end overlay would
	--// fight the ceremony, and dismiss() restores it later
	local intro = playerGui:FindFirstChild("ShiftIntro")
	if intro and intro:IsA("ScreenGui") and intro.Enabled then
		intro.Enabled = false
		hiddenIntro = intro
	end

	for _, child in ipairs(cardsHolder:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	mvpFrame.Visible = false
	cardsHolder.Visible = true
	awardsHeader.Text = "⭐ TONIGHT'S CREW ⭐"

	local scales = {}
	for order, entry in ipairs(awards.Players) do
		table.insert(scales, buildTitleCard(order, entry))
	end

	awardsGui.Enabled = true

	task.spawn(function()
		--// Phase 1: the crew, one card at a time (a tap deals the rest)
		for _, scale in ipairs(scales) do
			if ceremonySeq ~= mySeq then return end
			TweenService:Create(scale,
				TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }):Play()
			ceremonyWait(SCORE.CardRevealSeconds, mySeq)
		end
		if ceremonySeq ~= mySeq then return end
		for _, scale in ipairs(scales) do
			scale.Scale = 1 --// a tap mid-stagger still shows everyone
		end

		ceremonyTapped = false
		ceremonyWait(SCORE.TitlesHoldSeconds, mySeq)
		if ceremonySeq ~= mySeq then return end

		--// Phase 2: the crown
		if awards.MVP then
			cardsHolder.Visible = false
			awardsHeader.Text = awards.Solo and "AND TONIGHT'S HERO..." or "AND TONIGHT'S MVP..."
			mvpBanner.Text = awards.Solo and (SCORE.SoloBanner .. "!") or "MVP!"
			mvpAvatar.Image = avatarUrl(awards.MVP.UserId)
			mvpName.Text = awards.MVP.Name or "?"
			mvpReceipts.Text = table.concat(awards.MVP.Receipts or {}, "\n")
			mvpFrame.Visible = true
			mvpScale.Scale = 0
			TweenService:Create(mvpScale,
				TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }):Play()

			ceremonyTapped = false
			ceremonyWait(SCORE.MVPHoldSeconds, mySeq)
			if ceremonySeq ~= mySeq then return end
		end

		endCeremony()
		done()
	end)
end

reportRemote.OnClientEvent:Connect(function(action, payload)
	if action == "Show" and type(payload) == "table" then
		local awards = payload.Awards
		if type(awards) == "table" and type(awards.Players) == "table"
			and #awards.Players > 0 then
			--// Owner ruling: the ceremony FIRST, the stat rows only after
			runCeremony(awards, function()
				showReport(payload)
			end)
		else
			showReport(payload)
		end
	end
end)
