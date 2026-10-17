--[[
	Dinner Rush - AvatarPool
	ServerScriptService.Server.AvatarPool  (ModuleScript)

	Keeps a cache of finished CUSTOMER RIGS wearing avatars from players'
	friend lists, so customers walking in look like people you know.

	Models, not descriptions, for two reasons:
	  * CreateHumanoidModelFromDescription builds an R15 rig whatever the
	    source account uses, so there is no R6/R15 mismatch to fight and no
	    ApplyDescription rebuild fighting our anchored roots.
	  * Cloning a finished rig is instant, so a customer appears already
	    dressed instead of popping in plain and changing a beat later.

	Why a cache at all: one shift spawns roughly 25 customers, and the two web
	calls behind this are rate-limited. A pool of a dozen rigs means a dozen
	lookups reused all shift instead of one per customer.

	Everything is pcall'd. Friend lists can be private, the API can fail, and a
	player may have no friends at all - in every case the pool simply stays
	smaller and customers fall back to the plain CustomerRig.

	Usage:
		local AvatarPool = require(script.Parent.AvatarPool)
		AvatarPool.Start()
		local rig = AvatarPool.Get()   -- a fresh clone, or nil
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local AvatarPool = {}

local settings = Config.Customers.Avatars
local rigs = {}           -- array of finished R15 Models, cloned on request
local seenUserId = {}     -- userId -> true, so nobody is fetched twice
local queue = {}          -- userIds waiting to be turned into descriptions
local started = false

--// Somewhere out of Workspace to keep the originals
local stash = Instance.new("Folder")
stash.Name = "AvatarPool"
stash.Parent = ServerStorage

----------------------------------------------------------------
-- Gathering candidate user ids
----------------------------------------------------------------
local function queueUserId(userId)
	userId = tonumber(userId)
	if not userId or userId <= 0 or seenUserId[userId] then
		return
	end
	seenUserId[userId] = true
	table.insert(queue, userId)
end

--// One page of someone's friend list. Private lists just yield nothing.
local function queueFriendsOf(userId)
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(userId)
	end)

	if not ok or not pages then
		return 0
	end

	local added = 0
	local okIterate = pcall(function()
		while added < settings.FriendsPerPlayer do
			for _, friend in ipairs(pages:GetCurrentPage()) do
				queueUserId(friend.Id)
				added += 1
				if added >= settings.FriendsPerPlayer then
					return
				end
			end
			if pages.IsFinished then
				return
			end
			pages:AdvanceToNextPageAsync()
		end
	end)

	if not okIterate then
		return added
	end
	return added
end

----------------------------------------------------------------
-- Turning ids into wearable descriptions, slowly
----------------------------------------------------------------
local function fetchLoop()
	while true do
		if #rigs >= settings.PoolTarget or #queue == 0 then
			task.wait(settings.FetchDelaySeconds)
		else
			local userId = table.remove(queue, 1)

			local ok, description = pcall(function()
				return Players:GetHumanoidDescriptionFromUserId(userId)
			end)

			if not ok or not description then
				warn(("[AvatarPool] could not fetch user %d: %s")
					:format(userId, tostring(description)))
			else
				--// R15 explicitly: the source account's rig type does not
				--// matter, every customer comes out standardised
				local built, model = pcall(function()
					return Players:CreateHumanoidModelFromDescription(
						description, Enum.HumanoidRigType.R15)
				end)

				if built and model then
					model.Name = "Avatar_" .. userId
					model.Parent = stash
					table.insert(rigs, model)
					print(("[AvatarPool] cached rig %d/%d (user %d)")
						:format(#rigs, settings.PoolTarget, userId))
				else
					warn(("[AvatarPool] could not build a rig for user %d: %s")
						:format(userId, tostring(model)))
				end
			end

			--// Spaced out on purpose: rate-limited web call, nothing waiting
			task.wait(settings.FetchDelaySeconds)
		end
	end
end

----------------------------------------------------------------
-- Public
----------------------------------------------------------------
function AvatarPool.Start()
	if started or not settings.Enabled then
		return
	end
	started = true

	task.spawn(function()
		--// Debug list wins outright: deterministic avatars for testing, and it
		--// works on an account with no friends at all.
		local debugIds = settings.DebugUserIds or {}
		if #debugIds > 0 then
			for _, userId in ipairs(debugIds) do
				queueUserId(userId)
			end
			print(("[AvatarPool] DEBUG mode - using %d fixed user id(s), friend lists skipped")
				:format(#queue))
			return
		end

		--// Everyone already here, then everyone who arrives
		for _, player in ipairs(Players:GetPlayers()) do
			local added = queueFriendsOf(player.UserId)
			print(("[AvatarPool] %s: %d friend(s) reachable"):format(player.Name, added))
		end

		Players.PlayerAdded:Connect(function(player)
			task.spawn(queueFriendsOf, player.UserId)
		end)

		--// Nobody's friends reachable? Borrow the owner's list so the
		--// restaurant still fills with faces instead of clones.
		if #queue == 0 and settings.FallbackUserId > 0 then
			print("[AvatarPool] no friends found - falling back to the owner's list")
			queueFriendsOf(settings.FallbackUserId)
			queueUserId(settings.FallbackUserId)
		end

		print(("[AvatarPool] %d candidate avatar(s) queued"):format(#queue))
	end)

	task.spawn(fetchLoop)
end

--// A fresh clone of a random cached rig, or nil while the pool is empty.
--// Never yields - this is called from the spawner.
function AvatarPool.Get()
	if #rigs == 0 then
		return nil
	end
	return rigs[math.random(#rigs)]:Clone()
end

function AvatarPool.Count()
	return #rigs
end

return AvatarPool
