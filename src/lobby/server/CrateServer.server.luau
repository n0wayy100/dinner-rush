--[[
	Dinner Rush - CrateServer (lobby)
	ServerScriptService.Server.CrateServer  (Script)

	THE PASSIVE CRATE (Oct 2026). The client (CrateClient) only ever ASKS;
	everything that matters happens here and in ProfileAPI.OpenCrate:

	  CrateRemote (RemoteFunction)
	    "State"        -> { Price, Wallet, Owned, Equipped, PityEpic,
	                        PityLegendary, Restricted }
	    "Open"         -> ok, result | reason     (pay + roll, server-side)
	    "Equip", key   -> ok, reason               ("" unequips)
	  CrateShout (RemoteEvent, server -> all)  "Legendary", name, passiveKey

	PAID RANDOM ITEMS: coins can be bought with Robux, so a crate counts as
	a paid random item. PolicyService decides per player; when Roblox says
	they are restricted (or the check fails), crates stay closed for them.
	The odds are shown on the client before every open (Config.Passives).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local PolicyService = game:GetService("PolicyService")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ProfileAPI = require(ServerStorage:WaitForChild("Shared"):WaitForChild("ProfileAPI"))

local P = Config.Passives

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local crateRemote = remotes:FindFirstChild("CrateRemote")
if not crateRemote then
	crateRemote = Instance.new("RemoteFunction")
	crateRemote.Name = "CrateRemote"
	crateRemote.Parent = remotes
end

local shoutRemote = remotes:FindFirstChild("CrateShout")
if not shoutRemote then
	shoutRemote = Instance.new("RemoteEvent")
	shoutRemote.Name = "CrateShout"
	shoutRemote.Parent = remotes
end

----------------------------------------------------------------
-- Policy: are paid random items allowed for this player? Cached per
-- session. Fails CLOSED on a live server; Studio always allows (the
-- policy call does not answer there).
----------------------------------------------------------------
local restrictedCache = {}

local function isRestricted(player)
	if RunService:IsStudio() then return false end
	local cached = restrictedCache[player]
	if cached ~= nil then return cached end
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	local restricted = true
	if ok and type(info) == "table" then
		restricted = info.ArePaidRandomItemsRestricted == true
		restrictedCache[player] = restricted --// only cache a real answer
	end
	return restricted
end

local lastOpen = {}

Players.PlayerRemoving:Connect(function(player)
	restrictedCache[player] = nil
	lastOpen[player] = nil
end)

local function stateFor(player)
	local snapshot = ProfileAPI.GetSnapshot(player)
	return {
		Price = P.CratePrice,
		Wallet = snapshot.Wallet or 0,
		Owned = snapshot.OwnedPassives or {},
		Equipped = snapshot.EquippedPassive or "",
		PityEpic = snapshot.CratePityEpic or 0,
		PityLegendary = snapshot.CratePityLegendary or 0,
		Opened = snapshot.CratesOpened or 0,
		Restricted = isRestricted(player),
	}
end

crateRemote.OnServerInvoke = function(player, action, arg)
	if action == "State" then
		return stateFor(player)

	elseif action == "Open" then
		if isRestricted(player) then
			return false, "Crates are not available for your account."
		end
		local now = os.clock()
		if now - (lastOpen[player] or 0) < (P.OpenCooldownSeconds or 2) then
			return false, "Slow down, chef!"
		end
		lastOpen[player] = now

		local ok, result = ProfileAPI.OpenCrate(player)
		if not ok then
			return false, result
		end
		if result.Rarity == "Legendary" and P.ShoutLegendary then
			shoutRemote:FireAllClients("Legendary", player.DisplayName, result.Key)
		end
		return true, result

	elseif action == "Equip" then
		if type(arg) ~= "string" then
			return false, "Pick a passive"
		end
		return ProfileAPI.EquipPassive(player, arg)
	end

	return false, "Unknown request"
end

print("[Crates] ready")
