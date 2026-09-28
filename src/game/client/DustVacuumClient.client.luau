--[[
	Dinner Rush - DustVacuumClient
	StarterPlayer.StarterPlayerScripts.Client.DustVacuumClient  (LocalScript)

	THE VACUUM PANEL (Config.Tidiness, owner design Sep 27 2026): pressing E on a
	dust spot with the vacuum opens a SQUARE panel with dust specks scattered at
	random spots. HOVER the nozzle over each speck to suck it up. Every speck
	sucked reports one "Suck"; the SERVER counts them (rate-capped, vacuum +
	proximity re-checked) and CLOSES the panel when the spot is clean.
	  mouse / touch - move the pointer over the specks
	  gamepad       - left stick steers the nozzle
	  keyboard      - arrow keys steer the nozzle
	Render-only; the server owns the finish. Driven by VacuumRemote:
	  S->C  "Open" {Token, DustCount} / "Progress" (token, frac) / "Close" (token, ok)
	  C->S  "Suck" (token) / "Abandon" (token)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local vacuumRemote = remotes:WaitForChild("VacuumRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local BASIL = Color3.fromRGB(76, 175, 109)
local DUST = Color3.fromRGB(150, 138, 116)
local FLOOR_A = Color3.fromRGB(120, 100, 78)

local SUCK_RADIUS = 0.09 --// floor-fraction: nozzle within this of a speck sucks it
local NOZZLE_SPEED = 1.2 --// floor-fractions/sec for stick/keys

local session = nil

local function teardown()
	if not session then return end
	if session.Render then session.Render:Disconnect() end
	for _, c in ipairs(session.Conns or {}) do c:Disconnect() end
	ContextActionService:UnbindAction("VacuumStick")
	if session.Gui then session.Gui:Destroy() end
	session = nil
end

local function buildPanel(dustCount)
	local gui = Instance.new("ScreenGui")
	gui.Name = "DustVacuum_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Active = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.52, 0.52)
	panel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	panel.Position = UDim2.fromScale(0.5, 0.46)
	panel.BackgroundColor3 = CREAM
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(CREAM, CREAM_DEEP)
	grad.Parent = panel
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
	title.Text = "VACUUM! Hover over the dust!"
	title.TextColor3 = CHOC
	title.Parent = panel
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 22
	titleCap.Parent = title

	local progress = Instance.new("TextLabel")
	progress.Active = false
	progress.AnchorPoint = Vector2.new(0.5, 0)
	progress.Size = UDim2.fromScale(0.5, 0.08)
	progress.Position = UDim2.fromScale(0.5, 0.115)
	progress.BackgroundTransparency = 1
	progress.Font = Enum.Font.FredokaOne
	progress.TextScaled = true
	progress.Text = "0%"
	progress.TextColor3 = CHOC
	progress.Parent = panel

	--// the floor play area
	local floor = Instance.new("Frame")
	floor.Name = "Floor"
	floor.Active = false
	floor.AnchorPoint = Vector2.new(0.5, 1)
	floor.Size = UDim2.fromScale(0.92, 0.78)
	floor.Position = UDim2.fromScale(0.5, 0.96)
	floor.BackgroundColor3 = FLOOR_A
	floor.ClipsDescendants = true
	floor.Parent = panel
	local floorCorner = Instance.new("UICorner")
	floorCorner.CornerRadius = UDim.new(0.04, 0)
	floorCorner.Parent = floor
	local floorStroke = Instance.new("UIStroke")
	floorStroke.Thickness = 2.5
	floorStroke.Color = CHOC
	floorStroke.Parent = floor

	--// scatter dust specks at random spots (kept off the edges)
	local dusts = {}
	for _ = 1, dustCount do
		local dx = 0.1 + math.random() * 0.8
		local dy = 0.12 + math.random() * 0.76
		local speck = Instance.new("Frame")
		speck.Name = "Dust"
		speck.Active = false
		speck.AnchorPoint = Vector2.new(0.5, 0.5)
		speck.Position = UDim2.fromScale(dx, dy)
		speck.Size = UDim2.fromScale(0.13, 0.13)
		speck.BackgroundColor3 = DUST
		speck.BackgroundTransparency = 0.1
		speck.Parent = floor
		local sc = Instance.new("UICorner")
		sc.CornerRadius = UDim.new(1, 0)
		sc.Parent = speck
		local wisp = Instance.new("TextLabel")
		wisp.Active = false
		wisp.Size = UDim2.fromScale(1, 1)
		wisp.BackgroundTransparency = 1
		wisp.Font = Enum.Font.FredokaOne
		wisp.TextScaled = true
		wisp.Text = "💨"
		wisp.TextTransparency = 0.15
		wisp.Parent = speck
		table.insert(dusts, { Frame = speck, X = dx, Y = dy, Sucked = false })
	end

	--// the vacuum nozzle (follows the pointer / stick)
	local nozzle = Instance.new("TextLabel")
	nozzle.Name = "Nozzle"
	nozzle.Active = false
	nozzle.AnchorPoint = Vector2.new(0.5, 0.5)
	nozzle.Size = UDim2.fromScale(0.18, 0.18)
	nozzle.Position = UDim2.fromScale(0.5, 0.5)
	nozzle.BackgroundTransparency = 1
	nozzle.Font = Enum.Font.FredokaOne
	nozzle.TextScaled = true
	nozzle.Text = "🌀"
	nozzle.ZIndex = 5
	nozzle.Parent = floor

	return gui, floor, nozzle, dusts, progress
end

vacuumRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "Open" then
		teardown()
		local data = a
		local count = (type(data) == "table" and data.DustCount) or 6
		local gui, floor, nozzle, dusts, progress = buildPanel(count)
		session = {
			Token = (type(data) == "table" and data.Token) or data,
			Gui = gui, Floor = floor, Nozzle = nozzle, Dusts = dusts,
			Progress = progress, Total = count, Sucked = 0,
			NX = 0.5, NY = 0.5, StickVel = Vector2.new(0, 0), Conns = {},
		}

		--// gamepad left stick steers the nozzle
		ContextActionService:BindAction("VacuumStick", function(_, _, input)
			if session and input.KeyCode == Enum.KeyCode.Thumbstick1 then
				local v = input.Position
				session.StickVel = Vector2.new(v.X, -v.Y) --// screen Y points down
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.Thumbstick1)

		--// keyboard arrows
		local keys = { Left = false, Right = false, Up = false, Down = false }
		table.insert(session.Conns, UserInputService.InputBegan:Connect(function(input, gp)
			if gp then return end
			local k = input.KeyCode
			if k == Enum.KeyCode.Left then keys.Left = true
			elseif k == Enum.KeyCode.Right then keys.Right = true
			elseif k == Enum.KeyCode.Up then keys.Up = true
			elseif k == Enum.KeyCode.Down then keys.Down = true end
		end))
		table.insert(session.Conns, UserInputService.InputEnded:Connect(function(input)
			local k = input.KeyCode
			if k == Enum.KeyCode.Left then keys.Left = false
			elseif k == Enum.KeyCode.Right then keys.Right = false
			elseif k == Enum.KeyCode.Up then keys.Up = false
			elseif k == Enum.KeyCode.Down then keys.Down = false end
		end))

		session.Render = RunService.RenderStepped:Connect(function(dt)
			if not session then return end
			local floorGui = session.Floor
			local fpos, fsize = floorGui.AbsolutePosition, floorGui.AbsoluteSize

			--// the nozzle follows the POINTER when it is over the floor, else the
			--// stick / arrow keys steer it
			local usedPointer = false
			if fsize.X > 0 and fsize.Y > 0 then
				local m = UserInputService:GetMouseLocation()
				local rx = (m.X - fpos.X) / fsize.X
				local ry = (m.Y - fpos.Y) / fsize.Y
				if rx >= 0 and rx <= 1 and ry >= 0 and ry <= 1 then
					session.NX, session.NY = rx, ry
					usedPointer = true
				end
			end
			if not usedPointer then
				local kx = (keys.Right and 1 or 0) - (keys.Left and 1 or 0)
				local ky = (keys.Down and 1 or 0) - (keys.Up and 1 or 0)
				local vx = session.StickVel.X + kx
				local vy = session.StickVel.Y + ky
				session.NX = math.clamp(session.NX + vx * NOZZLE_SPEED * dt, 0, 1)
				session.NY = math.clamp(session.NY + vy * NOZZLE_SPEED * dt, 0, 1)
			end
			session.Nozzle.Position = UDim2.fromScale(session.NX, session.NY)

			--// suck any dust the nozzle is hovering
			for _, d in ipairs(session.Dusts) do
				if not d.Sucked then
					local dx, dy = d.X - session.NX, d.Y - session.NY
					if (dx * dx + dy * dy) <= SUCK_RADIUS * SUCK_RADIUS then
						d.Sucked = true
						session.Sucked += 1
						vacuumRemote:FireServer("Suck", session.Token)
						session.Progress.Text =
							("%d%%"):format(math.floor(session.Sucked / session.Total * 100))
						local frame = d.Frame
						local t = TweenService:Create(frame,
							TweenInfo.new(0.18, Enum.EasingStyle.Quad),
							{ Size = UDim2.fromScale(0, 0), BackgroundTransparency = 1 })
						t:Play()
						t.Completed:Connect(function()
							if frame then frame:Destroy() end
						end)
					end
				end
			end
		end)

	elseif action == "Progress" then
		if session and session.Token == a and session.Progress then
			session.Progress.Text = ("%d%%"):format(math.floor((b or 0) * 100))
		end

	elseif action == "Close" then
		if session and session.Token == a then
			if b and session.Progress then
				session.Progress.Text = "SPOTLESS! ✨"
				session.Progress.TextColor3 = BASIL
				if session.Render then session.Render:Disconnect() session.Render = nil end
				task.delay(0.5, teardown)
			else
				teardown()
			end
		end
	end
end)
