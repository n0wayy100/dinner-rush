--[[
	Dinner Rush - SkeletonLoop
	ServerScriptService.Server.SkeletonLoop  (regular Script, server-side)

	The customer journey as a server-owned state machine, all placeholders:

	  QUEUED -> SEATED -> WAITING_FOOD -> SERVED(eating) -> PAYING -> LEAVING

	Interactions (all ProximityPrompts, all handled ON THE SERVER - no remotes):
	  * Prompt on a queued party pawn ......... "Seat party"
	  * Prompt on their table (changes job) ... "Take order" -> "Serve dish" -> "Collect payment"
	  * Prompt on the pass .................... "Pick up Dish (T#)"  (gives a Tool)

	DELIBERATELY ABSENT (later sessions): patience bars, cooking, bussing,
	events, shift timer, real NPC rigs. Customers are labeled cylinders; when
	real rigs arrive, only spawnPartyPawn() changes.

	REQUIRED TAGS on the grey-box (CollectionService), all inside Workspace:
	  QueueSpot  (Attribute: Order = 1..5)   - parts outside the door
	  Table      (Attribute: TableId = 1..4) - the table parts
	  Pass                                   - the pass counter part

	The script waits for these rather than failing at startup, so it works
	whether the restaurant is built into the place or cloned in from
	ServerStorage.Maps by MatchServer. It reports what is missing while it waits.
]]

----------------------------------------------------------------
-- Services & Config
----------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Skeleton] ReplicatedStorage.Shared not found - is your folder named exactly 'Shared'?")
local configModule = sharedFolder:WaitForChild("Config", 10)
assert(configModule, "[Skeleton] Shared.Config not found - the Config module must be installed first")
local Config = require(configModule)

local WALK_SPEED = 12                  -- NPC amble, studs/sec (animation time, untimed by design)
local BASE_COINS_PER_PARTY = 15
local DEBUG_SPAWN_INTERVAL = nil       -- set to e.g. 8 for rapid testing; nil = use Config building-phase rate

--// MatchServer publishes the real shift settings as Workspace attributes when
--// a party teleports in. Playtesting this place directly, they are absent and
--// we fall back so the loop is still playable on its own.
local DIFFICULTY = workspace:GetAttribute("MatchDifficulty")
if not Config.IsValidDifficulty(DIFFICULTY) then
	DIFFICULTY = "NORMAL"
end

local PLAYER_COUNT = workspace:GetAttribute("MatchPlayerCount") or 1
local diff = Config.ForDifficulty(DIFFICULTY)

----------------------------------------------------------------
-- Grey-box discovery
--
-- GetTagged searches the whole DataModel, so a map sitting in ServerStorage
-- would be found alongside the copy in Workspace - same TableIds twice, half
-- the tables unreachable. Scope every lookup to Workspace.
----------------------------------------------------------------
local function taggedInWorkspace(tag)
	local found = {}
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			table.insert(found, instance)
		end
	end
	return found
end

--// Everything here gets read for Position/Size/CFrame, so a tagged Decal,
--// Model or Attachment would only blow up much later inside the spawner.
local function checkIsPart(instance, tag, problems)
	if instance:IsA("BasePart") then
		return true
	end

	table.insert(problems, ("%s is tagged %s but is a %s, not a part - tag the part itself, not its children"):format(
		instance:GetFullName(), tag, instance.ClassName))
	return false
end

--// Returns a list of human-readable problems; empty means the grey-box is usable
local function inspectGreybox(queueSpots, tables, passParts)
	local problems = {}

	if #queueSpots == 0 then
		table.insert(problems, "No parts tagged 'QueueSpot' (need up to 5, Attribute Order = 1..5)")
	else
		local seenOrder = {}
		for _, spot in ipairs(queueSpots) do
			if not checkIsPart(spot, "QueueSpot", problems) then
				continue
			end

			local order = spot:GetAttribute("Order")
			if order == nil then
				table.insert(problems, spot:GetFullName() .. " is tagged QueueSpot but missing the 'Order' attribute")
			elseif seenOrder[order] then
				table.insert(problems, ("Order %s is used by both %s and %s"):format(
					tostring(order), seenOrder[order]:GetFullName(), spot:GetFullName()))
			else
				seenOrder[order] = spot
			end
		end
	end

	if #tables == 0 then
		table.insert(problems, "No parts tagged 'Table' (need 4, Attribute TableId = 1..4)")
	else
		local seenId = {}
		for _, t in ipairs(tables) do
			if not checkIsPart(t, "Table", problems) then
				continue
			end

			local id = t:GetAttribute("TableId")
			if id == nil then
				table.insert(problems, t:GetFullName() .. " is tagged Table but missing the 'TableId' attribute")
			elseif seenId[id] then
				--// Duplicates silently overwrite each other in tableById, leaving
				--// a table nobody can ever be seated at
				table.insert(problems, ("TableId %s is used by both %s and %s"):format(
					tostring(id), seenId[id]:GetFullName(), t:GetFullName()))
			else
				seenId[id] = t
			end
		end
	end

	if #passParts == 0 then
		table.insert(problems, "No part tagged 'Pass' (the pass counter)")
	else
		for _, passPart in ipairs(passParts) do
			checkIsPart(passPart, "Pass", problems)
		end
	end

	return problems
end

--// Waits rather than erroring: the restaurant may be cloned in after we start
local function waitForGreybox()
	local ticks = 0

	while true do
		local queueSpots = taggedInWorkspace("QueueSpot")
		local tables = taggedInWorkspace("Table")
		local passParts = taggedInWorkspace("Pass")

		local problems = inspectGreybox(queueSpots, tables, passParts)
		if #problems == 0 then
			table.sort(queueSpots, function(a, b)
				return (a:GetAttribute("Order") or 99) < (b:GetAttribute("Order") or 99)
			end)

			print(("[Skeleton] Grey-box OK: %d queue spots, %d tables, pass found. Difficulty: %s (%s)")
				:format(#queueSpots, #tables, DIFFICULTY, diff.Label))
			return queueSpots, tables, passParts[1]
		end

		if ticks % 50 == 0 then --// roughly every 5s
			warn("[Skeleton] Waiting on the grey-box:")
			for _, problem in ipairs(problems) do
				warn("  - " .. problem)
			end
		end

		ticks += 1
		task.wait(0.1)
	end
end

local queueSpots, tableParts, passPart = waitForGreybox()

----------------------------------------------------------------
-- Leaderstats (visible coins so serving feels like something)
----------------------------------------------------------------
local function giveLeaderstats(player)
	if player:FindFirstChild("leaderstats") then return end

	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = 0
	coins.Parent = stats
	stats.Parent = player
end

--// Players already in the server when this script finishes waiting would
--// otherwise never get stats, and payment would silently do nothing
for _, player in ipairs(Players:GetPlayers()) do
	giveLeaderstats(player)
end
Players.PlayerAdded:Connect(giveLeaderstats)

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local STATE = {
	QUEUED = "QUEUED", SEATED = "SEATED", WAITING_FOOD = "WAITING FOOD",
	SERVED = "EATING", PAYING = "PAYING", LEAVING = "LEAVING",
}

local STATE_COLOR = {
	[STATE.QUEUED] = Color3.fromRGB(245, 184, 65),      -- mustard: waiting at door
	[STATE.SEATED] = Color3.fromRGB(120, 170, 220),     -- blue: browsing
	[STATE.WAITING_FOOD] = Color3.fromRGB(229, 72, 77), -- tomato: kitchen owes them
	[STATE.SERVED] = Color3.fromRGB(76, 175, 109),      -- basil: happy eating
	[STATE.PAYING] = Color3.fromRGB(180, 140, 220),     -- purple: wallet out
	[STATE.LEAVING] = Color3.fromRGB(150, 150, 150),    -- gray: goodbye
}

local parties = {}          -- partyId -> party record
local nextPartyId = 0
local satisfiedCount = 0

-- table occupancy: TableId -> party or nil
local tableById = {}
local tableOccupant = {}
for _, t in ipairs(tableParts) do
	tableById[t:GetAttribute("TableId")] = t
end

-- queue occupancy: spot instance -> party or nil
local spotOccupant = {}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function pointAbove(part, height)
	return part.Position + Vector3.new(0, (part.Size.Y / 2) + height, 0)
end

local function walkTo(pawnPart, targetPos, onDone)
	-- Tween the pawn at WALK_SPEED; duration derives from real distance so the
	-- map's stud counts are literally what you see.
	local from = pawnPart.Position
	local flatTarget = Vector3.new(targetPos.X, from.Y, targetPos.Z)
	local distance = (flatTarget - from).Magnitude
	local tween = TweenService:Create(pawnPart,
		TweenInfo.new(math.max(distance / WALK_SPEED, 0.05), Enum.EasingStyle.Linear),
		{ Position = flatTarget })
	tween.Completed:Once(function()
		if onDone then onDone() end
	end)
	tween:Play()
end

local function setPartyState(party, newState)
	party.State = newState
	if party.Label then
		party.Label.Text = ("Party of %d - %s"):format(party.Size, newState)
	end
	if party.Pawn and STATE_COLOR[newState] then
		party.Pawn.Color = STATE_COLOR[newState]
	end
	print(("[Skeleton] Party %d -> %s"):format(party.Id, newState))
end

--// Party sizes this difficulty defines, ascending. Read from Config rather
--// than hardcoded, so raising the MVP cap of 2 is a Config-only edit.
local PARTY_SIZES = {}
for size in pairs(diff.PartySizeWeights) do
	table.insert(PARTY_SIZES, size)
end
table.sort(PARTY_SIZES)

local function rollPartySize()
	local weights = diff.PartySizeWeights
	local r = math.random()
	local acc = 0

	for _, size in ipairs(PARTY_SIZES) do
		acc += weights[size]
		if r <= acc then return size end
	end

	--// Only reachable if the weights sum below 1.0
	return PARTY_SIZES[#PARTY_SIZES]
end

--// Dishes live on the character while equipped and in the Backpack when not,
--// so both have to be searched or unequipping smuggles an extra dish out
local function eachCarriedTool(player, fn)
	local containers = { player.Character, player:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") then
					local result = fn(child)
					if result then return result end
				end
			end
		end
	end
	return nil
end

local function isCarryingAnyDish(player)
	return eachCarriedTool(player, function(tool)
		return tool:GetAttribute("TableId") ~= nil
	end) ~= nil
end

local function findHeldDish(player, tableId)
	return eachCarriedTool(player, function(tool)
		if tool:GetAttribute("TableId") == tableId then
			return tool
		end
		return nil
	end)
end

----------------------------------------------------------------
-- Pawn creation (the ONLY function that changes when real rigs arrive)
----------------------------------------------------------------
local function spawnPartyPawn(party, atPosition)
	local pawn = Instance.new("Part")
	pawn.Name = "PartyPawn_" .. party.Id
	pawn.Shape = Enum.PartType.Cylinder
	pawn.Size = Vector3.new(5, 2.5, 2.5)      -- cylinder axis is X; stand it up:
	pawn.CFrame = CFrame.new(atPosition) * CFrame.Angles(0, 0, math.rad(90))
	pawn.Anchored = true
	pawn.CanCollide = false
	pawn.Material = Enum.Material.SmoothPlastic
	pawn.Color = STATE_COLOR[STATE.QUEUED]

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(200, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	gui.Parent = pawn

	party.Pawn = pawn
	party.Label = label
	pawn.Parent = workspace
end

----------------------------------------------------------------
-- The Pass: dish pickup pedestals
----------------------------------------------------------------
local dishSlotOffset = 0
local function spawnDishAtPass(tableId)
	-- A gray block on the pass with a prompt; picking up gives a carry Tool.
	local slot = Instance.new("Part")
	slot.Name = ("DishSlot_T%d"):format(tableId)
	slot.Size = Vector3.new(2, 1, 2)
	slot.Color = Color3.fromRGB(200, 200, 200)
	slot.Material = Enum.Material.SmoothPlastic
	slot.Anchored = true
	slot.CanCollide = false
	dishSlotOffset = (dishSlotOffset % 5) + 1
	local along = passPart.CFrame.RightVector * ((dishSlotOffset - 3) * 4)
	slot.Position = pointAbove(passPart, 0.5) + along
	slot.Parent = workspace

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up"
	prompt.ObjectText = ("Dish for Table %d"):format(tableId)
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = slot

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		if not character then return end

		-- one dish at a time for the skeleton (two-item inventory = session 4)
		if isCarryingAnyDish(player) then
			return -- already carrying a dish; politely ignore
		end

		local tool = Instance.new("Tool")
		tool.Name = ("Dish (T%d)"):format(tableId)
		tool.RequiresHandle = true
		tool:SetAttribute("TableId", tableId)
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(2, 0.6, 2)
		handle.Color = Color3.fromRGB(200, 200, 200)
		handle.Material = Enum.Material.SmoothPlastic
		handle.Parent = tool
		tool.Parent = character            -- equips into their hands
		slot:Destroy()
		print(("[Skeleton] %s picked up dish for Table %d"):format(player.Name, tableId))
	end)
end

----------------------------------------------------------------
-- Tables: one prompt each, its job changes with the occupant's state
----------------------------------------------------------------
local tablePrompt = {}

local function refreshTablePrompt(tableId)
	local prompt = tablePrompt[tableId]
	local party = tableOccupant[tableId]
	if not party then
		prompt.Enabled = false
		return
	end
	if party.State == STATE.SEATED then
		prompt.Enabled = true
		prompt.ActionText = "Take order"
		prompt.ObjectText = ("Table %d"):format(tableId)
		prompt.HoldDuration = 1
	elseif party.State == STATE.WAITING_FOOD then
		prompt.Enabled = true
		prompt.ActionText = "Serve dish"
		prompt.ObjectText = ("Table %d - needs their dish"):format(tableId)
		prompt.HoldDuration = 0.5
	elseif party.State == STATE.PAYING then
		prompt.Enabled = true
		prompt.ActionText = "Collect payment"
		prompt.ObjectText = ("Table %d"):format(tableId)
		prompt.HoldDuration = 2
	else
		prompt.Enabled = false
	end
end

local function onPartyFinished(party, tableId)
	satisfiedCount += 1
	print(("[Skeleton] Party %d satisfied! Total this run: %d"):format(party.Id, satisfiedCount))
	setPartyState(party, STATE.LEAVING)
	tableOccupant[tableId] = nil
	refreshTablePrompt(tableId)
	-- amble out via queue spot 1's position, then vanish
	local exitPos = pointAbove(queueSpots[1], 2)
	walkTo(party.Pawn, exitPos, function()
		party.Pawn:Destroy()
		parties[party.Id] = nil
	end)
end

local function setupTable(tableId, tablePart)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Enabled = false
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = tablePart
	tablePrompt[tableId] = prompt

	prompt.Triggered:Connect(function(player)
		local party = tableOccupant[tableId]
		if not party then return end

		if party.State == STATE.SEATED then
			-- TAKE ORDER: dish appears at the pass instantly (cooking = session 4)
			setPartyState(party, STATE.WAITING_FOOD)
			refreshTablePrompt(tableId)
			spawnDishAtPass(tableId)
			print(("[Skeleton] Order for Table %d is at the pass"):format(tableId))

		elseif party.State == STATE.WAITING_FOOD then
			-- SERVE: must be holding THIS table's dish
			local dish = findHeldDish(player, tableId)
			if not dish then
				prompt.ObjectText = ("Table %d - bring their dish from the pass!"):format(tableId)
				return
			end
			dish:Destroy()
			setPartyState(party, STATE.SERVED)
			refreshTablePrompt(tableId)
			task.delay(diff.EatingSeconds, function()
				if party.State ~= STATE.SERVED then return end
				setPartyState(party, STATE.PAYING)
				refreshTablePrompt(tableId)
			end)

		elseif party.State == STATE.PAYING then
			-- COLLECT: coins to whoever collects (per-player split = later polish)
			local coins = player:FindFirstChild("leaderstats")
				and player.leaderstats:FindFirstChild("Coins")
			if coins then
				local payout = math.floor(BASE_COINS_PER_PARTY * party.Size * diff.Rewards.CoinMult)
				coins.Value += payout
				print(("[Skeleton] %s collected %d coins from Table %d"):format(player.Name, payout, tableId))
			end
			onPartyFinished(party, tableId)
		end
	end)
end

for tableId, tablePart in pairs(tableById) do
	setupTable(tableId, tablePart)
end

----------------------------------------------------------------
-- Seating: prompt on each queued pawn
----------------------------------------------------------------
local function findFreeTable()
	--// Sorted so tables fill 1, 2, 3, 4 rather than in hash order
	local ids = {}
	for tableId in pairs(tableById) do
		table.insert(ids, tableId)
	end
	table.sort(ids)

	for _, tableId in ipairs(ids) do
		if tableOccupant[tableId] == nil then
			return tableId
		end
	end
	return nil
end

local function attachSeatPrompt(party)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Seat party"
	prompt.ObjectText = ("Party of %d"):format(party.Size)
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = party.Pawn

	prompt.Triggered:Connect(function(player)
		if party.State ~= STATE.QUEUED then return end
		local tableId = findFreeTable()
		if not tableId then
			prompt.ObjectText = "No free tables!"
			task.delay(1.5, function()
				prompt.ObjectText = ("Party of %d"):format(party.Size)
			end)
			return
		end

		-- door bar would be DESTROYED here (session 3) - seating INITIATED
		prompt:Destroy()
		spotOccupant[party.Spot] = nil
		party.Spot = nil
		tableOccupant[tableId] = party
		party.TableId = tableId

		local tablePart = tableById[tableId]
		local seatPos = pointAbove(tablePart, 2) - tablePart.CFrame.LookVector * 4
		walkTo(party.Pawn, seatPos, function()
			-- seated bar would START here (session 3) - bodies in chairs
			setPartyState(party, STATE.SEATED)
			refreshTablePrompt(tableId)
		end)
		print(("[Skeleton] %s seated Party %d at Table %d"):format(player.Name, party.Id, tableId))
	end)
end

----------------------------------------------------------------
-- Spawning: parties appear at the lowest free queue spot
----------------------------------------------------------------
local function findFreeSpot()
	local queuedCount = 0
	for _, p in pairs(parties) do
		if p.State == STATE.QUEUED then queuedCount += 1 end
	end
	if queuedCount >= diff.DoorQueueMax then return nil end
	for _, spot in ipairs(queueSpots) do
		if spotOccupant[spot] == nil then
			return spot
		end
	end
	return nil
end

local function spawnParty()
	local spot = findFreeSpot()
	if not spot then return end -- queue full: in session 3 this is a walkout risk signal

	nextPartyId += 1
	local party = {
		Id = nextPartyId,
		Size = rollPartySize(),
		State = STATE.QUEUED,
		Spot = spot,
		TableId = nil,
	}
	parties[party.Id] = party
	spotOccupant[spot] = party
	spawnPartyPawn(party, pointAbove(spot, 2))
	setPartyState(party, STATE.QUEUED)
	attachSeatPrompt(party)
	-- door bar would START here (session 3) - the moment they exist
end

----------------------------------------------------------------
-- The spawner loop (endless for the skeleton; shift phases = session 5)
----------------------------------------------------------------
--// Config.SpawnIntervalFor applies difficulty AND player-count scaling;
--// dividing by SpawnRate alone would spawn a 6-player shift at solo pace.
local spawnInterval = DEBUG_SPAWN_INTERVAL
	or Config.SpawnIntervalFor("Building", DIFFICULTY, PLAYER_COUNT)

print(("[Skeleton] Spawning a party every %.0fs (building-phase rate, %d player(s)). Ready - go be a waiter!")
	:format(spawnInterval, PLAYER_COUNT))

task.spawn(function()
	task.wait(3)
	spawnParty() -- first customer arrives quickly so testing starts fast
	while true do
		task.wait(spawnInterval)
		spawnParty()
	end
end)
