--[[
	Dinner Rush - ChargeClient
	StarterPlayer.StarterPlayerScripts.Client.ChargeClient  (LocalScript)

	The ultimate as a CIRCULAR ABILITY BUTTON (owner call - the thin bar
	read as a second stamina line). The circle shows the class's sticker
	icon (Config.Classes[*].IconId - the same art as the shop cards), a
	gold fill rising inside it as charge builds, and a 0-100% counter.
	Tapping/clicking the circle activates; Q and gamepad Y still work.

	PLACEMENT: desktop sits right on top of the stamina bar (bottom-left);
	touch devices move it to the RIGHT side, above the jump/sprint cluster,
	so it can never sit on the joystick (which owns the bottom-left).
	The circle IS the mobile button - no separate CAS touch chip.

	Render/intent only: the SERVER owns the charge (UltimateCharge
	attribute) and every activation decision. Denials come back with a
	reason and flash over the button in tomato.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ultimateRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UltimateRemote")

local ULT = Config.Ultimates

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local GOLD = Color3.fromRGB(255, 200, 60)

--// The circle charges WHITE -> BLUE (owner call); the icon charges from
--// black silhouette to its true sticker colours
local CHARGE_EMPTY = Color3.new(1, 1, 1)
local CHARGE_FULL = Color3.fromRGB(80, 150, 255)
local ICON_DARK = Color3.fromRGB(35, 32, 30)

local ACTION = "DinnerRushUltimate"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- The circle
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Ultimate_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 15
gui.Parent = playerGui

local button = Instance.new("ImageButton")
button.Name = "ChargeButton"
button.BackgroundTransparency = 1
button.Size = UDim2.fromScale(0.2, 0.115)
button.Visible = false
button.Parent = gui

local aspect = Instance.new("UIAspectRatioConstraint")
aspect.AspectRatio = 1
aspect.Parent = button

--// CanvasGroup + full UICorner = everything inside clips to the circle
local clip = Instance.new("CanvasGroup")
clip.Name = "Clip"
clip.Size = UDim2.fromScale(1, 1)
clip.BackgroundColor3 = CHARGE_EMPTY
clip.Parent = button

local clipCorner = Instance.new("UICorner")
clipCorner.CornerRadius = UDim.new(1, 0)
clipCorner.Parent = clip

local ring = Instance.new("UIStroke")
ring.Thickness = 3
ring.Color = CHOC
ring.Parent = clip

--// The class sticker (same art as the shop cards)
local icon = Instance.new("ImageLabel")
icon.Name = "ClassIcon"
icon.AnchorPoint = Vector2.new(0.5, 0.5)
icon.Position = UDim2.fromScale(0.5, 0.44)
icon.Size = UDim2.fromScale(0.62, 0.62)
icon.BackgroundTransparency = 1
icon.ScaleType = Enum.ScaleType.Fit
icon.Parent = clip

--// Fallback face while a class has no icon id
local initial = Instance.new("TextLabel")
initial.AnchorPoint = Vector2.new(0.5, 0.5)
initial.Position = UDim2.fromScale(0.5, 0.44)
initial.Size = UDim2.fromScale(0.6, 0.5)
initial.BackgroundTransparency = 1
initial.Font = Enum.Font.FredokaOne
initial.TextScaled = true
initial.TextColor3 = CHOC
initial.Text = "?"
initial.Visible = false
initial.Parent = clip

--// The 0-100% counter, INSIDE the circle so nothing pokes past the rim
local percent = Instance.new("TextLabel")
percent.Name = "Percent"
percent.AnchorPoint = Vector2.new(0.5, 1)
percent.Position = UDim2.fromScale(0.5, 0.92)
percent.Size = UDim2.fromScale(0.64, 0.22)
percent.BackgroundTransparency = 1
percent.Font = Enum.Font.FredokaOne
percent.TextScaled = true
percent.TextColor3 = Color3.new(1, 1, 1)
percent.TextStrokeColor3 = CHOC
percent.TextStrokeTransparency = 0
percent.Text = "0%"
percent.Parent = clip

--// Floats above the circle: the ultimate's name when ready, denials in
--// tomato. Parented to the button so it follows both layouts for free.
local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.AnchorPoint = Vector2.new(0.5, 1)
hint.Position = UDim2.fromScale(0.5, -0.08)
hint.Size = UDim2.fromScale(3, 0.3)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.FredokaOne
hint.TextScaled = true
hint.TextColor3 = GOLD
hint.TextStrokeColor3 = CHOC
hint.TextStrokeTransparency = 0
hint.Text = ""
hint.Parent = button

----------------------------------------------------------------
-- Placement: stamina-bar corner on desktop, joystick-safe on touch
----------------------------------------------------------------
local function applyLayout()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	if touchOnly then
		--// Right side, above the jump/sprint cluster - the joystick owns
		--// the bottom-left, so the button stays far away from it
		button.AnchorPoint = Vector2.new(1, 1)
		button.Position = UDim2.fromScale(0.93, 0.68)
	else
		--// Right on top of the stamina bar (which sits at 0.03 / 0.95)
		button.AnchorPoint = Vector2.new(0, 1)
		button.Position = UDim2.fromScale(0.03, 0.925)
	end
end

applyLayout()
UserInputService.LastInputTypeChanged:Connect(applyLayout)

----------------------------------------------------------------
-- Rendering
----------------------------------------------------------------
local fillTween = TweenInfo.new(ULT.BarTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local pulseTween = nil
local hintSerial = 0

local function classInfo()
	local classKey = player:GetAttribute("ClassKey")
	if not classKey or classKey == "" then
		return nil
	end
	return classKey, Config.Classes[classKey]
end

local function setPulsing(on)
	if on and not pulseTween then
		pulseTween = TweenService:Create(ring,
			TweenInfo.new(ULT.ReadyPulseSeconds, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut, -1, true),
			{ Color = GOLD, Thickness = 4.5 })
		pulseTween:Play()
	elseif not on and pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
		ring.Color = CHOC
		ring.Thickness = 3
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
	local classKey, class = classInfo()
	button.Visible = classKey ~= nil
	if not classKey then return end

	local hasIcon = class and class.IconId ~= "" and class.IconId ~= "rbxassetid://0"
	icon.Visible = hasIcon == true
	icon.Image = hasIcon and class.IconId or ""
	initial.Visible = not hasIcon
	initial.Text = string.upper(string.sub(classKey, 1, 1))

	local charge = player:GetAttribute("UltimateCharge") or 0
	local fraction = math.clamp(charge / ULT.MaxCharge, 0, 1)

	--// The circle drinks in colour as it charges: white -> blue behind a
	--// black silhouette that lights up to the sticker's true colours
	TweenService:Create(clip, fillTween, {
		BackgroundColor3 = CHARGE_EMPTY:Lerp(CHARGE_FULL, fraction),
	}):Play()
	TweenService:Create(icon, fillTween, {
		ImageColor3 = ICON_DARK:Lerp(Color3.new(1, 1, 1), fraction),
	}):Play()
	initial.TextColor3 = ICON_DARK:Lerp(CHOC, fraction)
	percent.Text = ("%d%%"):format(math.floor(fraction * 100))

	local ready = fraction >= 1
	setPulsing(ready)
	if ready then
		hintSerial += 1 --// a ready banner outranks a stale denial
		hint.TextColor3 = GOLD
		hint.Text = (class and class.UltimateName ~= "" and class.UltimateName or "ULT!") .. " ready!"
	elseif hint.TextColor3 == GOLD then
		hint.Text = ""
	end
end

----------------------------------------------------------------
-- Input: the circle itself + Q + gamepad Y (no separate touch chip)
----------------------------------------------------------------
local function activate()
	ultimateRemote:FireServer("Activate")
end

button.Activated:Connect(activate)

local bound = false

local function onAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		activate()
	end
	return Enum.ContextActionResult.Pass
end

local function refreshBinding()
	local classed = (player:GetAttribute("ClassKey") or "") ~= ""
	if classed and not bound then
		bound = true
		ContextActionService:BindAction(ACTION, onAction, false,
			Enum.KeyCode.Q, Enum.KeyCode.ButtonY)
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
