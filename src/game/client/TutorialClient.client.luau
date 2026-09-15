--[[
	Dinner Rush - TutorialClient
	StarterPlayer.StarterPlayerScripts.Client.TutorialClient  (LocalScript)

	The tutorial's face: a top-centre OBJECTIVE banner ("STEP 3/15 -
	Take the order!") driven by ReplicatedStorage.TutorialState, and a
	SKIP TUTORIAL pill (top-right, clear of mobile thumbs and the shift
	bar). Bruno's teaching lines ride the normal ManagerClient card.

	The TutorialState folder only EXISTS on tutorial servers - on a
	normal shift the wait below times out and this script exits.
	Render-only: skipping is an intent ("Skip" on TutorialRemote); the
	server decides everything else.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local State = ReplicatedStorage:WaitForChild("TutorialState", 30)
if not State then return end --// not a tutorial server

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local tutorialRemote = remotes:WaitForChild("TutorialRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local TOMATO = Color3.fromRGB(229, 72, 77)

local gui = Instance.new("ScreenGui")
gui.Name = "Tutorial_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 28
gui.Parent = playerGui

--// THE BANNER: below the shift bar, above the action
local banner = Instance.new("Frame")
banner.Active = false
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.fromScale(0.5, 0.13)
banner.Size = UDim2.fromScale(0.44, 0.075)
banner.BackgroundColor3 = CREAM
banner.BorderSizePixel = 0
banner.Visible = false
banner.Parent = gui
local gradient = Instance.new("UIGradient")
gradient.Rotation = 90
gradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
gradient.Parent = banner
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.3, 0)
corner.Parent = banner
local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = CHOC
stroke.Parent = banner

local stepChip = Instance.new("TextLabel")
stepChip.Active = false
stepChip.Size = UDim2.fromScale(0.9, 0.34)
stepChip.Position = UDim2.fromScale(0.05, 0.06)
stepChip.BackgroundTransparency = 1
stepChip.Font = Enum.Font.FredokaOne
stepChip.TextScaled = true
stepChip.Text = ""
stepChip.TextColor3 = MUSTARD
stepChip.TextStrokeColor3 = CHOC
stepChip.TextStrokeTransparency = 0.4
stepChip.Parent = banner

local objective = Instance.new("TextLabel")
objective.Active = false
objective.Size = UDim2.fromScale(0.9, 0.5)
objective.Position = UDim2.fromScale(0.05, 0.42)
objective.BackgroundTransparency = 1
objective.Font = Enum.Font.FredokaOne
objective.TextScaled = true
objective.Text = ""
objective.TextColor3 = CHOC
objective.Parent = banner

--// SKIP: top-right pill, out of every mobile control's way
local skip = Instance.new("TextButton")
skip.AnchorPoint = Vector2.new(1, 0)
skip.Position = UDim2.new(1, -12, 0.13, 0)
skip.Size = UDim2.fromScale(0.13, 0.045)
skip.BackgroundColor3 = CREAM
skip.Font = Enum.Font.FredokaOne
skip.TextScaled = true
skip.Text = "SKIP TUTORIAL"
skip.TextColor3 = TOMATO
skip.Parent = gui
local skipCorner = Instance.new("UICorner")
skipCorner.CornerRadius = UDim.new(0.5, 0)
skipCorner.Parent = skip
local skipStroke = Instance.new("UIStroke")
skipStroke.Thickness = 2.5
skipStroke.Color = CHOC
skipStroke.Parent = skip

skip.Activated:Connect(function()
	tutorialRemote:FireServer("Skip")
	skip.Visible = false
end)

local function refresh()
	local text = State:GetAttribute("Objective") or ""
	local step = State:GetAttribute("Step") or 0
	local total = State:GetAttribute("StepCount") or 0

	banner.Visible = text ~= ""
	objective.Text = text
	stepChip.Text = (step > 0 and total > 0)
		and ("STEP %d/%d"):format(step, total) or ""

	--// a little pop so a new objective catches the eye
	banner.Size = UDim2.fromScale(0.4, 0.068)
	TweenService:Create(banner,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(0.44, 0.075) }):Play()
end

State:GetAttributeChangedSignal("Objective"):Connect(refresh)
State:GetAttributeChangedSignal("Step"):Connect(refresh)

--// Wrap-up: a green flourish, then everything melts away
State:GetAttributeChangedSignal("Active"):Connect(function()
	if State:GetAttribute("Active") ~= false then return end
	skip.Visible = false
	stepChip.Text = "🎉"
	stepChip.TextColor3 = BASIL
	task.delay(4, function()
		TweenService:Create(banner, TweenInfo.new(0.5),
			{ Position = UDim2.fromScale(0.5, -0.15) }):Play()
		task.delay(0.55, function()
			gui:Destroy()
		end)
	end)
end)

refresh()
print("[Tutorial] banner up - class is in session")
