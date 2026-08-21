--[[
	Dinner Rush - ServiceLoop (Session 3: the clocks)
	ServerScriptService.Server.ServiceLoop  (regular Script, server-side)

	REPLACES SkeletonLoop. Running both doubles every prompt.

	Adds to the Session-2 skeleton:
	  * Door patience bar    (spawn -> seating initiated; greeting extends once)
	  * Seated patience bar  (chairs -> LAST dish served; one continuous bar)
	  * Multi-dish orders    (party of N = N dishes; +grace per dish landed)
	  * VIP customers        (gold, impatient, double tips, bigger rep)
	  * Walkouts + live REPUTATION (scoreboard above the pass; 0 = early loss)
	  * Full shift clock     (prep countdown -> Calm/Building/Crescendo -> report)
	  * Phase spawn scheduler via Config.PhaseAt / Config.SpawnIntervalFor
	  * Difficulty bridge    reads workspace attribute "MatchDifficulty"
	                         (set by MatchServer; falls back to NORMAL in Studio)
	  * Water pours          ONLY if a part is tagged "WaterStation" (optional)

	REQUIRED TAGS: QueueSpot (Order), Table (TableId), Pass
	OPTIONAL TAGS: WaterStation (enables the pitcher + pour system)

	Tag lookups are scoped to Workspace and validated as BaseParts, and the
	script waits for a usable grey-box rather than erroring, so a map cloned in
	late or a stray tag on a Decal reports itself instead of crashing.
]]

----------------------------------------------------------------
-- Services & Config
----------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// RIGS --------------------------------------------------------------------
--// ServerStorage.CustomerRig is cloned per customer. Without it, customers
--// fall back to the placeholder cylinder so the loop still runs.
local RIG_NAME = "CustomerRig"

--// Paste a looping walk animation id here to animate the legs. Left empty the
--// rigs glide, which is fine for testing.
local WALK_ANIMATION_ID = ""

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Service] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

-- DEBUG knobs (set to nil to use real Config values)
local DEBUG_PREP_SECONDS = 8        -- real: Config.Shift.PrepTimeSeconds (45)
local DEBUG_SHIFT_SECONDS = nil     -- e.g. 180 for a 3-minute test shift
local VIP_TIP_MULT = 2.0
local BASE_COINS_PER_PARTY = 15
local WALK_SPEED = 12               -- NPC amble (untimed by design)

--// PRESENTATION -----------------------------------------------------------
--// The server owns the numbers and publishes them as attributes; drawing them
--// is a separate concern. Neither flag below affects the simulation - only the
--// blocks marked "PLACEHOLDER VISUAL".

--// The billboard scoreboard above the pass. Off now that ShiftHud_UI exists.
local SHOW_PLACEHOLDER_SCOREBOARD = false

--// The bars and name labels floating over each customer. Still on until you
--// build your own - they read PatienceFraction off the tagged pawns.
local SHOW_PLACEHOLDER_BARS = true

--// How often published attributes refresh, in seconds. Every attribute write
--// replicates, so this is deliberately not per-frame; a client HUD can
--// interpolate between ticks for a smooth bar.
local PUBLISH_INTERVAL = 0.1

----------------------------------------------------------------
-- Difficulty bridge: MatchServer's attribute, else NORMAL (Studio)
----------------------------------------------------------------
local function resolveDifficulty()
	local attr = workspace:GetAttribute("MatchDifficulty")
	if Config.IsValidDifficulty(attr) then
		return attr
	end
	if attr ~= nil then
		warn(("[Service] MatchDifficulty %q is not valid - using NORMAL"):format(tostring(attr)))
	end
	return "NORMAL"
end

----------------------------------------------------------------
-- Grey-box discovery
--
-- GetTagged searches the whole DataModel, so a map template in ServerStorage
-- would be found alongside the Workspace copy - duplicate TableIds, half the
-- tables unreachable. Scope every lookup to Workspace.
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

--// Everything here is read for Position/Size/CFrame and is the parent of a
--// ProximityPrompt, neither of which works on a Decal, Model or Attachment.
local function checkIsPart(instance, tag, problems)
	if instance:IsA("BasePart") then
		return true
	end

	table.insert(problems, ("%s is tagged %s but is a %s, not a part - tag the part itself, not its children"):format(
		instance:GetFullName(), tag, instance.ClassName))
	return false
end

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

			if #passParts > 1 then
				warn(("[Service] %d parts tagged 'Pass' - using %s (remove the extra tags)")
					:format(#passParts, passParts[1]:GetFullName()))
			end

			local water = taggedInWorkspace("WaterStation")[1]
			if not water then
				warn("[Service] No part tagged 'WaterStation' - water pours DISABLED (tag one to enable)")
			end

			print(("[Service] Grey-box OK: %d queue spots, %d tables, pass found, water %s")
				:format(#queueSpots, #tables, water and "ON" or "off"))

			return queueSpots, tables, passParts[1], water
		end

		if ticks % 50 == 0 then --// roughly every 5s
			warn("[Service] Waiting on the grey-box:")
			for _, problem in ipairs(problems) do
				warn("  - " .. problem)
			end
		end

		ticks += 1
		task.wait(0.1)
	end
end

local queueSpots, tableParts, passPart, waterPart = waitForGreybox()

----------------------------------------------------------------
-- WAYPOINTS - how customers route around this map's walls
--
-- Movement is tweened, not physics-driven, so a straight line would cut
-- through walls. Waypoints bend the path. Which ones a customer uses is
-- map data, not code, so a new map only needs new parts and attributes:
--
--   Tag a part "Waypoint" with an "Order" attribute (1, 2, 3...).
--
--   On each Table part, two OPTIONAL string attributes list the waypoint
--   Orders to walk through, comma separated:
--     EntryVia  e.g. "1"    or "1,2"   queue -> table
--     ExitVia   e.g. "2,1"             table -> door
--
--   Missing or empty = walk straight there.
--
-- For this map: every table gets EntryVia "1" (Waypoint 1 sits on QueueSpot 1,
-- so it is a no-op hop from there and a real one from spots 2-5), Table 4 gets
-- "1,2", and every table gets ExitVia "2,1".
----------------------------------------------------------------
local waypointByOrder = {}
do
	local found = taggedInWorkspace("Waypoint")
	for _, wp in ipairs(found) do
		if not wp:IsA("BasePart") then
			warn(("[Service] %s is tagged Waypoint but is a %s, not a part - ignored")
				:format(wp:GetFullName(), wp.ClassName))
			continue
		end
		--// tonumber so an Order created as a string ("1") still keys the same
		--// as a lookup for the number 1 - otherwise every route silently misses
		local raw = wp:GetAttribute("Order")
		local order = tonumber(raw)
		if order == nil then
			warn(("[Service] %s is tagged Waypoint but its 'Order' is %s - needs a number")
				:format(wp:GetFullName(), raw == nil and "missing" or ("'" .. tostring(raw) .. "'")))
			continue
		end
		if waypointByOrder[order] then
			warn(("[Service] Waypoint Order %s is used twice (%s and %s) - keeping the first")
				:format(tostring(order), waypointByOrder[order]:GetFullName(), wp:GetFullName()))
			continue
		end
		waypointByOrder[order] = wp
	end

	local count = 0
	for _ in pairs(waypointByOrder) do count += 1 end
	print(("[Service] %d waypoint(s) found"):format(count))

end

--// "1,2" -> { waypointPart1, waypointPart2 }. Unknown orders warn once and
--// are skipped rather than stranding the customer.
local viaCache = {}
local function parseVia(spec)
	--// Accept a number too: an EntryVia created as a number attribute rather
	--// than a string would otherwise be dropped here without a word
	if type(spec) == "number" then
		spec = tostring(spec)
	end
	if type(spec) ~= "string" or spec == "" then
		return {}
	end
	if viaCache[spec] then
		return viaCache[spec]
	end

	local route = {}
	for token in string.gmatch(spec, "[^,%s]+") do
		local order = tonumber(token)
		local wp = order and waypointByOrder[order]
		if wp then
			table.insert(route, wp)
		else
			warn(("[Service] route '%s' refers to waypoint %s, which does not exist"):format(spec, token))
		end
	end

	viaCache[spec] = route
	return route
end

--// Resolve every table's routes at boot. Printing the raw attribute is not
--// enough - "1" looks identical whether or not it actually finds a waypoint,
--// which is exactly how a silent mismatch survives to runtime.
do
	local resolved = 0
	for _, t in ipairs(tableParts) do
		local entry = t:GetAttribute("EntryVia")
		local exit = t:GetAttribute("ExitVia")
		local entryCount = #parseVia(entry)
		local exitCount = #parseVia(exit)
		resolved += entryCount + exitCount

		print(("[Service]   Table %s: entry [%s] -> %d waypoint(s), exit [%s] -> %d waypoint(s)"):format(
			tostring(t:GetAttribute("TableId")),
			tostring(entry or ""), entryCount,
			tostring(exit or ""), exitCount))
	end

	if resolved == 0 then
		warn("[Service] No table route resolves to a waypoint - customers will walk straight through walls")
	end
end

----------------------------------------------------------------
-- Leaderstats
----------------------------------------------------------------
local function ensureStats(player)
	if player:FindFirstChild("leaderstats") then return end
	local stats = Instance.new("Folder"); stats.Name = "leaderstats"
	local coins = Instance.new("IntValue"); coins.Name = "Coins"; coins.Parent = stats
	stats.Parent = player
end
Players.PlayerAdded:Connect(ensureStats)
for _, p in ipairs(Players:GetPlayers()) do ensureStats(p) end

--// A player's own balance. Only ever touched by the end-of-shift split -
--// during service, money belongs to the restaurant, not to whoever happened
--// to walk to the table.
local function awardCoins(player, amount)
	local coins = player:FindFirstChild("leaderstats")
		and player.leaderstats:FindFirstChild("Coins")
	if coins then coins.Value += amount end
end

----------------------------------------------------------------
-- Shift + reputation state
----------------------------------------------------------------
local DIFFICULTY = "NORMAL"     -- resolved at shift start
local diff = Config.ForDifficulty(DIFFICULTY)

local shift = {
	State = "WAITING",          -- WAITING -> PREP -> RUNNING -> ENDED
	Elapsed = 0,
	Length = DEBUG_SHIFT_SECONDS or Config.Shift.LengthSeconds,
	Phase = "Calm",
	Reputation = Config.Reputation.Start,
	Satisfied = 0,
	Till = Config.Money.ShiftStartingTill, -- shared, resets every shift
	DoorWalkouts = 0,
	SeatedWalkouts = 0,
}

----------------------------------------------------------------
-- PUBLISHED STATE - the contract your ScreenGui reads
--
-- ReplicatedStorage.ShiftState carries the whole HUD:
--   State ("WAITING"/"PREP"/"RUNNING"/"ENDED"), PrepRemaining, TimeRemaining,
--   Length, Phase, Reputation, ReputationMax, Satisfied, TargetParties,
--   Difficulty, DifficultyLabel, DoorWalkouts, SeatedWalkouts, EndText
--
-- Each customer pawn is tagged "CustomerParty" and carries:
--   PartySize, IsVIP, PartyState, BarKind ("door"/"seated"/""),
--   PatienceRemaining, PatienceTotal, PatienceFraction (0-1)
--
-- Attributes replicate on their own, so a LocalScript needs no remotes:
--   local state = ReplicatedStorage:WaitForChild("ShiftState")
--   state:GetAttributeChangedSignal("Reputation"):Connect(...)
----------------------------------------------------------------
local ShiftState = Instance.new("Folder")
ShiftState.Name = "ShiftState"
ShiftState.Parent = ReplicatedStorage

local function publishShift()
	ShiftState:SetAttribute("State", shift.State)
	ShiftState:SetAttribute("PrepRemaining", math.max(0, shift.PrepRemaining or 0))
	ShiftState:SetAttribute("TimeRemaining", math.max(0, shift.Length - shift.Elapsed))
	ShiftState:SetAttribute("Length", shift.Length)
	ShiftState:SetAttribute("Phase", shift.Phase)
	ShiftState:SetAttribute("Reputation", shift.Reputation)
	ShiftState:SetAttribute("ReputationMax", Config.Reputation.Max)
	ShiftState:SetAttribute("Satisfied", shift.Satisfied)
	ShiftState:SetAttribute("Till", shift.Till)
	ShiftState:SetAttribute("TargetParties", diff.Rewards.TargetParties)
	ShiftState:SetAttribute("Difficulty", DIFFICULTY)
	ShiftState:SetAttribute("DifficultyLabel", diff.Label)
	ShiftState:SetAttribute("DoorWalkouts", shift.DoorWalkouts)
	ShiftState:SetAttribute("SeatedWalkouts", shift.SeatedWalkouts)
	ShiftState:SetAttribute("EndText", shift.EndText or "")
end

local function publishParty(party)
	local pawn = party.Pawn
	if not pawn or not pawn.Parent then return end

	pawn:SetAttribute("PartySize", party.Size)
	pawn:SetAttribute("IsVIP", party.IsVIP == true)
	pawn:SetAttribute("PartyState", party.State or "")
	pawn:SetAttribute("BarKind", party.BarKind or "")
	pawn:SetAttribute("PatienceRemaining", party.BarRemaining or 0)
	pawn:SetAttribute("PatienceTotal", party.BarTotal or 0)

	local fraction = 0
	if party.BarRemaining and party.BarTotal and party.BarTotal > 0 then
		fraction = math.clamp(party.BarRemaining / party.BarTotal, 0, 1)
	end
	pawn:SetAttribute("PatienceFraction", fraction)
end

--// Service is "open" for the whole time customers are still being dealt
--// with: RUNNING while the clock ticks, then CLOSING until the room empties.
--// Anything a player does to a customer must work in both.
local function serviceOpen()
	return shift.State == "RUNNING" or shift.State == "CLOSING"
end

local function repChange(amount, why)
	if not serviceOpen() then return end
	shift.Reputation = math.clamp(shift.Reputation + amount, 0, Config.Reputation.Max)
	print(("[Service] Rep %+d (%s) -> %d"):format(amount, why, shift.Reputation))
end

----------------------------------------------------------------
-- THE TILL: one shared pot per shift.
--
-- Customer payments go in, the Supplier spends out, and the balance is split
-- evenly between everyone at the buzzer. Nobody has a private balance during
-- service, so nobody is incentivised to hog the tables.
----------------------------------------------------------------
local function addToTill(amount, why)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return end

	shift.Till += amount
	print(("[Service] Till +%d (%s) -> %d"):format(amount, why or "income", shift.Till))
end

--// Returns false and spends nothing when the till cannot cover it
local function spendFromTill(amount, why)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return true end

	if shift.Till < amount then
		return false
	end

	shift.Till -= amount
	print(("[Service] Till -%d (%s) -> %d"):format(amount, why or "spend", shift.Till))
	return true
end

do
	local spend = Instance.new("BindableFunction")
	spend.Name = "SpendFromTill"
	spend.OnInvoke = function(amount, why)
		return spendFromTill(amount, why)
	end
	spend.Parent = game:GetService("ServerStorage")

	local balance = Instance.new("BindableFunction")
	balance.Name = "GetTill"
	balance.OnInvoke = function()
		return shift.Till
	end
	balance.Parent = game:GetService("ServerStorage")
end

--// REPUTATION BRIDGE for other server systems (EventSystem, and anything
--// later). There is exactly one reputation number and it lives here; nothing
--// else keeps its own. Same BindableFunction pattern as
--// ServerStorage.RestockIngredient.
--//   ServerStorage.ApplyReputation:Invoke(-3, "toilet flood")
do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "ApplyReputation"
	bridge.OnInvoke = function(amount, why)
		amount = tonumber(amount)
		if not amount or amount == 0 then
			return false
		end
		repChange(amount, tostring(why or "event"))
		return true
	end
	bridge.Parent = game:GetService("ServerStorage")
end

--// Lets other systems check whether the shift is live without duplicating
--// the state machine
do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "GetShiftInfo"
	bridge.OnInvoke = function()
		return {
			State = shift.State,
			Elapsed = shift.Elapsed,
			Phase = shift.Phase,
			Difficulty = DIFFICULTY,
		}
	end
	bridge.Parent = game:GetService("ServerStorage")
end

----------------------------------------------------------------
-- PLACEHOLDER VISUAL 1/2: scoreboard billboard above the pass.
-- Replaced by your ScreenGui reading ReplicatedStorage.ShiftState.
-- Delete this whole block plus refreshScoreboard's body when it exists.
----------------------------------------------------------------
local scoreboard
if SHOW_PLACEHOLDER_SCOREBOARD then
	local gui = Instance.new("BillboardGui")
	gui.Name = "Scoreboard"
	gui.Size = UDim2.fromOffset(420, 70)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 400
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.fromRGB(59, 43, 32)
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = gui
	gui.Parent = passPart
	scoreboard = label
end

local function fmtClock(seconds)
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

local function refreshScoreboard()
	if not scoreboard then return end

	if shift.State == "WAITING" then
		scoreboard.Text = "Waiting for players..."
	elseif shift.State == "PREP" then
		scoreboard.Text = ("Shift starts in %d...  (%s)"):format(math.ceil(shift.PrepRemaining or 0), diff.Label)
	elseif shift.State == "CLOSING" then
		scoreboard.Text = ("REP %d   |   LAST TABLES   |   Served %d/%d")
			:format(shift.Reputation, shift.Satisfied, diff.Rewards.TargetParties)
	elseif shift.State == "RUNNING" then
		scoreboard.Text = ("REP %d   |   %s   |   %s   |   Served %d/%d")
			:format(shift.Reputation, fmtClock(shift.Length - shift.Elapsed), shift.Phase,
				shift.Satisfied, diff.Rewards.TargetParties)
	else
		scoreboard.Text = shift.EndText or "Shift over"
	end
end

----------------------------------------------------------------
-- Party state machine
----------------------------------------------------------------
local STATE = {
	QUEUED = "QUEUED", SEATED = "SEATED", WAITING_FOOD = "WAITING FOOD",
	SERVED = "EATING", PAYING = "PAYING", LEAVING = "LEAVING", WALKOUT = "STORMED OUT",
}
local STATE_COLOR = {
	[STATE.QUEUED] = Color3.fromRGB(245, 184, 65),
	[STATE.SEATED] = Color3.fromRGB(120, 170, 220),
	[STATE.WAITING_FOOD] = Color3.fromRGB(229, 72, 77),
	[STATE.SERVED] = Color3.fromRGB(76, 175, 109),
	[STATE.PAYING] = Color3.fromRGB(180, 140, 220),
	[STATE.LEAVING] = Color3.fromRGB(150, 150, 150),
	[STATE.WALKOUT] = Color3.fromRGB(80, 80, 80),
}
local VIP_GOLD = Color3.fromRGB(255, 200, 60)

local parties = {}
local nextPartyId = 0
local tableById, tableOccupant, spotOccupant = {}, {}, {}
for _, t in ipairs(tableParts) do
	tableById[t:GetAttribute("TableId")] = t
end

local function pointAbove(part, height)
	return part.Position + Vector3.new(0, (part.Size.Y / 2) + height, 0)
end

--// Moves the anchored root; on a rig the limbs follow through their Motor6Ds,
--// so animations keep playing. Height is held from the current position - the
--// spawn placed them on the floor and every destination is on the same floor.
local function walkTo(party, targetPos, onDone)
	local root = party.Root
	if not root or not root.Parent then
		if onDone then onDone() end
		return
	end

	local from = root.Position
	local flat = Vector3.new(targetPos.X, from.Y, targetPos.Z)
	local distance = (flat - from).Magnitude

	--// Face the direction of travel, unless we are already there
	local goal
	if distance > 0.1 then
		goal = CFrame.lookAt(flat, flat + (flat - from).Unit)
	else
		goal = CFrame.new(flat) * (root.CFrame - root.CFrame.Position)
	end

	local tween = TweenService:Create(root,
		TweenInfo.new(math.max(distance / WALK_SPEED, 0.05), Enum.EasingStyle.Linear),
		{ CFrame = goal })

	if party.WalkTrack then
		party.WalkTrack:Play()
	end

	tween.Completed:Once(function()
		if party.WalkTrack then
			party.WalkTrack:Stop()
		end
		if onDone then onDone() end
	end)
	tween:Play()
end

--// Walks a chain of points in order, then calls onDone. Used for waypoint
--// routes; an empty route is just a single walk to the destination.
local function walkPath(party, points, onDone)
	local index = 0

	local function step()
		index += 1
		if index > #points then
			if onDone then onDone() end
			return
		end
		walkTo(party, points[index], step)
	end

	step()
end

--// The floor-level point a customer should stand at for a given part
local function standingPoint(part)
	return Vector3.new(part.Position.X, part.Position.Y, part.Position.Z)
end

--// Waypoint parts -> the positions to walk through
local function routePoints(route)
	local points = {}
	for _, wp in ipairs(route) do
		table.insert(points, standingPoint(wp))
	end
	return points
end

local function setPartyState(party, newState)
	party.State = newState
	if party.Label then
		local vip = party.IsVIP and "* " or ""
		party.Label.Text = ("%sParty of %d - %s"):format(vip, party.Size, newState)
	end
	--// State colour: a Highlight on rigs, the part's own colour on the
	--// placeholder cylinder. VIPs stay gold until they leave.
	local color = STATE_COLOR[newState]
	if party.IsVIP and newState ~= STATE.WALKOUT and newState ~= STATE.LEAVING then
		color = VIP_GOLD
	end

	if color then
		if party.Highlight then
			party.Highlight.FillColor = color
			party.Highlight.OutlineColor = color
		elseif party.Pawn and party.Pawn:IsA("BasePart") then
			party.Pawn.Color = color
		end
	end
	publishParty(party)
	print(("[Service] Party %d -> %s"):format(party.Id, newState))
end

--// Party sizes this difficulty defines, ascending. Read from Config rather
--// than hardcoded, so changing the cap is a Config-only edit.
local PARTY_SIZES = {}
for size in pairs(diff.PartySizeWeights) do
	table.insert(PARTY_SIZES, size)
end
table.sort(PARTY_SIZES)

local function rollPartySize()
	local weights = diff.PartySizeWeights
	local r, acc = math.random(), 0

	for _, size in ipairs(PARTY_SIZES) do
		acc += weights[size]
		if r <= acc then return size end
	end

	--// Only reachable if the weights sum below 1.0
	return PARTY_SIZES[#PARTY_SIZES]
end

----------------------------------------------------------------
-- Carried tools: equipped tools live on the character, unequipped ones in
-- the Backpack. Searching only the character loses a dish on unequip.
----------------------------------------------------------------
local function findCarried(player, predicate)
	local containers = { player.Character, player:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and predicate(child) then
					return child
				end
			end
		end
	end
	return nil
end

--// Dishes are cooked by KitchenService now, so they carry a Dish name rather
--// than a TableId - a grilled steak is a grilled steak, not "table 3's". The
--// match is therefore ticket-based: does this party still want what you are
--// holding? Returns the tool and the dish name.
local function findTicketDish(player, party)
	if not party.Ticket then return nil end

	for _, wanted in ipairs(party.Ticket) do
		local tool = findCarried(player, function(candidate)
			return candidate:GetAttribute("Dish") == wanted
		end)
		if tool then
			return tool, wanted
		end
	end

	return nil
end

--// Ticket sign over the party, so players can see what to cook without
--// walking to the table. Icons come from Config.Recipes[*].Icon; until those
--// asset ids are filled in it falls back to the dish name as text.
local function showTicket(party)
	if not party.Root or not party.Ticket then return end

	local gui = party.TicketGui
	if not gui then
		gui = Instance.new("BillboardGui")
		gui.Name = "Ticket"
		gui.Size = UDim2.fromOffset(200, 44)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		gui.AlwaysOnTop = true
		gui.Parent = party.Root
		party.TicketGui = gui

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 4)
		layout.Parent = gui
	end

	for _, child in ipairs(gui:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	if #party.Ticket == 0 then
		gui.Enabled = false
		return
	end
	gui.Enabled = true

	for index, dishName in ipairs(party.Ticket) do
		local recipe = Config.Recipes[dishName]
		local icon = recipe and recipe.Icon

		if icon and icon ~= "" and icon ~= "rbxassetid://0" then
			local image = Instance.new("ImageLabel")
			image.Size = UDim2.fromOffset(40, 40)
			image.BackgroundTransparency = 1
			image.Image = icon
			image.LayoutOrder = index
			image.Parent = gui
		else
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromOffset(96, 40)
			label.BackgroundTransparency = 1
			label.TextScaled = true
			label.Font = Enum.Font.FredokaOne
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextStrokeTransparency = 0.2
			label.Text = recipe and recipe.Display or dishName
			label.LayoutOrder = index
			label.Parent = gui
		end
	end
end

--// What this party is still waiting on, for prompts and the ticket sign
local function ticketText(party)
	if not party.Ticket or #party.Ticket == 0 then
		return ""
	end

	local names = {}
	for _, dishName in ipairs(party.Ticket) do
		local recipe = Config.Recipes[dishName]
		table.insert(names, recipe and recipe.Display or dishName)
	end
	return table.concat(names, " + ")
end

local function findHeldPitcher(player)
	return findCarried(player, function(tool)
		return tool:GetAttribute("PitcherUses") ~= nil
	end)
end

----------------------------------------------------------------
-- Patience bars. The TIMER is server state (party.BarRemaining/BarTotal,
-- published as PatienceFraction on the pawn). Only the drawing below is
-- placeholder - the bar keeps running with SHOW_PLACEHOLDER_BARS off.
--
-- PLACEHOLDER VISUAL 2/2: billboard bar over each pawn.
----------------------------------------------------------------
local function attachBar(party)
	if not SHOW_PLACEHOLDER_BARS then return end

	local gui = Instance.new("BillboardGui")
	gui.Name = "PatienceBar"
	gui.Size = UDim2.fromOffset(160, 14)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5.2, 0)
	gui.AlwaysOnTop = true
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	back.BorderSizePixel = 0
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(76, 175, 109)
	fill.BorderSizePixel = 0
	fill.Parent = back
	back.Parent = gui
	--// BillboardGui needs a BasePart parent; on a rig that is the root
	gui.Parent = party.Root
	party.BarGui, party.BarFill = gui, fill
end

local function updateBarVisual(party, fraction)
	if not party.BarFill then return end
	fraction = math.clamp(fraction, 0, 1)
	party.BarFill.Size = UDim2.fromScale(fraction, 1)
	local color
	if fraction > 0.5 then
		color = Color3.fromRGB(76, 175, 109)
	elseif fraction > 0.25 then
		color = Color3.fromRGB(245, 184, 65)
	else
		color = Color3.fromRGB(229, 72, 77)
	end
	party.BarFill.BackgroundColor3 = color
end

local function removeBar(party)
	if party.BarGui then party.BarGui:Destroy() end
	party.BarGui, party.BarFill = nil, nil
	party.BarRemaining, party.BarTotal, party.BarKind = nil, nil, nil
	publishParty(party)
end

local function startDoorBar(party)
	local base = party.IsVIP and Config.Customers.VIPDoorPatienceSeconds
		or Config.Customers.DoorPatienceSeconds
	party.BarTotal = base * diff.Patience
	party.BarRemaining = party.BarTotal
	party.BarKind = "door"
	attachBar(party)
	publishParty(party)
end

local function startSeatedBar(party)
	local base = party.IsVIP and Config.Customers.VIPSeatedPatienceSeconds
		or Config.Customers.SeatedPatienceSeconds
	party.BarTotal = base * diff.Patience
	party.BarRemaining = party.BarTotal
	party.BarKind = "seated"
	attachBar(party)
	publishParty(party)
end

local function extendBar(party, seconds, why)
	if not party.BarRemaining then return end
	party.BarRemaining += seconds
	party.BarTotal = math.max(party.BarTotal, party.BarRemaining)
	print(("[Service] Party %d bar +%ds (%s)"):format(party.Id, seconds, why))
end

----------------------------------------------------------------
-- Walkouts & departures
----------------------------------------------------------------
local refreshTablePrompt -- forward declared
local cancelDialogue -- forward declared (order-dialogue section, below the table code)

--// Customers still in the queue are already outside, so they leave directly.
--// Seated ones walk their table's ExitVia route back out through the door.
local function departTo(party, target)
	local points = {}

	if not party.Spot and party.ExitFrom then
		points = routePoints(parseVia(party.ExitFrom:GetAttribute("ExitVia")))
	end

	print(("[Service] Party %d leaving %s via %d waypoint(s)"):format(
		party.Id,
		party.ExitFrom and ("Table " .. tostring(party.ExitFrom:GetAttribute("TableId")))
			or "the queue (no route)",
		#points))

	table.insert(points, target)

	walkPath(party, points, function()
		if party.WalkTrack then
			party.WalkTrack:Stop()
		end
		party.Pawn:Destroy()
		parties[party.Id] = nil
	end)
end

local exitPos = pointAbove(queueSpots[#queueSpots], 2)

local function doorWalkout(party)
	shift.DoorWalkouts += 1
	repChange(diff.Consequences.DoorWalkoutRep, "door walkout")
	removeBar(party)
	if party.Spot then spotOccupant[party.Spot] = nil; party.Spot = nil end
	if party.SeatPrompt then party.SeatPrompt:Destroy(); party.SeatPrompt = nil end
	setPartyState(party, STATE.WALKOUT)
	departTo(party, exitPos)
end

local function seatedWalkout(party)
	cancelDialogue(party) --// a mid-dialogue walkout closes the waiter's panel
	shift.SeatedWalkouts += 1
	repChange(diff.Consequences.SeatedWalkoutRep, "seated walkout")
	removeBar(party)
	local tid = party.TableId
	if tid then
		tableOccupant[tid] = nil
		party.TableId = nil
		refreshTablePrompt(tid)
	end
	setPartyState(party, STATE.WALKOUT)
	departTo(party, exitPos)
end

----------------------------------------------------------------
-- Pawns
----------------------------------------------------------------
local rigTemplate = ServerStorage:FindFirstChild(RIG_NAME)
if not rigTemplate then
	warn(("[Service] ServerStorage.%s not found - customers will be placeholder cylinders")
		:format(RIG_NAME))
end

--// Rigs are moved by tween, never by physics, so nothing collides: they
--// cannot snag on a wall, shove a player, or push each other. The root is
--// anchored and the limbs hang off it through their Motor6Ds, which is what
--// lets animations still play while the root is driven by a tween.
local function buildRig(party, atPosition)
	local rig = rigTemplate:Clone()
	rig.Name = "Customer_" .. party.Id

	local root = rig:FindFirstChild("HumanoidRootPart")
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		warn(("[Service] %s has no HumanoidRootPart or Humanoid - falling back to a cylinder")
			:format(RIG_NAME))
		rig:Destroy()
		return nil
	end

	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Anchored = false
		end
	end
	root.Anchored = true

	--// Feet on the floor: root sits hip height plus half its own depth above it
	local lift = humanoid.HipHeight + (root.Size.Y / 2)
	root.CFrame = CFrame.new(atPosition + Vector3.new(0, lift, 0))

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	if WALK_ANIMATION_ID ~= "" then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			local anim = Instance.new("Animation")
			anim.AnimationId = WALK_ANIMATION_ID
			local ok, track = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			if ok and track then
				track.Looped = true
				party.WalkTrack = track
			else
				warn("[Service] could not load WALK_ANIMATION_ID - rigs will glide")
			end
		else
			warn(("[Service] %s's Humanoid has no Animator - rigs will glide"):format(RIG_NAME))
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "StateHighlight"
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0
	highlight.Parent = rig
	party.Highlight = highlight

	party.Root = root
	return rig
end

local function spawnPartyPawn(party, atPosition)
	local pawn = rigTemplate and buildRig(party, atPosition)

	if not pawn then
		--// Placeholder cylinder: no rig template, or it was malformed
		pawn = Instance.new("Part")
		pawn.Name = "PartyPawn_" .. party.Id
		pawn.Shape = Enum.PartType.Cylinder
		pawn.Size = Vector3.new(5, 2.5, 2.5)
		--// atPosition is floor level; lift the cylinder onto its own base
		pawn.CFrame = CFrame.new(atPosition + Vector3.new(0, 1.25, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		pawn.Anchored = true
		pawn.CanCollide = false
		pawn.Material = Enum.Material.SmoothPlastic
		party.Root = pawn
	end

	--// How a client finds customers: CollectionService:GetTagged("CustomerParty")
	CollectionService:AddTag(pawn, "CustomerParty")

	party.Pawn = pawn
	publishParty(party)

	if not SHOW_PLACEHOLDER_BARS then
		pawn.Parent = workspace
		return
	end

	--// PLACEHOLDER VISUAL: name/state label over the pawn
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 36)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	gui.Parent = party.Root --// must be a BasePart, not the rig Model

	party.Label = label
	pawn.Parent = workspace
end

----------------------------------------------------------------
-- Water: pitcher tool + pour prompt (only if WaterStation tagged)
----------------------------------------------------------------
local pourPrompts = {}
if waterPart then
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Fill pitcher"
	prompt.ObjectText = "Water station"
	prompt.HoldDuration = Config.Customers.WaterStationHoldSeconds
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = waterPart

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		if not character then return end

		-- refill an existing pitcher, or hand out a new one
		local existing = findHeldPitcher(player)
		if existing then
			existing:SetAttribute("PitcherUses", diff.PitcherCapacity)
			existing.Name = ("Water Pitcher (%d)"):format(diff.PitcherCapacity)
			return
		end

		local tool = Instance.new("Tool")
		tool.Name = ("Water Pitcher (%d)"):format(diff.PitcherCapacity)
		tool.RequiresHandle = true
		tool:SetAttribute("PitcherUses", diff.PitcherCapacity)
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 2, 1)
		handle.Color = Color3.fromRGB(120, 170, 220)
		handle.Parent = tool
		tool.Parent = character
	end)
end

----------------------------------------------------------------
-- Tables: main prompt (order/serve/collect) + optional pour prompt
----------------------------------------------------------------
local tablePrompt = {}

refreshTablePrompt = function(tableId)
	local prompt = tablePrompt[tableId]
	local party = tableOccupant[tableId]
	local pour = pourPrompts[tableId]
	if pour then
		pour.Enabled = (party ~= nil) and party.BarKind == "seated"
			and (party.State == STATE.SEATED or party.State == STATE.WAITING_FOOD)
	end
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
		prompt.ObjectText = ("Table %d - %d dish%s left"):format(
			tableId, party.DishesRemaining, party.DishesRemaining == 1 and "" or "es")
		prompt.HoldDuration = 0.5
	else
		prompt.Enabled = false
	end
end

----------------------------------------------------------------
-- Payments. Finishing a meal no longer pays instantly: the money waits
-- ON the table as a collect point and melts while nobody grabs it.
-- Full value through GraceSeconds, then a linear decay over DecaySeconds:
-- BASE (what a plain no-perfect, no-VIP order pays) floors at
-- BaseFloorPercent; TIP (perfect-cook surplus + VIP surplus) melts to
-- zero. After the melt finishes it lingers LingerSeconds, then the
-- remainder is lost - no rep penalty, the lost coins ARE the penalty.
-- The party leaves on its normal schedule; turnover never waits on money.
----------------------------------------------------------------
local payments = {} --// tableId -> { Base, Tip, CreatedAt, Gui, Prompt, Amount }

--// Current value plus where in the melt we are (0 = grace, 1 = floored)
local function paymentValue(payment)
	local P = Config.Payment
	local elapsed = os.clock() - payment.CreatedAt
	local t = math.clamp((elapsed - P.GraceSeconds) / P.DecaySeconds, 0, 1)
	local baseVal = payment.Base * (1 - t * (1 - P.BaseFloorPercent))
	local tipVal = payment.Tip * (1 - t * (1 - P.TipFloorPercent))
	return math.floor(baseVal + tipVal), t
end

local function destroyPayment(tableId)
	local payment = payments[tableId]
	if not payment then return end
	payments[tableId] = nil
	if payment.Gui then payment.Gui:Destroy() end
	if payment.Prompt then payment.Prompt:Destroy() end
end

local function collectPayment(tableId, collector)
	local payment = payments[tableId]
	if not payment then return end
	local value = paymentValue(payment)
	destroyPayment(tableId)
	addToTill(value, ("payment from table %d"):format(tableId))
	print(("[Service] %s banked %d coins (Table %d)"):format(
		collector.Name, value, tableId))
end

local PAY_COLOR = {
	GRACE = Color3.fromRGB(76, 175, 109),   -- basil: full value
	DECAY = Color3.fromRGB(245, 184, 65),   -- mustard: melting
	FLOOR = Color3.fromRGB(229, 72, 77),    -- tomato: floored, about to vanish
}

local function createPayment(party, tableId)
	--// Exactly the money the old instant flow would have paid - same
	--// math, just deferred to the collect point.
	local perfect = party.PerfectDishes or 0
	local overcooked = party.OvercookedDishes or 0
	local served = math.max(perfect + overcooked, 1)
	local qualityMult = ((perfect * Config.Kitchen.PerfectPayMult)
		+ (overcooked * Config.Kitchen.OvercookedPayMult)) / served

	local payout = math.floor(BASE_COINS_PER_PARTY * party.Size * diff.Rewards.CoinMult
		* (party.IsVIP and VIP_TIP_MULT or 1) * qualityMult)

	--// The split: BASE is the plain-order guarantee, TIP is everything above
	local base = math.floor(BASE_COINS_PER_PARTY * party.Size * diff.Rewards.CoinMult
		* Config.Kitchen.OvercookedPayMult)
	base = math.min(base, payout)
	local tip = payout - base

	local tablePart = tableById[tableId]
	if not tablePart then return end

	--// Same table somehow still holding leftovers (linger is short, so this
	--// is a rare edge): fold them in at their current value, clock restarts
	local existing = payments[tableId]
	if existing then
		base += (paymentValue(existing))
		destroyPayment(tableId)
	end

	--// Compact money sign: sits low over the table so it coexists with a
	--// newly seated party's billboards (which hang higher, at 7 studs)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Payment"
	gui.Size = UDim2.fromOffset(110, 34)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
	gui.AlwaysOnTop = true
	gui.Parent = tablePart

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.Parent = gui

	--// No money art in the asset registry yet, so the icon is a mustard "$"
	local sign = Instance.new("TextLabel")
	sign.Size = UDim2.fromOffset(26, 30)
	sign.BackgroundTransparency = 1
	sign.Font = Enum.Font.FredokaOne
	sign.TextScaled = true
	sign.TextColor3 = Color3.fromRGB(245, 184, 65)
	sign.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	sign.TextStrokeTransparency = 0
	sign.Text = "$"
	sign.LayoutOrder = 1
	sign.Parent = gui

	local amount = Instance.new("TextLabel")
	amount.Size = UDim2.fromOffset(70, 30)
	amount.BackgroundTransparency = 1
	amount.Font = Enum.Font.FredokaOne
	amount.TextScaled = true
	amount.TextXAlignment = Enum.TextXAlignment.Left
	amount.TextColor3 = PAY_COLOR.GRACE
	amount.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	amount.TextStrokeTransparency = 0
	amount.Text = tostring(payout)
	amount.LayoutOrder = 2
	amount.Parent = gui

	--// Its own prompt (G), offset below the table's main prompt (E) and
	--// the pour prompt (F), so three prompts on one part stay readable
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CollectPayment"
	prompt.ActionText = "Collect payment"
	prompt.ObjectText = ("Table %d"):format(tableId)
	prompt.KeyboardKeyCode = Enum.KeyCode.G
	prompt.UIOffset = Vector2.new(0, -70)
	prompt.HoldDuration = Config.Payment.CollectHoldSeconds
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = tablePart

	prompt.Triggered:Connect(function(player)
		collectPayment(tableId, player)
	end)

	payments[tableId] = {
		Base = base, Tip = tip, CreatedAt = os.clock(),
		Gui = gui, Prompt = prompt, Amount = amount,
	}
	print(("[Service] Table %d payment on the table: %d base + %d tip%s")
		:format(tableId, base, tip, party.IsVIP and " (VIP)" or ""))
end

--// ~2x/sec from the heartbeat: tick every billboard, expire the stale
local function updatePayments()
	local P = Config.Payment
	local expired = nil
	for tableId, payment in pairs(payments) do
		local value, t = paymentValue(payment)
		payment.Amount.Text = tostring(value)
		payment.Amount.TextColor3 = (t <= 0 and PAY_COLOR.GRACE)
			or (t < 1 and PAY_COLOR.DECAY) or PAY_COLOR.FLOOR

		--// The party leaves the moment the payment appears, so the linger
		--// clock runs from the END of the melt, not from "party left"
		local lifetime = P.GraceSeconds + P.DecaySeconds + P.LingerSeconds
		if os.clock() - payment.CreatedAt >= lifetime then
			expired = expired or {}
			table.insert(expired, tableId)
			print(("[Service] Table %d payment vanished - %d coins lost")
				:format(tableId, value))
		end
	end
	if expired then
		for _, tableId in ipairs(expired) do
			destroyPayment(tableId)
		end
	end
end

--// Eating done: the party is satisfied HERE (rep, served count) and
--// leaves on schedule; only the money waits behind on the table.
local function onPartyFinishedEating(party, tableId)
	shift.Satisfied += 1
	local repGain = party.IsVIP and diff.Reputation.VIPSatisfied or diff.Reputation.SatisfiedParty
	repChange(repGain, party.IsVIP and "VIP satisfied" or "party satisfied")

	createPayment(party, tableId)
	print(("[Service] Table %d finished eating%s. Served %d/%d")
		:format(tableId, party.IsVIP and " VIP" or "",
			shift.Satisfied, diff.Rewards.TargetParties))

	setPartyState(party, STATE.LEAVING)
	tableOccupant[tableId] = nil
	refreshTablePrompt(tableId)
	departTo(party, exitPos)
end

----------------------------------------------------------------
-- Order dialogue. Taking an order is now a short conversation rendered
-- by DialogueClient on the interacting player's screen. The server stays
-- in charge: it rolls the flow, picks every phrase, holds a per-party
-- lock, validates the recommendation pick, and auto-resolves on timeout
-- so a party can never be stranded un-ordered. The seated patience bar
-- keeps draining throughout - the conversation is charm, not a pause.
----------------------------------------------------------------
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local dialogueRemote = remotes:FindFirstChild("DialogueRemote")
if not dialogueRemote then
	dialogueRemote = Instance.new("RemoteEvent")
	dialogueRemote.Name = "DialogueRemote"
	dialogueRemote.Parent = remotes
end

local dialogueByToken = {}
local nextDialogueToken = 0

local function pickLine(pool)
	return pool[math.random(#pool)]
end

--// Customer-voiced pools have Singular/Plural variants: parties of one
--// say "I", parties of two or more say "we"
local function pickVoiced(pool, isPlural)
	return pickLine(isPlural and pool.Plural or pool.Singular)
end

--// Ends a dialogue and, if the order is still takeable, completes it -
--// the same sequence the old instant take-order ran. pickedKey (recommend
--// flow only, already validated) swaps the ASKING customer's dish, which
--// is Ticket[1]; the rest of a multi-dish ticket is untouched.
--// notifyClient closes the panel for timeouts; a completion the player
--// tapped themselves skips it so the closing line can play out.
local function resolveDialogue(dlg, pickedKey, notifyClient)
	if dialogueByToken[dlg.Token] ~= dlg then return end
	dialogueByToken[dlg.Token] = nil

	local party = dlg.Party
	if party.Dialogue == dlg then
		party.Dialogue = nil
	end

	if notifyClient and dlg.Player.Parent then
		dialogueRemote:FireClient(dlg.Player, "Cancel", dlg.Token)
	end

	--// Shift over / party gone: nothing left to order
	if party.State ~= STATE.SEATED or not serviceOpen() then return end

	if pickedKey and dlg.Flow == "recommend" then
		party.Ticket[1] = pickedKey
		if Config.Dialogue.RecommendPatienceBonus > 0 then
			extendBar(party, Config.Dialogue.RecommendPatienceBonus, "great recommendation")
		end
	end

	setPartyState(party, STATE.WAITING_FOOD)
	showTicket(party)
	refreshTablePrompt(party.TableId)
	print(("[Service] Order for Table %d: %s%s"):format(party.TableId, ticketText(party),
		pickedKey and " (waiter's recommendation)" or ""))
end

--// Pure close, NO completion - for walkouts. The panel disappears and the
--// party's fate is whatever the caller is already doing to them.
cancelDialogue = function(party)
	local dlg = party.Dialogue
	if not dlg then return end
	dialogueByToken[dlg.Token] = nil
	party.Dialogue = nil
	if dlg.Player.Parent then
		dialogueRemote:FireClient(dlg.Player, "Cancel", dlg.Token)
	end
end

local function beginDialogue(player, party, tableId)
	nextDialogueToken += 1
	local token = nextDialogueToken
	local flow = (math.random() < Config.Dialogue.RecommendChance) and "recommend" or "direct"

	local dlg = { Player = player, Party = party, Token = token, Flow = flow }
	party.Dialogue = dlg
	dialogueByToken[token] = dlg

	--// The server picks every phrase; the client only renders, substituting
	--// {DISH} with DishText (direct) or the picked dish's display (recommend)
	local plural = party.Size > 1
	local payload = {
		Token = token,
		Flow = flow,
		Timeout = Config.Dialogue.TimeoutSeconds,
		CloseAfter = Config.Dialogue.CloseAfterSeconds,
		DishText = ticketText(party),
		Lines = {
			Greet = pickLine(Config.Dialogue.WaiterGreetings),
			SmallTalkQ = pickVoiced(Config.Dialogue.WaiterSmallTalk, plural),
			Mood = pickVoiced(Config.Dialogue.CustomerMoods, plural),
			Customer = pickVoiced(flow == "recommend"
				and Config.Dialogue.CustomerAsksRecommend
				or Config.Dialogue.CustomerOrders, plural),
			Accept = pickVoiced(Config.Dialogue.CustomerAccepts, plural),
			Confirm = pickLine(Config.Dialogue.WaiterConfirms),
		},
	}

	if flow == "recommend" then
		payload.Dishes = {}
		for dishName, recipe in pairs(Config.Recipes) do
			table.insert(payload.Dishes, {
				Key = dishName,
				Display = recipe.Display,
				Icon = recipe.Icon,
				Line = pickLine(Config.Dialogue.WaiterRecommends),
			})
		end
		--// pairs order is undefined; sort so the buttons never shuffle
		table.sort(payload.Dishes, function(a, b) return a.Display < b.Display end)
	end

	dialogueRemote:FireClient(player, "Begin", payload)

	--// Walked off / died / left: the party orders what they were always
	--// going to order, and the table unlocks.
	task.delay(Config.Dialogue.TimeoutSeconds, function()
		local pending = dialogueByToken[token]
		if pending then
			print(("[Service] Dialogue for Table %d timed out - auto-resolving"):format(tableId))
			resolveDialogue(pending, nil, true)
		end
	end)
end

dialogueRemote.OnServerEvent:Connect(function(player, action, token, pickedKey)
	if action ~= "Complete" then return end

	local dlg = dialogueByToken[token]
	--// Only the waiter who opened this dialogue may finish it
	if not dlg or dlg.Player ~= player then return end

	--// Validate the pick; a bad or absent key falls back to the party's
	--// original ticket (the direct flow always lands here with nil)
	if pickedKey ~= nil and (type(pickedKey) ~= "string" or Config.Recipes[pickedKey] == nil) then
		pickedKey = nil
	end

	resolveDialogue(dlg, pickedKey, false)
end)

local function setupTable(tableId, tablePart)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Enabled = false
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = tablePart
	tablePrompt[tableId] = prompt

	if waterPart then
		local pour = Instance.new("ProximityPrompt")
		pour.Enabled = false
		pour.ActionText = "Pour water"
		pour.ObjectText = "Refresh their patience"
		pour.HoldDuration = 0.5
		pour.KeyboardKeyCode = Enum.KeyCode.F
		pour.UIOffset = Vector2.new(0, 60)
		pour.MaxActivationDistance = Config.Interaction.PromptRangeStuds
		pour.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
		pour.Parent = tablePart
		pourPrompts[tableId] = pour

		pour.Triggered:Connect(function(player)
			local party = tableOccupant[tableId]
			if not party or party.BarKind ~= "seated" then return end
			local pitcher = findHeldPitcher(player)
			if not pitcher then
				pour.ObjectText = "Need a filled pitcher!"
				task.delay(1.5, function() pour.ObjectText = "Refresh their patience" end)
				return
			end
			local uses = pitcher:GetAttribute("PitcherUses")
			if uses <= 0 then
				pour.ObjectText = "Pitcher empty - refill it!"
				task.delay(1.5, function() pour.ObjectText = "Refresh their patience" end)
				return
			end
			pitcher:SetAttribute("PitcherUses", uses - 1)
			pitcher.Name = ("Water Pitcher (%d)"):format(uses - 1)
			party.PoursReceived = (party.PoursReceived or 0) + 1
			local bonus = (party.PoursReceived == 1)
				and Config.Customers.WaterPourFirstBonus
				or Config.Customers.WaterPourRepeatBonus
			extendBar(party, bonus, "water pour")
		end)
	end

	prompt.Triggered:Connect(function(player)
		local party = tableOccupant[tableId]
		if not party or not serviceOpen() then return end

		if party.State == STATE.SEATED then
			--// The ticket was rolled when the party spawned. Taking the order
			--// is now a short dialogue on the waiter's screen; the ticket is
			--// revealed to the kitchen when it resolves (or times out).
			if party.Dialogue then
				--// Another waiter is already mid-conversation with this table
				prompt.ObjectText = "Being served!"
				task.delay(1.5, function() refreshTablePrompt(tableId) end)
				return
			end
			beginDialogue(player, party, tableId)

		elseif party.State == STATE.WAITING_FOOD then
			local dish, dishName = findTicketDish(player, party)
			if not dish then
				prompt.ObjectText = ("Table %d wants %s"):format(tableId, ticketText(party))
				return
			end

			--// Quality rides on the Tool from KitchenService and decides both
			--// the tip multiplier and the reputation on this dish
			local quality = dish:GetAttribute("Quality")
			if quality == "Perfect" then
				party.PerfectDishes = (party.PerfectDishes or 0) + 1
				repChange(Config.Reputation.PerfectDish, "perfect dish")
			elseif quality == "Overcooked" then
				party.OvercookedDishes = (party.OvercookedDishes or 0) + 1
				if Config.Kitchen.OvercookedRep ~= 0 then
					repChange(Config.Kitchen.OvercookedRep, "overcooked dish")
				end
			end

			dish:Destroy()

			--// Remove that one dish from the ticket
			local index = table.find(party.Ticket, dishName)
			if index then
				table.remove(party.Ticket, index)
			end
			showTicket(party)

			party.DishesRemaining -= 1
			if party.DishesRemaining > 0 then
				extendBar(party, Config.Customers.PerDishServeBonus, "dish landed")
				refreshTablePrompt(tableId)
			else
				-- LAST dish: the seated bar dies here, per spec
				removeBar(party)
				setPartyState(party, STATE.SERVED)
				refreshTablePrompt(tableId)
				task.delay(diff.EatingSeconds, function()
					if party.State ~= STATE.SERVED then return end
					if not serviceOpen() then
						setPartyState(party, STATE.LEAVING)
						tableOccupant[tableId] = nil
						refreshTablePrompt(tableId)
						departTo(party, exitPos)
						return
					end
					onPartyFinishedEating(party, tableId)
				end)
			end

		end
		--// Collecting payment is its own prompt now (see the payment
		--// section) - the party is long gone by the time money is grabbed
	end)
end

for tableId, tablePart in pairs(tableById) do
	setupTable(tableId, tablePart)
end

----------------------------------------------------------------
-- Seating + greeting (two prompts on the queued pawn)
----------------------------------------------------------------
local function findFreeTable()
	--// Sorted so tables fill 1, 2, 3, 4 rather than in hash order
	local ids = {}
	for tableId in pairs(tableById) do
		table.insert(ids, tableId)
	end
	table.sort(ids)

	for _, tableId in ipairs(ids) do
		--// A table with uncollected money on it is not clear yet: grab the
		--// payment (or let it melt away) before the next party sits down
		if tableOccupant[tableId] == nil and payments[tableId] == nil then
			return tableId
		end
	end
	return nil
end

local function attachQueuePrompts(party)
	local seat = Instance.new("ProximityPrompt")
	seat.ActionText = "Seat party"
	seat.ObjectText = ("Party of %d"):format(party.Size)
	seat.HoldDuration = 0.5
	seat.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	seat.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	seat.Parent = party.Pawn
	party.SeatPrompt = seat

	local greet = Instance.new("ProximityPrompt")
	greet.ActionText = "Greet"
	greet.ObjectText = "A warm welcome buys time"
	greet.HoldDuration = 0.4
	greet.KeyboardKeyCode = Enum.KeyCode.F
	greet.UIOffset = Vector2.new(0, 60)
	greet.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	greet.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	greet.Parent = party.Pawn

	greet.Triggered:Connect(function()
		if party.State ~= STATE.QUEUED or party.Greeted then return end
		party.Greeted = true
		greet:Destroy()
		extendBar(party, diff.GreetingBonus, "greeting")
	end)

	seat.Triggered:Connect(function(player)
		if party.State ~= STATE.QUEUED then return end
		local tableId = findFreeTable()
		if not tableId then
			--// Teach the rule: if a table is empty but has money on it,
			--// collecting is what unlocks the seat
			local moneyBlocked = false
			for tid in pairs(tableById) do
				if tableOccupant[tid] == nil and payments[tid] ~= nil then
					moneyBlocked = true
					break
				end
			end
			seat.ObjectText = moneyBlocked and "Collect the payment first!" or "No free tables!"
			task.delay(1.5, function()
				if seat.Parent then seat.ObjectText = ("Party of %d"):format(party.Size) end
			end)
			return
		end

		-- DOOR BAR DIES HERE: seating initiated (the walk is free, per spec)
		removeBar(party)
		seat:Destroy(); party.SeatPrompt = nil
		if greet.Parent then greet:Destroy() end
		spotOccupant[party.Spot] = nil
		party.Spot = nil
		tableOccupant[tableId] = party
		party.TableId = tableId

		local tablePart = tableById[tableId]
		party.ExitFrom = tablePart --// remembered for the ExitVia route later

		local seatPos = pointAbove(tablePart, 2) - tablePart.CFrame.LookVector * 4

		--// Route around this map's walls before arriving at the chair
		local points = routePoints(parseVia(tablePart:GetAttribute("EntryVia")))
		print(("[Service] Party %d walking to Table %d via %d waypoint(s)")
			:format(party.Id, tableId, #points))
		table.insert(points, seatPos)

		walkPath(party, points, function()
			-- SEATED BAR STARTS HERE: bodies in chairs
			setPartyState(party, STATE.SEATED)
			startSeatedBar(party)
			refreshTablePrompt(tableId)
		end)
		print(("[Service] %s seated Party %d at Table %d"):format(player.Name, party.Id, tableId))
	end)
end

----------------------------------------------------------------
-- Spawning
----------------------------------------------------------------
local function findFreeSpot()
	local queuedCount = 0
	for _, p in pairs(parties) do
		if p.State == STATE.QUEUED then queuedCount += 1 end
	end
	if queuedCount >= diff.DoorQueueMax then return nil end
	for _, spot in ipairs(queueSpots) do
		if spotOccupant[spot] == nil then return spot end
	end
	return nil
end

local function spawnParty()
	if shift.State ~= "RUNNING" then return end
	local spot = findFreeSpot()
	if not spot then return end

	nextPartyId += 1
	local party = {
		Id = nextPartyId,
		Size = rollPartySize(),
		IsVIP = math.random() < diff.VIPChance,
		State = STATE.QUEUED,
		Spot = spot,
		Greeted = false,
		DishesRemaining = 0,
	}
	party.DishesRemaining = party.Size

	--// One dish per customer, rolled from Config.OrderWeights. The ticket is
	--// what the kitchen has to produce; it shrinks as dishes land.
	party.Ticket = {}
	for _ = 1, party.Size do
		table.insert(party.Ticket, Config.RollDish())
	end
	parties[party.Id] = party
	spotOccupant[spot] = party
	--// Floor level: the top face of the queue pad. Rigs and the placeholder
	--// cylinder each add their own height from there.
	spawnPartyPawn(party, pointAbove(spot, 0))
	setPartyState(party, STATE.QUEUED)
	attachQueuePrompts(party)
	-- DOOR BAR STARTS HERE: the moment they exist
	startDoorBar(party)
	if party.IsVIP then
		print(("[Service] VIP party %d arrived - impatient, pays double"):format(party.Id))
	end
end

----------------------------------------------------------------
-- Shift end
----------------------------------------------------------------
local function endShift(success, reason)
	if shift.State == "ENDED" then return end
	shift.State = "ENDED"
	local hit = shift.Satisfied >= diff.Rewards.TargetParties
	shift.EndText = success
		and ("SHIFT COMPLETE - Served %d/%d %s"):format(shift.Satisfied,
			diff.Rewards.TargetParties, hit and "PASS" or "MISS")
		or ("SHIFT FAILED - %s"):format(reason or "")
	print("[Service] ============================================")
	print("[Service] " .. shift.EndText)
	print(("[Service] Rep %d | Door walkouts %d | Seated walkouts %d")
		:format(shift.Reputation, shift.DoorWalkouts, shift.SeatedWalkouts))
	if success then
		--// Paid once into the till, not once per player - the split below
		--// shares it out
		addToTill(diff.Rewards.CompletionBonus, "completion bonus")
		print(("[Service] Completion bonus: %d coins to everyone"):format(diff.Rewards.CompletionBonus))
	end
	-- bars freeze (heartbeat stops draining); everyone still inside ambles out
	for _, party in pairs(parties) do
		if party.State ~= STATE.LEAVING and party.State ~= STATE.WALKOUT then
			removeBar(party)
			if party.SeatPrompt then party.SeatPrompt:Destroy() end
			if party.TableId then
				tableOccupant[party.TableId] = nil
				refreshTablePrompt(party.TableId)
			end
			setPartyState(party, STATE.LEAVING)
			departTo(party, exitPos)
		end
	end

	--// Money still melting on tables banks at its current value - never
	--// strand earned coins at the buzzer. Split evenly, remainder to the
	--// first player in the list.
	local uncollected = 0
	local paymentTables = {}
	for tableId, payment in pairs(payments) do
		uncollected += (paymentValue(payment))
		table.insert(paymentTables, tableId)
	end
	for _, tableId in ipairs(paymentTables) do
		destroyPayment(tableId)
	end
	if uncollected > 0 then
		addToTill(uncollected, "uncollected table payments")
	end

	--// THE SPLIT. Everything the shift earned, minus everything the Supplier
	--// spent, divided evenly. This is the only moment private balances move.
	local everyone = Players:GetPlayers()
	if #everyone > 0 and shift.Till > 0 then
		local share = math.floor(shift.Till / #everyone)
		local remainder = shift.Till - (share * #everyone)

		for index, member in ipairs(everyone) do
			local paid = share
			if index == 1 and Config.Money.RemainderToFirstPlayer then
				paid += remainder
			end
			awardCoins(member, paid)
		end

		print(("[Service] Till %d split %d ways - %d each%s"):format(
			shift.Till, #everyone, share,
			remainder > 0 and (" (+%d remainder)"):format(remainder) or ""))
		shift.Till = 0
	elseif shift.Till > 0 then
		print("[Service] Nobody left to split the till with")
	end

	publishShift()
	refreshScoreboard()
end

----------------------------------------------------------------
-- CLOSING: the doors shut, the room does not empty instantly.
--
-- Not overtime - nobody new arrives. Everyone already inside finishes their
-- meal and pays, then the shift really ends. Queued customers outside are
-- turned away with no penalty; they were never served.
----------------------------------------------------------------
local function beginClosing()
	if shift.State ~= "RUNNING" then return end

	shift.State = "CLOSING"
	shift.Phase = "Closing"
	shift.ClosingElapsed = 0

	--// Turn away the queue. No reputation hit - the restaurant closed, they
	--// did not storm out.
	local turnedAway = 0
	for _, party in pairs(parties) do
		if party.State == STATE.QUEUED then
			removeBar(party)
			if party.Spot then
				spotOccupant[party.Spot] = nil
				party.Spot = nil
			end
			if party.SeatPrompt then
				party.SeatPrompt:Destroy()
				party.SeatPrompt = nil
			end
			setPartyState(party, STATE.LEAVING)
			departTo(party, exitPos)
			turnedAway += 1
		end
	end

	publishShift()
	print(("[Service] === CLOSING - doors shut, %d turned away, finishing the room ==="):format(turnedAway))
end

--// Everyone inside has gone, and no money is still sitting on a table
local function closingDone()
	for _, party in pairs(parties) do
		if party.State ~= STATE.LEAVING and party.State ~= STATE.WALKOUT then
			return false
		end
	end

	for _ in pairs(payments) do
		return false
	end

	return true
end

----------------------------------------------------------------
-- Heartbeat: the one clock that drains every bar
----------------------------------------------------------------
local sincePublish = 0
local PAYMENT_TICK = 0.5 --// billboard update rate for melting payments
local sincePaymentTick = 0

RunService.Heartbeat:Connect(function(dt)
	--// Attribute writes replicate, so publish on a throttle rather than per
	--// frame. A client HUD interpolates between ticks for a smooth bar.
	sincePublish += dt
	local shouldPublish = sincePublish >= PUBLISH_INTERVAL
	if shouldPublish then
		sincePublish = 0
	end

	if shift.State == "PREP" then
		shift.PrepRemaining -= dt
		if shouldPublish then publishShift() end
		refreshScoreboard()
		return
	end
	if not serviceOpen() then return end

	--// Elapsed freezes at closing time: the clock is done, only the room is
	--// still working. Phases stop advancing with it.
	if shift.State == "RUNNING" then
		shift.Elapsed += dt
		local phase = Config.PhaseAt(shift.Elapsed)
		if phase ~= shift.Phase then
			shift.Phase = phase
			print(("[Service] === Phase: %s ==="):format(phase))
		end
	else
		shift.ClosingElapsed = (shift.ClosingElapsed or 0) + dt
	end

	for _, party in pairs(parties) do
		if party.BarRemaining then
			party.BarRemaining -= dt
			updateBarVisual(party, party.BarRemaining / party.BarTotal)
			if shouldPublish then publishParty(party) end
			if party.BarRemaining <= 0 then
				if party.BarKind == "door" then
					doorWalkout(party)
				else
					seatedWalkout(party)
				end
			end
		end
	end

	sincePaymentTick += dt
	if sincePaymentTick >= PAYMENT_TICK then
		sincePaymentTick = 0
		updatePayments()
	end

	if shift.Reputation <= 0 then
		endShift(false, "reputation hit zero - the manager is furious")

	elseif shift.State == "RUNNING" and shift.Elapsed >= shift.Length then
		--// The clock is up, but the room is not empty yet
		beginClosing()

	elseif shift.State == "CLOSING" then
		if closingDone() then
			endShift(true)
		elseif shift.ClosingElapsed >= Config.Shift.ClosingMaxSeconds then
			--// Something is stuck. Close anyway rather than hang the shift.
			warn(("[Service] closing ran past %ds - ending anyway")
				:format(Config.Shift.ClosingMaxSeconds))
			endShift(true)
		end
	end

	if shouldPublish then publishShift() end
	refreshScoreboard()
end)

----------------------------------------------------------------
-- Boot: wait for a player, prep countdown, resolve difficulty, run
----------------------------------------------------------------
task.spawn(function()
	while #Players:GetPlayers() == 0 do
		publishShift()
		refreshScoreboard()
		task.wait(0.5)
	end

	DIFFICULTY = resolveDifficulty()
	diff = Config.ForDifficulty(DIFFICULTY)
	print(("[Service] Difficulty: %s (%s)"):format(DIFFICULTY, diff.Label))

	shift.State = "PREP"
	shift.PrepRemaining = DEBUG_PREP_SECONDS or Config.Shift.PrepTimeSeconds
	publishShift()
	print(("[Service] Prep: shift starts in %ds"):format(shift.PrepRemaining))
	task.wait(shift.PrepRemaining)

	shift.State = "RUNNING"
	shift.Elapsed = 0
	shift.Till = Config.Money.ShiftStartingTill --// every shift opens at zero
	publishShift()
	print(("[Service] === SHIFT START - %s, %ds, target %d parties ===")
		:format(diff.Label, shift.Length, diff.Rewards.TargetParties))

	task.wait(2)
	spawnParty()
	while shift.State == "RUNNING" do
		local interval = Config.SpawnIntervalFor(shift.Phase, DIFFICULTY, #Players:GetPlayers())
		task.wait(interval)
		spawnParty()
	end
end)
