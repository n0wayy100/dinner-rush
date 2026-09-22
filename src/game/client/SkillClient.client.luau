--[[
	Dinner Rush - SkillClient
	StarterPlayer.StarterPlayerScripts.Client.SkillClient  (LocalScript)

	The two CLASS SKILL buttons (Q + R), bottom-centre. Each shows the
	class's skill for that slot with a cooldown sweep. Render + intent only:
	the SERVER (SkillService) runs and gates every skill.

	  keys      Q / R           touch: tap the button
	  gamepad   B (Q) / DPadUp (R)

	Rebuilds whenever the player's ClassKey changes (class applies late).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SKILLS = Config.Skills
if not (SKILLS and SKILLS.Enabled) then
	return
end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local skillRemote = remotes:WaitForChild("SkillRemote")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local WHITE = Color3.fromRGB(255, 255, 255)

local gui = Instance.new("ScreenGui")
gui.Name = "Skills_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 18
gui.Parent = playerGui

local BUTTON_PX = 84 --// bigger than before

local row = Instance.new("Frame")
row.AnchorPoint = Vector2.new(0, 1)
row.Size = UDim2.fromOffset(BUTTON_PX, BUTTON_PX * 2 + 12)
row.BackgroundTransparency = 1
row.Visible = false
row.Parent = gui
local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Vertical --// stacked column
rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
rowLayout.Padding = UDim.new(0, 12)
rowLayout.Parent = row

--// Sit the column just ABOVE the ultimate circle (bottom-left), matching
--// how ChargeClient places the ult on touch vs desktop.
local function applyLayout()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	row.Position = touchOnly and UDim2.fromScale(0.02, 0.52)
		or UDim2.fromScale(0.03, 0.79)
end
applyLayout()
UserInputService.LastInputTypeChanged:Connect(applyLayout)

--// slot -> widget { Button, Cover, Count, Def, ReadyAt }
local widgets = {}

local function classSkill(slot)
	local classKey = player:GetAttribute("ClassKey") or ""
	local class = classKey ~= "" and Config.Classes[classKey] or nil
	if not class then return nil end
	return class[slot == "Q" and "SkillQ" or "SkillR"]
end

local function useSlot(slot)
	local w = widgets[slot]
	if not w then return end
	if os.clock() < (w.ReadyAt or 0) then return end --// cooling; ignore
	--// send where the CAMERA is aimed, so aim-based skills (Plate Juggler)
	--// throw toward it. Harmless for skills that ignore it.
	local cam = workspace.CurrentCamera
	local aim = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
	skillRemote:FireServer("Use", slot, aim)
end

----------------------------------------------------------------
-- PLATE JUGGLER: the drag-back SLINGSHOT aim (skills with HoldAim).
-- Press starts the aim, dragging pulls the slingshot (length = power,
-- downward = steeper arc, sideways = yaw), a dotted trajectory previews
-- it, and release flings the plate. All client-side render + intent; the
-- server flies the real projectile from the launch velocity we send.
----------------------------------------------------------------
local aiming = false
local startPointer = Vector2.new()
local pointer = Vector2.new()
local lastVel = nil
local renderConn = nil
local dots = {}

local function isHoldAim(slot)
	local def = classSkill(slot)
	return def ~= nil and def.HoldAim == true
end

local LINE_SEGMENTS = 26
local function ensureDots()
	if #dots > 0 then return end
	for i = 1, LINE_SEGMENTS do
		local d = Instance.new("Part")
		d.Name = "AimLine"
		d.Size = Vector3.new(0.28, 0.28, 1) --// length set per frame (the Z span)
		d.Color = Color3.fromRGB(245, 184, 65) --// mustard, easy to read
		d.Material = Enum.Material.Neon
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.Transparency = 1
		d.Parent = workspace
		dots[i] = d
	end
end

local function hideDots()
	for _, d in ipairs(dots) do d.Transparency = 1 end
end

--// launch velocity from the drag: length = power, downward = steep pitch,
--// sideways = yaw. You launch OPPOSITE the pull, forward from the camera.
local function computeVelocity()
	local def = classSkill("R")
	if not def then return nil end
	local drag = pointer - startPointer
	if drag.Magnitude < 5 then return nil end
	local maxDrag = def.MaxDragPixels or 240
	local strength = math.clamp(drag.Magnitude / maxDrag, 0, 1)
	local power = (def.MinPower or 55) + ((def.MaxPower or 150) - (def.MinPower or 55)) * strength
	local pitchT = math.clamp(drag.Y / maxDrag, 0, 1) --// dragging DOWN = steeper
	local pitch = math.rad((def.MinPitchDeg or 18)
		+ ((def.MaxPitchDeg or 68) - (def.MinPitchDeg or 18)) * pitchT)
	local yaw = math.rad(-math.clamp(drag.X / maxDrag, -1, 1) * (def.MaxYawDeg or 55))

	local cam = workspace.CurrentCamera
	local look = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = fwd.Magnitude > 0.01 and fwd.Unit or Vector3.new(0, 0, -1)
	fwd = (CFrame.Angles(0, yaw, 0) * fwd)
	local dir = (fwd * math.cos(pitch) + Vector3.new(0, 1, 0) * math.sin(pitch)).Unit
	return dir * power
end

local function updateAim()
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local vel = computeVelocity()
	if not root or not vel then
		lastVel = nil
		hideDots()
		return
	end
	lastVel = vel
	local from = root.Position + Vector3.new(0, 2.5, 0)
	local g = -workspace.Gravity
	local floorY = root.Position.Y - 3 --// stop the line at about ground level
	local step = 0.05
	local prev = from
	local stopped = false
	for i, seg in ipairs(dots) do
		if stopped then
			seg.Transparency = 1
		else
			local t = i * step
			local pt = from + vel * t + Vector3.new(0, 0.5 * g * t * t, 0)
			local len = (pt - prev).Magnitude
			if len > 0.01 then
				seg.Size = Vector3.new(0.28, 0.28, len)
				seg.CFrame = CFrame.lookAt((prev + pt) / 2, pt) --// spans prev -> pt
				seg.Transparency = 0.1
			else
				seg.Transparency = 1
			end
			prev = pt
			if pt.Y <= floorY then stopped = true end --// hide the rest past the floor
		end
	end
end

local function beginAim()
	if aiming then return end
	local w = widgets.R
	if not w or os.clock() < (w.ReadyAt or 0) then return end
	if not isHoldAim("R") then return end
	aiming = true
	startPointer = pointer
	lastVel = nil
	ensureDots()
	renderConn = RunService.RenderStepped:Connect(updateAim)
end

local function endAim()
	if not aiming then return end
	aiming = false
	if renderConn then renderConn:Disconnect(); renderConn = nil end
	hideDots()
	if lastVel then
		skillRemote:FireServer("Use", "R", lastVel)
	end
	lastVel = nil
end

--// keep the pointer current (mouse OR the active touch), and release on lift
UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
		pointer = Vector2.new(input.Position.X, input.Position.Y)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if aiming and (input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch) then
		endAim()
	end
end)

local function hasIcon(id)
	return type(id) == "string" and id ~= "" and not id:match("//0$")
end

local function makeButton(slot, def, order)
	local button = Instance.new("TextButton")
	button.Name = "Skill" .. slot
	button.LayoutOrder = order
	button.Size = UDim2.fromOffset(BUTTON_PX, BUTTON_PX)
	button.BackgroundColor3 = CREAM
	button.AutoButtonColor = false
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	--// the uploaded art when it exists, the emoji until then
	button.Text = hasIcon(def.IconId) and "" or (def.Emoji or "?")
	button.TextColor3 = CHOC
	button.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.28, 0)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CHOC
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 30
	cap.Parent = button

	if hasIcon(def.IconId) then
		local icon = Instance.new("ImageLabel")
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.78, 0.78)
		icon.BackgroundTransparency = 1
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = def.IconId
		icon.Parent = button
	end

	--// key hint bottom-right
	local key = Instance.new("TextLabel")
	key.AnchorPoint = Vector2.new(1, 1)
	key.Position = UDim2.fromScale(0.98, 0.98)
	key.Size = UDim2.fromScale(0.42, 0.34)
	key.BackgroundColor3 = CHOC
	key.Font = Enum.Font.FredokaOne
	key.TextScaled = true
	key.Text = slot
	key.TextColor3 = WHITE
	key.ZIndex = 3
	key.Parent = button
	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(0.3, 0)
	keyCorner.Parent = key

	--// cooldown cover (drains top-down) + countdown number
	local cover = Instance.new("Frame")
	cover.AnchorPoint = Vector2.new(0.5, 0)
	cover.Position = UDim2.fromScale(0.5, 0)
	cover.Size = UDim2.fromScale(1, 0)
	cover.BackgroundColor3 = Color3.new(0, 0, 0)
	cover.BackgroundTransparency = 0.5
	cover.ZIndex = 2
	cover.Visible = false
	cover.Parent = button
	local coverCorner = Instance.new("UICorner")
	coverCorner.CornerRadius = UDim.new(0.28, 0)
	coverCorner.Parent = cover

	local count = Instance.new("TextLabel")
	count.Size = UDim2.fromScale(1, 1)
	count.BackgroundTransparency = 1
	count.Font = Enum.Font.FredokaOne
	count.TextScaled = true
	count.Text = ""
	count.TextColor3 = WHITE
	count.TextStrokeColor3 = CHOC
	count.TextStrokeTransparency = 0
	count.ZIndex = 3
	count.Visible = false
	count.Parent = button
	local countCap = Instance.new("UITextSizeConstraint")
	countCap.MaxTextSize = 26
	countCap.Parent = count

	--// A tap fires normal skills; a HoldAim skill (Plate Juggler) starts the
	--// drag-aim on press - the GLOBAL release (InputEnded) flings it, so a
	--// drag off the button never cuts the aim short.
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			pointer = Vector2.new(input.Position.X, input.Position.Y)
			if isHoldAim(slot) then beginAim() end
		end
	end)
	button.InputEnded:Connect(function(input)
		if (input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1)
			and not isHoldAim(slot) then
			useSlot(slot)
		end
	end)

	return { Button = button, Cover = cover, Count = count, Def = def, ReadyAt = 0 }
end

local function rebuild()
	for _, w in pairs(widgets) do
		w.Button:Destroy()
	end
	widgets = {}

	local q = classSkill("Q")
	local r = classSkill("R")
	if q then widgets.Q = makeButton("Q", q, 1) end
	if r then widgets.R = makeButton("R", r, 2) end
	row.Visible = (q ~= nil) or (r ~= nil)
end

--// cooldown ticker: drains each cover, updates the number
RunService.RenderStepped:Connect(function()
	local now = os.clock()
	for _, w in pairs(widgets) do
		local left = (w.ReadyAt or 0) - now
		if left > 0 then
			local total = (w.Def.CooldownSeconds or 20)
			w.Cover.Visible = true
			w.Count.Visible = true
			w.Cover.Size = UDim2.fromScale(1, math.clamp(left / total, 0, 1))
			w.Count.Text = string.format("%.1f", left) --// 1 decimal, ticking down
		elseif w.Cover.Visible then
			w.Cover.Visible = false
			w.Count.Visible = false
		end
	end
end)

--// WAITER DASH: a short forward burst. Movement is client-side (the sprint
--// exception), so the server just says "go" and we apply it here.
local function performDash(speed, seconds)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local look = root.CFrame.LookVector
	local dir = Vector3.new(look.X, 0, look.Z)
	if dir.Magnitude < 0.05 then return end
	dir = dir.Unit

	local att = Instance.new("Attachment")
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = dir * (speed or 85)
	lv.Parent = root

	--// a quick motion trail off the torso for feel
	local trail = Instance.new("Trail")
	local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(-1, 0, 0); a0.Parent = root
	local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(1, 0, 0); a1.Parent = root
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.25
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	trail.Transparency = NumberSequence.new(0.3, 1)
	trail.Parent = root

	task.delay(seconds or 0.28, function()
		lv:Destroy(); att:Destroy()
	end)
	task.delay((seconds or 0.28) + 0.3, function()
		trail:Destroy(); a0:Destroy(); a1:Destroy()
	end)
end

skillRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "Dash" then
		performDash(a, b) --// a = speed, b = seconds
		return
	end
	local slot = a
	local w = widgets[slot]
	if not w then return end
	if action == "Cooldown" then
		w.ReadyAt = os.clock() + (b or w.Def.CooldownSeconds or 20)
	elseif action == "Denied" then
		--// red flash + the reason briefly on the button
		local btn = w.Button
		btn.BackgroundColor3 = TOMATO
		local old = w.Button.Text
		w.Button.Text = "✕"
		task.delay(0.6, function()
			if btn.Parent then
				btn.BackgroundColor3 = CREAM
				btn.Text = old
			end
		end)
	end
end)

--// keys + gamepad
ContextActionService:BindAction("SkillQ", function(_, s)
	if s == Enum.UserInputState.Begin then useSlot("Q") end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)

ContextActionService:BindAction("SkillR", function(_, s)
	if s == Enum.UserInputState.Begin then
		--// hold-aim (Plate Juggler): R-down starts the drag-aim, R-up flings it
		if isHoldAim("R") then beginAim() else useSlot("R") end
	elseif s == Enum.UserInputState.End then
		if aiming then endAim() end
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.R, Enum.KeyCode.DPadUp)

player:GetAttributeChangedSignal("ClassKey"):Connect(rebuild)
rebuild()
