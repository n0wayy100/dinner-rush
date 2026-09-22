--[[
	Dinner Rush - PassService
	ServerScriptService.Server.PassService   (regular Script, server-side)

	THE PASS. The counter between the kitchen and the floor, and the only route
	a dish can take to a customer.

	Build contract:
	  Tag  PassSlot  on each plate. Either shape works:
	     a Model wrapping the plate -> set its PrimaryPart
	     the plate part or UNION itself -> nothing else needed
	  (A Union is a BasePart, so a one-union plate needs no special handling.)
	  Anchored. Optional attribute  Order  (number) - only labels it in logs.

	The loop:
	  EMPTY   plate on the counter          -> cook walks up holding a dish
	  PLATED  plate + food on the counter   -> waiter takes it
	  CARRIED plate hidden, a clone is the waiter's Tool
	  SERVED  plate + food sitting on the table in front of a customer
	  EMPTY   again, once that table's payment has been COLLECTED

	THE PLATE ECONOMY: however many PassSlot models exist is the ceiling on
	dishes in flight. Owner's ruling is that a plate frees on payment
	collection, so an uncollected payment holds a plate. Every other way a
	plate could be lost - carrier quits, carrier dies, dish binned, party
	storms out, shift ends - returns it, or the kitchen would slowly jam.

	Bridges published to ServerStorage (house pattern):
	  PassReturnPlate:Invoke(slotId)          -> plate home, empty
	  PassPlaceOnTable:Invoke(slotId, cframe) -> plate to the table, keeps food
	  PassStats:Invoke()                      -> { Total, Empty, Plated, Out }
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local DishModels = require(ServerStorage:WaitForChild("Shared"):WaitForChild("DishModels"))

local SLOT_TAG = "PassSlot"

----------------------------------------------------------------
-- SLOTS
----------------------------------------------------------------

--// slotId -> slot record
local slots = {}
local nextSlotId = 0

local function taggedInWorkspace(tag)
	local found = {}
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			table.insert(found, instance)
		end
	end
	return found
end

--// Every BasePart in a tagged thing, INCLUDING the thing itself when the
--// plate was tagged directly rather than wrapped in a Model.
--//
--// A Union is a BasePart (UnionOperation inherits from it), so a plate built
--// as a single union needs no special handling anywhere in this file.
local function partsOf(root)
	local parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

--// Biggest part is the best guess at "the plate" when PrimaryPart is unset
local function largestPart(root)
	local best, bestVolume = nil, -1
	for _, part in ipairs(partsOf(root)) do
		local size = part.Size
		local volume = size.X * size.Y * size.Z
		if volume > bestVolume then
			best, bestVolume = part, volume
		end
	end
	return best
end

--// Half the part's height along WORLD Y, whatever its own rotation is.
--//
--// BasePart has no GetExtentsSize (that is a Model method), and Size is the
--// LOCAL box - useless on a union whose axes are rotated. This projects the
--// box's three half-extents onto world up, which is the standard way to get
--// an axis-aligned bound from an oriented one.
local function worldHalfHeight(part)
	local cf, size = part.CFrame, part.Size
	return math.abs(cf.RightVector.Y) * (size.X / 2)
		+ math.abs(cf.UpVector.Y) * (size.Y / 2)
		+ math.abs(cf.LookVector.Y) * (size.Z / 2)
end

--// The part a Tool will use as its Handle
local function handleOf(root)
	if root:IsA("Model") then
		return root.PrimaryPart or largestPart(root)
	end
	return root:IsA("BasePart") and root or nil
end

----------------------------------------------------------------
-- SHOW / HIDE
--
-- A carried plate is hidden rather than destroyed: the slot's model is the
-- one canonical plate, so it can never be duplicated or lost by accident.
-- Original transparencies are remembered so a glass or patterned plate comes
-- back looking like itself.
----------------------------------------------------------------

local function snapshotTransparency(slot)
	slot.Transparency = {}
	for _, part in ipairs(partsOf(slot.Root)) do
		slot.Transparency[part] = part.Transparency
	end
end

--// Clients read this to decide whether an EMPTY plate is worth prompting
--// about. Rendering only - the server still validates every Triggered.
local function publishState(slot)
	slot.Root:SetAttribute("PassState", slot.State)
end

local function setShown(slot, shown)
	for part, original in pairs(slot.Transparency) do
		if part.Parent then
			part.Transparency = shown and original or 1
		end
	end
	if slot.Food then
		--// A dressed portion keeps its base invisible; the meal parts
		--// under it follow the plate's hide/show
		local dressed = slot.Food:GetAttribute("Dressed")
		slot.Food.Transparency = (not shown or dressed) and 1 or 0
		for _, child in ipairs(slot.Food:GetDescendants()) do
			if child:IsA("BasePart") then
				child.Transparency = shown and 0 or 1
			end
		end
	end
	slot.Prompt.Enabled = shown
end

----------------------------------------------------------------
-- FOOD
----------------------------------------------------------------

--// Placeholder portion in the recipe's colour. Swap this one function for a
--// clone of a real food model when the art exists - nothing else changes.
local function makeFood(dishName)
	local recipe = Config.Recipes[dishName]
	if not recipe then return nil end

	local food = Instance.new("Part")
	food.Name = "Food"
	food.Shape = Enum.PartType.Cylinder
	food.Size = Config.Pass.FoodSize
	food.Color = recipe.Color
	food.Material = Enum.Material.SmoothPlastic
	food.TopSurface = Enum.SurfaceType.Smooth
	food.BottomSurface = Enum.SurfaceType.Smooth
	food.CanCollide = false
	food.Massless = true
	food:SetAttribute("Dish", dishName)
	return food
end

--// WHERE THE PORTION SITS, measured ONCE while the plate is resting flat on
--// the counter, in WORLD space, then stored as a rigid offset from the plate.
--//
--// Measuring in world space matters: a union's local +Y is whatever its
--// geometry baked in, so "up" in the plate's own axes points somewhere
--// arbitrary. World-up is the only axis that means what it says. Because the
--// result is a rigid offset, the portion then follows the plate correctly
--// into a player's hand and onto the table.
--//
--// Roblox cylinders run along X, so a portion lying flat needs the quarter turn.
local function measureFoodOffset(platePart)
	local nudge = Config.Pass.FoodOffset
	local lift = (Config.Pass.FoodSize.X / 2) + Config.Pass.FoodLiftStuds

	local halfHeight = worldHalfHeight(platePart)

	local world = CFrame.new(platePart.Position
			+ Vector3.new(nudge.X, halfHeight + lift + nudge.Y, nudge.Z))
		* CFrame.Angles(0, 0, math.rad(90))

	return platePart.CFrame:ToObjectSpace(world)
end

local function attachFood(slot, dishName)
	if slot.Food then
		slot.Food:Destroy()
		slot.Food = nil
	end

	local food = makeFood(dishName)
	if not food then return end

	food.Anchored = true
	food.CFrame = slot.Part.CFrame * slot.FoodOffset

	--// Composed cartoon meal (DishModels): rebuilt UPRIGHT at the same
	--// spot (the 90-degree flat turn only suits the bare cylinder),
	--// dropped per-dish so every model sits flush on the plate, dressed,
	--// and the cylinder becomes an invisible base. Children of Food, so
	--// clone/destroy/hide all carry the whole meal.
	food.CFrame = CFrame.new(food.Position
		- Vector3.new(0, DishModels.plateDrop(dishName), 0))
	if DishModels.dress(food, dishName) then
		food.Transparency = 1
		food:SetAttribute("Dressed", true)
	else
		food.CFrame = slot.Part.CFrame * slot.FoodOffset --// bare cylinder lies flat
	end

	food.Parent = slot.Root
	slot.Food = food
end

local function clearFood(slot)
	if slot.Food then
		slot.Food:Destroy()
		slot.Food = nil
	end
end

----------------------------------------------------------------
-- PROMPT TEXT
----------------------------------------------------------------

local function dishDisplay(dishName)
	local recipe = Config.Recipes[dishName]
	return recipe and recipe.Display or tostring(dishName)
end

local function refreshPrompt(slot)
	local prompt = slot.Prompt
	if slot.State == "EMPTY" then
		prompt.ActionText = "Plate up"
		prompt.ObjectText = "Empty plate"
		prompt.HoldDuration = Config.Pass.PlaceHoldSeconds
	elseif slot.State == "PLATED" then
		prompt.ActionText = "Take"
		prompt.ObjectText = ("%s (%s)"):format(dishDisplay(slot.Dish), slot.Quality or "?")
		prompt.HoldDuration = Config.Pass.TakeHoldSeconds
	else
		--// CARRIED or SERVED: the plate is not on the counter, so there is
		--// nothing to offer. Disabling here rather than relying on setShown
		--// having run first means the state alone decides it.
		prompt.ActionText = ""
		prompt.ObjectText = ""
		prompt.Enabled = false
	end
end

--// Briefly says why a prompt did nothing, then restores it
local function flash(slot, message)
	slot.Prompt.ObjectText = message
	task.delay(1.5, function()
		if slot.Prompt.Parent then
			refreshPrompt(slot)
		end
	end)
end

----------------------------------------------------------------
-- STATE CHANGES
----------------------------------------------------------------

local function goEmpty(slot)
	slot.State = "EMPTY"
	slot.Dish = nil
	slot.Quality = nil
	slot.HeldBy = nil
	clearFood(slot)
	slot.Root:PivotTo(slot.Home)
	setShown(slot, true)
	refreshPrompt(slot)
	publishState(slot)
end

local function goPlated(slot, dishName, quality)
	slot.State = "PLATED"
	slot.Dish = dishName
	slot.Quality = quality
	slot.HeldBy = nil
	--// Pivot first: the food is placed relative to the plate's CURRENT
	--// position, so moving the model afterwards would leave it behind.
	slot.Root:PivotTo(slot.Home)
	attachFood(slot, dishName)
	setShown(slot, true)
	refreshPrompt(slot)
	publishState(slot)
end

local function goCarried(slot, player)
	slot.State = "CARRIED"
	slot.HeldBy = player
	clearFood(slot)
	setShown(slot, false)
	refreshPrompt(slot)
	publishState(slot)
end

----------------------------------------------------------------
-- THE HELPER'S PASS VERBS (HelperService). The Helper takes the WHOLE
-- plate like a waiter would: the slot goes CARRIED with no holder (the
-- reclaim sweep only matches real leavers), the plate lands on the
-- table through the normal serve, and frees on payment collection.
-- HelperReturnDish sends it home when a delivery dies mid-trip.
----------------------------------------------------------------
do
	local snapshot = Instance.new("BindableFunction")
	snapshot.Name = "HelperPassSnapshot"
	snapshot.OnInvoke = function()
		local plated = {}
		for slotId, slot in pairs(slots) do
			if slot.State == "PLATED" then
				table.insert(plated, {
					SlotId = slotId,
					Dish = slot.Dish,
					Quality = slot.Quality,
					Position = slot.Part and slot.Part.Position,
				})
			end
		end
		return plated
	end
	snapshot.Parent = ServerStorage

	local take = Instance.new("BindableFunction")
	take.Name = "HelperTakeDish"
	take.OnInvoke = function(slotId)
		local slot = slots[slotId]
		if not slot or slot.State ~= "PLATED" then return nil end
		local dish, quality = slot.Dish, slot.Quality
		goCarried(slot, nil) --// plate travels with the Helper, holderless
		print(("[Pass] the Helper took %s (plate and all) from slot %s")
			:format(tostring(dish), tostring(slotId)))
		return dish, quality
	end
	take.Parent = ServerStorage

	local giveBack = Instance.new("BindableFunction")
	giveBack.Name = "HelperReturnDish"
	giveBack.OnInvoke = function(slotId)
		local slot = slots[slotId]
		if slot and slot.State == "CARRIED" and slot.HeldBy == nil then
			goEmpty(slot)
			return true
		end
		return false
	end
	giveBack.Parent = ServerStorage

	--// The Sous Chef skill (SkillService) COOKS and plates at the pass like a
	--// player would, then leaves - a waiter/player/Helper carries it out. Finds
	--// a free plate and plates the cooked dish on it; false if the pass is full.
	local plate = Instance.new("BindableFunction")
	plate.Name = "HelperPlateDish"
	plate.OnInvoke = function(dishName, quality)
		if not dishName then return false end
		for _, slot in pairs(slots) do
			if slot.State == "EMPTY" then
				goPlated(slot, dishName, quality or "Good")
				print(("[Pass] the Sous Chef plated %s (%s) on slot %s")
					:format(tostring(dishName), tostring(quality), tostring(slot.Id)))
				return true
			end
		end
		return false --// every plate is in use
	end
	plate.Parent = ServerStorage
end

----------------------------------------------------------------
-- CARRY HELPERS
----------------------------------------------------------------

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

--// A dish that is NOT already on a plate - the only thing worth plating
local function findUnplatedDish(player)
	return eachCarried(player, function(tool)
		if tool:GetAttribute("Dish") and not tool:GetAttribute("PlateSlot") then
			return tool
		end
		return nil
	end)
end

local function countCarried(player)
	local count = 0
	eachCarried(player, function(tool)
		if tool:GetAttribute("Ingredient") or tool:GetAttribute("Dish") then
			count += 1
		end
		return nil
	end)
	return count
end

----------------------------------------------------------------
-- BUILDING THE CARRIED PLATE
--
-- The Tool is a clone of the slot's own model, so what a waiter carries is
-- the plate the owner built, not a stand-in. A Tool needs one BasePart named
-- Handle; everything else welds to it.
----------------------------------------------------------------

local function buildPlateTool(slot, dishName, quality)
	local recipe = Config.Recipes[dishName]
	if not recipe then return nil end

	local tool = Instance.new("Tool")
	tool.Name = recipe.Display
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	if recipe.Icon and recipe.Icon ~= "" and recipe.Icon ~= "rbxassetid://0" then
		tool.TextureId = recipe.Icon
	end

	--// Dish + Quality keep the existing serve contract intact; PlateSlot is
	--// what tells ServiceLoop which plate to send home later.
	tool:SetAttribute("Dish", dishName)
	tool:SetAttribute("Quality", quality)
	tool:SetAttribute("PlateSlot", slot.Id)

	local clone = slot.Root:Clone()

	--// The clone inherits the slot's PassSlot tag, and the added-instance
	--// signal would register the CARRIED plate as a brand-new slot with its
	--// own floating prompt. Untag it - this copy is scenery, not a slot.
	CollectionService:RemoveTag(clone, SLOT_TAG)
	for _, descendant in ipairs(clone:GetDescendants()) do
		CollectionService:RemoveTag(descendant, SLOT_TAG)
	end

	--// STRIP EVERYTHING THAT IS NOT GEOMETRY.
	--//
	--// The plate on the counter carries its ProximityPrompt and its portion as
	--// children, so a naive clone hands the player a working "Take" prompt that
	--// follows them around forever - the slot's own prompt is correctly off, but
	--// the stowaway on the tool looks identical and never updates. Same story
	--// for the food: a second portion would sit inside the fresh one.
	for _, descendant in ipairs(clone:GetDescendants()) do
		local junk = descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
			or descendant:IsA("LayerCollector")   --// Billboard/Surface GUIs
			or descendant:IsA("LuaSourceContainer")
			or (descendant:IsA("BasePart") and descendant.Name == "Food")
		if junk then
			descendant:Destroy()
		end
	end

	--// The slot is visible when this runs, but a reclaim could race it. Copy
	--// the remembered transparencies across so a carried plate is never a
	--// ghost. GetDescendants order is stable between a model and its clone.
	local originals = partsOf(slot.Root)
	local copies = partsOf(clone)
	for index, original in ipairs(originals) do
		local copy = copies[index]
		if copy then
			copy.Transparency = slot.Transparency[original] or 0
		end
	end

	local plate = handleOf(clone)
	if not plate then
		clone:Destroy()
		tool:Destroy()
		return nil
	end

	--// Food rides the clone, positioned before anything is unanchored.
	--// Same dressing as the counter portion: composed meal upright,
	--// invisible base; bare cylinder flat if no builder exists.
	local food = makeFood(dishName)
	if food then
		food.Anchored = true
		food.CFrame = plate.CFrame * slot.FoodOffset
		local upright = CFrame.new(food.Position
			- Vector3.new(0, DishModels.plateDrop(dishName), 0))
		food.CFrame = upright
		if DishModels.dress(food, dishName) then
			food.Transparency = 1
		else
			food.CFrame = plate.CFrame * slot.FoodOffset
		end
		food.Parent = clone
	end

	--// THE HANDLE IS ITS OWN PART, and this matters.
	--//
	--// Tool.Grip rotates the Handle's LOCAL axes against the hand. A union's
	--// local axes are whatever its geometry baked in - almost never the plate's
	--// flat plane - so gripping the union directly means guessing angles against
	--// a frame nobody can see, and every guess looks wrong in a different way.
	--//
	--// Instead: an invisible handle with IDENTITY rotation, created while the
	--// plate is sitting flat on the counter. The welds bake "flat" in, so grip
	--// angles are measured from how the plate looks at rest - which is the
	--// thing the owner can actually reason about.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.2, 0.4)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Anchored = true

	--// Sits UNDER the plate, not in the middle of it: the hand should be a
	--// palm beneath a plate, not a fist through one. Measured world-aligned
	--// so a rotated union still gets a sensible drop.
	local under = worldHalfHeight(plate) + Config.Pass.HandleDropStuds
	handle.CFrame = CFrame.new(plate.Position - Vector3.new(0, under, 0))
	handle.Parent = tool

	local parts = partsOf(clone)

	--// Reparent everything to the Tool while still anchored, weld, and only
	--// then let physics have it. Unanchoring first drops the plate on the floor.
	for _, part in ipairs(parts) do
		part.Parent = tool
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = handle
	end

	handle.Anchored = false
	for _, part in ipairs(parts) do
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
	end

	--// A Tool's Handle is welded to the hand through Grip. Identity leaves a
	--// flat plate standing on its edge, so the plate needs tipping over.
	--// Purely cosmetic - all of it is Config, none of it affects the loop.
	local angles = Config.Pass.GripAngles
	tool.Grip = CFrame.new(Config.Pass.GripOffset)
		* CFrame.Angles(
			math.rad(angles.X),
			math.rad(angles.Y),
			math.rad(angles.Z))

	--// A tagged MODEL leaves an empty husk here once its parts moved to the
	--// Tool - throw it away. A plate tagged as a BARE PART **is** one of those
	--// moved parts, so destroying it would delete the plate out of the
	--// player's hand (the Yamasaki MeshPart plates found this the hard way).
	if not clone:IsA("BasePart") then
		clone:Destroy()
	end
	return tool
end

----------------------------------------------------------------
-- INTERACTION
----------------------------------------------------------------

local function onTriggered(slot, player)
	if slot.State == "EMPTY" then
		local tool = findUnplatedDish(player)
		if not tool then
			flash(slot, "Bring a cooked dish")
			return
		end

		local dishName = tool:GetAttribute("Dish")
		local quality = tool:GetAttribute("Quality") or "Overcooked"
		tool:Destroy() --// the bare dish becomes the plated one

		goPlated(slot, dishName, quality)
		print(("[Pass] %s plated %s (%s) on slot %d")
			:format(player.Name, dishName, quality, slot.Id))

	elseif slot.State == "PLATED" then
		--// Per-player limit: THIRD HAND! raises it via the CarryLimit attribute
		local carryLimit = player:GetAttribute("CarryLimit") or Config.Kitchen.MaxCarriedItems
		if countCarried(player) >= carryLimit then
			flash(slot, ("Hands full (max %d)"):format(carryLimit))
			return
		end

		local character = player.Character
		if not character then return end

		local tool = buildPlateTool(slot, slot.Dish, slot.Quality)
		if not tool then
			flash(slot, "Plate is broken - tell the owner")
			warn(("[Pass] could not build a tool from slot %d (%s)")
				:format(slot.Id, slot.Root:GetFullName()))
			return
		end

		local dishName = slot.Dish
		tool.Parent = character
		goCarried(slot, player)
		print(("[Pass] %s took %s from slot %d"):format(player.Name, dishName, slot.Id))
	end
end

----------------------------------------------------------------
-- SETUP
----------------------------------------------------------------

--// Accepts either shape, because both are reasonable things to tag:
--//   a Model wrapping the plate  -> uses its PrimaryPart
--//   the plate part/union itself -> uses itself
--// A plate built as one Union is a BasePart, so tagging it directly is fine.
local function setupSlot(root)
	local part = handleOf(root)

	if not part then
		warn(("[Pass] %s is tagged %s but contains no BasePart - skipped")
			:format(root:GetFullName(), SLOT_TAG))
		return
	end

	if root:IsA("Model") then
		if not root.PrimaryPart then
			warn(("[Pass] %s has no PrimaryPart - using '%s' (%s). Set PrimaryPart to be sure.")
				:format(root:GetFullName(), part.Name, part.ClassName))
		end
		--// PivotTo is only predictable with one set
		root.PrimaryPart = part
	end

	nextSlotId += 1
	local slot = {
		Id = nextSlotId,
		Order = tonumber(root:GetAttribute("Order")),
		Root = root,
		Part = part,
		Home = root:GetPivot(),
		State = "EMPTY",
		Dish = nil,
		Quality = nil,
		Food = nil,
		HeldBy = nil,
	}

	--// Measured now, while the plate is anchored flat on the counter. Every
	--// later placement reuses it, so the portion stays put in a hand and on
	--// a table.
	slot.FoodOffset = measureFoodOffset(part)

	--// A leftover prompt from an earlier run of this script would keep
	--// answering E with stale text forever, because nothing else tracks it.
	local stale = part:FindFirstChild("Pass")
	if stale then
		stale:Destroy()
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Pass"
	--// Tight for the same reason cook stations are: six plates in a row would
	--// otherwise all answer one keypress.
	prompt.MaxActivationDistance = Config.Pass.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Parent = part
	slot.Prompt = prompt

	--// CHEF PASSIVE: taking a plated dish off the pass counts as a collect
	--// hold too (same shared-prompt scaling trick as the cook stations)
	prompt.PromptButtonHoldBegan:Connect(function(player)
		local mult = player:GetAttribute("CollectHoldMult") or 1
		if mult ~= 1 and slot.State == "PLATED" then
			prompt.HoldDuration = Config.Pass.TakeHoldSeconds * mult
		end
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		refreshPrompt(slot)
	end)

	snapshotTransparency(slot)
	slots[slot.Id] = slot
	refreshPrompt(slot)
	publishState(slot)

	prompt.Triggered:Connect(function(player)
		onTriggered(slot, player)
	end)

	print(("[Pass] slot %d ready: %s (%s)")
		:format(slot.Id, root:GetFullName(), part.ClassName))
end

--// One malformed plate must not take the other five with it. Without this,
--// a single error in setupSlot leaves NO slots registered, and since plating
--// is mandatory the whole shift becomes unplayable with no obvious cause.
local function safeSetup(instance)
	local ok, err = pcall(setupSlot, instance)
	if not ok then
		warn(("[Pass] %s failed to set up and was skipped: %s")
			:format(instance:GetFullName(), tostring(err)))
	end
end

for _, model in ipairs(taggedInWorkspace(SLOT_TAG)) do
	safeSetup(model)
end

CollectionService:GetInstanceAddedSignal(SLOT_TAG):Connect(function(model)
	if model:IsDescendantOf(workspace) then
		safeSetup(model)
	end
end)

if nextSlotId == 0 then
	warn(("[Pass] no %s models found - dishes cannot be plated, and with "):format(SLOT_TAG)
		.. "Config.Pass.RequirePlateToServe nothing can be served either")
else
	print(("[Pass] %d plate(s) in circulation"):format(nextSlotId))
end

----------------------------------------------------------------
-- SERVED TABLE PLATES (unlimited-plate model, Sep 19)
--
-- The counter used to run dry: a plate was tied up from plating until the
-- table paid. Now serving spawns an INDEPENDENT plate on the table and the
-- slot is freed instantly - so the counter never runs out however many
-- meals are in flight. Each served plate is tracked by a string handle and
-- destroyed when its table's payment is collected (or the shift ends).
----------------------------------------------------------------
local servedPlates = {}       --// handle -> the anchored table plate model
local nextServedId = 0
local SERVED_TAG = "ServedPlate" --// so plate placement never stacks on one

--// An anchored copy of a slot's plate, dressed with the dish, planted flat
--// on the table at `cframe`. Mirrors buildPlateTool's clone/strip/restore,
--// minus the tool and grip - this one just sits there.
local function makeTablePlate(slot, dishName, cframe)
	local clone = slot.Root:Clone()

	CollectionService:RemoveTag(clone, SLOT_TAG)
	for _, descendant in ipairs(clone:GetDescendants()) do
		CollectionService:RemoveTag(descendant, SLOT_TAG)
	end

	for _, descendant in ipairs(clone:GetDescendants()) do
		local junk = descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
			or descendant:IsA("LayerCollector")
			or descendant:IsA("LuaSourceContainer")
			or (descendant:IsA("BasePart") and descendant.Name == "Food")
		if junk then
			descendant:Destroy()
		end
	end

	--// Restore visibility (the slot was hidden while CARRIED)
	local originals = partsOf(slot.Root)
	local copies = partsOf(clone)
	for index, original in ipairs(originals) do
		if copies[index] then
			copies[index].Transparency = slot.Transparency[original] or 0
		end
	end

	local plate = handleOf(clone)
	if not plate then
		clone:Destroy()
		return nil
	end

	--// Position: caller's spot, plate's resting rotation. Then lift so the
	--// plate's real bottom rests flush (mesh plates bake odd pivots).
	clone:PivotTo(CFrame.new(cframe.Position) * slot.Home.Rotation)
	local bottom = plate.Position.Y - worldHalfHeight(plate)
	local sink = cframe.Position.Y - bottom
	if math.abs(sink) > 0.01 then
		clone:PivotTo(clone:GetPivot() + Vector3.new(0, sink, 0))
	end

	--// The dish, positioned relative to THIS plate, same recipe as the slot
	local food = makeFood(dishName)
	if food then
		food.Anchored = true
		food.CFrame = plate.CFrame * slot.FoodOffset
		food.CFrame = CFrame.new(food.Position
			- Vector3.new(0, DishModels.plateDrop(dishName), 0))
		if DishModels.dress(food, dishName) then
			food.Transparency = 1
		else
			food.CFrame = plate.CFrame * slot.FoodOffset
		end
		food.Parent = clone
	end

	for _, part in ipairs(partsOf(clone)) do
		part.Anchored = true
		part.CanCollide = false
	end

	--// tagged so ServiceLoop's plate-placement ray never sets the next
	--// dish on top of this one; NOT PassSlot, so it never becomes a slot
	CollectionService:AddTag(plate, SERVED_TAG)
	clone.Parent = slot.Root.Parent
	return clone
end

----------------------------------------------------------------
-- RECLAIM
--
-- Every way a plate could leave the world without coming back.
----------------------------------------------------------------

local function returnPlate(slotId, why)
	local slot = slots[slotId]
	if not slot then
		warn(("[Pass] return asked for unknown slot %s"):format(tostring(slotId)))
		return false
	end
	if slot.State == "EMPTY" then
		return true --// already home; harmless to ask twice
	end

	goEmpty(slot)
	print(("[Pass] slot %d back on the pass (%s)"):format(slotId, why or "returned"))
	return true
end

--// A carried plate whose Tool no longer exists anywhere is lost - sweep it
--// home. Covers dying, disconnecting, and anything that destroys a Tool.
local function reclaimFrom(player, why)
	for _, slot in pairs(slots) do
		if slot.State == "CARRIED" and slot.HeldBy == player then
			returnPlate(slot.Id, why)
		end
	end
end

if Config.Pass.ReclaimOnPlayerLeave then
	Players.PlayerRemoving:Connect(function(player)
		reclaimFrom(player, "carrier left")
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function()
			--// Tools are destroyed on death, so the plate would vanish with it
			reclaimFrom(player, "carrier died")
		end)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterRemoving:Connect(function()
			reclaimFrom(player, "carrier died")
		end)
	end
end

----------------------------------------------------------------
-- BRIDGES
----------------------------------------------------------------

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

--// ServiceLoop calls this when a table's payment is collected, when a served
--// party storms out, and at shift end. KitchenService calls it when a plated
--// dish is binned.
--// Two kinds of handle come back here: a STRING "served:N" is one of the
--// independent table plates (destroy it); a NUMBER is a real counter slot
--// being sent home (carried plate binned, party stormed out mid-carry).
bridge("PassReturnPlate", function(handle, why)
	if type(handle) == "string" then
		local plate = servedPlates[handle]
		if plate then
			plate:Destroy()
			servedPlates[handle] = nil
		end
		return true
	end
	return returnPlate(tonumber(handle), why)
end)

--// Serving spawns an INDEPENDENT plate on the table and frees the slot at
--// once, so the counter is instantly ready for the next dish (unlimited
--// plates). Returns a string handle the caller stores; PassReturnPlate
--// destroys that plate when the table pays. Slot-based return no longer
--// applies to a served dish - the slot went home the moment it was served.
bridge("PassPlaceOnTable", function(slotId, cframe)
	local slot = slots[tonumber(slotId)]
	if not slot then
		warn(("[Pass] table placement asked for unknown slot %s"):format(tostring(slotId)))
		return nil
	end
	if typeof(cframe) ~= "CFrame" then
		warn("[Pass] table placement needs a CFrame")
		return nil
	end

	local dish = slot.Dish
	--// Free the counter plate immediately, whatever happens next.
	goEmpty(slot)

	local plate = makeTablePlate(slot, dish, cframe)
	if not plate then
		warn(("[Pass] could not build a table plate for slot %d"):format(slot.Id))
		return nil
	end

	nextServedId += 1
	local handle = "served:" .. nextServedId
	servedPlates[handle] = plate
	return handle
end)

--// Shift end: everything comes home, wherever it was. This is the backstop
--// that guarantees a shift never starts short of plates.
bridge("PassReturnAll", function(why)
	local returned = 0
	for _, slot in pairs(slots) do
		if slot.State ~= "EMPTY" then
			goEmpty(slot)
			returned += 1
		end
	end
	--// Independent table plates are not slots - clear them here too, so a
	--// new shift never opens with last shift's plates still on tables.
	for handle, plate in pairs(servedPlates) do
		plate:Destroy()
		servedPlates[handle] = nil
	end
	if returned > 0 then
		print(("[Pass] reclaimed %d plate(s) (%s)"):format(returned, why or "reset"))
	end
	return returned
end)

--// Prints what every slot actually thinks it is. First thing to run when a
--// prompt is showing that should not be.
bridge("PassDump", function()
	for id = 1, nextSlotId do
		local slot = slots[id]
		if slot then
			print(("[Pass] slot %d  state=%-8s dish=%-12s promptEnabled=%s  %s")
				:format(id, slot.State, tostring(slot.Dish),
					tostring(slot.Prompt.Enabled), slot.Root:GetFullName()))
		end
	end
	return nextSlotId
end)

bridge("PassStats", function()
	local stats = { Total = 0, Empty = 0, Plated = 0, Carried = 0, Served = 0 }
	for _, slot in pairs(slots) do
		stats.Total += 1
		if slot.State == "EMPTY" then
			stats.Empty += 1
		elseif slot.State == "PLATED" then
			stats.Plated += 1
		elseif slot.State == "CARRIED" then
			stats.Carried += 1
		else
			stats.Served += 1
		end
	end
	return stats
end)

print("[Pass] ready")
