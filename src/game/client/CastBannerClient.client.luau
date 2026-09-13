--[[
	Dinner Rush - CastBannerClient
	StarterPlayer.StarterPlayerScripts.Client.CastBannerClient  (LocalScript)

	THE ULTIMATE CAST BANNER (Config.Ultimates.CastBanner). On a
	server-confirmed cast ("Cast" on UltimateRemote - fired ONLY after the
	ability succeeded), the CASTER gets a banner sliding in from the left:
	their own avatar in a ViewportFrame, posed per class, slow camera
	push-in, the ultimate's name and class badge. Everyone else gets a
	small toast.

	HARD RULES (see the handoff doc + project constitution):
	- Render-only. Never keyed off the keypress; charge/ability untouched.
	- NOTHING here is interactive: Active=false everywhere, no buttons.
	  A GUI stealing the mouse mid-shift-lock is a shipped-bug repeat.
	- No animation TRACKS on the viewport rig - Roblox viewports don't
	  play them. Poses (six upper-body Motor6Ds) are applied as
	  rest-C0 * angles and the rig is solved MANUALLY (part CFrames),
	  which renders in a plain ViewportFrame regardless of engine joint
	  handling. A class with a Config Motion pose SWINGS between its two
	  poses per-frame through that same solver (owner request, Sep 2026)
	  - procedural, viewport-only, never the live character.
	- Clones only: Archivable flipped and restored, scripts stripped
	  (a cloned Animate would fight the pose every frame).
	- Degrade, don't break: no character / failed clone = banner with an
	  enlarged class badge instead of the portrait, one warn.
	- OWNER RULING SCOPE: static UI-viewport posing is allowed; live
	  in-world character animation stays hired-out animator work.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CFG = Config.Ultimates and Config.Ultimates.CastBanner
if not CFG or CFG.Enabled == false then return end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local ultimateRemote = remotes:WaitForChild("UltimateRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)

local warnedJoints = {} --// warn once per missing joint name, not per cast

----------------------------------------------------------------
-- The avatar clone (client-side; teammates' characters replicate too)
----------------------------------------------------------------
local function cloneForPortrait(character)
	--// Characters are Archivable=false by default and Clone() on a
	--// non-archivable instance returns nil. Flip, clone, flip back.
	local was = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = was
	if not clone then return nil end

	--// STRIP THE SCRIPTS - not optional. A cloned Animate LocalScript
	--// RUNS under PlayerGui and fights the pose every frame. Tools would
	--// ruin the pose; billboards/prompts don't belong in a portrait.
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("LuaSourceContainer")
			or d:IsA("Animator")
			or d:IsA("Tool")
			or d:IsA("Sound")
			or d:IsA("ProximityPrompt")
			or d:IsA("LayerCollector") then
			d:Destroy()
		end
	end

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
		end
	end
	local root = clone:FindFirstChild("HumanoidRootPart")
	if root then root.Anchored = true end

	clone:PivotTo(CFrame.new()) --// origin, facing -Z: framing is predictable
	return clone
end

--// Gathers the posed joints ONCE per fresh clone, remembering each
--// motor's REST C0 - poses are always applied as rest * angles, so
--// re-applying (the motion loop does, every frame) never compounds.
--// Returns { {Motor, Base, A = degrees, B = degrees|nil}, ... }.
local function collectPose(clone, poseA, poseB)
	local joints = {}
	if not poseA then return joints end
	for jointName, deg in pairs(poseA) do
		local motor = clone:FindFirstChild(jointName, true)
		if motor and motor:IsA("Motor6D") then
			table.insert(joints, {
				Motor = motor,
				Base = motor.C0,
				A = deg,
				B = poseB and poseB[jointName] or nil,
			})
		elseif not warnedJoints[jointName] then
			warnedJoints[jointName] = true
			warn("[CastBanner] pose joint not found (R6 avatar?): " .. jointName)
		end
	end
	return joints
end

--// alpha 0 = pose A, alpha 1 = pose B (joints with no B hold pose A)
local function setPose(joints, alpha)
	for _, joint in ipairs(joints) do
		local a, b = joint.A, joint.B or joint.A
		joint.Motor.C0 = joint.Base * CFrame.Angles(
			math.rad(a[1] + (b[1] - a[1]) * alpha),
			math.rad(a[2] + (b[2] - a[2]) * alpha),
			math.rad(a[3] + (b[3] - a[3]) * alpha))
	end
end

--// MANUAL joint solve: viewports don't reliably run Motor6Ds, so place
--// every part ourselves. part1 = part0 * C0 * Transform * C1^-1 is
--// exactly what the engine does. Walk outward from the root so every
--// Part0 is placed before its Part1.
local function solveRig(clone)
	local root = clone:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local placed = { [root] = true }
	local motors = {}
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Motor6D") then table.insert(motors, d) end
	end
	local progress = true
	while progress do
		progress = false
		for _, m in ipairs(motors) do
			if m.Part0 and m.Part1 and placed[m.Part0] and not placed[m.Part1] then
				m.Part1.CFrame = m.Part0.CFrame * m.C0 * m.Transform * m.C1:Inverse()
				placed[m.Part1] = true
				progress = true
			end
		end
	end

	--// Accessories hang on Welds, not motors - reposition their handles
	--// the same way so hats follow the posed head
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Weld") and d.Part0 and d.Part1 and placed[d.Part0] then
			d.Part1.CFrame = d.Part0.CFrame * d.C0 * d.C1:Inverse()
		end
	end

	--// Solved = static portrait; anchor everything so nothing drifts
	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
end

----------------------------------------------------------------
-- The banner
----------------------------------------------------------------
local currentBanner = nil --// only one on screen; a new cast snaps it out

local function destroyBanner()
	if currentBanner then
		currentBanner:Destroy()
		currentBanner = nil
	end
end

local function showBanner(caster, classKey)
	local class = Config.Classes and Config.Classes[classKey]
	if not class or not class.UltimateName or class.UltimateName == "" then
		return
	end

	destroyBanner()

	local gui = Instance.new("ScreenGui")
	gui.Name = "CastBanner_UI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 70 --// above the HUD, below the shift report (60? report holds 60 - banner is transient, keep it on top)
	gui.Parent = playerGui
	currentBanner = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Active = false
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Size = UDim2.fromScale(CFG.WidthScale, CFG.HeightScale)
	panel.Position = UDim2.new(-CFG.WidthScale - 0.05, 0, 0.5, 0) --// off-screen left
	panel.BackgroundColor3 = CREAM
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
	gradient.Parent = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.08, 0)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = CHOC
	stroke.Parent = panel

	--// The rarity burst behind the portrait
	local burst = Instance.new("Frame")
	burst.Active = false
	burst.AnchorPoint = Vector2.new(0.5, 0.5)
	burst.Size = UDim2.fromScale(0.46, 0.92)
	burst.Position = UDim2.fromScale(0.26, 0.5)
	burst.BackgroundColor3 = class.RarityColor or CREAM_DEEP
	burst.BackgroundTransparency = 0.45
	burst.BorderSizePixel = 0
	burst.Parent = panel
	local burstCorner = Instance.new("UICorner")
	burstCorner.CornerRadius = UDim.new(0.5, 0)
	burstCorner.Parent = burst

	--// Portrait window (viewport OR enlarged badge fallback)
	local portrait = Instance.new("ViewportFrame")
	portrait.Name = "Portrait"
	portrait.Active = false
	portrait.AnchorPoint = Vector2.new(0.5, 0.5)
	portrait.Size = UDim2.fromScale(0.44, 0.88)
	portrait.Position = UDim2.fromScale(0.26, 0.5)
	portrait.BackgroundTransparency = 1
	--// Unlit viewports render avatars dark and muddy
	portrait.Ambient = Color3.fromRGB(200, 200, 200)
	portrait.LightColor = Color3.fromRGB(255, 250, 240)
	portrait.LightDirection = Vector3.new(-0.4, -1, -0.6)
	portrait.Parent = panel
	--// ClipsDescendants clips RECTANGULAR and ignores UICorner - round
	--// the image itself (map-picker lesson)
	local portraitCorner = Instance.new("UICorner")
	portraitCorner.CornerRadius = UDim.new(0.5, 0)
	portraitCorner.Parent = portrait

	--// Fill the portrait: clone -> pose -> manual solve -> camera
	local usedViewport = false
	local character = caster.Character
	if character and character:FindFirstChild("Head") then
		local okClone, clone = pcall(cloneForPortrait, character)
		if okClone and clone then
			local joints = collectPose(clone,
				CFG.Poses and CFG.Poses[classKey],
				CFG.Motion and CFG.Motion[classKey])
			setPose(joints, 0)
			pcall(solveRig, clone)
			clone.Parent = portrait

			--// BANNER MOTION: classes with a Motion pose swing between
			--// their two poses for the hold - joints lerped, rig
			--// re-solved per frame. Viewport-only; stops with the gui.
			local hasMotion = false
			for _, joint in ipairs(joints) do
				if joint.B then hasMotion = true break end
			end
			if hasMotion then
				local RunService = game:GetService("RunService")
				local swings = CFG.MotionSwingsPerHold or 2
				local elapsed = 0
				local conn
				conn = RunService.RenderStepped:Connect(function(dt)
					if not gui.Parent then
						conn:Disconnect()
						return
					end
					elapsed += dt
					local alpha = 0.5 - 0.5 * math.cos(
						elapsed * math.pi * 2 * swings / math.max(CFG.HoldSeconds, 0.1))
					setPose(joints, alpha)
					pcall(solveRig, clone)
				end)
			end

			local head = clone:FindFirstChild("Head")
			if head then
				local camera = Instance.new("Camera")
				camera.FieldOfView = CFG.FieldOfView
				camera.Parent = portrait
				portrait.CurrentCamera = camera

				local focus = head.Position - Vector3.new(0, 0.7, 0)
				local function camAt(dist)
					local offset = CFrame.Angles(0, math.rad(CFG.CameraOrbitDegrees), 0)
						* Vector3.new(0, 0.15, -dist) --// in front: the rig faces -Z
					return CFrame.lookAt(focus + offset, focus)
				end
				camera.CFrame = camAt(CFG.CameraDistance + CFG.CameraPushStuds)
				TweenService:Create(camera,
					TweenInfo.new(CFG.HoldSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
					{ CFrame = camAt(CFG.CameraDistance) }):Play()
				usedViewport = true
			end
		end
	end
	if not usedViewport then
		--// Degrade, don't break: class badge fills the window instead
		warn("[CastBanner] no portrait for " .. caster.Name .. " - showing badge")
		local badge = Instance.new("ImageLabel")
		badge.Active = false
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Size = UDim2.fromScale(0.8, 0.8)
		badge.Position = UDim2.fromScale(0.5, 0.5)
		badge.BackgroundTransparency = 1
		badge.Image = class.IconId or ""
		badge.Parent = portrait
	end

	--// Right column: ultimate name, caster, badge
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Active = false
	nameLabel.Size = UDim2.fromScale(0.46, 0.34)
	nameLabel.Position = UDim2.fromScale(0.5, 0.14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.TextScaled = true
	nameLabel.Text = class.UltimateName
	nameLabel.TextColor3 = CHOC
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = panel
	local nameStroke = Instance.new("UIStroke")
	nameStroke.Thickness = 2
	nameStroke.Color = class.RarityColor or CREAM_DEEP
	nameStroke.Parent = nameLabel

	local casterLabel = Instance.new("TextLabel")
	casterLabel.Active = false
	casterLabel.Size = UDim2.fromScale(0.46, 0.14)
	casterLabel.Position = UDim2.fromScale(0.5, 0.5)
	casterLabel.BackgroundTransparency = 1
	casterLabel.Font = Enum.Font.FredokaOne
	casterLabel.TextScaled = true
	casterLabel.Text = caster.DisplayName
	casterLabel.TextColor3 = CHOC
	casterLabel.TextTransparency = 0.25
	casterLabel.TextXAlignment = Enum.TextXAlignment.Left
	casterLabel.Parent = panel

	local badge = Instance.new("ImageLabel")
	badge.Active = false
	badge.Size = UDim2.fromScale(0.16, 0.28)
	badge.SizeConstraint = Enum.SizeConstraint.RelativeYY
	badge.Position = UDim2.fromScale(0.5, 0.66)
	badge.BackgroundColor3 = CREAM_DEEP
	badge.Image = class.IconId or ""
	badge.Parent = panel
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0.5, 0)
	badgeCorner.Parent = badge
	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Thickness = 2
	badgeStroke.Color = CHOC
	badgeStroke.Parent = badge

	--// Slide in (overshoot snap), hold, slide out, gone
	local restPos = UDim2.new(0.015, 0, 0.5, 0)
	TweenService:Create(panel,
		TweenInfo.new(CFG.SlideInSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = restPos }):Play()

	task.delay(CFG.SlideInSeconds + CFG.HoldSeconds, function()
		if currentBanner ~= gui then return end --// a newer cast took over
		local out = TweenService:Create(panel,
			TweenInfo.new(CFG.SlideOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(-CFG.WidthScale - 0.05, 0, 0.5, 0) })
		out.Completed:Once(function()
			if currentBanner == gui then
				destroyBanner()
			end
		end)
		out:Play()
	end)
end

----------------------------------------------------------------
-- The teammate toast
----------------------------------------------------------------
local currentToast = nil

local function showToast(caster, classKey)
	local class = Config.Classes and Config.Classes[classKey]
	if not class or not class.UltimateName or class.UltimateName == "" then
		return
	end

	if currentToast then
		currentToast:Destroy()
		currentToast = nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CastToast_UI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40
	gui.Parent = playerGui
	currentToast = gui

	local pill = Instance.new("TextLabel")
	pill.Active = false
	pill.AnchorPoint = Vector2.new(0.5, 0)
	pill.Size = UDim2.fromScale(0.3, 0.045)
	pill.Position = UDim2.fromScale(0.5, -0.08) --// slides down into view
	pill.BackgroundColor3 = CREAM
	pill.Font = Enum.Font.FredokaOne
	pill.TextScaled = true
	pill.Text = caster.DisplayName .. " used " .. class.UltimateName
	pill.TextColor3 = CHOC
	pill.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = class.RarityColor or CHOC
	stroke.Parent = pill

	TweenService:Create(pill,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 0.08) }):Play()
	task.delay(CFG.ToastSeconds, function()
		if currentToast ~= gui then return end
		local out = TweenService:Create(pill,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.fromScale(0.5, -0.08), TextTransparency = 1 })
		out.Completed:Once(function()
			if currentToast == gui then
				gui:Destroy()
				currentToast = nil
			end
		end)
		out:Play()
	end)
end

----------------------------------------------------------------
-- One source of truth: the server's "Cast" broadcast
----------------------------------------------------------------
ultimateRemote.OnClientEvent:Connect(function(action, caster, classKey)
	if action ~= "Cast" then return end
	if typeof(caster) ~= "Instance" or not caster:IsA("Player") then return end

	local ok, err = pcall(function()
		if caster == player then
			showBanner(caster, classKey)
		else
			showToast(caster, classKey)
		end
	end)
	if not ok then
		warn("[CastBanner] render failed (cosmetic, ignored): " .. tostring(err))
	end
end)
