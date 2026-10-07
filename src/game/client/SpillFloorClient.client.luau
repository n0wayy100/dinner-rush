--[[
	Dinner Rush - SpillFloorClient
	StarterPlayer.StarterPlayerScripts.Client.SpillFloorClient  (LocalScript)

	THE DINER-FLOOR SCENE version of the spill sweep (Oct 2026, Claude
	Design Prompt D). Runs ONLY when Config.Events.SpillSweep.Style is
	"Diner" - "Classic" runs SpillSweepClient instead, so the owner can
	compare the two. Same server, same protocol, same rules:

	  server -> client  "Open" {Token, StrokesNeeded}
	                    "Progress" token, fill (0..1)
	                    "Close" token, success
	  client -> server  "Stroke" token   (one per StrokeTravelFraction of travel)

	The picture: a checkered diner floor seen from above, a wet-floor sign
	in the corner, a glossy puddle with droplets around it, and a push
	broom you DRAG across it (mouse/touch anywhere on the floor, gamepad
	left stick, arrow keys). The broom tilts into the stroke, dust and
	spray puff off the bristles, droplets flick away. The puddle shrinks
	big -> medium -> small as the server's count climbs; dry = sparkles,
	a shine sweeps the floor and the SPOTLESS stamp slams.

	Render/report only: the server counts the strokes and owns the finish.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SWEEP = Config.Events and Config.Events.SpillSweep
if not SWEEP or (SWEEP.Style or "Classic") ~= "Diner" then return end

local ART = SWEEP.DinerArt or {}
local sweepRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SpillSweepRemote")

local CHOC = Color3.fromRGB(59, 43, 32)
local BASIL = Color3.fromRGB(76, 175, 109)
local MUSTARD = Color3.fromRGB(245, 184, 65)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function image(parent, key)
	local img = Instance.new("ImageLabel")
	img.Name = key
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Image = ART[key] or ""
	img.Parent = parent
	return img
end

local function aspect(obj, ratio)
	local a = Instance.new("UIAspectRatioConstraint")
	a.AspectRatio = ratio
	a.Parent = obj
end

local function playSheet(img, frames, fps)
	img.ImageRectSize = Vector2.new(256, 256)
	task.spawn(function()
		for i = 0, frames - 1 do
			if not img.Parent then return end
			img.ImageRectOffset = Vector2.new((i % 4) * 256, math.floor(i / 4) * 256)
			task.wait(1 / fps)
		end
		img:Destroy()
	end)
end

----------------------------------------------------------------
-- The scene (built once)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "SpillFloor_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.55)
panel.BackgroundTransparency = 1
panel.Parent = gui
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

local function layout()
	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(1366, 768)
	local side = math.floor(math.clamp(math.min(view.X * 0.36, view.Y * 0.6), 260, 460))
	panel.Size = UDim2.fromOffset(side, side)
end
layout()
do
	local function watch()
		local camera = workspace.CurrentCamera
		if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout) end
		layout()
	end
	watch()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watch)
end

local floorArt = image(panel, "Floor_Panel")
floorArt.ScaleType = Enum.ScaleType.Stretch
floorArt.Position = UDim2.fromScale(0.5, 0.5)
floorArt.Size = UDim2.fromScale(1, 1)
floorArt.ZIndex = 1

--// the play area inside the frame: drags anywhere here sweep
local floor = Instance.new("TextButton")
floor.Name = "Floor"
floor.Text = ""
floor.AutoButtonColor = false
floor.BackgroundTransparency = 1
floor.AnchorPoint = Vector2.new(0.5, 0.5)
floor.Position = UDim2.fromScale(0.5, 0.5)
floor.Size = UDim2.fromScale(0.84, 0.84)
floor.ClipsDescendants = true
floor.ZIndex = 2
floor.Parent = panel

local sign = image(panel, "Wet_Sign")
sign.Position = UDim2.fromScale(0.86, 0.17)
sign.Size = UDim2.fromScale(0.2, 0.2)
sign.ZIndex = 6

--// the three puddle sizes stack; the right one shows for the progress
local puddles = {}
for i, key in ipairs({ "Puddle_Big", "Puddle_Medium", "Puddle_Small" }) do
	local p = image(floor, key)
	p.Position = UDim2.fromScale(0.5, 0.52)
	p.Size = UDim2.fromScale(0.95, 0.95)
	p.ZIndex = 3
	p.ImageTransparency = i == 1 and 0 or 1
	puddles[i] = p
end
local puddleScale = Instance.new("UIScale")
puddleScale.Parent = floor

local droplets = {}

local broom = image(floor, "Broom")
broom.AnchorPoint = Vector2.new(0.5, 0.82) --// the bristles track the finger
broom.Size = UDim2.fromScale(0.32, 0.64)
broom.ZIndex = 7

local arrows = image(panel, "Drag_Arrows")
arrows.Position = UDim2.fromScale(0.5, 0.86)
arrows.Size = UDim2.fromScale(0.36, 0.18)
arrows.ZIndex = 8
local arrowScale = Instance.new("UIScale")
arrowScale.Parent = arrows

local caption = Instance.new("TextLabel")
caption.BackgroundTransparency = 1
caption.AnchorPoint = Vector2.new(0.5, 0)
caption.Position = UDim2.fromScale(0.42, 0.065)
caption.Size = UDim2.fromScale(0.6, 0.09)
caption.Font = Enum.Font.FredokaOne
caption.TextScaled = true
caption.Text = "SWEEP IT UP!"
caption.TextColor3 = Color3.new(1, 1, 1)
caption.TextStrokeColor3 = CHOC
caption.TextStrokeTransparency = 0
caption.ZIndex = 9
caption.Parent = panel

local shine = image(floor, "Shine_Floor")
shine.ScaleType = Enum.ScaleType.Stretch
shine.Size = UDim2.fromScale(0.5, 1.4)
shine.Position = UDim2.fromScale(-0.4, 0.5)
shine.ZIndex = 8
shine.Visible = false

local stamp = image(panel, "Clean_Stamp")
stamp.Position = UDim2.fromScale(0.5, 0.5)
stamp.Size = UDim2.fromScale(0.56, 0.56)
stamp.ZIndex = 12
stamp.Visible = false
local stampScale = Instance.new("UIScale")
stampScale.Parent = stamp

----------------------------------------------------------------
-- Effects
----------------------------------------------------------------
local function scatterDroplets()
	for _, d in ipairs(droplets) do d:Destroy() end
	droplets = {}
	for _ = 1, 9 do
		local d = image(floor, "Droplet")
		local angle = math.random() * math.pi * 2
		local dist = 0.26 + math.random() * 0.16
		d.Position = UDim2.fromScale(0.5 + math.cos(angle) * dist, 0.52 + math.sin(angle) * dist * 0.8)
		local s = 0.05 + math.random() * 0.04
		d.Size = UDim2.fromScale(s, s)
		d.ZIndex = 4
		table.insert(droplets, d)
	end
end

local function dustPuff(at, dir)
	local puff = image(floor, "Bristle_Dust_Sheet")
	puff.Position = UDim2.fromScale(at.X - dir * 0.08, at.Y)
	puff.Size = UDim2.fromScale(0.22, 0.22)
	puff.ImageTransparency = 0.1
	puff.Rotation = dir > 0 and 0 or 180
	puff.ZIndex = 6
	playSheet(puff, 16, 30)
end

local function flickDrop(at, dir)
	local d = image(floor, "Droplet")
	d.Position = UDim2.fromScale(at.X, at.Y)
	d.Size = UDim2.fromScale(0.04, 0.04)
	d.ZIndex = 6
	local target = UDim2.fromScale(at.X - dir * (0.15 + math.random() * 0.15),
		at.Y + (math.random() - 0.5) * 0.25)
	tween(d, 0.35, { Position = target, ImageTransparency = 1, Size = UDim2.fromScale(0.02, 0.02) })
	task.delay(0.36, function() d:Destroy() end)
end

local function sparkleBurst(count)
	for _ = 1, count do
		task.delay(math.random() * 0.6, function()
			local s = image(floor, "Sparkle_Clean")
			s.ImageColor3 = math.random() < 0.5 and Color3.new(1, 1, 1) or MUSTARD
			s.Position = UDim2.fromScale(0.15 + math.random() * 0.7, 0.15 + math.random() * 0.7)
			s.Size = UDim2.fromScale(0, 0)
			s.ZIndex = 9
			local size = 0.08 + math.random() * 0.08
			tween(s, 0.25, { Size = UDim2.fromScale(size, size), Rotation = 45 }, Enum.EasingStyle.Back)
			task.delay(0.35, function()
				tween(s, 0.3, { Size = UDim2.fromScale(0, 0), Rotation = 90 })
				task.delay(0.32, function() s:Destroy() end)
			end)
		end)
	end
end

----------------------------------------------------------------
-- Session
----------------------------------------------------------------
local session = nil
local conns = {}

local function teardown()
	for _, c in ipairs(conns) do c:Disconnect() end
	conns = {}
	ContextActionService:UnbindAction("SpillFloorStick")
	ContextActionService:UnbindAction("SpillFloorKeys")
	session = nil
	tween(panelScale, 0.2, { Scale = 0.8 })
	task.delay(0.22, function()
		if not session then gui.Enabled = false end
	end)
end

local function setProgress(fill)
	--// big -> medium -> small, then gone; the active one shrinks a touch too
	local stage = fill < 0.34 and 1 or (fill < 0.67 and 2 or 3)
	for i, p in ipairs(puddles) do
		local want = (i == stage and fill < 1) and 0 or 1
		if p.ImageTransparency ~= want then
			tween(p, 0.25, { ImageTransparency = want })
		end
	end
	puddleScale.Scale = 1 - (fill % 0.34) * 0.3
	--// droplets dry up as it goes
	local keep = math.ceil(#droplets * (1 - fill))
	for i = #droplets, keep + 1, -1 do
		local d = droplets[i]
		if d and d.Parent then
			tween(d, 0.3, { Size = UDim2.fromScale(0, 0), ImageTransparency = 1 })
			task.delay(0.32, function() d:Destroy() end)
		end
		droplets[i] = nil
	end
end

local function finish()
	session.Done = true
	caption.Text = "SPOTLESS!"
	caption.TextColor3 = BASIL
	setProgress(1)
	tween(broom, 0.3, { ImageTransparency = 1 })
	sparkleBurst(12)
	shine.Visible = true
	shine.Position = UDim2.fromScale(-0.4, 0.5)
	tween(shine, 0.6, { Position = UDim2.fromScale(1.4, 0.5) }, Enum.EasingStyle.Sine)
	task.delay(0.35, function()
		stamp.Visible = true
		stamp.ImageTransparency = 1
		stamp.Rotation = -30
		stampScale.Scale = 2.4
		tween(stamp, 0.18, { ImageTransparency = 0, Rotation = -10 })
		tween(stampScale, 0.24, { Scale = 1 }, Enum.EasingStyle.Back)
		task.delay(0.18, function()
			panelScale.Scale = 0.93
			tween(panelScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	end)
	task.delay(1.5, function()
		if session and session.Done then teardown() end
	end)
end

local function open(data)
	teardown()
	session = {
		Token = data.Token,
		X = 0.5, Y = 0.55,
		Travel = 0,
		Dragging = false,
		Done = false,
		Started = false,
		StickX = 0, StickY = 0, KeyX = 0, KeyY = 0,
		LastFx = 0,
	}
	caption.Text = "SWEEP IT UP!"
	caption.TextColor3 = Color3.new(1, 1, 1)
	stamp.Visible = false
	shine.Visible = false
	broom.ImageTransparency = 0
	broom.Position = UDim2.fromScale(0.5, 0.55)
	broom.Rotation = 0
	arrows.ImageTransparency = 0
	puddleScale.Scale = 1
	for i, p in ipairs(puddles) do p.ImageTransparency = i == 1 and 0 or 1 end
	scatterDroplets()

	gui.Enabled = true
	panelScale.Scale = 0.6
	tween(panelScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)

	local function moveBroom(dx, dy)
		if not session or session.Done then return end
		if dx == 0 and dy == 0 then return end
		local nx = math.clamp(session.X + dx, 0.1, 0.9)
		local ny = math.clamp(session.Y + dy, 0.2, 0.92)
		local moved = math.sqrt((nx - session.X) ^ 2 + (ny - session.Y) ^ 2)
		session.X, session.Y = nx, ny
		broom.Position = UDim2.fromScale(nx, ny)
		if dx ~= 0 then
			broom.Rotation = broom.Rotation + ((dx > 0 and 20 or -20) - broom.Rotation) * 0.35
		end
		if not session.Started then
			session.Started = true
			tween(arrows, 0.3, { ImageTransparency = 1 }) --// the hint did its job
		end
		--// spray + dust, rate-limited so it reads as strokes, not noise
		local now = os.clock()
		if moved > 0.004 and now - session.LastFx > 0.09 then
			session.LastFx = now
			local dir = dx >= 0 and 1 or -1
			dustPuff(Vector2.new(nx, ny), dir)
			if math.random() < 0.6 then flickDrop(Vector2.new(nx, ny), dir) end
		end
		session.Travel += moved
		if session.Travel >= SWEEP.StrokeTravelFraction then
			session.Travel = 0
			sweepRemote:FireServer("Stroke", session.Token)
		end
	end

	local lastX, lastY = nil, nil
	table.insert(conns, floor.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			session.Dragging = true
			lastX, lastY = input.Position.X, input.Position.Y
		end
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			if session then session.Dragging = false end
			lastX, lastY = nil, nil
		end
	end))
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not session or session.Done or not session.Dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		local size = floor.AbsoluteSize
		if size.X <= 0 then return end
		local x, y = input.Position.X, input.Position.Y
		if lastX then
			moveBroom((x - lastX) / size.X, (y - lastY) / size.Y)
		end
		lastX, lastY = x, y
	end))

	ContextActionService:BindAction("SpillFloorStick", function(_, state, input)
		if session then
			local live = state == Enum.UserInputState.Change or state == Enum.UserInputState.Begin
			session.StickX = live and input.Position.X or 0
			session.StickY = live and -input.Position.Y or 0
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Thumbstick1)
	ContextActionService:BindAction("SpillFloorKeys", function(_, state, input)
		if session then
			local down = state == Enum.UserInputState.Begin
			local k = input.KeyCode
			if k == Enum.KeyCode.Left then session.KeyX = down and -1 or (session.KeyX < 0 and 0 or session.KeyX)
			elseif k == Enum.KeyCode.Right then session.KeyX = down and 1 or (session.KeyX > 0 and 0 or session.KeyX)
			elseif k == Enum.KeyCode.Up then session.KeyY = down and -1 or (session.KeyY < 0 and 0 or session.KeyY)
			elseif k == Enum.KeyCode.Down then session.KeyY = down and 1 or (session.KeyY > 0 and 0 or session.KeyY)
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Down)

	local clock = 0
	table.insert(conns, RunService.RenderStepped:Connect(function(dt)
		if not session then return end
		clock += dt
		if not session.Done then
			local ax = math.abs(session.StickX) > 0.2 and session.StickX or session.KeyX
			local ay = math.abs(session.StickY) > 0.2 and session.StickY or session.KeyY
			if ax ~= 0 or ay ~= 0 then
				moveBroom(ax * dt * 1.6, ay * dt * 1.6)
			end
			--// the broom eases back upright when you stop
			if not session.Dragging and ax == 0 then
				broom.Rotation *= math.max(0, 1 - dt * 6)
			end
		end
		--// idle life: the drag hint swings, the sign wobbles, the puddle glints
		if not session.Started then
			arrows.Position = UDim2.fromScale(0.5 + math.sin(clock * 4) * 0.05, 0.86)
			arrowScale.Scale = 1 + math.sin(clock * 8) * 0.05
		end
		sign.Rotation = math.sin(clock * 1.7) * 4
	end))
end

sweepRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "Open" and type(a) == "table" then
		open(a)
	elseif action == "Progress" then
		if not session or session.Token ~= a or session.Done then return end
		setProgress(math.clamp(tonumber(b) or 0, 0, 1))
		caption.TextColor3 = Color3.new(1, 1, 1)
	elseif action == "Close" then
		if not session or session.Token ~= a then return end
		if b then finish() else teardown() end
	end
end)

player.CharacterAdded:Connect(function()
	if session then teardown() end
end)
