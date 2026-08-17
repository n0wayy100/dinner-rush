--[[
	Dinner Rush - DialogueClient
	StarterPlayer.StarterPlayerScripts.Client.DialogueClient  (LocalScript)

	The take-order conversation panel. Built entirely in code.

	STYLE NOTE: owner's call - this panel is plain black-and-white (white
	panel, black text, Gotham) instead of the cream/FredokaOne house style.
	Deliberate deviation for this UI only.

	Render only: the SERVER rolled the flow, picked every phrase (in the
	right voice - "I" for a party of one, "we" for two or more), and holds
	the timeout. This script draws what it was sent and reports which
	button the player tapped. Nothing here decides anything.

	DialogueRemote protocol:
	  server -> client  ("Begin", payload)   open the panel
	                    ("Cancel", token)    close it (timeout / walkout)
	  client -> server  ("Complete", token, dishKeyOrNil)

	Openers (two buttons, pick either):
	  greet       straight to business: customer states order / asks for
	              a recommendation
	  small talk  "How is your day going?" -> the customer's mood line runs
	              into their order ("It's been great! We'll have the
	              Burger, please!") - same flow after that, just warmer

	Then: direct = one confirm tap; recommend = one big button per dish
	(icon + name), the closing beat plays, auto-dismiss.

	{DISH} in a phrase is filled with payload.DishText (direct: the whole
	ticket, e.g. "Burger + Fries") or the picked dish's display name.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local dialogueRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DialogueRemote")

local WHITE = Color3.fromRGB(255, 255, 255)
local BLACK = Color3.fromRGB(0, 0, 0)

local FONT = Enum.Font.GothamMedium
local BEAT_SECONDS = 0.9 --// pause between the closing lines of the recommend flow

local function fill(line, dishText)
	return (line:gsub("{DISH}", dishText))
end

----------------------------------------------------------------
-- Panel: built once, hidden. Bottom-centre, above the hotbar; the stamina
-- bar lives bottom-LEFT (SprintClient), so this space is clear.
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Dialogue_UI"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 22 --// above the stamina bar, below the event banner
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.fromScale(0.5, 0.84)
panel.Size = UDim2.fromScale(0.48, 0.28)
panel.BackgroundColor3 = WHITE
panel.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Thickness = 2
stroke.Color = BLACK
stroke.Parent = panel

--// Speaker chip: black tag = you, outlined white tag = the customer
local chip = Instance.new("TextLabel")
chip.Name = "Speaker"
chip.AnchorPoint = Vector2.new(0, 0.5)
chip.Position = UDim2.fromScale(0.05, 0)
chip.Size = UDim2.fromScale(0.24, 0.16)
chip.BackgroundColor3 = WHITE
chip.Font = FONT
chip.TextScaled = true
chip.TextColor3 = BLACK
chip.Text = "Customer"
chip.Parent = panel

local chipCorner = Instance.new("UICorner")
chipCorner.CornerRadius = UDim.new(0, 6)
chipCorner.Parent = chip

local chipStroke = Instance.new("UIStroke")
chipStroke.Thickness = 2
chipStroke.Color = BLACK
chipStroke.Parent = chip

local chipPad = Instance.new("UIPadding")
chipPad.PaddingLeft = UDim.new(0.08, 0)
chipPad.PaddingRight = UDim.new(0.08, 0)
chipPad.PaddingTop = UDim.new(0.12, 0)
chipPad.PaddingBottom = UDim.new(0.12, 0)
chipPad.Parent = chip

--// The spoken line
local line = Instance.new("TextLabel")
line.Name = "Line"
line.AnchorPoint = Vector2.new(0.5, 0)
line.Position = UDim2.fromScale(0.5, 0.12)
line.Size = UDim2.fromScale(0.92, 0.3)
line.BackgroundTransparency = 1
line.Font = FONT
line.TextScaled = true
line.TextWrapped = true
line.TextColor3 = BLACK
line.Text = ""
line.Parent = panel

--// Button area: everything tappable lives here
local buttons = Instance.new("Frame")
buttons.Name = "Buttons"
buttons.AnchorPoint = Vector2.new(0.5, 1)
buttons.Position = UDim2.fromScale(0.5, 0.96)
buttons.Size = UDim2.fromScale(0.92, 0.5)
buttons.BackgroundTransparency = 1
buttons.Parent = panel

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.Padding = UDim.new(0.05, 0)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
layout.Parent = buttons

local function clearButtons()
	for _, child in ipairs(buttons:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

--// One white outlined button. Returns it; dish rows add their icon onto it.
local function addButton(text, heightScale, onTap)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromScale(1, heightScale)
	button.BackgroundColor3 = WHITE
	button.Font = FONT
	button.TextScaled = true
	button.TextWrapped = true
	button.TextColor3 = BLACK
	button.Text = text
	button.Parent = buttons

	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = button

	local bs = Instance.new("UIStroke")
	bs.Thickness = 2
	bs.Color = BLACK
	bs.Parent = button

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.03, 0)
	pad.PaddingRight = UDim.new(0.03, 0)
	pad.Parent = button

	button.Activated:Connect(onTap)
	return button
end

----------------------------------------------------------------
-- Flow driver. `seq` guards every delayed step: anything that changes the
-- panel bumps it, so a stale task.delay from a previous dialogue can never
-- write over the current one.
----------------------------------------------------------------
local current = nil --// { Token, Payload }
local seq = 0

local function say(speaker, text)
	chip.Text = speaker
	chip.BackgroundColor3 = speaker == "You" and BLACK or WHITE
	chip.TextColor3 = speaker == "You" and WHITE or BLACK
	line.Text = text
end

local function closePanel()
	seq += 1
	current = nil
	clearButtons()
	gui.Enabled = false
end

--// Step two: the customer has spoken (customerText); now the order
--// happens. Direct = one confirm tap; recommend = one button per dish.
local function showOrderStep(mySeq, payload, customerText)
	if seq ~= mySeq then return end
	local lines = payload.Lines
	local dishText = payload.DishText

	clearButtons()
	say("Customer", customerText)

	if payload.Flow == "direct" then
		addButton(fill(lines.Confirm, dishText), 0.45, function()
			if seq ~= mySeq then return end
			dialogueRemote:FireServer("Complete", payload.Token, nil)
			clearButtons()
			say("You", fill(lines.Confirm, dishText))
			task.delay(payload.CloseAfter, function()
				if seq == mySeq then closePanel() end
			end)
		end)
	else
		local rowHeight = math.clamp(1 / math.max(#payload.Dishes, 1) - 0.05, 0.2, 0.38)
		for _, dish in ipairs(payload.Dishes) do
			local button = addButton(dish.Display, rowHeight, function()
				if seq ~= mySeq then return end
				dialogueRemote:FireServer("Complete", payload.Token, dish.Key)

				--// The closing beat: your line, their delight, your confirm
				clearButtons()
				say("You", fill(dish.Line, dish.Display))
				task.delay(BEAT_SECONDS, function()
					if seq ~= mySeq then return end
					say("Customer", fill(lines.Accept, dish.Display))
					task.delay(BEAT_SECONDS, function()
						if seq ~= mySeq then return end
						say("You", fill(lines.Confirm, dish.Display))
						task.delay(payload.CloseAfter, function()
							if seq == mySeq then closePanel() end
						end)
					end)
				end)
			end)

			--// Icon on the right edge; skipped while the id is a placeholder
			local hasIcon = dish.Icon and dish.Icon ~= "" and dish.Icon ~= "rbxassetid://0"
			if hasIcon then
				button.TextXAlignment = Enum.TextXAlignment.Left
				local icon = Instance.new("ImageLabel")
				icon.AnchorPoint = Vector2.new(1, 0.5)
				icon.Position = UDim2.fromScale(0.98, 0.5)
				icon.Size = UDim2.fromScale(0.14, 0.9)
				icon.BackgroundTransparency = 1
				icon.Image = dish.Icon
				icon.ScaleType = Enum.ScaleType.Fit
				icon.Parent = button
			end
		end
	end
end

local function beginDialogue(payload)
	seq += 1
	local mySeq = seq
	current = { Token = payload.Token, Payload = payload }

	local lines = payload.Lines
	local dishText = payload.DishText
	local customerLine = fill(lines.Customer, dishText)

	clearButtons()
	say("Customer", "...")
	gui.Enabled = true

	--// TAP 1, two ways to open: straight to business, or a little small
	--// talk first. Small talk runs the customer's mood line into their
	--// order: "It's been great! We'll have the Burger, please!"
	addButton(lines.Greet, 0.42, function()
		showOrderStep(mySeq, payload, customerLine)
	end)
	addButton(lines.SmallTalkQ, 0.42, function()
		showOrderStep(mySeq, payload, lines.Mood .. " " .. customerLine)
	end)

	--// Belt and braces: the server auto-resolves at Timeout and sends
	--// Cancel, but close locally too in case that message never lands
	task.delay(payload.Timeout, function()
		if seq == mySeq then closePanel() end
	end)
end

dialogueRemote.OnClientEvent:Connect(function(action, a)
	if action == "Begin" then
		beginDialogue(a)
	elseif action == "Cancel" then
		--// Only for the dialogue we are actually showing - a stale Cancel
		--// from an earlier table must not kill the current conversation
		if current and current.Token == a then
			closePanel()
		end
	end
end)

--// Death/respawn mid-conversation: drop the panel; the server's timeout
--// resolves the order on its own
player.CharacterAdded:Connect(function()
	if current then closePanel() end
end)
