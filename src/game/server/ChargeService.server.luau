--[[
	Dinner Rush - ChargeService
	ServerScriptService.Server.ChargeService  (regular Script, server-side)

	Phase 2, final step: CHARGE + THE FOUR ULTIMATES.

	Charge is SERVER-owned: a 0..MaxCharge number per player, stored as the
	UltimateCharge attribute (replicates to that client for the bar).
	It is earned through ServerStorage.AddCharge, invoked by the SAME
	creditStat calls that write careers - every counted moment is a charge
	moment, mapped by Config.Ultimates.ChargePer. Classless players earn
	nothing and can activate nothing.

	Activation (UltimateRemote "Activate", sent by ChargeClient on
	Q / touch / gamepad Y): validated end-to-end here - class equipped,
	charge full, shift live - then dispatched:

	  Chef     FLASH FRY!   EVERY carried raw becomes its Perfect dish;
	                        dish variants resolve to what open tickets
	                        want (neediest first), else by
	                        Config.Ultimates.FlashFryMethodOrder
	  Waiter   THIRD HAND!  CarryLimit attribute +1 for the rest of the shift
	  Fixer    SPEED DIAL!  ServerStorage.ResolveActiveEvent (EventSystem's
	                        own stop* success paths - never re-implemented)
	  Charmer  SWEET TALK!  ServerStorage.SweetTalkTable (ServiceLoop's
	                        extendBar on the most desperate seated party)

	Only a SUCCESSFUL ability consumes charge; denials keep it and tell the
	player why. Charge survives respawn (it lives on the Player), dies with
	leaving, and resets - along with THIRD HAND's CarryLimit - when a new
	shift goes RUNNING.

	THE LAW: FLASH FRY skips the cook timer entirely; it never modifies it.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Charge] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

local ULT = Config.Ultimates

print("[Charge] script started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local ultimateRemote = remotes:FindFirstChild("UltimateRemote")
if not ultimateRemote then
	ultimateRemote = Instance.new("RemoteEvent")
	ultimateRemote.Name = "UltimateRemote"
	ultimateRemote.Parent = remotes
end

local function shiftInfo()
	local bridge = ServerStorage:FindFirstChild("GetShiftInfo")
	if not bridge then
		return { State = "WAITING" }
	end
	local ok, info = pcall(function() return bridge:Invoke() end)
	return (ok and type(info) == "table") and info or { State = "WAITING" }
end

----------------------------------------------------------------
-- Charge accrual
----------------------------------------------------------------
local function addCharge(player, key, count)
	if not player or not player.Parent then return end

	--// No class, no charge - classless play stays clean of the system
	local classKey = player:GetAttribute("ClassKey")
	if not classKey or classKey == "" then return end

	local per = ULT.ChargePer[key] or 0
	if per <= 0 then return end

	local current = player:GetAttribute("UltimateCharge") or 0
	if current >= ULT.MaxCharge then return end

	player:SetAttribute("UltimateCharge",
		math.min(ULT.MaxCharge, current + per * math.max(tonumber(count) or 1, 1)))
end

do
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "AddCharge"
	bindable.OnInvoke = addCharge
	bindable.Parent = ServerStorage
end

----------------------------------------------------------------
-- The abilities. Each returns ok, reasonText - false keeps the charge.
----------------------------------------------------------------

--// Same tool shape KitchenService hands out at collect, so the pass and
--// serving flow treat a flash-fried dish exactly like a cooked one
local function makeDishTool(recipe, dishName)
	local tool = Instance.new("Tool")
	tool.Name = recipe.Display
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	if recipe.Icon ~= "" and recipe.Icon ~= "rbxassetid://0" then
		tool.TextureId = recipe.Icon
	end
	tool:SetAttribute("Dish", dishName)
	tool:SetAttribute("Quality", "Perfect")

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1.6, 0.8, 1.6)
	handle.Color = recipe.Color
	handle.Material = Enum.Material.SmoothPlastic
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	--// Composed cartoon food, same as KitchenService's collect path
	local ok, DishModels = pcall(function()
		return require(ServerStorage:WaitForChild("Shared"):WaitForChild("DishModels"))
	end)
	if ok and DishModels and DishModels.decorate(tool, dishName) then
		handle.Transparency = 1
	end

	return tool
end

--// Every recipe an ingredient can become, sorted by FlashFryMethodOrder
--// (then name) so variant resolution is DETERMINISTIC - pairs() order
--// must never decide which steak the chef gets
local function recipesFor(ingredient)
	local rank = {}
	for index, method in ipairs(ULT.FlashFryMethodOrder) do
		rank[method] = index
	end
	local out = {}
	for name, recipe in pairs(Config.Recipes) do
		if recipe.Ingredient == ingredient then
			table.insert(out, { Name = name, Recipe = recipe })
		end
	end
	table.sort(out, function(a, b)
		local ra = rank[a.Recipe.Method] or math.huge
		local rb = rank[b.Recipe.Method] or math.huge
		if ra ~= rb then return ra < rb end
		return a.Name < b.Name
	end)
	return out
end

--// What the floor is waiting on right now: dish -> how many tickets
--// still want it, and the hungriest one's patience fraction
local function openWants()
	local bridge = ServerStorage:FindFirstChild("GetOpenOrders")
	if not bridge then return {} end
	local ok, orders = pcall(function() return bridge:Invoke() end)
	if not ok or type(orders) ~= "table" then return {} end

	local wants = {}
	for _, order in ipairs(orders) do
		if not order.Walkout then
			for _, dishName in ipairs(order.Dishes or {}) do
				local want = wants[dishName]
				if not want then
					want = { Count = 0, Neediest = 1 }
					wants[dishName] = want
				end
				want.Count += 1
				want.Neediest = math.min(want.Neediest, order.Patience or 1)
			end
		end
	end
	return wants
end

--// One raw -> one dish. A lone recipe just cooks; variants go to the
--// neediest open ticket asking for one, else the preference order.
--// Claiming decrements the want so two steaks can feed two tickets.
local function pickDish(candidates, wants)
	local pick = nil
	if #candidates > 1 then
		local bestNeed
		for _, candidate in ipairs(candidates) do
			local want = wants[candidate.Name]
			if want and want.Count > 0
				and (not pick or want.Neediest < bestNeed) then
				pick, bestNeed = candidate, want.Neediest
			end
		end
	end
	pick = pick or candidates[1]
	local want = wants[pick.Name]
	if want and want.Count > 0 then
		want.Count -= 1
	end
	return pick
end

local function flashFry(player)
	local character = player.Character
	if not character then
		return false, "No character!"
	end

	--// EVERY carried raw - the equipped one and the pocketed one both
	local raws = {}
	local containers = { character, player:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and child:GetAttribute("Ingredient") then
					table.insert(raws, child)
				end
			end
		end
	end
	if #raws == 0 then
		return false, "Grab a raw ingredient first!"
	end

	local wants = openWants()
	local cookedNames = {}
	for _, held in ipairs(raws) do
		local candidates = recipesFor(held:GetAttribute("Ingredient"))
		if #candidates > 0 then
			local pick = pickDish(candidates, wants)
			local home = held.Parent
			held:Destroy()
			makeDishTool(pick.Recipe, pick.Name).Parent = home
			table.insert(cookedNames, pick.Recipe.Display)
		end
	end
	if #cookedNames == 0 then
		return false, "That can't be cooked!"
	end

	print(("[Charge] FLASH FRY! %s instantly cooked: Perfect %s"):format(
		player.Name, table.concat(cookedNames, ", Perfect ")))
	return true
end

local function thirdHand(player)
	if player:GetAttribute("CarryLimit") then
		return false, "Third hand already out!"
	end
	player:SetAttribute("CarryLimit",
		Config.Kitchen.MaxCarriedItems + ULT.ThirdHandExtraSlots)
	print(("[Charge] THIRD HAND! %s carries %d for the rest of the shift"):format(
		player.Name, player:GetAttribute("CarryLimit")))
	return true
end

local function speedDial(player)
	local bridge = ServerStorage:FindFirstChild("ResolveActiveEvent")
	if not bridge then
		return false, "Nothing to dial!"
	end
	local ok, resolved, reason = pcall(function()
		return bridge:Invoke(player)
	end)
	if not ok then
		return false, "The line is busy!"
	end
	if resolved then
		print(("[Charge] SPEED DIAL! %s resolved the emergency"):format(player.Name))
	end
	return resolved, reason
end

local function sweetTalk(player)
	local bridge = ServerStorage:FindFirstChild("SweetTalkTable")
	if not bridge then
		return false, "Nobody to charm!"
	end
	local ok, charmed, reason = pcall(function()
		return bridge:Invoke(player)
	end)
	if not ok then
		return false, "The charm fizzled!"
	end
	if charmed then
		print(("[Charge] SWEET TALK! %s soothed the neediest table"):format(player.Name))
	end
	return charmed, reason
end

local ABILITIES = {
	Chef = flashFry,
	Waiter = thirdHand,
	Fixer = speedDial,
	Charmer = sweetTalk,
}

----------------------------------------------------------------
-- Activation
----------------------------------------------------------------
ultimateRemote.OnServerEvent:Connect(function(player, action)
	if action ~= "Activate" then return end

	local info = shiftInfo()
	if info.State ~= "RUNNING" and info.State ~= "CLOSING" then
		ultimateRemote:FireClient(player, "Result", false, "Wait for the shift!")
		return
	end

	local classKey = player:GetAttribute("ClassKey")
	local ability = classKey and ABILITIES[classKey]
	if not ability then
		ultimateRemote:FireClient(player, "Result", false, "No class equipped!")
		return
	end

	local charge = player:GetAttribute("UltimateCharge") or 0
	if charge < ULT.MaxCharge then
		ultimateRemote:FireClient(player, "Result", false, "Not charged yet!")
		return
	end

	local ok, reason = ability(player)
	if ok then
		player:SetAttribute("UltimateCharge", 0) --// spent only on success
		ultimateRemote:FireClient(player, "Result", true)
	else
		ultimateRemote:FireClient(player, "Result", false, reason or "Not now!")
	end
end)

----------------------------------------------------------------
-- Lifecycle: zeroed on join, reset (with THIRD HAND) every new shift
----------------------------------------------------------------
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("UltimateCharge", 0)
end)
for _, player in ipairs(Players:GetPlayers()) do
	player:SetAttribute("UltimateCharge", 0)
end

task.spawn(function()
	local lastState = ""
	while true do
		local state = shiftInfo().State
		if state == "RUNNING" and lastState ~= "RUNNING" then
			for _, player in ipairs(Players:GetPlayers()) do
				player:SetAttribute("UltimateCharge", 0)
				player:SetAttribute("CarryLimit", nil) --// third hands retract
			end
			print("[Charge] new shift - charges and carry limits reset")
		end
		lastState = state
		task.wait(1)
	end
end)
