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

--// the VIP pass's free pick: ownership asked of Roblox HERE (server-side,
--// fails closed) - a client can never claim it
local Purchases = nil
pcall(function()
	Purchases = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Purchases"))
end)
local function vipFreeAvailable(player)
	if not Purchases or ProfileAPI.VipMvpPickUsed(player) then return false end
	local ok, owns = pcall(Purchases.OwnsPass, player, "VIP")
	return ok and owns == true
end

local busy = {}
Players.PlayerRemoving:Connect(function(player) busy[player] = nil end)

remote.OnServerInvoke = function(player, action, name)
	if busy[player] then return false, "One moment!" end
	busy[player] = true
	local ok, a, b = pcall(function()
		if action == "State" then
			local state = ProfileAPI.MvpState(player)
			if state then state.VipFree = vipFreeAvailable(player) end
			return state
		elseif action == "Buy" then
			--// a VIP with the pick unused takes this one free; else coins
			return ProfileAPI.BuyMvp(player, name, vipFreeAvailable(player))
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
