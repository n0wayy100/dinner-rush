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

--// THE BANNER TOQUE (Chef only, Config.ChefHatOnBanner): a parts-built
--// chef hat welded to the clone's head - sized off the head itself so
--// R6 and R15 both wear it right. Hat ACCESSORIES come off first (one
--// hat at a time); hair and face accessories stay. The welds run
--// through the same manual solver as everything else, so the toque
--// rides the pose and the cooking swing.
local TOQUE_WHITE = Color3.fromRGB(250, 248, 242)
local TOQUE_BAND = Color3.fromRGB(240, 234, 222)

local function addChefHat(clone)
	local head = clone:FindFirstChild("Head")
	if not head then return end

	for _, acc in ipairs(clone:GetChildren()) do
		if acc:IsA("Accessory") then
			local handle = acc:FindFirstChild("Handle")
			if handle and handle:FindFirstChild("HatAttachment") then
				acc:Destroy() --// the crown yields to the kitchen
			end
		end
	end

	local w = math.max(head.Size.X, 1)
	local top = head.Size.Y / 2

	local function piece(size, color, c0)
		local p = Instance.new("Part")
		p.Size = size
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		local weld = Instance.new("Weld")
		weld.Part0 = head
		weld.Part1 = p
		weld.C0 = c0
		weld.Parent = p
		p.Parent = head
		return p
	end

	--// the band (an upright cylinder: cylinders lie along X, so roll 90)
	local band = piece(
		Vector3.new(w * 0.38, w * 0.95, w * 0.95), TOQUE_BAND,
		CFrame.new(0, top + w * 0.16, 0) * CFrame.Angles(0, 0, math.rad(90)))
	band.Shape = Enum.PartType.Cylinder

	--// the puff: one big squashed ball + two lumps, pure cartoon
	local puffY = top + w * 0.34 + w * 0.28
	local puff = piece(Vector3.new(w * 1.15, w * 0.62, w * 1.15), TOQUE_WHITE,
		CFrame.new(0, puffY, 0))
	puff.Shape = Enum.PartType.Ball
	local lumpA = piece(Vector3.new(w * 0.55, w * 0.45, w * 0.55), TOQUE_WHITE,
		CFrame.new(w * 0.32, puffY + w * 0.14, 0.08 * w))
	lumpA.Shape = Enum.PartType.Ball
	local lumpB = piece(Vector3.new(w * 0.5, w * 0.42, w * 0.5), TOQUE_WHITE,
		CFrame.new(-w * 0.3, puffY + w * 0.16, -0.06 * w))
	lumpB.Shape = Enum.PartType.Ball
end

--// R6 TRANSLATION: poses are authored in R15 joint names (most
--// players). An R6 avatar maps shoulders across (R6 spells them with
--// spaces), leans via RootJoint instead of Waist, and folds elbow
--// angles into the shoulder - R6 arms are one piece. Same pose, same
--// swing, either rig. (R6 joint AXES differ, so R6 may want its own
--// tuning pass once seen - expected, not a bug.)
local R6_MAP = {
	Waist = "RootJoint",
	Neck = "Neck",
	RightShoulder = "Right Shoulder",
	LeftShoulder = "Left Shoulder",
	RightElbow = "Right Shoulder",
	LeftElbow = "Left Shoulder",
}

local function translatePose(pose, isR6)
	if not pose or not isR6 then return pose end
	local out = {}
	for name, deg in pairs(pose) do
		local target = R6_MAP[name] or name
		local acc = out[target]
		if acc then --// elbow folding: angles sum into the shoulder
			out[target] = { acc[1] + deg[1], acc[2] + deg[2], acc[3] + deg[3] }
		else
			out[target] = { deg[1], deg[2], deg[3] }
		end
	end
	return out
end

--// Gathers the posed joints ONCE per fresh clone, remembering each
--// motor's REST C0 - poses are always applied as rest * angles, so
--// re-applying (the motion loop does, every frame) never compounds.
--// Returns { {Motor, Base, A = degrees, B = degrees|nil}, ... }.
--// Motor lookup that forgives naming dialects: exact name first, then
--// the spaced spelling ("RightShoulder" -> "Right Shoulder") - some
--// bundles mix conventions on one rig.
local function findMotor(clone, name)
	local m = clone:FindFirstChild(name, true)
	if m and m:IsA("Motor6D") then return m end
	local spaced = name:gsub("(%l)(%u)", "%1 %2")
	if spaced ~= name then
		m = clone:FindFirstChild(spaced, true)
		if m and m:IsA("Motor6D") then return m end
	end
	return nil
end

local dumpedMotors = false

local function collectPose(clone, poseA, poseB)
	local joints = {}
	if not poseA then return joints end
	for jointName, deg in pairs(poseA) do
		local motor = findMotor(clone, jointName)
		if motor then
			table.insert(joints, {
				Motor = motor,
				Base = motor.C0,
				A = deg,
				B = poseB and poseB[jointName] or nil,
			})
		elseif not warnedJoints[jointName] then
			warnedJoints[jointName] = true
			warn("[CastBanner] pose joint not found: " .. jointName)
			--// GROUND TRUTH, once: what this rig actually calls its motors
			if not dumpedMotors then
				dumpedMotors = true
				local names = {}
				for _, d in ipairs(clone:GetDescendants()) do
					if d:IsA("Motor6D") then table.insert(names, d.Name) end
				end
				warn("[CastBanner] this rig's motors: " .. table.concat(names, ", "))
			end
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

	--// FULL-BLEED portrait (owner ruling, Sep 2026): the avatar fills
	--// the whole panel - no circle window, no rarity burst, no ultimate
	--// text, no badge. The avatar IS the banner.
	local portrait = Instance.new("ViewportFrame")
	portrait.Name = "Portrait"
	portrait.Active = false
	portrait.AnchorPoint = Vector2.new(0.5, 0.5)
	portrait.Size = UDim2.fromScale(1, 1)
	portrait.Position = UDim2.fromScale(0.5, 0.5)
	portrait.BackgroundTransparency = 1
	--// Unlit viewports render avatars dark and muddy
	portrait.Ambient = Color3.fromRGB(200, 200, 200)
	portrait.LightColor = Color3.fromRGB(255, 250, 240)
	portrait.LightDirection = Vector3.new(-0.4, -1, -0.6)
	portrait.Parent = panel
	--// Corner radius MATCHES the panel so the viewport's corners don't
	--// punch through the rounded frame (map-picker lesson)
	local portraitCorner = Instance.new("UICorner")
	portraitCorner.CornerRadius = UDim.new(0.08, 0)
	portraitCorner.Parent = portrait

	--// Fill the portrait: clone -> pose -> manual solve -> camera
	local usedViewport = false
	local character = caster.Character
	if character and character:FindFirstChild("Head") then
		local okClone, clone = pcall(cloneForPortrait, character)
		if okClone and clone then
			if classKey == "Chef" and CFG.ChefHatOnBanner ~= false then
				pcall(addChefHat, clone)
			end
			local cloneHumanoid = clone:FindFirstChildOfClass("Humanoid")
			local isR6 = cloneHumanoid ~= nil
				and cloneHumanoid.RigType == Enum.HumanoidRigType.R6
			--// Posing is PARKED (Config.PosesEnabled) - natural stance +
			--// camera push. When re-enabled: R6 hand-tuned tables beat
			--// axis-translated R15 numbers whenever one exists.
			local poseA, poseB
			if CFG.PosesEnabled ~= false then
				if isR6 and CFG.PosesR6 and CFG.PosesR6[classKey] then
					poseA = CFG.PosesR6[classKey]
					poseB = CFG.MotionR6 and CFG.MotionR6[classKey]
				else
					poseA = translatePose(CFG.Poses and CFG.Poses[classKey], isR6)
					poseB = translatePose(CFG.Motion and CFG.Motion[classKey], isR6)
				end
			end
			local joints = collectPose(clone, poseA, poseB)
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
				print(("[CastBanner] motion running (%d joints, %s rig)")
					:format(#joints, isR6 and "R6" or "R15"))
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

				local focus = head.Position
					- Vector3.new(0, CFG.FocusBelowHeadStuds or 0.7, 0)
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

	--// Just the caster's name, small, bottom-left over the portrait
	local casterLabel = Instance.new("TextLabel")
	casterLabel.Active = false
	casterLabel.AnchorPoint = Vector2.new(0, 1)
	casterLabel.Size = UDim2.fromScale(0.6, 0.12)
	casterLabel.Position = UDim2.fromScale(0.05, 0.95)
	casterLabel.BackgroundTransparency = 1
	casterLabel.Font = Enum.Font.FredokaOne
	casterLabel.TextScaled = true
	casterLabel.Text = caster.DisplayName
	casterLabel.TextColor3 = CHOC
	casterLabel.TextStrokeColor3 = CREAM
	casterLabel.TextStrokeTransparency = 0.2
	casterLabel.TextXAlignment = Enum.TextXAlignment.Left
	casterLabel.Parent = panel

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
