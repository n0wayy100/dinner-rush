--[[
	Dinner Rush - ClassService
	ServerScriptService.Server.ClassService  (regular Script, server-side)

	Reads each player's EquippedClass AND EquippedPassive from the profile
	(ProfileAPI, ServerStorage.Shared). Since Oct 2026 the modifiers come
	from the EQUIPPED PASSIVE (Config.Passives - the crate system), not the
	class; the class only decides ClassKey / ClassLevel. Published as
	ATTRIBUTES ON THE PLAYER (the list below is the pre-crate history; the
	live set is Config.Passives.Defaults + PassiveKey + CarryLimit):

	  ClassKey            "Chef" / "Waiter" / "Fixer" / "Charmer" / ""
	  CarryLimit          Chef: how many items they can hold (2 + CarryBonus)
	  StaminaDrainMult    Waiter: sprint drain  (client reads - movement
	  StaminaRegenMult    Waiter: sprint regen   feel exception)
	  ChannelMult         Fixer: plunge / douse / breaker channels
	  MoneyMult           Charmer: payment collection bonus
	  RecommendBonusMult  Charmer: recommendation patience bonus
	  CleanMult           Janitor: dust specks / plunge taps a clean needs
	  ClassLevel          the equipped class's level (the Q/R/T level gate)
	  (CollectHoldMult is still published for back-compat but every class
	   sits at 1 now - E is press-everywhere, so there is no hold to scale.)

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

--// PASSIVES MOVED TO CRATES (Oct 2026, owner design): classes no longer
--// carry passives. Every modifier attribute now comes from the player's
--// EQUIPPED PASSIVE (Config.Passives). Classes keep Q / R / ultimate.
--// These two legacy attributes stay published at 1 (their readers remain).
local LEGACY_ONES = { "CollectHoldMult", "ChannelMult", "CleanMult" }

--// The passive this player plays with: the save's equipped one, if they
--// still own it. Studio's StudioEquip knob overrides for testing.
local function equippedPassive(snapshot)
	local passives = Config.Passives
	if game:GetService("RunService"):IsStudio() and (passives.StudioEquip or "") ~= "" then
		return passives.StudioEquip, passives.List[passives.StudioEquip]
	end
	local key = snapshot.EquippedPassive or ""
	if key == "" or not (snapshot.OwnedPassives or {})[key] then
		return "", nil
	end
	return key, passives.List[key]
end

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

	--// STUDIO: when the ultimate-test knob is on, force that class outright
	--// (passives + skills + ultimate), so a Studio class test is complete
	--// whatever the save says. Live servers never see this.
	if game:GetService("RunService"):IsStudio() then
		local ult = Config.Ultimates
		if ult and ult.StudioFullCharge and (ult.StudioClassKey or "") ~= "" then
			classKey = ult.StudioClassKey
		end
	end

	local class = classKey ~= "" and Config.Classes[classKey] or nil
	if classKey ~= "" and not class then
		warn(("[Class] %s has unknown EquippedClass '%s' - treating as classless")
			:format(player.Name, classKey))
		classKey, class = "", nil
	end

	local before = player:GetAttribute("ClassKey")
	player:SetAttribute("ClassKey", classKey)
	for _, attribute in ipairs(LEGACY_ONES) do
		player:SetAttribute(attribute, 1)
	end

	--// THE EQUIPPED PASSIVE: every Defaults attribute is written each
	--// apply, the passive's Effects over the top - so swapping passives
	--// never leaves a stale bonus behind.
	local passiveKey, passive = equippedPassive(snapshot)
	local effects = passive and passive.Effects or {}
	for attribute, default in pairs(Config.Passives.Defaults) do
		if attribute ~= "CarryBonus" then
			player:SetAttribute(attribute, effects[attribute] or default)
		end
	end
	local beforePassive = player:GetAttribute("PassiveKey")
	player:SetAttribute("PassiveKey", passiveKey)
	if beforePassive ~= passiveKey then
		print(("[Class] %s passive: %s"):format(player.Name,
			passive and passive.Display or "none"))
	end

	--// Carry limit is a COUNT: Big Pockets adds to the Config default.
	local carryBonus = effects.CarryBonus or 0
	player:SetAttribute("CarryLimit", Config.Kitchen.MaxCarriedItems + carryBonus)

	--// THE LEVEL GATE (Oct 2026): the equipped class's level, read off the
	--// save. SkillService / ChargeService refuse slots above it (Q 1, R 3,
	--// ultimate 5 - Config.Skills.UnlockLevels). Server-set, so a client
	--// cannot raise it. Studio's StudioUnlockAll knob (or the ultimate test
	--// knob forcing a class) lifts the gate for testing.
	local level = class and ((snapshot.ClassLevels or {})[classKey] or 1) or 0
	if game:GetService("RunService"):IsStudio() and class then
		local ult = Config.Ultimates
		if (Config.Skills and Config.Skills.StudioUnlockAll)
			or (ult and ult.StudioFullCharge and (ult.StudioClassKey or "") ~= "") then
			level = 99
		end
	end
	player:SetAttribute("ClassLevel", level)

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
