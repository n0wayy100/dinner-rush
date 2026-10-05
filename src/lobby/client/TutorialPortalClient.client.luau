--[[
	Dinner Rush - TutorialPortalClient (lobby)
	StarterPlayerScripts.Client.TutorialPortalClient  (LocalScript)

	The HOW TO PLAY guide's YES / NO card. The server fires "Ask" on
	TutorialPortalRemote when a player talks to the guide; this card
	asks "Play the tutorial with Bruno?" - YES tells the server (which
	re-validates the player is still standing at the guide before any
	teleport), NO just closes. Render + intent only, house style.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
if not sharedFolder then return end
local Config = require(sharedFolder:WaitForChild("Config", 10))
local PORTAL = Config.TutorialPortal

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local portalRemote = remotes:WaitForChild("TutorialPortalRemote")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local BASIL = Color3.fromRGB(76, 175, 109)
local TOMATO = Color3.fromRGB(229, 72, 77)
local WHITE = Color3.fromRGB(255, 255, 255)

local gui = Instance.new("ScreenGui")
gui.Name = "TutorialPortal_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 40
gui.Enabled = false
gui.Parent = playerGui

--// dim the street so the question owns the moment
local dim = Instance.new("TextButton") --// button: tapping outside = NO
dim.Size = UDim2.fromScale(1, 1)
dim.BackgroundColor3 = Color3.new(0, 0, 0)
dim.BackgroundTransparency = 0.45
dim.Text = ""
dim.AutoButtonColor = false
dim.Parent = gui

local card = Instance.new("Frame")
card.AnchorPoint = Vector2.new(0.5, 0.5)
card.Position = UDim2.fromScale(0.5, 0.45)
card.Size = UDim2.fromScale(0.34, 0.3)
card.BackgroundColor3 = CREAM
card.Parent = gui
local cardGradient = Instance.new("UIGradient")
cardGradient.Rotation = 90
cardGradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
cardGradient.Parent = card
local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0.08, 0)
cardCorner.Parent = card
local cardStroke = Instance.new("UIStroke")
cardStroke.Thickness = 3
cardStroke.Color = CHOC
cardStroke.Parent = card
local cardRatio = Instance.new("UIAspectRatioConstraint")
cardRatio.AspectRatio = 1.6
cardRatio.Parent = card

local title = Instance.new("TextLabel")
title.Size = UDim2.fromScale(0.9, 0.22)
title.Position = UDim2.fromScale(0.05, 0.06)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.Text = PORTAL.AskTitle
title.TextColor3 = TOMATO
title.Parent = card
local titleCap = Instance.new("UITextSizeConstraint")
titleCap.MaxTextSize = 30
titleCap.Parent = title

local question = Instance.new("TextLabel")
question.Size = UDim2.fromScale(0.86, 0.26)
question.Position = UDim2.fromScale(0.07, 0.3)
question.BackgroundTransparency = 1
question.Font = Enum.Font.FredokaOne
question.TextScaled = true
question.TextWrapped = true
question.Text = PORTAL.AskLine
question.TextColor3 = CHOC
question.Parent = card
local questionCap = Instance.new("UITextSizeConstraint")
questionCap.MaxTextSize = 24
questionCap.Parent = question

local function makeAnswer(text, color, x)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromScale(0.38, 0.24)
	button.Position = UDim2.fromScale(x, 0.66)
	button.BackgroundColor3 = color
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.Text = text
	button.TextColor3 = WHITE
	button.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CHOC
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border --// box, not glyphs
	stroke.Parent = button
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 26
	cap.Parent = button
	return button
end

local yesButton = makeAnswer(PORTAL.YesLabel, BASIL, 0.09)
local noButton = makeAnswer(PORTAL.NoLabel, TOMATO, 0.53)

local function open()
	gui.Enabled = true
	card.Size = UDim2.fromScale(0.3, 0.26)
	TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.34, 0.3) }):Play()
end

local function close()
	gui.Enabled = false
end

yesButton.Activated:Connect(function()
	portalRemote:FireServer("Yes")
	close()
end)
noButton.Activated:Connect(function()
	portalRemote:FireServer("No")
	close()
end)
dim.Activated:Connect(close) --// tapping the street = not right now

portalRemote.OnClientEvent:Connect(function(action)
	if action == "Ask" then
		open()
	end
end)
