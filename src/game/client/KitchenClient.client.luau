--[[
	Dinner Rush - KitchenClient
	StarterPlayer.StarterPlayerScripts.Client.KitchenClient  (LocalScript)

	The ingredient picker for sources that stock more than one thing (the
	fridge holds patty and steak). Built entirely in code - no manual UI.

	Intent only: clicking an item asks the server, which re-checks the carry
	limit and that you are actually standing at a fridge before handing
	anything over. Nothing here is trusted.

	Icons come from Config.Ingredients[*].Icon. While those are still
	rbxassetid://0 the buttons show the name alone and the row simply has no
	picture - no broken-image box.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local kitchenRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("KitchenRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local WARM = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local GREY = Color3.fromRGB(196, 188, 178)      -- out of stock row
local GREY_TEXT = Color3.fromRGB(122, 112, 102)

--// Friendlier titles than the raw tag name
local TITLES = {
	Fridge = "FRIDGE",
	DryShelf = "DRY SHELF",
}

----------------------------------------------------------------
-- Built once, hidden; repopulated each time it opens
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "KitchenMenu_UI"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 20
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.55)
panel.Size = UDim2.fromScale(0.3, 0.34)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local ratio = Instance.new("UIAspectRatioConstraint")
ratio.AspectRatio = 1.25
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
title.Position = UDim2.fromScale(0.5, 0.04)
title.Size = UDim2.fromScale(0.7, 0.16)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.TextColor3 = CHOC
title.Text = "FRIDGE"
title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.fromScale(0.97, 0.04)
closeBtn.Size = UDim2.fromScale(0.13, 0.14)
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
list.Name = "ItemList"
list.AnchorPoint = Vector2.new(0.5, 0)
list.Position = UDim2.fromScale(0.5, 0.24)
list.Size = UDim2.fromScale(0.9, 0.62)
list.BackgroundTransparency = 1
list.Parent = panel

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.Padding = UDim.new(0.04, 0)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = list

local hint = Instance.new("TextLabel")
hint.AnchorPoint = Vector2.new(0.5, 1)
hint.Position = UDim2.fromScale(0.5, 0.99)
hint.Size = UDim2.fromScale(0.9, 0.1)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.FredokaOne
hint.TextScaled = true
hint.TextColor3 = CHOC
hint.TextTransparency = 0.4
hint.Text = ""
hint.Parent = panel

local function closeMenu()
	gui.Enabled = false
end

closeBtn.Activated:Connect(closeMenu)

local function clearList()
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

--// Remembered so a StockChanged push for the source we are showing can
--// redraw it, and one for any other source can be ignored
local currentSource = nil

local function openMenu(sourceName, items)
	currentSource = sourceName
	clearList()
	title.Text = TITLES[sourceName] or string.upper(tostring(sourceName))
	hint.Text = "Pick an ingredient"

	--// Rows share the height so two items or five both look deliberate
	local rowHeight = math.clamp(1 / math.max(#items, 1) - 0.04, 0.15, 0.42)

	for _, item in ipairs(items) do
		local count = tonumber(item.Count) or 0
		local inStock = count > 0

		local button = Instance.new("TextButton")
		button.Name = item.Name
		button.Size = UDim2.fromScale(1, rowHeight)
		button.BackgroundColor3 = inStock and MUSTARD or GREY
		button.Text = ""
		button.AutoButtonColor = inStock
		button.Parent = list

		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 10)
		bc.Parent = button

		local bs = Instance.new("UIStroke")
		bs.Thickness = 2.5
		bs.Color = CHOC
		bs.Parent = button

		--// Skip the ImageLabel entirely while the id is still a placeholder,
		--// so a missing icon is blank space rather than a broken-image box
		local hasIcon = item.Icon and item.Icon ~= "" and item.Icon ~= "rbxassetid://0"
		if hasIcon then
			--// Icon sits on the RIGHT edge of the row, text on the left
			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.AnchorPoint = Vector2.new(1, 0.5)
			icon.Position = UDim2.fromScale(0.96, 0.5)
			icon.Size = UDim2.fromScale(0.22, 0.82)
			icon.BackgroundTransparency = 1
			icon.Image = item.Icon
			icon.ImageTransparency = inStock and 0 or 0.55
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Parent = button
		end

		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.Position = UDim2.fromScale(0.07, 0.5)
		label.Size = UDim2.fromScale(hasIcon and 0.48 or 0.62, 0.6)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = inStock and CHOC or GREY_TEXT
		label.Text = item.Display
		label.Parent = button

		--// Count sits between the name and the icon, right-aligned so the
		--// numbers line up down the column
		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "Count"
		countLabel.AnchorPoint = Vector2.new(1, 0.5)
		countLabel.Position = UDim2.fromScale(hasIcon and 0.72 or 0.94, 0.5)
		countLabel.Size = UDim2.fromScale(0.2, 0.5)
		countLabel.BackgroundTransparency = 1
		countLabel.Font = Enum.Font.FredokaOne
		countLabel.TextScaled = true
		countLabel.TextXAlignment = Enum.TextXAlignment.Right
		countLabel.TextColor3 = inStock and CHOC or GREY_TEXT
		countLabel.Text = ("%dx"):format(count)
		countLabel.Parent = button

		button.Activated:Connect(function()
			if not inStock then
				hint.Text = "Out of stock!"
				return
			end
			kitchenRemote:FireServer("Take", item.Name)
			closeMenu()
		end)
	end

	gui.Enabled = true
end

kitchenRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "OpenSourceMenu" then
		openMenu(a, b)
	elseif action == "StockChanged" then
		--// Only redraw if this is the source we are actually looking at,
		--// otherwise a fridge take would rebuild an open shelf menu
		if gui.Enabled and currentSource == a then
			openMenu(a, b)
		end
	elseif action == "TakeDenied" then
		--// Reopen briefly to say why, rather than the click seeming to do nothing
		hint.Text = tostring(a or "Cannot take that right now")
		gui.Enabled = true
		task.delay(1.4, closeMenu)
	end
	--// A successful take needs no message: the Tool arriving in the hotbar is it
end)
