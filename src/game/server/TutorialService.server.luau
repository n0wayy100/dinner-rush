--[[
	Dinner Rush - TutorialService
	ServerScriptService.Server.TutorialService  (Script)

	THE GUIDED FIRST SHIFT (Config.Tutorial). Runs ONLY while
	workspace.MatchMode is "TUTORIAL" (set by MatchServer from lobby
	teleport data, or the StudioTutorial knob); on a normal shift this
	script goes back to sleep untouched.

	Manager Bruno teaches ONE full customer loop with one scripted
	party: seat -> greet -> order -> then fetch/cook/serve three
	dishes, one per cook minigame (TutorialForceGame pins the roll),
	-> collect the payment -> wrap-up. The restaurant itself is the
	classroom: every step completes through the REAL validated flows,
	detected by watching the ServerStorage.AddScore bus the game
	already fires at every meaningful moment - no new bridges into
	ServiceLoop's internals.

	Publishes ReplicatedStorage.TutorialState (Active, Step, StepCount,
	Objective, TargetTag, TargetMethod) for TutorialClient's banner and
	the EventArrow. TutorialRemote "Skip" jumps to the wrap-up.

	The tutorial cannot be failed: ServiceLoop freezes patience and the
	shift clock in this mode, spawns/dash/critic/VIP/Helper are off.
	After the wrap the kitchen stays open as FREE PRACTICE.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local TUT = Config.Tutorial
if not TUT then return end

--// MatchServer publishes MatchMode with the rest of the match settings
--// when the first player arrives - wait for the verdict
while workspace:GetAttribute("MatchMode") == nil do
	task.wait(0.25)
end
if workspace:GetAttribute("MatchMode") ~= "TUTORIAL" then
	return --// a normal shift: this script has no business here
end

print("[Tutorial] TUTORIAL mode - waiting for the shift to open")

----------------------------------------------------------------
-- Published state + the skip remote
----------------------------------------------------------------
local State = Instance.new("Folder")
State.Name = "TutorialState"
State:SetAttribute("Active", true)
State:SetAttribute("Step", 0)
State:SetAttribute("StepCount", 0)
State:SetAttribute("Objective", "")
State:SetAttribute("TargetTag", "")
State:SetAttribute("TargetMethod", "")
State:SetAttribute("Dialogue", "")   --// Bruno's current box ("" = none)
State:SetAttribute("DialogueId", 0)  --// bumps per box, drives the client
State.Parent = ReplicatedStorage

--// THE ACTION GATE (owner spec, Sep 2026): on tutorial servers this
--// workspace attribute names the ONE interaction currently allowed
--// ("Seat"/"Greet"/"Order"/"Fetch"/"Cook"/"Serve"/"Collect"), "" while
--// Bruno is talking, "Free" once the lesson ends. ServiceLoop and
--// KitchenService refuse everything else with a Wait for Bruno flash;
--// on normal servers the attribute never exists and nothing is gated.
workspace:SetAttribute("TutorialGate", "")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end
local tutorialRemote = remotes:FindFirstChild("TutorialRemote")
if not tutorialRemote then
	tutorialRemote = Instance.new("RemoteEvent")
	tutorialRemote.Name = "TutorialRemote"
	tutorialRemote.Parent = remotes
end

local skipRequested = false
local dialogueAck = 0 --// last box id a player clicked past

tutorialRemote.OnServerEvent:Connect(function(player, action)
	if action == "Skip" and not skipRequested then
		skipRequested = true
		workspace:SetAttribute("TutorialGate", "Free") --// hands free at once
		print(("[Tutorial] %s skipped the tutorial"):format(player.Name))
	elseif action == "Next" then
		--// OWNER RULING (Sep 2026): Bruno WAITS. A box stays up until
		--// someone clicks it away; this ack releases the current one.
		dialogueAck = State:GetAttribute("DialogueId") or dialogueAck
	end
end)

----------------------------------------------------------------
-- Progress detection: the AddScore bus fires at every moment we care
-- about (Seats / Greetings / OrdersTaken / the cook-quality trio /
-- DishesServed / PaymentsCollected) - count them, never poke parties
----------------------------------------------------------------
local statCounts = {}
do
	local bus = ServerStorage:WaitForChild("AddScore", 30)
	if bus then
		bus.Event:Connect(function(_, key, amount)
			statCounts[key] = (statCounts[key] or 0) + (tonumber(amount) or 1)
		end)
	else
		warn("[Tutorial] no AddScore bus - steps cannot advance")
	end
end

local function stat(key)
	return statCounts[key] or 0
end

local function cookedTotal()
	return stat("PerfectCooks") + stat("GoodCooks") + stat("OvercookedCooks")
end

--// A raw of this exact ingredient in anyone's hands (or backpack)
local function anyPlayerCarries(ingredientName)
	for _, plr in ipairs(Players:GetPlayers()) do
		for _, container in ipairs({ plr.Character, plr:FindFirstChildOfClass("Backpack") }) do
			if container then
				for _, tool in ipairs(container:GetChildren()) do
					if tool:IsA("Tool")
						and tool:GetAttribute("Ingredient") == ingredientName then
						return true
					end
				end
			end
		end
	end
	return false
end

--// STUDIO fast-forward (Config.Tutorial.StudioSkipToFinale): while
--// true, every wait passes instantly and setStep publishes nothing -
--// the script sprints silently to the finale, then acts normally
local ffwd = false

--// Every wait bails the moment skip is requested
local function waitUntil(check)
	if ffwd then return true end
	while not skipRequested do
		if check() then return true end
		task.wait(0.15)
	end
	return false
end

local function waitSeconds(seconds)
	local deadline = os.clock() + seconds
	waitUntil(function() return os.clock() >= deadline end)
end

----------------------------------------------------------------
-- The script itself
----------------------------------------------------------------
local dialogueId = 0

--// One Bruno box on screen, gated on the player's click (or skip)
local function publishBox(text)
	dialogueId += 1
	--// text FIRST, id second: the client renders on the id change and
	--// must find the fresh text already there
	State:SetAttribute("Dialogue", text)
	State:SetAttribute("DialogueId", dialogueId)
	return dialogueId
end

--// Click through every box of a step's Bruno entry, one at a time -
--// this is what makes Bruno wait instead of talking past the player
local function sayBoxes(lines, dishName, fillFn)
	if typeof(lines) == "string" then
		lines = { lines }
	end
	if typeof(lines) ~= "table" then return end
	for _, line in ipairs(lines) do
		if skipRequested then break end
		local myId = publishBox(fillFn(line, dishName))
		waitUntil(function() return dialogueAck >= myId end)
	end
	State:SetAttribute("Dialogue", "")
end

--// {DISH}/{INGREDIENT}/{SOURCE}/{METHOD} come from the scripted
--// ticket; the minigame numbers come from the REAL game configs, so
--// Bruno's rules always match what the pans actually demand
local CARDS = Config.CardMatch or {}
local function fill(text, dishName)
	if not text then return "" end
	local recipe = Config.Recipes[dishName or ""] or {}
	local ingredient = Config.Ingredients[recipe.Ingredient or ""] or {}
	return (text
		:gsub("{DISH}", recipe.Display or tostring(dishName))
		:gsub("{INGREDIENT}", ingredient.Display or tostring(recipe.Ingredient))
		:gsub("{SOURCE}", ingredient.Source == "DryShelf" and "dry shelf" or "fridge")
		:gsub("{METHOD}", tostring(recipe.Method))
		:gsub("{CARDPAIRS}", tostring(CARDS.PerfectPairs))
		:gsub("{CARDGOOD}", tostring(CARDS.GoodPairs))
		:gsub("{CARDOK}", tostring(CARDS.OvercookedPairs)))
end

local stepNumber = 0
local function setStep(entry, dishName, targetTag, targetMethod, gate)
	stepNumber += 1
	if skipRequested or ffwd then
		return --// racing ahead: no lines, no objectives, no gate
	end
	State:SetAttribute("Step", stepNumber)

	--// Bruno talks FIRST, at the player's pace - hands OFF and the
	--// banner and arrow at rest until his last box is clicked away,
	--// then the task (and only ITS action) unlocks
	workspace:SetAttribute("TutorialGate", "")
	State:SetAttribute("Objective", "")
	State:SetAttribute("TargetTag", "")
	State:SetAttribute("TargetMethod", "")
	sayBoxes(entry.Bruno, dishName, fill)

	State:SetAttribute("Objective", fill(entry.Objective, dishName))
	State:SetAttribute("TargetTag", targetTag or "")
	State:SetAttribute("TargetMethod", targetMethod or "")
	workspace:SetAttribute("TutorialGate", gate or "")
end

--// The teaching ticket: the active map's dishes, biggest menu weight
--// first, one per cook game
local function buildTicket()
	local menu = Config.MenuForMap(workspace:GetAttribute("MatchMapId"))
	local rows = {}
	for dishName, weight in pairs(menu) do
		if Config.Recipes[dishName] then
			table.insert(rows, { Name = dishName, Weight = weight })
		end
	end
	table.sort(rows, function(a, b)
		if a.Weight ~= b.Weight then return a.Weight > b.Weight end
		return a.Name < b.Name --// stable when weights tie
	end)

	local wanted = #TUT.CookGameOrder
	local ticket = {}
	for i = 1, wanted do
		--// wrap if a future map's menu is shorter than the tour
		ticket[i] = rows[(i - 1) % math.max(#rows, 1) + 1].Name
	end
	return ticket
end

task.spawn(function()
	--// The shift must actually open first (PREP runs its course)
	local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 60)
	if not ShiftState then
		warn("[Tutorial] no ShiftState folder - tutorial cannot run")
		return
	end
	waitUntil(function()
		return ShiftState:GetAttribute("State") == "RUNNING"
	end)

	local ticket = buildTicket()

	--// TWO TABLES (owner spec, Sep 2026): the first party takes the
	--// first Parties[1] dishes, a later solo arrival takes the rest
	local sizes = TUT.Parties or { #ticket }
	local firstTicket, secondTicket = {}, {}
	for i, dishName in ipairs(ticket) do
		table.insert(i <= (sizes[1] or #ticket) and firstTicket or secondTicket,
			dishName)
	end
	local tableCount = #secondTicket > 0 and 2 or 1

	--// welcome/greet/seat/patience/order/cooking-intro + 3 per dish +
	--// the second table's seat and order + fire drill + VIP + collect
	--// + wrap
	State:SetAttribute("StepCount",
		6 + #ticket * 3 + (tableCount == 2 and 2 or 0) + 4)
	print(("[Tutorial] teaching with: %s"):format(table.concat(ticket, ", ")))

	if game:GetService("RunService"):IsStudio()
		and TUT.StudioSkipToFinale == true then
		ffwd = true
		print("[Tutorial] STUDIO: sprinting to the finale (StudioSkipToFinale)")
	end

	local spawner = ServerStorage:FindFirstChild("TutorialSpawnParty")

	--// FETCH / COOK / SERVE for one dish - cumulative targets, so a
	--// rookie who works ahead never wedges a step
	local function teachDish(i, dishName)
		local recipe = Config.Recipes[dishName]

		setStep(TUT.Text.Fetch, dishName,
			(Config.Ingredients[recipe.Ingredient] or {}).Source or "Fridge",
			nil, "Fetch")
		waitUntil(function()
			return anyPlayerCarries(recipe.Ingredient) or cookedTotal() >= i
		end)

		local cookText = TUT.Text.Cook[i] or TUT.Text.Cook[#TUT.Text.Cook]
		setStep(cookText, dishName, "CookStation", recipe.Method, "Cook")
		waitUntil(function() return cookedTotal() >= i end)

		--// pin the NEXT teaching game the moment this cook lands, so
		--// an eager early pan-load still draws the right one
		if TUT.CookGameOrder[i + 1] then
			workspace:SetAttribute("TutorialForceGame", TUT.CookGameOrder[i + 1])
		else
			workspace:SetAttribute("TutorialForceGame", nil)
		end

		--// full plate lesson on the first serve, a one-liner after
		local serveText = i == 1 and TUT.Text.Serve
			or (TUT.Text.ServeAgain or TUT.Text.Serve)
		setStep(serveText, dishName, "CustomerParty", nil, "Serve")
		waitUntil(function() return stat("DishesServed") >= i end)
		waitSeconds(TUT.StepSettleSeconds)
	end

	--// 1: WELCOME - setStep gates on Bruno's boxes, so the first party
	--// only shows up once the rookie has clicked through his hello
	setStep(TUT.Text.Welcome)

	--// Party one: a pair, plain (never VIP/critic/dash), through the
	--// real spawn path (fast-forward spawns nobody - the finale needs
	--// an empty floor)
	if spawner and not skipRequested and not ffwd then
		spawner:Invoke({ Plain = true, Size = sizes[1] or #firstTicket,
			Ticket = firstTicket })
	end
	--// Pin the first teaching cook before anyone touches a pan
	workspace:SetAttribute("TutorialForceGame", TUT.CookGameOrder[1])

	--// 2: GREET - FIRST, at the queue: the greet prompt lives on the
	--// QUEUED pawn and retires the moment the party is seated, so
	--// hello must come before the table
	setStep(TUT.Text.Greet, nil, "CustomerParty", nil, "Greet")
	waitUntil(function() return stat("Greetings") >= 1 end)
	waitSeconds(TUT.StepSettleSeconds)

	--// 3: SEAT (the party pawns themselves are the target)
	setStep(TUT.Text.Seat, nil, "CustomerParty", nil, "Seat")
	waitUntil(function() return stat("Seats") >= 1 end)
	waitSeconds(TUT.StepSettleSeconds)

	--// 4: PATIENCE - pure dialogue, taught while the bars hang right
	--// there over the seated party's heads
	setStep(TUT.Text.Patience)
	waitSeconds(TUT.StepSettleSeconds)

	--// 5: ORDER
	setStep(TUT.Text.Order, nil, "CustomerParty", nil, "Order")
	waitUntil(function() return stat("OrdersTaken") >= 1 end)
	waitSeconds(TUT.StepSettleSeconds)

	--// 6: COOKING INTRO - the three-game surprise, explained BEFORE
	--// the first kitchen trip (owner spec); pure dialogue
	setStep(TUT.Text.Cooking)
	waitSeconds(TUT.StepSettleSeconds)

	--// 7..: table one's dishes
	for i, dishName in ipairs(firstTicket) do
		teachDish(i, dishName)
	end

	--// THE SECOND TABLE: a solo customer arrives for the last dish
	if tableCount == 2 and spawner then
		if not skipRequested and not ffwd then
			spawner:Invoke({ Plain = true, Size = sizes[2] or #secondTicket,
				Ticket = secondTicket })
		end

		setStep(TUT.Text.Seat2, nil, "CustomerParty", nil, "Seat")
		waitUntil(function() return stat("Seats") >= 2 end)
		waitSeconds(TUT.StepSettleSeconds)

		setStep(TUT.Text.Order2, nil, "CustomerParty", nil, "Order")
		waitUntil(function() return stat("OrdersTaken") >= 2 end)
		waitSeconds(TUT.StepSettleSeconds)

		for j, dishName in ipairs(secondTicket) do
			teachDish(#firstTicket + j, dishName)
		end
	end

	--// COLLECT - one payment per table (melt is frozen in tutorial
	--// mode, so table one's money is still waiting)
	setStep(TUT.Text.Collect, nil, "Table", nil, "Collect")
	waitUntil(function() return stat("PaymentsCollected") >= tableCount end)
	waitSeconds(TUT.StepSettleSeconds)

	ffwd = false --// fast-forward ends HERE: the finale plays for real

	--// FINALE 1: THE FIRE DRILL - a real grease fire, started on
	--// purpose, so the first one in a live shift is old news. The
	--// extinguisher flow is ungated; out = ActiveEvent back to ""
	--// (one completed spray clears everything, owner ruling). The
	--// shift CANNOT fail meanwhile: ForceEndShift and the rep floor
	--// are both tutorial-proof in ServiceLoop.
	local EventState = ReplicatedStorage:FindFirstChild("EventState")
	local fireLever = ServerStorage:FindFirstChild("TutorialStartEvent")
	if EventState and fireLever and not skipRequested then
		setStep(TUT.Text.FireDrill, nil, "ExtinguisherMount")
		if not skipRequested and fireLever:Invoke("GreaseFire") then
			waitUntil(function()
				return (EventState:GetAttribute("ActiveEvent") or "") ~= "GreaseFire"
			end)
		end
		waitSeconds(TUT.StepSettleSeconds)
	end

	--// FINALE 2: THE CRITIC GRADUATION - the food critic himself, and
	--// NO hand holding: gate wide open, no guide line, the cook game a
	--// real surprise (the pin was cleared after cook three). The
	--// rookie runs the whole loop they just learned, and the review
	--// lands like it always does.
	if spawner and not skipRequested then
		setStep(TUT.Text.Critic, nil, nil, nil, "Free")
		if not skipRequested then
			--// relative target, so the graduation works whether the
			--// main lesson banked payments or was fast-forwarded past
			local paymentsBefore = stat("PaymentsCollected")
			spawner:Invoke({ Plain = true, Critic = true, Size = 1,
				Ticket = { Config.RollDish(
					Config.MenuForMap(workspace:GetAttribute("MatchMapId"))) } })
			waitUntil(function()
				return stat("PaymentsCollected") > paymentsBefore
			end)
		end
		waitSeconds(TUT.StepSettleSeconds)
	end

	--// WRAP - spoken even after a skip - and the kitchen stays open
	--// as free practice, every action unlocked
	workspace:SetAttribute("TutorialForceGame", nil)
	workspace:SetAttribute("TutorialGate", "Free")
	State:SetAttribute("Step", State:GetAttribute("StepCount"))
	State:SetAttribute("Objective", fill(TUT.Text.Wrap.Objective))
	State:SetAttribute("TargetTag", "")
	State:SetAttribute("TargetMethod", "")
	if skipRequested then
		--// no click gate on the way out: the GOODBYE box (the last
		--// line - a skipper gets the send-off, not the events tease)
		--// shows itself and melts away with the banner
		local lines = TUT.Text.Wrap.Bruno
		publishBox(fill(typeof(lines) == "table" and lines[#lines] or lines))
		print("[Tutorial] skipped - free practice from here")
	else
		sayBoxes(TUT.Text.Wrap.Bruno, nil, fill)
		print("[Tutorial] complete - free practice from here")
	end
	task.wait(TUT.WrapSeconds)
	State:SetAttribute("Dialogue", "")
	State:SetAttribute("Active", false)

	--// THE EXIT (owner spec): everyone back to the lobby. Guarded the
	--// way MatchServer's notes demand: TeleportAsync cannot run in
	--// Studio, and an unset PlaceId means the lobby wiring pass has
	--// not happened yet - both fall back to free practice.
	local placeId = tonumber(TUT.LobbyPlaceId) or 0
	if placeId > 0 and not game:GetService("RunService"):IsStudio() then
		task.wait(TUT.TeleportDelaySeconds or 3)
		local ok, err = pcall(function()
			game:GetService("TeleportService")
				:TeleportAsync(placeId, Players:GetPlayers())
		end)
		if not ok then
			warn("[Tutorial] lobby teleport failed: " .. tostring(err)
				.. " - free practice stays open")
		end
	else
		print("[Tutorial] no lobby send (Studio, or LobbyPlaceId unset)"
			.. " - free practice stays open")
	end
end)
