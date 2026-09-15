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

local Sfx = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Sfx"))
local DishModels = require(ServerStorage:WaitForChild("Shared"):WaitForChild("DishModels"))
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

--// Score-only moments (no career write): the HIDDEN shift score still
--// counts them (same shape as ServiceLoop's helper)
local function scoreOnly(player, key, amount)
	local bus = game:GetService("ServerStorage"):FindFirstChild("AddScore")
	if bus then
		bus:Fire(player, key, amount)
	end
end

--// Career + ultimate charge + hidden score in one call
local function creditStat(player, key, amount)
	ProfileAPI.AddStat(player, key, amount)
	local charge = game:GetService("ServerStorage"):FindFirstChild("AddCharge")
	if charge then
		pcall(function()
			charge:Invoke(player, key, amount)
		end)
	end
	scoreOnly(player, key, amount)
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

	--// Composed cartoon food (DishModels): once a builder dresses the
	--// tool, the plain block becomes an invisible grip. Default grip -
	--// a GripPos nudge was tried and pulled food INTO the chest.
	if DishModels.decorate(tool, attributes.Dish or attributes.Ingredient) then
		handle.Transparency = 1
	end

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

--// Only ingredients the ACTIVE map's menu can cook exist in its kitchen -
--// no raw shrimp in the diner fridge, no patties at Yamasaki. Computed per
--// call because MatchMapId can arrive after this script boots.
local function menuAllows(ingredientName)
	local menu = Config.MenuForMap(workspace:GetAttribute("MatchMapId"))
	for dishName in pairs(menu) do
		local recipe = Config.Recipes[dishName]
		if recipe and recipe.Ingredient == ingredientName then
			return true
		end
	end
	return false
end

local function ingredientsFor(sourceTag)
	local names = {}
	for name, data in pairs(Config.Ingredients) do
		if data.Source == sourceTag and menuAllows(name) then
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
	if not menuAllows(ingredientName) then return end --// not on this map's menu

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
		return station.Method == "Ramen" and "RUINED!" or "BURNT!"
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
	if station.Method == "Ramen" then
		return ("%s - RUINED"):format(display)
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

--// ONE sizzle per method, however many pans run (owner ruling, Sep
--// 2026): the loop starts with the first cook of a method and ends
--// when the LAST pan of that method stops - three burgers at once is
--// one grill sound, not three stacked. Ref-counted; parented at
--// whichever station started it (the kitchen is compact, close enough).
local cookLoops = {} --// [method] = { Handle, Count }

local function cookSoundStart(station)
	if station.SfxOn then return end
	station.SfxOn = true

	local entry = cookLoops[station.Method]
	if not entry then
		entry = { Handle = nil, Count = 0 }
		cookLoops[station.Method] = entry
	end
	entry.Count += 1
	if not (entry.Handle and entry.Handle:IsPlaying()) then
		local loopName = ({ Fry = "CookFry", Grill = "CookGrill", Ramen = "CookRamen" })
			[station.Method] or "CookGrill"
		entry.Handle = Sfx.Loop(loopName, station.Part)
	end
end

local function cookSoundStop(station)
	if not station.SfxOn then return end
	station.SfxOn = nil

	local entry = cookLoops[station.Method]
	if not entry then return end
	entry.Count = math.max(entry.Count - 1, 0)
	if entry.Count == 0 and entry.Handle then
		entry.Handle:Stop()
		entry.Handle = nil
	end
end

--// THE FOOD ON THE PAN (owner request, Sep 2026): the raw model sits
--// on the station while it cooks, swaps to the finished dish at the
--// PERFECT turn, and chars black if it burns. Same DishModels builders
--// as hands and plates; the base is an invisible anchored core.
local function clearStationFood(station)
	if station.FoodDisplay then
		station.FoodDisplay:Destroy()
		station.FoodDisplay = nil
	end
end

local function setStationFood(station, itemName, burnt)
	clearStationFood(station)
	if not itemName then return end

	local base = Instance.new("Part")
	base.Name = "CookingFood"
	base.Size = Vector3.new(0.6, 0.4, 0.6)
	base.Transparency = 1
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = false
	base.CanTouch = false
	--// Bottom-aligned: every model's underside lands exactly on the
	--// measured lift for THIS station's method, whatever its shape
	local lift = Config.Kitchen.StationFoodLiftStuds[station.Method] or 0
	base.CFrame = CFrame.new(station.Part.Position
		+ Vector3.new(0, lift
			+ DishModels.BottomDepth - DishModels.plateDrop(itemName), 0))

	if not DishModels.dress(base, itemName) then
		base:Destroy() --// no builder for this item: show nothing
		return
	end

	if burnt then
		for _, child in ipairs(base:GetChildren()) do
			if child:IsA("BasePart") then
				child.Color = Color3.fromRGB(45, 40, 38) --// charcoal ruin
			end
		end
	end

	base.Parent = workspace
	station.FoodDisplay = base
end

--// The RAW model cooks on the pan the whole way (owner ruling: no
--// assembled dish sitting on a grill - the finished product only
--// exists once collected); burning chars it black.
local function refreshStationFood(station)
	if station.State == "COOKING" or station.State == "PERFECT"
		or station.State == "OVERCOOKED" then
		if not station.FoodDisplay then
			setStationFood(station, station.RawName)
		end
	elseif station.State == "BURNT" then
		setStationFood(station, station.RawName, true)
	else
		clearStationFood(station)
	end
end

----------------------------------------------------------------
-- THE SMASH GAME (Config.RamenSmash - the name survives its ramen-only
-- debut; it is now game 2 of the minigame coin flip, playable on ANY
-- method). The 7s colour game IS the cook: the server simulates the
-- arcs, honours lag-rewound taps, and the score at the end decides the
-- dish (station.ForcedQuality). Ramen still never burns; a smash-
-- cooked grill/fry dish resumes normal aging after the game.
----------------------------------------------------------------
local RAMEN = Config.RamenSmash
local CARDS = Config.CardMatch
local PICK = Config.CookMinigamePick

--// THE MINIGAME ROLL (owner spec, Sep 2026): every gated cook rolls
--// which game it gets - even odds across the pool. Per-player streak
--// memory: each same-game pick in a row moves a slice of that game's
--// odds to the others (split evenly, capped at MaxBias); the moment
--// the streak breaks, the new game starts at the single-pick baseline.
local GAME_ARROW, GAME_SMASH, GAME_CARDS = 1, 2, 3
local GAME_COUNT = 3

local pickStreaks = {} --// [userId] = { Game = 1..GAME_COUNT, Count = n in a row }

local function rollCookGame(player)
	--// TUTORIAL SEAM: the tutor pins each teaching cook to one game
	--// (server-set workspace attribute; clients cannot write it)
	local tutorialForced = workspace:GetAttribute("TutorialForceGame")
	if typeof(tutorialForced) == "number"
		and tutorialForced >= 1 and tutorialForced <= GAME_COUNT then
		return tutorialForced
	end

	--// STUDIO KNOB (live-ignored): pin the roll while testing one game
	if RunService:IsStudio() then
		local forced = PICK.StudioForceGame or 0
		if forced >= 1 and forced <= GAME_COUNT then
			return forced
		end
	end

	local streak = pickStreaks[player.UserId]
	local weights = table.create(GAME_COUNT, 1 / GAME_COUNT)
	if streak then
		local bias = math.min(streak.Count * PICK.StreakBiasPerRepeat, PICK.MaxBias)
		bias = math.min(bias, weights[streak.Game]) --// never below zero
		weights[streak.Game] -= bias
		for game = 1, GAME_COUNT do
			if game ~= streak.Game then
				weights[game] += bias / (GAME_COUNT - 1)
			end
		end
	end

	local roll, acc, pick = math.random(), 0, GAME_COUNT
	for game = 1, GAME_COUNT do
		acc += weights[game]
		if roll <= acc then
			pick = game
			break
		end
	end

	if streak and streak.Game == pick then
		streak.Count += 1
	else
		pickStreaks[player.UserId] = { Game = pick, Count = 1 }
	end
	return pick
end

Players.PlayerRemoving:Connect(function(player)
	pickStreaks[player.UserId] = nil
end)

local ramenRemote = remotes:FindFirstChild("RamenSmashRemote")
if not ramenRemote then
	ramenRemote = Instance.new("RemoteEvent")
	ramenRemote.Name = "RamenSmashRemote"
	ramenRemote.Parent = remotes
end

local ramenSessions = {} --// [station] = session (see beginRamenSession)
local ramenToken = 0

--// Forward-declared: defined with the arrow-game section below, and
--// shared by both games - the smash's game-end grant lands the dish
--// in the cook's hands the same way the arrow's result does
local grantFromMinigame

--// Shortest angular distance, degrees
local function angDist(a, b)
	return math.abs(((a - b) + 180) % 360 - 180)
end

local function ramenQualityFor(points)
	if points >= RAMEN.PerfectPoints then
		return "Perfect"
	elseif points >= RAMEN.GoodPoints then
		return "Good"
	end
	return "Ruined" --// below mid = UNSERVABLE - dump it (owner ruling)
end

local function closeRamenSession(station, tellClient)
	local session = ramenSessions[station]
	if not session then return end
	ramenSessions[station] = nil
	if tellClient and session.Player and session.Player.Parent then
		ramenRemote:FireClient(session.Player, "Close", session.Token)
	end
end

local function beginRamenSession(station, player)
	--// The score is about to decide the dish, so aging PAUSES for the
	--// game (grill/fry windows come back at the end; ramen's never do)
	station.PerfectUntil = math.huge
	station.OvercookedUntil = math.huge
	station.BurntAt = math.huge

	ramenToken += 1
	local offset = math.random(0, 359) --// same layout, never the same start
	local session = {
		Player = player,
		Token = ramenToken,
		StartedAt = os.clock(),
		Score = 0,
		LastScoreAt = 0,
		Arcs = {},
	}
	local openArcs = {}
	for i, def in ipairs(RAMEN.Arcs) do
		session.Arcs[i] = {
			Angle = (def.StartDeg + offset) % 360,
			Size = def.SizeDeg,
			Points = def.Points,
			Base = def.Speed,
			Eff = def.Speed,
			Shrink = def.ShrinkPerHitDeg or 0,
			MinSize = def.MinSizeDeg or def.SizeDeg,
			Phases = def.PhasesThrough, --// arc index this one ghosts past
		}
		openArcs[i] = {
			SizeDeg = def.SizeDeg,
			Points = def.Points,
			Chips = def.Chips,
			Angle = session.Arcs[i].Angle,
			Speed = def.Speed,
		}
	end
	ramenSessions[station] = session

	ramenRemote:FireClient(player, "Open", {
		Token = session.Token,
		GameSeconds = RAMEN.GameSeconds,
		Arcs = openArcs,
	})

	--// THE SIMULATION: the server steps the arcs (overlapping arcs run
	--// at CollisionSlowMult) and snapshots the truth to the cook a few
	--// times a second; the client only extrapolates between snapshots
	task.spawn(function()
		local last = os.clock()
		local lastSnap = 0
		while ramenSessions[station] == session do
			task.wait(0.03)
			local now = os.clock()
			local dt = now - last
			last = now

			--// BUMPER ARCS (owner spec): arcs never overlap. On contact
			--// both REVERSE, get pushed apart to just-touching, and run
			--// slowed for BumpSlowSeconds.
			for i = 1, #session.Arcs do
				for j = i + 1, #session.Arcs do
					local a, b = session.Arcs[i], session.Arcs[j]
					local delta = ((b.Angle - a.Angle + 180) % 360) - 180
					local minGap = (a.Size + b.Size) / 2 + 2
					--// phasing pairs ghost through each other, no bump
					if a.Phases == j or b.Phases == i then
						minGap = -1
					end
					if math.abs(delta) < minGap then
						local sign = delta >= 0 and 1 or -1
						local push = (minGap - math.abs(delta)) / 2
						a.Angle = (a.Angle - sign * push) % 360
						b.Angle = (b.Angle + sign * push) % 360
						a.Base, b.Base = -a.Base, -b.Base
						a.BumpUntil = now + RAMEN.BumpSlowSeconds
						b.BumpUntil = now + RAMEN.BumpSlowSeconds
					end
				end
			end
			for _, arc in ipairs(session.Arcs) do
				arc.Eff = arc.Base * ((arc.BumpUntil or 0) > now
					and RAMEN.CollisionSlowMult or 1)
				arc.Angle = (arc.Angle + arc.Eff * dt) % 360
				--// short TRUE-position history (~0.7s) for lag-
				--// compensated taps - survives bounces honestly
				local hist = arc.Hist
				if not hist then
					hist = {}
					arc.Hist = hist
				end
				hist[#hist + 1] = { T = now, A = arc.Angle }
				if #hist > 24 then
					table.remove(hist, 1)
				end
			end

			if now - lastSnap >= 1 / RAMEN.SnapshotHz then
				lastSnap = now
				if player.Parent then
					local snap = {}
					for i, arc in ipairs(session.Arcs) do
						snap[i] = { Angle = arc.Angle, Speed = arc.Eff, Size = arc.Size }
					end
					ramenRemote:FireClient(player, "Sync", session.Token, snap)
				end
			end
		end
	end)

	--// ONE ENDING, TWO EXITS: the clock running out, or the score
	--// hitting PerfectPoints early (owner spec: a perfect score ends
	--// the game ON THE SPOT - the Tap handler calls session.Finish).
	--// Either way the server decides when the game is over, never the
	--// client.
	local function finishSession()
		local live = ramenSessions[station]
		if live ~= session then return end
		ramenSessions[station] = nil

		local quality = ramenQualityFor(session.Score)
		if quality == "Ruined" then
			--// UNSERVABLE: the station flips to the cleanup state (on
			--// ramen the labels say RUINED, everywhere else BURNT)
			station.ForcedQuality = nil
			if station.State ~= "IDLE" then
				station.State = "BURNT"
				refreshStationFood(station)
				refreshStationUi(station)
				refreshStationPrompt(station)
			end
		else
			station.ForcedQuality = quality
			--// A smash-cooked GRILL/FRY dish resumes normal aging from
			--// here - leave it sitting and it still degrades and burns
			--// (ForcedQuality only holds while the state is PERFECT).
			--// Ramen keeps its infinite windows: soup never burns.
			if station.Method ~= "Ramen" then
				local recipe = Config.Recipes[station.Dish]
				local timing = recipe and Config.Cooking[recipe.Timing]
				if timing then
					station.PerfectUntil = station.Elapsed + timing.PerfectWindow
					station.OvercookedUntil = station.PerfectUntil + timing.OvercookAfter
					station.BurntAt = station.OvercookedUntil + timing.BurntAfter
				end
			end
		end
		if player.Parent then
			ramenRemote:FireClient(player, "End", session.Token, session.Score, quality)
		end
		print(("[Kitchen] SMASH: %s scored %d point(s) - %s %s")
			:format(player.Name, session.Score, quality, tostring(station.Dish)))

		--// Like the arrow: a won game lands the dish straight in the
		--// cook's hands (after the verdict splash). Full hands leave it
		--// waiting on the station - E collects it at the scored tier.
		if quality ~= "Ruined" and player.Parent then
			task.delay(1.2, function()
				if station.ForcedQuality and not ramenSessions[station]
					and station.State == "PERFECT" and player.Parent then
					grantFromMinigame(station, player, station.ForcedQuality)
				end
			end)
		end
	end
	session.Finish = finishSession
	task.delay(RAMEN.GameSeconds, finishSession)
end

ramenRemote.OnServerEvent:Connect(function(player, action, token)
	if action ~= "Tap" then return end

	local station, session
	for s, sess in pairs(ramenSessions) do
		if sess.Token == token and sess.Player == player then
			station, session = s, sess
			break
		end
	end
	if not session then return end

	local now = os.clock()
	if now - session.StartedAt > RAMEN.GameSeconds then return end
	if now - (session.LastTapAt or 0) < RAMEN.ScoreCooldownSeconds then
		return --// machine-gun taps are ignored entirely
	end
	session.LastTapAt = now

	--// SERVER STATE RULES with FULL LAG COMPENSATION: the player's
	--// screen runs a whole round-trip behind this clock (display lag +
	--// return trip), so judge each arc where it ACTUALLY WAS then -
	--// looked up from its recorded history, which stays honest through
	--// bounces. GraceDeg is the only forgiveness; Studio's ~zero ping
	--// makes this an exact-edge test.
	local rewind = math.clamp(player:GetNetworkPing() * 2, 0, 0.4)
	local tapTime = now - rewind
	local best = nil
	for _, arc in ipairs(session.Arcs) do
		local angleThen = arc.Angle
		local hist = arc.Hist
		if hist and #hist > 0 then
			angleThen = hist[1].A --// oldest available as the floor
			for index = #hist, 1, -1 do
				if hist[index].T <= tapTime then
					angleThen = hist[index].A
					break
				end
			end
		end
		if angDist(angleThen, 0) <= arc.Size / 2 + RAMEN.GraceDeg then
			if not best or arc.Points > best.Points then
				best = arc
			end
		end
	end

	--// Both outcomes RE-ROLL the board (owner spec) - hits also shrink
	--// yellow/blue toward their floors
	local function rerollArcs(shrink)
		for index, arc in ipairs(session.Arcs) do
			if shrink and arc.Shrink > 0 then
				arc.Size = math.max(arc.Size - arc.Shrink, arc.MinSize)
			end
			--// fresh spot: off the pointer AND clear of already-placed
			--// arcs, so a re-roll never spawns a stack
			for _ = 1, 14 do
				local candidate = math.random(0, 359)
				local clear = angDist(candidate, 0) > arc.Size / 2 + 25
				if clear then
					for prior = 1, index - 1 do
						local other = session.Arcs[prior]
						if angDist(candidate, other.Angle)
							< (arc.Size + other.Size) / 2 + 8 then
							clear = false
							break
						end
					end
				end
				if clear then
					arc.Angle = candidate
					break
				end
			end
			--// fresh world: old positions must not judge new taps (a
			--// stale history could double-score across a re-roll)
			arc.Hist = nil
		end
		local snap = {}
		for i, arc in ipairs(session.Arcs) do
			snap[i] = { Angle = arc.Angle, Speed = arc.Eff, Size = arc.Size }
		end
		return snap
	end

	if best then
		session.Score += best.Points

		--// PERFECT ON THE SPOT (owner spec): reaching PerfectPoints
		--// ends the game immediately - no riding out the clock. The
		--// final +N still pops, then the ending takes over.
		if session.Score >= RAMEN.PerfectPoints then
			ramenRemote:FireClient(player, "Hit", token, session.Score, {
				Points = best.Points,
			})
			session.Finish()
			return
		end

		ramenRemote:FireClient(player, "Hit", token, session.Score, {
			Points = best.Points,
			Arcs = rerollArcs(true),
		})
	else
		--// A miss COSTS (floor 0) and scrambles the board anyway
		session.Score = math.max(session.Score - RAMEN.MissPenaltyPoints, 0)
		ramenRemote:FireClient(player, "Miss", token, session.Score, {
			Penalty = RAMEN.MissPenaltyPoints,
			Arcs = rerollArcs(false),
		})
	end
end)

----------------------------------------------------------------
-- THE CARD MATCH (Config.CardMatch): game 3 of the minigame roll -
-- memory pairs against the clock. The server deals Pairs from the
-- ACTIVE MAP's food icons (menu dishes + their raws: Diner art on the
-- Diner, Yamasaki art at Yamasaki), shows the board for the PEEK,
-- then validates every flip; pairs found decide the dish, and a full
-- sweep is Perfect on the spot. The full layout rides the "Open"
-- payload ON PURPOSE: the peek makes it public knowledge by design,
-- and every match is still judged here, never by the client.
----------------------------------------------------------------
local cardRemote = remotes:FindFirstChild("CardMatchRemote")
if not cardRemote then
	cardRemote = Instance.new("RemoteEvent")
	cardRemote.Name = "CardMatchRemote"
	cardRemote.Parent = remotes
end

local cardSessions = {} --// [station] = session (see beginCardSession)
local cardToken = 0

local function cardQualityFor(pairsFound)
	if pairsFound >= CARDS.PerfectPairs then
		return "Perfect"
	elseif pairsFound >= CARDS.GoodPairs then
		return "Good"
	elseif pairsFound >= CARDS.OvercookedPairs then
		return "Overcooked"
	end
	return "Ruined" --// barely remembered anything: bin it
end

local function closeCardSession(station, tellClient)
	local session = cardSessions[station]
	if not session then return end
	cardSessions[station] = nil
	if tellClient and session.Player and session.Player.Parent then
		cardRemote:FireClient(session.Player, "Close", session.Token)
	end
end

--// The ACTIVE map's food art, one entry per icon: every menu dish
--// plus its raw ingredient. Both maps stock 6 - more than Pairs asks.
local function cardIconPool()
	local icons, seen = {}, {}
	local menu = Config.MenuForMap(workspace:GetAttribute("MatchMapId"))
	for dishName in pairs(menu) do
		local recipe = Config.Recipes[dishName]
		if recipe then
			local raw = Config.Ingredients[recipe.Ingredient]
			for _, icon in ipairs({ recipe.Icon, raw and raw.Icon }) do
				if icon and icon ~= "" and not seen[icon] then
					seen[icon] = true
					table.insert(icons, icon)
				end
			end
		end
	end
	table.sort(icons) --// stable base order; the shuffle does the mixing
	return icons
end

local function beginCardSession(station, player)
	--// The result is about to decide the dish, so aging PAUSES for the
	--// game - same deal as the smash (windows restored at the finish)
	station.PerfectUntil = math.huge
	station.OvercookedUntil = math.huge
	station.BurntAt = math.huge

	cardToken += 1

	--// THE DEAL: draw Pairs icons from the map pool, double, shuffle
	local pool = cardIconPool()
	for i = #pool, 2, -1 do
		local j = math.random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local cards = {}
	for pair = 1, CARDS.Pairs do
		--// wrap if a future map's pool runs short of Pairs
		local icon = pool[(pair - 1) % math.max(#pool, 1) + 1] or ""
		table.insert(cards, icon)
		table.insert(cards, icon)
	end
	for i = #cards, 2, -1 do
		local j = math.random(i)
		cards[i], cards[j] = cards[j], cards[i]
	end

	local session = {
		Player = player,
		Token = cardToken,
		Cards = cards,
		Matched = {},     --// [index] = true once paired away
		FirstPick = nil,  --// index face-up waiting for its partner
		PairsFound = 0,
		PlayableAt = os.clock() + CARDS.PeekSeconds, --// peek first
		LockedUntil = 0,  --// mismatch flip-back lock
		LastFlipAt = 0,
	}
	cardSessions[station] = session

	cardRemote:FireClient(player, "Open", {
		Token = session.Token,
		Cards = cards,
		GameSeconds = CARDS.GameSeconds,
		PeekSeconds = CARDS.PeekSeconds,
	})

	--// ONE ENDING, TWO EXITS, same as the smash: the clock landing,
	--// or the board swept early (the Flip handler calls Finish)
	local function finishSession()
		local live = cardSessions[station]
		if live ~= session then return end
		cardSessions[station] = nil

		local quality = cardQualityFor(session.PairsFound)
		if quality == "Ruined" then
			--// UNSERVABLE: the station flips to the cleanup state (on
			--// ramen the labels say RUINED, everywhere else BURNT)
			station.ForcedQuality = nil
			if station.State ~= "IDLE" then
				station.State = "BURNT"
				refreshStationFood(station)
				refreshStationUi(station)
				refreshStationPrompt(station)
			end
		else
			station.ForcedQuality = quality
			--// Grill/fry dishes resume normal aging from here - ramen
			--// keeps its infinite windows (soup never burns)
			if station.Method ~= "Ramen" then
				local recipe = Config.Recipes[station.Dish]
				local timing = recipe and Config.Cooking[recipe.Timing]
				if timing then
					station.PerfectUntil = station.Elapsed + timing.PerfectWindow
					station.OvercookedUntil = station.PerfectUntil + timing.OvercookAfter
					station.BurntAt = station.OvercookedUntil + timing.BurntAfter
				end
			end
		end
		if player.Parent then
			cardRemote:FireClient(player, "End", session.Token, session.PairsFound, quality)
		end
		print(("[Kitchen] CARDS: %s matched %d pair(s) - %s %s")
			:format(player.Name, session.PairsFound, quality, tostring(station.Dish)))

		--// A won game lands the dish in the cook's hands after the
		--// verdict splash; full hands leave it for an E-collect
		if quality ~= "Ruined" and player.Parent then
			task.delay(1.2, function()
				if station.ForcedQuality and not cardSessions[station]
					and station.State == "PERFECT" and player.Parent then
					grantFromMinigame(station, player, station.ForcedQuality)
				end
			end)
		end
	end
	session.Finish = finishSession
	task.delay(CARDS.PeekSeconds + CARDS.GameSeconds, finishSession)
end

cardRemote.OnServerEvent:Connect(function(player, action, token, index)
	if action ~= "Flip" then return end

	local station, session
	for s, sess in pairs(cardSessions) do
		if sess.Token == token and sess.Player == player then
			station, session = s, sess
			break
		end
	end
	if not session then return end

	local now = os.clock()
	if now < session.PlayableAt then return end  --// still peeking
	if now < session.LockedUntil then return end --// mismatch flip-back
	if now - session.LastFlipAt < CARDS.FlipCooldownSeconds then return end
	session.LastFlipAt = now

	index = tonumber(index)
	if not index or index ~= math.floor(index) then return end
	if not session.Cards[index] then return end
	if session.Matched[index] or session.FirstPick == index then return end

	if not session.FirstPick then
		session.FirstPick = index
		cardRemote:FireClient(player, "Show", token, index)
		return
	end

	local first = session.FirstPick
	session.FirstPick = nil
	cardRemote:FireClient(player, "Show", token, index)

	if session.Cards[first] == session.Cards[index] then
		session.Matched[first] = true
		session.Matched[index] = true
		session.PairsFound += 1
		cardRemote:FireClient(player, "Match", token,
			{ A = first, B = index, Pairs = session.PairsFound })
		--// Perfect bar reached (or board swept): over on the spot
		if session.PairsFound >= CARDS.PerfectPairs
			or session.PairsFound >= CARDS.Pairs then
			session.Finish()
		end
	else
		session.LockedUntil = now + CARDS.MismatchLockSeconds
		cardRemote:FireClient(player, "Mismatch", token, { A = first, B = index })
	end
end)

local function clearStation(station)
	--// Every route out of cooking lands here - collected, binned, burnt,
	--// wiped by a grease fire - so one stop covers all of them.
	cookSoundStop(station)
	clearStationFood(station)
	closeRamenSession(station, true) --// a wiped pan ends its smash game
	closeCardSession(station, true)  --// ...and its card game
	station.ForcedQuality = nil
	station.CookGame = nil

	station.State = "IDLE"
	station.Dish = nil
	station.RawName = nil
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

	local rawName = tool:GetAttribute("Ingredient") --// read before it dies
	tool:Destroy() --// the raw ingredient is consumed

	--// Gated difficulties cook in one flat time - the minigame is the
	--// skill there; an ungated difficulty would keep the full timers
	local cookTime = timing.CookTime
	local gated = cookMinigameGated()
	if gated then
		cookTime = TIMING.MinigameCookSeconds
	end

	--// THE MINIGAME ROLL: every gated cook, any method, rolls its game.
	--// ALL of them share the same entry (owner spec): the pan cooks the
	--// flat MinigameCookSeconds, and E at the READY station opens the
	--// drawn game - arrow, smash, or card match (see beginCookSession).
	local cookGame = gated and rollCookGame(player) or nil

	station.State = "COOKING"
	station.Dish = dishName
	station.RawName = rawName
	station.Elapsed = 0
	station.CookTime = cookTime
	station.PerfectUntil = cookTime + timing.PerfectWindow
	station.OvercookedUntil = station.PerfectUntil + timing.OvercookAfter
	station.BurntAt = station.OvercookedUntil + timing.BurntAfter
	station.CookGame = cookGame

	if station.Method == "Ramen" then
		--// RAMEN NEVER BURNS (owner ruling: it is soup). The worst an
		--// ignored pot reaches is the trash tier, and it keeps forever.
		station.BurntAt = math.huge
	end

	--// Sizzle at the station, not in the player's ear: positional, and
	--// shared per method - see cookSoundStart's ref-counting above.
	cookSoundStart(station)

	refreshStationFood(station) --// the raw lands on the pan, visibly
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
	--// A smash-cooked dish's quality was decided by its score - but only
	--// while it still sits in the PERFECT state: a grill/fry dish left
	--// to age past its window degrades like any other cook
	local quality = (station.State == "PERFECT" and station.ForcedQuality)
		or (station.State == "PERFECT" and "Perfect" or "Overcooked")

	local tool = makeTool(recipe.Display, recipe.Icon, recipe.Color, {
		Dish = dishName,
		Quality = quality,
	})
	tool.Parent = character

	--// The perfect COLLECT is the skill moment - career and ultimate charge
	--// credit here, at the pan, not later at the table (owner call)
	if quality == "Perfect" then
		creditStat(player, "PerfectCooks", 1)
	elseif quality == "Good" then
		scoreOnly(player, "GoodCooks", 1) --// hidden score only
	else
		scoreOnly(player, "OvercookedCooks", 1) --// hidden score only
	end

	print(("[Kitchen] %s collected a %s %s"):format(player.Name, quality, dishName))
	clearStation(station)
end

----------------------------------------------------------------
-- THE COOK TIMING GAME (gated by Difficulty.Interactions.CookMinigame -
-- an ungated difficulty would keep window-collect and never see this).
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
--// (assigns the forward declaration above - the smash section calls it too)
function grantFromMinigame(station, player, quality)
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
	elseif quality == "Good" then
		scoreOnly(player, "GoodCooks", 1) --// hidden score only
	else
		scoreOnly(player, "OvercookedCooks", 1)
	end

	print(("[Kitchen] %s earned a %s %s off the minigame"):format(player.Name, quality, dishName))
	clearStation(station)
	return true
end

local function beginCookSession(station, player)
	--// SMASH and CARD MATCH cooks: the same E that would open the
	--// arrow opens the drawn game instead (owner spec - every game
	--// starts on the press at a READY station), and its result
	--// decides the dish
	local gameSessions, beginGame
	if station.CookGame == GAME_SMASH then
		gameSessions, beginGame = ramenSessions, beginRamenSession
	elseif station.CookGame == GAME_CARDS then
		gameSessions, beginGame = cardSessions, beginCardSession
	end
	if gameSessions then
		if gameSessions[station] then
			flash(station.Prompt, "Game in progress!", stationPromptText(station))
			return
		end
		if station.State == "BURNT" then
			collect(station, player) --// a ruined dish only dumps
			return
		end
		if station.ForcedQuality then
			--// Already played (hands were full at the grant): plain grab
			--// at the scored tier - unless it aged past PERFECT waiting
			grantFromMinigame(station, player,
				(station.State == "PERFECT" and station.ForcedQuality)
					or "Overcooked")
			return
		end
		beginGame(station, player) --// THIS press starts the game
		return
	end

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

	--// SERVER CLOCK with LAG REWIND (Sep 2026 fix): the client's arrow
	--// starts one network-trip late and the claim takes a trip back, so
	--// the player's screen runs a full ROUND-TRIP behind this clock.
	--// Judge the claim against where the arrow was THEN - without this,
	--// a seen-green judged a miss (and seen-yellow a lucky perfect) for
	--// anyone with real ping. Tolerance now absorbs jitter only.
	local rewind = math.clamp(player:GetNetworkPing() * 2, 0, 0.4)
	local expected = arrowAt(
		os.clock() - session.SwingStart - rewind, session.SweepSeconds)
	local tolerance = TIMING.StopToleranceSeconds / session.SweepSeconds
	local position = tonumber(claimed)
	if not position or math.abs(position - expected) > tolerance then
		position = expected --// dishonest (or hopeless) claims get the truth
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
			collect(station, player) --// ungated fallback: window-collect
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
				refreshStationFood(station) --// raw -> cooked -> charcoal
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

				--// The pans are frozen, so the sizzle stops with them. A
				--// blackout that still sounds like a working kitchen reads
				--// as a bug.
				cookSoundStop(station)
			else
				refreshStationPrompt(station)

				--// Anything mid-cook picks its sizzle back up
				if station.State == "COOKING" then
					cookSoundStart(station)
				end
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
