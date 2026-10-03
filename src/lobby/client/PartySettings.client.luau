--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local QueueRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("QueueRemote")

print("[PartySettings] script started")

--// Searches the whole subtree, so folders like StarterGui.Inparty do not matter.
--// Keeps waiting rather than giving up, but warns every ~5s so a typo is obvious.
local function needAny(parent, ...)
	local names = {...}
	local waited = 0

	while true do
		for _, name in ipairs(names) do
			local child = parent:FindFirstChild(name, true)
			if child then
				return child
			end
		end

		task.wait(0.1)
		waited += 1
		if waited % 50 == 0 then
			warn(("[PartySettings] still waiting for '%s' under %s"):format(
				table.concat(names, "' or '"), parent:GetFullName()))
		end
	end
end

local function need(parent, name)
	return needAny(parent, name)
end

--// MatchMaking_UI is a ScreenGui nested under the Inparty folder, not a direct child of PlayerGui
local screenGui = need(playerGui, "MatchMaking_UI")
local panel = need(screenGui, "MainPanel")

print("[PartySettings] found panel at", panel:GetFullName())

local column = needAny(panel, "SettingsColumn", "SettingsHandler")
local closeBtn = need(panel, "CloseButton")

-- === Players stepper ===
local playersCard = need(column, "PlayersCard")
local valueLabel = need(playersCard, "ValueLabel")
local minusBtn = need(playersCard, "MinusButton")
local plusBtn = need(playersCard, "PlusButton")

local MIN_PLAYERS = 1
local MAX_PLAYERS = 6
local playerCount = 3

local function refreshPlayers()
	valueLabel.Text = tostring(playerCount)
end

minusBtn.Activated:Connect(function()
	if playerCount > MIN_PLAYERS then
		playerCount -= 1
		refreshPlayers()
	end
end)

plusBtn.Activated:Connect(function()
	if playerCount < MAX_PLAYERS then
		playerCount += 1
		refreshPlayers()
	end
end)

-- === Difficulty cycler ===
local difficultyCard = need(column, "DifficultyCard")
local difficultyBtn = need(difficultyCard, "DifficultyButton")

local DIFFICULTIES = {
	{name = "EASY",   color = Color3.fromRGB(76, 175, 109)},
	{name = "NORMAL", color = Color3.fromRGB(245, 184, 65)},
	{name = "HARD",   color = Color3.fromRGB(229, 72, 77)},
}
local difficultyIndex = 1

local function refreshDifficulty()
	local d = DIFFICULTIES[difficultyIndex]
	difficultyBtn.Text = d.name
	difficultyBtn.BackgroundColor3 = d.color
end

difficultyBtn.Activated:Connect(function()
	difficultyIndex += 1
	if difficultyIndex > #DIFFICULTIES then
		difficultyIndex = 1
	end
	refreshDifficulty()
end)

-- === Friends toggle ===
local friendsCard = need(column, "FriendsCard")
local toggleBtn = need(friendsCard, "ToggleButton")

local friendsOnly = false

local function refreshFriends()
	if friendsOnly then
		toggleBtn.Text = "ON"
		toggleBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 109)
	else
		toggleBtn.Text = "OFF"
		toggleBtn.BackgroundColor3 = Color3.fromRGB(181, 136, 99)
	end
end

toggleBtn.Activated:Connect(function()
	friendsOnly = not friendsOnly
	refreshFriends()
end)

-- === Map selection ===
--// A pop-up rather than a cycler: maps have identity - a cuisine, a name, a
--// blurb - and a button that flips between two words cannot carry that. It
--// also gives unbuilt maps somewhere to sit as COMING SOON instead of being
--// invisible until the day they ship.
--//
--// Code-built on purpose: this is a new panel rather than a fourth settings
--// card, so there is no hand-made art for it to clash with. The palette and
--// font below are lifted from the cards so it still reads as the same UI.

local MAP_CREAM  = Color3.fromRGB(247, 236, 214)
local MAP_INK    = Color3.fromRGB(59, 43, 32)     -- the cards' chocolate outline
local MAP_HEADER = Color3.fromRGB(229, 72, 77)    -- the HARD red
local MAP_GREEN  = Color3.fromRGB(76, 175, 109)   -- the EASY green
local MAP_LOCKED = Color3.fromRGB(181, 136, 99)   -- the OFF brown
local MAP_FONT   = Enum.Font.FredokaOne

--// The button is optional: a lobby without it still works, it just cannot
--// change map. Never hang the whole panel waiting for one.
local mapsButton = panel:FindFirstChild("MapsButton", true)

local mapId = Config.DefaultMapId
local mapOverlay = nil
local mapCardButtons = {}   --// mapId -> its pick button, so states can refresh

local function currentMap()
	return Config.MapById(mapId) or Config.Maps[1]
end

--// The button label stays "MAPS" whatever is chosen - it is the door to the
--// picker, not a readout of the selection. Which map is picked is shown
--// inside the panel, where there is room to show it properly.

local function refreshMapCards()
	for id, button in pairs(mapCardButtons) do
		local map = Config.MapById(id)
		if map then
			if not map.Available then
				button.Text = "COMING SOON"
				button.BackgroundColor3 = MAP_LOCKED
			elseif id == mapId then
				button.Text = "SELECTED"
				button.BackgroundColor3 = MAP_GREEN
			else
				button.Text = "CHOOSE"
				button.BackgroundColor3 = MAP_LOCKED
			end
		end
	end
end

local function closeMapOverlay()
	if mapOverlay then
		mapOverlay.Visible = false
	end
end

local function buildMapCard(map, parent, order)
	--// THE CARD IS THE ART. The whole bar is the map image; only the pick
	--// button sits on top. The art carries its own title, so nothing here
	--// draws a name over it.
	local card = Instance.new("Frame")
	card.Name = map.Id .. "Card"
	--// Full width; the aspect constraint below sets the height. The 9999 is
	--// just headroom for it to fit within - it is never the real height.
	card.Size = UDim2.new(1, 0, 0, 9999)
	card.BackgroundColor3 = Color3.fromRGB(238, 228, 210)
	card.BorderSizePixel = 0
	card.ClipsDescendants = true   --// keeps the image inside the rounded corners
	card.LayoutOrder = order
	card.Parent = parent

	local CARD_RADIUS = UDim.new(0, 10)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = CARD_RADIUS
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = MAP_INK
	stroke.Thickness = 3
	stroke.Parent = card

	--// HEIGHT COMES FROM THE ART, not a number someone has to keep in sync.
	--// The bar takes the width it is given and derives its height from the
	--// image's shape, so the picture fills it exactly - no cream showing, no
	--// edge cropped - whatever width the panel happens to be.
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = Config.MapCardAspect
	ratio.DominantAxis = Enum.DominantAxis.Width
	ratio.AspectType = Enum.AspectType.FitWithinMaxSize
	ratio.Parent = card

	local imageId = tostring(map.ImageId or "")
	if imageId:match("^%d+$") then
		imageId = "rbxassetid://" .. imageId
	end
	local hasArt = imageId ~= "" and imageId ~= "rbxassetid://0"

	if hasArt then
		local image = Instance.new("ImageLabel")
		image.Name = "MapImage"
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.Image = imageId
		--// FIT, not Crop: the art carries its own title, and cropping ate the
		--// first letter of it. Fit always shows the whole picture; a shape
		--// mismatch leaves cream at the sides instead of losing an edge.
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = card

		--// ClipsDescendants clips to a RECTANGLE, not to the UICorner radius -
		--// so a square image punches its corners straight through the rounded
		--// card and past the outline. The image has to round itself, with the
		--// same radius, or the two edges never line up.
		local imageCorner = Instance.new("UICorner")
		imageCorner.CornerRadius = CARD_RADIUS
		imageCorner.Parent = image

	else
		--// PLACEHOLDER, not a broken card. Until the art is uploaded the bar
		--// shows the map's initial, so the layout is already right and only
		--// the picture is missing.
		local initial = Instance.new("TextLabel")
		initial.Name = "Placeholder"
		initial.Size = UDim2.fromScale(1, 1)
		initial.BackgroundTransparency = 1
		initial.Font = MAP_FONT
		initial.TextSize = 52
		initial.TextXAlignment = Enum.TextXAlignment.Right
		initial.Position = UDim2.fromOffset(-24, 0)
		--// Was almost the same colour as the card behind it
		initial.TextColor3 = Color3.fromRGB(196, 172, 138)
		initial.Text = string.sub(map.Display or "?", 1, 1)
		initial.Parent = card
	end

	local pick = Instance.new("TextButton")
	pick.Name = "PickButton"
	pick.AnchorPoint = Vector2.new(1, 0.5)
	pick.Position = UDim2.new(1, -14, 0.5, 0)
	pick.Size = UDim2.fromOffset(128, 42)
	pick.Font = MAP_FONT
	pick.TextSize = 16
	pick.TextColor3 = Color3.new(1, 1, 1)
	pick.AutoButtonColor = map.Available == true
	pick.Active = map.Available == true
	pick.Text = ""
	pick.Parent = card

	local pickCorner = Instance.new("UICorner")
	pickCorner.CornerRadius = UDim.new(0, 8)
	pickCorner.Parent = pick

	local pickStroke = Instance.new("UIStroke")
	pickStroke.Color = MAP_INK
	pickStroke.Thickness = 2.5
	pickStroke.Parent = pick

	mapCardButtons[map.Id] = pick

	pick.Activated:Connect(function()
		--// Locked maps are visible but never selectable. The server checks
		--// again anyway - this is only so the click does not lie.
		if not map.Available then
			return
		end
		mapId = map.Id
		refreshMapCards()
		closeMapOverlay()
		print(("[PartySettings] map set to %s"):format(map.Id))
	end)

	return card
end

local function buildMapOverlay()
	local overlay = Instance.new("Frame")
	overlay.Name = "MapSelect"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.45
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 50
	overlay.Visible = false
	overlay.Parent = screenGui

	local box = Instance.new("Frame")
	box.Name = "Panel"
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromOffset(520, 400)
	box.BackgroundColor3 = MAP_CREAM
	box.BorderSizePixel = 0
	box.ZIndex = 51
	box.Parent = overlay

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 16)
	boxCorner.Parent = box

	local boxStroke = Instance.new("UIStroke")
	boxStroke.Color = MAP_INK
	boxStroke.Thickness = 4
	boxStroke.Parent = box

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.Size = UDim2.new(1, -24, 0, 48)
	header.Position = UDim2.fromOffset(12, 12)
	header.BackgroundColor3 = MAP_HEADER
	header.BorderSizePixel = 0
	header.Font = MAP_FONT
	header.TextSize = 26
	header.TextColor3 = Color3.new(1, 1, 1)
	header.Text = "CHOOSE YOUR MAP"
	header.Parent = box

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 10)
	headerCorner.Parent = header

	local headerStroke = Instance.new("UIStroke")
	headerStroke.Color = MAP_INK
	headerStroke.Thickness = 3
	headerStroke.Parent = header

	--// Scrolling so a fifth map costs nothing but a Config row
	local list = Instance.new("ScrollingFrame")
	list.Name = "MapList"
	list.Position = UDim2.fromOffset(12, 72)
	list.Size = UDim2.new(1, -24, 1, -84)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = box

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	--// A UIStroke draws OUTSIDE its frame, and a ScrollingFrame clips anything
	--// past its edge - so a card sitting flush against the boundary gets its
	--// outline shaved off. This padding is the room the strokes need.
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop = UDim.new(0, 6)
	listPad.PaddingBottom = UDim.new(0, 6)
	listPad.PaddingLeft = UDim.new(0, 6)
	listPad.PaddingRight = UDim.new(0, 12)   --// extra: the scrollbar lives here
	listPad.Parent = list

	for index, map in ipairs(Config.Maps) do
		buildMapCard(map, list, index)
	end

	--// Everything inside the panel has to out-draw the dim behind it. Done
	--// after the cards exist so it catches them too.
	--// Lift the whole panel above the dim behind it. OFFSET, not a flat
	--// assignment: each card layers image, then wash, then text, and setting
	--// them all equal would let that order come apart.
	for _, descendant in ipairs(box:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = descendant.ZIndex + 52
		end
	end

	--// The X sits above the header it overlaps, so it is set last
	local close = Instance.new("TextButton")
	close.Name = "CloseMaps"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -6, 0, 6)
	close.Size = UDim2.fromOffset(40, 40)
	close.BackgroundColor3 = MAP_LOCKED
	close.Font = MAP_FONT
	close.TextSize = 22
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Text = "X"
	close.ZIndex = 55
	close.Parent = box

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = close

	local closeStroke = Instance.new("UIStroke")
	closeStroke.Color = MAP_INK
	closeStroke.Thickness = 2.5
	closeStroke.Parent = close

	close.Activated:Connect(closeMapOverlay)

	return overlay
end

if mapsButton and mapsButton:IsA("GuiButton") then
	mapOverlay = buildMapOverlay()
	refreshMapCards()

	mapsButton.Activated:Connect(function()
		if mapOverlay then
			mapOverlay.Visible = not mapOverlay.Visible
			if mapOverlay.Visible then
				refreshMapCards()
			end
		end
	end)
	print("[PartySettings] map selection wired to " .. mapsButton:GetFullName())
else
	warn("[PartySettings] no MapsButton in the panel - map selection unavailable;"
		.. " parties will use " .. tostring(Config.DefaultMapId))
end

-- === Create button ===
--// Confirms the settings and opens the zone to everyone else.
--// Built in code if you have not added one to the panel yet.
local function findCreateButton()
	for _, child in ipairs(panel:GetDescendants()) do
		if child:IsA("GuiButton") then
			local lowered = string.lower(child.Name)
			if string.find(lowered, "create", 1, true)
				or string.find(lowered, "confirm", 1, true)
				or string.find(lowered, "start", 1, true) then
				return child
			end
		end
	end

	--// Nothing named clearly, so fall back to the one spare button sitting
	--// directly in the panel (not the close button, not a settings control)
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("GuiButton") and child ~= closeBtn and not child:IsDescendantOf(column) then
			warn(("[PartySettings] using '%s' as the create button - rename it to CreateButton"):format(child.Name))
			return child
		end
	end

	return nil
end

local createBtn = findCreateButton()
if not createBtn then
	warn("[PartySettings] No create button in MainPanel - building a fallback one")
	createBtn = Instance.new("TextButton")
	createBtn.Name = "CreateButton"
	createBtn.AnchorPoint = Vector2.new(0.5, 1)
	createBtn.Position = UDim2.new(0.5, 0, 1, -16)
	createBtn.Size = UDim2.new(1, -32, 0, 48)
	createBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 109)
	createBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	createBtn.Font = Enum.Font.GothamBold
	createBtn.TextSize = 20
	createBtn.Text = "CREATE PARTY"
	createBtn.Parent = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = createBtn
end

-- === Panel state ===

local function setPanelVisible(state)
	if not state then
		--// Only hide the panel itself - its ancestors may hold the Leave button
		panel.Visible = false
		return
	end

	screenGui.Enabled = true

	--// A hidden ancestor hides the panel even when the panel itself is visible
	local object = panel
	while object and object ~= screenGui do
		if object:IsA("GuiObject") then
			object.Visible = true
		end
		object = object.Parent
	end
end

--// Mirrors whatever the server hands back so the UI never drifts from the real settings
local function applySettings(settings)
	if typeof(settings) ~= "table" then return end

	local max = tonumber(settings.MaxPlayers)
	if max then
		playerCount = math.clamp(math.floor(max), MIN_PLAYERS, MAX_PLAYERS)
	end

	for index, d in ipairs(DIFFICULTIES) do
		if d.name == settings.Difficulty then
			difficultyIndex = index
			break
		end
	end

	friendsOnly = settings.FriendsOnly == true

	refreshPlayers()
	refreshDifficulty()
	refreshFriends()
end

createBtn.Activated:Connect(function()
	createBtn.Active = false --// debounce, the server replies with PartyCreated

	QueueRemote:FireServer("CreateParty", {
		MaxPlayers = playerCount,
		Difficulty = DIFFICULTIES[difficultyIndex].name,
		FriendsOnly = friendsOnly,
		MapId = mapId,
	})
end)

--// X IS LEAVE, not just "hide the panel". Closing it any other way would
--// strand the host in the zone holding it open for everyone with no visible
--// way out - the Leave button is deliberately hidden until the party exists.
closeBtn.Activated:Connect(function()
	setPanelVisible(false) --// instant feedback; the server confirms with LeaveParty
	QueueRemote:FireServer("LeaveParty")
end)

QueueRemote.OnClientEvent:Connect(function(Action, Settings)
	print("[PartySettings] received", Action)

	if Action == "HostParty" then
		--// We were first into the zone, so we configure the party
		applySettings(Settings)
		createBtn.Active = true
		setPanelVisible(true)
	elseif Action == "PartyCreated" then
		applySettings(Settings)
		setPanelVisible(false)
	elseif Action == "JoinParty" or Action == "LeaveParty" then
		--// Joiners never see the settings panel
		applySettings(Settings)
		setPanelVisible(false)
	end
end)

refreshPlayers()
refreshDifficulty()
refreshFriends()
setPanelVisible(false)
