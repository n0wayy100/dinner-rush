--[[
	Dinner Rush - ProfileAPI
	ServerStorage.Shared.ProfileAPI  (ModuleScript - shared by BOTH places;
	the lobby shops through it, the main game counts and deposits through it)

	THE CONTRACT between the lobby UI and player persistence.

	This used to be a stub holding everything in memory. It now writes through
	ServerStorage.Shared.Profiles to the real DataStore. The INTERFACE below is
	unchanged, which is the whole point of how it was written - ClassVendor,
	ClassShopClient and StatsServer needed no edits.

	========================  INTERFACE  ========================
	ProfileAPI.GetSnapshot(player) -> {
	    Wallet        = number,
	    OwnedClasses  = { [classKey] = true },
	    EquippedClass = string,          -- "" = nothing equipped
	    ClassLevels   = { [classKey] = number },
	    TaskProgress  = {                -- cumulative career counters, written
	        PerfectCooks = number,       -- by the MAIN GAME
	        DishesServed = number,
	        EventChannels = number,
	        PaymentsCollected = number,
	        Greetings = number,
	        Recommendations = number,
	    },
	    Stats = { [registryKey] = number },
	    BestShifts = { { Grade, Tone, Label, DiffName, Served, Target,
	                     Net, Seconds, When }, ... }  -- max BestShiftsCap,
	                                                  -- sorted best-first
	}
	ProfileAPI.AddStat(player, key, amount) -> ok
	    -- THE gameplay write call. Key must exist in the Registry (Stats or
	    -- TaskProgress source); routed to the right table automatically.
	ProfileAPI.Deposit(player, amount) -> ok
	    -- The main game's shift-end wallet write (the till split made real).
	    -- Wraps Profiles.AddWallet so Changed fires and every wallet
	    -- mutation stays inside this contract.
	ProfileAPI.RecordShift(player, entry) -> ok
	ProfileAPI.PurchaseClass(player, classKey) -> ok, reasonText?
	ProfileAPI.EquipClass(player, classKey)    -> ok, reasonText?
	ProfileAPI.UpgradeClass(player, classKey)  -> ok, reasonText?
	ProfileAPI.Changed -> Signal(player)
	=============================================================

	Everything here runs on the SERVER and validates against the saved profile.
	The client never does its own money maths - it renders a snapshot.

	One thing genuinely changed for callers: a profile can be MISSING for a
	moment after someone joins, while the DataStore is still answering. Reads
	return an empty snapshot during that window and writes refuse politely,
	rather than inventing a profile that would later be overwritten.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local sharedServer = ServerStorage:WaitForChild("Shared", 20)
local Profiles = sharedServer and require(sharedServer:WaitForChild("Profiles", 20))

if not Profiles then
	warn("[ProfileAPI] ServerStorage.Shared.Profiles missing - the shop cannot save."
		.. " Is the Rojo sync complete?")
end

local ProfileAPI = {}

local changed = Instance.new("BindableEvent")
ProfileAPI.Changed = changed.Event

local SETTINGS = Config.Profile

----------------------------------------------------------------
-- SHAPE
--
-- Reconcile fills in keys added to the template, but the Stats table is
-- driven by a registry rather than the template, so its defaults are merged
-- here. A stat added to the registry later must come back as its default on
-- an old profile, never nil.
----------------------------------------------------------------

local function ensureShape(data)
	data.Stats = data.Stats or {}
	data.BestShifts = data.BestShifts or {}
	data.OwnedClasses = data.OwnedClasses or {}
	data.ClassLevels = data.ClassLevels or {}
	data.TaskProgress = data.TaskProgress or {}

	for _, entry in ipairs(Config.PlayerStats.Registry) do
		if entry.Source == "Stats" and data.Stats[entry.Key] == nil then
			data.Stats[entry.Key] = entry.Default or 0
		elseif entry.Source == "TaskProgress" and data.TaskProgress[entry.Key] == nil then
			data.TaskProgress[entry.Key] = entry.Default or 0
		end
	end
end

--// The tutorial that awards the Trainee does not exist yet, so until it does
--// every profile is handed it on first load. Phase 3 flips the Config flag
--// and the tutorial grants it instead.
local function ensureTrainee(player, data)
	if not SETTINGS.GrantTraineeOnJoin then
		return false
	end
	if data.OwnedClasses.Trainee then
		return false
	end

	data.OwnedClasses.Trainee = true
	data.ClassLevels.Trainee = data.ClassLevels.Trainee or 1
	print(("[ProfileAPI] granted the Trainee to %s"):format(player.Name))
	return true
end

--// DEV ONLY, off by default. Writes fake progress into the REAL save so the
--// upgrade buttons can be exercised without playing shifts. Anything it
--// grants is permanent for that player - see Config.Profile.DevSeedProgress.
local function devSeed(player, data)
	if not SETTINGS.DevSeedProgress or data.DevSeeded then
		return false
	end

	data.DevSeeded = true
	data.Wallet += SETTINGS.DevSeedWallet
	data.TaskProgress.PerfectCooks = math.max(data.TaskProgress.PerfectCooks or 0, 22)
	data.TaskProgress.DishesServed = math.max(data.TaskProgress.DishesServed or 0, 25)
	data.TaskProgress.EventChannels = math.max(data.TaskProgress.EventChannels or 0, 4)
	data.TaskProgress.PaymentsCollected = math.max(data.TaskProgress.PaymentsCollected or 0, 14)

	warn(("[ProfileAPI] DEV SEED applied to %s - this is written to the REAL save")
		:format(player.Name))
	return true
end

--// nil while the DataStore is still answering, or if they are being kicked
local function profileFor(player)
	if not Profiles then
		return nil
	end

	local data = Profiles.Get(player)
	if not data then
		return nil
	end

	ensureShape(data)
	local granted = ensureTrainee(player, data)
	local seeded = devSeed(player, data)
	if granted or seeded then
		changed:Fire(player)
	end
	return data
end

--// What the UI gets when the profile has not arrived yet: a real shape with
--// nothing in it, so the panel renders empty instead of erroring.
local function emptySnapshot()
	local stats, tasks = {}, {}
	for _, entry in ipairs(Config.PlayerStats.Registry) do
		if entry.Source == "Stats" then
			stats[entry.Key] = entry.Default or 0
		elseif entry.Source == "TaskProgress" then
			tasks[entry.Key] = entry.Default or 0
		end
	end
	return {
		Wallet = 0,
		OwnedClasses = {},
		EquippedClass = "",
		ClassLevels = {},
		TaskProgress = tasks,
		Stats = stats,
		BestShifts = {},
	}
end

----------------------------------------------------------------
-- READS
----------------------------------------------------------------

function ProfileAPI.GetSnapshot(player)
	local data = profileFor(player)
	if not data then
		return emptySnapshot()
	end

	return {
		Wallet = data.Wallet,
		OwnedClasses = table.clone(data.OwnedClasses),
		EquippedClass = data.EquippedClass or "",
		ClassLevels = table.clone(data.ClassLevels),
		TaskProgress = table.clone(data.TaskProgress),
		Stats = table.clone(data.Stats),
		BestShifts = table.clone(data.BestShifts),
	}
end

----------------------------------------------------------------
-- WRITES
----------------------------------------------------------------

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

	local data = profileFor(player)
	if not data then
		warn(("[ProfileAPI] AddStat: no profile for %s (dropped %s %+d)")
			:format(player.Name, tostring(key), amount))
		return false
	end

	local target = entry.Source == "TaskProgress" and data.TaskProgress or data.Stats
	target[key] = (target[key] or entry.Default or 0) + amount
	changed:Fire(player)
	return true
end

--// The main game's shift-end wallet write. Through the contract rather
--// than Profiles directly so Changed fires (shop/stats screens refresh)
--// and wallet mutations stay in one auditable place.
function ProfileAPI.Deposit(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return false end

	local data = profileFor(player)
	if not data then
		warn(("[ProfileAPI] Deposit: no profile for %s (dropped %d)"):format(player.Name, amount))
		return false
	end

	Profiles.AddWallet(player, amount)
	changed:Fire(player)
	return true
end

--// Best Shifts insert: sorted (Served desc, Net desc) and trimmed to the
--// cap AT INSERT, so the saved array has a hard ceiling forever.
function ProfileAPI.RecordShift(player, entry)
	if type(entry) ~= "table" then return false end

	local data = profileFor(player)
	if not data then
		warn(("[ProfileAPI] RecordShift: no profile for %s"):format(player.Name))
		return false
	end

	table.insert(data.BestShifts, {
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

	table.sort(data.BestShifts, function(a, b)
		if a.Served ~= b.Served then
			return a.Served > b.Served
		end
		return a.Net > b.Net
	end)

	while #data.BestShifts > Config.PlayerStats.BestShiftsCap do
		table.remove(data.BestShifts)
	end

	changed:Fire(player)
	return true
end

----------------------------------------------------------------
-- TRANSACTIONS
--
-- Every one of these re-reads the saved profile and does its own maths. The
-- client's snapshot is a picture, never an authority.
----------------------------------------------------------------

local NOT_READY = "One moment - still loading your save!"

function ProfileAPI.PurchaseClass(player, classKey)
	local class = type(classKey) == "string" and Config.Classes[classKey] or nil
	if not class then
		return false, "That class does not exist"
	end

	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end

	if data.OwnedClasses[classKey] then
		return false, "Already owned!"
	end
	if classKey == "Trainee" then
		return false, "Complete the tutorial!" --// never a purchase
	end
	if data.Wallet < class.Price then
		return false, ("Need %d more coins!"):format(class.Price - data.Wallet)
	end

	data.Wallet -= class.Price
	data.OwnedClasses[classKey] = true
	data.ClassLevels[classKey] = 1
	changed:Fire(player)
	print(("[ProfileAPI] %s bought %s for %d (wallet now %d)"):format(
		player.Name, classKey, class.Price, data.Wallet))
	return true
end

function ProfileAPI.EquipClass(player, classKey)
	local class = type(classKey) == "string" and Config.Classes[classKey] or nil
	if not class then
		return false, "That class does not exist"
	end

	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end

	if not data.OwnedClasses[classKey] then
		return false, "You don't own that yet!"
	end
	if data.EquippedClass == classKey then
		return false, "Already equipped!"
	end

	data.EquippedClass = classKey
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

	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end

	if not data.OwnedClasses[classKey] then
		return false, "You don't own that yet!"
	end

	local level = data.ClassLevels[classKey] or 1
	if level > #track.Steps then
		return false, "Already max level!"
	end

	local progress = data.TaskProgress[track.Counter] or 0
	local needed = track.Steps[level]
	if progress < needed then
		return false, ("Finish the task first: %s %d/%d"):format(track.Label, progress, needed)
	end

	local cost = track.Costs[level]
	if data.Wallet < cost then
		return false, ("Need %d more coins!"):format(cost - data.Wallet)
	end

	data.Wallet -= cost
	data.ClassLevels[classKey] = level + 1
	changed:Fire(player)
	print(("[ProfileAPI] %s upgraded %s to Lv %d (paid %d, wallet now %d)"):format(
		player.Name, classKey, level + 1, cost, data.Wallet))
	return true
end

----------------------------------------------------------------
-- The profile lands a moment AFTER the player does, so anyone whose panel
-- was already open gets one nudge once it arrives.
----------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		if Profiles and Profiles.WaitFor(player, 30) then
			changed:Fire(player)
		end
	end)
end)

return ProfileAPI
