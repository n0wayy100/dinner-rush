--[[
	Dinner Rush - PlungeClient
	StarterPlayer.StarterPlayerScripts.Client.PlungeClient  (LocalScript)

	The plunge tapping bar (ON for every difficulty since the Sep 2026
	un-freeze). SPAM TAP - left-click on desktop, tap on
	touch, A on gamepad - to fill the bar. It leaks while you rest, so
	keep the rhythm up until it's full.

	Render/report only: the server counts its own taps (rate-capped),
	re-checks the plunger and proximity on every one, and decides when
	the bar is truly full. This panel just bounces and looks desperate.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local plungeRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PlungeRemote")

local PLUNGE = Config.PlungeTap

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)

local ACTION = "DinnerRushPlungeTap"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Panel (built once)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "PlungeTap_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.Parent = playerGui

--// Full-screen tap catcher: anywhere is the plunger (phone-first)
local catcher = Instance.new("TextButton")
catcher.Name = "TapCatcher"
catcher.Size = UDim2.fromScale(1, 1)
catcher.BackgroundTransparency = 1
catcher.Text = ""
catcher.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.68) --// low centre: the toilet stays visible
panel.Size = UDim2.fromScale(0.38, 0.15)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 3
panelStroke.Color = CHOC
panelStroke.Parent = panel

local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 0)
caption.Position = UDim2.fromScale(0.5, 0.07)
caption.Size = UDim2.fromScale(0.9, 0.3)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.FredokaOne
caption.TextScaled = true
caption.TextColor3 = CHOC
caption.TextStrokeColor3 = CREAM
caption.TextStrokeTransparency = 0.5
caption.Text = "TAP! TAP! TAP!"
caption.Parent = panel

--// The fill bar
local barBack = Instance.new("Frame")
barBack.Name = "BarBack"
barBack.AnchorPoint = Vector2.new(0.5, 0.5)
barBack.Position = UDim2.fromScale(0.5, 0.62)
barBack.Size = UDim2.fromScale(0.88, 0.34)
barBack.BackgroundColor3 = Color3.fromRGB(235, 220, 200)
barBack.ClipsDescendants = true
barBack.Parent = panel

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 8)
barCorner.Parent = barBack

local barStroke = Instance.new("UIStroke")
barStroke.Thickness = 2
barStroke.Color = CHOC
barStroke.Parent = barBack

local fillBar = Instance.new("Frame")
fillBar.Name = "Fill"
fillBar.Size = UDim2.fromScale(0, 1)
fillBar.BackgroundColor3 = MUSTARD
fillBar.BorderSizePixel = 0
fillBar.Parent = barBack

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 8)
fillCorner.Parent = fillBar

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local current = nil --// { Token, FillPerTap, ToiletPosition }
local knownFill = 0 --// last authoritative-ish fill value
local knownAt = 0 --// when we learned it (decay predicts from here)
local finished = false --// success flash in progress; ignore input
local walkWatcher = nil
local renderWatcher = nil

--// What the bar shows right now: last known fill, leaking ever since
local function predictedFill()
	return math.clamp(knownFill - PLUNGE.DecayPerSecond * (os.clock() - knownAt), 0, 1)
end

local function close(tellServer)
	if walkWatcher then
		walkWatcher:Disconnect()
		walkWatcher = nil
	end
	if renderWatcher then
		renderWatcher:Disconnect()
		renderWatcher = nil
	end
	ContextActionService:UnbindAction(ACTION)
	if tellServer and current then
		plungeRemote:FireServer("Abandon", current.Token)
	end
	current = nil
	finished = false
	gui.Enabled = false
end

----------------------------------------------------------------
-- Tapping
----------------------------------------------------------------
local pulseTween = nil

local function tap()
	if not current or finished then return end

	--// Optimistic bump so the bar answers the finger instantly; the
	--// server's Progress overwrites with the true (rate-capped) value
	knownFill = math.clamp(predictedFill() + current.FillPerTap, 0, 1)
	knownAt = os.clock()
	plungeRemote:FireServer("Tap", current.Token)

	--// A little jolt per tap - the panel is being plunged too
	panelScale.Scale = 1.06
	if pulseTween then pulseTween:Cancel() end
	pulseTween = TweenService:Create(panelScale,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = 1 })
	pulseTween:Play()
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
		caption.Text = "TAP! TAP! TAP!"
		caption.TextColor3 = CHOC
		fillBar.Size = UDim2.fromScale(0, 1)
		gui.Enabled = true

		--// Gamepad A taps too (tap/click come through the catcher)
		ContextActionService:BindAction(ACTION, onAction, false, Enum.KeyCode.ButtonA)

		--// The bar leaks on screen exactly as it leaks on the server
		if renderWatcher then renderWatcher:Disconnect() end
		renderWatcher = RunService.RenderStepped:Connect(function()
			local fill = finished and 1 or predictedFill()
			fillBar.Size = UDim2.fromScale(fill, 1)
			fillBar.BackgroundColor3 = MUSTARD:Lerp(BASIL, fill)
			if not finished then
				caption.TextColor3 = fill > 0 and CHOC or TOMATO --// drained empty: nudge
			end
		end)

		--// Wandering from the bowl closes the panel and frees the toilet
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
		--// a = token, b = the server's true fill
		if not current or current.Token ~= a or finished then return end
		knownFill = math.clamp(tonumber(b) or 0, 0, 1)
		knownAt = os.clock()

	elseif action == "Close" then
		--// a = token, b = true when the bar was filled (success)
		if not current or current.Token ~= a then return end
		if b then
			finished = true
			caption.Text = "FIXED!"
			caption.TextColor3 = BASIL
			local token = a
			task.delay(0.7, function()
				if current and current.Token == token then
					close(false)
				end
			end)
		else
			close(false)
		end
	end
end)

--// Death mid-plunge drops the panel; the server frees the toilet
player.CharacterAdded:Connect(function()
	if current then
		close(true)
	end
end)
