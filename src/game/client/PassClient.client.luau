--[[
	Dinner Rush - PassClient
	StarterPlayerScripts.Client.PassClient

	Hides the "Plate up" prompt on empty plates unless YOU are carrying a
	cooked dish. Six plates in a row all shouting E at someone with empty
	hands is noise, and it buries the prompts that do matter.

	Rendering only. The server publishes PassState on each plate and still
	re-validates every trigger in PassService - a client that lies to itself
	about a prompt gains nothing, because the server checks again.

	  EMPTY   -> prompt only while holding an unplated dish
	  PLATED  -> always prompt; anyone can run it to a table
	  other   -> plate is in a hand or on a table, nothing to offer
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local SLOT_TAG = "PassSlot"

--// Cheap enough to run often, but there is no reason to run it every frame:
--// what it depends on only changes when you pick something up or put it down.
local REFRESH_SECONDS = 0.2

local function carryingUnplatedDish()
	local containers = { player.Character, player:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool")
					and child:GetAttribute("Dish")
					and not child:GetAttribute("PlateSlot")
				then
					return true
				end
			end
		end
	end
	return false
end

local function promptOf(root)
	--// The server parents it to the plate part, which may be the tagged
	--// instance itself or a descendant of it.
	if root:IsA("BasePart") then
		local direct = root:FindFirstChild("Pass")
		if direct and direct:IsA("ProximityPrompt") then
			return direct
		end
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Name == "Pass" then
			return descendant
		end
	end
	return nil
end

local function refresh()
	local holding = carryingUnplatedDish()

	for _, root in ipairs(CollectionService:GetTagged(SLOT_TAG)) do
		local prompt = promptOf(root)
		if prompt then
			local state = root:GetAttribute("PassState")
			if state == nil then
				--// FAIL OPEN. No state means the server has not published yet,
				--// or PassService is broken. Hiding the prompt would make the
				--// game unplayable with no visible cause; showing a prompt that
				--// does nothing is obvious and harmless - the server validates
				--// every trigger regardless.
				prompt.Enabled = true
			elseif state == "PLATED" then
				prompt.Enabled = true
			elseif state == "EMPTY" then
				prompt.Enabled = holding
			else
				prompt.Enabled = false
			end
		end
	end
end

local accumulated = 0
RunService.Heartbeat:Connect(function(dt)
	accumulated += dt
	if accumulated < REFRESH_SECONDS then
		return
	end
	accumulated = 0
	refresh()
end)

refresh()
