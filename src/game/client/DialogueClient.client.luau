--[[
	Dinner Rush - DialogueClient
	StarterPlayer.StarterPlayerScripts.Client.DialogueClient  (LocalScript)

	The take-order conversation, styled fully after Work at a Pizza
	Place (owner request, Sep 2026):
	  - speech is NATIVE Roblox chat bubbles (TextChatService
	    :DisplayBubble): the customer's lines pop over THEIR head, your
	    picked line pops over YOUR head, exactly like the reference
	  - your reply choices are clean white cards at the bottom-left -
	    thin grey border, soft dark text, auto-height, simple font
	No panel, no custom bubbles, no speaker chips.

	Render only: the SERVER rolled the flow, picked every phrase (in the
	right voice - "I" for a party of one, "we" for two or more), and
	holds the timeout. This script draws the choices and reports which
	one was tapped. Nothing here decides anything.

	DialogueRemote protocol (unchanged; payload carries Speaker = the
	party leader's root part, where their bubbles hang):
	  server -> client  ("Begin", payload)   open the conversation
	                    ("Cancel", token)    close it (timeout / walkout)
	  client -> server  ("Complete", token, dishKeyOrNil)

	{DISH} in a phrase is filled with payload.DishText (direct: the whole
	ticket, e.g. "Burger + Fries") or the picked dish's display name.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local dialogueRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DialogueRemote")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

--// Snappy bubbles (owner call). BubbleDuration is global, so player
--// chat fades at the same pace - one rhythm everywhere.
task.spawn(function()
	local bubbleConfig = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
		or TextChatService:WaitForChild("BubbleChatConfiguration", 10)
	if bubbleConfig then
		bubbleConfig.BubbleDuration = Config.Dialogue.BubbleSeconds
	end
end)

local FONT = Enum.Font.SourceSans --// plain and simple, like the reference
local TEXT = Color3.fromRGB(45, 45, 45)
local BORDER = Color3.fromRGB(185, 185, 185)
local WHITE = Color3.fromRGB(255, 255, 255)

local BEAT_SECONDS = 0.9  --// pause between the closing lines
local REPLY_SECONDS = 0.6 --// the customer "thinks" before answering you

local function fill(line, dishText)
	return (line:gsub("{DISH}", dishText))
end

--// Native chat bubble over any character or part - the exact look the
--// reference game uses. Local-only, which suits a private conversation.
local function speak(adornee, text)
	if not adornee then return end
	pcall(function()
		TextChatService:DisplayBubble(adornee, text)
	end)
end

local function speakSelf(text)
	local character = player.Character
	if character then
		speak(character, text)
	end
end

----------------------------------------------------------------
-- The choice stack: bottom-left, white cards, built once
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Dialogue_UI"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 22
gui.Parent = playerGui

local options = Instance.new("Frame")
options.Name = "Options"
options.AnchorPoint = Vector2.new(0, 1)
options.Position = UDim2.fromScale(0.03, 0.87)
options.Size = UDim2.fromScale(0.27, 0.55)
options.BackgroundTransparency = 1
options.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = options

local function clearOptions()
	for _, child in ipairs(options:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

--// One white card, reference-style: roomy, thin grey border, soft
--// dark text, growing taller on its own when the line wraps
local nextOrder = 0
local function addOption(text, onTap)
	nextOrder += 1
	local button = Instance.new("TextButton")
	button.LayoutOrder = nextOrder
	button.Size = UDim2.new(1, 0, 0, 0)
	button.AutomaticSize = Enum.AutomaticSize.Y
	button.BackgroundColor3 = WHITE
	button.AutoButtonColor = true
	button.Font = FONT
	button.TextSize = 20
	button.TextWrapped = true
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.TextYAlignment = Enum.TextYAlignment.Center
	button.TextColor3 = TEXT
	button.Text = text
	button.Parent = options

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = BORDER
	stroke.Parent = button

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.Parent = button

	button.Activated:Connect(onTap)
	return button
end

----------------------------------------------------------------
-- Flow driver. `seq` guards every delayed step: anything that changes
-- the conversation bumps it, so a stale task.delay from a previous
-- dialogue can never write over the current one.
----------------------------------------------------------------
local current = nil --// { Token, Payload }
local seq = 0

local function closePanel()
	seq += 1
	current = nil
	clearOptions()
	gui.Enabled = false
end

--// Step two: the customer has answered; now the order happens.
--// Direct = one confirm tap; recommend = one card per dish.
local function showOrderStep(mySeq, payload)
	if seq ~= mySeq then return end
	local lines = payload.Lines
	local dishText = payload.DishText

	clearOptions()

	if payload.Flow == "direct" then
		addOption(fill(lines.Confirm, dishText), function()
			if seq ~= mySeq then return end
			dialogueRemote:FireServer("Complete", payload.Token, nil)
			clearOptions()
			speakSelf(fill(lines.Confirm, dishText))
			task.delay(payload.CloseAfter, function()
				if seq == mySeq then closePanel() end
			end)
		end)
	else
		for _, dish in ipairs(payload.Dishes) do
			addOption(dish.Display, function()
				if seq ~= mySeq then return end
				dialogueRemote:FireServer("Complete", payload.Token, dish.Key)

				--// The closing beat: your pitch, their delight, your confirm
				clearOptions()
				speakSelf(fill(dish.Line, dish.Display))
				task.delay(BEAT_SECONDS, function()
					if seq ~= mySeq then return end
					speak(payload.Speaker, fill(lines.Accept, dish.Display))
					task.delay(BEAT_SECONDS, function()
						if seq ~= mySeq then return end
						speakSelf(fill(lines.Confirm, dish.Display))
						task.delay(payload.CloseAfter, function()
							if seq == mySeq then closePanel() end
						end)
					end)
				end)
			end)
		end
	end
end

--// An opener was tapped: you say it over your head, the customer
--// thinks for a beat, answers in their bubble, then the order cards show
local function playOpener(mySeq, payload, myLine, customerText)
	if seq ~= mySeq then return end
	clearOptions()
	speakSelf(myLine)
	task.delay(REPLY_SECONDS, function()
		if seq ~= mySeq then return end
		speak(payload.Speaker, customerText)
		showOrderStep(mySeq, payload)
	end)
end

local function beginDialogue(payload)
	seq += 1
	local mySeq = seq
	current = { Token = payload.Token, Payload = payload }

	local lines = payload.Lines
	local customerLine = fill(lines.Customer, payload.DishText)

	clearOptions()
	gui.Enabled = true

	--// TAP 1, two ways to open: straight to business, or a little small
	--// talk first. Small talk runs the customer's mood line into their
	--// order: "It's been great! We'll have the Burger, please!"
	addOption(lines.Greet, function()
		playOpener(mySeq, payload, lines.Greet, customerLine)
	end)
	addOption(lines.SmallTalkQ, function()
		playOpener(mySeq, payload, lines.SmallTalkQ,
			lines.Mood .. " " .. customerLine)
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

--// Death/respawn mid-conversation: drop the choices; the server's
--// timeout resolves the order on its own
player.CharacterAdded:Connect(function()
	if current then closePanel() end
end)
