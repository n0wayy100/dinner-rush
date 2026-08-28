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

	  Chef     FLASH FRY!   held raw ingredient becomes its Perfect dish
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

	return tool
end

local function flashFry(player)
	local character = player.Character
	if not character then
		return false, "No character!"
	end

	--// The HELD raw - equipped, in hand, right now
	local held = nil
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("Ingredient") then
			held = child
			break
		end
	end
	if not held then
		return false, "Hold a raw ingredient first!"
	end

	local ingredient = held:GetAttribute("Ingredient")
	local dishName, recipe = nil, nil
	for name, r in pairs(Config.Recipes) do
		if r.Ingredient == ingredient then
			dishName, recipe = name, r
			break
		end
	end
	if not recipe then
		return false, "That can't be cooked!"
	end

	held:Destroy()
	makeDishTool(recipe, dishName).Parent = character
	print(("[Charge] FLASH FRY! %s turned %s into a Perfect %s"):format(
		player.Name, ingredient, recipe.Display))
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
