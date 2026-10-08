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
	if ProfileAPI._ensureSlots then
		ProfileAPI._ensureSlots(data) --// the 5 passive slots (defined below)
	end
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
		CrateKeys = data.CrateKeys or 0,
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

	--// DAILY MISSIONS: the shift-end goals count from the same record
	if ProfileAPI.DailyProgress then
		ProfileAPI.DailyProgress(player, "ShiftsPlayed", 1) --// any shift played to its end
		if entry.Success then
			ProfileAPI.DailyProgress(player, "ShiftsDone", 1)
			if entry.Tone == "good" then
				ProfileAPI.DailyProgress(player, "GreatShift", 1)
			end
		end
		if entry.MVP then
			ProfileAPI.DailyProgress(player, "MVP", 1)
		end
		ProfileAPI.DailyProgress(player, "CoinsEarned", tonumber(entry.Coins) or 0)
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
--// THE 5 SLOTS (owner design, Oct 2026). A player HOLDS at most
--// Config.Passives.SlotsMax passives, in numbered slots; any slot can be
--// LOCKED so a new roll can never replace it. When every slot is full a
--// new roll waits as PendingPassive until the player places it in an
--// unlocked slot (losing what was there) or discards it.
--// OwnedPassives is kept as a mirror of the slots, because ClassService and
--// the equip check read it.
local function slotsMax()
	return Config.Passives.SlotsMax or 5
end

local function rarityRank(key)
	local passive = Config.Passives.List[key]
	local info = passive and Config.Passives.Rarities[passive.Rarity]
	return info and info.Order or 0
end

local function ensureSlots(data)
	local max = slotsMax()
	if type(data.PassiveSlots) ~= "table" then data.PassiveSlots = {} end
	if type(data.PassiveLocks) ~= "table" then data.PassiveLocks = {} end
	for i = 1, max do
		local key = data.PassiveSlots[i]
		if type(key) ~= "string" or (key ~= "" and not Config.Passives.List[key]) then
			data.PassiveSlots[i] = ""
		end
		data.PassiveLocks[i] = data.PassiveLocks[i] == true
	end
	--// a save from before the slots: move its passives in - the equipped
	--// one first, then rarest first - keeping at most `max`
	local empty = true
	for i = 1, max do
		if data.PassiveSlots[i] ~= "" then empty = false break end
	end
	if empty and type(data.OwnedPassives) == "table" and next(data.OwnedPassives) then
		local keys = {}
		for key in pairs(data.OwnedPassives) do
			if Config.Passives.List[key] then table.insert(keys, key) end
		end
		table.sort(keys, function(a, b)
			if a == data.EquippedPassive then return true end
			if b == data.EquippedPassive then return false end
			return rarityRank(a) > rarityRank(b)
		end)
		for i = 1, math.min(max, #keys) do
			data.PassiveSlots[i] = keys[i]
		end
	end
	--// the mirror, and an equipped passive must be in a slot
	data.OwnedPassives = {}
	for i = 1, max do
		local key = data.PassiveSlots[i]
		if key ~= "" then data.OwnedPassives[key] = true end
	end
	if (data.EquippedPassive or "") ~= "" and not data.OwnedPassives[data.EquippedPassive] then
		data.EquippedPassive = ""
	end
	if type(data.PendingPassive) ~= "string" or (data.PendingPassive ~= ""
		and not Config.Passives.List[data.PendingPassive]) then
		data.PendingPassive = ""
	end
end
ProfileAPI._ensureSlots = ensureSlots

--// the slots as the client sees them (plain values)
function ProfileAPI.PassiveSlots(player)
	local data = profileFor(player)
	if not data then return nil end
	ensureSlots(data)
	return {
		Slots = table.clone(data.PassiveSlots),
		Locks = table.clone(data.PassiveLocks),
		Pending = data.PendingPassive,
		Equipped = data.EquippedPassive or "",
	}
end

--// a waiting roll goes into slot `index` (must be unlocked); whatever was
--// there is gone. Placing over the equipped slot equips the new one.
function ProfileAPI.PlacePassive(player, index)
	local data = profileFor(player)
	if not data then return false, NOT_READY end
	ensureSlots(data)
	local key = data.PendingPassive
	if key == "" then return false, "Nothing to place" end
	index = tonumber(index)
	if not index or index < 1 or index > slotsMax() or index % 1 ~= 0 then
		return false, "Pick a slot"
	end
	if data.PassiveLocks[index] then return false, "That slot is locked!" end
	local old = data.PassiveSlots[index]
	data.PassiveSlots[index] = key
	data.PendingPassive = ""
	if old ~= "" and data.EquippedPassive == old then
		data.EquippedPassive = key
	end
	ensureSlots(data)
	changed:Fire(player)
	print(("[ProfileAPI] %s placed %s in slot %d (replaced %s)"):format(player.Name, key, index,
		old ~= "" and old or "nothing"))
	return true, { Slot = index, Replaced = old }
end

function ProfileAPI.DiscardPending(player)
	local data = profileFor(player)
	if not data then return false, NOT_READY end
	ensureSlots(data)
	if data.PendingPassive == "" then return false, "Nothing to discard" end
	print(("[ProfileAPI] %s discarded %s"):format(player.Name, data.PendingPassive))
	data.PendingPassive = ""
	changed:Fire(player)
	return true
end

function ProfileAPI.SetSlotLock(player, index, locked)
	local data = profileFor(player)
	if not data then return false, NOT_READY end
	ensureSlots(data)
	index = tonumber(index)
	if not index or index < 1 or index > slotsMax() or index % 1 ~= 0 then
		return false, "Pick a slot"
	end
	if data.PassiveSlots[index] == "" then return false, "That slot is empty" end
	data.PassiveLocks[index] = locked == true
	changed:Fire(player)
	return true
end

function ProfileAPI.GrantPassive(player, key)
	if type(key) ~= "string" or not Config.Passives.List[key] then
		return false, "That passive does not exist"
	end
	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end
	ensureSlots(data)
	if data.OwnedPassives[key] then
		return false, "Already owned"
	end
	for i = 1, slotsMax() do
		if data.PassiveSlots[i] == "" then
			data.PassiveSlots[i] = key
			ensureSlots(data)
			changed:Fire(player)
			print(("[ProfileAPI] %s gained passive %s"):format(player.Name, key))
			return true
		end
	end
	return false, "All slots are full"
end

function ProfileAPI.EquipPassive(player, key)
	if type(key) ~= "string" or (key ~= "" and not Config.Passives.List[key]) then
		return false, "That passive does not exist"
	end
	local data = profileFor(player)
	if not data then
		return false, NOT_READY
	end
	ensureSlots(data)
	if key ~= "" and not data.OwnedPassives[key] then
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

function ProfileAPI.OpenCrate(player, useKey)
	local P = Config.Passives
	local data = profileFor(player)
	if not data or not Profiles then
		return false, NOT_READY
	end
	local price = P.CratePrice
	ensureSlots(data)
	if data.PendingPassive ~= "" then
		return false, "Place or discard your new passive first!"
	end
	if useKey == true then
		--// a FREE open with a crate key (daily bonus / codes). A key-opened
		--// duplicate still refunds coins, at the normal rate.
		if (data.CrateKeys or 0) < 1 then
			return false, "No crate keys!"
		end
		data.CrateKeys -= 1
	elseif not Profiles.TrySpendWallet(player, price) then
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

	local duplicate = data.OwnedPassives[key] == true
	local refund = 0
	local autoEquipped = false
	local needsSlot = false
	local placedSlot = nil
	if duplicate then
		refund = math.floor(price * (P.DuplicateRefund[rarity] or 0))
		if refund > 0 then
			Profiles.AddWallet(player, refund)
		end
	else
		--// the first empty slot, else it WAITS for the player to choose
		for i = 1, slotsMax() do
			if data.PassiveSlots[i] == "" then
				data.PassiveSlots[i] = key
				placedSlot = i
				break
			end
		end
		if placedSlot then
			ensureSlots(data)
			--// a first passive goes straight on - nothing to lose
			if (data.EquippedPassive or "") == "" then
				data.EquippedPassive = key
				autoEquipped = true
			end
		else
			data.PendingPassive = key
			needsSlot = true
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
		NeedsSlot = needsSlot,   --// all 5 full: the player picks a slot or discards
		Slot = placedSlot,
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

----------------------------------------------------------------
-- DAILY MISSIONS, THE FREE GIFT AND CODES (Oct 2026, Config.Daily)
--
-- Everything is decided HERE against the saved profile. The lobby's
-- DailyServer only forwards requests; the game place's DailyService only
-- reports progress. A client can ask, never award itself anything.
----------------------------------------------------------------
local DAILY = Config.Daily

local function dayIndex()
	return math.floor((os.time() + (DAILY.ResetOffsetHours or 0) * 3600) / 86400)
end

local function secondsToReset()
	local t = os.time() + (DAILY.ResetOffsetHours or 0) * 3600
	return 86400 - (t % 86400)
end

local function missionDef(key)
	for tier, list in pairs(DAILY.Pool) do
		for _, def in ipairs(list) do
			if def.Key == key then
				return def, tier
			end
		end
	end
	return nil, nil
end

--// Today's three, rolled the first time the player is looked at each day.
--// Seeded by player + day so a re-roll (e.g. a lost save write) is the same.
local function ensureDaily(player, data)
	if type(data.Daily) ~= "table" then
		data.Daily = {}
	end
	local d = data.Daily
	local today = dayIndex()
	if d.Day ~= today or type(d.Missions) ~= "table" or #d.Missions == 0 then
		local rng = Random.new(player.UserId * 7919 + today)
		d.Day = today
		d.Missions = {}
		d.BonusClaimed = false
		for _, tier in ipairs(DAILY.MissionsPerDay) do
			local list = DAILY.Pool[tier]
			local fixed = DAILY.Fixed and DAILY.Fixed[tier]
			if fixed then
				table.insert(d.Missions, { Key = fixed, Progress = 0, Claimed = false })
			elseif list and #list > 0 then
				local def = list[rng:NextInteger(1, #list)]
				table.insert(d.Missions, { Key = def.Key, Progress = 0, Claimed = false })
			end
		end
	end
	--// a Fixed mission added mid-day replaces that tier's untouched roll
	for index, tier in ipairs(DAILY.MissionsPerDay) do
		local fixed = DAILY.Fixed and DAILY.Fixed[tier]
		local mission = d.Missions[index]
		if fixed and mission and mission.Key ~= fixed and not mission.Claimed and mission.Progress == 0 then
			d.Missions[index] = { Key = fixed, Progress = 0, Claimed = false }
		end
	end
	d.Streak = d.Streak or 0
	d.LastBonusDay = d.LastBonusDay or 0
	return d
end

--// Progress from gameplay (game place). Counts only toward unclaimed,
--// unfinished missions whose Stat matches.
function ProfileAPI.DailyProgress(player, stat, amount)
	local data = profileFor(player)
	if not data then return false end
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 or type(stat) ~= "string" then return false end
	local d = ensureDaily(player, data)
	local moved = false
	for _, mission in ipairs(d.Missions) do
		local def = missionDef(mission.Key)
		if def and def.Stat == stat and not mission.Claimed and mission.Progress < def.Goal then
			mission.Progress = math.min(def.Goal, mission.Progress + amount)
			moved = true
		end
	end
	return moved
end

--// The lobby screen's view of today (plain values only)
function ProfileAPI.DailyState(player)
	local data = profileFor(player)
	if not data then return nil end
	local d = ensureDaily(player, data)
	local missions, allClaimed = {}, #d.Missions > 0
	for index, mission in ipairs(d.Missions) do
		local def, tier = missionDef(mission.Key)
		if def then
			table.insert(missions, {
				Index = index,
				Tier = tier,
				Text = def.Text:find("%%d") and def.Text:format(def.Goal) or def.Text,
				Goal = def.Goal,
				Progress = math.min(mission.Progress, def.Goal),
				Claimed = mission.Claimed == true,
				Reward = DAILY.Rewards[tier] or 0,
			})
			if not mission.Claimed then allClaimed = false end
		end
	end
	local gift = type(data.DailyGift) == "table" and data.DailyGift or { LastClaim = 0, Streak = 0 }
	local giftDay = gift.LastClaim or 0
	if giftDay > 1000000 then giftDay = math.floor(giftDay / 86400) end --// old timestamp saves
	local today = dayIndex()
	local nextGiftStep = (giftDay == today - 1) and ((gift.Streak or 0) % #DAILY.GiftCoins) + 1 or 1
	return {
		Missions = missions,
		AllClaimed = allClaimed,
		BonusClaimed = d.BonusClaimed == true,
		--// the streak shown is the one a bonus TODAY would continue
		Streak = (d.LastBonusDay == today or d.LastBonusDay == today - 1) and d.Streak or 0,
		ResetIn = secondsToReset(),
		CrateKeys = data.CrateKeys or 0,
		GiftClaimedToday = giftDay == today,
		GiftStep = giftDay == today and (gift.Streak or 1) or nextGiftStep,
		GiftCoins = DAILY.GiftCoins,
		GroupRewardClass = data.GroupRewardClass or "",
	}
end

function ProfileAPI.ClaimDailyMission(player, index)
	local data = profileFor(player)
	if not data or not Profiles then return false, NOT_READY end
	local d = ensureDaily(player, data)
	local mission = type(index) == "number" and d.Missions[math.floor(index)] or nil
	if not mission then return false, "No such mission" end
	local def, tier = missionDef(mission.Key)
	if not def then return false, "No such mission" end
	if mission.Claimed then return false, "Already claimed!" end
	if mission.Progress < def.Goal then return false, "Not done yet!" end
	mission.Claimed = true
	local coins = DAILY.Rewards[tier] or 0
	Profiles.AddWallet(player, coins)
	changed:Fire(player)
	print(("[ProfileAPI] %s claimed daily %s (+%d)"):format(player.Name, mission.Key, coins))
	return true, { Coins = coins }
end

function ProfileAPI.ClaimDailyBonus(player)
	local data = profileFor(player)
	if not data or not Profiles then return false, NOT_READY end
	local d = ensureDaily(player, data)
	if d.BonusClaimed then return false, "Already claimed today!" end
	for _, mission in ipairs(d.Missions) do
		if not mission.Claimed then return false, "Finish all three first!" end
	end
	d.BonusClaimed = true
	d.Streak = (d.LastBonusDay == d.Day - 1) and (d.Streak + 1) or 1
	d.LastBonusDay = d.Day
	local keys = DAILY.BonusCrateKeys or 1
	data.CrateKeys = (data.CrateKeys or 0) + keys
	local coins = (DAILY.StreakBonusCoins or 0) * math.min(d.Streak - 1, DAILY.StreakBonusCap or 7)
	if coins > 0 then Profiles.AddWallet(player, coins) end
	changed:Fire(player)
	print(("[ProfileAPI] %s finished all dailies - streak %d, +%d key(s), +%d coins")
		:format(player.Name, d.Streak, keys, coins))
	return true, { Keys = keys, Coins = coins, Streak = d.Streak }
end

function ProfileAPI.ClaimDailyGift(player)
	local data = profileFor(player)
	if not data or not Profiles then return false, NOT_READY end
	if type(data.DailyGift) ~= "table" then data.DailyGift = { LastClaim = 0, Streak = 0 } end
	local gift = data.DailyGift
	local last = gift.LastClaim or 0
	if last > 1000000 then last = math.floor(last / 86400) end
	local today = dayIndex()
	if last == today then return false, "Come back tomorrow!" end
	gift.Streak = (last == today - 1) and ((gift.Streak or 0) % #DAILY.GiftCoins) + 1 or 1
	gift.LastClaim = today
	local coins = DAILY.GiftCoins[gift.Streak] or DAILY.GiftCoins[1]
	Profiles.AddWallet(player, coins)
	changed:Fire(player)
	print(("[ProfileAPI] %s claimed the daily gift (day %d, +%d)"):format(player.Name, gift.Streak, coins))
	return true, { Coins = coins, Step = gift.Streak }
end

--// THE GROUP REWARD: one class from Config.Daily.Group.Choices, given at
--// MAX LEVEL, once per player. `inGroup` must come from a SERVER-side
--// membership check (DailyServer asks Roblox) - never from a client.
function ProfileAPI.ClaimGroupReward(player, classKey, inGroup)
	local group = DAILY.Group
	if not group or (group.GroupId or 0) == 0 then return false, "Coming soon!" end
	if inGroup ~= true then return false, "Join the group first!" end
	if type(classKey) ~= "string" or not table.find(group.Choices, classKey) then
		return false, "Pick one of the rewards"
	end
	local class = Config.Classes[classKey]
	if not class then return false, "That class does not exist" end
	local data = profileFor(player)
	if not data then return false, NOT_READY end
	if (data.GroupRewardClass or "") ~= "" then return false, "Already claimed!" end
	local maxLevel = class.UpgradeTrack and (#class.UpgradeTrack.Steps + 1) or 1
	if data.OwnedClasses[classKey] and (data.ClassLevels[classKey] or 1) >= maxLevel then
		return false, "You already have it maxed! Pick the other one."
	end
	data.GroupRewardClass = classKey
	data.OwnedClasses[classKey] = true
	data.ClassLevels[classKey] = maxLevel
	changed:Fire(player)
	print(("[ProfileAPI] %s took the group reward: %s at level %d"):format(player.Name, classKey, maxLevel))
	return true, { Class = classKey, Level = maxLevel }
end

--// Codes: the list is SERVER-ONLY (ServerStorage.Shared.CodeList)
local codeList = nil
pcall(function()
	codeList = require(ServerStorage:WaitForChild("Shared"):WaitForChild("CodeList", 5))
end)

function ProfileAPI.RedeemCode(player, raw)
	if type(raw) ~= "string" or #raw > 40 then return false, "That code doesn't exist" end
	local code = raw:upper():gsub("%s", "")
	local entry = codeList and codeList[code]
	if type(entry) ~= "table" then return false, "That code doesn't exist" end
	if entry.Expires and os.time() > entry.Expires then return false, "That code has expired" end
	local data = profileFor(player)
	if not data or not Profiles then return false, NOT_READY end
	if type(data.RedeemedCodes) ~= "table" then data.RedeemedCodes = {} end
	if data.RedeemedCodes[code] then return false, "You already used that code!" end
	data.RedeemedCodes[code] = true
	local coins = math.floor(tonumber(entry.Coins) or 0)
	local keys = math.floor(tonumber(entry.Keys) or 0)
	if coins > 0 then Profiles.AddWallet(player, coins) end
	if keys > 0 then data.CrateKeys = (data.CrateKeys or 0) + keys end
	changed:Fire(player)
	print(("[ProfileAPI] %s redeemed %s"):format(player.Name, code))
	return true, { Coins = coins, Keys = keys }
end

return ProfileAPI
