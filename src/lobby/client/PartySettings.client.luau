--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

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
	})
end)

closeBtn.Activated:Connect(function()
	setPanelVisible(false)
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
