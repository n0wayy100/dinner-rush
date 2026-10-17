--[[
	Dinner Rush - ThrowHighlightClient
	StarterPlayer.StarterPlayerScripts.Client.ThrowHighlightClient  (LocalScript)

	The Waiter's PLATE JUGGLER range feedback. While the local player is the
	Waiter AND holding a plated dish, every table WITHIN THROW RANGE that
	ordered a dish they hold - and its seated customers - glows BLUE, so you
	know exactly where you can throw. Press R to fling the plate to the nearest
	one (SkillService does the throw).

	Reads only replicated data: the OrdersUpdate broadcast (table -> dishes),
	the Table tag, and the CustomerParty pawns' TableId attribute.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local ordersRemote = remotes:WaitForChild("OrdersUpdate")

local player = Players.LocalPlayer

local BLUE_FILL = Color3.fromRGB(70, 140, 255)
local BLUE_LINE = Color3.fromRGB(130, 190, 255)

local function throwRange()
	local sr = Config.Classes.Waiter and Config.Classes.Waiter.SkillR
	return (sr and sr.ThrowRangeStuds) or 45
end

--// latest broadcast: list of { Table, Dishes, Walkout, ... }
local orders = {}
ordersRemote.OnClientEvent:Connect(function(list)
	orders = list or {}
end)

--// instance -> Highlight
local highlights = {}
local function clearHi(inst)
	if highlights[inst] then
		highlights[inst]:Destroy()
		highlights[inst] = nil
	end
end
local function clearAll()
	for inst in pairs(highlights) do clearHi(inst) end
end
local function ensureHi(inst)
	if highlights[inst] or not inst.Parent then return end
	local h = Instance.new("Highlight")
	h.FillColor = BLUE_FILL
	h.FillTransparency = 0.55
	h.OutlineColor = BLUE_LINE
	h.OutlineTransparency = 0
	h.Adornee = inst
	h.Parent = inst
	highlights[inst] = h
end

local function heldDishes()
	local set, any = {}, false
	local char = player.Character
	for _, container in ipairs({ char, player:FindFirstChildOfClass("Backpack") }) do
		if container then
			for _, t in ipairs(container:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("Dish") and t:GetAttribute("PlateSlot") then
					set[t:GetAttribute("Dish")] = true
					any = true
				end
			end
		end
	end
	return set, any
end

local function tablePos(tpart)
	return tpart:IsA("BasePart") and tpart.Position or tpart:GetPivot().Position
end

local function refresh()
	if (player:GetAttribute("ClassKey") or "") ~= "Waiter" then clearAll() return end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then clearAll() return end
	local dishes, holding = heldDishes()
	if not holding then clearAll() return end

	local range = throwRange()

	--// id -> Table part
	local tableParts = {}
	for _, inst in ipairs(CollectionService:GetTagged("Table")) do
		tableParts[inst:GetAttribute("TableId")] = inst
	end

	--// in-range tables ordering a held dish
	local validTable = {}
	for _, order in ipairs(orders) do
		if not order.Walkout and not validTable[order.Table] then
			local match = false
			for _, dish in ipairs(order.Dishes or {}) do
				if dishes[dish] then match = true break end
			end
			if match then
				local tpart = tableParts[order.Table]
				if tpart and (tablePos(tpart) - root.Position).Magnitude <= range then
					validTable[order.Table] = true
				end
			end
		end
	end

	--// build the set to highlight: the table + its customers
	local wanted = {}
	for id in pairs(validTable) do
		if tableParts[id] then wanted[tableParts[id]] = true end
	end
	for _, pawn in ipairs(CollectionService:GetTagged("CustomerParty")) do
		local tid = pawn:GetAttribute("TableId")
		if tid and validTable[tid] then wanted[pawn] = true end
	end

	for inst in pairs(wanted) do ensureHi(inst) end
	for inst in pairs(highlights) do
		if not wanted[inst] then clearHi(inst) end
	end
end

task.spawn(function()
	while true do
		pcall(refresh)
		task.wait(0.2)
	end
end)
