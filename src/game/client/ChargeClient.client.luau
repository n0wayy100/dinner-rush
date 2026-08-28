--[[
	Dinner Rush - ChargeClient
	StarterPlayer.StarterPlayerScripts.Client.ChargeClient  (LocalScript)

	The ultimate charge bar + the activation input. Render/intent only:
	the SERVER owns the charge (UltimateCharge attribute on the Player),
	decides every activation, and this script draws the number and sends
	the button press.

	  bar      gold, sits just above the stamina bar (bottom-left); only
	           visible while a class is equipped
	  ready    bar pulses + the ultimate's name appears over it
	  input    Q on keyboard · touch button (near sprint's) · gamepad Y -
	           one ContextActionService action, bound only while classed

	Denials come back with a reason ("Not charged yet!", "Hold a raw
	ingredient first!") and flash in tomato over the bar.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ultimateRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UltimateRemote")

local ULT = Config.Ultimates

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local GOLD = Color3.fromRGB(255, 200, 60)

local ACTION = "DinnerRushUltimate"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- The bar (just above the stamina bar; same pill language)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Ultimate_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 15
gui.Parent = playerGui

local bar = Instance.new("CanvasGroup")
bar.Name = "ChargeBar"
bar.AnchorPoint = Vector2.new(0, 1)
bar.Position = UDim2.fromScale(0.03, 0.925) --// stamina sits at 0.95
bar.Size = UDim2.fromScale(0.16, 0.014)
bar.BackgroundColor3 = CREAM
bar.GroupTransparency = 1
bar.Parent = gui

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = bar

local barStroke = Instance.new("UIStroke")
barStroke.Thickness = 2
barStroke.Color = CHOC
barStroke.Parent = bar

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 2)
pad.PaddingBottom = UDim.new(0, 2)
pad.PaddingLeft = UDim.new(0, 2)
pad.PaddingRight = UDim.new(0, 2)
pad.Parent = bar

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = GOLD
fill.BorderSizePixel = 0
fill.Parent = bar

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

--// Floats over the bar: the ultimate's name when ready, denials in tomato
local hint = Instance.new("TextLabel")
hint.AnchorPoint = Vector2.new(0, 1)
hint.Position = UDim2.fromScale(0.03, 0.906)
hint.Size = UDim2.fromScale(0.16, 0.024)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.FredokaOne
hint.TextScaled = true
hint.TextColor3 = GOLD
hint.TextStrokeColor3 = CHOC
hint.TextStrokeTransparency = 0
hint.Text = ""
hint.Parent = gui

----------------------------------------------------------------
-- State + rendering
----------------------------------------------------------------
local tweenInfo = TweenInfo.new(ULT.BarTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local pulseTween = nil
local hintSerial = 0

local function ultimateName()
	local classKey = player:GetAttribute("ClassKey")
	local class = classKey and classKey ~= "" and Config.Classes[classKey]
	return (class and class.UltimateName ~= "" and class.UltimateName) or "ULT!"
end

local function setPulsing(on)
	if on and not pulseTween then
		pulseTween = TweenService:Create(barStroke,
			TweenInfo.new(ULT.ReadyPulseSeconds, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut, -1, true),
			{ Color = GOLD })
		pulseTween:Play()
	elseif not on and pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
		barStroke.Color = CHOC
	end
end

local function showDenial(reason)
	hintSerial += 1
	local mySerial = hintSerial
	hint.TextColor3 = TOMATO
	hint.Text = reason
	task.delay(2, function()
		if hintSerial == mySerial then
			hint.Text = ""
		end
	end)
end

local function render()
	local classKey = player:GetAttribute("ClassKey")
	local classed = classKey ~= nil and classKey ~= ""
	local charge = player:GetAttribute("UltimateCharge") or 0
	local fraction = math.clamp(charge / ULT.MaxCharge, 0, 1)

	bar.GroupTransparency = classed and 0 or 1
	TweenService:Create(fill, tweenInfo, { Size = UDim2.fromScale(fraction, 1) }):Play()

	local ready = classed and fraction >= 1
	setPulsing(ready)
	if ready then
		hintSerial += 1 --// a ready banner outranks a stale denial
		hint.TextColor3 = GOLD
		hint.Text = ultimateName() .. " ready!"
	elseif hint.TextColor3 == GOLD then
		hint.Text = ""
	end
end

----------------------------------------------------------------
-- Input: bound only while a class is equipped
----------------------------------------------------------------
local bound = false

local function onActivate(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		ultimateRemote:FireServer("Activate")
	end
	return Enum.ContextActionResult.Pass
end

local function refreshBinding()
	local classed = (player:GetAttribute("ClassKey") or "") ~= ""
	if classed and not bound then
		bound = true
		ContextActionService:BindAction(ACTION, onActivate, true,
			Enum.KeyCode.Q, Enum.KeyCode.ButtonY)
		ContextActionService:SetTitle(ACTION, "ULT!")
		--// Touch: left of the sprint button, clear of jump
		ContextActionService:SetPosition(ACTION, UDim2.new(0.45, 0, 0.05, 0))
	elseif not classed and bound then
		bound = false
		ContextActionService:UnbindAction(ACTION)
	end
end

player:GetAttributeChangedSignal("UltimateCharge"):Connect(render)
player:GetAttributeChangedSignal("ClassKey"):Connect(function()
	refreshBinding()
	render()
end)

ultimateRemote.OnClientEvent:Connect(function(action, ok, reason)
	if action ~= "Result" then return end
	if not ok and reason then
		showDenial(reason)
	end
end)

refreshBinding()
render()
