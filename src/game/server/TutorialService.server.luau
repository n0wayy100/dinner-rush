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
State.Parent = ReplicatedStorage

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
tutorialRemote.OnServerEvent:Connect(function(player, action)
	if action == "Skip" and not skipRequested then
		skipRequested = true
		print(("[Tutorial] %s skipped the tutorial"):format(player.Name))
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

--// Every wait bails the moment skip is requested
local function waitUntil(check)
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
local function say(line)
	local bruno = ServerStorage:FindFirstChild("ManagerSay")
	if bruno then
		bruno:Fire(line)
	end
end

--// {DISH}/{INGREDIENT}/{SOURCE}/{METHOD} come from the scripted ticket
local function fill(text, dishName)
	if not text then return "" end
	local recipe = Config.Recipes[dishName or ""] or {}
	local ingredient = Config.Ingredients[recipe.Ingredient or ""] or {}
	return (text
		:gsub("{DISH}", recipe.Display or tostring(dishName))
		:gsub("{INGREDIENT}", ingredient.Display or tostring(recipe.Ingredient))
		:gsub("{SOURCE}", ingredient.Source == "DryShelf" and "dry shelf" or "fridge")
		:gsub("{METHOD}", tostring(recipe.Method)))
end

local stepNumber = 0
local function setStep(entry, dishName, targetTag, targetMethod)
	stepNumber += 1
	if skipRequested then
		return --// racing to the wrap-up: no lines, no objectives
	end
	State:SetAttribute("Step", stepNumber)
	State:SetAttribute("Objective", fill(entry.Objective, dishName))
	State:SetAttribute("TargetTag", targetTag or "")
	State:SetAttribute("TargetMethod", targetMethod or "")
	if entry.Bruno then
		say(fill(entry.Bruno, dishName))
	end
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
	State:SetAttribute("StepCount", 4 + #ticket * 3 + 2)
	print(("[Tutorial] teaching with: %s"):format(table.concat(ticket, ", ")))

	--// 1: WELCOME
	setStep(TUT.Text.Welcome)
	waitSeconds(TUT.WelcomeSeconds)

	--// The one scripted party - plain (never VIP/critic/dash), one
	--// dish per cook game, through the real spawn path
	local spawner = ServerStorage:FindFirstChild("TutorialSpawnParty")
	if spawner and not skipRequested then
		spawner:Invoke({ Plain = true, Size = #ticket, Ticket = ticket })
	end
	--// Pin the first teaching cook before anyone touches a pan
	workspace:SetAttribute("TutorialForceGame", TUT.CookGameOrder[1])

	--// 2: SEAT (the party pawns themselves are the target)
	setStep(TUT.Text.Seat, nil, "CustomerParty")
	waitUntil(function() return stat("Seats") >= 1 end)
	waitSeconds(TUT.StepSettleSeconds)

	--// 3: GREET (an eager rookie who orders first auto-passes this)
	setStep(TUT.Text.Greet, nil, "CustomerParty")
	waitUntil(function()
		return stat("Greetings") >= 1 or stat("OrdersTaken") >= 1
	end)

	--// 4: ORDER
	setStep(TUT.Text.Order, nil, "CustomerParty")
	waitUntil(function() return stat("OrdersTaken") >= 1 end)
	waitSeconds(TUT.StepSettleSeconds)

	--// 5..: FETCH / COOK / SERVE, once per dish - cumulative targets,
	--// so working ahead never wedges a step
	for i, dishName in ipairs(ticket) do
		local recipe = Config.Recipes[dishName]

		setStep(TUT.Text.Fetch, dishName,
			(Config.Ingredients[recipe.Ingredient] or {}).Source or "Fridge")
		waitUntil(function()
			return anyPlayerCarries(recipe.Ingredient) or cookedTotal() >= i
		end)

		local cookText = TUT.Text.Cook[i] or TUT.Text.Cook[#TUT.Text.Cook]
		setStep(cookText, dishName, "CookStation", recipe.Method)
		waitUntil(function() return cookedTotal() >= i end)

		--// pin the NEXT teaching game the moment this cook lands, so
		--// an eager early pan-load still draws the right one
		if TUT.CookGameOrder[i + 1] then
			workspace:SetAttribute("TutorialForceGame", TUT.CookGameOrder[i + 1])
		else
			workspace:SetAttribute("TutorialForceGame", nil)
		end

		setStep(TUT.Text.Serve, dishName, "CustomerParty")
		waitUntil(function() return stat("DishesServed") >= i end)
		waitSeconds(TUT.StepSettleSeconds)
	end

	--// COLLECT (the party is eating, then the money melts on the table)
	setStep(TUT.Text.Collect, nil, "Table")
	waitUntil(function() return stat("PaymentsCollected") >= 1 end)

	--// WRAP - spoken even after a skip - and the kitchen stays open
	--// as free practice
	workspace:SetAttribute("TutorialForceGame", nil)
	State:SetAttribute("Step", State:GetAttribute("StepCount"))
	State:SetAttribute("Objective", fill(TUT.Text.Wrap.Objective))
	State:SetAttribute("TargetTag", "")
	State:SetAttribute("TargetMethod", "")
	say(fill(TUT.Text.Wrap.Bruno))
	if skipRequested then
		print("[Tutorial] skipped - free practice from here")
	else
		print("[Tutorial] complete - free practice from here")
	end
	task.wait(TUT.WrapSeconds)
	State:SetAttribute("Active", false)
end)
