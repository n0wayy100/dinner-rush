--[[
	Dinner Rush - OrderPanelClient
	StarterPlayer.StarterPlayerScripts.Client.OrderPanelClient  (LocalScript)

	The on-screen ORDER PANEL (playtest feedback, Sep 20 2026): a code-built
	list of open orders that is always legible on mobile and PC, so a player
	with no voice comms can still see what every table wants and which one is
	running out of patience. The wall OrderBoard stays as flavour; this is the
	reliable copy.

	Server-driven: OrderPanelServer broadcasts the open-order list on the
	OrdersUpdate RemoteEvent a few times a second. This script only renders.
	Orders are shown in the order they were TAKEN (by order number), each
	with its table, dish icons, a patience bar in the same colours as the
	over-head bars, and a red ❗ flag when patience is low.

	Tap the header to collapse/expand (per-session).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local PANEL = Config.OrderPanel
if not (PANEL and PANEL.Enabled) then
	return
end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local ordersRemote = remotes:WaitForChild("OrdersUpdate")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local VIP_GOLD = Color3.fromRGB(255, 200, 60)
local BAR_BACK = Color3.fromRGB(40, 40, 40)
local WHITE = Color3.fromRGB(255, 255, 255)

local ROW_HEIGHT = 42

local function patienceColor(fraction)
	if fraction > 0.5 then
		return BASIL
	elseif fraction > 0.25 then
		return MUSTARD
	end
	return TOMATO
end

local function dishIcon(dishName)
	local recipe = Config.Recipes[dishName]
	local icon = recipe and recipe.Icon
	if icon and icon ~= "" and icon ~= "rbxassetid://0" then
		return icon
	end
	return nil
end

----------------------------------------------------------------
-- Build the shell
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "OrderPanel_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 16 --// above the world, below minigames/report
gui.Parent = playerGui

--// Top-right, offset-sized so it is the same physical size on any screen
local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(1, 0)
root.Position = UDim2.new(1, -8, 0, 96) --// clear of Roblox's top bar
root.Size = UDim2.fromOffset(238, 40)
root.BackgroundTransparency = 1
root.AutomaticSize = Enum.AutomaticSize.Y
root.Visible = false
root.Parent = gui

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = root

--// HEADER (also the collapse button)
local header = Instance.new("TextButton")
header.Name = "Header"
header.LayoutOrder = 0
header.Size = UDim2.new(1, 0, 0, 30)
header.BackgroundColor3 = TOMATO
header.AutoButtonColor = false
header.Font = Enum.Font.FredokaOne
header.TextScaled = true
header.Text = "ORDERS"
header.TextColor3 = WHITE
header.Parent = root
local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 8)
headerCorner.Parent = header
local headerStroke = Instance.new("UIStroke")
headerStroke.Thickness = 2
headerStroke.Color = CHOC
headerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
headerStroke.Parent = header
local headerCap = Instance.new("UITextSizeConstraint")
headerCap.MaxTextSize = 18
headerCap.Parent = header

--// A little chevron on the right edge of the header
local chevron = Instance.new("TextLabel")
chevron.AnchorPoint = Vector2.new(1, 0.5)
chevron.Position = UDim2.fromScale(0.97, 0.5)
chevron.Size = UDim2.fromOffset(20, 20)
chevron.BackgroundTransparency = 1
chevron.Font = Enum.Font.FredokaOne
chevron.TextScaled = true
chevron.TextColor3 = WHITE
chevron.Text = "▾"
chevron.Parent = header

--// ROWS container
local rowsHolder = Instance.new("Frame")
rowsHolder.Name = "Rows"
rowsHolder.LayoutOrder = 1
rowsHolder.Size = UDim2.new(1, 0, 0, 0)
rowsHolder.BackgroundTransparency = 1
rowsHolder.AutomaticSize = Enum.AutomaticSize.Y
rowsHolder.Parent = root

local rowsLayout = Instance.new("UIListLayout")
rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowsLayout.Padding = UDim.new(0, 4)
rowsLayout.Parent = rowsHolder

----------------------------------------------------------------
-- Row rendering
----------------------------------------------------------------
local function buildRow(order, index)
	local row = Instance.new("Frame")
	row.Name = "Order" .. tostring(order.OrderNo)
	row.LayoutOrder = index
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = order.Walkout and TOMATO or CREAM
	row.Parent = rowsHolder
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(row.BackgroundColor3,
		order.Walkout and TOMATO or CREAM_DEEP)
	grad.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = CHOC
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = row

	--// #N · T2 chip
	local tag = Instance.new("TextLabel")
	tag.AnchorPoint = Vector2.new(0, 0)
	tag.Position = UDim2.fromOffset(8, 4)
	tag.Size = UDim2.fromOffset(58, 18)
	tag.BackgroundTransparency = 1
	tag.Font = Enum.Font.FredokaOne
	tag.TextScaled = true
	tag.TextXAlignment = Enum.TextXAlignment.Left
	tag.TextColor3 = CHOC
	tag.Text = ("#%d  T%d"):format(order.OrderNo, order.Table)
	tag.Parent = row
	local tagCap = Instance.new("UITextSizeConstraint")
	tagCap.MaxTextSize = 15
	tagCap.Parent = tag

	--// VIP star
	if order.VIP then
		local star = Instance.new("TextLabel")
		star.AnchorPoint = Vector2.new(0, 0)
		star.Position = UDim2.fromOffset(66, 3)
		star.Size = UDim2.fromOffset(18, 18)
		star.BackgroundTransparency = 1
		star.Font = Enum.Font.FredokaOne
		star.TextScaled = true
		star.Text = "⭐"
		star.TextColor3 = VIP_GOLD
		star.Parent = row
	end

	--// dish icons, right-aligned on the top line
	local icons = Instance.new("Frame")
	icons.AnchorPoint = Vector2.new(1, 0)
	icons.Position = UDim2.new(1, -8, 0, 3)
	icons.Size = UDim2.fromOffset(120, 20)
	icons.BackgroundTransparency = 1
	icons.Parent = row
	local iconsLayout = Instance.new("UIListLayout")
	iconsLayout.FillDirection = Enum.FillDirection.Horizontal
	iconsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	iconsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	iconsLayout.Padding = UDim.new(0, 3)
	iconsLayout.Parent = icons

	for i, dishName in ipairs(order.Dishes or {}) do
		local icon = dishIcon(dishName)
		if icon then
			local img = Instance.new("ImageLabel")
			img.Size = UDim2.fromOffset(20, 20)
			img.BackgroundTransparency = 1
			img.ScaleType = Enum.ScaleType.Fit
			img.Image = icon
			img.LayoutOrder = i
			img.Parent = icons
		else
			local txt = Instance.new("TextLabel")
			txt.Size = UDim2.fromOffset(40, 20)
			txt.BackgroundTransparency = 1
			txt.Font = Enum.Font.FredokaOne
			txt.TextScaled = true
			txt.TextColor3 = CHOC
			local recipe = Config.Recipes[dishName]
			txt.Text = (recipe and recipe.Display or dishName):sub(1, 4)
			txt.LayoutOrder = i
			txt.Parent = icons
		end
	end

	--// patience bar along the bottom, same colours as the over-head bar
	local barBack = Instance.new("Frame")
	barBack.AnchorPoint = Vector2.new(0.5, 1)
	barBack.Position = UDim2.new(0.5, 0, 1, -5)
	barBack.Size = UDim2.new(1, -16, 0, 6)
	barBack.BackgroundColor3 = BAR_BACK
	barBack.BorderSizePixel = 0
	barBack.Parent = row
	local barBackCorner = Instance.new("UICorner")
	barBackCorner.CornerRadius = UDim.new(1, 0)
	barBackCorner.Parent = barBack

	local fraction = math.clamp(order.Patience or 0, 0, 1)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(fraction, 1)
	fill.BackgroundColor3 = patienceColor(fraction)
	fill.BorderSizePixel = 0
	fill.Parent = barBack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	--// low-patience ❗ flag
	if fraction <= (PANEL.LowPatienceBelow or 0.25) and not order.Walkout then
		local bang = Instance.new("TextLabel")
		bang.AnchorPoint = Vector2.new(1, 0)
		bang.Position = UDim2.new(1, -6, 0, 22)
		bang.Size = UDim2.fromOffset(18, 18)
		bang.BackgroundTransparency = 1
		bang.Font = Enum.Font.FredokaOne
		bang.TextScaled = true
		bang.Text = "❗"
		bang.TextColor3 = TOMATO
		bang.Parent = row
	end

	return row
end

----------------------------------------------------------------
-- State + update
----------------------------------------------------------------
local collapsed = false
local lastOrders = {}

local function render()
	--// clear
	for _, child in ipairs(rowsHolder:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local orders = lastOrders
	if #orders == 0 then
		root.Visible = false
		return
	end
	root.Visible = true

	--// most urgent first: the lowest patience rises to the top (owner,
	--// Sep 20), so the table about to walk is always the one you read first
	table.sort(orders, function(a, b)
		local pa, pb = a.Patience or 0, b.Patience or 0
		if pa ~= pb then
			return pa < pb
		end
		return (a.OrderNo or 0) < (b.OrderNo or 0)
	end)

	header.Text = collapsed and ("ORDERS (%d)"):format(#orders) or "ORDERS"
	chevron.Text = collapsed and "▸" or "▾"
	rowsHolder.Visible = not collapsed
	if collapsed then
		return
	end

	local maxRows = PANEL.MaxRows or 6
	local shown = math.min(#orders, maxRows)
	for i = 1, shown do
		buildRow(orders[i], i)
	end
	if #orders > maxRows then
		local more = Instance.new("TextLabel")
		more.LayoutOrder = maxRows + 1
		more.Size = UDim2.new(1, 0, 0, 20)
		more.BackgroundTransparency = 1
		more.Font = Enum.Font.FredokaOne
		more.TextScaled = true
		more.TextColor3 = CHOC
		more.Text = ("+%d more"):format(#orders - maxRows)
		more.Parent = rowsHolder
		local moreCap = Instance.new("UITextSizeConstraint")
		moreCap.MaxTextSize = 14
		moreCap.Parent = more
	end
end

header.Activated:Connect(function()
	collapsed = not collapsed
	render()
end)

ordersRemote.OnClientEvent:Connect(function(orders)
	lastOrders = orders or {}
	render()
end)
