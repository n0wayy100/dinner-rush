--[[
	Dinner Rush - EntranceCutscene
	StarterPlayer.StarterPlayerScripts.Client.EntranceCutscene  (LocalScript)

	THE ENTRANCE CUTSCENE (owner trial, Oct 2026 - Config.EntranceCutscene).
	When a shift's PREP begins, the player gets a short film:

	  1. AERIAL  - the camera circles high over the restaurant; the map's
	               name slides in
	  2. WALK-IN - their character walks in along the queue line (from
	               behind the back of the queue to the front), camera tracking
	  3. LOOK    - over the shoulder, the camera pans across the dining room
	               toward the kitchen
	  4. FIRE UP - the camera swings round to the front, the character plays
	               the catalog Cheer emote (PLAYED, never authored) and the
	               title slams in: LET'S COOK!

	Everything is LOCAL: each player films their own character (a client
	may move its own character). Skippable. Gameplay never waits on it.

	TO REMOVE: set Config.EntranceCutscene.Enabled = false, or delete this
	script and that Config block - nothing else references either.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SETTINGS = Config.EntranceCutscene
if not SETTINGS or SETTINGS.Enabled == false then return end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)

local RENDER_NAME = "EntranceCutsceneCamera"

local function tween(obj, seconds, props, style, dir)
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad,
		dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function flat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	return f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, -1)
end

--// a tagged instance's position (Model -> its PrimaryPart / first part)
local function positionOf(inst)
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Model") then
		local p = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		return p and p.Position
	end
	return nil
end

local function taggedPositions(tag)
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		if inst:IsDescendantOf(workspace) then
			local p = positionOf(inst)
			if p then table.insert(out, { Pos = p, Order = inst:GetAttribute("Order") or 0 }) end
		end
	end
	return out
end

----------------------------------------------------------------
-- The shot plan, worked out from the map's tags
----------------------------------------------------------------
local function planShots(character)
	local queue = taggedPositions("QueueSpot")
	table.sort(queue, function(a, b) return a.Order < b.Order end)
	local tables = taggedPositions("Table")
	local kitchen = taggedPositions("CookStation")
	if #queue == 0 or #tables == 0 then return nil end

	--// the restaurant's centre + size
	local sum, n = Vector3.zero, 0
	for _, list in ipairs({ queue, tables, kitchen }) do
		for _, e in ipairs(list) do sum += e.Pos n += 1 end
	end
	local center = sum / n
	local radius = 0
	for _, list in ipairs({ queue, tables, kitchen }) do
		for _, e in ipairs(list) do radius = math.max(radius, (e.Pos - center).Magnitude) end
	end
	local tableCenter = Vector3.zero
	for _, e in ipairs(tables) do tableCenter += e.Pos end
	tableCenter /= #tables
	local kitchenCenter = tableCenter
	if #kitchen > 0 then
		kitchenCenter = Vector3.zero
		for _, e in ipairs(kitchen) do kitchenCenter += e.Pos end
		kitchenCenter /= #kitchen
	end

	--// the walk: from behind the back of the queue to its front (owner
	--// parts tagged EntranceStart / EntranceEnd win when present)
	local front = queue[1].Pos
	local back = queue[#queue].Pos
	local along = #queue > 1 and flat(back - front) or flat(front - center)

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then table.insert(ignore, other.Character) end
	end
	rp.FilterDescendantsInstances = ignore

	local startPos = back + along * (SETTINGS.WalkBackStuds or 18)
	--// a wall between the queue and the start: stop short of it
	local wall = workspace:Raycast(back + Vector3.new(0, 3, 0), startPos - back, rp)
	if wall then
		startPos = back + along * math.max((wall.Position - (back + Vector3.new(0, 3, 0))).Magnitude - 2.5, 0)
	end
	local endPos = front
	local overrideStart = taggedPositions("EntranceStart")[1]
	local overrideEnd = taggedPositions("EntranceEnd")[1]
	if overrideStart then startPos = overrideStart.Pos end
	if overrideEnd then endPos = overrideEnd.Pos end

	--// stand the root on the floor at the start
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local standHeight = humanoid.RigType == Enum.HumanoidRigType.R15
		and (humanoid.HipHeight + root.Size.Y / 2) or 3
	local ground = workspace:Raycast(startPos + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), rp)
	local startY = ground and ground.Position.Y or startPos.Y
	local startCF = CFrame.lookAt(Vector3.new(startPos.X, startY + standHeight, startPos.Z),
		Vector3.new(endPos.X, startY + standHeight, endPos.Z))

	return {
		Center = center, Radius = math.max(radius, 20),
		TableCenter = tableCenter, KitchenCenter = kitchenCenter,
		StartCF = startCF, Waypoints = { back, endPos },
		EndPos = endPos,
	}
end

----------------------------------------------------------------
-- The screen: letterbox bars, fade, title cards, skip
----------------------------------------------------------------
local function buildScreen()
	local gui = Instance.new("ScreenGui")
	gui.Name = "EntranceCutscene_UI"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 95
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local barScale = SETTINGS.LetterboxScale or 0.1
	local function bar(anchorY)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.fromScale(0, anchorY)
		f.Size = UDim2.fromScale(1, 0)
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.ZIndex = 5
		f.Parent = gui
		tween(f, 0.5, { Size = UDim2.fromScale(1, barScale) })
		return f
	end
	local top, bottom = bar(0), bar(1)

	local fade = Instance.new("Frame")
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.ZIndex = 20
	fade.Parent = gui

	local skip = nil
	if SETTINGS.Skippable ~= false then
		skip = Instance.new("TextButton")
		skip.Name = "Skip"
		skip.AnchorPoint = Vector2.new(1, 1)
		skip.Position = UDim2.new(0.98, 0, 1 - barScale - 0.02, 0)
		skip.Size = UDim2.fromScale(0.1, 0.06)
		skip.BackgroundColor3 = CREAM
		skip.Font = Enum.Font.FredokaOne
		skip.TextScaled = true
		skip.TextColor3 = CHOC
		skip.Text = "SKIP ▶"
		skip.ZIndex = 25
		skip.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = skip
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = CHOC
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = skip
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.18, 0)
		pad.PaddingBottom = UDim.new(0.18, 0)
		pad.Parent = skip
	end
	return gui, fade, top, bottom, skip
end

--// a chunky sticker caption that slams in and slides away
local function caption(gui, text, sub, color, y)
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(-0.5, y or 0.72)
	holder.Size = UDim2.fromScale(0.5, 0.16)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 10
	holder.Parent = gui
	local main = Instance.new("TextLabel")
	main.Size = UDim2.fromScale(1, sub and 0.68 or 1)
	main.BackgroundTransparency = 1
	main.Font = Enum.Font.FredokaOne
	main.TextScaled = true
	main.Text = text
	main.TextColor3 = color or CREAM
	main.TextStrokeColor3 = CHOC
	main.TextStrokeTransparency = 0
	main.Rotation = -3
	main.ZIndex = 11
	main.Parent = holder
	if sub then
		local small = Instance.new("TextLabel")
		small.Position = UDim2.fromScale(0.15, 0.68)
		small.Size = UDim2.fromScale(0.7, 0.32)
		small.BackgroundTransparency = 1
		small.Font = Enum.Font.FredokaOne
		small.TextScaled = true
		small.Text = sub
		small.TextColor3 = MUSTARD
		small.TextStrokeColor3 = CHOC
		small.TextStrokeTransparency = 0
		small.ZIndex = 11
		small.Parent = holder
	end
	tween(holder, 0.45, { Position = UDim2.fromScale(0.5, y or 0.72) }, Enum.EasingStyle.Back)
	return holder
end

----------------------------------------------------------------
-- PLAY
----------------------------------------------------------------
local playing = false

local function play()
	if playing then return end
	if workspace:GetAttribute("MatchMode") == "TUTORIAL" then return end --// Bruno has the floor
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root and humanoid.Health > 0) then return end
	local plan = planShots(character)
	if not plan then
		warn("[EntranceCutscene] no QueueSpot / Table tags on this map - skipping")
		return
	end
	playing = true

	local camera = workspace.CurrentCamera
	local before = { Type = camera.CameraType, Subject = camera.CameraSubject, Fov = camera.FieldOfView }
	local gui, fade, _, _, skipButton = buildScreen()
	local skipped = false
	if skipButton then
		skipButton.Activated:Connect(function() skipped = true end)
	end

	--// hide the HUD for the film (given back after). Kept hidden EVERY frame:
	--// the HUD re-enables itself on its own updates (the "SHIFT STARTS IN"
	--// countdown popped back over the pose shot), so anything that turns
	--// itself on mid-film is switched straight back off and given back after
	local hidden, hiddenSet = {}, {}
	local function hideHud()
		for _, child in ipairs(playerGui:GetChildren()) do
			if child:IsA("ScreenGui") and child ~= gui and child.Enabled then
				child.Enabled = false
				if not hiddenSet[child] then
					hiddenSet[child] = true
					table.insert(hidden, child)
				end
			end
		end
	end
	hideHud()
	local hudKeeper = RunService.RenderStepped:Connect(hideHud)
	--// no walking off mid-shot
	local controls = nil
	pcall(function()
		local module = player.PlayerScripts:FindFirstChild("PlayerModule")
		if module then
			controls = require(module):GetControls()
			controls:Disable()
		end
	end)

	camera.CameraType = Enum.CameraType.Scriptable
	local shot = nil --// function(dt) -> CFrame, set per shot
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		if shot then
			local ok, cf = pcall(shot, dt)
			if ok and cf then camera.CFrame = cf end
		end
	end)

	local function wait(seconds)
		local untilT = os.clock() + seconds
		while os.clock() < untilT and not skipped do
			RunService.RenderStepped:Wait()
		end
		return not skipped
	end
	local function dip()
		tween(fade, 0.2, { BackgroundTransparency = 0 }).Completed:Wait()
	end
	local function undip()
		tween(fade, 0.25, { BackgroundTransparency = 1 })
	end

	local ok, err = pcall(function()
		--// place the character outside, at the start of the walk
		dip()
		root.CFrame = plan.StartCF
		root.AssemblyLinearVelocity = Vector3.zero

		--// SHOT 1: THE SHOWCASE - a still establishing view with a slow push
		--// in. The owner's camera marker (a part tagged EntranceCam, dropped
		--// at the Studio camera's view) wins; otherwise a fixed high corner
		--// view worked out from the map. No rotation (owner call).
		local c, r = plan.Center, plan.Radius
		local t1 = 0
		local aerialSeconds = SETTINGS.AerialSeconds or 3.2
		--// one marker per map is fine: the one nearest this restaurant wins
		local markerInst, bestDist = nil, math.huge
		for _, inst in ipairs(CollectionService:GetTagged("EntranceCam")) do
			if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
				local d = (inst.Position - c).Magnitude
				if d < bestDist then markerInst, bestDist = inst, d end
			end
		end
		local baseCF
		if markerInst and markerInst:IsA("BasePart") then
			baseCF = markerInst.CFrame
		else
			local angle0 = math.atan2(plan.StartCF.Position.Z - c.Z, plan.StartCF.Position.X - c.X)
			baseCF = CFrame.lookAt(c + Vector3.new(math.cos(angle0) * (r + 20), r * 0.45 + 18,
				math.sin(angle0) * (r + 20)), c)
		end
		local drift = SETTINGS.ShowcaseDriftStuds or 3
		camera.FieldOfView = markerInst and markerInst:GetAttribute("FieldOfView") or 60
		shot = function(dt)
			t1 += dt
			local k = math.clamp(t1 / aerialSeconds, 0, 1)
			return baseCF * CFrame.new(0, 0, -drift * k) --// gentle push forward
		end
		undip()
		local mapRow = Config.MapById and Config.MapById(workspace:GetAttribute("MatchMapId"))
		local card = caption(gui, (mapRow and mapRow.Display) or "DINNER RUSH", "TONIGHT'S SHIFT", CREAM, 0.74)
		if not wait(aerialSeconds) then return end
		tween(card, 0.3, { Position = UDim2.fromScale(1.5, 0.74) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

		--// SHOT 2: WALK-IN - tracking from behind and to the side
		dip()
		camera.FieldOfView = 55
		shot = function()
			local look = flat(root.CFrame.LookVector)
			local right = look:Cross(Vector3.yAxis).Unit
			local pos = root.Position - look * 11 + right * 4 + Vector3.new(0, 4, 0)
			return CFrame.lookAt(pos, root.Position + look * 6 + Vector3.new(0, 1.5, 0))
		end
		undip()
		local walkStart = os.clock()
		for _, point in ipairs(plan.Waypoints) do
			humanoid:MoveTo(point)
			local arrived = false
			local conn = humanoid.MoveToFinished:Connect(function() arrived = true end)
			while not arrived and not skipped
				and os.clock() - walkStart < (SETTINGS.WalkTimeoutSeconds or 6) do
				RunService.RenderStepped:Wait()
			end
			conn:Disconnect()
			if skipped then return end
		end
		humanoid:MoveTo(root.Position) --// stop

		--// SHOT 3: LOOK AROUND - turn to the dining room, pan to the kitchen
		root.CFrame = CFrame.lookAt(root.Position,
			Vector3.new(plan.TableCenter.X, root.Position.Y, plan.TableCenter.Z))
		local lookSeconds = SETTINGS.LookAroundSeconds or 2.6
		local t3 = 0
		shot = function(dt)
			t3 += dt
			local k = math.clamp(t3 / lookSeconds, 0, 1)
			k = k * k * (3 - 2 * k) --// ease in-out
			local look = flat(root.CFrame.LookVector)
			local right = look:Cross(Vector3.yAxis).Unit
			local pos = root.Position - look * 5 + right * 2.2 + Vector3.new(0, 3.2, 0)
			local target = plan.TableCenter:Lerp(plan.KitchenCenter, k)
			return CFrame.lookAt(pos, target + Vector3.new(0, 1, 0))
		end
		if not wait(lookSeconds) then return end

		--// SHOT 4: FIRE UP - swing round to the front, the pose, the title
		dip()
		camera.FieldOfView = 50
		local poseSeconds = SETTINGS.PoseSeconds or 3.2
		local t4 = 0
		shot = function(dt)
			t4 += dt
			local look = flat(root.CFrame.LookVector)
			local dist = 9 - math.min(t4 / poseSeconds, 1) * 2.2 --// a slow push-in
			local pos = root.Position + look * dist + Vector3.new(0, 1.2, 0)
			return CFrame.lookAt(pos, root.Position + Vector3.new(0, 1.3, 0))
		end
		undip()
		local animId = Config.Gestures and Config.Gestures[SETTINGS.PoseGesture or "Cheer"]
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animId and animator then
			local animation = Instance.new("Animation")
			animation.AnimationId = animId
			local okTrack, track = pcall(animator.LoadAnimation, animator, animation)
			if okTrack and track then
				track.Priority = Enum.AnimationPriority.Action
				track:Play(0.15)
			end
		end
		task.wait(0.35)
		local title = caption(gui, SETTINGS.TitleText or "LET'S COOK!", nil, TOMATO, 0.7)
		local titleScale = Instance.new("UIScale")
		titleScale.Scale = 1.6
		titleScale.Parent = title
		tween(titleScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		wait(poseSeconds)
	end)
	if not ok then
		warn("[EntranceCutscene] " .. tostring(err))
	end

	--// THE END (or a skip): make sure they are inside, give everything back
	if skipped or not ok then
		root.CFrame = CFrame.lookAt(
			Vector3.new(plan.EndPos.X, root.Position.Y, plan.EndPos.Z),
			Vector3.new(plan.TableCenter.X, root.Position.Y, plan.TableCenter.Z))
		humanoid:MoveTo(root.Position)
	end
	tween(fade, 0.3, { BackgroundTransparency = 0 }).Completed:Wait()
	shot = nil
	RunService:UnbindFromRenderStep(RENDER_NAME)
	camera.CameraType = before.Type == Enum.CameraType.Scriptable and Enum.CameraType.Custom or before.Type
	camera.CameraSubject = humanoid
	camera.FieldOfView = before.Fov
	hudKeeper:Disconnect()
	for _, other in ipairs(hidden) do
		if other.Parent then other.Enabled = true end
	end
	if controls then pcall(function() controls:Enable() end) end
	for _, child in ipairs(gui:GetChildren()) do
		if child ~= fade then child:Destroy() end
	end
	tween(fade, 0.35, { BackgroundTransparency = 1 }).Completed:Wait()
	gui:Destroy()
	playing = false
end

----------------------------------------------------------------
-- Trigger: the start of PREP (once per session by default)
----------------------------------------------------------------
--// tell the server this player's film is over - the shift (and the first
--// customers) waits for everyone. Sent on EVERY way out: finished,
--// skipped, nothing to film, tutorial, already played.
local function reportDone()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
		local remote = remotes and remotes:WaitForChild("EntranceCutsceneRemote", 10)
		if remote then
			remote:FireServer("Done")
		end
	end)
end

--// The server enters PREP the moment the first player joins - the same
--// moment this script starts listening - so the trigger can fire TWICE.
--// A second call while the film runs must NOT report "Done" (that once
--// started the shift mid-film); it only re-reports once the film is over.
local played, finished = false, false
local function tryPlay()
	if played then
		if finished then reportDone() end
		return
	end
	played = true
	task.spawn(function()
		--// the character may still be loading in
		local deadline = os.clock() + 10
		while os.clock() < deadline do
			local character = player.Character
			if character and character:FindFirstChild("HumanoidRootPart")
				and character:FindFirstChildOfClass("Humanoid") then
				break
			end
			task.wait(0.2)
		end
		task.wait(0.5)
		pcall(play) --// returns when the film ends (or straight away if it can't run)
		finished = true
		reportDone()
	end)
end

task.spawn(function()
	local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 60)
	if not ShiftState then return end
	ShiftState:GetAttributeChangedSignal("State"):Connect(function()
		if ShiftState:GetAttribute("State") == "PREP" then tryPlay() end
	end)
	if ShiftState:GetAttribute("State") == "PREP" then tryPlay() end
end)
