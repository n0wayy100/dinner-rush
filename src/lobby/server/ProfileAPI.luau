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

	--- Stats (the lobby STATS screen; Config.PlayerStats.Registry is the
	--- single source of truth for keys/defaults) ---
	GetSnapshot also returns:
	    Stats      = { [registryKey] = number }  -- merged over registry
	                                             -- defaults on load, so new
	                                             -- stats are never nil
	    BestShifts = { { Grade, Tone, Label, DiffName, Served, Target,
	                     Net, Seconds, When }, ... }  -- max BestShiftsCap,
	                                                  -- sorted best-first
	ProfileAPI.AddStat(player, key, amount) -> ok
	    -- THE gameplay write call (e.g. shift end: AddStat(p,
	    -- "ShiftsCompleted", 1), AddStat(p, "TimeOnFloorSeconds", 480)).
	    -- Key must exist in the Registry (Stats or TaskProgress source);
	    -- routed to the right table automatically.
	ProfileAPI.RecordShift(player, entry) -> ok
	    -- Insert a Best Shifts candidate; server sorts (Served desc, Net
	    -- desc) and trims to BestShiftsCap AT INSERT so the saved array
	    -- has a hard ceiling.
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

			--// Lifetime stats, merged over the registry defaults - the merge
			--// is the pattern the real ProfileService must keep: a stat added
			--// to the registry later must come back as its default, not nil
			Stats = {},

			--// STUB ONLY: two fake history entries so the panel renders
			BestShifts = {
				{ Grade = "GREAT SHIFT!", Tone = "good", Label = "Dinner Rush",
					DiffName = "NORMAL", Served = 15, Target = 15, Net = 420,
					Seconds = 510, When = os.time() - 3 * 86400 },
				{ Grade = "NOT BAD!", Tone = "mid", Label = "Cozy Shift",
					DiffName = "EASY", Served = 9, Target = 11, Net = 260,
					Seconds = 495, When = os.time() - 8 * 86400 },
			},
		}

		--// Merge registry defaults into Stats (STUB seeds a few for show)
		for _, entry in ipairs(Config.PlayerStats.Registry) do
			if entry.Source == "Stats" and profile.Stats[entry.Key] == nil then
				profile.Stats[entry.Key] = entry.Default
			end
		end
		if STUB_MODE then
			profile.Stats.ShiftsCompleted = 7
			profile.Stats.ShiftsFailed = 2
			profile.Stats.CustomersServed = 84
			profile.Stats.MoneyDeposited = 2350
			profile.Stats.TimeOnFloorSeconds = 3540
			profile.Stats.KitchenCrimes = 1
		end
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
		Stats = table.clone(profile.Stats),
		BestShifts = table.clone(profile.BestShifts),
	}
end

--// Registry-validated gameplay write: routes the key to the right table.
--// This is THE call gameplay code makes ("player served a dish", "shift
--// over"). Unknown keys are refused loudly - a typo must not invent a stat.
function ProfileAPI.AddStat(player, key, amount)
	amount = tonumber(amount)
	if not amount or amount == 0 then return false end

	local entry = nil
	for _, row in ipairs(Config.PlayerStats.Registry) do
		if row.Key == key then
			entry = row
			break
		end
	end
	if not entry or entry.Source == "Computed" then
		warn(("[ProfileAPI] AddStat with unknown/computed key '%s'"):format(tostring(key)))
		return false
	end

	local profile = profileFor(player)
	local target = entry.Source == "TaskProgress" and profile.TaskProgress or profile.Stats
	target[key] = (target[key] or entry.Default or 0) + amount
	changed:Fire(player)
	return true
end

--// Best Shifts insert: sorted (Served desc, Net desc) and trimmed to the
--// cap AT INSERT, so the saved array has a hard ceiling forever.
function ProfileAPI.RecordShift(player, entry)
	if type(entry) ~= "table" then return false end

	local profile = profileFor(player)
	table.insert(profile.BestShifts, {
		Grade = tostring(entry.Grade or "?"),
		Tone = tostring(entry.Tone or "mid"),
		Label = tostring(entry.Label or ""),
		DiffName = tostring(entry.DiffName or "NORMAL"),
		Served = tonumber(entry.Served) or 0,
		Target = tonumber(entry.Target) or 0,
		Net = tonumber(entry.Net) or 0,
		Seconds = tonumber(entry.Seconds) or 0,
		When = tonumber(entry.When) or os.time(),
	})

	table.sort(profile.BestShifts, function(a, b)
		if a.Served ~= b.Served then
			return a.Served > b.Served
		end
		return a.Net > b.Net
	end)

	while #profile.BestShifts > Config.PlayerStats.BestShiftsCap do
		table.remove(profile.BestShifts)
	end

	changed:Fire(player)
	return true
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
