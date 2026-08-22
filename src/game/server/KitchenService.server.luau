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
local Players = game:GetService("Players")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Kitchen] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

print("[Kitchen] script started")

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

local STATE_COLOR = {
	COOKING = Color3.fromRGB(245, 184, 65),
	PERFECT = Color3.fromRGB(76, 175, 109),
	OVERCOOKED = Color3.fromRGB(219, 128, 60),
	BURNT = Color3.fromRGB(90, 80, 78),
}

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

local function isFull(player)
	return countCarried(player) >= Config.Kitchen.MaxCarriedItems
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
			("Hands full (max %d)"):format(Config.Kitchen.MaxCarriedItems))
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
-- Cook stations
----------------------------------------------------------------
local stations = {} --// list of station records, ticked by one Heartbeat

local function stationLabel(station)
	if station.State == "IDLE" then
		return ""
	end
	local recipe = Config.Recipes[station.Dish]
	local display = recipe and recipe.Display or station.Dish
	if station.State == "COOKING" then
		return ("%s - cooking"):format(display)
	elseif station.State == "PERFECT" then
		return ("%s - READY"):format(display)
	elseif station.State == "OVERCOOKED" then
		return ("%s - overcooked"):format(display)
	end
	return ("%s - BURNT"):format(display)
end

local function refreshStationUi(station)
	local gui = station.Gui
	gui.Enabled = station.State ~= "IDLE"
	if station.State == "IDLE" then
		return
	end

	station.Label.Text = stationLabel(station)
	station.Fill.BackgroundColor3 = STATE_COLOR[station.State] or STATE_COLOR.COOKING

	--// Bar fills while cooking, then holds full through the eating states so
	--// colour alone communicates the window
	local fraction = 1
	if station.State == "COOKING" and station.CookTime > 0 then
		fraction = math.clamp(station.Elapsed / station.CookTime, 0, 1)
	end
	station.Fill.Size = UDim2.fromScale(fraction, 1)
end

local function refreshStationPrompt(station)
	local prompt = station.Prompt
	if station.State == "IDLE" then
		prompt.ActionText = "Cook"
		prompt.ObjectText = ("%s station"):format(station.Method)
		prompt.HoldDuration = Config.Kitchen.StationLoadHoldSeconds
	elseif station.State == "COOKING" then
		prompt.ActionText = "Cooking..."
		prompt.ObjectText = stationLabel(station)
		prompt.HoldDuration = Config.Kitchen.CollectHoldSeconds
	elseif station.State == "BURNT" then
		prompt.ActionText = "Bin it"
		prompt.ObjectText = stationLabel(station)
		prompt.HoldDuration = Config.Kitchen.BurntCleanupSeconds
	else
		prompt.ActionText = "Collect"
		prompt.ObjectText = stationLabel(station)
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

	station.State = "COOKING"
	station.Dish = dishName
	station.Elapsed = 0
	station.CookTime = timing.CookTime
	station.PerfectUntil = timing.CookTime + timing.PerfectWindow
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
		--// Ruined. Binning it costs a little reputation via the served-dish
		--// path being denied entirely; the number lives in Config.
		print(("[Kitchen] %s binned a burnt %s"):format(player.Name, tostring(station.Dish)))
		clearStation(station)
		return
	end

	if isFull(player) then
		flash(station.Prompt, ("Hands full (max %d)"):format(Config.Kitchen.MaxCarriedItems),
			stationLabel(station))
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

	print(("[Kitchen] %s collected a %s %s"):format(player.Name, quality, dishName))
	clearStation(station)
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
	gui.Size = UDim2.fromOffset(180, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.5)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui

	local back = Instance.new("Frame")
	back.Position = UDim2.fromScale(0, 0.55)
	back.Size = UDim2.fromScale(1, 0.35)
	back.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = STATE_COLOR.COOKING
	fill.BorderSizePixel = 0
	fill.Parent = back

	local prompt = Instance.new("ProximityPrompt")
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = part

	local station = {
		Part = part,
		Method = method,
		State = "IDLE",
		Elapsed = 0,
		Gui = gui,
		Label = label,
		Fill = fill,
		Prompt = prompt,
		Disabled = false, --// set by the event bridge (grease fire); prompt is
		                  --// also turned off, this is belt-and-braces
	}

	prompt.Triggered:Connect(function(player)
		if station.Disabled then return end
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
			flash(prompt, "Not ready yet", stationLabel(station))

		else
			collect(station, player)
		end
	end)

	refreshStationPrompt(station)
	table.insert(stations, station)
	print(("[Kitchen] station ready: %s (%s)"):format(part:GetFullName(), method))
end

----------------------------------------------------------------
-- One clock for every station
----------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
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
					Busy = station.State ~= "IDLE",
					Disabled = station.Disabled == true,
				})
			end
			return list
		end

		local station = stations[tonumber(id) or -1]
		if not station then return false end

		if action == "CancelCook" then
			local wasBusy = station.State ~= "IDLE"
			if wasBusy then
				print(("[Kitchen] cook on the %s cancelled by event (station %d)")
					:format(station.Method, id))
			end
			clearStation(station)
			return wasBusy
		elseif action == "SetDisabled" then
			station.Disabled = value == true
			station.Prompt.Enabled = not station.Disabled
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

			print(("[Kitchen] ready: %d fridge(s), %d shelf/shelves, %d station(s)")
				:format(#fridges, #shelves, #cookers))
			return
		end

		task.wait(0.5)
		waited += 0.5
	end

	warn("[Kitchen] no Fridge/DryShelf/CookStation tags found in Workspace - cooking is disabled")
end)
