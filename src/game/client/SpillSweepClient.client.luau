--[[
	Dinner Rush - SpillSweepClient
	StarterPlayer.StarterPlayerScripts.Client.SpillSweepClient  (LocalScript)

	THE SWEEP PANEL (Config.Events.SpillSweep, owner design Sep 17
	2026): pressing E on the puddle with the broom opens a SQUARE
	panel - a wooden plank floor with glossy water droplets - and you
	DRAG the broom icon LEFT and RIGHT across it. Every full pass
	(StrokeTravelFraction of the panel's width) reports one "Stroke";
	the SERVER counts them (rate-capped, broom + proximity re-checked)
	and the droplets dry up as the count climbs. All platforms:
	  mouse / touch - press and drag sideways
	  gamepad      - left stick sweeps
	  keyboard     - hold Left/Right arrows
	Optional owner art: SpillSweep.FloorImage replaces the code-drawn
	planks ("" = planks). Render-only; the server owns the finish.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SWEEP = Config.Events and Config.Events.SpillSweep
if not SWEEP then return end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local sweepRemote = remotes:WaitForChild("SpillSweepRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local BASIL = Color3.fromRGB(76, 175, 109)
local WATER = Color3.fromRGB(120, 180, 235)
local PLANK_A = Color3.fromRGB(178, 128, 84)
local PLANK_B = Color3.fromRGB(158, 112, 72)

local DROPLETS = 8 --// visual blobs; they dry as the stroke count climbs

local session = nil

local function teardown()
	if not session then return end
	if session.Conn then session.Conn:Disconnect() end
	for _, conn in ipairs(session.InputConns or {}) do
		conn:Disconnect()
	end
	ContextActionService:UnbindAction("SweepStick")
	ContextActionService:UnbindAction("SweepKeys")
	if session.Gui then session.Gui:Destroy() end
	session = nil
end

local function buildPanel(data)
	local gui = Instance.new("ScreenGui")
	gui.Name = "SpillSweep_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Active = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.52, 0.52)
	panel.SizeConstraint = Enum.SizeConstraint.RelativeYY --// SQUARE, owner spec
	panel.Position = UDim2.fromScale(0.5, 0.46)
	panel.BackgroundColor3 = CREAM
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
	gradient.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.05, 0)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = CHOC
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Active = false
	title.Size = UDim2.fromScale(0.9, 0.1)
	title.Position = UDim2.fromScale(0.05, 0.02)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "SWEEP! Drag the broom to scrub!"
	title.TextColor3 = CHOC
	title.Parent = panel
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 22
	titleCap.Parent = title

	--// THE FLOOR: owner art when set, else code-drawn planks
	local floor = Instance.new(SWEEP.FloorImage ~= "" and "ImageLabel" or "Frame")
	floor.Name = "Floor"
	floor.Active = false
	floor.AnchorPoint = Vector2.new(0.5, 1)
	floor.Size = UDim2.fromScale(0.92, 0.8)
	floor.Position = UDim2.fromScale(0.5, 0.96)
	floor.BackgroundColor3 = PLANK_A
	floor.ClipsDescendants = true
	floor.Parent = panel
	if SWEEP.FloorImage ~= "" then
		floor.Image = SWEEP.FloorImage
		floor.ScaleType = Enum.ScaleType.Crop
	end
	local floorCorner = Instance.new("UICorner")
	floorCorner.CornerRadius = UDim.new(0.04, 0)
	floorCorner.Parent = floor
	local floorStroke = Instance.new("UIStroke")
	floorStroke.Thickness = 2.5
	floorStroke.Color = CHOC
	floorStroke.Parent = floor

	if SWEEP.FloorImage == "" then
		for i = 0, 5 do
			local plank = Instance.new("Frame")
			plank.Active = false
			plank.Size = UDim2.fromScale(1, 1 / 6)
			plank.Position = UDim2.fromScale(0, i / 6)
			plank.BackgroundColor3 = (i % 2 == 0) and PLANK_A or PLANK_B
			plank.BorderSizePixel = 0
			plank.Parent = floor
			local seam = Instance.new("Frame")
			seam.Active = false
			seam.Size = UDim2.new(1, 0, 0, 2)
			seam.Position = UDim2.fromScale(0, 1)
			seam.AnchorPoint = Vector2.new(0, 1)
			seam.BackgroundColor3 = Color3.fromRGB(120, 82, 52)
			seam.BorderSizePixel = 0
			seam.Parent = plank
		end
	end

	--// THE WATER: glossy droplets scattered centre-ish
	local droplets = {}
	for i = 1, DROPLETS do
		local size = 0.1 + math.random() * 0.16
		local blob = Instance.new("Frame")
		blob.Active = false
		blob.AnchorPoint = Vector2.new(0.5, 0.5)
		blob.Size = UDim2.fromScale(size * (0.8 + math.random() * 0.6), size)
		blob.Position = UDim2.fromScale(0.2 + math.random() * 0.6, 0.2 + math.random() * 0.55)
		blob.BackgroundColor3 = WATER
		blob.BackgroundTransparency = 0.25
		blob.BorderSizePixel = 0
		blob.Parent = floor
		local blobCorner = Instance.new("UICorner")
		blobCorner.CornerRadius = UDim.new(0.5, 0)
		blobCorner.Parent = blob
		local shine = Instance.new("Frame")
		shine.Active = false
		shine.AnchorPoint = Vector2.new(0.5, 0.5)
		shine.Size = UDim2.fromScale(0.3, 0.25)
		shine.Position = UDim2.fromScale(0.35, 0.3)
		shine.BackgroundColor3 = Color3.fromRGB(225, 245, 255)
		shine.BackgroundTransparency = 0.3
		shine.BorderSizePixel = 0
		shine.Parent = blob
		local shineCorner = Instance.new("UICorner")
		shineCorner.CornerRadius = UDim.new(0.5, 0)
		shineCorner.Parent = shine
		droplets[i] = blob
	end

	--// THE BROOM: rides a horizontal track, follows the drag
	local broom = Instance.new("TextLabel")
	broom.Active = false
	broom.AnchorPoint = Vector2.new(0.5, 0.5)
	broom.Size = UDim2.fromScale(0.34, 0.34)
	broom.Position = UDim2.fromScale(0.5, 0.55)
	broom.BackgroundTransparency = 1
	broom.Font = Enum.Font.FredokaOne
	broom.TextScaled = true
	broom.Text = "🧹"
	broom.Rotation = -18
	broom.Parent = floor

	--// progress: droplets left, in words kids skip anyway
	local progress = Instance.new("TextLabel")
	progress.Active = false
	progress.AnchorPoint = Vector2.new(1, 0)
	progress.Size = UDim2.fromScale(0.3, 0.07)
	progress.Position = UDim2.fromScale(0.95, 0.12)
	progress.BackgroundTransparency = 1
	progress.Font = Enum.Font.FredokaOne
	progress.TextScaled = true
	progress.TextXAlignment = Enum.TextXAlignment.Right
	progress.Text = ""
	progress.TextColor3 = CHOC
	progress.Parent = panel
	local progressCap = Instance.new("UITextSizeConstraint")
	progressCap.MaxTextSize = 18
	progressCap.Parent = progress

	return gui, panel, floor, broom, droplets, progress
end

sweepRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "Open" then
		teardown()
		local data = a
		local gui, panel, floor, broom, droplets, progress = buildPanel(data)
		session = {
			Token = data.Token,
			Gui = gui,
			Panel = panel,
			Floor = floor,
			Broom = broom,
			Droplets = droplets,
			Progress = progress,
			BroomX = 0.5,
			BroomY = 0.55,
			Travel = 0,       --// accumulated drag distance in floor-fractions
			StickX = 0,
			StickY = 0,
			KeyX = 0,
			KeyY = 0,
			Dragging = false,
			Done = false,
		}
		progress.Text = "0%"

		--// Full 2D scrubbing (owner call): the broom chases the drag in
		--// every direction, and all movement counts toward the strokes
		local function moveBroom(dxFrac, dyFrac)
			if not session or session.Done then return end
			if dxFrac == 0 and dyFrac == 0 then return end
			local newX = math.clamp(session.BroomX + dxFrac, 0.08, 0.92)
			local newY = math.clamp(session.BroomY + dyFrac, 0.12, 0.88)
			local moved = math.sqrt(
				(newX - session.BroomX) ^ 2 + (newY - session.BroomY) ^ 2)
			session.BroomX, session.BroomY = newX, newY
			session.Broom.Position = UDim2.fromScale(newX, newY)
			if dxFrac ~= 0 then
				session.Broom.Rotation = dxFrac > 0 and 18 or -18
			end
			session.Travel += moved
			if session.Travel >= SWEEP.StrokeTravelFraction then
				session.Travel = 0
				sweepRemote:FireServer("Stroke", session.Token)
			end
		end

		--// mouse / touch: press anywhere on the floor and drag sideways
		--// (the global connections live in the session and die with it)
		local lastInputX, lastInputY = nil, nil
		session.InputConns = {}
		floor.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				session.Dragging = true
				lastInputX, lastInputY = input.Position.X, input.Position.Y
			end
		end)
		table.insert(session.InputConns, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				if session then session.Dragging = false end
				lastInputX, lastInputY = nil, nil
			end
		end))
		table.insert(session.InputConns, UserInputService.InputChanged:Connect(function(input)
			if not session or session.Done or not session.Dragging then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local size = session.Floor.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then return end
			local x, y = input.Position.X, input.Position.Y
			if lastInputX and lastInputY then
				moveBroom((x - lastInputX) / size.X, (y - lastInputY) / size.Y)
			end
			lastInputX, lastInputY = x, y
		end))

		--// gamepad stick + arrow keys sweep too, both axes
		ContextActionService:BindAction("SweepStick", function(_, state, input)
			if session then
				local live = state == Enum.UserInputState.Change
					or state == Enum.UserInputState.Begin
				session.StickX = live and input.Position.X or 0
				session.StickY = live and -input.Position.Y or 0 --// stick up = broom up
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.Thumbstick1)
		ContextActionService:BindAction("SweepKeys", function(_, state, input)
			if session then
				local down = state == Enum.UserInputState.Begin
				if input.KeyCode == Enum.KeyCode.Left then
					session.KeyX = down and -1 or (session.KeyX < 0 and 0 or session.KeyX)
				elseif input.KeyCode == Enum.KeyCode.Right then
					session.KeyX = down and 1 or (session.KeyX > 0 and 0 or session.KeyX)
				elseif input.KeyCode == Enum.KeyCode.Up then
					session.KeyY = down and -1 or (session.KeyY < 0 and 0 or session.KeyY)
				elseif input.KeyCode == Enum.KeyCode.Down then
					session.KeyY = down and 1 or (session.KeyY > 0 and 0 or session.KeyY)
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.Left, Enum.KeyCode.Right,
			Enum.KeyCode.Up, Enum.KeyCode.Down)

		session.Conn = RunService.RenderStepped:Connect(function(dt)
			if not session or session.Done then return end
			local ax = math.abs(session.StickX) > 0.2 and session.StickX or session.KeyX
			local ay = math.abs(session.StickY) > 0.2 and session.StickY or session.KeyY
			if ax ~= 0 or ay ~= 0 then
				moveBroom(ax * dt * 1.6, ay * dt * 1.6)
			end
		end)

	elseif action == "Progress" then
		if not session or session.Token ~= a then return end
		local fill = b or 0
		session.Progress.Text = ("%d%%"):format(math.floor(fill * 100))
		--// droplets dry as the count climbs
		local keep = math.ceil(#session.Droplets * (1 - fill))
		for index = #session.Droplets, keep + 1, -1 do
			local blob = session.Droplets[index]
			if blob and blob.Parent then
				TweenService:Create(blob, TweenInfo.new(0.3, Enum.EasingStyle.Quad),
					{ Size = UDim2.fromScale(0, 0), BackgroundTransparency = 1 }):Play()
				task.delay(0.35, function()
					if blob.Parent then blob:Destroy() end
				end)
				session.Droplets[index] = nil
			end
		end

	elseif action == "Close" then
		if not session or session.Token ~= a then return end
		if b then --// success: the floor shines
			session.Done = true
			for _, blob in pairs(session.Droplets) do
				if blob and blob.Parent then
					TweenService:Create(blob, TweenInfo.new(0.25),
						{ Size = UDim2.fromScale(0, 0), BackgroundTransparency = 1 }):Play()
				end
			end
			local splash = Instance.new("TextLabel")
			splash.Active = false
			splash.AnchorPoint = Vector2.new(0.5, 0.5)
			splash.Size = UDim2.fromScale(0.9, 0.24)
			splash.Position = UDim2.fromScale(0.5, 0.5)
			splash.BackgroundTransparency = 1
			splash.Font = Enum.Font.FredokaOne
			splash.TextScaled = true
			splash.Text = "SPOTLESS! ✨"
			splash.TextColor3 = BASIL
			splash.TextStrokeColor3 = CHOC
			splash.TextStrokeTransparency = 0
			splash.Parent = session.Panel
			task.delay(0.9, teardown)
		else
			teardown()
		end
	end
end)

print("[SpillSweep] ready - drag it clean")
