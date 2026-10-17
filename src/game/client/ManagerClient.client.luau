--[[
	Dinner Rush - ManagerClient
	StarterPlayer.StarterPlayerScripts.Client.ManagerClient  (LocalScript)

	Manager Bruno's FACE. Renders the bottom-centre commentator card: a
	portrait box plus a speech bubble that pops in when ManagerState
	publishes a new line, types it on, lingers, and slides away.

	Portrait: Config.Manager.PortraitImage when the owner uploads Bruno's
	2D PNG; until then the box carries the name placeholder. Render-only:
	ManagerService decides every word.

	Nothing here takes input (Active = false throughout), so a line that
	briefly overlaps another bottom-centre panel never eats its taps.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MANAGER = Config.Manager

local CREAM = Color3.fromRGB(255, 246, 233)
local WARM = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local ManagerState = ReplicatedStorage:WaitForChild("ManagerState")

--// Bottom-MID (owner call): clear of the mobile jump cluster on the
--// right and the stamina bar on the left. Nothing here takes input, so
--// even when a transient line overlaps another bottom-centre panel the
--// taps fall straight through to it.
local CARD_POSITION = UDim2.fromScale(0.5, 0.985)

----------------------------------------------------------------
-- The card (built once, hidden between lines)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ManagerBruno_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 30
gui.Parent = playerGui

local card = Instance.new("Frame")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 1)
card.Position = CARD_POSITION
card.Size = UDim2.fromScale(0.34, 0.13)
card.BackgroundTransparency = 1
card.Active = false
card.Visible = false
card.Parent = gui

--// Portrait box, LEFT of the bubble (owner call - reads name-first)
local portrait = Instance.new("Frame")
portrait.Name = "Portrait"
portrait.AnchorPoint = Vector2.new(0, 1)
portrait.Position = UDim2.fromScale(0, 1)
portrait.Size = UDim2.fromScale(0.26, 1)
portrait.BackgroundColor3 = CREAM
portrait.Active = false
portrait.Parent = card

local pa = Instance.new("UIAspectRatioConstraint")
pa.AspectRatio = 1
pa.DominantAxis = Enum.DominantAxis.Height
pa.Parent = portrait

local pc = Instance.new("UICorner")
pc.CornerRadius = UDim.new(0, 12)
pc.Parent = portrait

local ps = Instance.new("UIStroke")
ps.Thickness = 3
ps.Color = CHOC
ps.Parent = portrait

local pg = Instance.new("UIGradient")
pg.Rotation = 90
pg.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
pg.Parent = portrait

if MANAGER.PortraitImage ~= "" then
	local face = Instance.new("ImageLabel")
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundTransparency = 1
	face.Image = MANAGER.PortraitImage
	face.Active = false
	face.Parent = portrait
else
	--// The placeholder until Bruno's PNG arrives: just the name
	local name = Instance.new("TextLabel")
	name.AnchorPoint = Vector2.new(0.5, 0.5)
	name.Position = UDim2.fromScale(0.5, 0.5)
	name.Size = UDim2.fromScale(0.86, 0.7)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextWrapped = true
	name.TextColor3 = CHOC
	name.Text = MANAGER.Name
	name.Active = false
	name.Parent = portrait
end

--// Speech bubble, right of the portrait
local bubble = Instance.new("Frame")
bubble.Name = "Bubble"
bubble.AnchorPoint = Vector2.new(0, 1)
bubble.Position = UDim2.fromScale(0.28, 0.92)
bubble.Size = UDim2.fromScale(0.72, 0.86)
bubble.BackgroundColor3 = CREAM
bubble.Active = false
bubble.Parent = card

local bc = Instance.new("UICorner")
bc.CornerRadius = UDim.new(0, 12)
bc.Parent = bubble

local bs = Instance.new("UIStroke")
bs.Thickness = 3
bs.Color = CHOC
bs.Parent = bubble

local tail = Instance.new("Frame")
tail.AnchorPoint = Vector2.new(1, 0.5)
tail.Position = UDim2.fromScale(0.015, 0.62)
tail.Size = UDim2.fromScale(0.05, 0.18)
tail.BackgroundColor3 = CREAM
tail.Rotation = 45
tail.BorderSizePixel = 0
tail.Active = false
tail.Parent = bubble

local speech = Instance.new("TextLabel")
speech.AnchorPoint = Vector2.new(0.5, 0.5)
speech.Position = UDim2.fromScale(0.5, 0.5)
speech.Size = UDim2.fromScale(0.9, 0.74)
speech.BackgroundTransparency = 1
speech.Font = Enum.Font.FredokaOne
speech.TextScaled = true
speech.TextWrapped = true
speech.TextColor3 = CHOC
speech.Text = ""
speech.Active = false
speech.ZIndex = 3
speech.Parent = bubble

local cardScale = Instance.new("UIScale")
cardScale.Parent = card

----------------------------------------------------------------
-- Delivery: pop in, type on, linger, slide away
----------------------------------------------------------------
local showing = 0

local function deliver(line)
	showing += 1
	local mine = showing

	card.Visible = true
	speech.Text = ""
	cardScale.Scale = 0.6
	TweenService:Create(cardScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()

	task.spawn(function()
		--// Typewriter: reveal the line over TypeSeconds
		local length = #line
		local step = math.max(MANAGER.TypeSeconds / math.max(length, 1), 0.015)
		for index = 1, length do
			if showing ~= mine then return end
			speech.Text = string.sub(line, 1, index)
			task.wait(step)
		end

		local hold = MANAGER.LineHoldBaseSeconds + MANAGER.LineHoldPerChar * length
		task.wait(hold)
		if showing ~= mine then return end

		local out = TweenService:Create(cardScale,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = 0 })
		out.Completed:Connect(function()
			if showing == mine then
				card.Visible = false
			end
		end)
		out:Play()
	end)
end

ManagerState:GetAttributeChangedSignal("LineId"):Connect(function()
	local line = ManagerState:GetAttribute("Line") or ""
	if line ~= "" then
		deliver(line)
	end
end)
