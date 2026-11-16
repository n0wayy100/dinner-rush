--[[
	Dinner Rush - DailyService (main game)
	ServerScriptService.Server.DailyService  (Script)

	Counts DAILY MISSION progress during shifts (Config.Daily). It listens
	to the hidden-score bus (ServerStorage.AddScore) that every gameplay
	credit already fires - dishes, seats, orders, perfects, payments, event
	fixes, messes, dashers caught, VIPs served - and hands each one to
	ProfileAPI.DailyProgress, which only moves missions whose Stat matches.
	The shift-end goals (finish a shift, grade, MVP, coins) count inside
	ProfileAPI.RecordShift. Claiming happens in the lobby.
--]]

local ServerStorage = game:GetService("ServerStorage")

local ProfileAPI = require(ServerStorage:WaitForChild("Shared"):WaitForChild("ProfileAPI"))
local Sfx = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Sfx"))

local bus = ServerStorage:WaitForChild("AddScore", 60)
if not bus then
	warn("[Daily] ServerStorage.AddScore never appeared - daily missions will not count")
	return
end

bus.Event:Connect(function(player, key, amount)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or not player.Parent then return end
	local ok, _, finished = pcall(ProfileAPI.DailyProgress, player, key, amount or 1)
	if ok and (finished or 0) > 0 then
		--// a mission just hit its goal mid-shift: a private "done!" for
		--// that player only (Config.Sfx.Sounds.DailyMissionDone)
		Sfx.PlayFor(player, "DailyMissionDone")
	end
end)

print("[Daily] counting mission progress")
