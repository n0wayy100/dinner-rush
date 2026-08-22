--[[
	Dinner Rush - EventClient
	StarterPlayer.StarterPlayerScripts.Client.EventClient  (LocalScript)

	Renders whatever EventSystem publishes to ReplicatedStorage.EventState.
	Same split as the HUD: the server owns the numbers, this only draws them.

	A banner across the top of the screen, below the shift HUD, showing the
	alert text and a fuse bar while one is counting down. Nothing here decides
	anything - clearing the banner happens because the server said so.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local REFRESH_INTERVAL = 0.1

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local WATER = Color3.fromRGB(120, 170, 200)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local EventState = ReplicatedStorage:WaitForChild("EventState", 30)
if not EventState then
	warn("[EventClient] ReplicatedStorage.EventState never appeared - is EventSystem running?")
	return
end

----------------------------------------------------------------
-- Built once, hidden
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "EventAlert_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 30 --// above the HUD, below the shift intro
gui.Enabled = false
gui.Parent = playerGui

local banner = Instance.new("Frame")
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.fromScale(0.5, 0.14)
banner.Size = UDim2.fromScale(0.42, 0.085)
banner.BackgroundColor3 = CREAM
banner.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = banner

local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = CHOC
stroke.Parent = banner

local text = Instance.new("TextLabel")
text.AnchorPoint = Vector2.new(0.5, 0)
text.Position = UDim2.fromScale(0.5, 0.08)
text.Size = UDim2.fromScale(0.92, 0.5)
text.BackgroundTransparency = 1
text.Font = Enum.Font.FredokaOne
text.TextScaled = true
text.TextColor3 = CHOC
text.Text = ""
text.Parent = banner

local barBack = Instance.new("Frame")
barBack.AnchorPoint = Vector2.new(0.5, 1)
barBack.Position = UDim2.fromScale(0.5, 0.88)
barBack.Size = UDim2.fromScale(0.92, 0.22)
barBack.BackgroundColor3 = Color3.fromRGB(216, 205, 192)
barBack.BorderSizePixel = 0
barBack.Parent = banner

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 6)
barCorner.Parent = barBack

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(1, 1)
barFill.BackgroundColor3 = TOMATO
barFill.BorderSizePixel = 0
barFill.Parent = barBack

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 6)
fillCorner.Parent = barFill

----------------------------------------------------------------
-- Centre-screen toast: the water-trap lesson ("NEVER put water on a
-- grease fire!"). Driven by EventState.Toast; big, tomato, unmissable.
----------------------------------------------------------------
local toastGui = Instance.new("ScreenGui")
toastGui.Name = "EventToast_UI"
toastGui.ResetOnSpawn = false
toastGui.IgnoreGuiInset = true
toastGui.DisplayOrder = 40 --// above the banner - the lesson interrupts
toastGui.Enabled = false
toastGui.Parent = playerGui

local toastFrame = Instance.new("Frame")
toastFrame.AnchorPoint = Vector2.new(0.5, 0.5)
toastFrame.Position = UDim2.fromScale(0.5, 0.35)
toastFrame.Size = UDim2.fromScale(0.52, 0.12)
toastFrame.BackgroundColor3 = TOMATO
toastFrame.Parent = toastGui

local toastCorner = Instance.new("UICorner")
toastCorner.CornerRadius = UDim.new(0, 14)
toastCorner.Parent = toastFrame

local toastStroke = Instance.new("UIStroke")
toastStroke.Thickness = 3
toastStroke.Color = CHOC
toastStroke.Parent = toastFrame

local toastLabel = Instance.new("TextLabel")
toastLabel.AnchorPoint = Vector2.new(0.5, 0.5)
toastLabel.Position = UDim2.fromScale(0.5, 0.5)
toastLabel.Size = UDim2.fromScale(0.92, 0.7)
toastLabel.BackgroundTransparency = 1
toastLabel.Font = Enum.Font.FredokaOne
toastLabel.TextScaled = true
toastLabel.TextWrapped = true
toastLabel.TextColor3 = Color3.new(1, 1, 1)
toastLabel.TextStrokeColor3 = CHOC
toastLabel.TextStrokeTransparency = 0
toastLabel.Text = ""
toastLabel.Parent = toastFrame

----------------------------------------------------------------
-- A gentle pulse while something is wrong, so it reads as urgent
-- without a flashing screen
----------------------------------------------------------------
local pulse = TweenService:Create(
	stroke,
	TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Color = TOMATO }
)
local pulsing = false

local function setPulsing(on)
	if on == pulsing then return end
	pulsing = on
	if on then
		pulse:Play()
	else
		pulse:Cancel()
		stroke.Color = CHOC
	end
end

----------------------------------------------------------------
-- Render
----------------------------------------------------------------
local function refresh()
	local active = EventState:GetAttribute("ActiveEvent") or ""
	local alert = EventState:GetAttribute("AlertText") or ""
	local phase = EventState:GetAttribute("Phase") or ""

	--// Toast is independent of the banner: it may outlive the event
	local toast = EventState:GetAttribute("Toast") or ""
	toastGui.Enabled = toast ~= ""
	toastLabel.Text = toast

	if alert == "" then
		gui.Enabled = false
		setPulsing(false)
		return
	end

	gui.Enabled = true
	text.Text = alert

	local total = EventState:GetAttribute("FuseTotal") or 0
	local remaining = EventState:GetAttribute("FuseRemaining") or 0

	if phase == "ERUPTING" and total > 0 then
		barBack.Visible = true
		barFill.Size = UDim2.fromScale(math.clamp(remaining / total, 0, 1), 1)
		barFill.BackgroundColor3 = (remaining / total) <= 0.5 and TOMATO or MUSTARD
		setPulsing(true)
	elseif phase == "FLOODED" then
		barBack.Visible = true
		barFill.Size = UDim2.fromScale(1, 1)
		barFill.BackgroundColor3 = WATER
		setPulsing(true)
	else
		--// A closing message like "X fixed the toilet!" - no bar, no alarm
		barBack.Visible = false
		setPulsing(false)
	end
end

refresh()

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < REFRESH_INTERVAL then return end
	since = 0
	refresh()
end)
