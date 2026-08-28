--[[
	Dinner Rush - Profiles
	ServerStorage.Shared.Profiles          SERVER ONLY

	The savefile, wrapped. ProfileStore does storage and session locking; this
	module owns everything Dinner Rush-specific and is the ONLY thing the rest
	of the game talks to. Nothing outside this file requires ProfileStore.

	That indirection is the point: if ProfileStore is ever replaced, this file
	changes and nothing else does.

	Usage (server scripts):
		local Profiles = require(game:GetService("ServerStorage").Shared.Profiles)
		local data = Profiles.Get(player)            -- nil if not loaded yet
		Profiles.AddWallet(player, 250)
		if Profiles.OwnsClass(player, "Chef") then ... end

	Command-bar bridges (ServerStorage, house pattern):
		AddWallet:Invoke(player, amount)  --> new balance
		GetProfile:Invoke(player)         --> the data table

	THE RULE THAT MATTERS: a player with no loaded profile is kicked. Letting
	them play would mean earning progress into a table that is never saved,
	which reads to the player as "the game ate my money".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ProfileStore = require(script.Parent.ProfileStore)

local Profiles = {}

local SETTINGS = Config.Profile

----------------------------------------------------------------
-- STORE
----------------------------------------------------------------

--// Config is deep-frozen, and ProfileStore writes into the structures it
--// builds from the template. Hand it an unfrozen copy so a new profile is
--// never born with frozen tables inside it.
local function deepCopy(t)
	local out = {}
	for key, value in pairs(t) do
		out[key] = type(value) == "table" and deepCopy(value) or value
	end
	return out
end

local store = ProfileStore.New(SETTINGS.StoreName, deepCopy(SETTINGS.Template))

--// Mock is an in-memory store with no relation to the real DataStore. Off by
--// default so the Phase 1 test (earn -> leave -> rejoin) is a real test.
if SETTINGS.UseMockInStudio and RunService:IsStudio() then
	store = store.Mock
	warn("[Profiles] MOCK store - nothing saved this session (Config.Profile.UseMockInStudio)")
end

--// player -> Profile object. Only populated once a session is live.
local sessions = {}

--// player -> true from the moment we start loading. Start() connects
--// PlayerAdded before sweeping the players already in the server, so without
--// this a player who joins between those two steps gets two concurrent
--// StartSessionAsync calls and the second steals the first one's lock.
local claimed = {}

local function keyFor(player)
	return SETTINGS.KeyPrefix .. player.UserId
end

local function ownedCount(data)
	local n = 0
	for _ in pairs(data.OwnedClasses) do
		n += 1
	end
	return n
end

----------------------------------------------------------------
-- DIAGNOSTICS
--
-- Silent DataStore failure is the worst outcome, so every failure mode
-- ProfileStore exposes gets a loud, specific line.
----------------------------------------------------------------

task.spawn(function()
	--// "NotReady" resolves to one of the other three within a few seconds
	while ProfileStore.DataStoreState == "NotReady" do
		task.wait(0.5)
	end

	local state = ProfileStore.DataStoreState
	if state == "Access" then
		print(("[Profiles] DataStore ready - store '%s'"):format(SETTINGS.StoreName))
	elseif state == "NoAccess" then
		warn("[Profiles] NO DATASTORE ACCESS. Nothing will save.")
		warn("[Profiles]   Studio: Game Settings > Security > Enable Studio Access to API Services")
		warn("[Profiles]   Also check this place is PUBLISHED - unpublished places have no DataStore.")
	elseif state == "NoInternet" then
		warn("[Profiles] No internet connection - DataStore unreachable.")
	end
end)

ProfileStore.OnError:Connect(function(message, storeName, key)
	warn(("[Profiles] DataStore error (%s / %s): %s"):format(storeName, tostring(key), message))
end)

ProfileStore.OnOverwrite:Connect(function(storeName, key)
	--// Means the key held something that was not a ProfileStore profile.
	--// Worth shouting about: it usually means two systems share one key.
	warn(("[Profiles] OVERWRITE on %s / %s - that key held non-profile data")
		:format(storeName, tostring(key)))
end)

ProfileStore.OnCriticalToggle:Connect(function(isCritical)
	if isCritical then
		warn("[Profiles] CRITICAL STATE - repeated DataStore failures. Saves are at risk.")
	else
		print("[Profiles] recovered from critical state")
	end
end)

----------------------------------------------------------------
-- LEADERSTATS MIRROR
--
-- Read-only view of Wallet. Coins is left alone: that is the shift's team
-- money and belongs to ServiceLoop.
----------------------------------------------------------------

local function walletValue(player)
	if not SETTINGS.ShowWalletInLeaderstats then
		return nil
	end

	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
	end

	local wallet = stats:FindFirstChild("Wallet")
	if not wallet then
		wallet = Instance.new("IntValue")
		wallet.Name = "Wallet"
		wallet.Parent = stats
	end
	return wallet
end

local function pushWallet(player, amount)
	local value = walletValue(player)
	if value then
		value.Value = amount
	end
end

----------------------------------------------------------------
-- SESSION LIFECYCLE
----------------------------------------------------------------

local function onPlayerAdded(player)
	if claimed[player] then
		return
	end
	claimed[player] = true

	--// Cancel condition: stop hammering the DataStore for someone who already
	--// left. Without this a player who joins and immediately quits leaves a
	--// retry loop running for the full timeout.
	local profile = store:StartSessionAsync(keyFor(player), {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		--// Either they left mid-load (fine) or the store is unreachable.
		if player.Parent == Players then
			warn(("[Profiles] session failed for %s - kicking"):format(player.Name))
			player:Kick(SETTINGS.KickMessage)
		end
		return
	end

	profile:AddUserId(player.UserId)  --// GDPR association
	profile:Reconcile()               --// back-fill any keys added to the template

	--// Fires when THIS server loses the session - normally because another
	--// server started one (the player rejoined elsewhere). Playing on past
	--// this point would write into a dead table.
	profile.OnSessionEnd:Connect(function()
		sessions[player] = nil
		if player.Parent == Players then
			warn(("[Profiles] session ended remotely for %s - kicking"):format(player.Name))
			player:Kick(SETTINGS.KickMessage)
		end
	end)

	if player.Parent ~= Players then
		--// They left while we were loading. Release immediately or the next
		--// server they join waits on a lock nobody is using.
		profile:EndSession()
		return
	end

	sessions[player] = profile
	pushWallet(player, profile.Data.Wallet)

	print(("[Profiles] loaded %s - wallet $%d, %d class(es), tutorial %s"):format(
		player.Name,
		profile.Data.Wallet,
		ownedCount(profile.Data),
		profile.Data.TutorialDone and "done" or "pending"
	))
end

local function onPlayerRemoving(player)
	local profile = sessions[player]
	sessions[player] = nil
	claimed[player] = nil
	if profile then
		--// This is also the lobby -> restaurant handoff. PlayerRemoving fires
		--// when they leave for the teleport, which is well before the game
		--// server asks for the same profile, so the lock is free by then.
		profile:EndSession()
		print(("[Profiles] released %s"):format(player.Name))
	end
end

----------------------------------------------------------------
-- READS
----------------------------------------------------------------

--// nil means "not loaded". Callers must handle it - during the first seconds
--// of a join, and for a player being kicked, there is genuinely no profile.
function Profiles.Get(player)
	local profile = sessions[player]
	if profile and profile:IsActive() then
		return profile.Data
	end
	return nil
end

function Profiles.IsReady(player)
	return Profiles.Get(player) ~= nil
end

--// For code that runs at join time and cannot proceed without a profile.
function Profiles.WaitFor(player, timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or SETTINGS.LoadTimeoutSeconds)
	while os.clock() < deadline do
		local data = Profiles.Get(player)
		if data then
			return data
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(0.1)
	end
	warn(("[Profiles] WaitFor timed out for %s"):format(player.Name))
	return nil
end

----------------------------------------------------------------
-- WRITES
--
-- Every one returns nil/false on failure rather than erroring, so a missing
-- profile degrades to "the reward did not apply" instead of breaking a shift.
----------------------------------------------------------------

function Profiles.AddWallet(player, amount)
	local data = Profiles.Get(player)
	if not data then
		warn(("[Profiles] AddWallet: no profile for %s (dropped %s)"):format(
			player.Name, tostring(amount)))
		return nil
	end

	amount = math.floor(tonumber(amount) or 0)

	--// Never debt (spec 6). A negative net deposits zero.
	data.Wallet = math.max(0, data.Wallet + amount)
	pushWallet(player, data.Wallet)
	return data.Wallet
end

--// Purchases go through here so the balance check and the deduction cannot
--// drift apart. Returns false when they cannot afford it.
function Profiles.TrySpendWallet(player, cost)
	local data = Profiles.Get(player)
	if not data then
		return false
	end

	cost = math.floor(tonumber(cost) or 0)
	if cost < 0 or data.Wallet < cost then
		return false
	end

	data.Wallet -= cost
	pushWallet(player, data.Wallet)
	return true
end

function Profiles.OwnsClass(player, classKey)
	local data = Profiles.Get(player)
	return data ~= nil and data.OwnedClasses[classKey] == true
end

function Profiles.GrantClass(player, classKey)
	local data = Profiles.Get(player)
	if not data or data.OwnedClasses[classKey] then
		return false
	end

	data.OwnedClasses[classKey] = true
	data.ClassLevels[classKey] = data.ClassLevels[classKey] or 1
	print(("[Profiles] %s gained %s"):format(player.Name, classKey))
	return true
end

--// "" (and "None") are always allowed - classless play is legal (spec 2).
function Profiles.SetEquipped(player, classKey)
	local data = Profiles.Get(player)
	if not data then
		return false
	end

	if classKey == "None" then
		classKey = "" --// one representation of "nothing equipped", not two
	end

	if classKey ~= "" and not data.OwnedClasses[classKey] then
		warn(("[Profiles] %s tried to equip unowned %s"):format(player.Name, tostring(classKey)))
		return false
	end

	data.EquippedClass = classKey
	return true
end

function Profiles.BumpTask(player, taskKey, amount)
	local data = Profiles.Get(player)
	if not data then
		return nil
	end

	if data.TaskProgress[taskKey] == nil then
		warn(("[Profiles] BumpTask: '%s' is not in Config.Profile.Template.TaskProgress"):format(
			tostring(taskKey)))
		return nil
	end

	data.TaskProgress[taskKey] += (tonumber(amount) or 1)
	return data.TaskProgress[taskKey]
end

----------------------------------------------------------------
-- START
----------------------------------------------------------------

--// BindableFunction bridges in ServerStorage - the house cross-script pattern
local function bridge(name, handler)
	local existing = ServerStorage:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local fn = Instance.new("BindableFunction")
	fn.Name = name
	fn.OnInvoke = handler
	fn.Parent = ServerStorage
	return fn
end

local started = false

function Profiles.Start()
	if started then
		return
	end
	started = true

	bridge("AddWallet", function(player, amount)
		return Profiles.AddWallet(player, amount)
	end)
	bridge("GetProfile", function(player)
		return Profiles.Get(player)
	end)

	--// Connect BEFORE sweeping, so nobody who joins mid-sweep is missed.
	--// The claimed[] guard makes the overlap harmless.
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	--// Players already here when this runs (Studio start, or a script that
	--// loads a moment after the first join)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	--// No BindToClose here on purpose: ProfileStore registers its own and
	--// flushes every active session on shutdown. A second one would race it.
	print("[Profiles] started")
end

return Profiles
