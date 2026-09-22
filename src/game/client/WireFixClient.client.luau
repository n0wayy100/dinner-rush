--[[
	Dinner Rush - WireFixClient
	StarterPlayer.StarterPlayerScripts.Client.WireFixClient  (LocalScript)

	The breaker wire-matching panel (gated to the minigame difficulties -
	ON for every difficulty since the Sep 2026 un-freeze; EASY deals
	the gentlest wire count).

	INPUT, Among-Us style: PRESS a wire stub and DRAG - the wire follows
	your finger/cursor - then RELEASE on the matching socket to connect.
	A quick press-release without movement acts as a TAP-select instead,
	and tapping the matching socket then connects (both styles work).
	Only matching colours connect; a wrong drop shakes the socket. All
	wires connected = auto-submit.

	Render/report only: the SERVER dealt the shuffle (payload.RightSlots)
	and checks the submitted answer. Walking away closes the panel and
	unlocks the breaker; server "Close" ends it from the other side.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local wireRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("WireFixRemote")

local WIREFIX = Config.WireFix

--// A little zap each time a wire seats (owner ruling: the fix sounds
--// on the INTERACTION, not a loop for the whole puzzle). Local-only.
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

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
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, 10)
end

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local PLATE = Color3.fromRGB(45, 42, 40)

local TAP_SLOP_PIXELS = 12 --// release closer than this = a tap, not a drag

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Panel skeleton (built once)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "WireFix_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 35
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.46, 0.6)
panel.BackgroundColor3 = CREAM
panel.Parent = gui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 3
panelStroke.Color = CHOC
panelStroke.Parent = panel

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.fromScale(0.5, 0.025)
title.Size = UDim2.fromScale(0.8, 0.1)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.TextColor3 = CHOC
title.Text = "FIX THE WIRES!"
title.Parent = panel

--// The dark electrical plate the wires live on
local plate = Instance.new("Frame")
plate.Name = "Plate"
plate.AnchorPoint = Vector2.new(0.5, 1)
plate.Position = UDim2.fromScale(0.5, 0.965)
plate.Size = UDim2.fromScale(0.92, 0.8)
plate.BackgroundColor3 = PLATE
plate.Parent = panel

local plateCorner = Instance.new("UICorner")
plateCorner.CornerRadius = UDim.new(0, 10)
plateCorner.Parent = plate

local plateStroke = Instance.new("UIStroke")
plateStroke.Thickness = 2
plateStroke.Color = CHOC
plateStroke.Parent = plate

--// Connected wires draw here, under the stubs
local lineLayer = Instance.new("Frame")
lineLayer.Name = "Lines"
lineLayer.Size = UDim2.fromScale(1, 1)
lineLayer.BackgroundTransparency = 1
lineLayer.Parent = plate

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local current = nil --// { Token, Wires, RightSlots, BreakerPosition }
local leftStubs, rightSockets, lines = {}, {}, {}
local answer = {} --// leftIndex -> right slot
local selectedLeft = nil
local walkWatcher = nil
local drag = nil --// { LeftIndex, Input (touch), Line, StartPos }

local function clearDrag()
	if drag then
		if drag.Line then
			drag.Line:Destroy()
		end
		drag = nil
	end
end

local function clearBoard()
	clearDrag()
	for _, stub in pairs(leftStubs) do stub.Button:Destroy() end
	for _, socket in pairs(rightSockets) do socket.Button:Destroy() end
	for _, line in pairs(lines) do line:Destroy() end
	leftStubs, rightSockets, lines = {}, {}, {}
	answer = {}
	selectedLeft = nil
end

local function close(tellServer)
	if walkWatcher then
		walkWatcher:Disconnect()
		walkWatcher = nil
	end
	if tellServer and current then
		wireRemote:FireServer("Abandon", current.Token)
	end
	current = nil
	clearBoard()
	gui.Enabled = false
end

----------------------------------------------------------------
-- Geometry helpers (IgnoreGuiInset = true, so screen space matches
-- AbsolutePosition space and input positions map directly)
----------------------------------------------------------------
local function stubOut(leftIndex) --// where a wire leaves its stub
	local button = leftStubs[leftIndex].Button
	return button.AbsolutePosition + button.AbsoluteSize * Vector2.new(1, 0.5)
		- plate.AbsolutePosition
end

local function socketIn(slot) --// where a wire enters a socket
	local button = rightSockets[slot].Button
	return button.AbsolutePosition + button.AbsoluteSize * Vector2.new(0, 0.5)
		- plate.AbsolutePosition
end

local function makeLine(colorIndex)
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.BackgroundColor3 = WIREFIX.Colors[colorIndex] or CREAM
	line.BorderSizePixel = 0
	line.Parent = lineLayer

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = line

	return line
end

local function layLine(line, from, to)
	local middle = (from + to) / 2
	local delta = to - from
	line.Position = UDim2.fromOffset(middle.X, middle.Y)
	line.Size = UDim2.fromOffset(delta.Magnitude, 6)
	line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
end

local function socketAt(screenPosition)
	for slot, socket in pairs(rightSockets) do
		local topLeft = socket.Button.AbsolutePosition
		local size = socket.Button.AbsoluteSize
		if screenPosition.X >= topLeft.X and screenPosition.X <= topLeft.X + size.X
			and screenPosition.Y >= topLeft.Y and screenPosition.Y <= topLeft.Y + size.Y then
			return slot
		end
	end
	return nil
end

----------------------------------------------------------------
-- Connection logic (shared by drag-drop and tap-tap)
----------------------------------------------------------------
local function shake(guiObject)
	local tween = TweenService:Create(guiObject,
		TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 3, true),
		{ Rotation = 8 })
	tween:Play()
	tween.Completed:Once(function()
		guiObject.Rotation = 0
	end)
end

local function setSelected(leftIndex)
	if selectedLeft and leftStubs[selectedLeft] then
		leftStubs[selectedLeft].Stroke.Color = CHOC
		leftStubs[selectedLeft].Stroke.Thickness = 2.5
	end
	selectedLeft = leftIndex
	if leftIndex and leftStubs[leftIndex] then
		leftStubs[leftIndex].Stroke.Color = Color3.new(1, 1, 1)
		leftStubs[leftIndex].Stroke.Thickness = 4
	end
end

local function unplug(leftIndex)
	if answer[leftIndex] then
		answer[leftIndex] = nil
		if lines[leftIndex] then
			lines[leftIndex]:Destroy()
			lines[leftIndex] = nil
		end
	end
end

local function connectedCount()
	local count = 0
	for _ in pairs(answer) do
		count += 1
	end
	return count
end

--// Returns true when the wire connected
local function tryConnect(leftIndex, slot)
	if not current then return false end

	local colorIndex = current.RightSlots[slot]
	if colorIndex ~= leftIndex then
		shake(rightSockets[slot].Button)
		return false
	end

	--// Steal the slot from any wire already parked there
	for otherLeft, usedSlot in pairs(answer) do
		if usedSlot == slot then
			unplug(otherLeft)
		end
	end

	answer[leftIndex] = slot
	local line = makeLine(leftIndex)
	layLine(line, stubOut(leftIndex), socketIn(slot))
	lines[leftIndex] = line

	playConnectZap() --// the satisfying part

	if connectedCount() >= current.Wires then
		wireRemote:FireServer("Submit", current.Token, answer)
	end
	return true
end

----------------------------------------------------------------
-- Drag machinery
----------------------------------------------------------------
local function beginDrag(leftIndex, input)
	if not current then return end
	clearDrag()
	unplug(leftIndex) --// grabbing a connected wire pulls it out
	setSelected(leftIndex)

	drag = {
		LeftIndex = leftIndex,
		Input = input,
		Line = makeLine(leftIndex),
		StartPos = Vector2.new(input.Position.X, input.Position.Y),
	}
	layLine(drag.Line, stubOut(leftIndex),
		Vector2.new(input.Position.X, input.Position.Y) - plate.AbsolutePosition)
end

local function updateDrag(screenPosition)
	if not drag or not current then return end
	layLine(drag.Line, stubOut(drag.LeftIndex), screenPosition - plate.AbsolutePosition)
end

local function endDrag(screenPosition)
	if not drag or not current then return end
	local leftIndex = drag.LeftIndex
	local moved = (screenPosition - drag.StartPos).Magnitude
	clearDrag()

	if moved < TAP_SLOP_PIXELS then
		--// Barely moved: that was a TAP - keep the stub selected so the
		--// player can tap the socket next (the fallback style)
		return
	end

	local slot = socketAt(screenPosition)
	if slot then
		if tryConnect(leftIndex, slot) then
			setSelected(nil)
		end
	else
		--// Dropped on nothing: the wire snaps back
		setSelected(nil)
	end
end

UserInputService.InputChanged:Connect(function(input)
	if not drag then return end
	if input == drag.Input
		or (drag.Input.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement) then
		updateDrag(Vector2.new(input.Position.X, input.Position.Y))
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not drag then return end
	if input == drag.Input
		or (drag.Input.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1) then
		endDrag(Vector2.new(input.Position.X, input.Position.Y))
	end
end)

----------------------------------------------------------------
-- Board building
----------------------------------------------------------------
local function rowY(index, count)
	return 0.12 + (index - 0.5) * (0.82 / count)
end

local function makeStub(colorIndex, x, index)
	local stub = Instance.new("TextButton")
	stub.AnchorPoint = Vector2.new(0.5, 0.5)
	stub.Position = UDim2.fromScale(x, rowY(index, current.Wires))
	stub.Size = UDim2.fromScale(0.16, 0.7 / current.Wires)
	stub.BackgroundColor3 = WIREFIX.Colors[colorIndex] or CREAM
	stub.Text = ""
	stub.Parent = plate

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = stub

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CHOC
	stroke.Parent = stub

	return stub, stroke
end

local function buildBoard()
	clearBoard()

	for index = 1, current.Wires do
		local stub, stroke = makeStub(index, 0.11, index)
		stub.Name = "Stub" .. index
		leftStubs[index] = { Button = stub, Stroke = stroke }

		--// Press = pick the wire up; the drag machinery decides whether it
		--// was a drag (drop on a socket) or a tap (leave it selected)
		stub.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				beginDrag(index, input)
			end
		end)
	end

	for slot = 1, current.Wires do
		local colorIndex = current.RightSlots[slot]
		local socket, stroke = makeStub(colorIndex, 0.89, slot)
		socket.Name = "Socket" .. slot
		rightSockets[slot] = { Button = socket, Stroke = stroke }

		--// Tap-tap fallback: with a stub selected, tapping its socket connects
		socket.Activated:Connect(function()
			if not selectedLeft then return end
			if tryConnect(selectedLeft, slot) then
				setSelected(nil)
			else
				setSelected(nil)
			end
		end)
	end
end

----------------------------------------------------------------
-- Server traffic
----------------------------------------------------------------
local function open(payload)
	current = {
		Token = payload.Token,
		Wires = payload.Wires,
		RightSlots = payload.RightSlots,
		BreakerPosition = payload.BreakerPosition,
	}
	gui.Enabled = true
	buildBoard()

	--// Wandering off closes the panel and unlocks the breaker
	if walkWatcher then walkWatcher:Disconnect() end
	walkWatcher = RunService.Heartbeat:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and current
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
			close(false)
		end
	elseif action == "Deny" then
		--// Should be unreachable (only matches connect) - reset and retry
		if current and current.Token == a then
			for _, line in pairs(lines) do
				line:Destroy()
			end
			lines = {}
			answer = {}
			clearDrag()
			setSelected(nil)
		end
	end
end)

--// Death mid-repair drops the panel; the server timeout frees the breaker
player.CharacterAdded:Connect(function()
	if current then
		close(true)
	end
end)
