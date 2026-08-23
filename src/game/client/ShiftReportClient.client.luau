--[[
	Dinner Rush - ShiftReportClient
	StarterPlayer.StarterPlayerScripts.Client.ShiftReportClient  (LocalScript)

	The end-of-shift report card. Render only: the server computed every
	number, the emergencies line, and the verdict (ShiftReportRemote fires
	one "Show" payload to everyone at shift end). Nothing here derives a
	stat - it prints what it was handed.

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
		buildRow(1, "Served", ("%d / %d"):format(payload.Served or 0, payload.Target or 0)),
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

reportRemote.OnClientEvent:Connect(function(action, payload)
	if action == "Show" and type(payload) == "table" then
		showReport(payload)
	end
end)
