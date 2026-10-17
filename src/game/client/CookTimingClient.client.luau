--[[
	Dinner Rush - CookTimingClient
	StarterPlayer.StarterPlayerScripts.Client.CookTimingClient  (LocalScript)

	The cooking timing bar (gated difficulties only - EASY never sees it).
	A DONENESS BAR (owner, Oct 2026): pale RAW on one side of the green
	zone, dark BURNT on the other, yellow shoulders, and a GREEN zone that
	lands somewhere new every swing. An arrow ping-pongs across with the
	dish being cooked riding under it - pale on the raw side, bright and
	bouncing in the green, charred on the burnt side. STOP it with a
	tap/click anywhere or with Space/gamepad A.

	  green (swing 1)      PERFECT!
	  yellow then green    GOOD!
	  yellow then yellow   OK...
	  red                  MISS! - swing again

	(Config.CookTiming.OneStop = true is an optional one-stop variant -
	off by default; the look above is the same either way.)

	Render/report only: the server dealt the green's position, keeps its
	own arrow clock, and overrules any claim outside tolerance. The dish
	keeps aging on the stove while this panel is up - dawdle and it burns.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiPop = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiPop"))
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SfxLocal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SfxLocal"))
local MinigameJuice = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MinigameJuice"))
local MinigameSkin = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MinigameSkin"))
local timingRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CookTimingRemote")

local TIMING = Config.CookTiming

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local RAW = Color3.fromRGB(246, 226, 205)        --// pale: not done yet
local BURNT = Color3.fromRGB(74, 50, 36)         --// charred
local GREEN_GLOW = Color3.fromRGB(132, 224, 152) --// the green, lit while the arrow is in it

local ACTION = "DinnerRushCookStop"

--// What a final stop says. A red stop reads as the END of the doneness bar
--// it landed on - raw side or burnt side - though both serve Overcooked.
local RESULT = {
	Perfect = { Text = "PERFECT!", Color = BASIL },
	Good = { Text = "GOOD!", Color = MUSTARD },
	Raw = { Text = "UNDERCOOKED!", Color = TOMATO },
	Burnt = { Text = "OVERCOOKED!", Color = TOMATO },
}

--// The old two-stop game's in-between labels (OneStop = false only)
local ZONE_LABEL = {
	green = { Text = "PERFECT!", Color = BASIL },
	yellow = { Text = "OK...", Color = MUSTARD },
	red = { Text = "MISS!", Color = TOMATO },
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Panel (built once)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "CookTiming_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.Parent = playerGui

--// Full-screen tap catcher: anywhere is the STOP button (phone-first)
local catcher = Instance.new("TextButton")
catcher.Name = "TapCatcher"
catcher.Size = UDim2.fromScale(1, 1)
catcher.BackgroundTransparency = 1
catcher.Text = ""
catcher.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.68) --// low centre: the stove stays visible
panel.Size = UDim2.fromScale(0.44, 0.2) --// taller: room for the dish riding under the bar
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 3
panelStroke.Color = CHOC
panelStroke.Parent = panel

--// The zone bar
local bar = Instance.new("Frame")
bar.Name = "Bar"
bar.AnchorPoint = Vector2.new(0.5, 0.5)
bar.Position = UDim2.fromScale(0.5, 0.45)
bar.Size = UDim2.fromScale(0.92, 0.3)
bar.BackgroundColor3 = BURNT --// past the zones is BURNT; the raw side paints over it
bar.ClipsDescendants = true
bar.Parent = panel

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 8)
barCorner.Parent = bar

local barStroke = Instance.new("UIStroke")
barStroke.Thickness = 2
barStroke.Color = CHOC
barStroke.Parent = bar

local function makeZone(name, color)
	local zone = Instance.new("Frame")
	zone.Name = name
	zone.AnchorPoint = Vector2.new(0.5, 0)
	zone.Size = UDim2.fromScale(0, 1)
	zone.BackgroundColor3 = color
	zone.BorderSizePixel = 0
	zone.Parent = bar
	return zone
end

--// RAW: everything before the zones (the far side stays BURNT)
local rawZone = makeZone("Raw", RAW)
rawZone.AnchorPoint = Vector2.new(0, 0)
local yellowZone = makeZone("Yellow", MUSTARD) --// one band; green sits on top
local greenZone = makeZone("Green", BASIL)

--// Lights up while the arrow is inside the green - feel the moment
--// EXPLICIT LAYERS, bottom to top: bar 2 < raw/yellow 3 < green 4 <
--// arrow 5 < dish 6. Spelled out because a ScreenGui can sort its layers
--// globally, and then the bar's own dark background (left at the default
--// 1 along with its zones) can land ON TOP of the zones - the colours
--// vanished under a brown slab once the track art lifted the bar to 2.
rawZone.ZIndex = 3
yellowZone.ZIndex = 3
greenZone.ZIndex = 4

local greenGlow = Instance.new("UIStroke")
greenGlow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
greenGlow.Thickness = 3
greenGlow.Color = Color3.new(1, 1, 1)
greenGlow.Transparency = 0.2
greenGlow.Enabled = false
greenGlow.Parent = greenZone

--// The arrow: a chunky chocolate needle
local arrow = Instance.new("Frame")
arrow.Name = "Arrow"
arrow.AnchorPoint = Vector2.new(0.5, 0.5)
arrow.Position = UDim2.fromScale(0, 0.5)
arrow.Size = UDim2.new(0, 5, 1.35, 0)
arrow.BackgroundColor3 = CHOC
arrow.BorderSizePixel = 0
arrow.ZIndex = 5
arrow.Parent = bar

local arrowStroke = Instance.new("UIStroke")
arrowStroke.Thickness = 1.5
arrowStroke.Color = CREAM
arrowStroke.Parent = arrow

--// Result / stage text above the bar
local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 0)
caption.Position = UDim2.fromScale(0.5, 0.02)
caption.Size = UDim2.fromScale(0.9, 0.26)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.FredokaOne
caption.TextScaled = true
caption.TextColor3 = CHOC
caption.TextStrokeColor3 = CREAM
caption.TextStrokeTransparency = 0.5
caption.Text = ""
caption.Parent = panel

--// RAW / BURNT under the bar's two ends, so the colours explain themselves
local function endLabel(text, x, align)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(align == Enum.TextXAlignment.Left and 0 or 1, 0)
	label.Position = UDim2.fromScale(x, 0.63)
	label.Size = UDim2.fromScale(0.2, 0.15)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = align
	label.TextColor3 = CHOC
	label.TextTransparency = 0.35
	label.Text = text
	label.Parent = panel
	return label
end
endLabel("RAW", 0.04, Enum.TextXAlignment.Left)
endLabel("BURNT", 0.96, Enum.TextXAlignment.Right)

--// THE DISH, riding under the arrow - its look tells you how done it is
local rider = Instance.new("ImageLabel")
rider.Name = "Dish"
rider.Active = false
rider.AnchorPoint = Vector2.new(0.5, 0)
rider.Position = UDim2.fromScale(0.04, 0.61)
rider.Size = UDim2.fromScale(0.2, 0.36)
rider.BackgroundTransparency = 1
rider.ScaleType = Enum.ScaleType.Fit
rider.ZIndex = 6
rider.Visible = false
rider.Parent = panel
local riderSquare = Instance.new("UIAspectRatioConstraint")
riderSquare.AspectRatio = 1
riderSquare.DominantAxis = Enum.DominantAxis.Height
riderSquare.Parent = rider
local riderScale = Instance.new("UIScale")
riderScale.Parent = rider

--// THE ART KIT (Config.MinigameArt), each piece only once its id is in:
--// the wooden border round the panel, and the timer TRACK as a rim the
--// zone bar sits inside. No title plaque on this one: the caption changes
--// colour with every result, and a green "PERFECT!" would vanish on a
--// green sign.
MinigameSkin.Frame(panel)
if MinigameSkin.Has("TimerTrack") then
	local track = Instance.new("ImageLabel")
	track.Name = "BarTrack"
	track.Active = false
	track.BackgroundTransparency = 1
	track.AnchorPoint = bar.AnchorPoint
	track.Position = bar.Position
	--// a rim a few pixels proud of the bar on every side
	track.Size = UDim2.new(bar.Size.X.Scale, 14, bar.Size.Y.Scale, 14)
	MinigameSkin.Apply(track, "TimerTrack")
	--// behind the bar, above the border (which sits at 0)
	track.ZIndex = 1
	bar.ZIndex = 2 --// its zones sit at 3-4 and the arrow at 5, so they stay above it
	track.Parent = panel

	--// keep the track's rounded ends round at whatever height it draws
	local trackHeight = (Config.MinigameArt.TimerTrack and Config.MinigameArt.TimerTrack.Height) or 128
	local function fit()
		track.SliceScale = math.max(track.AbsoluteSize.Y / trackHeight, 0.01)
	end
	track:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()

	barStroke.Enabled = false --// the track is the bar's edge now
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local current = nil --// { Token, StationPosition }
local sweepStart = 0
local sweepSeconds = 1 --// dealt by the server, fresh every swing
local sweeping = false
local stopped = false --// pressed, waiting on the server's verdict
local walkWatcher = nil
local animWatcher = nil
local greenCenterNow = 0.5 --// this swing's green, for the dish's look
local stoppedAt = 0        --// where the arrow froze: which side a red stop was on

local function arrowAt(elapsed)
	elapsed = math.max(elapsed, 0)
	local phase = (elapsed % (sweepSeconds * 2)) / sweepSeconds
	if phase <= 1 then
		return phase
	end
	return 2 - phase
end

local function paintZones(greenCenter)
	greenCenterNow = greenCenter
	local rawEnd = greenCenter - TIMING.GreenWidth / 2 - TIMING.YellowWidth
	rawZone.Position = UDim2.fromScale(0, 0)
	rawZone.Size = UDim2.fromScale(math.max(rawEnd, 0), 1)
	greenZone.Position = UDim2.fromScale(greenCenter, 0)
	greenZone.Size = UDim2.fromScale(TIMING.GreenWidth, 1)
	yellowZone.Position = UDim2.fromScale(greenCenter, 0)
	yellowZone.Size = UDim2.fromScale(TIMING.GreenWidth + TIMING.YellowWidth * 2, 1)
end

--// Which part of the doneness bar a position is in (same maths as the
--// server's judge, plus which SIDE of the green a red is on)
local function zoneAt(position)
	local fromGreen = position - greenCenterNow
	local half = TIMING.GreenWidth / 2
	if math.abs(fromGreen) <= half then
		return "green"
	elseif math.abs(fromGreen) <= half + TIMING.YellowWidth then
		return "yellow"
	end
	return fromGreen < 0 and "raw" or "burnt"
end

--// The dish follows the arrow and looks as done as where it is
local function dressRider(position)
	--// the bar spans 0.04-0.96 of the panel
	rider.Position = UDim2.fromScale(0.04 + position * 0.92, 0.61)
	local zone = zoneAt(position)
	local inGreen = zone == "green"
	greenGlow.Enabled = inGreen
	greenZone.BackgroundColor3 = inGreen and GREEN_GLOW or BASIL

	if zone == "raw" then
		rider.ImageColor3 = Color3.new(1, 1, 1)
		rider.ImageTransparency = 0.45 --// washed out: not cooked yet
	elseif zone == "burnt" then
		rider.ImageColor3 = Color3.fromRGB(95, 72, 60) --// charred
		rider.ImageTransparency = 0
	elseif zone == "yellow" then
		rider.ImageColor3 = Color3.fromRGB(235, 225, 205)
		rider.ImageTransparency = 0
	else
		rider.ImageColor3 = Color3.new(1, 1, 1)
		rider.ImageTransparency = 0
	end
	--// a happy swell while it is perfect, eased so it never snaps
	local target = inGreen and 1.15 or 1
	riderScale.Scale += (target - riderScale.Scale) * 0.35
end

local function startSweep(stage, greenCenter, speed)
	sweepSeconds = speed or 1
	paintZones(greenCenter)
	caption.Text = stage == 2 and "Save it! One more..." or "Stop it on the GREEN!"
	caption.TextColor3 = CHOC
	sweepStart = os.clock()
	sweeping = true
	stopped = false
end

local function close(tellServer)
	if walkWatcher then
		walkWatcher:Disconnect()
		walkWatcher = nil
	end
	if animWatcher then
		animWatcher:Disconnect()
		animWatcher = nil
	end
	ContextActionService:UnbindAction(ACTION)
	if tellServer and current then
		timingRemote:FireServer("Abandon", current.Token)
	end
	current = nil
	sweeping = false
	gui.Enabled = false
end

----------------------------------------------------------------
-- Stopping the arrow
----------------------------------------------------------------
local function stopArrow()
	if not current or not sweeping or stopped then return end
	stopped = true
	sweeping = false
	--// Freeze the needle where WE see it and claim that position; the
	--// server honours it within tolerance of its own clock
	local position = arrowAt(os.clock() - sweepStart)
	arrow.Position = UDim2.fromScale(position, 0.5)
	stoppedAt = position
	dressRider(position)
	timingRemote:FireServer("Stop", current.Token, position)
end

catcher.Activated:Connect(stopArrow)

local function onAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		stopArrow()
	end
	return Enum.ContextActionResult.Sink
end

----------------------------------------------------------------
-- Server traffic
----------------------------------------------------------------
timingRemote.OnClientEvent:Connect(function(action, a, b, c, d)
	if action == "Open" and type(a) == "table" then
		current = {
			Token = a.Token,
			StationPosition = a.StationPosition,
		}
		--// the dish being cooked rides the arrow (no icon = no rider)
		local recipe = a.Dish and Config.Recipes[a.Dish]
		local icon = recipe and recipe.Icon or ""
		rider.Image = icon
		rider.Visible = icon ~= "" and icon ~= "rbxassetid://0"
		riderScale.Scale = 1

		gui.Enabled = true
		UiPop.Pop(gui)
		startSweep(a.Stage or 1, a.GreenCenter or 0.5, a.SweepSeconds)

		--// Space / gamepad A also stop it
		ContextActionService:BindAction(ACTION, onAction, false,
			Enum.KeyCode.Space, Enum.KeyCode.ButtonA)

		--// The arrow animation
		if animWatcher then animWatcher:Disconnect() end
		animWatcher = RunService.RenderStepped:Connect(function()
			if sweeping then
				local position = arrowAt(os.clock() - sweepStart)
				arrow.Position = UDim2.fromScale(position, 0.5)
				dressRider(position)
			end
		end)

		--// Wandering from the stove closes the panel and frees the pan
		if walkWatcher then walkWatcher:Disconnect() end
		walkWatcher = RunService.Heartbeat:Connect(function()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and current
				and (root.Position - current.StationPosition).Magnitude > TIMING.WalkAwayStuds then
				close(true)
			end
		end)

	elseif action == "Result" then
		--// a = token, b = zone, c = final quality (nil = more swings coming)
		if not current or current.Token ~= a then return end
		--// Green is a hit, red is a miss. Yellow is the shoulder - a GOOD
		--// swing that still counts, so it gets neither blip.
		if b == "green" then
			SfxLocal.Play("AnswerRight")
		elseif b == "red" then
			SfxLocal.Play("AnswerWrong")
		end

		if c and TIMING.OneStop == true then
			--// THE ONE-STOP VERDICT. A red stop names its side of the bar.
			local look
			if c == "Overcooked" then
				look = (b == "red" and zoneAt(stoppedAt) == "raw") and RESULT.Raw or RESULT.Burnt
			else
				look = RESULT[c] or RESULT.Burnt
			end
			caption.Text = look.Text
			caption.TextColor3 = look.Color

			if c == "Perfect" then
				MinigameJuice.Burst(rider.Visible and rider or arrow, BASIL)
				MinigameJuice.Bounce(caption)
			elseif b == "red" then
				MinigameJuice.Wrong(bar)
			else
				MinigameJuice.Bounce(caption)
			end
		else
			--// THE GAME AS DESIGNED: the same words it always said, with the
			--// new feedback on top
			local look = ZONE_LABEL[b]
			if look then
				caption.Text = c and (c == "Good" and "GOOD!" or look.Text) or look.Text
				caption.TextColor3 = look.Color
			end
			if b == "green" then
				MinigameJuice.Burst(rider.Visible and rider or arrow, BASIL)
				MinigameJuice.Bounce(caption)
			elseif b == "red" then
				MinigameJuice.Wrong(bar) --// a miss: red flash + shake, then swing again
			else
				MinigameJuice.Bounce(caption)
			end
		end

	elseif action == "Sweep" then
		--// a = token, b = stage, c = fresh green centre, d = fresh pace
		if not current or current.Token ~= a then return end
		task.delay(TIMING.ResultFlashSeconds, function()
			if current and current.Token == a then
				startSweep(b, c, d)
			end
		end)

	elseif action == "Close" then
		if current and current.Token == a then
			--// Let a final verdict linger for a beat before vanishing
			local token = a
			task.delay(TIMING.ResultFlashSeconds, function()
				if current and current.Token == token then
					close(false)
				end
			end)
		end
	end
end)

--// Death mid-flip drops the panel; the server timeout frees the pan
player.CharacterAdded:Connect(function()
	if current then
		close(true)
	end
end)
