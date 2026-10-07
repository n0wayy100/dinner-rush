--[[
	Dinner Rush - DailyServer (lobby)
	ServerScriptService.Server.DailyServer  (Script)

	The lobby's door to DAILY MISSIONS, the FREE GIFT and CODES. Clients
	only ask; ProfileAPI decides everything against the saved profile.

	  DailyRemote (RemoteFunction)
	    "State"           -> ProfileAPI.DailyState view
	    "Claim", index    -> ok, { Coins } | reason
	    "Bonus"           -> ok, { Keys, Coins, Streak } | reason
	    "Gift"            -> ok, { Coins, Step } | reason
	    "Redeem", code    -> ok, { Coins, Keys } | reason  (rate-limited)
	    "GroupClaim", key -> ok, { Class, Level } | reason (membership checked HERE)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ProfileAPI = require(ServerStorage:WaitForChild("Shared"):WaitForChild("ProfileAPI"))

local DAILY = Config.Daily

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end
local remote = remotes:FindFirstChild("DailyRemote")
if not remote then
	remote = Instance.new("RemoteFunction")
	remote.Name = "DailyRemote"
	remote.Parent = remotes
end

--// one request at a time per player, and code guessing is slowed down
local busy = {}
local lastRedeem = {}
local failedRedeems = {} --// [player] = { count, windowStart }

Players.PlayerRemoving:Connect(function(player)
	busy[player], lastRedeem[player], failedRedeems[player] = nil, nil, nil
end)

--// Group membership, asked of Roblox by the SERVER (fails closed)
local function inGroup(player)
	local groupId = DAILY.Group and DAILY.Group.GroupId or 0
	if groupId == 0 then return false end
	local ok, result = pcall(function()
		return player:IsInGroupAsync(groupId)
	end)
	if not ok then
		ok, result = pcall(function() return player:IsInGroup(groupId) end)
	end
	return ok and result == true
end

remote.OnServerInvoke = function(player, action, arg)
	if busy[player] then return false, "One moment!" end
	busy[player] = true
	local ok, a, b = pcall(function()
		if action == "State" then
			local view = ProfileAPI.DailyState(player)
			if view then view.InGroup = inGroup(player) end
			return view
		elseif action == "GroupClaim" then
			return ProfileAPI.ClaimGroupReward(player, arg, inGroup(player))
		elseif action == "Claim" then
			return ProfileAPI.ClaimDailyMission(player, tonumber(arg))
		elseif action == "Bonus" then
			return ProfileAPI.ClaimDailyBonus(player)
		elseif action == "Gift" then
			return ProfileAPI.ClaimDailyGift(player)
		elseif action == "Redeem" then
			local now = os.clock()
			if now - (lastRedeem[player] or 0) < (DAILY.RedeemCooldownSeconds or 2) then
				return false, "Slow down!"
			end
			lastRedeem[player] = now
			local fails = failedRedeems[player]
			if fails and now - fails[2] < 60 and fails[1] >= 8 then
				return false, "Too many tries, wait a minute!"
			end
			local success, result = ProfileAPI.RedeemCode(player, arg)
			if not success then
				if not fails or now - fails[2] >= 60 then
					fails = { 0, now }
				end
				fails[1] += 1
				failedRedeems[player] = fails
			end
			return success, result
		end
		return false, "Unknown request"
	end)
	busy[player] = nil
	if not ok then
		warn("[Daily] request failed: " .. tostring(a))
		return false, "Something went wrong, try again!"
	end
	return a, b
end

print("[Daily] lobby ready")
