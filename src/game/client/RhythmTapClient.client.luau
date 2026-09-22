--[[
	Dinner Rush - RhythmTapClient
	StarterPlayer.StarterPlayerScripts.Client.RhythmTapClient  (LocalScript)

	RHYTHM TAP (Sep 21 2026 - replaces recipe math). Notes slide toward a
	target ring; TAP each round note as it lands, and HOLD each long note
	from its head to its tail. The SERVER owns every note's timing and judges
	the press/release (RhythmTapRemote) - this only renders + reports.

	Protocol:
	  server -> client  ("Open", {Token, Notes={{Type,Head,Tail}}, TravelSeconds,
	                              HitWindowSeconds, TotalSeconds})
	                    ("HitOk", token, noteIndex)   -- note cleared
	                    ("HoldOk", token, noteIndex)  -- hold press accepted
	                    ("End", token, hits, quality)
	                    ("Close", token)
	  client -> server  ("Hit", token, noteIndex)         -- tap
	                    ("HoldStart"/"HoldEnd", token, noteIndex)

	Inputs: press/hold anywhere - tap / click / Space / gamepad A.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local remote = remotes:WaitForChild("RhythmTapRemote")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local BLUE = Color3.fromRGB(90, 160, 255)
local WHITE = Color3.fromRGB(255, 255, 255)

local TRACK_LEFT = 0.06
local TRACK_LINE = 0.8
local NEAR_WINDOW = 0.3 --// client leniency for picking which note a press means

local gui = Instance.new("ScreenGui")
gui.Name = "RhythmTap_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Enabled = false
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.62)
panel.Size = UDim2.fromScale(0.52, 0.24)
panel.BackgroundColor3 = CREAM
panel.Parent = gui
local panelRatio = Instance.new("UIAspectRatioConstraint")
panelRatio.AspectRatio = 2.4
panelRatio.Parent = panel
local panelGrad = Instance.new("UIGradient")
panelGrad.Rotation = 90
panelGrad.Color = ColorSequence.new(CREAM, CREAM_DEEP)
panelGrad.Parent = panel
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0.08, 0)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 3
panelStroke.Color = CHOC
panelStroke.Parent = panel

local header = Instance.new("TextLabel")
header.BackgroundColor3 = TOMATO
header.BorderSizePixel = 0
header.Size = UDim2.fromScale(1, 0.2)
header.Font = Enum.Font.FredokaOne
header.TextScaled = true
header.TextColor3 = WHITE
header.Text = "🎵 RHYTHM TAP!"
header.Parent = panel
local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0.3, 0)
headerCorner.Parent = header
local headerCap = Instance.new("UITextSizeConstraint")
headerCap.MaxTextSize = 26
headerCap.Parent = header

local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0.5)
track.Position = UDim2.fromScale(0.5, 0.62)
track.Size = UDim2.fromScale(0.92, 0.4)
track.BackgroundColor3 = Color3.fromRGB(245, 226, 200)
track.ClipsDescendants = true
track.Parent = panel
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(0.4, 0)
trackCorner.Parent = track
local trackStroke = Instance.new("UIStroke")
trackStroke.Thickness = 2
trackStroke.Color = CHOC
trackStroke.Parent = track

local lineRing = Instance.new("Frame")
lineRing.AnchorPoint = Vector2.new(0.5, 0.5)
lineRing.Position = UDim2.fromScale(TRACK_LINE, 0.5)
lineRing.Size = UDim2.fromScale(0.12, 1.5)
lineRing.BackgroundTransparency = 1
lineRing.ZIndex = 3
lineRing.Parent = track
local lineRingCorner = Instance.new("UICorner")
lineRingCorner.CornerRadius = UDim.new(1, 0)
lineRingCorner.Parent = lineRing
local lineRingStroke = Instance.new("UIStroke")
lineRingStroke.Thickness = 4
lineRingStroke.Color = BASIL
lineRingStroke.Parent = lineRing

local hint = Instance.new("TextLabel")
hint.AnchorPoint = Vector2.new(0.5, 1)
hint.Position = UDim2.fromScale(0.5, 0.98)
hint.Size = UDim2.fromScale(0.9, 0.16)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.FredokaOne
hint.TextScaled = true
hint.TextColor3 = CHOC
hint.Text = "Tap the circles, HOLD the bars!"
hint.Parent = panel
local hintCap = Instance.new("UITextSizeConstraint")
hintCap.MaxTextSize = 16
hintCap.Parent = hint

local verdict = Instance.new("TextLabel")
verdict.AnchorPoint = Vector2.new(0.5, 0.5)
verdict.Position = UDim2.fromScale(0.5, 0.5)
verdict.Size = UDim2.fromScale(0.9, 0.4)
verdict.BackgroundTransparency = 1
verdict.Font = Enum.Font.FredokaOne
verdict.TextScaled = true
verdict.Text = ""
verdict.TextColor3 = CHOC
verdict.TextStrokeColor3 = WHITE
verdict.TextStrokeTransparency = 0.2
verdict.Visible = false
verdict.ZIndex = 6
verdict.Parent = panel
local verdictCap = Instance.new("UITextSizeConstraint")
verdictCap.MaxTextSize = 40
verdictCap.Parent = verdict

----------------------------------------------------------------
-- Session
----------------------------------------------------------------
local session = nil
local renderConn = nil
local activeHold = nil

local function xForProgress(p)
	return TRACK_LEFT + math.clamp(p, -0.5, 1.5) * (TRACK_LINE - TRACK_LEFT)
end

local function stopRender()
	if renderConn then renderConn:Disconnect() renderConn = nil end
end

local function clearNotes()
	for _, child in ipairs(track:GetChildren()) do
		if child.Name == "Note" then child:Destroy() end
	end
end

local function closePanel()
	stopRender()
	clearNotes()
	gui.Enabled = false
	session = nil
	activeHold = nil
	ContextActionService:UnbindAction("RhythmTap")
end

local function makeTap()
	local f = Instance.new("Frame")
	f.Name = "Note"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromScale(0.08, 1.2)
	f.BackgroundColor3 = MUSTARD
	f.Visible = false
	f.ZIndex = 2
	f.Parent = track
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = f
	local s = Instance.new("UIStroke")
	s.Thickness = 2.5
	s.Color = CHOC
	s.Parent = f
	return f
end

local function makeHold()
	local f = Instance.new("Frame")
	f.Name = "Note"
	f.AnchorPoint = Vector2.new(0, 0.5)
	f.Size = UDim2.fromScale(0.1, 1.0)
	f.BackgroundColor3 = BLUE
	f.Visible = false
	f.ZIndex = 2
	f.Parent = track
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	local s = Instance.new("UIStroke")
	s.Thickness = 2.5
	s.Color = CHOC
	s.Parent = f
	return f
end

--// nearest live note by head-time, for a press
local function pickNote(elapsed)
	if not session then return nil end
	local best, bestErr
	for i, note in ipairs(session.Notes) do
		local w = session.Widgets[i]
		if w and not w.Done then
			local err = math.abs(elapsed - note.Head)
			if err <= NEAR_WINDOW and (not bestErr or err < bestErr) then
				best, bestErr = i, err
			end
		end
	end
	return best
end

local function onPress()
	if not session then return end
	local elapsed = os.clock() - session.Start
	local i = pickNote(elapsed)
	if not i then return end
	local note = session.Notes[i]
	if note.Type == "hold" then
		remote:FireServer("HoldStart", session.Token, i)
		activeHold = i
	else
		remote:FireServer("Hit", session.Token, i)
	end
end

local function onRelease()
	if not session or not activeHold then return end
	remote:FireServer("HoldEnd", session.Token, activeHold)
	activeHold = nil
end

local function markMiss(w)
	w.Done = true
	if w.Frame then
		w.Frame.BackgroundColor3 = TOMATO
		TweenService:Create(w.Frame, TweenInfo.new(0.25),
			{ BackgroundTransparency = 1 }):Play()
	end
end

----------------------------------------------------------------
-- Remote
----------------------------------------------------------------
remote.OnClientEvent:Connect(function(action, a, b, c)
	if action == "Open" then
		local payload = a
		closePanel()
		clearNotes()
		verdict.Visible = false
		hint.Visible = true

		local widgets = {}
		for i, note in ipairs(payload.Notes) do
			widgets[i] = {
				Frame = (note.Type == "hold") and makeHold() or makeTap(),
				Done = false,
			}
		end
		session = {
			Token = payload.Token,
			Notes = payload.Notes,
			Travel = payload.TravelSeconds,
			HitWindow = payload.HitWindowSeconds,
			Start = os.clock(),
			Widgets = widgets,
		}
		gui.Enabled = true

		--// Space + gamepad A through CAS so the A press does not also JUMP;
		--// Begin = press, End = release (for holds)
		ContextActionService:BindAction("RhythmTap", function(_, state)
			if state == Enum.UserInputState.Begin then
				onPress()
			elseif state == Enum.UserInputState.End then
				onRelease()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)

		renderConn = RunService.RenderStepped:Connect(function()
			if not session then return end
			local elapsed = os.clock() - session.Start
			for i, note in ipairs(session.Notes) do
				local w = session.Widgets[i]
				if w and not w.Done then
					local headP = (elapsed - (note.Head - session.Travel)) / session.Travel
					if note.Type == "hold" then
						local tailP = (elapsed - (note.Tail - session.Travel)) / session.Travel
						if headP >= -0.1 and tailP <= 1.5 then
							w.Frame.Visible = true
							local hx, tx = xForProgress(headP), xForProgress(tailP)
							local left = math.min(hx, tx)
							w.Frame.Position = UDim2.fromScale(left, 0.5)
							w.Frame.Size = UDim2.fromScale(math.max(math.abs(hx - tx), 0.05), 1.0)
						end
						if elapsed > note.Tail + session.HitWindow + 0.15 then
							if activeHold == i then activeHold = nil end
							markMiss(w)
						end
					else
						if headP >= -0.05 and headP <= 1.45 then
							w.Frame.Visible = true
							w.Frame.Position = UDim2.fromScale(xForProgress(headP), 0.5)
						end
						if elapsed > note.Head + session.HitWindow + 0.15 then
							markMiss(w)
						end
					end
				end
			end
		end)

	elseif action == "HoldOk" then
		--// press accepted: tint the bar green while it is held
		local w = session and session.Widgets[b]
		if w and w.Frame and not w.Done then
			w.Frame.BackgroundColor3 = BASIL
		end

	elseif action == "HitOk" then
		local w = session and session.Widgets[b]
		if w and not w.Done then
			w.Done = true
			w.Frame.BackgroundColor3 = BASIL
			TweenService:Create(w.Frame, TweenInfo.new(0.2, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
			lineRingStroke.Color = BASIL
		end

	elseif action == "End" then
		local quality = c
		stopRender()
		hint.Visible = false
		verdict.Visible = true
		if quality == "Perfect" then
			verdict.Text = "MASTER COOK!"
			verdict.TextColor3 = BASIL
		elseif quality == "Good" then
			verdict.Text = "DECENT COOK"
			verdict.TextColor3 = MUSTARD
		elseif quality == "Overcooked" then
			verdict.Text = "OVERCOOKED"
			verdict.TextColor3 = TOMATO
		else
			verdict.Text = "RUINED! BIN IT"
			verdict.TextColor3 = TOMATO
		end
		task.delay(1.1, function()
			if session and session.Token == a then closePanel() end
		end)

	elseif action == "Close" then
		closePanel()
	end
end)

----------------------------------------------------------------
-- Mouse + touch press/release (Space + gamepad A are bound via CAS above)
----------------------------------------------------------------
local function isTapInput(input)
	local t = input.UserInputType
	return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
end

UserInputService.InputBegan:Connect(function(input)
	if gui.Enabled and session and isTapInput(input) then
		onPress()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if gui.Enabled and session and isTapInput(input) then
		onRelease()
	end
end)
