--[[
	Dinner Rush - MinigameIntroClient
	StarterPlayer.StarterPlayerScripts.Client.MinigameIntroClient  (LocalScript)

	THE MINIGAME INTRO BANNER (owner, Oct 2026). Just under the shift timer, a
	bar pops up with the minigame's name; when it pops away, the game opens.

	Render only. The SERVER decides when and for how long (MinigameIntro) and
	holds the game back until the banner is done, so nothing here can change
	a game's timing:
	  S->C  "Show" (name, seconds)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MinigameIntroRemote")

local MUSTARD = Color3.fromRGB(245, 184, 65)
local CHOC = Color3.fromRGB(59, 43, 32)

local settings = Config.MinigameIntro or {}

local gui = Instance.new("ScreenGui")
gui.Name = "MinigameIntro_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 55 --// over the HUD (50), under the shift report (60)
gui.Parent = playerGui

local banner = Instance.new("TextLabel")
banner.Name = "Banner"
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.fromScale(0.5, settings.BannerY or 0.17)
banner.Size = UDim2.fromScale(0.34, 0.07)
banner.BackgroundColor3 = MUSTARD
banner.Font = Enum.Font.FredokaOne
banner.TextScaled = true
banner.TextColor3 = CHOC
banner.Text = ""
banner.Visible = false
banner.Parent = gui

--// Phones are narrow: never so small the name cannot be read
local sizeLimit = Instance.new("UISizeConstraint")
sizeLimit.MinSize = Vector2.new(220, 42)
sizeLimit.Parent = banner

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = banner

local border = Instance.new("UIStroke")
border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
border.Thickness = 3
border.Color = CHOC
border.Parent = banner

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0.05, 0)
pad.PaddingRight = UDim.new(0.05, 0)
pad.PaddingTop = UDim.new(0.14, 0)
pad.PaddingBottom = UDim.new(0.14, 0)
pad.Parent = banner

local scale = Instance.new("UIScale")
scale.Parent = banner

local POP_IN = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.In)

local showing = 0 --// a newer banner cancels an older one's exit

remote.OnClientEvent:Connect(function(action, name, seconds)
	if action ~= "Show" then return end
	showing += 1
	local mine = showing

	banner.Text = tostring(name or "")
	banner.Rotation = math.random(-3, 3)
	scale.Scale = 0
	banner.Visible = true
	TweenService:Create(scale, POP_IN, { Scale = 1 }):Play()

	--// Away just as the game opens, so the two never sit on screen together
	local hold = math.max((tonumber(seconds) or 1.2) - POP_OUT.Time, 0.1)
	task.delay(hold, function()
		if showing ~= mine then return end
		local out = TweenService:Create(scale, POP_OUT, { Scale = 0 })
		out:Play()
		out.Completed:Wait()
		if showing == mine then
			banner.Visible = false
		end
	end)
end)
