--[[
	Dinner Rush - SuperfanClient
	StarterPlayer.StarterPlayerScripts.Client.SuperfanClient  (LocalScript)

	The Charmer's SUPERFAN pick. While the server has pick mode open (it fires
	"Begin"), LEFT-CLICK (or tap) a glowing candidate customer to charm their
	whole table into fans. Intent only: this sends the clicked model and nothing
	else; the server owns the effect, validates the click is a real candidate for
	this caster, and closes pick mode ("End"). Clicking empty space costs nothing.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SuperfanRemote")

local active = false

remote.OnClientEvent:Connect(function(action)
	if action == "Begin" then
		active = true
	elseif action == "End" then
		active = false
	end
end)

--// From a screen point, find the candidate MODEL under it (server flags each
--// glowing customer with the SuperfanCandidate attribute) and tell the server.
local function tryPick(screenPos)
	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 600, params)
	if not hit then return end

	local inst = hit.Instance
	while inst and inst ~= workspace do
		if inst:GetAttribute("SuperfanCandidate") then
			remote:FireServer("Pick", inst)
			return
		end
		inst = inst.Parent
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not active or gameProcessed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		tryPick(input.Position)
	end
end)
