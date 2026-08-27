--[[
	Dinner Rush - ProfileAPI  (currently the STUB)
	ServerScriptService.Server.ProfileAPI  (ModuleScript)

	THE CONTRACT between the lobby UI and player persistence. The real
	ProfileService (being built in a parallel session) replaces the INSIDES
	of this module - the interface below must survive exactly as-is, and
	then the UI never changes.

	========================  INTERFACE  ========================
	ProfileAPI.GetSnapshot(player) -> {
	    Wallet        = number,
	    OwnedClasses  = { [classKey] = true },
	    EquippedClass = string,          -- "" = nothing equipped
	    ClassLevels   = { [classKey] = number },
	    TaskProgress  = {                -- cumulative career counters, written
	        PerfectCooks = number,       -- by the MAIN GAME through the real
	        DishesServed = number,       -- ProfileService (future phase); the
	        EventChannels = number,      -- lobby only READS them
	        PaymentsCollected = number,
	        Greetings = number,
	        Recommendations = number,
	    },
	}
	ProfileAPI.PurchaseClass(player, classKey) -> ok: boolean, reasonText: string?
	ProfileAPI.EquipClass(player, classKey)    -> ok: boolean, reasonText: string?
	ProfileAPI.UpgradeClass(player, classKey)  -> ok: boolean, reasonText: string?
	    -- level-up: requires the class's UpgradeTrack task threshold met
	    -- (Config.Classes[key].UpgradeTrack.Steps[level]) AND wallet >=
	    -- Costs[level]. Task gates, money pays - both, always.
	ProfileAPI.Changed  -> RBXScriptSignal, fires (player) after any change
	=============================================================

	Rules the real implementation must keep:
	  * ALL validation server-side IN HERE (valid key, ownership, wallet vs
	    price, Trainee never buyable). The UI only ever asks.
	  * New profiles own Trainee by default (there is no tutorial yet; the
	    "Complete the tutorial!" card state stays unreachable until one
	    exists - deliberate).
	  * reasonText is player-facing - keep it short and friendly.

	STUB behavior: in-memory only. Dev wallet, Trainee owned, nothing
	equipped, everything resets on rejoin. It screams in the log when
	active so it cannot ship silently.
--]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

----------------------------------------------------------------
-- THE FLAG. The real ProfileService deletes everything below the
-- interface docs and keeps the same exports.
----------------------------------------------------------------
local STUB_MODE = true
local STUB_WALLET = 5000 --// dev money so purchases are testable in Studio

if STUB_MODE then
	if RunService:IsStudio() then
		warn(("[ProfileAPI] STUB MODE: in-memory profiles, dev wallet %d, resets on rejoin"):format(STUB_WALLET))
	else
		warn("[ProfileAPI] !!! STUB is running OUTSIDE Studio - nothing saves and the dev wallet is live. Replace with ProfileService before shipping !!!")
	end
end

local ProfileAPI = {}

local changed = Instance.new("BindableEvent")
ProfileAPI.Changed = changed.Event

local profiles = {} --// [userId] = profile (stub: lives only while they do)

local function profileFor(player)
	local profile = profiles[player.UserId]
	if not profile then
		profile = {
			Wallet = STUB_MODE and STUB_WALLET or 0,
			OwnedClasses = { Trainee = true }, --// everyone starts as the Trainee
			EquippedClass = "",
			ClassLevels = { Trainee = 1 },
			--// STUB ONLY: pre-seeded progress so the upgrade flow is testable
			--// (buy Chef -> Lv2 upgrade is ready, Lv3 is task-blocked)
			TaskProgress = {
				PerfectCooks = 22, DishesServed = 9, EventChannels = 4,
				PaymentsCollected = 3, Greetings = 6, Recommendations = 2,
			},
		}
		profiles[player.UserId] = profile
	end
	return profile
end

Players.PlayerRemoving:Connect(function(player)
	profiles[player.UserId] = nil --// stub only: nothing persists, on purpose
end)

function ProfileAPI.GetSnapshot(player)
	local profile = profileFor(player)
	return {
		Wallet = profile.Wallet,
		OwnedClasses = table.clone(profile.OwnedClasses),
		EquippedClass = profile.EquippedClass,
		ClassLevels = table.clone(profile.ClassLevels),
		TaskProgress = table.clone(profile.TaskProgress),
	}
end

function ProfileAPI.PurchaseClass(player, classKey)
	local class = type(classKey) == "string" and Config.Classes[classKey] or nil
	if not class then
		return false, "That class does not exist"
	end

	local profile = profileFor(player)
	if profile.OwnedClasses[classKey] then
		return false, "Already owned!"
	end
	if classKey == "Trainee" then
		return false, "Complete the tutorial!" --// never a purchase
	end
	if profile.Wallet < class.Price then
		return false, ("Need %d more coins!"):format(class.Price - profile.Wallet)
	end

	profile.Wallet -= class.Price
	profile.OwnedClasses[classKey] = true
	profile.ClassLevels[classKey] = 1
	changed:Fire(player)
	print(("[ProfileAPI] %s bought %s for %d (wallet now %d)"):format(
		player.Name, classKey, class.Price, profile.Wallet))
	return true
end

function ProfileAPI.EquipClass(player, classKey)
	local class = type(classKey) == "string" and Config.Classes[classKey] or nil
	if not class then
		return false, "That class does not exist"
	end

	local profile = profileFor(player)
	if not profile.OwnedClasses[classKey] then
		return false, "You don't own that yet!"
	end
	if profile.EquippedClass == classKey then
		return false, "Already equipped!"
	end

	profile.EquippedClass = classKey
	changed:Fire(player)
	print(("[ProfileAPI] %s equipped %s"):format(player.Name, classKey))
	return true
end

--// Task gates, money pays: the level-up needs BOTH the class's cumulative
--// task threshold and the coin cost. Trainee (no UpgradeTrack) never levels.
function ProfileAPI.UpgradeClass(player, classKey)
	local class = type(classKey) == "string" and Config.Classes[classKey] or nil
	if not class then
		return false, "That class does not exist"
	end

	local track = class.UpgradeTrack
	if not track then
		return false, "This class doesn't level up"
	end

	local profile = profileFor(player)
	if not profile.OwnedClasses[classKey] then
		return false, "You don't own that yet!"
	end

	local level = profile.ClassLevels[classKey] or 1
	if level > #track.Steps then
		return false, "Already max level!"
	end

	local progress = profile.TaskProgress[track.Counter] or 0
	local needed = track.Steps[level]
	if progress < needed then
		return false, ("Finish the task first: %s %d/%d"):format(track.Label, progress, needed)
	end

	local cost = track.Costs[level]
	if profile.Wallet < cost then
		return false, ("Need %d more coins!"):format(cost - profile.Wallet)
	end

	profile.Wallet -= cost
	profile.ClassLevels[classKey] = level + 1
	changed:Fire(player)
	print(("[ProfileAPI] %s upgraded %s to Lv %d (paid %d, wallet now %d)"):format(
		player.Name, classKey, level + 1, cost, profile.Wallet))
	return true
end

return ProfileAPI
