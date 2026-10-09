--[[
	Dinner Rush - MvpCutscene
	StarterPlayer.StarterPlayerScripts.Client.MvpCutscene  (ModuleScript)

	THE MVP CUTSCENE (owner design, Oct 2026). When the shift ends the screen
	fades to black, and the MVP celebrates on the map's MvpSpot - filmed by a
	camera animated in Blender - before the awards ceremony and the report.

	HOW THE CAMERA WORKS. Every MVP animation carries one extra bone,
	CameraBone, parented to HumanoidRootPart and animated like a film camera.
	This builds a matching invisible CameraBone part on the stage rig, and
	every frame puts the player's camera where that part is. A different
	animation brings its own camera move with it - nothing else to set up.
	Config.MvpCutscene.CameraMode picks how the part is read:
	  "Aim"   position from the bone, always looking at the MVP's chest.
	          Can never point the wrong way. (What the Studio test's mode 0
	          showed.)
	  "Bone"  the bone's own rotation too, through BoneFix - needed only for
	          shots that deliberately look away from the MVP.

	Runs entirely on each client: the camera is per-player anyway, and a
	rig built locally plays with no network jitter. The SERVER picks which
	animation (payload.MvpAnim), so every screen shows the same one.

	THE ENDING (owner, Oct 2026): the animation FREEZES on its last frame and
	Run returns, so the ceremony and report pop up over the frozen shot. The
	shot holds until the server's ride home teleports everyone to the lobby.
	Studio never teleports, so there it lets go on the same clock.

	NEVER BLOCKS THE REPORT. No MVP, no MvpSpot, the MVP left, no animation
	id - Run returns at once. Anything that fails before the freeze is undone
	and Run still returns, so the ceremony and report card always follow.

	Usage (ShiftReportClient):
		MvpCutscene.Run(payload, { KeepGuis = { reportGui } })
		-- yields until the final pose, then returns with it frozen on screen
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local ProximityPromptService = game:GetService("ProximityPromptService")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local MvpCutscene = {}

local SPOT_TAG = "MvpSpot"
local RENDER_NAME = "MvpCutsceneCamera"

--// Blender and Roblox disagree about which way a camera faces. Same table,
--// same order as the Studio camera test: whichever number looked right
--// there is the BoneFix for Config ("Bone" mode only).
local BONE_FIXES = {
	CFrame.identity,
	CFrame.Angles(math.rad(-90), 0, 0),
	CFrame.Angles(math.rad(90), 0, 0),
	CFrame.Angles(0, math.pi, 0),
	CFrame.Angles(math.rad(-90), math.pi, 0),
	CFrame.Angles(math.rad(90), math.pi, 0),
}

--// What a celebrating copy must not carry over from the real character:
--// code (a cloned Animate script would fight the animation), whatever was
--// in their hands, and anything that floats over a head
local STRIP = {
	"LuaSourceContainer", "Tool", "BillboardGui", "ProximityPrompt",
	"Sound", "ForceField", "Highlight",
}

local warned = {}
local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn("[MvpCutscene] " .. message)
end

--// Volume falls fast at first and gently at the end - closer to how a
--// fade is heard than a straight line, which seems to drop off a cliff
local function fadeSound(sound, seconds)
	TweenService:Create(sound,
		TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Volume = 0 }):Play()
end

local function tween(instance, seconds, goal)
	local t = TweenService:Create(instance,
		TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), goal)
	t:Play()
	return t
end

----------------------------------------------------------------
-- FINDING THINGS
----------------------------------------------------------------

--// This map's stage mark. Only the chosen map is built, but prefer a spot
--// inside the model named after the match's map in case a test place has
--// more than one lying around.
local function findSpot()
	local mapId = workspace:GetAttribute("MatchMapId")
	local fallback = nil
	for _, spot in ipairs(CollectionService:GetTagged(SPOT_TAG)) do
		if spot:IsA("BasePart") and spot:IsDescendantOf(workspace) then
			local map = mapId and workspace:FindFirstChild(mapId, true)
			if map and spot:IsDescendantOf(map) then
				return spot
			end
			fallback = fallback or spot
		end
	end
	return fallback
end

--// A published id wins. In Studio, a KeyframeSequence with the entry's
--// Keyframes name anywhere in ReplicatedStorage works as well - the same
--// temporary-id trick as the camera test, so a new animation can be tried
--// before it is uploaded. Temporary ids do not exist on live servers.
local function resolveAnimationId(entry)
	local id = entry.AnimId
	if type(id) == "string" and id ~= "" then
		return id:match("^%d+$") and ("rbxassetid://" .. id) or id
	end
	if RunService:IsStudio() and type(entry.Keyframes) == "string" and entry.Keyframes ~= "" then
		local sequence = ReplicatedStorage:FindFirstChild(entry.Keyframes, true)
			--// the server copies it in from ServerStorage at shift end - give
			--// that copy a moment to arrive before giving up
			or ReplicatedStorage:WaitForChild(entry.Keyframes, 3)
		if sequence and sequence:IsA("KeyframeSequence") then
			local ok, temp = pcall(function()
				return game:GetService("KeyframeSequenceProvider"):RegisterKeyframeSequence(sequence)
			end)
			if ok then
				return temp
			end
			warn(("[MvpCutscene] could not load keyframes '%s': %s"):format(entry.Keyframes, tostring(temp)))
		elseif sequence then
			warn(("[MvpCutscene] '%s' is a %s, not a KeyframeSequence"):format(entry.Keyframes, sequence.ClassName))
		end
	end
	return nil
end

----------------------------------------------------------------
-- THE STAGE RIG
----------------------------------------------------------------

--// A copy of the MVP's real character, so the shot never depends on where
--// they were standing, what they were doing, or whether they keep still
local function buildStageRig(source)
	--// Characters ship Archivable = false and refuse to clone without this
	local was = source.Archivable
	source.Archivable = true
	local ok, rig = pcall(function()
		return source:Clone()
	end)
	source.Archivable = was
	if not ok or not rig then
		return nil
	end

	for _, descendant in ipairs(rig:GetDescendants()) do
		local junk = descendant:IsA("Weld") and descendant.Name == "RightGrip"
		for _, class in ipairs(STRIP) do
			if junk or descendant:IsA(class) then
				junk = true
				break
			end
		end
		if junk then
			descendant:Destroy()
		end
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local root = rig:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		rig:Destroy()
		return nil
	end

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end

	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end
	root.Anchored = true --// the animation moves the body; the root stays put

	--// NEWER AVATARS' JOINTS (Roblox's joint upgrade) are AnimationConstraints,
	--// not Motor6Ds: the animation only PULLS each limb toward its pose with
	--// limited strength, under gravity. On this frozen stage copy a big
	--// reach (the "you're next" point) fell short. Make every one of them
	--// rigid, so the body lands exactly on the animated pose like a Motor6D.
	for _, joint in ipairs(rig:GetDescendants()) do
		if joint:IsA("AnimationConstraint") then
			pcall(function()
				joint.IsKinematic = true
				joint.MaxForce = math.huge
				joint.MaxTorque = math.huge
			end)
		end
	end

	rig.Name = "MvpStageRig"
	return rig, humanoid, root
end

--// The invisible part the camera rides on, jointed exactly like the one on
--// the Studio rig the animation was imported onto
local function addCameraBone(rig, root)
	local bone = Instance.new("Part")
	bone.Name = "CameraBone"
	bone.Size = Vector3.new(0.2, 0.2, 0.2)
	bone.Transparency = 1
	bone.CanCollide = false
	bone.CanQuery = false
	bone.CanTouch = false
	bone.Massless = true
	bone.CFrame = root.CFrame
	bone.Parent = rig

	local joint = Instance.new("Motor6D")
	joint.Name = "CameraBone"
	joint.Part0 = root
	joint.Part1 = bone
	joint.Parent = bone
	return bone
end

--// Feet on top of the spot, facing the way its FRONT face points
local function placeOnSpot(rig, humanoid, root, spot)
	local lift = (humanoid.RigType == Enum.HumanoidRigType.R15)
		and (humanoid.HipHeight + root.Size.Y / 2)
		or 3
	local at = spot.Position + Vector3.new(0, spot.Size.Y / 2 + lift, 0)

	local look = spot.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	rig:PivotTo(CFrame.lookAt(at, at + flat.Unit))
end

----------------------------------------------------------------
-- CLEARING THE SET
--
-- Every change to the world goes on the undo list as {instance, property,
-- original}, and is played back afterwards. Instances destroyed in the
-- meantime are skipped.
----------------------------------------------------------------

local function remember(undo, instance, property, value)
	table.insert(undo, { instance, property, instance[property] })
	instance[property] = value
end

--// Everyone else - players, customers, the Helper, Bruno - would wander
--// through the shot. Hidden on THIS screen only; nobody actually moves.
local function hideCast(keep, undo)
	local ownParts = {}
	for _, humanoid in ipairs(workspace:GetDescendants()) do
		if humanoid:IsA("Humanoid") then
			local model = humanoid.Parent
			if model and model ~= keep and not model:IsDescendantOf(keep) then
				remember(undo, humanoid, "DisplayDistanceType", Enum.HumanoidDisplayDistanceType.None)
				local isMine = model == player.Character
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") or d:IsA("Decal") then
						remember(undo, d, "LocalTransparencyModifier", 1)
						if isMine then
							table.insert(ownParts, d)
						end
					elseif d:IsA("BillboardGui") or d:IsA("Highlight") then
						remember(undo, d, "Enabled", false)
					end
				end
			end
		end
	end
	return ownParts
end

--// Every HUD panel, the Roblox core UI, and the interact prompts.
--// hiddenGuis collects the panels turned off, so the hold can keep them off.
local function hideInterface(ownGui, keepGuis, undo, coreUndo, hiddenGuis)
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui ~= ownGui and not keepGuis[gui] and gui.Enabled then
			remember(undo, gui, "Enabled", false)
			table.insert(hiddenGuis, gui)
		end
	end

	for _, coreType in ipairs(Enum.CoreGuiType:GetEnumItems()) do
		if coreType ~= Enum.CoreGuiType.All then
			local ok, enabled = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, coreType)
			if ok and enabled then
				table.insert(coreUndo, coreType)
				pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreType, false)
			end
		end
	end

	pcall(function()
		remember(undo, ProximityPromptService, "Enabled", false)
	end)
end

----------------------------------------------------------------
-- THE SCREEN (fade + letterbox)
----------------------------------------------------------------

local function buildScreen(settings)
	local gui = Instance.new("ScreenGui")
	gui.Name = "MvpCutscene_UI"
	gui.DisplayOrder = 100 --// above everything, the report card included
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false

	local function blackFrame(name)
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BorderSizePixel = 0
		frame.Parent = gui
		return frame
	end

	--// Film bars: invisible until the scene is set, then shown behind the fade
	local bar = settings.LetterboxScale or 0.1
	local top = blackFrame("BarTop")
	top.Size = UDim2.fromScale(1, bar)
	top.Visible = false
	local bottom = blackFrame("BarBottom")
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	bottom.Size = UDim2.fromScale(1, bar)
	bottom.Visible = false

	local fade = blackFrame("Fade")
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundTransparency = 1
	fade.ZIndex = 10

	gui.Parent = playerGui
	return gui, fade, top, bottom
end

----------------------------------------------------------------
-- RUN
----------------------------------------------------------------

--// Pause this far before the very end: a non-looping track that actually
--// reaches its end stops, and the rig drops back to its rest pose
local FREEZE_EARLY = 1 / 30

--// Yields until the MVP lands their final pose, then RETURNS with the shot
--// frozen on screen, so the caller's ceremony and report pop up over it.
--// The frozen shot stays until the ride home teleports everyone away.
--// options.KeepGuis: ScreenGuis that must stay visible through the hold
function MvpCutscene.Run(payload, options)
	local settings = Config.MvpCutscene
	if not settings or settings.Enabled == false then return end

	local awards = type(payload) == "table" and payload.Awards
	local mvp = type(awards) == "table" and awards.MVP
	if type(mvp) ~= "table" then return end

	local list = settings.Animations or {}
	local entry = list[tonumber(payload.MvpAnim) or 1] or list[1]
	if not entry then return end

	--// Every reason to skip, checked BEFORE the screen goes black
	local mvpPlayer = Players:GetPlayerByUserId(mvp.UserId)
	local source = mvpPlayer and mvpPlayer.Character
	if not source or not source:FindFirstChild("HumanoidRootPart") then
		warnOnce("gone", "the MVP has no character (left the game?) - skipping")
		return
	end
	local spot = findSpot()
	if not spot then
		warnOnce("spot", "no part tagged " .. SPOT_TAG .. " in this map - skipping")
		return
	end
	local animationId = resolveAnimationId(entry)
	if not animationId then
		warnOnce("anim:" .. tostring(entry.Name),
			("'%s' has no AnimId (and no Studio keyframes) - skipping"):format(tostring(entry.Name)))
		return
	end

	local keepGuis = {}
	for _, keep in ipairs((options and options.KeepGuis) or {}) do
		keepGuis[keep] = true
	end

	--// "Show" arrives the moment the shift ends, so the ride-home clock
	--// (Config.Shift.ReturnToLobbySeconds) is counted from here
	local shiftEndedAt = os.clock()
	local fadeSeconds = settings.FadeSeconds or 0.6
	local camera = workspace.CurrentCamera
	local gui, fade, barTop, barBottom = buildScreen(settings)

	local undo, coreUndo, cleanups, hiddenGuis = {}, {}, {}, {}
	local cameraBefore = nil
	local controls = nil
	local cutsceneSound = nil

	--// Puts the world back. Normally the teleport home gets there first and
	--// this never runs; it is for Studio (no teleport), a failed teleport,
	--// and anything that breaks before the freeze.
	local released = false
	local function release()
		if released then return end
		released = true

		--// Still playing when the shot lets go: ease it out with the fade to
		--// black rather than cutting it off mid-note
		if cutsceneSound and cutsceneSound.Parent and cutsceneSound.IsPlaying then
			fadeSound(cutsceneSound, fadeSeconds)
		end

		fade.Visible = true
		tween(fade, fadeSeconds, { BackgroundTransparency = 0 }).Completed:Wait()
		barTop.Visible = false
		barBottom.Visible = false

		for index = #cleanups, 1, -1 do
			pcall(cleanups[index])
		end
		for index = #undo, 1, -1 do
			local item = undo[index]
			pcall(function()
				item[1][item[2]] = item[3]
			end)
		end
		for _, coreType in ipairs(coreUndo) do
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreType, true)
		end
		if cameraBefore then
			camera.CameraType = cameraBefore.Type
			camera.CameraSubject = cameraBefore.Subject
			camera.FieldOfView = cameraBefore.Fov
		end
		if controls then
			pcall(function() controls:Enable() end)
		end

		tween(fade, fadeSeconds, { BackgroundTransparency = 1 }).Completed:Wait()
		gui:Destroy()
	end

	local ok, err = pcall(function()
		tween(fade, fadeSeconds, { BackgroundTransparency = 0 }).Completed:Wait()
		task.wait(settings.HoldBlackSeconds or 0.3)

		--// Behind the black: clear the set, build the stage
		hideInterface(gui, keepGuis, undo, coreUndo, hiddenGuis)

		--// Nobody walks their (hidden) character around through the
		--// ceremony; given back on release
		pcall(function()
			local scripts = player:FindFirstChild("PlayerScripts")
			local module = scripts and scripts:FindFirstChild("PlayerModule")
			if module then
				controls = require(module):GetControls()
				controls:Disable()
			end
		end)

		local rig, humanoid, root = buildStageRig(source)
		if not rig then
			error("could not copy the MVP's character")
		end
		table.insert(cleanups, function() rig:Destroy() end)

		placeOnSpot(rig, humanoid, root, spot)
		local bone = addCameraBone(rig, root)
		rig.Parent = workspace

		local ownParts = hideCast(rig, undo)

		local aimPart = rig:FindFirstChild("UpperTorso") or rig:FindFirstChild("Torso") or root

		if settings.Light ~= false then
			--// a soft KEY light in front of and above the MVP (inside the chest
			--// it lit white outfits from point-blank and blew them out)
			local holder = Instance.new("Attachment")
			holder.Name = "MvpKeyLight"
			holder.Position = Vector3.new(0, settings.LightHeight or 2.5, -(settings.LightForward or 6))
			holder.Parent = aimPart --// goes when the rig goes
			local light = Instance.new("PointLight")
			light.Brightness = settings.LightBrightness or 0.7
			light.Range = settings.LightRange or 14
			light.Color = settings.LightColor or Color3.fromRGB(255, 236, 214)
			light.Shadows = false
			light.Parent = holder
		end

		--// soften the map's BLOOM for the shot (bright outfits glowed white
		--// under it); restored when the cutscene ends
		local bloomScale = settings.BloomScale or 0.35
		if bloomScale < 1 then
			for _, effect in ipairs(Lighting:GetChildren()) do
				if effect:IsA("BloomEffect") and effect.Enabled then
					local before = effect.Intensity
					effect.Intensity = before * bloomScale
					table.insert(cleanups, function()
						if effect.Parent then effect.Intensity = before end
					end)
				end
			end
		end

		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		local track = humanoid:FindFirstChildOfClass("Animator"):LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Action4
		track.Looped = false

		--// Length reads 0 until the keyframes are down. We are still behind
		--// the black, so waiting here is invisible.
		local deadline = os.clock() + 3
		while track.Length <= 0 and os.clock() < deadline do
			task.wait()
		end
		if track.Length <= 0 then
			error(("'%s' never loaded - is it published under the group?"):format(tostring(entry.Name)))
		end

		--// THIS animation's own sound (Config: SoundId on the entry). Loaded
		--// behind the black too, so it starts in sync with the first frame
		--// instead of whenever the download finishes. Flat 2D: the cutscene
		--// is on this screen only, so is its sound.
		local sound = nil
		local soundId = entry.SoundId
		if type(soundId) == "string" and soundId ~= "" then
			sound = Instance.new("Sound")
			sound.Name = "MvpCutsceneSound"
			sound.SoundId = soundId:match("^%d+$") and ("rbxassetid://" .. soundId) or soundId
			sound.Volume = (entry.SoundVolume or 1) * ((Config.Sfx and Config.Sfx.MasterVolume) or 1)
			sound.Parent = SoundService
			cutsceneSound = sound
			table.insert(cleanups, function() sound:Destroy() end)

			local soundDeadline = os.clock() + 3
			while not sound.IsLoaded and os.clock() < soundDeadline do
				task.wait()
			end
			if not sound.IsLoaded then
				--// not fatal: the cutscene still plays, just silent
				warnOnce("sound:" .. tostring(entry.Name),
					("'%s' sound never loaded - is it published under the group?")
						:format(tostring(entry.Name)))
			end
		end

		--// The camera
		cameraBefore = {
			Type = camera.CameraType,
			Subject = camera.CameraSubject,
			Fov = camera.FieldOfView,
		}
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = entry.FieldOfView or settings.FieldOfView or 40

		local blur = nil
		if settings.Blur ~= false then
			blur = Instance.new("DepthOfFieldEffect")
			blur.Name = "MvpCutsceneBlur"
			blur.NearIntensity = 0
			blur.FarIntensity = settings.BlurIntensity or 0.5
			blur.InFocusRadius = 6
			blur.Parent = Lighting
			table.insert(cleanups, function() blur:Destroy() end)
		end

		local mode = entry.CameraMode or settings.CameraMode or "Aim"
		local fix = BONE_FIXES[entry.BoneFix or settings.BoneFix or 1] or CFrame.identity

		--// ZOOM OUT (Config.MvpCutscene.CameraDistanceMult): push the camera
		--// back along its line of sight, stopping short of walls. The ray
		--// ignores everyone's characters and the stage rig itself.
		local distanceMult = entry.CameraDistanceMult or settings.CameraDistanceMult or 1
		local pushParams = RaycastParams.new()
		pushParams.FilterType = Enum.RaycastFilterType.Exclude
		local function pushBack(view)
			if distanceMult <= 1 then return view end
			local toCamera = view.Position - aimPart.Position
			local dist = toCamera.Magnitude
			if dist < 0.05 then return view end
			local want = dist * distanceMult
			local ignore = { rig }
			for _, other in ipairs(Players:GetPlayers()) do
				if other.Character then table.insert(ignore, other.Character) end
			end
			pushParams.FilterDescendantsInstances = ignore
			local hit = workspace:Raycast(aimPart.Position, toCamera.Unit * want, pushParams)
			local reach = hit and math.max(dist, (hit.Position - aimPart.Position).Magnitude - 0.6) or want
			--// keep the shot's own rotation, just slide it back along the line
			return view.Rotation + (aimPart.Position + toCamera.Unit * reach)
		end

		--// THE HERO SHOT (owner, Oct 2026): once the pose FREEZES, the camera
		--// eases from the animation's last frame round to a flattering
		--// 3/4-front, slightly-low angle (Config.MvpCutscene.FinalShot, or the
		--// animation's own FinalShot). heroBlend runs 0 -> 1 after the freeze.
		local heroShot = entry.FinalShot or settings.FinalShot
		local holdCamera = type(entry.HoldCamera) == "table" and entry.HoldCamera.From
			and entry.HoldCamera.To and entry.HoldCamera or nil
		local heldBone = nil
		local heroBlend, heroFrom = nil, nil
		local function heroView()
			--// the way the BODY faces (animations like Siu spin the torso round
			--// while the root stays put) - so the shot is always from the front
			local look = aimPart.CFrame.LookVector * Vector3.new(1, 0, 1)
			if look.Magnitude < 0.01 then look = Vector3.new(0, 0, -1) end
			look = look.Unit
			local yaw = math.rad(heroShot.Yaw or 30)
			local front = CFrame.fromAxisAngle(Vector3.yAxis, yaw):VectorToWorldSpace(look)
			local target = aimPart.Position + Vector3.new(0, heroShot.LookHeight or 0.3, 0)
			local eye = aimPart.Position + front * (heroShot.Distance or 9)
				+ Vector3.new(0, heroShot.Height or -0.6, 0)
			--// never into a wall: stop short along the line, like pushBack
			local ignore = { rig }
			for _, other in ipairs(Players:GetPlayers()) do
				if other.Character then table.insert(ignore, other.Character) end
			end
			pushParams.FilterDescendantsInstances = ignore
			local toEye = eye - target
			local hit = workspace:Raycast(target, toEye, pushParams)
			if hit then
				eye = target + toEye.Unit * math.max(3, (hit.Position - target).Magnitude - 0.6)
			end
			return CFrame.lookAt(eye, target)
		end

		RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function()
			if not bone.Parent then return end
			--// HOLD A SHOT LONGER (Config: HoldCamera = { From, To } on the
			--// entry): between From and To the camera stays where it was at
			--// From, so the shot animated there is never seen. The body keeps
			--// animating; only the camera waits for the next shot.
			local boneCF = bone.CFrame
			if holdCamera then
				local t = track.TimePosition
				if t < holdCamera.From then
					heldBone = root.CFrame:ToObjectSpace(boneCF)
				elseif t < holdCamera.To and heldBone then
					boneCF = root.CFrame * heldBone
				end
			end
			local view
			if mode == "Bone" then
				view = boneCF * fix
			else
				if (boneCF.Position - aimPart.Position).Magnitude < 0.05 then return end
				view = CFrame.lookAt(boneCF.Position, aimPart.Position)
			end
			view = pushBack(view)
			if heroBlend then
				heroFrom = heroFrom or view
				local t = heroBlend.Value
				local eased = 1 - (1 - t) ^ 3 --// ease out
				view = heroFrom:Lerp(heroView(), eased)
			end
			camera.CFrame = view
			if blur then
				blur.FocusDistance = (view.Position - aimPart.Position).Magnitude
			end
			--// The default camera can un-hide your own body as it moves;
			--// keep it hidden every frame (a handful of parts)
			for _, part in ipairs(ownParts) do
				part.LocalTransparencyModifier = 1
			end
			--// The report switches the HUD back on when it is dismissed, but
			--// the frozen shot outlives the report - keep the HUD off until
			--// release (a handful of panels)
			for _, hidden in ipairs(hiddenGuis) do
				if hidden.Enabled then
					hidden.Enabled = false
				end
			end
		end)
		table.insert(cleanups, function()
			RunService:UnbindFromRenderStep(RENDER_NAME)
		end)

		--// Action
		barTop.Visible = true
		barBottom.Visible = true
		--// SKIP THE OPENING (Config: StartAtSeconds on the entry) - e.g. a
		--// camera shot the owner did not want. The sound skips the same
		--// stretch so it stays on the beat.
		local startAt = math.clamp(entry.StartAtSeconds or 0, 0, math.max(track.Length - 0.1, 0))
		if startAt > 0 then
			--// Started PAUSED, moved, and only let go once the move has
			--// really landed (owner playtest: a jump made the same instant
			--// as Play was ignored, so the skipped shot still showed for a
			--// second). All of this happens behind the black.
			track:Play(0, 1, 0)
			local jumpDeadline = os.clock() + 1
			repeat
				track.TimePosition = startAt
				RunService.RenderStepped:Wait()
			until track.TimePosition >= startAt - 0.05 or os.clock() > jumpDeadline
			RunService.RenderStepped:Wait() --// pose + camera drawn at the new spot
			track:AdjustSpeed(1)
		else
			track:Play(0)
		end
		local started = os.clock() - startAt
		if sound then
			local function startSound()
				if not sound.Parent then return end
				if startAt > 0 and startAt < sound.TimeLength then
					sound.TimePosition = startAt
				end
				sound:Play()
				--// Ease down over the clip's LAST few seconds instead of
				--// stopping dead. TimeLength is real by now - the sound was
				--// loaded behind the black.
				local fadeOut = entry.SoundFadeOutSeconds or 0
				if fadeOut > 0 and sound.TimeLength > 0 then
					task.delay(math.max(sound.TimeLength - sound.TimePosition - fadeOut, 0), function()
						if sound.Parent and sound.IsPlaying then
							fadeSound(sound, math.min(fadeOut, sound.TimeLength))
						end
					end)
				end
			end

			local delay = entry.SoundDelay or 0
			if delay > 0 then
				task.delay(delay, startSound)
			else
				startSound()
			end
		end
		RunService.RenderStepped:Wait() --// camera in place before anyone sees it
		tween(fade, fadeSeconds, { BackgroundTransparency = 1 }).Completed:Wait()
		fade.Visible = false --// a full-screen frame must not sit over the report's buttons

		--// Run to the last frame and FREEZE there - the pose (and the
		--// camera, which rides the same animation) holds behind the report
		local stopAt = math.max(math.min(track.Length, settings.MaxSeconds or 10) - FREEZE_EARLY, 0)
		--// the hero glide can begin BEFORE the freeze (FinalShot.StartEarlySeconds)
		local function startHero()
			if heroBlend or not heroShot or heroShot.Enabled == false then return end
			heroBlend = Instance.new("NumberValue")
			heroBlend.Value = 0
			table.insert(cleanups, function() heroBlend:Destroy() end)
			tween(heroBlend, heroShot.EaseSeconds or 1.2, { Value = 1 })
		end
		local heroEarly = heroShot and (heroShot.StartEarlySeconds or 0) or 0
		--// STUDIO CHECK: where each wrist is (studs from the root: right, up,
		--// forward) as the animation runs, to compare with the Blender file
		local studioLog = RunService:IsStudio() and {} or nil
		local nextSample = 0
		local function wristAt(jointName)
			local joint = rig:FindFirstChild(jointName, true)
			local at = nil
			if joint and joint:IsA("Motor6D") and joint.Part1 then
				at = (joint.Part1.CFrame * joint.C1).Position
			elseif joint and joint:IsA("AnimationConstraint") and joint.Attachment1 then
				at = joint.Attachment1.WorldPosition
			else
				--// no joint by that name: the hand part itself
				local hand = rig:FindFirstChild(jointName == "LeftWrist" and "LeftHand" or "RightHand")
				at = hand and hand:IsA("BasePart") and hand.Position or nil
			end
			if not at then return "?" end
			local p = root.CFrame:PointToObjectSpace(at)
			return ("(%.2f, %.2f, %.2f)"):format(p.X, p.Y, -p.Z)
		end
		if studioLog then
			local kinds = {}
			for _, joint in ipairs(rig:GetDescendants()) do
				if joint:IsA("Motor6D") or joint:IsA("AnimationConstraint") then
					kinds[joint.ClassName] = (kinds[joint.ClassName] or 0) + 1
				end
			end
			local parts = {}
			for class, count in pairs(kinds) do
				table.insert(parts, ("%d %s"):format(count, class))
			end
			print(("[MvpCutscene] stage copy joints: %s | rig type %s")
				:format(table.concat(parts, ", "), humanoid.RigType.Name))
		end
		local function sample()
			if not studioLog then return end
			table.insert(studioLog, ("   %.2fs  left wrist %s  right wrist %s")
				:format(track.TimePosition, wristAt("LeftWrist"), wristAt("RightWrist")))
		end
		while track.IsPlaying and track.TimePosition < stopAt
			and os.clock() - started < stopAt + 1 do
			if heroEarly > 0 and track.TimePosition >= stopAt - heroEarly then
				startHero()
			end
			if studioLog and track.TimePosition >= nextSample then
				sample()
				nextSample += 0.4
			end
			RunService.RenderStepped:Wait()
		end
		track:AdjustSpeed(0)
		print(("[MvpCutscene] froze '%s' at %.2fs of %.2fs")
			:format(tostring(entry.Name), track.TimePosition, track.Length))
		if studioLog then
			sample()
			print("[MvpCutscene] hand check (studs from the body's centre: right, up, forward)\n"
				.. table.concat(studioLog, "\n"))
		end
		if not track.IsPlaying then
			--// it slipped past the end on a slow frame: put it back on the
			--// final pose, paused
			track:Play(0, 1, 0)
			track.TimePosition = stopAt
		end

		--// HOLD ON THE FINAL POSE (owner playtest, Oct 2026): the last frame
		--// is the payoff ("you're next"), and the reveal used to cover the
		--// screen the instant it landed - so it was never seen. Everything
		--// after (hero glide, reveal, awards, report) waits this long.
		local finalHold = entry.FinalHoldSeconds or settings.FinalHoldSeconds or 1.5
		if finalHold > 0 then
			task.wait(finalHold)
		end

		--// the hero shot: ease to the better final angle over the frozen pose
		startHero() --// (no-op if it already began before the freeze)

		--// Film bars slide away so the report gets the whole screen
		tween(barTop, 0.4, { Size = UDim2.fromScale(1, 0) })
		tween(barBottom, 0.4, { Size = UDim2.fromScale(1, 0) })

		--// THE "ORDER UP!" REVEAL (Oct 2026): the MVP is served over the
		--// frozen pose, then the card fades and the ceremony follows. Its own
		--// pcall - a broken reveal must never undo the cutscene.
		local revealModule = script.Parent:FindFirstChild("MvpReveal")
		if revealModule then
			local title = nil
			for _, card in ipairs(awards.Players or {}) do
				if card.UserId == mvp.UserId then
					title = card.Title
				end
			end
			local okReveal, revealErr = pcall(function()
				require(revealModule).Play({
					Rig = rig, Name = mvp.Name, Title = title, Receipts = mvp.Receipts,
				})
			end)
			if not okReveal then
				warn("[MvpCutscene] reveal failed: " .. tostring(revealErr))
			end
		end
	end)

	if not ok then
		warn("[MvpCutscene] " .. tostring(err))
		release()
		return
	end

	--// THE HOLD. The frozen shot sits behind the ceremony and the report
	--// until the server's ride home teleports everyone to the lobby. Studio
	--// never teleports, so it lets go on the same clock; a live server gives
	--// the teleport a generous grace first, so a failed one cannot strand
	--// players in a frozen camera forever.
	task.spawn(function()
		local studio = RunService:IsStudio()
		local holdFor = (Config.Shift.ReturnToLobbySeconds or 42) + (studio and 0 or 20)
		local remaining = holdFor - (os.clock() - shiftEndedAt)
		if remaining > 0 then
			task.wait(remaining)
		end
		if studio then
			print("[MvpCutscene] Studio never teleports - releasing the frozen shot")
		end
		release()
	end)
end

return MvpCutscene
