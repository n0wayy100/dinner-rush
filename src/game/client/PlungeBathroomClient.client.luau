--[[
	Dinner Rush - PlungeBathroomClient
	StarterPlayer.StarterPlayerScripts.Client.PlungeBathroomClient  (LocalScript)

	THE BATHROOM SCENE version of the toilet spam-tap panel (Oct 2026,
	Claude Design Prompt B). Runs ONLY when Config.PlungeTap.Style is
	"Bathroom" - "Classic" runs PlungeClient instead, so the owner can
	compare the two. Same server, same protocol, same rules:

	  server -> client  "Open" {Token, FillPerTap, ToiletPosition}
	                    "Progress" token, fill
	                    "Close" token, success
	  client -> server  "Tap" token / "Abandon" token

	The picture: a tiled bathroom panel, the toilet with its water stacked
	on top, a plunger that PUMPS into the bowl on every tap (squash and
	stretch), splash droplets and popping bubbles, a water gauge on the
	right that fills while the bowl's water sinks. A flooded toilet raises
	the flood water up the bottom of the screen. Success drains the bowl,
	bursts bubbles and slams the ALL CLEAR stamp.

	Render/report only: the server counts its own taps, re-checks the
	plunger and proximity, and decides when the gauge is truly full.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local PLUNGE = Config.PlungeTap
if (PLUNGE.Style or "Classic") ~= "Bathroom" then return end

local ART = PLUNGE.BathroomArt or {}
local plungeRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PlungeRemote")
local EventState = ReplicatedStorage:WaitForChild("EventState", 30)

local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local BASIL = Color3.fromRGB(76, 175, 109)

local ACTION = "DinnerRushPlungeBathroom"
local BOWL_Y = PLUNGE.BowlY or 0.67

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function image(parent, key, name)
	local img = Instance.new("ImageLabel")
	img.Name = name or key
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

--// a 4-column flipbook of 256px cells, removed when it ends
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
gui.Name = "PlungeBathroom_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

--// the flood water creeping up the screen (flooded toilets only)
local flood = image(gui, "Flood_Overlay")
flood.ScaleType = Enum.ScaleType.Stretch
flood.AnchorPoint = Vector2.new(0.5, 1)
flood.Size = UDim2.fromScale(1.1, 0.45)
flood.Position = UDim2.fromScale(0.5, 1.5)
flood.ZIndex = 1

--// full-screen tap catcher: anywhere is the plunger (phone-first)
local catcher = Instance.new("TextButton")
catcher.Name = "TapCatcher"
catcher.Size = UDim2.fromScale(1, 1)
catcher.BackgroundTransparency = 1
catcher.Text = ""
catcher.ZIndex = 2
catcher.Parent = gui

--// the square panel, sized from the screen (PC and phone)
local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.6)
panel.BackgroundTransparency = 1
panel.ZIndex = 3
panel.Parent = gui
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

local function layout()
	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(1366, 768)
	local side = math.clamp(math.min(view.X * 0.34, view.Y * 0.56), 240, 430)
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

local back = image(panel, "Bathroom_Panel")
back.ScaleType = Enum.ScaleType.Stretch
back.Position = UDim2.fromScale(0.5, 0.5)
back.Size = UDim2.fromScale(1, 1)
back.ZIndex = 3

local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.BackgroundTransparency = 1
caption.AnchorPoint = Vector2.new(0.5, 0)
caption.Position = UDim2.fromScale(0.42, 0.07)
caption.Size = UDim2.fromScale(0.66, 0.12)
caption.Font = Enum.Font.FredokaOne
caption.TextScaled = true
caption.Text = "TAP! TAP! TAP!"
caption.TextColor3 = Color3.new(1, 1, 1)
caption.TextStrokeColor3 = CHOC
caption.TextStrokeTransparency = 0
caption.ZIndex = 9
caption.Parent = panel
local captionScale = Instance.new("UIScale")
captionScale.Parent = caption

--// the toilet stage (a square the toilet, water, plunger and splashes share)
local stage = Instance.new("Frame")
stage.Name = "Stage"
stage.BackgroundTransparency = 1
stage.AnchorPoint = Vector2.new(0.5, 0.5)
stage.Position = UDim2.fromScale(0.41, 0.5)
stage.Size = UDim2.fromScale(0.86, 0.86)
stage.ZIndex = 4
stage.Parent = panel

local body = image(stage, "Toilet_Body")
body.Position = UDim2.fromScale(0.5, 0.5)
body.Size = UDim2.fromScale(1, 1)
body.ZIndex = 4
local water = image(stage, "Toilet_Water")
water.Position = UDim2.fromScale(0.5, 0.5)
water.Size = UDim2.fromScale(1, 1)
water.ZIndex = 5

local PLUNGER_REST = UDim2.fromScale(0.5, BOWL_Y + 0.06)
local PLUNGER_SIZE = UDim2.fromScale(0.24, 0.48)
local plunger = image(stage, "Plunger")
plunger.AnchorPoint = Vector2.new(0.5, 1) --// pivot at the cup
plunger.Position = PLUNGER_REST
plunger.Size = PLUNGER_SIZE
plunger.ZIndex = 6

--// the water gauge on the right
local gauge = image(panel, "Plunge_BarFrame")
gauge.ScaleType = Enum.ScaleType.Stretch
gauge.Position = UDim2.fromScale(0.86, 0.53)
gauge.Size = UDim2.fromScale(0.13, 0.72)
gauge.ZIndex = 6
local glass = Instance.new("Frame") --// the glass interior the fill rises in
glass.BackgroundTransparency = 1
glass.AnchorPoint = Vector2.new(0.5, 1)
glass.Position = UDim2.fromScale(0.5, 0.9)
glass.Size = UDim2.fromScale(0.58, 0.8)
glass.ZIndex = 7
glass.Parent = gauge
local gaugeFill = image(glass, "Plunge_BarFill")
gaugeFill.ScaleType = Enum.ScaleType.Stretch
gaugeFill.AnchorPoint = Vector2.new(0.5, 1)
gaugeFill.Position = UDim2.fromScale(0.5, 1)
gaugeFill.Size = UDim2.fromScale(1, 0)
gaugeFill.ZIndex = 7

--// the TAP hint, bottom left, pulsing
local tapIcon = image(panel, "Tap_Icon")
tapIcon.Position = UDim2.fromScale(0.14, 0.84)
tapIcon.Size = UDim2.fromScale(0.19, 0.19)
tapIcon.ZIndex = 9
aspect(tapIcon, 1)
local tapScale = Instance.new("UIScale")
tapScale.Parent = tapIcon

--// the ALL CLEAR stamp
local stamp = image(panel, "Fixed_Stamp")
stamp.Position = UDim2.fromScale(0.5, 0.48)
stamp.Size = UDim2.fromScale(0.62, 0.62)
stamp.ZIndex = 12
stamp.Visible = false
aspect(stamp, 1)
local stampScale = Instance.new("UIScale")
stampScale.Parent = stamp

----------------------------------------------------------------
-- Little effects
----------------------------------------------------------------
local function bubbles(sizeScale)
	local b = image(stage, "Bubbles_Sheet")
	local size = (0.2 + math.random() * 0.12) * (sizeScale or 1)
	b.Size = UDim2.fromScale(size, size)
	b.Position = UDim2.fromScale(0.42 + math.random() * 0.16, BOWL_Y - 0.06 - math.random() * 0.06)
	b.ZIndex = 7
	b.ImageColor3 = Color3.fromRGB(220, 240, 255)
	playSheet(b, 16, 24)
end

local function splash(count)
	for _ = 1, count do
		local drop = image(stage, "Splash_Drop")
		local size = 0.05 + math.random() * 0.05
		drop.Size = UDim2.fromScale(size, size)
		drop.Position = UDim2.fromScale(0.5 + (math.random() - 0.5) * 0.12, BOWL_Y)
		drop.ZIndex = 8
		local dir = math.random() < 0.5 and -1 or 1
		local peakX = 0.5 + dir * (0.12 + math.random() * 0.18)
		local peakY = BOWL_Y - 0.18 - math.random() * 0.15
		drop.Rotation = dir * math.random(10, 40)
		tween(drop, 0.22, { Position = UDim2.fromScale(peakX, peakY) }, Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out)
		task.delay(0.22, function()
			if not drop.Parent then return end
			tween(drop, 0.3, {
				Position = UDim2.fromScale(peakX + dir * 0.06, BOWL_Y + 0.12),
				ImageTransparency = 1,
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.32, function() drop:Destroy() end)
		end)
	end
end

local function slamStamp()
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
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local current = nil --// { Token, FillPerTap, ToiletPosition }
local knownFill = 0
local knownAt = 0
local finished = false
local walkWatcher = nil
local renderWatcher = nil

--// what the gauge shows: last known fill, leaking ever since
local function predictedFill()
	return math.clamp(knownFill - PLUNGE.DecayPerSecond * (os.clock() - knownAt), 0, 1)
end

local function flooded()
	return EventState ~= nil and EventState:GetAttribute("Phase") == "FLOODED"
end

--// the flood water rises once, THEN bobs (bobbing mid-rise would snap it)
local floodUp = false
local floodToken = 0
local function raiseFlood()
	floodToken += 1
	local mine = floodToken
	floodUp = false
	tween(flood, 0.9, { Position = UDim2.fromScale(0.5, 1.02) }, Enum.EasingStyle.Sine)
	task.delay(0.9, function()
		if floodToken == mine then floodUp = true end
	end)
end
local function lowerFlood(seconds)
	floodToken += 1
	floodUp = false
	tween(flood, seconds or 0.4, { Position = UDim2.fromScale(0.5, 1.5) })
end

local function close(tellServer)
	if walkWatcher then walkWatcher:Disconnect() walkWatcher = nil end
	if renderWatcher then renderWatcher:Disconnect() renderWatcher = nil end
	ContextActionService:UnbindAction(ACTION)
	if tellServer and current then
		plungeRemote:FireServer("Abandon", current.Token)
	end
	current = nil
	finished = false
	lowerFlood(0.4)
	task.delay(0.4, function()
		if not current then gui.Enabled = false end
	end)
end

----------------------------------------------------------------
-- Tapping
----------------------------------------------------------------
local plungeToken = 0
local function tap()
	if not current or finished then return end

	--// optimistic bump so the gauge answers the finger instantly; the
	--// server's Progress overwrites with the true (rate-capped) value
	knownFill = math.clamp(predictedFill() + current.FillPerTap, 0, 1)
	knownAt = os.clock()
	plungeRemote:FireServer("Tap", current.Token)

	--// THE PUMP: the plunger squashes down into the bowl, then springs up
	plungeToken += 1
	local mine = plungeToken
	plunger.Position = UDim2.fromScale(0.5, BOWL_Y + 0.11)
	plunger.Size = UDim2.fromScale(PLUNGER_SIZE.X.Scale * 1.18, PLUNGER_SIZE.Y.Scale * 0.84)
	task.delay(0.05, function()
		if mine ~= plungeToken then return end
		tween(plunger, 0.22, { Position = PLUNGER_REST, Size = PLUNGER_SIZE }, Enum.EasingStyle.Back)
	end)

	--// the toilet jolts, water sloshes, drops fly
	stage.Rotation = math.random(-3, 3)
	tween(stage, 0.18, { Rotation = 0 }, Enum.EasingStyle.Back)
	water.Position = UDim2.fromScale(0.5, 0.5 + 0.015)
	splash(math.random(2, 4))
	if math.random() < 0.5 then bubbles(0.8) end

	--// the TAP icon clicks
	tapScale.Scale = 0.8
	tween(tapScale, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
	captionScale.Scale = 1.08
	tween(captionScale, 0.12, { Scale = 1 })
end

catcher.Activated:Connect(tap)

local function onAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		tap()
	end
	return Enum.ContextActionResult.Sink
end

----------------------------------------------------------------
-- Server traffic
----------------------------------------------------------------
plungeRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "Open" and type(a) == "table" then
		current = {
			Token = a.Token,
			FillPerTap = a.FillPerTap or 0.1,
			ToiletPosition = a.ToiletPosition,
		}
		knownFill = 0
		knownAt = os.clock()
		finished = false
		caption.Text = flooded() and "IT FLOODED! PLUNGE!" or "TAP! TAP! TAP!"
		caption.TextColor3 = Color3.new(1, 1, 1)
		stamp.Visible = false
		water.ImageTransparency = 0
		water.Position = UDim2.fromScale(0.5, 0.5)
		plunger.Position = PLUNGER_REST
		plunger.Size = PLUNGER_SIZE
		gaugeFill.Size = UDim2.fromScale(1, 0)

		gui.Enabled = true
		panelScale.Scale = 0.6
		tween(panelScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		if flooded() then
			flood.Position = UDim2.fromScale(0.5, 1.5)
			raiseFlood()
		end

		ContextActionService:BindAction(ACTION, onAction, false, Enum.KeyCode.ButtonA)

		--// the scene breathes every frame
		local clock, bubbleAt = 0, 0
		if renderWatcher then renderWatcher:Disconnect() end
		renderWatcher = RunService.RenderStepped:Connect(function(dt)
			clock += dt
			local fill = finished and 1 or predictedFill()

			--// the gauge rises; the bowl's water sinks and clears as it does
			gaugeFill.Size = UDim2.fromScale(1, fill)
			gaugeFill.ImageColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(200, 255, 220), fill)
			if not finished then
				local sinkY = 0.5 + fill * 0.03
				water.Position = water.Position:Lerp(UDim2.fromScale(0.5, sinkY), math.min(1, dt * 10))
				water.ImageTransparency = fill * 0.35
				caption.TextColor3 = fill > 0 and Color3.new(1, 1, 1) or TOMATO --// drained: nudge
			end

			--// the toilet keeps burbling - harder when flooded, calmer as it clears
			if not finished and clock >= bubbleAt then
				bubbleAt = clock + (flooded() and 0.35 or 0.6) + fill * 0.5
				bubbles(1 - fill * 0.4)
			end

			--// the TAP hint breathes
			if not finished then
				tapIcon.Rotation = math.sin(clock * 6) * 8
			end

			--// the flood water bobs
			if floodUp then
				flood.Position = UDim2.new(0.5, 0, 1.02, math.sin(clock * 2) * 6)
			end
		end)

		--// wandering from the bowl closes the panel and frees the toilet
		if walkWatcher then walkWatcher:Disconnect() end
		walkWatcher = RunService.Heartbeat:Connect(function()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and current
				and (root.Position - current.ToiletPosition).Magnitude > PLUNGE.WalkAwayStuds then
				close(true)
			end
		end)

	elseif action == "Progress" then
		if not current or current.Token ~= a or finished then return end
		knownFill = math.clamp(tonumber(b) or 0, 0, 1)
		knownAt = os.clock()

	elseif action == "Close" then
		if not current or current.Token ~= a then return end
		if b then
			--// SUCCESS: the bowl drains, bubbles burst, the stamp slams
			finished = true
			caption.Text = "FIXED!"
			caption.TextColor3 = BASIL
			captionScale.Scale = 1.4
			tween(captionScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			tween(water, 0.5, { ImageTransparency = 1, Position = UDim2.fromScale(0.5, 0.56) })
			lowerFlood(0.6)
			for i = 1, 4 do
				task.delay(i * 0.06, function() bubbles(1.2) end)
			end
			splash(6)
			task.delay(0.25, slamStamp)
			local token = a
			task.delay(1.3, function()
				if current and current.Token == token then
					close(false)
				end
			end)
		else
			close(false)
		end
	end
end)

--// death mid-plunge drops the panel; the server frees the toilet
player.CharacterAdded:Connect(function()
	if current then
		close(true)
	end
end)

--// a flood that starts while the panel is up raises the water then
if EventState then
	EventState:GetAttributeChangedSignal("Phase"):Connect(function()
		if current and flooded() then
			caption.Text = "IT FLOODED! PLUNGE!"
			if not floodUp then raiseFlood() end
		end
	end)
end
