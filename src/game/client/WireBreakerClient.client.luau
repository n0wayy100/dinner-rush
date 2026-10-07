--[[
	Dinner Rush - WireBreakerClient
	StarterPlayer.StarterPlayerScripts.Client.WireBreakerClient  (LocalScript)

	THE BREAKER-BOX SCENE version of the power-outage wire puzzle (Oct
	2026, Claude Design Prompt C). Runs ONLY when Config.WireFix.Style is
	"Breaker" - "Classic" runs WireFixClient instead, so the owner can
	compare the two. Same server, same protocol, same rules:

	  server -> client  "Open" {Token, Wires, RightSlots, BreakerPosition}
	                    "Close" token   (after our Submit = solved; before = cancelled)
	                    "Deny" token    (answer refused - reset the board)
	  client -> server  "Submit" token, answer   (answer[leftIndex] = slot)
	                    "Abandon" token

	Left wire N is colour N (Config.WireFix.Colors); RightSlots[slot] says
	which colour each socket wants. TAP a plug then its socket, or PRESS a
	plug and DRAG the cable onto the socket. Only matching colours connect;
	a wrong socket zaps red and shakes.

	The picture: the room goes dark (a flashlight hole), the breaker box
	opens with a dead bulb flickering at the top, plugs on the left,
	sockets on the right, the big lever on the far right. Each connection
	draws its cable with a spark crackle and lights the socket. All wires
	in: the lever FLIPS UP, the bulb flickers on, the dark lifts and the
	POWER stamp slams.

	Render/report only: the server dealt the shuffle and checks the answer.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local WIREFIX = Config.WireFix
if (WIREFIX.Style or "Classic") ~= "Breaker" then return end

local ART = WIREFIX.BreakerArt or {}
local wireRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("WireFixRemote")

local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)

local TAP_SLOP_PIXELS = 12 --// release closer than this = a tap, not a drag

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function image(parent, key, class)
	local img = Instance.new(class or "ImageLabel")
	img.Name = key
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Image = ART[key] or ""
	img.Parent = parent
	if img:IsA("ImageButton") then img.AutoButtonColor = false end
	return img
end

local function aspect(obj, ratio)
	local a = Instance.new("UIAspectRatioConstraint")
	a.AspectRatio = ratio
	a.Parent = obj
end

local function playSheet(img, frames, fps)
	img.ImageRectSize = Vector2.new(256, 256)
	task.spawn(function()
		for i = 0, frames - 1 do
			if not img.Parent then return end
			img.ImageRectOffset = Vector2.new((i % 4) * 256, math.floor(i / 4) * 256)
			task.wait(1 / fps)
		end
		img:Destroy()
	end)
end

--// the same little zap the classic panel plays when a wire seats
local function playConnectZap()
	local sfx = Config.Sfx
	if not (sfx and sfx.Enabled) then return end
	local entry = sfx.Sounds.WireConnect
	if not entry or entry.Id == "" then return end
	local sound = Instance.new("Sound")
	sound.SoundId = ("rbxassetid://%s"):format(tostring(entry.Id))
	sound.Volume = (entry.Volume or 1) * (sfx.MasterVolume or 1)
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function() sound:Destroy() end)
	Debris:AddItem(sound, 10)
end

local function wireColor(index)
	return WIREFIX.Colors[index] or MUSTARD
end

----------------------------------------------------------------
-- The scene (built once)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "WireBreaker_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true --// screen space == AbsolutePosition space
gui.Enabled = false
gui.DisplayOrder = 35
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local dark = image(gui, "Dark_Overlay")
dark.ScaleType = Enum.ScaleType.Stretch
dark.Position = UDim2.fromScale(0.5, 0.5)
dark.Size = UDim2.fromScale(1.02, 1.02)
dark.ImageTransparency = 1
dark.ZIndex = 1

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.55)
panel.BackgroundTransparency = 1
panel.ZIndex = 2
panel.Parent = gui
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

local side = 400
local function layout()
	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(1366, 768)
	side = math.floor(math.clamp(math.min(view.X * 0.36, view.Y * 0.6), 260, 460))
	panel.Size = UDim2.fromOffset(side, side)
end
layout()
do
	local function watch()
		local camera = workspace.CurrentCamera
		if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout) end
		layout()
	end
	watch()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watch)
end

local back = image(panel, "Breaker_Panel")
back.ScaleType = Enum.ScaleType.Stretch
back.Position = UDim2.fromScale(0.5, 0.5)
back.Size = UDim2.fromScale(1, 1)
back.ZIndex = 2

--// the dead bulb at the top, with its halo
local bulbHalo = image(panel, "Glow_Halo")
bulbHalo.Position = UDim2.fromScale(0.5, 0.22)
bulbHalo.Size = UDim2.fromScale(0.36, 0.36)
bulbHalo.ImageColor3 = MUSTARD
bulbHalo.ImageTransparency = 1
bulbHalo.ZIndex = 3
local bulb = image(panel, "Light_Bulb_Off")
bulb.Position = UDim2.fromScale(0.5, 0.22)
bulb.Size = UDim2.fromScale(0.18, 0.18)
bulb.ZIndex = 4
local bulbScale = Instance.new("UIScale")
bulbScale.Parent = bulb

local hint = Instance.new("TextLabel")
hint.BackgroundTransparency = 1
hint.AnchorPoint = Vector2.new(0.5, 0)
hint.Position = UDim2.fromScale(0.5, 0.92)
hint.Size = UDim2.fromScale(0.8, 0.065)
hint.Font = Enum.Font.FredokaOne
hint.TextScaled = true
hint.TextColor3 = Color3.new(1, 1, 1)
hint.TextStrokeColor3 = CHOC
hint.TextStrokeTransparency = 0
hint.Text = "Match the wire colours!"
hint.ZIndex = 9
hint.Parent = panel

--// the lever: a base, and a handle that pivots near its bottom
local LEVER_X, LEVER_Y = 0.885, 0.6
local LEVER_W, LEVER_H = 0.11, 0.38
local leverBase = image(panel, "Lever_Base")
leverBase.ScaleType = Enum.ScaleType.Stretch
leverBase.Position = UDim2.fromScale(LEVER_X, LEVER_Y)
leverBase.Size = UDim2.fromScale(LEVER_W, LEVER_H)
leverBase.ZIndex = 3
local leverHandle = image(panel, "Lever_Handle")
leverHandle.ScaleType = Enum.ScaleType.Stretch
leverHandle.ZIndex = 4
local PIVOT = 0.86 --// the handle's pivot, as a fraction down its height
local leverAngle = 180 --// 180 = down (off), 0 = up (on)

--// GUI rotation spins round the CENTRE, so place the centre so the PIVOT
--// stays put: centre = pivot - rotate(pivot offset)
local function placeLever()
	--// the handle swings about the MIDDLE of the base: up = on, down = off
	local w, h = side * LEVER_W * 0.9, side * LEVER_H * 0.62
	local pivot = Vector2.new(side * LEVER_X, side * LEVER_Y)
	local offset = Vector2.new(0, h * (PIVOT - 0.5))
	local r = math.rad(leverAngle)
	local rotated = Vector2.new(-offset.Y * math.sin(r), offset.Y * math.cos(r))
	local centre = pivot - rotated
	leverHandle.Size = UDim2.fromOffset(w, h)
	leverHandle.Position = UDim2.fromOffset(centre.X, centre.Y)
	leverHandle.Rotation = leverAngle
end
placeLever()
panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeLever)

--// cables live on their own layer, in panel pixels
local lineLayer = Instance.new("Frame")
lineLayer.BackgroundTransparency = 1
lineLayer.Size = UDim2.fromScale(1, 1)
lineLayer.ZIndex = 5
lineLayer.Parent = panel

local stamp = image(panel, "Power_Stamp")
stamp.Position = UDim2.fromScale(0.5, 0.52)
stamp.Size = UDim2.fromScale(0.56, 0.56)
stamp.ZIndex = 12
stamp.Visible = false
local stampScale = Instance.new("UIScale")
stampScale.Parent = stamp

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local current = nil --// { Token, Wires, RightSlots, BreakerPosition }
local plugs, sockets, lines = {}, {}, {}
local answer = {}
local selected = nil
local submitted = false
local drag = nil
local walkWatcher, renderWatcher = nil, nil

local function rowY(index, count)
	if count <= 1 then return 0.6 end
	return 0.42 + (index - 1) * (0.42 / (count - 1))
end

local function toPanel(screen)
	return screen - panel.AbsolutePosition
end

local function plugOut(index)
	local b = plugs[index].Button
	return toPanel(b.AbsolutePosition + b.AbsoluteSize * Vector2.new(0.92, 0.5))
end

local function socketIn(slot)
	local b = sockets[slot].Button
	return toPanel(b.AbsolutePosition + b.AbsoluteSize * Vector2.new(0.3, 0.5))
end

local function makeCable(index)
	local cable = image(lineLayer, "Wire_Cable")
	cable.ScaleType = Enum.ScaleType.Stretch
	cable.ImageColor3 = wireColor(index)
	cable.ZIndex = 5
	return cable
end

local function layCable(cable, from, to)
	local middle = (from + to) / 2
	local delta = to - from
	cable.Position = UDim2.fromOffset(middle.X, middle.Y)
	cable.Size = UDim2.fromOffset(delta.Magnitude, math.max(6, side * 0.035))
	cable.Rotation = math.deg(math.atan2(delta.Y, delta.X))
end

local function shake(obj)
	local t = TweenService:Create(obj,
		TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 3, true),
		{ Rotation = 12 })
	t:Play()
	t.Completed:Once(function() obj.Rotation = 0 end)
end

local function spark(at, size, color)
	local s = image(panel, "Spark_Sheet")
	s.Position = UDim2.fromOffset(at.X, at.Y)
	s.Size = UDim2.fromOffset(side * size, side * size)
	if color then s.ImageColor3 = color end
	s.ZIndex = 10
	playSheet(s, 16, 30)
end

local function setSelected(index)
	if selected and plugs[selected] then
		plugs[selected].Halo.ImageTransparency = 1
	end
	selected = index
	if index and plugs[index] then
		plugs[index].Halo.ImageTransparency = 0.25
		plugs[index].Scale.Scale = 1.2
		tween(plugs[index].Scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

local function unplug(index)
	local slot = answer[index]
	if lines[index] then lines[index]:Destroy() lines[index] = nil end
	answer[index] = nil
	if slot and sockets[slot] then
		sockets[slot].Halo.ImageTransparency = 1
	end
end

local function connectedCount()
	local n = 0
	for _ in pairs(answer) do n += 1 end
	return n
end

--// returns true when the wire connected
local function tryConnect(index, slot)
	if not current or submitted then return false end
	local socket = sockets[slot]
	if current.RightSlots[slot] ~= index then
		--// WRONG: a red zap, the socket shakes, the box jolts
		local bolt = image(panel, "Zap_Bolt")
		local at = toPanel(socket.Button.AbsolutePosition + socket.Button.AbsoluteSize / 2)
		bolt.Position = UDim2.fromOffset(at.X, at.Y - side * 0.05)
		bolt.Size = UDim2.fromOffset(side * 0.09, side * 0.18)
		bolt.ImageColor3 = TOMATO
		bolt.ZIndex = 11
		tween(bolt, 0.35, { ImageTransparency = 1, Size = UDim2.fromOffset(side * 0.13, side * 0.26) })
		task.delay(0.36, function() bolt:Destroy() end)
		socket.Button.ImageColor3 = TOMATO
		task.delay(0.25, function()
			if socket.Button.Parent then socket.Button.ImageColor3 = wireColor(current and current.RightSlots[slot] or 1) end
		end)
		shake(socket.Button)
		panel.Rotation = math.random() < 0.5 and -2 or 2
		tween(panel, 0.2, { Rotation = 0 }, Enum.EasingStyle.Back)
		return false
	end

	--// steal the socket from any wire already parked there
	for other, used in pairs(answer) do
		if used == slot then unplug(other) end
	end

	--// RIGHT: the cable grows across, the socket sparks and lights up
	answer[index] = slot
	local cable = makeCable(index)
	lines[index] = cable
	local from, to = plugOut(index), socketIn(slot)
	local grow = Instance.new("NumberValue")
	grow.Changed:Connect(function(v)
		if cable.Parent then layCable(cable, from, from:Lerp(to, v)) end
	end)
	layCable(cable, from, from)
	tween(grow, 0.14, { Value = 1 })
	task.delay(0.16, function() grow:Destroy() end)

	task.delay(0.12, function()
		if not socket.Button.Parent then return end
		spark(to, 0.26, nil)
		socket.Halo.ImageTransparency = 0.3
		socket.Scale.Scale = 1.25
		tween(socket.Scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	playConnectZap()
	setSelected(nil)

	if connectedCount() >= current.Wires then
		submitted = true
		hint.Text = "Flipping the breaker..."
		wireRemote:FireServer("Submit", current.Token, answer)
	end
	return true
end

----------------------------------------------------------------
-- Building the board for a puzzle
----------------------------------------------------------------
local function clearBoard()
	if drag and drag.Cable then drag.Cable:Destroy() end
	drag = nil
	for _, p in pairs(plugs) do p.Button:Destroy() p.Halo:Destroy() end
	for _, s in pairs(sockets) do s.Button:Destroy() s.Halo:Destroy() end
	for _, l in pairs(lines) do l:Destroy() end
	plugs, sockets, lines, answer = {}, {}, {}, {}
	selected = nil
end

local function socketAt(screenPosition)
	for slot, s in pairs(sockets) do
		local tl, size = s.Button.AbsolutePosition, s.Button.AbsoluteSize
		if screenPosition.X >= tl.X and screenPosition.X <= tl.X + size.X
			and screenPosition.Y >= tl.Y and screenPosition.Y <= tl.Y + size.Y then
			return slot
		end
	end
	return nil
end

local function buildBoard()
	clearBoard()
	local count = current.Wires
	local size = math.min(0.15, 0.5 / count)
	for index = 1, count do
		local halo = image(panel, "Glow_Halo")
		halo.Position = UDim2.fromScale(0.2, rowY(index, count))
		halo.Size = UDim2.fromScale(size * 2, size * 2)
		halo.ImageColor3 = wireColor(index)
		halo.ImageTransparency = 1
		halo.ZIndex = 5
		local button = image(panel, "Wire_Plug", "ImageButton")
		button.Position = UDim2.fromScale(0.2, rowY(index, count))
		button.Size = UDim2.fromScale(size * 1.1, size * 1.1)
		button.ImageColor3 = wireColor(index)
		button.ZIndex = 7
		local scale = Instance.new("UIScale")
		scale.Parent = button
		plugs[index] = { Button = button, Halo = halo, Scale = scale }

		button.InputBegan:Connect(function(input)
			if submitted then return end
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then return end
			unplug(index) --// grabbing a connected wire pulls it out
			setSelected(index)
			local cable = makeCable(index)
			drag = { Index = index, Cable = cable, Start = Vector2.new(input.Position.X, input.Position.Y),
				Input = input.UserInputType == Enum.UserInputType.Touch and input or nil }
			local from = plugOut(index)
			layCable(cable, from, from)
		end)
	end

	for slot = 1, count do
		local colorIndex = current.RightSlots[slot]
		local halo = image(panel, "Glow_Halo")
		halo.Position = UDim2.fromScale(0.66, rowY(slot, count))
		halo.Size = UDim2.fromScale(size * 2.2, size * 2.2)
		halo.ImageColor3 = wireColor(colorIndex)
		halo.ImageTransparency = 1
		halo.ZIndex = 5
		local button = image(panel, "Wire_Socket", "ImageButton")
		button.Position = UDim2.fromScale(0.66, rowY(slot, count))
		button.Size = UDim2.fromScale(size, size)
		button.ImageColor3 = wireColor(colorIndex)
		button.ZIndex = 7
		local scale = Instance.new("UIScale")
		scale.Parent = button
		sockets[slot] = { Button = button, Halo = halo, Scale = scale }
		button.Activated:Connect(function()
			if selected and not drag then
				tryConnect(selected, slot)
			end
		end)
	end
end

--// drag: the cable follows the pointer; release on a socket connects
UserInputService.InputChanged:Connect(function(input)
	if not drag then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement
		and input.UserInputType ~= Enum.UserInputType.Touch then return end
	if drag.Input and input ~= drag.Input then return end
	layCable(drag.Cable, plugOut(drag.Index), toPanel(Vector2.new(input.Position.X, input.Position.Y)))
end)

UserInputService.InputEnded:Connect(function(input)
	if not drag then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then return end
	if drag.Input and input ~= drag.Input then return end
	local d = drag
	drag = nil
	d.Cable:Destroy()
	local at = Vector2.new(input.Position.X, input.Position.Y)
	if (at - d.Start).Magnitude < TAP_SLOP_PIXELS then
		return --// a tap: the plug stays selected for tap-tap
	end
	local slot = socketAt(at)
	if slot then
		tryConnect(d.Index, slot)
	end
end)

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------
local function close(tellServer)
	if walkWatcher then walkWatcher:Disconnect() walkWatcher = nil end
	if renderWatcher then renderWatcher:Disconnect() renderWatcher = nil end
	if tellServer and current then
		wireRemote:FireServer("Abandon", current.Token)
	end
	current = nil
	submitted = false
	tween(dark, 0.4, { ImageTransparency = 1 })
	tween(panelScale, 0.2, { Scale = 0.8 })
	task.delay(0.25, function()
		if not current then
			clearBoard()
			gui.Enabled = false
		end
	end)
end

local function powerOn(token)
	--// the lever flips up, the bulb flickers to life, the dark lifts
	local flip = Instance.new("NumberValue")
	flip.Value = leverAngle
	flip.Changed:Connect(function(v) leverAngle = v placeLever() end)
	tween(flip, 0.35, { Value = 0 }, Enum.EasingStyle.Back)
	task.delay(0.4, function() flip:Destroy() end)
	hint.Text = "POWER RESTORED!"
	hint.TextColor3 = BASIL

	task.spawn(function()
		task.wait(0.3)
		for i = 1, 4 do
			bulb.Image = ART.Light_Bulb_On or ""
			bulbHalo.ImageTransparency = 0.2
			task.wait(0.06 + i * 0.02)
			if i < 4 then
				bulb.Image = ART.Light_Bulb_Off or ""
				bulbHalo.ImageTransparency = 1
				task.wait(0.05)
			end
		end
		bulbScale.Scale = 1.35
		tween(bulbScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(bulbHalo, 0.4, { Size = UDim2.fromScale(0.6, 0.6), ImageTransparency = 0.1 })
		tween(dark, 0.6, { ImageTransparency = 1 })
		spark(toPanel(bulb.AbsolutePosition + bulb.AbsoluteSize / 2), 0.4, MUSTARD)
		task.wait(0.2)
		stamp.Visible = true
		stamp.ImageTransparency = 1
		stamp.Rotation = -30
		stampScale.Scale = 2.4
		tween(stamp, 0.18, { ImageTransparency = 0, Rotation = -10 })
		tween(stampScale, 0.24, { Scale = 1 }, Enum.EasingStyle.Back)
		task.delay(0.18, function()
			panelScale.Scale = 0.93
			tween(panelScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		task.wait(1.1)
		if current and current.Token == token then
			close(false)
		end
	end)
end

local function open(payload)
	current = {
		Token = payload.Token,
		Wires = payload.Wires,
		RightSlots = payload.RightSlots,
		BreakerPosition = payload.BreakerPosition,
	}
	submitted = false
	stamp.Visible = false
	hint.Text = "Match the wire colours!"
	hint.TextColor3 = Color3.new(1, 1, 1)
	bulb.Image = ART.Light_Bulb_Off or ""
	bulbHalo.ImageTransparency = 1
	bulbHalo.Size = UDim2.fromScale(0.36, 0.36)
	leverAngle = 180
	placeLever()

	gui.Enabled = true
	layout()
	buildBoard()
	tween(dark, 0.5, { ImageTransparency = 0 })
	panelScale.Scale = 0.6
	tween(panelScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)

	--// the dead bulb sputters now and then; the selected plug breathes
	local clock, flickerAt = 0, 1
	if renderWatcher then renderWatcher:Disconnect() end
	renderWatcher = RunService.RenderStepped:Connect(function(dt)
		clock += dt
		if not submitted and clock >= flickerAt then
			flickerAt = clock + 1.2 + math.random() * 2
			bulb.Image = ART.Light_Bulb_On or ""
			bulbHalo.ImageTransparency = 0.6
			task.delay(0.05, function()
				if not submitted then
					bulb.Image = ART.Light_Bulb_Off or ""
					bulbHalo.ImageTransparency = 1
				end
			end)
		end
		if selected and plugs[selected] and not drag then
			plugs[selected].Halo.ImageTransparency = 0.25 + (math.sin(clock * 6) * 0.5 + 0.5) * 0.4
		end
	end)

	if walkWatcher then walkWatcher:Disconnect() end
	walkWatcher = RunService.Heartbeat:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and current and not submitted
			and (root.Position - current.BreakerPosition).Magnitude > WIREFIX.WalkAwayStuds then
			close(true)
		end
	end)
end

wireRemote.OnClientEvent:Connect(function(action, a)
	if action == "Open" and type(a) == "table" then
		open(a)
	elseif action == "Close" then
		if current and current.Token == a then
			if submitted then
				powerOn(a) --// our answer was accepted
			else
				close(false) --// cancelled from the server side
			end
		end
	elseif action == "Deny" then
		--// should be unreachable (only matches connect) - reset and retry
		if current and current.Token == a then
			submitted = false
			for index in pairs(lines) do unplug(index) end
			setSelected(nil)
			hint.Text = "Match the wire colours!"
		end
	end
end)

--// death mid-repair drops the panel; the server timeout frees the breaker
player.CharacterAdded:Connect(function()
	if current then
		close(true)
	end
end)
