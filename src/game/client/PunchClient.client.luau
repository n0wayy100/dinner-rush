--[[
	Dinner Rush - PunchClient
	StarterPlayer.StarterPlayerScripts.Client.PunchClient  (LocalScript)

	The dine-and-dash punch: left-click on PC, tap on touch, X on
	gamepad - EMPTY-HANDED ONLY (holding any Tool means you're working,
	not brawling). Intent only: this fires PunchRemote and nothing else;
	the server re-checks hands, cooldown, and whether a dasher is
	actually in reach. Spamming clicks at nothing costs nothing.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local punchRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PunchRemote")

local player = Players.LocalPlayer
local lastSentAt = 0

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end --// a click on UI is a click on UI

	local isPunchInput = input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.ButtonX
	if not isPunchInput then return end

	local character = player.Character
	if not character or character:FindFirstChildOfClass("Tool") then
		return --// hands full = no punching (the server checks too)
	end

	local now = os.clock()
	if now - lastSentAt < Config.Dash.PunchCooldownSeconds then return end
	lastSentAt = now

	punchRemote:FireServer()
end)
