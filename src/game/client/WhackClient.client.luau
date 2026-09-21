--[[
	Dinner Rush - WhackClient
	StarterPlayer.StarterPlayerScripts.Client.WhackClient  (LocalScript)

	WHACK (Sep 21 2026 - one of two games replacing recipe math). Ingredient
	icons pop up around the pan; tap them before they vanish. The SERVER owns
	each target's up-window and validates every tap (WhackRemote), so this is
	render + report only. Fully latency-tolerant: a target is up for a WINDOW,
	any tap inside it counts.

	Protocol:
	  server -> client  ("Open", {Token, Targets = {{At,Up,Slot,Icon}}, TotalSeconds})
	                    ("HitOk", token, targetIndex)
	                    ("End", token, hits, quality)
	                    ("Close", token)
	  client -> server  ("Hit", token, targetIndex)

	Inputs: tap/click a target directly; gamepad A whacks the one about to
	vanish (so console players can play without a cursor).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local remote = remotes:WaitForChild("WhackRemote")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local WHK = Config.Whack

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local WHITE = Color3.fromRGB(255, 255, 255)

local HOLE_DARK = Color3.fromRGB(70, 48, 34)
local HOLE_RIM = Color3.fromRGB(120, 86, 58)

--// 3x3 grid: slot positions (scale) in the play area
local function slotXY(slot)
	local col = (slot - 1) % 3
	local row = math.floor((slot - 1) / 3)
	return 0.2 + col * 0.3, 0.2 + row * 0.3
end
local function slotPos(slot)
	local x, y = slotXY(slot)
	return UDim2.fromScale(x, y)
end

local gui = Instance.new("ScreenGui")
gui.Name = "Whack_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Enabled = false
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.55)
panel.Size = UDim2.fromScale(0.62, 0.66)
panel.BackgroundColor3 = CREAM
panel.Parent = gui
local panelRatio = Instance.new("UIAspectRatioConstraint")
panelRatio.AspectRatio = 1.02
panelRatio.Parent = panel
local panelGrad = Instance.new("UIGradient")
panelGrad.Rotation = 90
panelGrad.Color = ColorSequence.new(CREAM, CREAM_DEEP)
panelGrad.Parent = panel
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0.06, 0)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 3
panelStroke.Color = CHOC
panelStroke.Parent = panel

local header = Instance.new("TextLabel")
header.BackgroundColor3 = TOMATO
header.BorderSizePixel = 0
header.Size = UDim2.fromScale(1, 0.14)
header.Font = Enum.Font.FredokaOne
header.TextScaled = true
header.TextColor3 = WHITE
header.Text = "👋 GRAB ONLY THIS!"
header.Parent = panel
local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0.3, 0)
headerCorner.Parent = header
local headerCap = Instance.new("UITextSizeConstraint")
headerCap.MaxTextSize = 24
headerCap.Parent = header

--// the ONE ingredient to hit, shown big so decoys are obvious
local targetBanner = Instance.new("Frame")
targetBanner.Position = UDim2.fromScale(0.32, 0.15)
targetBanner.Size = UDim2.fromScale(0.36, 0.16)
targetBanner.BackgroundColor3 = WHITE
targetBanner.Parent = panel
local tbCorner = Instance.new("UICorner")
tbCorner.CornerRadius = UDim.new(0.3, 0)
tbCorner.Parent = targetBanner
local tbStroke = Instance.new("UIStroke")
tbStroke.Thickness = 2.5
tbStroke.Color = BASIL
tbStroke.Parent = targetBanner
local targetImage = Instance.new("ImageLabel")
targetImage.AnchorPoint = Vector2.new(0.5, 0.5)
targetImage.Position = UDim2.fromScale(0.5, 0.5)
targetImage.Size = UDim2.fromScale(0.85, 0.85)
targetImage.BackgroundTransparency = 1
targetImage.ScaleType = Enum.ScaleType.Fit
targetImage.Image = ""
targetImage.Parent = targetBanner

local playArea = Instance.new("Frame")
playArea.Position = UDim2.fromScale(0, 0.3)
playArea.Size = UDim2.fromScale(1, 0.7)
playArea.BackgroundTransparency = 1
playArea.Parent = panel

--// THE HOLES: a static 3x3 grid the pop-ups rise from. Built once; the
--// moles live in a layer above them (moleLayer) and are cleared per game.
local holeLayer = Instance.new("Frame")
holeLayer.Size = UDim2.fromScale(1, 1)
holeLayer.BackgroundTransparency = 1
holeLayer.ZIndex = 1
holeLayer.Parent = playArea

for slot = 1, 9 do
	local hole = Instance.new("Frame")
	hole.AnchorPoint = Vector2.new(0.5, 0.5)
	hole.Position = slotPos(slot)
	hole.Size = UDim2.fromScale(0.24, 0.16)
	hole.BackgroundColor3 = HOLE_DARK
	hole.ZIndex = 1
	hole.Parent = holeLayer
	local hc = Instance.new("UICorner")
	hc.CornerRadius = UDim.new(1, 0)
	hc.Parent = hole
	local hs = Instance.new("UIStroke")
	hs.Thickness = 3
	hs.Color = HOLE_RIM
	hs.Parent = hole
end

local moleLayer = Instance.new("Frame")
moleLayer.Size = UDim2.fromScale(1, 1)
moleLayer.BackgroundTransparency = 1
moleLayer.ClipsDescendants = false
moleLayer.ZIndex = 2
moleLayer.Parent = playArea

local verdict = Instance.new("TextLabel")
verdict.AnchorPoint = Vector2.new(0.5, 0.5)
verdict.Position = UDim2.fromScale(0.5, 0.5)
verdict.Size = UDim2.fromScale(0.9, 0.35)
verdict.BackgroundTransparency = 1
verdict.Font = Enum.Font.FredokaOne
verdict.TextScaled = true
verdict.Text = ""
verdict.TextColor3 = CHOC
verdict.TextStrokeColor3 = WHITE
verdict.TextStrokeTransparency = 0.2
verdict.Visible = false
verdict.ZIndex = 10
verdict.Parent = panel
local verdictCap = Instance.new("UITextSizeConstraint")
verdictCap.MaxTextSize = 38
verdictCap.Parent = verdict

----------------------------------------------------------------
-- Session
----------------------------------------------------------------
local session = nil --// { Token, Targets, Start, Widgets }
local renderConn = nil

local function stopRender()
	if renderConn then renderConn:Disconnect() renderConn = nil end
end

local function clearTargets()
	for _, child in ipairs(moleLayer:GetChildren()) do
		child:Destroy()
	end
end

local function closePanel()
	stopRender()
	clearTargets()
	gui.Enabled = false
	session = nil
	ContextActionService:UnbindAction("Whack")
end

local function makeTargetButton(index, target)
	local x, y = slotXY(target.Slot)

	--// anchored at its BASE (just inside the hole) so growing the Size
	--// makes the mole rise straight up out of the hole
	local btn = Instance.new("ImageButton")
	btn.Name = "Target"
	btn.AnchorPoint = Vector2.new(0.5, 1)
	btn.Position = UDim2.fromScale(x, y + 0.05)
	btn.Size = UDim2.fromScale(0.05, 0.02)
	btn.BackgroundColor3 = MUSTARD
	btn.AutoButtonColor = false
	--// the ingredient art rides the BUTTON itself (a child ImageLabel was
	--// rendering blank) - Fit keeps its aspect, centred on the mustard mole
	btn.Image = target.Icon or ""
	btn.ScaleType = Enum.ScaleType.Fit
	btn.ZIndex = 3
	btn.Parent = moleLayer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.45, 0)
	corner.Parent = btn
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = CHOC
	stroke.Parent = btn

	--// rise out of the hole (base stays put, it grows upward)
	TweenService:Create(btn, TweenInfo.new(0.14, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.26, 0.3) }):Play()

	btn.Activated:Connect(function()
		if session then remote:FireServer("Hit", session.Token, index) end
	end)
	return btn
end

--// duck a mole back down into its hole, then remove it
local function duckAway(btn, tint)
	if not btn then return end
	if tint then btn.BackgroundColor3 = tint end
	TweenService:Create(btn, TweenInfo.new(0.16, Enum.EasingStyle.Quad,
		Enum.EasingDirection.In), { Size = UDim2.fromScale(0.04, 0.02) }):Play()
	task.delay(0.18, function() if btn then btn:Destroy() end end)
end

--// gamepad: whack the CORRECT-ingredient pop-up about to vanish (icon ==
--// the target icon), so console players never auto-hit a decoy
local function whackSoonest()
	if not session then return end
	local elapsed = os.clock() - session.Start
	local best, bestLeft
	for i, target in ipairs(session.Targets) do
		local w = session.Widgets[i]
		if w and w.Button and not w.Done and target.Icon == session.TargetIcon then
			local left = (target.At + target.Up) - elapsed
			if not bestLeft or left < bestLeft then
				best, bestLeft = i, left
			end
		end
	end
	if best then remote:FireServer("Hit", session.Token, best) end
end

remote.OnClientEvent:Connect(function(action, a, b, c)
	if action == "Open" then
		local payload = a
		closePanel()
		clearTargets()
		verdict.Visible = false

		local widgets = {}
		for i = 1, #payload.Targets do
			widgets[i] = { Button = nil, Done = false }
		end
		session = {
			Token = payload.Token,
			Targets = payload.Targets,
			TargetIcon = payload.TargetIcon,
			Start = os.clock(),
			Widgets = widgets,
		}
		targetImage.Image = payload.TargetIcon or ""
		gui.Enabled = true

		ContextActionService:BindAction("Whack", function(_, state)
			if state == Enum.UserInputState.Begin then whackSoonest() end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonA)

		renderConn = RunService.RenderStepped:Connect(function()
			if not session then return end
			local elapsed = os.clock() - session.Start
			for i, target in ipairs(session.Targets) do
				local w = session.Widgets[i]
				if w and not w.Done then
					local up = elapsed >= target.At and elapsed <= target.At + target.Up
					if up and not w.Button then
						w.Button = makeTargetButton(i, target)
					elseif not up and elapsed > target.At + target.Up then
						--// ducked back into the hole unhit = a miss
						w.Done = true
						if w.Button then
							duckAway(w.Button)
							w.Button = nil
						end
					end
				end
			end
		end)

	elseif action == "HitOk" then
		local w = session and session.Widgets[b]
		if w and w.Button and not w.Done then
			w.Done = true
			duckAway(w.Button, BASIL) --// bonked! green, back in the hole
			w.Button = nil
		end

	elseif action == "Wrong" then
		--// hit a decoy: red, back in the hole
		local w = session and session.Widgets[b]
		if w and w.Button and not w.Done then
			w.Done = true
			duckAway(w.Button, TOMATO)
			w.Button = nil
		end

	elseif action == "End" then
		local quality = c
		stopRender()
		clearTargets()
		verdict.Visible = true
		if quality == "Perfect" then
			verdict.Text = "MASTER COOK!"
			verdict.TextColor3 = BASIL
		elseif quality == "Good" then
			verdict.Text = "DECENT COOK"
			verdict.TextColor3 = MUSTARD
		elseif quality == "Overcooked" then
			verdict.Text = "OVERCOOKED"
			verdict.TextColor3 = TOMATO
		else
			verdict.Text = "RUINED! BIN IT"
			verdict.TextColor3 = TOMATO
		end
		task.delay(1.1, function()
			if session and session.Token == a then closePanel() end
		end)

	elseif action == "Close" then
		closePanel()
	end
end)
