--[[
	Dinner Rush - SupplierClient
	StarterPlayer.StarterPlayerScripts.Client.SupplierClient  (LocalScript)

	The order board. Same house style as the fridge menu, same rule: the menu
	is intent only. Quantities are clamped and re-validated on the server, and
	the server owns whether a delivery can be placed at all.

	One row per ingredient with - / + steppers, then ORDER. A live strip at the
	bottom shows the delivery status from ReplicatedStorage.SupplierState so
	you can see the truck coming without standing at the board.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 30)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local supplierRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SupplierRemote")
local SupplierState = ReplicatedStorage:WaitForChild("SupplierState", 30)

local CREAM = Color3.fromRGB(255, 246, 233)
local WARM = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local GREY = Color3.fromRGB(196, 188, 178)

----------------------------------------------------------------
-- Panel, built once
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "SupplierBoard_UI"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 20
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.34, 0.46)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local ratio = Instance.new("UIAspectRatioConstraint")
ratio.AspectRatio = 1.05
ratio.Parent = panel

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = CHOC
stroke.Parent = panel

local grad = Instance.new("UIGradient")
grad.Rotation = 90
grad.Color = ColorSequence.new(Color3.new(1, 1, 1), WARM)
grad.Parent = panel

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.fromScale(0.5, 0.03)
title.Size = UDim2.fromScale(0.7, 0.12)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.TextColor3 = CHOC
title.Text = "SUPPLY ORDERS"
title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.fromScale(0.97, 0.03)
closeBtn.Size = UDim2.fromScale(0.11, 0.1)
closeBtn.BackgroundColor3 = TOMATO
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextScaled = true
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "X"
closeBtn.Parent = panel

local cbc = Instance.new("UICorner")
cbc.CornerRadius = UDim.new(0, 8)
cbc.Parent = closeBtn

local cbs = Instance.new("UIStroke")
cbs.Thickness = 2
cbs.Color = CHOC
cbs.Parent = closeBtn

local list = Instance.new("Frame")
list.Name = "Rows"
list.AnchorPoint = Vector2.new(0.5, 0)
list.Position = UDim2.fromScale(0.5, 0.18)
list.Size = UDim2.fromScale(0.9, 0.48)
list.BackgroundTransparency = 1
list.Parent = panel

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.Padding = UDim.new(0.04, 0)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = list

local orderBtn = Instance.new("TextButton")
orderBtn.AnchorPoint = Vector2.new(0.5, 0)
orderBtn.Position = UDim2.fromScale(0.5, 0.7)
orderBtn.Size = UDim2.fromScale(0.9, 0.13)
orderBtn.BackgroundColor3 = BASIL
orderBtn.Font = Enum.Font.FredokaOne
orderBtn.TextScaled = true
orderBtn.TextColor3 = Color3.new(1, 1, 1)
orderBtn.Text = "ORDER"
orderBtn.Parent = panel

local obc = Instance.new("UICorner")
obc.CornerRadius = UDim.new(0, 10)
obc.Parent = orderBtn

local obs = Instance.new("UIStroke")
obs.Thickness = 2.5
obs.Color = CHOC
obs.Parent = orderBtn

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 1)
status.Position = UDim2.fromScale(0.5, 0.97)
status.Size = UDim2.fromScale(0.9, 0.12)
status.BackgroundTransparency = 1
status.Font = Enum.Font.FredokaOne
status.TextScaled = true
status.TextColor3 = CHOC
status.TextTransparency = 0.25
status.Text = ""
status.Parent = panel

----------------------------------------------------------------
-- Rows
----------------------------------------------------------------
local quantities = {}  -- [ingredientName] = crates
local rows = {}        -- [ingredientName] = { Count = TextLabel }
local catalogItems = {}

local function closeBoard()
	gui.Enabled = false
end

closeBtn.Activated:Connect(closeBoard)

local function refreshRow(item)
	local row = rows[item.Name]
	if not row then return end

	local crates = quantities[item.Name] or 0
	row.Count.Text = ("%d"):format(crates * item.UnitsPerCrate)
	row.Count.TextColor3 = crates > 0 and CHOC or GREY
end

--// Total cost of what is currently dialled in
local function orderCost()
	local cost = 0
	for _, item in ipairs(catalogItems) do
		cost += (quantities[item.Name] or 0) * (item.Price or 0)
	end
	return cost
end

local function tillBalance()
	return ShiftState and (ShiftState:GetAttribute("Till") or 0) or 0
end

local refreshStatus --// forward declared, the steppers call it

local function buildRows(items)
	for _, child in ipairs(list:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	rows = {}

	local rowHeight = math.clamp(1 / math.max(#items, 1) - 0.04, 0.18, 0.32)

	for _, item in ipairs(items) do
		quantities[item.Name] = quantities[item.Name] or 0

		local row = Instance.new("Frame")
		row.Name = item.Name
		row.Size = UDim2.fromScale(1, rowHeight)
		row.BackgroundColor3 = MUSTARD
		row.Parent = list

		local rc = Instance.new("UICorner")
		rc.CornerRadius = UDim.new(0, 10)
		rc.Parent = row

		local rs = Instance.new("UIStroke")
		rs.Thickness = 2.5
		rs.Color = CHOC
		rs.Parent = row

		local hasIcon = item.Icon and item.Icon ~= "" and item.Icon ~= "rbxassetid://0"
		if hasIcon then
			local icon = Instance.new("ImageLabel")
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.fromScale(0.03, 0.5)
			icon.Size = UDim2.fromScale(0.16, 0.8)
			icon.BackgroundTransparency = 1
			icon.Image = item.Icon
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Parent = row
		end

		local name = Instance.new("TextLabel")
		name.AnchorPoint = Vector2.new(0, 0.5)
		name.Position = UDim2.fromScale(hasIcon and 0.22 or 0.05, 0.5)
		name.Size = UDim2.fromScale(0.36, 0.55)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.FredokaOne
		name.TextScaled = true
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = CHOC
		name.Text = item.Display
		name.Parent = row

		if (item.Price or 0) > 0 then
			local price = Instance.new("TextLabel")
			price.AnchorPoint = Vector2.new(0, 0.5)
			price.Position = UDim2.fromScale(hasIcon and 0.22 or 0.05, 0.8)
			price.Size = UDim2.fromScale(0.36, 0.28)
			price.BackgroundTransparency = 1
			price.Font = Enum.Font.FredokaOne
			price.TextScaled = true
			price.TextXAlignment = Enum.TextXAlignment.Left
			price.TextColor3 = CHOC
			price.TextTransparency = 0.35
			price.Text = ("$%d per %d"):format(item.Price, item.UnitsPerCrate)
			price.Parent = row
		end

		local function stepper(text, xScale)
			local button = Instance.new("TextButton")
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.fromScale(xScale, 0.5)
			button.Size = UDim2.fromScale(0.12, 0.62)
			button.BackgroundColor3 = CREAM
			button.Font = Enum.Font.FredokaOne
			button.TextScaled = true
			button.TextColor3 = CHOC
			button.Text = text
			button.Parent = row

			local bc = Instance.new("UICorner")
			bc.CornerRadius = UDim.new(0, 8)
			bc.Parent = button

			local bs = Instance.new("UIStroke")
			bs.Thickness = 2
			bs.Color = CHOC
			bs.Parent = button

			return button
		end

		local minus = stepper("-", 0.64)
		local plus = stepper("+", 0.94)

		local count = Instance.new("TextLabel")
		count.AnchorPoint = Vector2.new(0.5, 0.5)
		count.Position = UDim2.fromScale(0.79, 0.5)
		count.Size = UDim2.fromScale(0.14, 0.55)
		count.BackgroundTransparency = 1
		count.Font = Enum.Font.FredokaOne
		count.TextScaled = true
		count.TextColor3 = GREY
		count.Text = "0"
		count.Parent = row

		rows[item.Name] = { Count = count }

		minus.Activated:Connect(function()
			quantities[item.Name] = math.max(0, (quantities[item.Name] or 0) - 1)
			refreshRow(item)
			refreshStatus()
		end)

		plus.Activated:Connect(function()
			quantities[item.Name] = math.min(item.MaxCrates, (quantities[item.Name] or 0) + 1)
			refreshRow(item)
			refreshStatus()
		end)

		refreshRow(item)
	end
end

orderBtn.Activated:Connect(function()
	supplierRemote:FireServer("Order", quantities)
	closeBoard()
end)

----------------------------------------------------------------
-- Delivery status, read straight off the published attributes
----------------------------------------------------------------
local function statusText()
	if not SupplierState then return "" end

	local state = SupplierState:GetAttribute("Status") or "IDLE"
	local summary = SupplierState:GetAttribute("Summary") or ""

	if state == "ORDERED" then
		return ("Arriving in %ds - %s"):format(
			SupplierState:GetAttribute("ArrivesIn") or 0, summary)
	elseif state == "ARRIVED" then
		return ("Delivery outside the pantry: %s"):format(summary)
	end
	return "No delivery on the way"
end

function refreshStatus()
	status.Text = statusText()

	--// The server refuses a second order anyway; grey the button so that is
	--// obvious before anyone taps it
	local busy = SupplierState and (SupplierState:GetAttribute("Status") or "IDLE") ~= "IDLE"
	local cost = orderCost()
	local till = tillBalance()
	local broke = cost > till

	if busy then
		orderBtn.Text = "DELIVERY IN PROGRESS"
		orderBtn.BackgroundColor3 = GREY
	elseif cost == 0 then
		orderBtn.Text = ("ORDER   (till $%d)"):format(till)
		orderBtn.BackgroundColor3 = BASIL
	elseif broke then
		orderBtn.Text = ("NEED $%d - TILL HAS $%d"):format(cost, till)
		orderBtn.BackgroundColor3 = TOMATO
	else
		orderBtn.Text = ("ORDER  $%d   (till $%d)"):format(cost, till)
		orderBtn.BackgroundColor3 = BASIL
	end

	orderBtn.AutoButtonColor = not busy and not broke
end

supplierRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "OpenBoard" then
		catalogItems = a
		buildRows(catalogItems)
		refreshStatus()
		gui.Enabled = true
	elseif action == "OrderDenied" then
		status.Text = tostring(a or "Order refused")
		gui.Enabled = true
	end
end)

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < 0.25 then return end
	since = 0
	if gui.Enabled then
		refreshStatus()
	end
end)
