--[[
	Dinner Rush - ClassService
	ServerScriptService.Server.ClassService  (regular Script, server-side)

	Phase 2, step 1: PASSIVES. Reads each player's EquippedClass from the
	profile (ProfileAPI, now in ServerStorage.Shared) and publishes their
	class modifiers as ATTRIBUTES ON THE PLAYER:

	  ClassKey            "Chef" / "Waiter" / "Fixer" / "Charmer" / ""
	  CollectHoldMult     Chef: collect-prompt holds (stations + pass)
	  StaminaDrainMult    Waiter: sprint drain  (client reads - movement
	  StaminaRegenMult    Waiter: sprint regen   feel exception)
	  ChannelMult         Fixer: plunge / douse / breaker channels
	  MoneyMult           Charmer: payment collection bonus
	  RecommendBonusMult  Charmer: recommendation patience bonus

	Attributes because they need no bridge: server systems read them off the
	Player directly, and they replicate to that client for SprintClient.
	Everyone defaults to 1 - classless play is legal and unpunished.

	LOCK RULE: the class applies on arrival and re-applies freely during
	WAITING/PREP; the moment the shift is RUNNING it is locked for the
	shift. (Equipping happens in the lobby anyway - the lock is
	belt-and-braces against anything that fires Changed mid-shift.)

	THE LAW: nothing here touches CookTime, PerfectWindow, OvercookAfter,
	BurntAfter. Collect holds and event channels are chores, not skill
	windows.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Class] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

local ProfileAPI = require(ServerStorage:WaitForChild("Shared"):WaitForChild("ProfileAPI"))

print("[Class] script started")

--// attribute name -> Config.Classes field it reads (missing field = 1)
local MODIFIERS = {
	CollectHoldMult = "CollectHoldMult",
	StaminaDrainMult = "StaminaDrainMult",
	StaminaRegenMult = "StaminaRegenMult",
	ChannelMult = "ChannelMult",
	MoneyMult = "MoneyMult",
	RecommendBonusMult = "RecommendBonusMult",
}

local function shiftRunning()
	local bridge = ServerStorage:FindFirstChild("GetShiftInfo")
	if not bridge then return false end
	local ok, info = pcall(function() return bridge:Invoke() end)
	return ok and type(info) == "table" and info.State == "RUNNING"
end

local lockedIn = {} --// [player] = true once the shift caught them RUNNING

local function applyClass(player)
	if lockedIn[player] then return end

	local snapshot = ProfileAPI.GetSnapshot(player)
	local classKey = snapshot.EquippedClass or ""
	local class = classKey ~= "" and Config.Classes[classKey] or nil
	if classKey ~= "" and not class then
		warn(("[Class] %s has unknown EquippedClass '%s' - treating as classless")
			:format(player.Name, classKey))
		classKey, class = "", nil
	end

	local before = player:GetAttribute("ClassKey")
	player:SetAttribute("ClassKey", classKey)
	for attribute, field in pairs(MODIFIERS) do
		player:SetAttribute(attribute, (class and class[field]) or 1)
	end

	if before ~= classKey then
		print(("[Class] %s plays as %s"):format(player.Name,
			classKey ~= "" and class.Display or "no class"))
	end
end

local function watchPlayer(player)
	applyClass(player)

	--// The profile can arrive a moment after the player does (DataStore
	--// window) and nothing fires Changed on a plain load - so re-apply on
	--// a slow poll until the shift locks them in. Cheap, self-healing.
	task.spawn(function()
		while player.Parent and not lockedIn[player] do
			if shiftRunning() then
				lockedIn[player] = true
				print(("[Class] %s locked in as %s for this shift"):format(
					player.Name, player:GetAttribute("ClassKey") ~= "" and
					player:GetAttribute("ClassKey") or "no class"))
				break
			end
			applyClass(player)
			task.wait(2)
		end
	end)
end

Players.PlayerAdded:Connect(watchPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	watchPlayer(player)
end

Players.PlayerRemoving:Connect(function(player)
	lockedIn[player] = nil
end)

--// Instant refresh when the profile actually changes pre-lock
ProfileAPI.Changed:Connect(function(player)
	if player.Parent and not lockedIn[player] then
		applyClass(player)
	end
end)
