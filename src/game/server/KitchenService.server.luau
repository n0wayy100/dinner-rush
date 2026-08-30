--[[
	Dinner Rush - KitchenService
	ServerScriptService.Server.KitchenService  (regular Script, server-side)

	Ingredients, the two-item carry limit, and cooking.

	  parts tagged Fridge / DryShelf .. prompt gives a raw ingredient Tool
	  parts tagged CookStation ....... prompt cooks it, then hands back a dish
	    (attribute Method = "Fry" or "Grill"; the tag may sit on a Model)

	Cook progresses on one Heartbeat, same as ServiceLoop's patience bars:
	  COOKING -> PERFECT (scoring window) -> OVERCOOKED -> BURNT
	All timing comes from Config.Cooking via the recipe's Timing key, and
	difficulty never scales it.

	The handoff to ServiceLoop is attributes on the Tool, not a function call:
	  Ingredient = "RawSteak"          on raw items
	  Dish = "GrilledSteak"            on finished dishes
	  Quality = "Perfect"/"Overcooked" on finished dishes
	ServiceLoop reads those when a dish is served. Nothing else couples them.
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Kitchen] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

print("[Kitchen] script started")

--// Persistence contract - degrade over dying, same as ServiceLoop
local ProfileAPI
do
	local ok, api = pcall(function()
		return require(game:GetService("ServerStorage"):WaitForChild("Shared", 20):WaitForChild("ProfileAPI", 20))
	end)
	if ok and api then
		ProfileAPI = api
	else
		warn("[Kitchen] ProfileAPI unavailable - perfect-cook careers will NOT save")
		ProfileAPI = { AddStat = function() return false end }
	end
end

--// Career + ultimate charge in one call (same shape as ServiceLoop's)
local function creditStat(player, key, amount)
	ProfileAPI.AddStat(player, key, amount)
	local charge = game:GetService("ServerStorage"):FindFirstChild("AddCharge")
	if charge then
		pcall(function()
			charge:Invoke(player, key, amount)
		end)
	end
end

--// COOK TIMING GATE (used by startCook for the compensated timer and by
--// the collect path to open the minigame - see the cook-timing section)
local TIMING = Config.CookTiming

local function cookMinigameGated()
	local bridge = game:GetService("ServerStorage"):FindFirstChild("GetShiftInfo")
	if not bridge then return false end
	local ok, info = pcall(function() return bridge:Invoke() end)
	if not ok or type(info) ~= "table" then return false end
	local name = Config.IsValidDifficulty(info.Difficulty) and info.Difficulty or "NORMAL"
	local diff = Config.ForDifficulty(name)
	return diff.Interactions ~= nil and diff.Interactions.CookMinigame == true
end

----------------------------------------------------------------
-- Remote for the ingredient menu.
--
-- A prompt would do for one ingredient, but two prompts on one part both
-- answer to E and only one ever fires - which is why the fridge only ever
-- handed out steak. Sources with several ingredients open a menu instead.
-- The menu is intent only: the server re-checks everything below.
----------------------------------------------------------------
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local kitchenRemote = remotes:FindFirstChild("KitchenRemote")
if not kitchenRemote then
	kitchenRemote = Instance.new("RemoteEvent")
	kitchenRemote.Name = "KitchenRemote"
	kitchenRemote.Parent = remotes
end

--// POWER. EventSystem raises EventState.PowerOut during an outage; every
--// pan freezes where it is and no new cook can be started until the breaker
--// is thrown. Read, never written, here - the event owns it.
local eventStateFolder = nil
local function powerOut()
	if not eventStateFolder or not eventStateFolder.Parent then
		eventStateFolder = ReplicatedStorage:FindFirstChild("EventState")
	end
	return eventStateFolder ~= nil and eventStateFolder:GetAttribute("PowerOut") == true
end

local STATE_COLOR = {
	COOKING = Color3.fromRGB(245, 184, 65),
	PERFECT = Color3.fromRGB(76, 175, 109),
	OVERCOOKED = Color3.fromRGB(219, 128, 60),
	BURNT = Color3.fromRGB(90, 80, 78),
}

--// SHIFT REPORT COUNTERS. ServiceLoop pulls these at shift end through
--// GetKitchenStats. No reset needed: one server runs one shift, so the
--// script's lifetime IS the shift's.
local kitchenStats = {
	DishesBurnt = 0,
	ItemsBinned = 0,
	DishesBinned = 0,
	IngredientsBinned = 0,
}

do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "GetKitchenStats"
	bridge.OnInvoke = function()
		return table.clone(kitchenStats)
	end
	bridge.Parent = game:GetService("ServerStorage")
end

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

--// Tags may sit on a Model. Prompts and billboards need a BasePart.
local function resolvePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function taggedInWorkspace(tag)
	local found = {}
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			table.insert(found, instance)
		end
	end
	return found
end

--// Equipped tools live on the character, unequipped ones in the Backpack.
--// Both count toward the carry limit.
local function eachCarried(player, fn)
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

local function countCarried(player)
	local count = 0
	eachCarried(player, function(tool)
		if tool:GetAttribute("Ingredient") or tool:GetAttribute("Dish") then
			count += 1
		end
		return nil --// keep going
	end)
	return count
end

--// GAP 1 CHOKEPOINT: the carry limit is per-player now. THIRD HAND! sets
--// a CarryLimit attribute on its Waiter; everyone else falls through to
--// the Config default. Every limit read routes through here.
local function carryLimitFor(player)
	return player:GetAttribute("CarryLimit") or Config.Kitchen.MaxCarriedItems
end

local function isFull(player)
	return countCarried(player) >= carryLimitFor(player)
end

--// First carried raw ingredient this station can actually cook
local function findCookableIngredient(player, method)
	return eachCarried(player, function(tool)
		local ingredient = tool:GetAttribute("Ingredient")
		if ingredient and Config.RecipeFor(ingredient, method) then
			return tool
		end
		return nil
	end)
end

local function makeTool(name, icon, color, attributes)
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	if icon and icon ~= "" and icon ~= "rbxassetid://0" then
		tool.TextureId = icon
	end

	for key, value in pairs(attributes) do
		tool:SetAttribute(key, value)
	end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1.6, 0.8, 1.6)
	handle.Color = color
	handle.Material = Enum.Material.SmoothPlastic
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	return tool
end

local function giveIngredient(player, ingredientName)
	local data = Config.Ingredients[ingredientName]
	local character = player.Character
	if not data or not character then return end

	local tool = makeTool(data.Display, data.Icon, data.Color, { Ingredient = ingredientName })
	tool.Parent = character
	print(("[Kitchen] %s took %s"):format(player.Name, ingredientName))
end

--// Briefly says why a prompt did nothing, then restores its normal text
local function flash(prompt, message, normal)
	prompt.ObjectText = message
	task.delay(1.5, function()
		if prompt.Parent then
			prompt.ObjectText = normal
		end
	end)
end

----------------------------------------------------------------
-- STOCK: authoritative, server-only. The client is told the counts so it can
-- draw them; it never decides whether a take is allowed.
----------------------------------------------------------------
local stock = {}
for name, data in pairs(Config.Ingredients) do
	stock[name] = data.Stock or 0
end

local function ingredientsFor(sourceTag)
	local names = {}
	for name, data in pairs(Config.Ingredients) do
		if data.Source == sourceTag then
			table.insert(names, name)
		end
	end
	table.sort(names) --// stable order so menu rows never jump around
	return names
end

--// What the client menu draws: one row per ingredient, with its live count
local function menuPayload(sourceTag)
	local items = {}
	for _, name in ipairs(ingredientsFor(sourceTag)) do
		local data = Config.Ingredients[name]
		table.insert(items, {
			Name = name,
			Display = data.Display,
			Icon = data.Icon,
			Count = stock[name] or 0,
		})
	end
	return items
end

--// Counts live in the menu only - a world sign over every source stops
--// scaling the moment a fridge holds more than two or three ingredients.
--// Anyone with a menu open gets fresh counts; the client ignores sources it
--// is not currently showing, so no stale "3x" that is really 2x.
local function pushStockUpdate()
	for _, sourceTag in ipairs({ "Fridge", "DryShelf" }) do
		kitchenRemote:FireAllClients("StockChanged", sourceTag, menuPayload(sourceTag))
	end
end

--// ENTRY POINT FOR THE SUPPLIER SYSTEM (not built yet).
--// Adds stock and pushes the update everywhere. Call it from the delivery
--// code when a crate lands:
--//   ServerStorage.RestockIngredient:Invoke("RawPatty", 6)
local function restockIngredient(ingredientName, amount)
	if not Config.Ingredients[ingredientName] then
		warn(("[Kitchen] restock asked for unknown ingredient '%s'"):format(tostring(ingredientName)))
		return false
	end

	amount = tonumber(amount) or 0
	if amount <= 0 then
		return false
	end

	stock[ingredientName] = (stock[ingredientName] or 0) + amount
	pushStockUpdate()
	print(("[Kitchen] restocked %s by %d (now %d)"):format(
		ingredientName, amount, stock[ingredientName]))
	return true
end

do
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "RestockIngredient"
	bindable.OnInvoke = restockIngredient
	bindable.Parent = game:GetService("ServerStorage")
end

----------------------------------------------------------------
-- Ingredient sources: Fridge (cold) and DryShelf (dry)
----------------------------------------------------------------
local function setupSource(instance, sourceTag)
	local part = resolvePart(instance)
	if not part then
		warn(("[Kitchen] %s is tagged %s but has no BasePart - skipped")
			:format(instance:GetFullName(), sourceTag))
		return
	end

	local offered = ingredientsFor(sourceTag)
	if #offered == 0 then
		warn(("[Kitchen] nothing in Config.Ingredients has Source '%s'"):format(sourceTag))
		return
	end

	--// Every source opens the same menu, even one holding a single ingredient.
	--// One consistent interaction, and a shelf that gains a second ingredient
	--// later needs no code change.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Open_" .. sourceTag
	prompt.ActionText = "Open"
	prompt.ObjectText = sourceTag == "DryShelf" and "Dry Shelf" or sourceTag
	prompt.HoldDuration = Config.Kitchen.PickupHoldSeconds
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = part

	prompt.Triggered:Connect(function(player)
		kitchenRemote:FireClient(player, "OpenSourceMenu", sourceTag, menuPayload(sourceTag))
	end)

	print(("[Kitchen] %s offers %s"):format(part:GetFullName(), table.concat(offered, ", ")))
end

----------------------------------------------------------------
-- Menu picks come back here. The client chose; the server decides.
----------------------------------------------------------------
local function playerNearTag(player, tag, maxDistance)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	for _, instance in ipairs(taggedInWorkspace(tag)) do
		local part = resolvePart(instance)
		if part and (part.Position - root.Position).Magnitude <= maxDistance then
			return true
		end
	end
	return false
end

kitchenRemote.OnServerEvent:Connect(function(player, action, ingredientName)
	if action ~= "Take" then return end
	if typeof(ingredientName) ~= "string" then return end

	local data = Config.Ingredients[ingredientName]
	if not data then return end

	--// Must actually be standing at a source that stocks this ingredient,
	--// so a crafted "Take" from across the map is ignored. A little slack
	--// for stepping back while the menu is open.
	if not playerNearTag(player, data.Source, Config.Interaction.PromptRangeStuds + 6) then
		return
	end

	if isFull(player) then
		kitchenRemote:FireClient(player, "TakeDenied",
			("Hands full (max %d)"):format(carryLimitFor(player)))
		return
	end

	--// Stock is checked and spent here, on the server, after every other
	--// validation. The count the client drew is only ever a display.
	if (stock[ingredientName] or 0) <= 0 then
		kitchenRemote:FireClient(player, "TakeDenied", "Out of stock!")
		return
	end

	stock[ingredientName] -= 1
	giveIngredient(player, ingredientName)
	pushStockUpdate()
end)

----------------------------------------------------------------
-- THE BIN
-- Parts tagged TrashBin take whatever you are holding out of your hands.
-- Wrong ingredient, dish nobody ordered, something you grabbed by accident -
-- without this the two-item limit can wedge you with junk you cannot drop
-- (every Tool here is CanBeDropped = false).
--
-- Binned items are counted, ready for a future "take the trash out" chore.
----------------------------------------------------------------
local function firstBinnable(player)
	return eachCarried(player, function(tool)
		if tool:GetAttribute("Ingredient") or tool:GetAttribute("Dish") then
			return tool
		end
		return nil
	end)
end

local function setupBin(instance)
	local part = resolvePart(instance)
	if not part then
		warn(("[Kitchen] %s is tagged TrashBin but has no BasePart - skipped")
			:format(instance:GetFullName()))
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Bin"
	prompt.ActionText = "Bin it"
	prompt.ObjectText = "Trash"
	prompt.HoldDuration = Config.Kitchen.BinHoldSeconds
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = part

	prompt.Triggered:Connect(function(player)
		local tool = firstBinnable(player)
		if not tool then
			flash(prompt, "Nothing to throw away", "Trash")
			return
		end

		local what = tool:GetAttribute("Dish") or tool:GetAttribute("Ingredient")
		--// A binned DISH is a wasted cook, so it counts the same as a burnt
		--// one on the shift report. A raw ingredient is only wasted stock.
		if tool:GetAttribute("Dish") then
			kitchenStats.DishesBinned += 1
		else
			kitchenStats.IngredientsBinned += 1
		end
		kitchenStats.ItemsBinned += 1

		--// A plated dish scrapes into the bin and the plate goes straight back
		--// on the pass, empty. It never waits on a payment that will not come.
		local plateSlot = tool:GetAttribute("PlateSlot")
		if plateSlot then
			local ret = ServerStorage:FindFirstChild("PassReturnPlate")
			if ret then
				ret:Invoke(plateSlot, "dish binned")
			else
				warn("[Kitchen] binned a plated dish but ServerStorage.PassReturnPlate is missing"
					.. " - that plate is now lost until the shift ends")
			end
		end

		tool:Destroy()
		print(("[Kitchen] %s binned %s (%d item(s) this shift)")
			:format(player.Name, tostring(what), kitchenStats.ItemsBinned))
	end)

	print(("[Kitchen] bin ready: %s"):format(part:GetFullName()))
end

----------------------------------------------------------------
-- Cook stations
----------------------------------------------------------------
local stations = {} --// list of station records, ticked by one Heartbeat

--// ONE cook per station. A stove with three burners is three CookStation
--// anchors side by side, each with its own prompt and its own bar - stacking
--// several bars over a single anchor read as clutter.
--//
--// Anchors that close together do put several prompts near each other, which
--// is why StationPromptRangeStuds is tighter than the global prompt range:
--// stand at a burner and only that burner answers.

--// Kept SHORT on purpose. Burners sit a few studs apart, and TextScaled
--// stretches whatever it is given - "Grilled Steak - cooking" over three
--// adjacent anchors was a wall of overlapping text. The bar's fill and
--// colour already say cooking / ready / overcooked, so the label only needs
--// to name the dish, and shout when the pan is actually ruined.
local function stationLabel(station)
	if station.State == "IDLE" then
		return ""
	end

	if station.State == "BURNT" then
		return "BURNT!"
	end

	local recipe = Config.Recipes[station.Dish]
	return recipe and recipe.Display or tostring(station.Dish)
end

--// The prompt has room for the longer version
local function stationPromptText(station)
	local recipe = Config.Recipes[station.Dish]
	local display = recipe and recipe.Display or tostring(station.Dish)

	if station.State == "COOKING" then
		return ("%s - cooking"):format(display)
	elseif station.State == "PERFECT" then
		return ("%s - READY"):format(display)
	elseif station.State == "OVERCOOKED" then
		return ("%s - overcooked"):format(display)
	end
	return ("%s - BURNT"):format(display)
end

local function stationBusy(station)
	return station.State ~= "IDLE"
end

local function refreshStationUi(station)
	station.Gui.Enabled = stationBusy(station)
	if not stationBusy(station) then
		return
	end

	station.Label.Text = stationLabel(station)
	station.Fill.BackgroundColor3 = STATE_COLOR[station.State] or STATE_COLOR.COOKING

	--// Fills while cooking, then holds full through the later windows so
	--// colour alone communicates the state
	local fraction = 1
	if station.State == "COOKING" and station.CookTime > 0 then
		fraction = math.clamp(station.Elapsed / station.CookTime, 0, 1)
	end
	station.Fill.Size = UDim2.fromScale(fraction, 1)
end

local function refreshStationPrompt(station)
	local prompt = station.Prompt
	prompt.Enabled = not station.Disabled

	if station.State == "IDLE" then
		prompt.ActionText = "Cook"
		prompt.ObjectText = ("%s station"):format(station.Method)
		prompt.HoldDuration = Config.Kitchen.StationLoadHoldSeconds
	elseif station.State == "COOKING" then
		prompt.ActionText = "Cooking..."
		prompt.ObjectText = stationPromptText(station)
		prompt.HoldDuration = Config.Kitchen.CollectHoldSeconds
	elseif station.State == "BURNT" then
		prompt.ActionText = "Bin it"
		prompt.ObjectText = stationPromptText(station)
		prompt.HoldDuration = Config.Kitchen.BurntCleanupSeconds
	else
		prompt.ActionText = "Collect"
		prompt.ObjectText = stationPromptText(station)
		prompt.HoldDuration = Config.Kitchen.CollectHoldSeconds
	end
end

local function clearStation(station)
	station.State = "IDLE"
	station.Dish = nil
	station.Elapsed = 0
	refreshStationUi(station)
	refreshStationPrompt(station)
end

local function startCook(station, player, tool, dishName, recipe)
	local timing = Config.Cooking[recipe.Timing]
	if not timing then
		warn(("[Kitchen] recipe %s has Timing '%s', which is not in Config.Cooking")
			:format(dishName, tostring(recipe.Timing)))
		return
	end

	tool:Destroy() --// the raw ingredient is consumed

	--// Gated difficulties trade raw cook time for the timing minigame's
	--// overhead; EASY keeps the frozen full timer
	local cookTime = timing.CookTime
	if cookMinigameGated() then
		cookTime = math.max(cookTime * TIMING.MinigameCookTimeMult, TIMING.MinCookSeconds)
	end

	station.State = "COOKING"
	station.Dish = dishName
	station.Elapsed = 0
	station.CookTime = cookTime
	station.PerfectUntil = cookTime + timing.PerfectWindow
	station.OvercookedUntil = station.PerfectUntil + timing.OvercookAfter
	station.BurntAt = station.OvercookedUntil + timing.BurntAfter

	refreshStationUi(station)
	refreshStationPrompt(station)
	print(("[Kitchen] %s started %s on the %s"):format(player.Name, dishName, station.Method))
end

local function collect(station, player)
	local character = player.Character
	if not character then return end

	if station.State == "BURNT" then
		kitchenStats.DishesBurnt += 1 --// shift-report bookkeeping
		print(("[Kitchen] %s binned a burnt %s"):format(player.Name, tostring(station.Dish)))
		clearStation(station)
		return
	end

	if isFull(player) then
		flash(station.Prompt, ("Hands full (max %d)"):format(carryLimitFor(player)),
			stationPromptText(station))
		return
	end

	local dishName = station.Dish
	local recipe = Config.Recipes[dishName]
	local quality = station.State == "PERFECT" and "Perfect" or "Overcooked"

	local tool = makeTool(recipe.Display, recipe.Icon, recipe.Color, {
		Dish = dishName,
		Quality = quality,
	})
	tool.Parent = character

	--// The perfect COLLECT is the skill moment - career and ultimate charge
	--// credit here, at the pan, not later at the table (owner call)
	if quality == "Perfect" then
		creditStat(player, "PerfectCooks", 1)
	end

	print(("[Kitchen] %s collected a %s %s"):format(player.Name, quality, dishName))
	clearStation(station)
end

----------------------------------------------------------------
-- THE COOK TIMING GAME (gated by Difficulty.Interactions.CookMinigame -
-- EASY keeps the frozen window-collect and never sees this).
-- Replaces the COLLECT step only: an arrow ping-pongs across a bar, the
-- GREEN zone lands somewhere new every swing, and the SERVER keeps its
-- own clock - a client claim outside StopToleranceSeconds of the server's arrow
-- is overruled. The dish keeps AGING while the panel is up: a fumbling
-- cook can still burn it.
--   green (swing 1) -> Perfect  ·  yellow then green -> Good
--   yellow then yellow -> Overcooked  ·  red -> swing again
----------------------------------------------------------------
local cookTimingRemote = remotes:FindFirstChild("CookTimingRemote")
if not cookTimingRemote then
	cookTimingRemote = Instance.new("RemoteEvent")
	cookTimingRemote.Name = "CookTimingRemote"
	cookTimingRemote.Parent = remotes
end

local cookSessions = {} --// [station] = { Player, Stage, GreenCenter, SwingStart, Token }
local cookToken = 0

--// Where the server says the arrow is, 0..1, ping-ponging
local function arrowAt(elapsed, sweepSeconds)
	elapsed = math.max(elapsed, 0)
	local phase = (elapsed % (sweepSeconds * 2)) / sweepSeconds
	if phase <= 1 then
		return phase
	end
	return 2 - phase
end

--// A fresh pace every swing - no metronome to memorise
local function rollSweepSeconds()
	return TIMING.SweepSecondsMin
		+ math.random() * (TIMING.SweepSecondsMax - TIMING.SweepSecondsMin)
end

--// The green lands anywhere its full zone (plus yellows) fits on the bar
local function rollGreenCenter()
	local half = TIMING.GreenWidth / 2 + TIMING.YellowWidth
	return half + math.random() * (1 - 2 * half)
end

local function zoneFor(position, greenCenter)
	local fromGreen = math.abs(position - greenCenter)
	if fromGreen <= TIMING.GreenWidth / 2 then
		return "green"
	elseif fromGreen <= TIMING.GreenWidth / 2 + TIMING.YellowWidth then
		return "yellow"
	end
	return "red"
end

local function closeCookSession(station, tellClient)
	local session = cookSessions[station]
	if not session then return end
	cookSessions[station] = nil
	if tellClient and session.Player and session.Player.Parent then
		cookTimingRemote:FireClient(session.Player, "Close", session.Token)
	end
end

--// The minigame's version of collect(): same tool shape, same bookkeeping
local function grantFromMinigame(station, player, quality)
	local character = player.Character
	if not character then return false end
	if isFull(player) then
		flash(station.Prompt, ("Hands full (max %d)"):format(carryLimitFor(player)),
			stationPromptText(station))
		return false
	end

	local dishName = station.Dish
	local recipe = Config.Recipes[dishName]
	if not recipe then return false end

	local tool = makeTool(recipe.Display, recipe.Icon, recipe.Color, {
		Dish = dishName,
		Quality = quality,
	})
	tool.Parent = character

	if quality == "Perfect" then
		creditStat(player, "PerfectCooks", 1) --// the Chef's moment, as ever
	end

	print(("[Kitchen] %s timed a %s %s off the arrow"):format(player.Name, quality, dishName))
	clearStation(station)
	return true
end

local function beginCookSession(station, player)
	local existing = cookSessions[station]
	if existing then
		if existing.Player ~= player then
			flash(station.Prompt, "Being collected!", stationPromptText(station))
		end
		return
	end

	cookToken += 1
	local session = {
		Player = player,
		Stage = 1,
		GreenCenter = rollGreenCenter(),
		SweepSeconds = rollSweepSeconds(),
		SwingStart = os.clock(),
		Token = cookToken,
	}
	cookSessions[station] = session

	cookTimingRemote:FireClient(player, "Open", {
		Token = session.Token,
		Stage = 1,
		GreenCenter = session.GreenCenter,
		SweepSeconds = session.SweepSeconds,
		StationPosition = station.Part.Position,
	})

	--// An abandoned panel must never lock the pan
	local myToken = session.Token
	task.delay(TIMING.TimeoutSeconds, function()
		local live = cookSessions[station]
		if live and live.Token == myToken then
			print("[Kitchen] timing panel timed out - station freed")
			closeCookSession(station, true)
		end
	end)
end

local function findCookSession(player, token)
	for station, session in pairs(cookSessions) do
		if session.Token == token and session.Player == player then
			return station, session
		end
	end
	return nil, nil
end

cookTimingRemote.OnServerEvent:Connect(function(player, action, token, claimed)
	if action == "Abandon" then
		local station = findCookSession(player, token)
		if station then
			closeCookSession(station, false)
		end
		return
	end
	if action ~= "Stop" then return end

	local station, session = findCookSession(player, token)
	if not station then return end

	--// The dish must still be sitting there collectable (not burnt away,
	--// not wiped by a grease fire)
	if station.State ~= "PERFECT" and station.State ~= "OVERCOOKED" then
		closeCookSession(station, true)
		return
	end

	--// SERVER CLOCK RULES: honour the claim only within tolerance.
	--// Tolerance is lag in seconds converted to bar distance at THIS
	--// swing's speed, so a fast swing forgives the same ping
	local expected = arrowAt(os.clock() - session.SwingStart, session.SweepSeconds)
	local tolerance = TIMING.StopToleranceSeconds / session.SweepSeconds
	local position = tonumber(claimed)
	if not position or math.abs(position - expected) > tolerance then
		position = expected
	end
	position = math.clamp(position, 0, 1)

	local zone = zoneFor(position, session.GreenCenter)
	local done, quality = false, nil

	if zone == "green" then
		done = true
		quality = session.Stage == 1 and "Perfect" or "Good"
	elseif zone == "yellow" then
		if session.Stage == 1 then
			session.Stage = 2 --// one more swing to save the dish
		else
			done = true
			quality = "Overcooked"
		end
	end
	--// red: same stage, swing again

	if done then
		cookTimingRemote:FireClient(player, "Result", token, zone, quality)
		grantFromMinigame(station, player, quality)
		closeCookSession(station, true)
		return
	end

	--// Next swing: fresh green, fresh pace, and the server clock waits
	--// out the client's result flash so both arrows launch together
	session.GreenCenter = rollGreenCenter()
	session.SweepSeconds = rollSweepSeconds()
	session.SwingStart = os.clock() + TIMING.ResultFlashSeconds
	cookTimingRemote:FireClient(player, "Result", token, zone, nil)
	cookTimingRemote:FireClient(player, "Sweep", token,
		session.Stage, session.GreenCenter, session.SweepSeconds)
end)

--// Wipes whatever is on the pan. Used by the grease fire.
local function cancelCook(station)
	if station.State == "IDLE" then
		return false
	end
	clearStation(station)
	return true
end

local function setupStation(instance)
	local part = resolvePart(instance)
	if not part then
		warn(("[Kitchen] %s is tagged CookStation but has no BasePart - skipped")
			:format(instance:GetFullName()))
		return
	end

	local method = instance:GetAttribute("Method") or part:GetAttribute("Method")
	if not method or not Config.CookMethodAliases[method] then
		warn(("[Kitchen] %s has Method '%s' - needs \"Fry\" or \"Grill\"")
			:format(instance:GetFullName(), tostring(method)))
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "CookProgress"
	gui.Size = UDim2.fromOffset(Config.Kitchen.StationBarWidth, Config.Kitchen.StationBarHeight)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.55)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui

	local back = Instance.new("Frame")
	back.AnchorPoint = Vector2.new(0.5, 1)
	back.Position = UDim2.fromScale(0.5, 1)
	back.Size = UDim2.fromScale(0.92, 0.34)
	back.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = STATE_COLOR.COOKING
	fill.BorderSizePixel = 0
	fill.Parent = back

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Cook"
	--// Deliberately tighter than the global range: neighbouring burners
	--// would otherwise all be in reach and E would fire an arbitrary one
	prompt.MaxActivationDistance = Config.Kitchen.StationPromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = part

	--// Optional grouping. Several anchors on one physical appliance (three
	--// burners on one stove) share an Appliance name so a grease fire takes
	--// the whole thing at once instead of one burner at a time.
	--// Absent = the anchor stands alone, exactly as before.
	local appliance = instance:GetAttribute("Appliance") or part:GetAttribute("Appliance")

	local station = {
		Part = part,
		Method = method,
		Appliance = typeof(appliance) == "string" and appliance ~= "" and appliance or nil,
		State = "IDLE",
		Elapsed = 0,
		Gui = gui,
		Label = label,
		Fill = fill,
		Prompt = prompt,
		Disabled = false, --// set by the event bridge (grease fire); the prompt
		                  --// is also turned off, this is belt-and-braces
	}

	--// CHEF PASSIVE. HoldDuration lives on the SHARED prompt, so it cannot
	--// be per-player by itself: scale it the instant THIS player starts
	--// holding, restore on release. Two players starting a hold in the same
	--// frame is a last-writer race we accept - collect holds are 0.4s.
	--// Only collect-shaped holds scale; tap-to-load and burnt-bin stay flat.
	prompt.PromptButtonHoldBegan:Connect(function(player)
		local mult = player:GetAttribute("CollectHoldMult") or 1
		if mult ~= 1 and (station.State == "COOKING" or station.State == "PERFECT"
			or station.State == "OVERCOOKED") then
			prompt.HoldDuration = Config.Kitchen.CollectHoldSeconds * mult
		end
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		refreshStationPrompt(station)
	end)

	prompt.Triggered:Connect(function(player)
		if station.Disabled then return end

		if powerOut() then
			flash(prompt, "No power!", stationPromptText(station))
			return
		end

		if station.State == "IDLE" then
			local tool = findCookableIngredient(player, station.Method)
			if not tool then
				flash(prompt, "Bring something this station can cook",
					("%s station"):format(station.Method))
				return
			end
			local dishName, recipe = Config.RecipeFor(tool:GetAttribute("Ingredient"), station.Method)
			startCook(station, player, tool, dishName, recipe)

		elseif station.State == "COOKING" then
			flash(prompt, "Not ready yet", stationPromptText(station))

		elseif station.State == "BURNT" then
			collect(station, player) --// binning stays a plain hold everywhere

		elseif cookMinigameGated() then
			beginCookSession(station, player) --// gated: the arrow decides quality

		else
			collect(station, player) --// EASY: the frozen window-collect
		end
	end)

	refreshStationPrompt(station)
	table.insert(stations, station)
	print(("[Kitchen] station ready: %s (%s%s)"):format(
		part:GetFullName(), method,
		station.Appliance and (", appliance " .. station.Appliance) or ""))
end

----------------------------------------------------------------
-- One clock for every station
----------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	--// Lights out, stoves out: every pan holds exactly where it was, so a
	--// dish mid-cook is waiting rather than quietly burning in the dark.
	if powerOut() then
		return
	end

	for _, station in ipairs(stations) do
		if station.State ~= "IDLE" and station.State ~= "BURNT" then
			station.Elapsed += dt

			local previous = station.State
			if station.Elapsed >= station.BurntAt then
				station.State = "BURNT"
			elseif station.Elapsed >= station.OvercookedUntil then
				station.State = "OVERCOOKED"
			elseif station.Elapsed >= station.CookTime then
				station.State = "PERFECT"
			else
				station.State = "COOKING"
			end

			refreshStationUi(station)
			if station.State ~= previous then
				refreshStationPrompt(station)
			end
		end
	end
end)

--// Station state does not change while frozen, so nothing would otherwise
--// repaint the prompts. Watch the flag and refresh them the moment the power
--// goes out or comes back, so a dead stove reads as dead before anyone
--// walks up and presses E at it.
task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild("EventState", 30)
	if not folder then return end

	folder:GetAttributeChangedSignal("PowerOut"):Connect(function()
		local out = folder:GetAttribute("PowerOut") == true
		for _, station in ipairs(stations) do
			if out then
				station.Prompt.ActionText = "No power"
				station.Prompt.ObjectText = station.State == "IDLE"
					and ("%s station"):format(station.Method)
					or stationPromptText(station)
			else
				refreshStationPrompt(station)
			end
		end
		print(("[Kitchen] power %s - %d station(s) %s"):format(
			out and "out" or "back", #stations, out and "frozen" or "running"))
	end)
end)

----------------------------------------------------------------
-- EVENT BRIDGE (server-only). EventSystem drives grease fires through
-- this, mirroring the RestockIngredient pattern above:
--   local ctl = ServerStorage.KitchenStationControl
--   ctl:Invoke("List")                  -> { {Id, Part, Method, Busy, Disabled}, ... }
--   ctl:Invoke("CancelCook", id)        -> true if an in-progress cook was destroyed
--                                          (dish + progress bar; the ingredient is lost)
--   ctl:Invoke("SetDisabled", id, on)   -> station prompt on/off; a disabled station
--                                          refuses all interaction. true on success.
----------------------------------------------------------------
do
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "KitchenStationControl"
	bindable.OnInvoke = function(action, id, value)
		if action == "List" then
			local list = {}
			for index, station in ipairs(stations) do
				table.insert(list, {
					Id = index,
					Part = station.Part,
					Method = station.Method,
					Busy = stationBusy(station),
					Appliance = station.Appliance,
					Disabled = station.Disabled == true,
				})
			end
			return list
		end

		local station = stations[tonumber(id) or -1]
		if not station then return false end

		if action == "CancelCook" then
			--// A fire ruins every pan on the appliance, not just one burner
			local cancelled = cancelCook(station)
			if cancelled then
				print(("[Kitchen] cooks on the %s cancelled by event (station %d)")
					:format(station.Method, id))
			end
			return cancelled
		elseif action == "SetDisabled" then
			station.Disabled = value == true
			refreshStationPrompt(station)
			return true
		end

		return false
	end
	bindable.Parent = game:GetService("ServerStorage")
end

----------------------------------------------------------------
-- Setup. Waits for the kitchen the same way ServiceLoop waits for the
-- grey-box, so a map that arrives late still gets wired.
----------------------------------------------------------------
task.spawn(function()
	local waited = 0
	while waited < 20 do
		local fridges = taggedInWorkspace("Fridge")
		local shelves = taggedInWorkspace("DryShelf")
		local cookers = taggedInWorkspace("CookStation")

		if #fridges + #shelves > 0 and #cookers > 0 then
			for _, instance in ipairs(fridges) do setupSource(instance, "Fridge") end
			for _, instance in ipairs(shelves) do setupSource(instance, "DryShelf") end
			for _, instance in ipairs(cookers) do setupStation(instance) end

			--// Optional: no bin tagged just means nothing to throw items in
			local bins = taggedInWorkspace("TrashBin")
			for _, instance in ipairs(bins) do setupBin(instance) end
			if #bins == 0 then
				warn("[Kitchen] no part tagged TrashBin - players cannot discard items")
			end

			print(("[Kitchen] ready: %d fridge(s), %d shelf/shelves, %d station(s)")
				:format(#fridges, #shelves, #cookers))
			return
		end

		task.wait(0.5)
		waited += 0.5
	end

	warn("[Kitchen] no Fridge/DryShelf/CookStation tags found in Workspace - cooking is disabled")
end)
