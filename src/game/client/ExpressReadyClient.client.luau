--[[
	Dinner Rush - ExpressReadyClient
	StarterPlayer.StarterPlayerScripts.Client.ExpressReadyClient  (LocalScript)

	The Waiter's EXPRESS RUN ready-indicator. While the local player is the
	Waiter AND their ultimate is fully charged, a big mustard badge (the dish
	icon + "GRAB") floats over every PLATED plate on the pass, drawn ALWAYS ON
	TOP so you can see what's grabbable from anywhere on the map. It vanishes
	the moment the ult fires (charge drops) or the plate is taken.

	Reads only replicated attributes the pass already publishes (PassState /
	PassDish on each PassSlot) plus the player's ClassKey / UltimateCharge.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ULT = Config.Ultimates

local player = Players.LocalPlayer

local MUSTARD = Color3.fromRGB(245, 184, 65)
local CHOC = Color3.fromRGB(59, 43, 32)

local function dishIcon(dish)
	local r = Config.Recipes and Config.Recipes[dish]
	return r and r.Icon or ""
end

--// slotPart -> BillboardGui
local badges = {}

local function clearBadge(part)
	if badges[part] then
		badges[part]:Destroy()
		badges[part] = nil
	end
end
local function clearAll()
	for part in pairs(badges) do clearBadge(part) end
end

local function makeBadge(adornee, dish)
	local gui = Instance.new("BillboardGui")
	gui.Name = "ExpressBadge"
	gui.Size = UDim2.fromScale(3.4, 3.4)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true      --// through walls, from across the room
	gui.MaxDistance = 1000      --// visible anywhere on the floor
	gui.Adornee = adornee
	gui.Parent = adornee

	local circle = Instance.new("Frame")
	circle.Size = UDim2.fromScale(1, 1)
	circle.BackgroundColor3 = MUSTARD
	circle.BackgroundTransparency = 0.05
	circle.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circle
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = CHOC
	stroke.Parent = circle

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.46)
	icon.Size = UDim2.fromScale(0.72, 0.72)
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = dishIcon(dish)
	icon.Parent = circle

	local grab = Instance.new("TextLabel")
	grab.AnchorPoint = Vector2.new(0.5, 1)
	grab.Position = UDim2.fromScale(0.5, 1.08)
	grab.Size = UDim2.fromScale(1.4, 0.26)
	grab.BackgroundTransparency = 1
	grab.Font = Enum.Font.FredokaOne
	grab.TextScaled = true
	grab.Text = "GRAB"
	grab.TextColor3 = Color3.new(1, 1, 1)
	grab.TextStrokeColor3 = CHOC
	grab.TextStrokeTransparency = 0
	grab.Parent = gui

	--// a gentle bob so it reads as "ready"
	TweenService:Create(gui, TweenInfo.new(0.7, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true),
		{ StudsOffset = Vector3.new(0, 4.6, 0) }):Play()

	badges[adornee] = gui
	return gui
end

local function platePartOf(tagged)
	if tagged:IsA("BasePart") then return tagged end
	if tagged:IsA("Model") then
		return tagged.PrimaryPart or tagged:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function refresh()
	local classKey = player:GetAttribute("ClassKey") or ""
	local charge = player:GetAttribute("UltimateCharge") or 0
	local ready = (classKey == "Waiter") and (charge >= (ULT.MaxCharge or 100))
	if not ready then
		clearAll()
		return
	end

	local seen = {}
	for _, tagged in ipairs(CollectionService:GetTagged("PassSlot")) do
		local part = platePartOf(tagged)
		if part and tagged:GetAttribute("PassState") == "PLATED" then
			seen[part] = true
			local dish = tagged:GetAttribute("PassDish") or ""
			if not badges[part] then
				makeBadge(part, dish)
			else
				local icon = badges[part]:FindFirstChild("Icon", true)
				if icon then icon.Image = dishIcon(dish) end
			end
		end
	end
	for part in pairs(badges) do
		if not seen[part] then clearBadge(part) end
	end
end

task.spawn(function()
	while true do
		pcall(refresh)
		task.wait(0.4)
	end
end)
