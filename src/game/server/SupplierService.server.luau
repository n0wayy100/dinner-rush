--[[
	Dinner Rush - SupplierService
	ServerScriptService.Server.SupplierService  (regular Script, server-side)

	Ordering ingredients, and the delivery that follows.

	  part tagged SupplierBoard ... prompt opens the order board
	  part tagged DeliveryZone .... where the truck pulls up and drops crates

	Flow: order at the board -> wait Difficulty[*].SupplierDeliverySeconds ->
	a truck arrives outside the pantry with one crate per ingredient ordered ->
	hold E on a crate to move it into the kitchen's stock -> crate vanishes.

	Stock itself is owned by KitchenService. This never touches it directly; it
	goes through ServerStorage.RestockIngredient, the entry point left for
	exactly this.

	The truck and crates are placeholder blocks. Only spawnTruck() and
	spawnCrate() change when the real models arrive.

	Published for the client at ReplicatedStorage.SupplierState:
	  Status     "IDLE" / "ORDERED" / "ARRIVED"
	  ArrivesIn  seconds remaining, 0 when not counting
	  Summary    "10x Raw Patty, 5x Raw Potato"
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Supplier] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

print("[Supplier] script started")

local SUPPLIER = Config.Supplier

----------------------------------------------------------------
-- Remote + published state
----------------------------------------------------------------
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local supplierRemote = remotes:FindFirstChild("SupplierRemote")
if not supplierRemote then
	supplierRemote = Instance.new("RemoteEvent")
	supplierRemote.Name = "SupplierRemote"
	supplierRemote.Parent = remotes
end

local SupplierState = ReplicatedStorage:FindFirstChild("SupplierState")
if not SupplierState then
	SupplierState = Instance.new("Folder")
	SupplierState.Name = "SupplierState"
	SupplierState.Parent = ReplicatedStorage
end

local delivery = {
	Status = "IDLE",
	ArrivesIn = 0,
	Summary = "",
	Order = nil,   -- { [ingredientName] = crateCount }
	Truck = nil,   -- Model holding the truck and its crates
	CratesLeft = 0,
	LingerLeft = 0,
	Cost = 0,      -- what the till paid, so it can be handed back if undelivered
}

local function publish()
	SupplierState:SetAttribute("Status", delivery.Status)
	SupplierState:SetAttribute("ArrivesIn", math.max(0, math.ceil(delivery.ArrivesIn)))
	SupplierState:SetAttribute("Summary", delivery.Summary)
end

publish()

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function resolvePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function firstTaggedPart(tag)
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			local part = resolvePart(instance)
			if part then
				return part
			end
			warn(("[Supplier] %s is tagged %s but has no BasePart"):format(instance:GetFullName(), tag))
		end
	end
	return nil
end

local function difficultyBlock()
	local bridge = ServerStorage:FindFirstChild("GetShiftInfo")
	local name = bridge and bridge:Invoke().Difficulty or "NORMAL"
	if not Config.IsValidDifficulty(name) then
		name = "NORMAL"
	end
	return Config.ForDifficulty(name)
end

--// Sorted so the board rows never jump around
local function ingredientNames()
	local names = {}
	for name in pairs(Config.Ingredients) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function orderSummary(order)
	local parts = {}
	for _, name in ipairs(ingredientNames()) do
		local crates = order[name] or 0
		if crates > 0 then
			table.insert(parts, ("%dx %s"):format(
				crates * SUPPLIER.UnitsPerCrate, Config.Ingredients[name].Display))
		end
	end
	return table.concat(parts, ", ")
end

----------------------------------------------------------------
-- The delivery
----------------------------------------------------------------
local deliveryZone = nil

local function clearTruck()
	if delivery.Truck then
		delivery.Truck:Destroy()
		delivery.Truck = nil
	end
	delivery.CratesLeft = 0
end

local function finishDelivery()
	clearTruck()
	delivery.Status = "IDLE"
	delivery.ArrivesIn = 0
	delivery.LingerLeft = 0
	delivery.Order = nil
	delivery.Summary = ""
	delivery.Cost = 0
	publish()
	print("[Supplier] delivery closed - the board is free again")
end

--// PLACEHOLDER PROP. Swap the block for your truck model here; nothing else
--// in this file cares what it looks like.
local function spawnTruck(container)
	local truck = Instance.new("Part")
	truck.Name = "DeliveryTruck"
	truck.Size = SUPPLIER.TruckSize
	truck.Color = SUPPLIER.TruckColor
	truck.Material = Enum.Material.SmoothPlastic
	truck.Anchored = true
	truck.CanCollide = false

	--// Parked behind the drop point, along the zone's facing
	truck.CFrame = deliveryZone.CFrame
		* CFrame.new(0, SUPPLIER.TruckSize.Y / 2, -(SUPPLIER.TruckSize.Z / 2 + 6))
	truck.Parent = container
	return truck
end

local function spawnCrate(container, index, total, ingredientName, crates)
	local data = Config.Ingredients[ingredientName]
	local units = crates * SUPPLIER.UnitsPerCrate

	local crate = Instance.new("Part")
	crate.Name = "Crate_" .. ingredientName
	crate.Size = SUPPLIER.CrateSize
	crate.Color = SUPPLIER.CrateColor
	crate.Material = Enum.Material.WoodPlanks
	crate.Anchored = true
	crate.CanCollide = false

	--// Laid out in a row across the drop point
	local offset = (index - (total + 1) / 2) * SUPPLIER.CrateSpacingStuds
	crate.CFrame = deliveryZone.CFrame * CFrame.new(offset, SUPPLIER.CrateSize.Y / 2, 0)
	crate.Parent = container

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(150, 34)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = true
	gui.Parent = crate

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	label.TextStrokeTransparency = 0.2
	label.Text = ("%s x%d"):format(data.Display, units)
	label.Parent = gui

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Unload"
	prompt.ObjectText = ("%s x%d"):format(data.Display, units)
	prompt.HoldDuration = SUPPLIER.CollectHoldSeconds
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = crate

	local taken = false
	prompt.Triggered:Connect(function(player)
		if taken then return end
		taken = true

		--// Stock belongs to KitchenService; this is the only way in
		local restock = ServerStorage:FindFirstChild("RestockIngredient")
		if restock then
			restock:Invoke(ingredientName, units)
		else
			warn("[Supplier] ServerStorage.RestockIngredient is missing - stock not updated")
		end

		print(("[Supplier] %s unloaded %s x%d"):format(player.Name, ingredientName, units))
		crate:Destroy()

		delivery.CratesLeft -= 1
		if delivery.CratesLeft <= 0 then
			finishDelivery()
		end
	end)
end

local function arrive()
	if not deliveryZone then
		warn("[Supplier] no DeliveryZone - the order cannot be delivered")
		finishDelivery()
		return
	end

	local container = Instance.new("Model")
	container.Name = "Delivery"
	container.Parent = workspace
	delivery.Truck = container

	spawnTruck(container)

	--// One crate per ingredient ordered, holding all of that ingredient's units
	local ordered = {}
	for _, name in ipairs(ingredientNames()) do
		if (delivery.Order[name] or 0) > 0 then
			table.insert(ordered, name)
		end
	end

	for index, name in ipairs(ordered) do
		spawnCrate(container, index, #ordered, name, delivery.Order[name])
	end

	delivery.CratesLeft = #ordered
	delivery.Status = "ARRIVED"
	delivery.ArrivesIn = 0
	delivery.LingerLeft = SUPPLIER.TruckLingerSeconds
	publish()

	print(("[Supplier] delivery arrived: %s (%d crate(s))"):format(delivery.Summary, #ordered))
end

----------------------------------------------------------------
-- Ordering
----------------------------------------------------------------
local function catalog()
	local items = {}
	for _, name in ipairs(ingredientNames()) do
		local data = Config.Ingredients[name]
		table.insert(items, {
			Name = name,
			Display = data.Display,
			Icon = data.Icon,
			UnitsPerCrate = SUPPLIER.UnitsPerCrate,
			MaxCrates = SUPPLIER.MaxCratesPerIngredient,
			Price = SUPPLIER.ChargeForOrders and (SUPPLIER.CratePrice[name] or 0) or 0,
		})
	end
	return items
end

supplierRemote.OnServerEvent:Connect(function(player, action, payload)
	if action ~= "Order" then return end
	if typeof(payload) ~= "table" then return end

	--// A wall screen can be clicked from anywhere on the map, so the range
	--// check the ProximityPrompt used to provide has to happen here instead.
	local board = firstTaggedPart("SupplierBoard")
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if board and root then
		local reach = Config.Interaction.PromptRangeStuds + 6
		if (board.Position - root.Position).Magnitude > reach then
			return
		end
	end

	--// One delivery at a time. The board says so, but never trust that.
	if delivery.Status ~= "IDLE" then
		supplierRemote:FireClient(player, "OrderDenied", "A delivery is already on its way!")
		return
	end

	local order, crates = {}, 0
	for _, name in ipairs(ingredientNames()) do
		local wanted = tonumber(payload[name]) or 0
		wanted = math.clamp(math.floor(wanted), 0, SUPPLIER.MaxCratesPerIngredient)
		order[name] = wanted
		crates += wanted
	end

	if crates <= 0 then
		supplierRemote:FireClient(player, "OrderDenied", "Order something first!")
		return
	end

	--// Paid out of the shared till, which ServiceLoop owns. The client shows
	--// a price, but only this check decides whether the order happens.
	local orderCost = 0
	if SUPPLIER.ChargeForOrders then
		local cost = 0
		for name, wanted in pairs(order) do
			cost += wanted * (SUPPLIER.CratePrice[name] or 0)
		end

		orderCost = cost

		local spend = ServerStorage:FindFirstChild("SpendFromTill")
		if not spend then
			warn("[Supplier] ServerStorage.SpendFromTill is missing - order allowed for free")
		elseif not spend:Invoke(cost, "supply order") then
			local balance = ServerStorage:FindFirstChild("GetTill")
			supplierRemote:FireClient(player, "OrderDenied",
				("Not enough money - need $%d, till has $%d"):format(
					cost, balance and balance:Invoke() or 0))
			return
		end
	end

	local diff = difficultyBlock()
	delivery.Cost = orderCost
	delivery.Order = order
	delivery.Summary = orderSummary(order)
	delivery.Status = "ORDERED"
	delivery.ArrivesIn = diff.SupplierDeliverySeconds
	publish()

	print(("[Supplier] %s ordered %s - arriving in %ds"):format(
		player.Name, delivery.Summary, math.ceil(delivery.ArrivesIn)))
end)

--// Money paid for food that never arrived comes back at the buzzer. Returns
--// the amount so ServiceLoop can bank it - the till stays ServiceLoop's to
--// change, this only reports what is owed.
--//   ServerStorage.RefundInFlightOrder:Invoke()  ->  number
local function refundInFlightOrder()
	if delivery.Status ~= "ORDERED" then
		return 0
	end

	local owed = delivery.Cost or 0
	print(("[Supplier] shift ended with an order still in transit - refunding %d"):format(owed))
	finishDelivery()
	return owed
end

do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "RefundInFlightOrder"
	bridge.OnInvoke = refundInFlightOrder
	bridge.Parent = ServerStorage
end

----------------------------------------------------------------
-- One clock
----------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	if delivery.Status == "ORDERED" then
		delivery.ArrivesIn -= dt
		if delivery.ArrivesIn <= 0 then
			arrive()
		else
			SupplierState:SetAttribute("ArrivesIn", math.max(0, math.ceil(delivery.ArrivesIn)))
		end

	elseif delivery.Status == "ARRIVED" then
		--// The truck does not wait forever; anything left goes with it
		delivery.LingerLeft -= dt
		if delivery.LingerLeft <= 0 then
			warn(("[Supplier] truck left with %d uncollected crate(s)"):format(delivery.CratesLeft))
			finishDelivery()
		end
	end
end)

----------------------------------------------------------------
-- Setup
----------------------------------------------------------------
task.spawn(function()
	local waited = 0
	local board

	while waited < 20 do
		board = firstTaggedPart("SupplierBoard")
		deliveryZone = firstTaggedPart("DeliveryZone")
		if board and deliveryZone then
			break
		end
		task.wait(0.5)
		waited += 0.5
	end

	if not board then
		warn("[Supplier] no part tagged SupplierBoard - ordering is disabled")
		return
	end
	if not deliveryZone then
		warn("[Supplier] no part tagged DeliveryZone - orders cannot be delivered")
	end

	--// No ProximityPrompt here on purpose: the wall screen is always on and
	--// clicked directly, so a floating "Open" bubble over it is just clutter.
	--// Clients ask for the catalogue when they build the screen instead.
	--
	--// Older builds DID put a prompt here, and one saved into the place file
	--// would linger forever. Clear any that exists so the board self-heals.
	for _, child in ipairs(board:GetChildren()) do
		if child:IsA("ProximityPrompt") then
			warn(("[Supplier] removing a stale %s prompt left on the board"):format(child.Name))
			child:Destroy()
		end
	end
	supplierRemote.OnServerEvent:Connect(function(player, action)
		if action == "RequestBoard" then
			supplierRemote:FireClient(player, "OpenBoard", catalog(), {
				Status = delivery.Status,
				Summary = delivery.Summary,
			})
		end
	end)

	print(("[Supplier] board ready at %s, delivery zone %s"):format(
		board:GetFullName(), deliveryZone and deliveryZone:GetFullName() or "MISSING"))
end)
