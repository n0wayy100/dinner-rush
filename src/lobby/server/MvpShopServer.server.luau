--[[
	Dinner Rush - MvpShopServer (lobby)
	ServerScriptService.Server.MvpShopServer  (Script)

	The shop's MVP tab (Oct 2026): buy MVP celebrations with coins and equip
	the one that plays when you win MVP. The client only asks; ProfileAPI
	checks the price, the wallet and ownership against the save.

	  MvpShopRemote (RemoteFunction)
	    "State"        -> { Owned = { [name] = true }, Equipped, Wallet }
	    "Buy", name    -> ok, reason
	    "Equip", name  -> ok, reason
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ProfileAPI = require(ServerStorage:WaitForChild("Shared"):WaitForChild("ProfileAPI"))

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end
local remote = remotes:FindFirstChild("MvpShopRemote")
if not remote then
	remote = Instance.new("RemoteFunction")
	remote.Name = "MvpShopRemote"
	remote.Parent = remotes
end

local busy = {}
Players.PlayerRemoving:Connect(function(player) busy[player] = nil end)

remote.OnServerInvoke = function(player, action, name)
	if busy[player] then return false, "One moment!" end
	busy[player] = true
	local ok, a, b = pcall(function()
		if action == "State" then
			return ProfileAPI.MvpState(player)
		elseif action == "Buy" then
			return ProfileAPI.BuyMvp(player, name)
		elseif action == "Equip" then
			return ProfileAPI.EquipMvp(player, name)
		end
		return false, "Unknown request"
	end)
	busy[player] = nil
	if not ok then
		warn("[MvpShop] request failed: " .. tostring(a))
		return false, "Try again!"
	end
	return a, b
end

print("[MvpShop] ready")
