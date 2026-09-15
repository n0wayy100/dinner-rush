--[[
	Dinner Rush - CookTimingClient
	StarterPlayer.StarterPlayerScripts.Client.CookTimingClient  (LocalScript)

	The cooking timing bar (gated difficulties only - EASY never sees it).
	A horizontal bar: red ends, yellow shoulders, and a GREEN zone that
	lands somewhere new every swing. An arrow ping-pongs across; STOP it
	with a tap/click anywhere on the panel or with Space/gamepad A.

	  green (swing 1)      PERFECT!
	  yellow then green    GOOD!
	  yellow then yellow   OK...
	  red                  MISS! - swing again

	Render/report only: the server dealt the green's position, keeps its
	own arrow clock, and overrules any claim outside tolerance. The dish
	keeps aging on the stove while this panel is up - dawdle and it burns.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local timingRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CookTimingRemote")

local TIMING = Config.CookTiming

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)

local ACTION = "DinnerRushCookStop"

local ZONE_LABEL = {
	green = { Text = "PERFECT!", Color = BASIL },
	yellow = { Text = "OK...", Color = MUSTARD },
	red = { Text = "MISS!", Color = TOMATO },
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Panel (built once)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "CookTiming_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.Parent = playerGui

--// Full-screen tap catcher: anywhere is the STOP button (phone-first)
local catcher = Instance.new("TextButton")
catcher.Name = "TapCatcher"
catcher.Size = UDim2.fromScale(1, 1)
catcher.BackgroundTransparency = 1
catcher.Text = ""
catcher.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.68) --// low centre: the stove stays visible
panel.Size = UDim2.fromScale(0.44, 0.16)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 3
panelStroke.Color = CHOC
panelStroke.Parent = panel

--// The zone bar
local bar = Instance.new("Frame")
bar.Name = "Bar"
bar.AnchorPoint = Vector2.new(0.5, 0.5)
bar.Position = UDim2.fromScale(0.5, 0.56)
bar.Size = UDim2.fromScale(0.92, 0.42)
bar.BackgroundColor3 = TOMATO --// red is the default; zones paint over it
bar.ClipsDescendants = true
bar.Parent = panel

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 8)
barCorner.Parent = bar

local barStroke = Instance.new("UIStroke")
barStroke.Thickness = 2
barStroke.Color = CHOC
barStroke.Parent = bar

local function makeZone(name, color)
	local zone = Instance.new("Frame")
	zone.Name = name
	zone.AnchorPoint = Vector2.new(0.5, 0)
	zone.Size = UDim2.fromScale(0, 1)
	zone.BackgroundColor3 = color
	zone.BorderSizePixel = 0
	zone.Parent = bar
	return zone
end

local yellowZone = makeZone("Yellow", MUSTARD) --// one band; green sits on top
local greenZone = makeZone("Green", BASIL)

--// The arrow: a chunky chocolate needle
local arrow = Instance.new("Frame")
arrow.Name = "Arrow"
arrow.AnchorPoint = Vector2.new(0.5, 0.5)
arrow.Position = UDim2.fromScale(0, 0.5)
arrow.Size = UDim2.new(0, 5, 1.35, 0)
arrow.BackgroundColor3 = CHOC
arrow.BorderSizePixel = 0
arrow.ZIndex = 5
arrow.Parent = bar

local arrowStroke = Instance.new("UIStroke")
arrowStroke.Thickness = 1.5
arrowStroke.Color = CREAM
arrowStroke.Parent = arrow

--// Result / stage text above the bar
local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 0)
caption.Position = UDim2.fromScale(0.5, 0.05)
caption.Size = UDim2.fromScale(0.9, 0.28)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.FredokaOne
caption.TextScaled = true
caption.TextColor3 = CHOC
caption.TextStrokeColor3 = CREAM
caption.TextStrokeTransparency = 0.5
caption.Text = ""
caption.Parent = panel

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local current = nil --// { Token, StationPosition }
local sweepStart = 0
local sweepSeconds = 1 --// dealt by the server, fresh every swing
local sweeping = false
local stopped = false --// pressed, waiting on the server's verdict
local walkWatcher = nil
local animWatcher = nil

local function arrowAt(elapsed)
	elapsed = math.max(elapsed, 0)
	local phase = (elapsed % (sweepSeconds * 2)) / sweepSeconds
	if phase <= 1 then
		return phase
	end
	return 2 - phase
end

local function paintZones(greenCenter)
	greenZone.Position = UDim2.fromScale(greenCenter, 0)
	greenZone.Size = UDim2.fromScale(TIMING.GreenWidth, 1)
	yellowZone.Position = UDim2.fromScale(greenCenter, 0)
	yellowZone.Size = UDim2.fromScale(TIMING.GreenWidth + TIMING.YellowWidth * 2, 1)
end

local function startSweep(stage, greenCenter, speed)
	sweepSeconds = speed or 1
	paintZones(greenCenter)
	caption.Text = stage == 2 and "Save it! One more..." or "Stop it on the GREEN!"
	caption.TextColor3 = CHOC
	sweepStart = os.clock()
	sweeping = true
	stopped = false
end

local function close(tellServer)
	if walkWatcher then
		walkWatcher:Disconnect()
		walkWatcher = nil
	end
	if animWatcher then
		animWatcher:Disconnect()
		animWatcher = nil
	end
	ContextActionService:UnbindAction(ACTION)
	if tellServer and current then
		timingRemote:FireServer("Abandon", current.Token)
	end
	current = nil
	sweeping = false
	gui.Enabled = false
end

----------------------------------------------------------------
-- Stopping the arrow
----------------------------------------------------------------
local function stopArrow()
	if not current or not sweeping or stopped then return end
	stopped = true
	sweeping = false
	--// Freeze the needle where WE see it and claim that position; the
	--// server honours it within tolerance of its own clock
	local position = arrowAt(os.clock() - sweepStart)
	arrow.Position = UDim2.fromScale(position, 0.5)
	timingRemote:FireServer("Stop", current.Token, position)
end

catcher.Activated:Connect(stopArrow)

local function onAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		stopArrow()
	end
	return Enum.ContextActionResult.Sink
end

----------------------------------------------------------------
-- Server traffic
----------------------------------------------------------------
timingRemote.OnClientEvent:Connect(function(action, a, b, c, d)
	if action == "Open" and type(a) == "table" then
		current = {
			Token = a.Token,
			StationPosition = a.StationPosition,
		}
		gui.Enabled = true
		startSweep(a.Stage or 1, a.GreenCenter or 0.5, a.SweepSeconds)

		--// Space / gamepad A also stop it
		ContextActionService:BindAction(ACTION, onAction, false,
			Enum.KeyCode.Space, Enum.KeyCode.ButtonA)

		--// The arrow animation
		if animWatcher then animWatcher:Disconnect() end
		animWatcher = RunService.RenderStepped:Connect(function()
			if sweeping then
				arrow.Position = UDim2.fromScale(arrowAt(os.clock() - sweepStart), 0.5)
			end
		end)

		--// Wandering from the stove closes the panel and frees the pan
		if walkWatcher then walkWatcher:Disconnect() end
		walkWatcher = RunService.Heartbeat:Connect(function()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and current
				and (root.Position - current.StationPosition).Magnitude > TIMING.WalkAwayStuds then
				close(true)
			end
		end)

	elseif action == "Result" then
		--// a = token, b = zone, c = final quality (nil = more swings coming)
		if not current or current.Token ~= a then return end
		local look = ZONE_LABEL[b]
		if look then
			caption.Text = c and (c == "Good" and "GOOD!" or look.Text) or look.Text
			caption.TextColor3 = look.Color
		end

	elseif action == "Sweep" then
		--// a = token, b = stage, c = fresh green centre, d = fresh pace
		if not current or current.Token ~= a then return end
		task.delay(TIMING.ResultFlashSeconds, function()
			if current and current.Token == a then
				startSweep(b, c, d)
			end
		end)

	elseif action == "Close" then
		if current and current.Token == a then
			--// Let a final verdict linger for a beat before vanishing
			local token = a
			task.delay(TIMING.ResultFlashSeconds, function()
				if current and current.Token == token then
					close(false)
				end
			end)
		end
	end
end)

--// Death mid-flip drops the panel; the server timeout frees the pan
player.CharacterAdded:Connect(function()
	if current then
		close(true)
	end
end)
