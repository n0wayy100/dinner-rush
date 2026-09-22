--[[
	Dinner Rush - RecipeMathClient
	StarterPlayer.StarterPlayerScripts.Client.RecipeMathClient  (LocalScript)

	RECIPE MATH (Config.RecipeMath, owner design Sep 17 2026 - game 2
	of the minigame roll, replacing the ping-unfair colour smash). Two
	kitchen-dressed arithmetic questions, three chunky answer buttons,
	a per-question timer bar. The SERVER writes every question and
	judges every answer - this panel only renders and reports taps, so
	latency cannot touch fairness.

	Inputs, all platforms:
	  mouse / touch - tap an answer button
	  keyboard      - 1 / 2 / 3
	  gamepad       - D-pad left/right walks a highlight, A confirms

	Feedback: right = basil flash + a happy pop; wrong or the buzzer =
	tomato flash while the TRUE answer glows so the kid learns it.
	Verdicts share the kitchen's voice: MASTER COOK! / DECENT COOK /
	RUINED! BIN IT!
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SfxLocal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SfxLocal"))
local MATHQ = Config.RecipeMath
if not MATHQ then return end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local mathRemote = remotes:WaitForChild("RecipeMathRemote")

--// RED AND WHITE theme (owner call, Sep 17) - the lobby's red-band
--// look, distinct from the cream-and-mustard kitchen panels
local SNOW = Color3.fromRGB(255, 241, 239)      --// white with red in it
local SNOW_DEEP = Color3.fromRGB(255, 226, 223) --// ...mixing redder below
local WHITE = Color3.fromRGB(255, 255, 255)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local TOMATO = Color3.fromRGB(229, 72, 77)
local RED_DEEP = Color3.fromRGB(198, 52, 58)
local PINK_TRACK = Color3.fromRGB(255, 226, 224)

local VERDICTS = {
	Perfect = { Text = "MASTER COOK!", Color = BASIL },
	Good = { Text = "DECENT COOK", Color = MUSTARD },
	Ruined = { Text = "RUINED! BIN IT!", Color = TOMATO },
}

local session = nil

local function teardown()
	if not session then return end
	if session.TimerConn then session.TimerConn:Disconnect() end
	ContextActionService:UnbindAction("MathMove")
	ContextActionService:UnbindAction("MathConfirm")
	if session.Gui then session.Gui:Destroy() end
	session = nil
end

local function sendAnswer(optionIndex)
	if not session or session.Done or session.Locked then return end
	session.Locked = true --// one pick per question; the server agrees
	mathRemote:FireServer("Answer", session.Token, session.QIndex, optionIndex)
end

--// The keyboard/gamepad highlight - hidden until a directional or
--// confirm press asks for it, so mouse and touch kids never see it
local function setHighlight(index)
	if not session then return end
	for i, button in ipairs(session.Buttons) do
		local on = session.HighlightOn and i == index
		button.Stroke.Color = on and MUSTARD or TOMATO
		button.Stroke.Thickness = on and 5 or 3
	end
	session.Highlight = index
end

local function buildPanel()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RecipeMath_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Active = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.46, 0.52)
	panel.Position = UDim2.fromScale(0.5, 0.46)
	panel.BackgroundColor3 = SNOW
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(SNOW, SNOW_DEEP)
	gradient.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.06, 0)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = RED_DEEP
	stroke.Parent = panel

	--// THE RED BAND: the lobby's header look - white lettering and the
	--// abacus riding a tomato bar
	local band = Instance.new("Frame")
	band.Active = false
	band.Size = UDim2.fromScale(0.94, 0.13)
	band.Position = UDim2.fromScale(0.03, 0.03)
	band.BackgroundColor3 = TOMATO
	band.BorderSizePixel = 0
	band.Parent = panel
	local bandCorner = Instance.new("UICorner")
	bandCorner.CornerRadius = UDim.new(0.35, 0)
	bandCorner.Parent = band

	local title = Instance.new("TextLabel")
	title.Active = false
	title.Size = UDim2.fromScale(0.62, 0.72)
	title.Position = UDim2.fromScale(0.04, 0.14)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "🧮 RECIPE MATH!"
	title.TextColor3 = WHITE
	title.Parent = band
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 24
	titleCap.Parent = title

	local counter = Instance.new("TextLabel")
	counter.Active = false
	counter.AnchorPoint = Vector2.new(1, 0.5)
	counter.Size = UDim2.fromScale(0.3, 0.6)
	counter.Position = UDim2.fromScale(0.96, 0.5)
	counter.BackgroundTransparency = 1
	counter.Font = Enum.Font.FredokaOne
	counter.TextScaled = true
	counter.TextXAlignment = Enum.TextXAlignment.Right
	counter.Text = ""
	counter.TextColor3 = WHITE
	counter.Parent = band
	local counterCap = Instance.new("UITextSizeConstraint")
	counterCap.MaxTextSize = 16
	counterCap.Parent = counter

	--// the kitchen-flavour sentence ("The recipe needs 7 + 5 tomatoes!")
	local prompt = Instance.new("TextLabel")
	prompt.Active = false
	prompt.Size = UDim2.fromScale(0.9, 0.11)
	prompt.Position = UDim2.fromScale(0.05, 0.18)
	prompt.BackgroundTransparency = 1
	prompt.Font = Enum.Font.FredokaOne
	prompt.TextScaled = true
	prompt.TextWrapped = true
	prompt.Text = ""
	prompt.TextColor3 = CHOC
	prompt.Parent = panel
	local promptCap = Instance.new("UITextSizeConstraint")
	promptCap.MaxTextSize = 20
	promptCap.Parent = prompt

	--// the big honest equation underneath, in the theme's red
	local equation = Instance.new("TextLabel")
	equation.Active = false
	equation.Size = UDim2.fromScale(0.9, 0.19)
	equation.Position = UDim2.fromScale(0.05, 0.29)
	equation.BackgroundTransparency = 1
	equation.Font = Enum.Font.FredokaOne
	equation.TextScaled = true
	equation.Text = ""
	equation.TextColor3 = CHOC --// the numbers keep their old ink (owner)
	equation.Parent = panel
	local equationCap = Instance.new("UITextSizeConstraint")
	equationCap.MaxTextSize = 44
	equationCap.Parent = equation

	--// three fat answer buttons - the DIGITS are the whole point, so
	--// they render at equation size with breathing room around them
	local buttons = {}
	for i = 1, 3 do
		local button = Instance.new("TextButton")
		button.Name = "Answer" .. i
		button.Size = UDim2.fromScale(0.28, 0.24)
		button.Position = UDim2.fromScale(0.04 + (i - 1) * 0.32, 0.52)
		--// The answers render EXACTLY like the equation (owner ruling,
		--// Sep 17): FredokaOne at a FIXED size in the equation's own
		--// render range - TextScaled inflated two digits to fill the
		--// card, where FredokaOne's heavy rounds close into blobs
		button.BackgroundColor3 = WHITE
		button.Font = Enum.Font.FredokaOne
		button.TextScaled = false
		button.TextSize = 30
		button.Text = ""
		button.TextColor3 = CHOC --// old ink, owner call
		button.Parent = panel
		local bCorner = Instance.new("UICorner")
		bCorner.CornerRadius = UDim.new(0.2, 0)
		bCorner.Parent = button
		local bStroke = Instance.new("UIStroke")
		bStroke.Thickness = 3
		bStroke.Color = TOMATO
		--// Border, NOT the default Contextual: on a text object a
		--// contextual UIStroke outlines the GLYPHS - it was fattening
		--// every digit into a blob while the equation stayed crisp
		bStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bStroke.Parent = button

		button.Activated:Connect(function()
			if session then
				session.HighlightOn = false
				setHighlight(session.Highlight)
			end
			sendAnswer(i)
		end)

		buttons[i] = { Button = button, Stroke = bStroke }
	end

	--// per-question clock
	local timerBack = Instance.new("Frame")
	timerBack.Active = false
	timerBack.Size = UDim2.fromScale(0.9, 0.055)
	timerBack.Position = UDim2.fromScale(0.05, 0.88)
	timerBack.BackgroundColor3 = PINK_TRACK
	timerBack.BorderSizePixel = 0
	timerBack.Parent = panel
	local timerCorner = Instance.new("UICorner")
	timerCorner.CornerRadius = UDim.new(0.5, 0)
	timerCorner.Parent = timerBack
	local timerFill = Instance.new("Frame")
	timerFill.Active = false
	timerFill.Size = UDim2.fromScale(1, 1)
	timerFill.BackgroundColor3 = TOMATO
	timerFill.BorderSizePixel = 0
	timerFill.Parent = timerBack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = timerFill

	return gui, panel, prompt, equation, buttons, counter, timerFill
end

mathRemote.OnClientEvent:Connect(function(action, a, b, c)
	if action == "Open" then
		teardown()
		local data = a
		local gui, panel, prompt, equation, buttons, counter, timerFill = buildPanel()
		session = {
			Token = data.Token,
			Gui = gui,
			Panel = panel,
			Prompt = prompt,
			Equation = equation,
			Buttons = buttons,
			Counter = counter,
			TimerFill = timerFill,
			Total = data.Total,
			QIndex = 1,
			AskedAt = os.clock(),
			Seconds = MATHQ.QuestionSeconds,
			Highlight = 2, --// middle button, thumb-neutral
			HighlightOn = false,
			Locked = true, --// unlocks when the first Question lands
			Done = false,
		}

		--// the clock drains client-side for FEEL; the server keeps the
		--// real one (plus transport grace) so ping still can't cheat you
		session.TimerConn = RunService.RenderStepped:Connect(function()
			if not session or session.Done then return end
			local left = 1 - (os.clock() - session.AskedAt) / session.Seconds
			left = math.clamp(left, 0, 1)
			session.TimerFill.Size = UDim2.fromScale(session.Locked and
				session.TimerFill.Size.X.Scale or left, 1)
			if not session.Locked then
				session.TimerFill.BackgroundColor3 =
					left < 0.3 and RED_DEEP or TOMATO
			end
		end)

		--// gamepad + keyboard: D-pad/arrows walk, A/Space/Enter picks,
		--// 1/2/3 answer directly
		ContextActionService:BindAction("MathMove", function(_, state, input)
			if state ~= Enum.UserInputState.Begin or not session then
				return Enum.ContextActionResult.Sink
			end
			local key = input.KeyCode
			if key == Enum.KeyCode.One then
				sendAnswer(1)
			elseif key == Enum.KeyCode.Two then
				sendAnswer(2)
			elseif key == Enum.KeyCode.Three then
				sendAnswer(3)
			elseif key == Enum.KeyCode.Left or key == Enum.KeyCode.DPadLeft then
				session.HighlightOn = true
				setHighlight(math.max(1, (session.Highlight or 2) - 1))
			elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.DPadRight then
				session.HighlightOn = true
				setHighlight(math.min(3, (session.Highlight or 2) + 1))
			end
			return Enum.ContextActionResult.Sink
		end, false,
			Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three,
			Enum.KeyCode.Left, Enum.KeyCode.Right,
			Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight)

		ContextActionService:BindAction("MathConfirm", function(_, state)
			if state == Enum.UserInputState.Begin and session then
				if session.HighlightOn then
					sendAnswer(session.Highlight)
				else
					session.HighlightOn = true
					setHighlight(session.Highlight)
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonA, Enum.KeyCode.Return)

	elseif action == "Question" then
		if not session or session.Token ~= a then return end
		local q = b
		session.QIndex = q.Index
		session.AskedAt = os.clock()
		session.Seconds = q.Seconds or MATHQ.QuestionSeconds
		session.Locked = false
		session.Counter.Text = ("Question %d of %d"):format(q.Index, q.Total)
		session.Prompt.Text = q.Prompt
		session.Equation.Text = q.Equation
		session.Equation.TextColor3 = CHOC
		for i, entry in ipairs(session.Buttons) do
			entry.Button.Text = tostring(q.Options[i])
			entry.Button.BackgroundColor3 = WHITE --// equation twins
			entry.Button.TextColor3 = CHOC
		end
		setHighlight(session.Highlight)
		--// a small pop so the new question reads as new
		session.Panel.Size = UDim2.fromScale(0.44, 0.5)
		TweenService:Create(session.Panel,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(0.46, 0.52) }):Play()

	elseif action == "Result" then
		if not session or session.Token ~= a then return end
		local r = b
		session.Locked = true

		--// Local, not global: this panel is on your screen alone
		SfxLocal.Play(r.WasCorrect and "AnswerRight" or "AnswerWrong")
		--// the TRUE answer always glows basil; a wrong pick goes tomato
		for i, entry in ipairs(session.Buttons) do
			if i == r.CorrectIndex then
				entry.Button.BackgroundColor3 = BASIL
				entry.Button.TextColor3 = WHITE
			elseif i == r.Picked and not r.WasCorrect then
				entry.Button.BackgroundColor3 = TOMATO
				entry.Button.TextColor3 = WHITE
			end
		end
		local pop = Instance.new("TextLabel")
		pop.Active = false
		pop.AnchorPoint = Vector2.new(0.5, 0.5)
		pop.Size = UDim2.fromScale(0.5, 0.14)
		pop.Position = UDim2.fromScale(0.5, 0.44)
		pop.BackgroundTransparency = 1
		pop.Font = Enum.Font.FredokaOne
		pop.TextScaled = true
		pop.Text = r.WasCorrect and "CORRECT!"
			or (r.Picked == nil and "TOO SLOW!" or "NOPE!")
		pop.TextColor3 = r.WasCorrect and BASIL or TOMATO
		pop.TextStrokeColor3 = CHOC
		pop.TextStrokeTransparency = 0
		pop.Parent = session.Panel
		TweenService:Create(pop,
			TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.34), TextTransparency = 1,
				TextStrokeTransparency = 1 }):Play()
		task.delay(0.65, function() pop:Destroy() end)
		if not r.WasCorrect then --// a quick apologetic shake
			session.Panel.Position = UDim2.fromScale(0.51, 0.47)
			TweenService:Create(session.Panel, TweenInfo.new(0.12),
				{ Position = UDim2.fromScale(0.5, 0.46) }):Play()
		end

	elseif action == "End" then
		if not session or session.Token ~= a then return end
		session.Done = true
		local verdict = VERDICTS[c] or VERDICTS.Ruined
		local splash = Instance.new("TextLabel")
		splash.Active = false
		splash.Size = UDim2.fromScale(0.9, 0.26)
		splash.Position = UDim2.fromScale(0.05, 0.37)
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

print("[RecipeMath] ready - the kitchen asks the questions now")
