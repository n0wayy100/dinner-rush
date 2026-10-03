--[[
	Dinner Rush - OrderTabletClient
	StarterPlayer.StarterPlayerScripts.Client.OrderTabletClient  (LocalScript)

	THE ORDER TABLET (Config.OrderTablet, owner design Sep 29 2026): taking an
	order opens a small BLACK TABLET on the right with a BLUE SCREEN. The screen
	shows the customer's order (their dishes); below are the map's FOOD ICON
	BUTTONS. Press the icon of each dish they asked for. Right press ticks it off
	(green); wrong press buzzes (red, no penalty). Press them all and the order
	is SENT.

	Render + intent only - the server owns the order (it is the party's fixed
	ticket) and closes the tablet on completion / timeout / walkout. Driven by
	OrderTabletRemote:
	  S->C  "Open" {Token, Menu, Wanted} / "Close" (token, ok)
	  C->S  "Done" (token)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local tabletRemote = remotes:WaitForChild("OrderTabletRemote")

--// Download the waiter's order animation as soon as the player joins. The
--// SERVER plays it, but this client is the one that has to draw it, and
--// without the keyframes already on hand the first order of every session
--// stood still while they downloaded.
task.spawn(function()
	local ContentProvider = game:GetService("ContentProvider")
	local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
	local settings = Config.Dialogue and Config.Dialogue.OrderAnim
	if not settings or settings.Enabled == false then return end

	local animations = {}
	for _, id in ipairs({ settings.PullOut, settings.Tap }) do
		if type(id) == "string" and id ~= "" then
			local animation = Instance.new("Animation")
			animation.AnimationId = id:match("^%d+$") and ("rbxassetid://" .. id) or id
			table.insert(animations, animation)
		end
	end
	if #animations > 0 then
		pcall(ContentProvider.PreloadAsync, ContentProvider, animations)
	end
end)

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local BASIL = Color3.fromRGB(76, 175, 109)
local BASIL_DIM = Color3.fromRGB(44, 92, 60)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local TABLET_BLACK = Color3.fromRGB(28, 28, 34)
local SCREEN_BLUE = Color3.fromRGB(34, 92, 168)
local SCREEN_BLUE_DEEP = Color3.fromRGB(22, 62, 122)
local BTN = Color3.fromRGB(48, 50, 60)

local session = nil

--// native chat bubble over a character/part - the SHORT interactive line the
--// customer says while you tap their order (same look as the old dialogue)
local function speak(adornee, text)
	if not adornee or not text or text == "" then return end
	pcall(function() TextChatService:DisplayBubble(adornee, text) end)
end
local function speakSelf(text)
	if player.Character then speak(player.Character, text) end
end

local TABLET_IN = UDim2.fromScale(0.985, 0.52)  --// resting spot, right-centre
local TABLET_OUT = UDim2.fromScale(1.35, 0.52)   --// off-screen right
local BUBBLE_LEAD = 0.8  --// the customer speaks this long BEFORE the tablet slides in

--// one order row on the blue screen (icon + name + a check). Shared by the
--// DIRECT order checklist and the RECOMMEND picks as they come in.
local function makeOrderRow(parent, dish, layoutOrder, total, checkText, checkColor)
	local row = Instance.new("Frame")
	row.Name = "Order" .. layoutOrder
	row.Size = UDim2.fromScale(1, 1 / math.max(total, 3) - 0.05)
	row.BackgroundColor3 = Color3.fromRGB(22, 62, 122) --// SCREEN_BLUE_DEEP
	row.BackgroundTransparency = 0.35
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	local rCorner = Instance.new("UICorner")
	rCorner.CornerRadius = UDim.new(0.3, 0)
	rCorner.Parent = row

	local check = Instance.new("TextLabel")
	check.Size = UDim2.fromScale(0.16, 0.9)
	check.Position = UDim2.fromScale(0.02, 0.05)
	check.BackgroundTransparency = 1
	check.Font = Enum.Font.FredokaOne
	check.TextScaled = true
	check.Text = checkText or "o"
	check.TextColor3 = checkColor or Color3.fromRGB(150, 190, 235)
	check.Parent = row

	local hasIcon = type(dish.Icon) == "string" and dish.Icon ~= ""
	if hasIcon then
		local icon = Instance.new("ImageLabel")
		icon.Size = UDim2.fromScale(0.18, 0.86)
		icon.Position = UDim2.fromScale(0.2, 0.07)
		icon.BackgroundTransparency = 1
		icon.Image = dish.Icon
		icon.Parent = row
	end

	local name = Instance.new("TextLabel")
	name.Size = UDim2.fromScale(hasIcon and 0.58 or 0.78, 0.9)
	name.Position = UDim2.fromScale(hasIcon and 0.4 or 0.2, 0.05)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.Text = dish.Display or dish.Key
	name.TextColor3 = Color3.fromRGB(255, 246, 233) --// CREAM
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Parent = row
	local nameCap = Instance.new("UITextSizeConstraint")
	nameCap.MaxTextSize = 16
	nameCap.Parent = name

	return row, check
end

local function teardown()
	if not session then return end
	local gui, tablet = session.Gui, session.Tablet
	session = nil
	--// slide back off the right edge, then destroy
	if tablet then
		local out = TweenService:Create(tablet,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = TABLET_OUT })
		out:Play()
		out.Completed:Connect(function()
			if gui then gui:Destroy() end
		end)
	elseif gui then
		gui:Destroy()
	end
end

--// flash a food button a colour, then settle back
local function flashButton(frame, colour)
	if not frame then return end
	frame.BackgroundColor3 = colour
	TweenService:Create(frame, TweenInfo.new(0.35, Enum.EasingStyle.Quad),
		{ BackgroundColor3 = BTN }):Play()
end

local function checkDone()
	if not session then return end
	for _, item in ipairs(session.Wanted) do
		if not item.Done then return end
	end
	--// every ordered dish is in - send it
	local token = session.Token
	tabletRemote:FireServer("Done", token)
	if session.Status then
		session.Status.Text = "ORDER SENT!"
		session.Status.TextColor3 = BASIL
	end
	speakSelf(session.ConfirmLine) --// the waiter confirms out loud
	task.delay(0.9, function()
		if session and session.Token == token then teardown() end
	end)
end

local function handlePress(key)
	if not session then return end

	--// RECOMMEND flow (the indecisive party): pick ONE dish per customer, then
	--// the whole list becomes their order - nothing is auto-chosen.
	if session.Flow == "recommend" then
		flashButton(session.Buttons[key], BASIL)
		table.insert(session.Picks, key)
		--// show the pick on the blue screen as a fresh ticked row
		if session.List and session.MenuByKey[key] then
			local row, check = makeOrderRow(session.List, session.MenuByKey[key],
				#session.Picks, session.RecommendCount or 1, "✓", BASIL)
			row.BackgroundColor3 = BASIL_DIM
		end
		local count, need = #session.Picks, session.RecommendCount or 1
		if count < need then
			if session.Status then
				session.Status.Text = ("Recommended %d/%d"):format(count, need)
			end
			return
		end
		--// every customer covered - send the recommendations
		local token = session.Token
		tabletRemote:FireServer("Recommend", token, session.Picks)
		if session.Status then
			session.Status.Text = "RECOMMENDED!"
			session.Status.TextColor3 = BASIL
		end
		speakSelf(session.ConfirmLine)
		task.delay(0.9, function()
			if session and session.Token == token then teardown() end
		end)
		return
	end

	--// DIRECT flow: tick off each ordered dish
	for _, item in ipairs(session.Wanted) do
		if item.Key == key and not item.Done then
			item.Done = true
			item.Check.Text = "✓"
			item.Check.TextColor3 = BASIL
			item.Row.BackgroundColor3 = BASIL_DIM
			flashButton(session.Buttons[key], BASIL)
			checkDone()
			return
		end
	end
	--// not on the order (or already ticked): a harmless buzz
	flashButton(session.Buttons[key], TOMATO)
end

local function buildTablet(data)
	local gui = Instance.new("ScreenGui")
	gui.Name = "OrderTablet_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 48
	gui.Parent = playerGui

	--// the black tablet, right-centre
	local tablet = Instance.new("Frame")
	tablet.Name = "Tablet"
	tablet.AnchorPoint = Vector2.new(1, 0.5)
	tablet.Position = UDim2.fromScale(0.985, 0.52)
	tablet.Size = UDim2.fromScale(0.22, 0.62)
	tablet.BackgroundColor3 = TABLET_BLACK
	tablet.BorderSizePixel = 0
	tablet.Parent = gui
	local tCorner = Instance.new("UICorner")
	tCorner.CornerRadius = UDim.new(0.06, 0)
	tCorner.Parent = tablet
	local tStroke = Instance.new("UIStroke")
	tStroke.Thickness = 3
	tStroke.Color = Color3.fromRGB(12, 12, 16)
	tStroke.Parent = tablet
	local tPad = Instance.new("UIPadding")
	tPad.PaddingTop = UDim.new(0.03, 0)
	tPad.PaddingBottom = UDim.new(0.03, 0)
	tPad.PaddingLeft = UDim.new(0.05, 0)
	tPad.PaddingRight = UDim.new(0.05, 0)
	tPad.Parent = tablet

	--// THE BLUE SCREEN: shows the order
	local screen = Instance.new("Frame")
	screen.Name = "Screen"
	screen.Size = UDim2.fromScale(1, 0.42)
	screen.Position = UDim2.fromScale(0, 0)
	screen.BackgroundColor3 = SCREEN_BLUE
	screen.BorderSizePixel = 0
	screen.Parent = tablet
	local sGrad = Instance.new("UIGradient")
	sGrad.Rotation = 90
	sGrad.Color = ColorSequence.new(SCREEN_BLUE, SCREEN_BLUE_DEEP)
	sGrad.Parent = screen
	local sCorner = Instance.new("UICorner")
	sCorner.CornerRadius = UDim.new(0.06, 0)
	sCorner.Parent = screen
	local sStroke = Instance.new("UIStroke")
	sStroke.Thickness = 2
	sStroke.Color = Color3.fromRGB(120, 180, 235)
	sStroke.Parent = screen

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(0.94, 0.2)
	title.Position = UDim2.fromScale(0.03, 0.04)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = (data.Flow == "recommend") and "RECOMMEND?" or "TABLE ORDER"
	title.TextColor3 = Color3.fromRGB(200, 226, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = screen
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 18
	titleCap.Parent = title

	--// the ordered dishes, each a row that ticks green when pressed
	local list = Instance.new("Frame")
	list.Size = UDim2.fromScale(0.94, 0.7)
	list.Position = UDim2.fromScale(0.03, 0.27)
	list.BackgroundTransparency = 1
	list.Parent = screen
	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Padding = UDim.new(0.04, 0)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list

	--// DIRECT: the fixed order, ticked off as pressed. RECOMMEND: the list
	--// starts empty and each pick you make APPEARS here as a row (green check).
	local wanted = {}
	local wantedList = data.Wanted or {}
	for i, dish in ipairs(wantedList) do
		local row, check = makeOrderRow(list, dish, i, #wantedList)
		table.insert(wanted, { Key = dish.Key, Done = false, Row = row, Check = check })
	end

	--// FOOD BUTTONS: the map's menu, press to input
	local grid = Instance.new("Frame")
	grid.Name = "Buttons"
	grid.Size = UDim2.fromScale(1, 0.53)
	grid.Position = UDim2.fromScale(0, 0.47)
	grid.BackgroundTransparency = 1
	grid.Parent = tablet
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromScale(0.46, 0.46)
	gridLayout.CellPadding = UDim2.fromScale(0.06, 0.06)
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	local buttons = {}
	local menuByKey = {}
	for i, dish in ipairs(data.Menu or {}) do
		menuByKey[dish.Key] = dish
		local button = Instance.new("TextButton")
		button.Name = "Btn_" .. dish.Key
		button.BackgroundColor3 = BTN
		button.AutoButtonColor = true
		button.Text = ""
		button.LayoutOrder = i
		button.Parent = grid
		local bCorner = Instance.new("UICorner")
		bCorner.CornerRadius = UDim.new(0.12, 0)
		bCorner.Parent = button
		local bStroke = Instance.new("UIStroke")
		bStroke.Thickness = 2
		bStroke.Color = Color3.fromRGB(14, 14, 18)
		bStroke.Parent = button

		local hasIcon = type(dish.Icon) == "string" and dish.Icon ~= ""
		if hasIcon then
			local img = Instance.new("ImageLabel")
			img.Size = UDim2.fromScale(0.7, 0.62)
			img.Position = UDim2.fromScale(0.15, 0.06)
			img.BackgroundTransparency = 1
			img.Image = dish.Icon
			img.Parent = button
		end
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(0.92, hasIcon and 0.3 or 0.9)
		label.Position = UDim2.fromScale(0.04, hasIcon and 0.68 or 0.05)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.Text = dish.Display or dish.Key
		label.TextColor3 = CREAM
		label.Parent = button
		local labelCap = Instance.new("UITextSizeConstraint")
		labelCap.MaxTextSize = 15
		labelCap.Parent = label

		local key = dish.Key
		button.Activated:Connect(function()
			handlePress(key)
		end)
		buttons[key] = button
	end

	--// status line under the buttons
	local status = Instance.new("TextLabel")
	status.Size = UDim2.fromScale(1, 0.06)
	status.Position = UDim2.fromScale(0, 1.01)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.FredokaOne
	status.TextScaled = true
	status.Text = (data.Flow == "recommend")
		and ("Recommended 0/%d"):format(data.RecommendCount or 1)
		or "Tap what they ordered!"
	status.TextColor3 = MUSTARD
	status.Parent = tablet
	local statusCap = Instance.new("UITextSizeConstraint")
	statusCap.MaxTextSize = 16
	statusCap.Parent = status

	return gui, tablet, wanted, buttons, status, list, menuByKey
end

tabletRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "Open" then
		teardown()
		local data = a
		local gui, tablet, wanted, buttons, status, list, menuByKey = buildTablet(data)
		session = {
			Token = data.Token,
			Gui = gui,
			Tablet = tablet,
			Wanted = wanted,
			Buttons = buttons,
			Status = status,
			List = list,
			MenuByKey = menuByKey,
			Flow = data.Flow,
			RecommendCount = data.RecommendCount or 1,
			Picks = {},
			ConfirmLine = data.ConfirmLine,
		}
		--// the customer says their order out loud FIRST...
		speak(data.Speaker, data.OrderLine)
		--// ...THEN, after a short beat, the tablet slides in from the right
		tablet.Position = TABLET_OUT
		local token = data.Token
		task.delay(BUBBLE_LEAD, function()
			if session and session.Token == token then
				TweenService:Create(tablet,
					TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Position = TABLET_IN }):Play()
			end
		end)
	elseif action == "Close" then
		if session and session.Token == a then
			teardown()
		end
	end
end)
