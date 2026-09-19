--[[
	Dinner Rush - CardMatchClient
	StarterPlayer.StarterPlayerScripts.Client.CardMatchClient  (LocalScript)

	THE CARD MATCH (Config.CardMatch): game 3 of the minigame roll -
	memory pairs against the clock. The server deals the board from the
	ACTIVE MAP's food icons (dishes + raws), the whole board PEEKS
	face-up for a second, then flip two to match. Pairs found decide
	the dish; sweeping the board is Perfect on the spot.

	EVERY PLATFORM PLAYS (owner spec):
	  mouse    - click a card
	  touch    - tap a card (cards are big, fat targets on purpose)
	  keyboard - arrow keys walk a highlight, Space/Enter flips
	  gamepad  - D-pad walks the highlight, A flips
	The highlight ring appears the moment a directional input is used
	and hides again on a direct click/tap, so mouse and touch kids
	never see it.

	Server-driven rendering: a card only turns when the server says
	"Show" - taps send intent, the server judges every flip and match.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SfxLocal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SfxLocal"))
local CARDS = Config.CardMatch
if not CARDS then return end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local cardRemote = remotes:WaitForChild("CardMatchRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
--// BLUISH WHITE panel ground (owner call, Sep 17) - each minigame
--// wears its own colour: math is red-white, memory is blue-white
local SKY = Color3.fromRGB(240, 247, 255)
local SKY_DEEP = Color3.fromRGB(221, 235, 252)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local TOMATO = Color3.fromRGB(229, 72, 77)

--// Same dish-blind verdicts as the smash - one voice for every game
local VERDICTS = {
	Perfect = { Text = "MASTER COOK!", Color = BASIL },
	Good = { Text = "DECENT COOK", Color = MUSTARD },
	Ruined = { Text = "RUINED! BIN IT!", Color = TOMATO },
	Overcooked = { Text = "SLOPPY WORK...", Color = Color3.fromRGB(150, 130, 120) },
}

local COLUMNS = 4 --// board is 4 wide; rows follow the pair count

local session = nil

local function teardown()
	if not session then return end
	ContextActionService:UnbindAction("CardMatchMove")
	ContextActionService:UnbindAction("CardMatchFlip")
	if session.Gui then session.Gui:Destroy() end
	session = nil
end

local function sendFlip(index)
	if not session or session.Done then return end
	if os.clock() < session.PlayableAt then return end --// still peeking
	cardRemote:FireServer("Flip", session.Token, index)
end

--// One card = a fat button with a face (icon) and a back ("?"); the
--// face is shown by toggling, never rebuilt
local function buildCard(parent, index, icon, position, size)
	local button = Instance.new("ImageButton")
	button.Name = "Card" .. index
	button.Position = position
	button.Size = size
	button.BackgroundColor3 = CREAM_DEEP
	button.AutoButtonColor = true
	button.Image = ""
	button.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.12, 0)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CHOC
	stroke.Parent = button

	local back = Instance.new("TextLabel")
	back.Name = "Back"
	back.Active = false
	back.Size = UDim2.fromScale(0.7, 0.7)
	back.AnchorPoint = Vector2.new(0.5, 0.5)
	back.Position = UDim2.fromScale(0.5, 0.5)
	back.BackgroundTransparency = 1
	back.Font = Enum.Font.FredokaOne
	back.TextScaled = true
	back.Text = "?"
	back.TextColor3 = CHOC
	back.TextTransparency = 0.35
	back.Parent = button

	local face = Instance.new("ImageLabel")
	face.Name = "Face"
	face.Active = false
	face.Size = UDim2.fromScale(0.85, 0.85)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.BackgroundTransparency = 1
	face.Image = icon
	face.Visible = false
	face.Parent = button

	return { Button = button, Back = back, Face = face,
		Stroke = stroke, HomeSize = size }
end

local function setFace(card, up)
	card.Face.Visible = up
	card.Back.Visible = not up
	--// a quick squash-and-pop sells the flip without real 3D
	card.Button.Size = UDim2.fromScale(
		card.HomeSize.X.Scale * 0.8, card.HomeSize.Y.Scale * 0.8)
	TweenService:Create(card.Button,
		TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = card.HomeSize }):Play()
end

--// The keyboard/gamepad highlight ring - hidden until a directional
--// input asks for it
local function setHighlight(index)
	if not session then return end
	for i, card in ipairs(session.Cards) do
		if not card.Matched then --// matched cards keep their basil ring
			card.Stroke.Color = (session.HighlightOn and i == index) and MUSTARD or CHOC
			card.Stroke.Thickness = (session.HighlightOn and i == index) and 4.5 or 2.5
		end
	end
	session.Highlight = index
end

local function moveHighlight(dx, dy)
	if not session or session.Done then return end
	session.HighlightOn = true
	local count = #session.Cards
	local rows = math.ceil(count / COLUMNS)
	local index = session.Highlight or 1
	local col = (index - 1) % COLUMNS
	local row = math.floor((index - 1) / COLUMNS)
	col = math.clamp(col + dx, 0, COLUMNS - 1)
	row = math.clamp(row + dy, 0, rows - 1)
	setHighlight(math.min(row * COLUMNS + col + 1, count))
end

local function buildPanel(data)
	local gui = Instance.new("ScreenGui")
	gui.Name = "CardMatch_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Active = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.46, 0.62)
	panel.Position = UDim2.fromScale(0.5, 0.46)
	panel.BackgroundColor3 = SKY
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(SKY, SKY_DEEP)
	gradient.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.06, 0)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = CHOC
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Active = false
	title.Size = UDim2.fromScale(0.9, 0.1)
	title.Position = UDim2.fromScale(0.05, 0.03)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "MEMORY MATCH! Find the pairs!"
	title.TextColor3 = CHOC
	title.Parent = panel

	local pairsLabel = Instance.new("TextLabel")
	pairsLabel.Active = false
	pairsLabel.Size = UDim2.fromScale(0.3, 0.08)
	pairsLabel.Position = UDim2.fromScale(0.05, 0.14)
	pairsLabel.BackgroundTransparency = 1
	pairsLabel.Font = Enum.Font.FredokaOne
	pairsLabel.TextScaled = true
	pairsLabel.TextXAlignment = Enum.TextXAlignment.Left
	pairsLabel.Text = ("0/%d pairs"):format(math.floor(#data.Cards / 2))
	pairsLabel.TextColor3 = CHOC
	pairsLabel.Parent = panel

	--// THE BOARD: COLUMNS wide, fat scale-sized cards - big targets
	--// for thumbs on phones by design
	local board = Instance.new("Frame")
	board.Active = false
	board.Size = UDim2.fromScale(0.9, 0.6)
	board.Position = UDim2.fromScale(0.05, 0.24)
	board.BackgroundTransparency = 1
	board.Parent = panel

	local count = #data.Cards
	local rows = math.ceil(count / COLUMNS)
	local padX, padY = 0.03, 0.05
	local cardW = (1 - padX * (COLUMNS - 1)) / COLUMNS
	local cardH = (1 - padY * (rows - 1)) / rows

	local cards = {}
	for i = 1, count do
		local col = (i - 1) % COLUMNS
		local row = math.floor((i - 1) / COLUMNS)
		local card = buildCard(board, i, data.Cards[i],
			UDim2.fromScale(col * (cardW + padX), row * (cardH + padY)),
			UDim2.fromScale(cardW, cardH))
		card.Button.Activated:Connect(function()
			if session then
				--// a direct click/tap retires the highlight ring
				session.HighlightOn = false
				setHighlight(session.Highlight)
			end
			sendFlip(i)
		end)
		cards[i] = card
	end

	local timerBack = Instance.new("Frame")
	timerBack.Active = false
	timerBack.Size = UDim2.fromScale(0.9, 0.05)
	timerBack.Position = UDim2.fromScale(0.05, 0.9)
	timerBack.BackgroundColor3 = CREAM_DEEP
	timerBack.BorderSizePixel = 0
	timerBack.Parent = panel
	local timerCorner = Instance.new("UICorner")
	timerCorner.CornerRadius = UDim.new(0.5, 0)
	timerCorner.Parent = timerBack
	local timerFill = Instance.new("Frame")
	timerFill.Active = false
	timerFill.Size = UDim2.fromScale(1, 1)
	timerFill.BackgroundColor3 = MUSTARD
	timerFill.BorderSizePixel = 0
	timerFill.Parent = timerBack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = timerFill

	return gui, panel, cards, pairsLabel, timerFill
end

--// Floating "+PAIR!" / verdict pops, shared shape with the smash
local function popText(parent, text, color, y)
	local pop = Instance.new("TextLabel")
	pop.Active = false
	pop.AnchorPoint = Vector2.new(0.5, 0.5)
	pop.Size = UDim2.fromScale(0.4, 0.12)
	pop.Position = UDim2.fromScale(0.5, y or 0.18)
	pop.BackgroundTransparency = 1
	pop.Font = Enum.Font.FredokaOne
	pop.TextScaled = true
	pop.Text = text
	pop.TextColor3 = color
	pop.TextStrokeColor3 = CHOC
	pop.TextStrokeTransparency = 0
	pop.Parent = parent
	TweenService:Create(pop, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, (y or 0.18) - 0.1), TextTransparency = 1,
			TextStrokeTransparency = 1 }):Play()
	task.delay(0.55, function() pop:Destroy() end)
end

cardRemote.OnClientEvent:Connect(function(action, a, b, c)
	if action == "Open" then
		teardown()
		local data = a
		local gui, panel, cards, pairsLabel, timerFill = buildPanel(data)
		session = {
			Token = data.Token,
			Gui = gui,
			Panel = panel,
			Cards = cards,
			PairsLabel = pairsLabel,
			PairsTotal = math.floor(#data.Cards / 2),
			PlayableAt = os.clock() + data.PeekSeconds,
			Highlight = 1,
			HighlightOn = false,
			Done = false,
		}

		--// THE PEEK: everything face-up, then the board turns and the
		--// clock starts
		for _, card in ipairs(cards) do
			card.Face.Visible = true
			card.Back.Visible = false
		end
		task.delay(data.PeekSeconds, function()
			if not session or session.Token ~= data.Token or session.Done then return end
			for _, card in ipairs(session.Cards) do
				if not card.Matched then
					setFace(card, false)
				end
			end
			TweenService:Create(timerFill,
				TweenInfo.new(data.GameSeconds, Enum.EasingStyle.Linear),
				{ Size = UDim2.fromScale(0, 1) }):Play()
		end)

		--// Keyboard arrows + D-pad walk the highlight; Space/Enter/A flip
		ContextActionService:BindAction("CardMatchMove", function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			local key = input.KeyCode
			if key == Enum.KeyCode.Left or key == Enum.KeyCode.DPadLeft then
				moveHighlight(-1, 0)
			elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.DPadRight then
				moveHighlight(1, 0)
			elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.DPadUp then
				moveHighlight(0, -1)
			elseif key == Enum.KeyCode.Down or key == Enum.KeyCode.DPadDown then
				moveHighlight(0, 1)
			end
			return Enum.ContextActionResult.Sink
		end, false,
			Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Down,
			Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight,
			Enum.KeyCode.DPadUp, Enum.KeyCode.DPadDown)

		ContextActionService:BindAction("CardMatchFlip", function(_, state)
			if state == Enum.UserInputState.Begin and session then
				if session.HighlightOn then
					sendFlip(session.Highlight)
				else
					--// first press summons the ring instead of flipping
					--// blind - the next press flips
					session.HighlightOn = true
					setHighlight(session.Highlight)
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.Space, Enum.KeyCode.Return, Enum.KeyCode.ButtonA)

	elseif action == "Show" then
		if not session or session.Token ~= a then return end
		local card = session.Cards[b]
		if card then setFace(card, true) end

	elseif action == "Match" then
		--// payload rides arg THREE (b) - ("Match", token, {A,B,Pairs})
		if not session or session.Token ~= a then return end
		for _, index in ipairs({ b.A, b.B }) do
			local card = session.Cards[index]
			if card then
				card.Matched = true
				card.Stroke.Color = BASIL
				card.Stroke.Thickness = 4
				card.Button.BackgroundColor3 = Color3.fromRGB(226, 244, 224)
			end
		end
		session.PairsLabel.Text = ("%d/%d pairs"):format(b.Pairs, session.PairsTotal)
		SfxLocal.Play("AnswerRight")
		popText(session.Panel, "PAIR!", BASIL)

	elseif action == "Mismatch" then
		--// payload rides arg THREE (b) - ("Mismatch", token, {A,B})
		if not session or session.Token ~= a then return end
		local myToken = session.Token
		SfxLocal.Play("AnswerWrong")
		local wrongPair = { b.A, b.B }
		--// both wrong cards sit readable for the lock, then turn back
		task.delay(CARDS.MismatchLockSeconds, function()
			if not session or session.Token ~= myToken or session.Done then return end
			for _, index in ipairs(wrongPair) do
				local card = session.Cards[index]
				if card and not card.Matched then
					setFace(card, false)
				end
			end
		end)

	elseif action == "End" then
		if not session or session.Token ~= a then return end
		session.Done = true
		local verdict = VERDICTS[c] or VERDICTS.Overcooked
		local splash = Instance.new("TextLabel")
		splash.Active = false
		splash.Size = UDim2.fromScale(0.9, 0.28)
		splash.Position = UDim2.fromScale(0.05, 0.36)
		splash.BackgroundTransparency = 1
		splash.Font = Enum.Font.FredokaOne
		splash.TextScaled = true
		splash.Text = verdict.Text
		splash.TextColor3 = verdict.Color
		splash.TextStrokeColor3 = CHOC
		splash.TextStrokeTransparency = 0
		splash.Parent = session.Panel
		task.delay(1.4, teardown)

	elseif action == "Close" then
		if session and session.Token == a then
			teardown()
		end
	end
end)

print("[CardMatch] ready - remember where the ramen was")
