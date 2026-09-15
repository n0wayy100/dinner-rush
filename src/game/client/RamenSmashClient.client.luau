--[[
	Dinner Rush - RamenSmashClient
	StarterPlayer.StarterPlayerScripts.Client.RamenSmashClient  (LocalScript)

	THE SMASH GAME (Config.RamenSmash - the name survives its ramen-only
	debut; any cook that draws game 2 of the minigame coin flip plays
	this). Owner spec: the POINTER is fixed at the top; three coloured
	arcs ORBIT the rim - yellow big and cheap, blue middling, green
	small and precious. Tap (click / touch / Space / gamepad A) when an
	arc passes under the pointer to score its points. Arcs that run
	into each other slow down.

	The SERVER simulates the arcs and snapshots the truth ("Sync") a few
	times a second; this panel extrapolates between snapshots and taps.
	DELIBERATELY DISH-BLIND (owner spec): no dish name, no food emoji -
	one identical panel for every method on every map.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local RAMEN = Config.RamenSmash
if not RAMEN then return end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local ramenRemote = remotes:WaitForChild("RamenSmashRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)

--// Arc colours by index - MUST mirror Config.RamenSmash.Arcs order
local ARC_COLORS = {
	Color3.fromRGB(245, 184, 65),  -- yellow: big, cheap
	Color3.fromRGB(86, 148, 223),  -- blue: middling
	Color3.fromRGB(76, 175, 109),  -- green: small, precious
}

--// Dish-blind on purpose: these fit a bowl, a burger, and whatever
--// comes next
local VERDICTS = {
	Perfect = { Text = "MASTER COOK!", Color = Color3.fromRGB(76, 175, 109) },
	Good = { Text = "DECENT COOK", Color = Color3.fromRGB(245, 184, 65) },
	Ruined = { Text = "RUINED! BIN IT!", Color = Color3.fromRGB(229, 72, 77) },
	Overcooked = { Text = "SLOPPY WORK...", Color = Color3.fromRGB(150, 130, 120) },
}

local session = nil

local function teardown()
	if not session then return end
	if session.Conn then session.Conn:Disconnect() end
	ContextActionService:UnbindAction("RamenSmashTap")
	if session.Gui then session.Gui:Destroy() end
	session = nil
end

local function sendTap()
	if session and not session.Done then
		ramenRemote:FireServer("Tap", session.Token)
	end
end

--// Degrees clockwise from top -> position on the ring
local function ringPosition(angleDeg, radius)
	local rad = math.rad(angleDeg)
	return UDim2.fromScale(0.5 + radius * math.sin(rad), 0.5 - radius * math.cos(rad))
end

local function buildPanel(data)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RamenSmash_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Active = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.42, 0.6)
	panel.Position = UDim2.fromScale(0.5, 0.46)
	panel.BackgroundColor3 = CREAM
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
	gradient.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.06, 0)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = CHOC
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Active = false
	title.Size = UDim2.fromScale(0.9, 0.11)
	title.Position = UDim2.fromScale(0.05, 0.03)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "COLOR SMASH! Tap when a colour hits the pointer!"
	title.TextColor3 = CHOC
	title.Parent = panel

	--// THE RING
	local ring = Instance.new("Frame")
	ring.Active = false
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Size = UDim2.fromScale(0.72, 0.72)
	ring.SizeConstraint = Enum.SizeConstraint.RelativeYY
	ring.Position = UDim2.fromScale(0.5, 0.52)
	ring.BackgroundTransparency = 1
	ring.Parent = panel
	local ringCircle = Instance.new("Frame")
	ringCircle.Active = false
	ringCircle.Size = UDim2.fromScale(1, 1)
	ringCircle.BackgroundColor3 = CREAM_DEEP
	ringCircle.Parent = ring
	local rcCorner = Instance.new("UICorner")
	rcCorner.CornerRadius = UDim.new(0.5, 0)
	rcCorner.Parent = ringCircle
	local rcStroke = Instance.new("UIStroke")
	rcStroke.Thickness = 5
	rcStroke.Color = CHOC
	rcStroke.Parent = ringCircle

	--// THE POINTER: fixed at the top, pointing down at the rim
	local pointer = Instance.new("TextLabel")
	pointer.Active = false
	pointer.AnchorPoint = Vector2.new(0.5, 1)
	pointer.Size = UDim2.fromScale(0.22, 0.22)
	pointer.Position = UDim2.fromScale(0.5, 0.04)
	pointer.BackgroundTransparency = 1
	pointer.Font = Enum.Font.FredokaOne
	pointer.TextScaled = true
	pointer.Text = "▼"
	pointer.TextColor3 = CHOC
	pointer.Parent = ring

	--// THE ARCS: chains of RECTANGULAR chips hugging the rim, each
	--// rotated to its tangent. Widths follow the arc's LIVE size, so
	--// shrinking arcs visibly tighten.
	local arcDots = {}
	for index, arcDef in ipairs(data.Arcs) do
		local color = ARC_COLORS[index] or CREAM_DEEP
		local count = arcDef.Chips or math.max(1, math.ceil(arcDef.SizeDeg / 30))
		local dots = {}
		for d = 1, count do
			local chip = Instance.new("Frame")
			chip.Active = false
			chip.AnchorPoint = Vector2.new(0.5, 0.5)
			chip.Size = UDim2.fromScale(0.2, 0.09)
			chip.BackgroundColor3 = color
			chip.Parent = ring
			local chipCorner = Instance.new("UICorner")
			chipCorner.CornerRadius = UDim.new(0.2, 0)
			chipCorner.Parent = chip
			local chipStroke = Instance.new("UIStroke")
			chipStroke.Thickness = 2
			chipStroke.Color = CHOC
			chipStroke.Parent = chip
			dots[d] = chip
		end
		arcDots[index] = dots
	end

	local score = Instance.new("TextLabel")
	score.Active = false
	score.Size = UDim2.fromScale(0.26, 0.1)
	score.Position = UDim2.fromScale(0.04, 0.16)
	score.BackgroundTransparency = 1
	score.Font = Enum.Font.FredokaOne
	score.TextScaled = true
	score.Text = "0 pts"
	score.TextColor3 = CHOC
	score.Parent = panel

	local timerBack = Instance.new("Frame")
	timerBack.Active = false
	timerBack.Size = UDim2.fromScale(0.9, 0.06)
	timerBack.Position = UDim2.fromScale(0.05, 0.91)
	timerBack.BackgroundColor3 = CREAM_DEEP
	timerBack.BorderSizePixel = 0
	timerBack.Parent = panel
	local timerCorner = Instance.new("UICorner")
	timerCorner.CornerRadius = UDim.new(0.5, 0)
	timerCorner.Parent = timerBack
	local timerFill = Instance.new("Frame")
	timerFill.Active = false
	timerFill.Size = UDim2.fromScale(1, 1)
	timerFill.BackgroundColor3 = MUSTARD
	timerFill.BorderSizePixel = 0
	timerFill.Parent = timerBack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = timerFill

	return gui, panel, arcDots, score, timerFill
end

ramenRemote.OnClientEvent:Connect(function(action, a, b, c)
	if action == "Open" then
		teardown()
		local data = a
		local gui, panel, arcDots, score, timerFill = buildPanel(data)
		local arcs = {}
		for index, arcDef in ipairs(data.Arcs) do
			arcs[index] = {
				SizeDeg = arcDef.SizeDeg,
				Angle = arcDef.Angle,
				Speed = arcDef.Speed,
				SyncedAt = os.clock(),
				Dots = arcDots[index],
			}
		end
		session = {
			Token = data.Token,
			Gui = gui,
			Panel = panel,
			Arcs = arcs,
			ScoreLabel = score,
			TimerFill = timerFill,
			Start = os.clock(),
			Seconds = data.GameSeconds,
			Done = false,
		}

		session.Conn = RunService.RenderStepped:Connect(function()
			if not session or session.Done then return end
			local now = os.clock()
			for _, arc in ipairs(session.Arcs) do
				--// extrapolate from the last server snapshot
				local angle = (arc.Angle + arc.Speed * (now - arc.SyncedAt)) % 360
				local count = #arc.Dots
				local step = arc.SizeDeg / count
				--// a degree of rim is ~pi/360 of the ring frame across
				local chipWidth = math.max(step * 0.0082, 0.05)
				for d, chip in ipairs(arc.Dots) do
					local chipAngle = angle + (d - (count + 1) / 2) * step
					chip.Position = ringPosition(chipAngle, 0.5)
					chip.Rotation = chipAngle --// tangent to the rim
					chip.Size = UDim2.fromScale(chipWidth, 0.11)
				end
			end
			session.TimerFill.Size = UDim2.fromScale(
				math.clamp(1 - (now - session.Start) / session.Seconds, 0, 1), 1)
		end)

		ContextActionService:BindAction("RamenSmashTap", function(_, state)
			if state == Enum.UserInputState.Begin then sendTap() end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)

	elseif action == "Sync" then
		if not session or session.Token ~= a then return end
		local now = os.clock()
		for index, snap in ipairs(b) do
			local arc = session.Arcs[index]
			if arc then
				arc.Angle = snap.Angle
				arc.Speed = snap.Speed
				arc.SizeDeg = snap.Size or arc.SizeDeg
				arc.SyncedAt = now
			end
		end

	elseif action == "Hit" then
		if not session or session.Token ~= a then return end
		session.ScoreLabel.Text = b .. " pts"
		--// the layout re-rolls on every hit: snap straight to the
		--// server's fresh positions (and shrunken sizes)
		local now = os.clock()
		for index, snap in ipairs(c.Arcs or {}) do
			local arc = session.Arcs[index]
			if arc then
				arc.Angle = snap.Angle
				arc.Speed = snap.Speed
				arc.SizeDeg = snap.Size or arc.SizeDeg
				arc.SyncedAt = now
			end
		end
		--// "+N" pops off the pointer
		local pop = Instance.new("TextLabel")
		pop.Active = false
		pop.AnchorPoint = Vector2.new(0.5, 0.5)
		pop.Size = UDim2.fromScale(0.24, 0.16)
		pop.Position = UDim2.fromScale(0.5, 0.12)
		pop.BackgroundTransparency = 1
		pop.Font = Enum.Font.FredokaOne
		pop.TextScaled = true
		pop.Text = "+" .. (c.Points or "?")
		pop.TextColor3 = Color3.fromRGB(76, 175, 109)
		pop.TextStrokeColor3 = CHOC
		pop.TextStrokeTransparency = 0
		pop.Parent = session.Panel
		TweenService:Create(pop, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.02), TextTransparency = 1,
				TextStrokeTransparency = 1 }):Play()
		task.delay(0.55, function() pop:Destroy() end)

	elseif action == "Miss" then
		if not session or session.Token ~= a then return end
		session.ScoreLabel.Text = b .. " pts"
		--// the board scrambles on a miss too
		local now = os.clock()
		for index, snap in ipairs((c and c.Arcs) or {}) do
			local arc = session.Arcs[index]
			if arc then
				arc.Angle = snap.Angle
				arc.Speed = snap.Speed
				arc.SizeDeg = snap.Size or arc.SizeDeg
				arc.SyncedAt = now
			end
		end
		local panel = session.Panel
		panel.Position = UDim2.fromScale(0.51, 0.48)
		TweenService:Create(panel, TweenInfo.new(0.1),
			{ Position = UDim2.fromScale(0.5, 0.48) }):Play()
		--// "-N" stings in tomato
		local pop = Instance.new("TextLabel")
		pop.Active = false
		pop.AnchorPoint = Vector2.new(0.5, 0.5)
		pop.Size = UDim2.fromScale(0.24, 0.16)
		pop.Position = UDim2.fromScale(0.5, 0.12)
		pop.BackgroundTransparency = 1
		pop.Font = Enum.Font.FredokaOne
		pop.TextScaled = true
		pop.Text = "-" .. ((c and c.Penalty) or "?")
		pop.TextColor3 = Color3.fromRGB(229, 72, 77)
		pop.TextStrokeColor3 = CHOC
		pop.TextStrokeTransparency = 0
		pop.Parent = session.Panel
		TweenService:Create(pop, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.02), TextTransparency = 1,
				TextStrokeTransparency = 1 }):Play()
		task.delay(0.55, function() pop:Destroy() end)

	elseif action == "End" then
		if not session or session.Token ~= a then return end
		session.Done = true
		local verdict = VERDICTS[c] or VERDICTS.Overcooked
		local splash = Instance.new("TextLabel")
		splash.Active = false
		splash.Size = UDim2.fromScale(0.9, 0.28)
		splash.Position = UDim2.fromScale(0.05, 0.36)
		splash.BackgroundTransparency = 1
		splash.Font = Enum.Font.FredokaOne
		splash.TextScaled = true
		splash.Text = verdict.Text
		splash.TextColor3 = verdict.Color
		splash.TextStrokeColor3 = CHOC
		splash.TextStrokeTransparency = 0
		splash.Parent = session.Panel
		task.delay(1.4, teardown)

	elseif action == "Close" then
		if session and session.Token == a then
			teardown()
		end
	end
end)

--// Mouse / touch taps (keys and gamepad ride ContextActionService above)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not session or session.Done then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		sendTap()
	end
end)

print("[RamenSmash] ready - any pan can draw the smash")
