--[[
	Dinner Rush - OrderBoardService
	ServerScriptService.Server.OrderBoardService  (regular Script, server-side)

	The kitchen's wall-mounted order ticket board: one card per open order,
	sorted most-desperate-first (leftmost = lowest remaining patience).

	DATA FLOW CHOICE: server-rendered SurfaceGui, polled from ServiceLoop's
	GetOpenOrders bindable at Config.OrderBoard.UpdateHz. Every other world
	surface in this game (patience bars, station progress, payment signs,
	fire alerts, the pass scoreboard) is server-built, so the board follows
	the house pattern rather than inventing a client-rendered exception.
	ServiceLoop stays the only owner of party state - this script renders.

	  part tagged OrderBoard ... the wall sign (owner places + tags it;
	                             Config.OrderBoard.Face picks the drawn face)

	Card anatomy: "#orderNo · T<table>" (+ gold star for VIPs), the
	remaining dish ICONS side by side (a party's ticket can be different
	dishes - Burger + Fries - so icon-per-dish, never icon-x-count; the row
	shrinks as dishes land), and a patience bar using EXACTLY the same
	colour language as the over-head bars (updateBarVisual: basil > 0.5,
	mustard > 0.25, tomato below).

	Cards slide (tween) when the sort order changes, the leftmost card
	pulses when critical, a walkout flashes tomato before dropping, and
	overflow beyond MaxTickets collapses into a "+N more" chip - the hidden
	tickets are by definition the least urgent. The board keeps updating
	through CLOSING: parties still eating after the buzzer keep tickets.
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[OrderBoard] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

local BOARD = Config.OrderBoard

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local VIP_GOLD = Color3.fromRGB(255, 200, 60)
local BAR_BACK = Color3.fromRGB(40, 40, 40)

print("[OrderBoard] script started")

--// Same colour thresholds as ServiceLoop's updateBarVisual - the board and
--// the over-head bar describe the same number and must speak one language
local function patienceColor(fraction)
	if fraction > 0.5 then
		return BASIL
	elseif fraction > 0.25 then
		return MUSTARD
	end
	return TOMATO
end

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
			warn(("[OrderBoard] %s is tagged %s but has no BasePart"):format(instance:GetFullName(), tag))
		end
	end
	return nil
end

----------------------------------------------------------------
-- Layout maths: a grid of TicketsPerRow columns inside the card area
----------------------------------------------------------------
local PAD = 0.015
local CARD_W = (1 - PAD * (BOARD.TicketsPerRow + 1)) / BOARD.TicketsPerRow
local CARD_H = 0.42

local function slotPosition(rank) --// 1-based sort rank -> card Position
	local index = rank - 1
	local col = index % BOARD.TicketsPerRow
	local row = math.floor(index / BOARD.TicketsPerRow)
	return UDim2.fromScale(
		PAD + col * (CARD_W + PAD),
		PAD + row * (CARD_H + PAD * 2))
end

----------------------------------------------------------------
-- Board construction (once)
----------------------------------------------------------------
local boardPart, cardArea, countLabel, overflowChip

--// The board is a slab: its two BIG faces sit along its thinnest axis.
--// Of those two, the front is whichever is not buried in the wall - probe
--// both with a short raycast and keep the side with open air. Drawing on
--// a thin edge face is what turns the board into giant stretched slivers.
local function autoFace(part)
	local size = part.Size
	local axis, half = "Z", size.Z / 2
	if size.X <= size.Y and size.X <= size.Z then
		axis, half = "X", size.X / 2
	elseif size.Y <= size.X and size.Y <= size.Z then
		axis, half = "Y", size.Y / 2
	end

	local candidates = {
		X = { Enum.NormalId.Right, Enum.NormalId.Left },
		Y = { Enum.NormalId.Top, Enum.NormalId.Bottom },
		Z = { Enum.NormalId.Front, Enum.NormalId.Back },
	}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { part }

	local best, bestClearance = candidates[axis][1], -1
	for _, normalId in ipairs(candidates[axis]) do
		local normal = part.CFrame:VectorToWorldSpace(Vector3.FromNormalId(normalId))
		local origin = part.Position + normal * (half + 0.05)
		local hit = workspace:Raycast(origin, normal * 6, params)
		local clearance = hit and (hit.Position - origin).Magnitude or 6
		if clearance > bestClearance then
			best, bestClearance = normalId, clearance
		end
	end
	return best
end

local function buildBoard(part)
	local face
	if BOARD.Face ~= "Auto" then
		pcall(function()
			face = Enum.NormalId[BOARD.Face]
		end)
	end
	face = face or autoFace(part)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "OrderBoard"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = BOARD.PixelsPerStud
	gui.LightInfluence = 0 --// readable in the dim kitchen (and mid-outage)
	gui.Parent = part

	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = CREAM
	back.BorderSizePixel = 0
	back.Parent = gui

	--// Chocolate header strip: "ORDERS" + the live open count
	local header = Instance.new("Frame")
	header.Size = UDim2.fromScale(1, 0.14)
	header.BackgroundColor3 = CHOC
	header.BorderSizePixel = 0
	header.Parent = back

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.fromScale(0.02, 0.5)
	title.Size = UDim2.fromScale(0.4, 0.8)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = CREAM
	title.Text = "ORDERS"
	title.Parent = header

	countLabel = Instance.new("TextLabel")
	countLabel.AnchorPoint = Vector2.new(1, 0.5)
	countLabel.Position = UDim2.fromScale(0.98, 0.5)
	countLabel.Size = UDim2.fromScale(0.3, 0.8)
	countLabel.BackgroundTransparency = 1
	countLabel.Font = Enum.Font.FredokaOne
	countLabel.TextScaled = true
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.TextColor3 = MUSTARD
	countLabel.Text = "0 OPEN"
	countLabel.Parent = header

	cardArea = Instance.new("Frame")
	cardArea.Name = "Cards"
	cardArea.Position = UDim2.fromScale(0, 0.14)
	cardArea.Size = UDim2.fromScale(1, 0.86)
	cardArea.BackgroundTransparency = 1
	cardArea.Parent = back

	--// Overflow chip: appears only when the board is fuller than MaxTickets
	overflowChip = Instance.new("TextLabel")
	overflowChip.Name = "Overflow"
	overflowChip.Size = UDim2.fromScale(CARD_W, CARD_H)
	overflowChip.BackgroundColor3 = CHOC
	overflowChip.Font = Enum.Font.FredokaOne
	overflowChip.TextScaled = true
	overflowChip.TextColor3 = CREAM
	overflowChip.Text = "+0 more"
	overflowChip.Visible = false
	overflowChip.Parent = cardArea

	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0, 8)
	chipCorner.Parent = overflowChip

	boardPart = part
	print(("[OrderBoard] board ready at %s (drawing on the %s face)"):format(
		part:GetFullName(), face.Name))
end

----------------------------------------------------------------
-- Cards
----------------------------------------------------------------
local cards = {} --// OrderNo -> record
local pulseTween = nil
local pulseCard = nil

local function buildCard(order)
	local frame = Instance.new("Frame")
	frame.Name = "Ticket" .. order.OrderNo
	frame.Size = UDim2.fromScale(CARD_W, CARD_H)
	frame.Position = slotPosition(BOARD.MaxTickets) --// slides in from the end
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.Parent = cardArea

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = CHOC
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.04)
	title.Size = UDim2.fromScale(0.92, 0.24)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = order.VIP and VIP_GOLD or CHOC
	title.Text = ("#%d · T%d%s"):format(order.OrderNo, order.Table, order.VIP and " ★" or "")
	title.Parent = frame

	local icons = Instance.new("Frame")
	icons.Name = "Dishes"
	icons.AnchorPoint = Vector2.new(0.5, 0)
	icons.Position = UDim2.fromScale(0.5, 0.3)
	icons.Size = UDim2.fromScale(0.92, 0.42)
	icons.BackgroundTransparency = 1
	icons.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.04, 0)
	layout.Parent = icons

	local barBack = Instance.new("Frame")
	barBack.AnchorPoint = Vector2.new(0.5, 1)
	barBack.Position = UDim2.fromScale(0.5, 0.94)
	barBack.Size = UDim2.fromScale(0.92, 0.14)
	barBack.BackgroundColor3 = BAR_BACK
	barBack.BorderSizePixel = 0
	barBack.Parent = frame

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 4)
	barCorner.Parent = barBack

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = BASIL
	fill.BorderSizePixel = 0
	fill.Parent = barBack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	return {
		Frame = frame,
		Stroke = stroke,
		Title = title,
		Icons = icons,
		Fill = fill,
		DishSig = "",
		FlashUntil = nil, --// set when the party walks out
		MoveTween = nil,
	}
end

--// A ticket can hold DIFFERENT dishes (Burger + Fries); redraw the icon
--// row only when the remaining set actually changes
local function updateDishes(card, dishes)
	local sig = table.concat(dishes, "|")
	if sig == card.DishSig then return end
	card.DishSig = sig

	for _, child in ipairs(card.Icons:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	for index, dishName in ipairs(dishes) do
		local recipe = Config.Recipes[dishName]
		local icon = recipe and recipe.Icon
		if icon and icon ~= "" and icon ~= "rbxassetid://0" then
			local image = Instance.new("ImageLabel")
			image.Size = UDim2.fromScale(0.42, 1)
			image.BackgroundTransparency = 1
			image.Image = icon
			image.ScaleType = Enum.ScaleType.Fit
			image.LayoutOrder = index
			image.Parent = card.Icons
		else
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(0.46, 0.8)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.TextColor3 = CHOC
			label.Text = recipe and recipe.Display or dishName
			label.LayoutOrder = index
			label.Parent = card.Icons
		end
	end
end

local function destroyCard(orderNo)
	local card = cards[orderNo]
	if not card then return end
	cards[orderNo] = nil
	if pulseCard == card then
		if pulseTween then pulseTween:Cancel() end
		pulseTween, pulseCard = nil, nil
	end
	if card.MoveTween then card.MoveTween:Cancel() end
	card.Frame:Destroy()
end

--// The leftmost card, and only while it is critical, breathes tomato
local function setPulse(card)
	if pulseCard == card then return end
	if pulseTween then
		pulseTween:Cancel()
		if pulseCard then pulseCard.Stroke.Color = CHOC end
	end
	pulseCard = card
	pulseTween = nil
	if card then
		pulseTween = TweenService:Create(card.Stroke,
			TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Color = TOMATO })
		pulseTween:Play()
	end
end

----------------------------------------------------------------
-- The refresh: poll, sort, diff, place
----------------------------------------------------------------
local function refresh()
	local bridge = ServerStorage:FindFirstChild("GetOpenOrders")
	if not bridge then return end
	local ok, orders = pcall(function() return bridge:Invoke() end)
	if not ok or type(orders) ~= "table" then return end

	local now = os.clock()
	local seen = {}
	local active = {}

	for _, order in ipairs(orders) do
		seen[order.OrderNo] = true
		local card = cards[order.OrderNo]

		if order.Walkout then
			--// Dying ticket: flash tomato, drop after the flash
			if card and not card.FlashUntil then
				card.FlashUntil = now + BOARD.WalkoutFlashSeconds
				card.Frame.BackgroundColor3 = TOMATO
				card.Title.TextColor3 = Color3.new(1, 1, 1)
			end
		else
			if not card then
				card = buildCard(order)
				cards[order.OrderNo] = card
			end
			updateDishes(card, order.Dishes)
			card.Fill.Size = UDim2.fromScale(math.clamp(order.Patience, 0, 1), 1)
			card.Fill.BackgroundColor3 = patienceColor(order.Patience)
			card.Patience = order.Patience
			table.insert(active, order)
		end
	end

	--// Cards whose party vanished entirely (served, or walkout pawn gone),
	--// and flashed walkouts past their moment
	for orderNo, card in pairs(cards) do
		if not seen[orderNo] and not card.FlashUntil then
			destroyCard(orderNo)
		elseif card.FlashUntil and now >= card.FlashUntil then
			destroyCard(orderNo)
		end
	end

	--// THE SORT: most desperate first, leftmost
	table.sort(active, function(a, b)
		if a.Patience ~= b.Patience then
			return a.Patience < b.Patience
		end
		return a.OrderNo < b.OrderNo --// stable tiebreak
	end)

	--// Overflow: the least urgent collapse into the chip
	local visibleCount = #active
	local overflow = 0
	if visibleCount > BOARD.MaxTickets then
		visibleCount = BOARD.MaxTickets - 1 --// the chip takes the last slot
		overflow = #active - visibleCount
	end

	for rank, order in ipairs(active) do
		local card = cards[order.OrderNo]
		if card then
			if rank <= visibleCount then
				card.Frame.Visible = true
				local target = slotPosition(rank)
				if card.Frame.Position ~= target then
					if card.MoveTween then card.MoveTween:Cancel() end
					card.MoveTween = TweenService:Create(card.Frame,
						TweenInfo.new(BOARD.SortTweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Position = target })
					card.MoveTween:Play()
				end
			else
				card.Frame.Visible = false --// folded into the chip
			end
		end
	end

	if overflow > 0 then
		overflowChip.Visible = true
		overflowChip.Text = ("+%d more"):format(overflow)
		overflowChip.Position = slotPosition(BOARD.MaxTickets)
	else
		overflowChip.Visible = false
	end

	countLabel.Text = ("%d OPEN"):format(#active)

	--// Critical pulse on the single most desperate ticket
	local first = active[1]
	local firstCard = first and cards[first.OrderNo]
	if firstCard and first.Patience < BOARD.CriticalPulseBelow then
		setPulse(firstCard)
	else
		setPulse(nil)
	end
end

----------------------------------------------------------------
-- Boot: wait for the board part, then tick at UpdateHz forever - the
-- bridge simply returns nothing outside RUNNING/CLOSING, so the board
-- empties itself between shifts with no state-machine of its own
----------------------------------------------------------------
task.spawn(function()
	local waited = 0
	local part
	while waited < 20 do
		part = firstTaggedPart("OrderBoard")
		if part then break end
		task.wait(0.5)
		waited += 0.5
	end

	if not part then
		warn("[OrderBoard] no part tagged OrderBoard - the ticket board is disabled")
		return
	end

	buildBoard(part)

	local interval = 1 / math.max(BOARD.UpdateHz, 1)
	local since = 0
	RunService.Heartbeat:Connect(function(dt)
		since += dt
		if since < interval then return end
		since = 0
		refresh()
	end)
end)
