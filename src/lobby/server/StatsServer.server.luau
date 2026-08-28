--[[
	Dinner Rush - StatsServer (lobby)
	ServerScriptService.Server.StatsServer  (regular Script, server-side)

	The STATS screen's server half. Assembles the payload the client
	renders: raw numbers from the ProfileAPI snapshot, the derived level
	(computed here from ShiftsCompleted - never stored, cannot desync),
	the Computed registry entries, and the equipped class's display data.
	The client formats and draws; it never computes a stat or a ranking.

	StatsRemote protocol:
	  client -> server  ("Get")            open/refresh request
	  server -> client  ("Stats", payload) full payload
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Stats] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))
local ProfileAPI = require(script.Parent:WaitForChild("ProfileAPI"))

print("[Stats] script started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local statsRemote = remotes:FindFirstChild("StatsRemote")
if not statsRemote then
	statsRemote = Instance.new("RemoteEvent")
	statsRemote.Name = "StatsRemote"
	statsRemote.Parent = remotes
end

local function buildPayload(player)
	local snapshot = ProfileAPI.GetSnapshot(player)

	--// Computed registry values live only in the payload, never the save
	local ownedCount = 0
	for _ in pairs(snapshot.OwnedClasses) do
		ownedCount += 1
	end
	snapshot.Stats.ClassesOwned = ownedCount

	--// Derived, not stored: level can never desync from its own stat
	local perLevel = math.max(Config.PlayerStats.LevelShiftsPerLevel, 1)
	local level = 1 + math.floor((snapshot.Stats.ShiftsCompleted or 0) / perLevel)

	local equipped = snapshot.EquippedClass
	local class = equipped ~= "" and Config.Classes[equipped] or nil

	return {
		Stats = snapshot.Stats,
		TaskProgress = snapshot.TaskProgress,
		BestShifts = snapshot.BestShifts,
		Level = level,
		Wallet = snapshot.Wallet,
		EquippedClass = equipped,
		EquippedDisplay = class and class.Display or "No class",
		EquippedIcon = class and class.IconId or "",
	}
end

statsRemote.OnServerEvent:Connect(function(player, action)
	if action == "Get" then
		statsRemote:FireClient(player, "Stats", buildPayload(player))
	end
end)

--// Live refresh while the panel is open (purchases, upgrades, deposits)
ProfileAPI.Changed:Connect(function(player)
	if player.Parent then
		statsRemote:FireClient(player, "Stats", buildPayload(player))
	end
end)
