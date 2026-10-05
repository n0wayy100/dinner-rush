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
	ProfileAPI.GrantPassive(player, key)       -> ok, reasonText?  (crates)
	ProfileAPI.EquipPassive(player, key)       -> ok, reasonText?  ("" unequips)
	ProfileAPI.OpenCrate(player)               -> ok, result | reasonText  (pay + roll)
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

--// PLAYTEST GRANT (Config.Profile.PlaytestGrant): tops a NAMED tester up
--// to GrantWallet whenever they load below it, so classes are freely
--// buyable during a playtest. Never touches anyone not on the list.
local function playtestGrant(player, data)
	local grant = SETTINGS.PlaytestGrant
	if not grant or grant.Enabled ~= true then
		return false
	end
	local named = grant.GrantEveryone == true
	if not named then
		for _, name in ipairs(grant.Usernames or {}) do
			if player.Name:lower() == tostring(name):lower() then
				named = true
				break
			end
		end
	end
	if not named then
		return false
	end
	local target = grant.GrantWallet or 0
	if data.Wallet >= target then
		return false
	end
	--// through AddWallet so the visible leaderstats Wallet updates too (a
	--// direct write left the screen showing 0 while the save held 10k)
	if Profiles then
		Profiles.AddWallet(player, target - data.Wallet)
	else
		data.Wallet = target
	end
	warn(("[ProfileAPI] PLAYTEST GRANT: topped %s up to %d coins")
		:format(player.Name, target))
	return true
end

--// PLAYTEST: unlock every class for EVERY player (Config.Profile
--// .PlaytestGrant.UnlockAllClasses). Written to the real save; turn off
--// after the playtest.
local function unlockAllClasses(player, data)
	local grant = SETTINGS.PlaytestGrant
	if not grant or grant.Enabled ~= true or grant.UnlockAllClasses ~= true then
		return false
	end
	local changedAny = false
	for classKey in pairs(Config.Classes) do
		if not data.OwnedClasses[classKey] then
			data.OwnedClasses[classKey] = true
			data.ClassLevels[classKey] = data.ClassLevels[classKey] or 1
			changedAny = true
		end
	end
	if changedAny then
		warn(("[ProfileAPI] PLAYTEST: unlocked all classes for %s"):format(player.Name))
	end
	return changedAny
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
	local topped = playtestGrant(player, data)
	local unlocked = unlockAllClasses(player, data)
	if granted or seeded or topped or unlocked then
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
		OwnedPassives = {},
		EquippedPassive = "",
		CratePityEpic = 0,
		CratePityLegendary = 0,
		ClassLevels = {},
		TaskProgress = tasks,
		Stats = stats,
		BestShifts = {},
		RecentShifts = {},
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
		OwnedPassives = table.clone(data.OwnedPassives or {}),
		EquippedPassive = data.EquippedPassive or "",
		CratePityEpic = data.CratePityEpic or 0,
		CratePityLegendary = data.CratePityLegendary or 0,
		CratesOpened = data.CratesOpened or 0,
		ClassLevels = table.clone(data.ClassLevels),
		TaskProgress = table.clone(data.TaskProgress),
		Stats = table.clone(data.Stats),
		BestShifts = table.clone(data.BestShifts),
		RecentShifts = table.clone(data.RecentShifts or {}),
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

	--// THE SHIFT LOG (Oct 2026): every shift, newest first, with what THIS
	--// player got out of it. Plain values only (it is saved).
	if type(data.RecentShifts) ~= "table" then
		data.RecentShifts = {}
	end
	table.insert(data.RecentShifts, 1, {
		Grade = tostring(entry.Grade or "?"),
		Tone = tostring(entry.Tone or "mid"),
		Label = tostring(entry.Label or ""),
		DiffName = tostring(entry.DiffName or "NORMAL"),
		Map = tostring(entry.Map or ""),
		Served = tonumber(entry.Served) or 0,
		Walkouts = tonumber(entry.Walkouts) or 0,
		PerfectCooks = tonumber(entry.PerfectCooks) or 0,
		Coins = tonumber(entry.Coins) or 0,
		Title = tostring(entry.Title or ""),
		MVP = entry.MVP == true,
		Success = entry.Success ~= false,
		Seconds = tonumber(entry.Seconds) or 0,
		When = tonumber(entry.When) or os.time(),
	})
	while #data.RecentShifts > (Config.PlayerStats.RecentShiftsCap or 10) do
		table.remove(data.RecentShifts)
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

--// PASSIVES (Oct 2026). GrantPassive is the crate system's write - server
--// code only, never reachable from a remote on its own. EquipPassive
--// validates ownership; "" unequips.
function ProfileAPI.GrantPassive(player, key)
	if type(key) ~= "string" or not Config.Passives.List[key] then
		return false, "That passive does not exist"
	end
	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end
	data.OwnedPassives = data.OwnedPassives or {}
	if data.OwnedPassives[key] then
		return false, "Already owned"
	end
	data.OwnedPassives[key] = true
	changed:Fire(player)
	print(("[ProfileAPI] %s gained passive %s"):format(player.Name, key))
	return true
end

function ProfileAPI.EquipPassive(player, key)
	if type(key) ~= "string" or (key ~= "" and not Config.Passives.List[key]) then
		return false, "That passive does not exist"
	end
	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end
	if key ~= "" and not (data.OwnedPassives and data.OwnedPassives[key]) then
		return false, "You don't own that yet!"
	end
	if (data.EquippedPassive or "") == key then
		return false, "Already equipped!"
	end
	data.EquippedPassive = key
	changed:Fire(player)
	print(("[ProfileAPI] %s equipped passive %s"):format(player.Name,
		key ~= "" and key or "(none)"))
	return true
end

--// THE CRATE (Oct 2026). The whole roll happens HERE, server-side, against
--// the saved profile: pay, roll the rarity (with pity), roll a passive in
--// that rarity, then either grant it or refund a duplicate. Callers
--// (CrateServer) do the policy / cooldown checks before calling this.
local crateRng = Random.new()

local function rollRarity(epicMiss, legendaryMiss)
	local P = Config.Passives
	--// pity: the counters already include THIS crate
	if legendaryMiss >= P.PityLegendary then
		return "Legendary", "pity"
	end
	local pool = {}
	for name, info in pairs(P.Rarities) do
		if epicMiss < P.PityEpic or info.Order >= P.Rarities.Epic.Order then
			table.insert(pool, { Name = name, Weight = info.Weight, Order = info.Order })
		end
	end
	table.sort(pool, function(a, b) return a.Order < b.Order end)
	local total = 0
	for _, entry in ipairs(pool) do total += entry.Weight end
	local pick = crateRng:NextNumber() * total
	for _, entry in ipairs(pool) do
		pick -= entry.Weight
		if pick <= 0 then
			return entry.Name, (epicMiss >= P.PityEpic) and "pity" or "luck"
		end
	end
	return pool[#pool].Name, "luck"
end

function ProfileAPI.OpenCrate(player)
	local P = Config.Passives
	local data = profileFor(player)
	if not data or not Profiles then
		return false, NOT_READY
	end
	local price = P.CratePrice
	if not Profiles.TrySpendWallet(player, price) then
		return false, ("Need %d more coins!"):format(math.max(0, price - (data.Wallet or 0)))
	end

	local epicMiss = (data.CratePityEpic or 0) + 1
	local legendaryMiss = (data.CratePityLegendary or 0) + 1
	local rarity, how = rollRarity(epicMiss, legendaryMiss)

	--// pity counters: an Epic resets the Epic counter, a Legendary both
	if rarity == "Legendary" then
		data.CratePityEpic, data.CratePityLegendary = 0, 0
	elseif rarity == "Epic" then
		data.CratePityEpic, data.CratePityLegendary = 0, legendaryMiss
	else
		data.CratePityEpic, data.CratePityLegendary = epicMiss, legendaryMiss
	end
	data.CratesOpened = (data.CratesOpened or 0) + 1

	--// an even split inside the rarity
	local inRarity = {}
	for _, key in ipairs(P.Order) do
		local passive = P.List[key]
		if passive and passive.Rarity == rarity then
			table.insert(inRarity, key)
		end
	end
	local key = inRarity[crateRng:NextInteger(1, #inRarity)]

	data.OwnedPassives = data.OwnedPassives or {}
	local duplicate = data.OwnedPassives[key] == true
	local refund = 0
	local autoEquipped = false
	if duplicate then
		refund = math.floor(price * (P.DuplicateRefund[rarity] or 0))
		if refund > 0 then
			Profiles.AddWallet(player, refund)
		end
	else
		data.OwnedPassives[key] = true
		--// a first passive goes straight on - nothing to lose
		if (data.EquippedPassive or "") == "" then
			data.EquippedPassive = key
			autoEquipped = true
		end
	end

	changed:Fire(player)
	print(("[ProfileAPI] %s opened a crate: %s %s (%s)%s"):format(player.Name, rarity, key, how,
		duplicate and (" - duplicate, refunded %d"):format(refund) or ""))
	return true, {
		Key = key,
		Rarity = rarity,
		Duplicate = duplicate,
		Refund = refund,
		AutoEquipped = autoEquipped,
		Pity = how == "pity",
	}
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

	--// (owner, Oct 5 2026: no task gate any more - levels are bought with
	--// coins alone. Track.Steps still sets the max level: #Steps + 1.)
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
