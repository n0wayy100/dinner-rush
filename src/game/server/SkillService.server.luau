--[[
	Dinner Rush - SkillService
	ServerScriptService.Server.SkillService  (regular Script, server-side)

	CLASS SKILLS (Sep 21 2026): each class can have up to two active,
	cooldown-based skills on Q and R (the ultimate moved to T / gamepad Y /
	its on-screen circle). This is the generic framework - it reads the
	skill a player's class defines for a slot, checks the cooldown, and runs
	the effect by its Id. Only the FIXER has skills so far:

	  Toolbelt (Q) - hands you the tool the current emergency needs
	  RushIn   (R) - teleports you straight to the emergency

	SkillRemote protocol:
	  client -> server  ("Use", slot)                 slot = "Q" / "R"
	  server -> client  ("Cooldown", slot, seconds)   -- accepted, now cooling
	                    ("Denied", slot, reason)      -- could not use it

	Server-authoritative: the client only asks; every check is here.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local DishModels = require(ServerStorage:WaitForChild("Shared"):WaitForChild("DishModels"))
local SKILLS = Config.Skills
if not (SKILLS and SKILLS.Enabled) then
	return
end

print("[Skill] script started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end
local skillRemote = remotes:FindFirstChild("SkillRemote")
if not skillRemote then
	skillRemote = Instance.new("RemoteEvent")
	skillRemote.Name = "SkillRemote"
	skillRemote.Parent = remotes
end

local EventState = ReplicatedStorage:WaitForChild("EventState", 30)

--// cooldowns[player][slot] = os.clock() the skill is ready again
local cooldowns = {}

local function skillFor(player, slot)
	local classKey = player:GetAttribute("ClassKey") or ""
	local class = classKey ~= "" and Config.Classes[classKey] or nil
	if not class then return nil end
	return class[slot == "Q" and "SkillQ" or "SkillR"]
end

----------------------------------------------------------------
-- Effect helpers
----------------------------------------------------------------
local function tagPart(tag)
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			if instance:IsA("BasePart") then
				return instance
			elseif instance:IsA("Model") then
				return instance.PrimaryPart
					or instance:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	return nil
end

local function namedWorkspacePart(name)
	for _, instance in ipairs(workspace:GetDescendants()) do
		if instance.Name == name and instance:IsA("BasePart") then
			return instance
		end
	end
	return nil
end

--// where the active emergency is - mirrors EventArrowClient's target rule
local function eventTarget()
	local active = EventState and EventState:GetAttribute("ActiveEvent") or ""
	if active == "ToiletEmergency" then
		return tagPart("Toilet")
	elseif active == "GreaseFire" then
		return namedWorkspacePart("GreaseBlaze") or tagPart("ExtinguisherMount")
	elseif active == "PowerOutage" then
		return tagPart("BreakerBox")
	elseif active == "Spill" then
		return namedWorkspacePart("SpillPuddle")
	end
	return nil
end

--// The anime "instant transmission" look: bold BLACK speed lines burst
--// around the spot the character fades through. Pure code, no texture.
local LINE_COLOR = Color3.new(0, 0, 0)
local function spawnLines(position)
	for _ = 1, 16 do
		local line = Instance.new("Part")
		line.Anchored = true
		line.CanCollide = false
		line.CanQuery = false
		line.CastShadow = false
		line.Material = Enum.Material.SmoothPlastic
		line.Color = LINE_COLOR
		line.Size = Vector3.new(0.1, 3.4, 0.1) --// thin tall streak
		local angle = math.random() * math.pi * 2
		local radius = 0.4 + math.random() * 1.3
		line.CFrame = CFrame.new(position
			+ Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
			* CFrame.Angles(0, 0, math.rad((math.random() - 0.5) * 30))
		line.Parent = workspace
		TweenService:Create(line, TweenInfo.new(0.32, Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out), {
				CFrame = line.CFrame + Vector3.new(0, 2.5, 0),
				Transparency = 1,
			}):Play()
		Debris:AddItem(line, 0.4)
	end
end

--// RUSH IN (instant transmission): black speed lines + a quick fade OUT
--// here, blink to the emergency, quick fade IN there. Fast, everyone sees
--// it. Server-side transparency so the fade replicates to all clients.
local FADE_OUT = 0.14
local FADE_IN = 0.2
local function rushTeleport(character, root, destination)
	spawnLines(root.Position)

	local originals = {}
	for _, d in ipairs(character:GetDescendants()) do
		if (d:IsA("BasePart") or d:IsA("Decal")) and d.Transparency < 1 then
			originals[d] = d.Transparency
			TweenService:Create(d, TweenInfo.new(FADE_OUT), { Transparency = 1 }):Play()
		end
	end

	task.delay(FADE_OUT, function()
		if not (root and root.Parent) then return end
		root.CFrame = CFrame.new(destination)
		spawnLines(destination)
		for d, orig in pairs(originals) do
			if d.Parent then
				TweenService:Create(d, TweenInfo.new(FADE_IN), { Transparency = orig }):Play()
			end
		end
	end)
end

----------------------------------------------------------------
-- THE CHEF'S SOUS CHEF (Sep 21 2026): a summoned cook that works the
-- kitchen for REAL. It walks to the fridge/shelf, carries the raw in
-- hand, stands at the matching station while the dish cooks, plates it
-- and walks it to the waiting table - the same fetch->cook->serve loop
-- a player runs, on autopilot. Serves through the Helper's validated
-- serve bridge (credits nobody) at "Good" quality: clears tickets, no
-- reputation bonus, so it helps a short-handed shift without trivialising
-- it. Movement reuses the Helper's pathfound-tween amble.
--
-- Appearance: the owner's ServerStorage.SousChefRig if present, else the
-- CustomerRig so it still walks and cooks before the art lands. No parts
-- model, no Toolbox.
----------------------------------------------------------------
local function bridgeInvoke(name, ...)
	local found = ServerStorage:FindFirstChild(name)
	if not found then return nil end
	local ok, a, b = pcall(found.Invoke, found, ...)
	if not ok then return nil end
	return a, b
end

--// The station part for a cooking Method ("Grill" / "Fry" / "Ramen")
local function stationFor(method)
	for _, inst in ipairs(CollectionService:GetTagged("CookStation")) do
		if inst:IsDescendantOf(workspace) and inst:GetAttribute("Method") == method then
			if inst:IsA("BasePart") then return inst end
			if inst:IsA("Model") then
				return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	return nil
end

--// Build the rig: owner's cook or the customer rig, grounded, anchored
--// root (the Helper proves an anchored-root clone walks + renders fine).
local function spawnCook(spawnPos, walkSpeed, ignore)
	local template = ServerStorage:FindFirstChild("SousChefRig")
		or ServerStorage:FindFirstChild("CustomerRig")
	if not template then
		warn("[Skill] no SousChefRig or CustomerRig in ServerStorage - Sous Chef cannot spawn")
		return nil
	end
	local rig = template:Clone()
	rig.Name = "SousChef"
	local root = rig:FindFirstChild("HumanoidRootPart")
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		rig:Destroy()
		return nil
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.WalkSpeed = walkSpeed

	--// A REAL physics character (owner call - stop it phasing through counters):
	--// nothing anchored, so the Humanoid walks with its own collision and CANNOT
	--// pass through solid, anchored kitchen parts. We steer it with Humanoid:MoveTo
	--// and it grounds itself. Leave the rig's own CanCollide setup alone.
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end
	rig.PrimaryPart = root

	--// SOUS CHEF nametag, studs-sized like every other overhead
	local head = rig:FindFirstChild("Head")
	if head then
		local gui = Instance.new("BillboardGui")
		gui.Name = "SousChefTag"
		gui.Size = UDim2.fromScale(4.4, 1.1)
		gui.StudsOffset = Vector3.new(0, 1.5, 0)
		gui.MaxDistance = 80
		gui.Parent = head
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.Text = "SOUS CHEF"
		label.TextColor3 = Color3.fromRGB(245, 184, 65)
		label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
		label.TextStrokeTransparency = 0
		label.Parent = gui
	end

	--// The catalog walk cycle the customers/Helper loop
	local walkTrack = nil
	local walkId = Config.Gestures and Config.Gestures.Walk
	if walkId and walkId ~= "" then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = walkId
		local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
		if ok and track then
			track.Looped = true
			walkTrack = track
		end
	end

	--// Drop it at the spawn, a touch above the floor, and let physics settle
	--// it to standing height (the Humanoid keeps its own hip height).
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignore and { ignore } or {}
	--// Start the ray at the player's own height (2 studs up), NOT 20 - starting
	--// high clears the restaurant ceiling and lands the chef on the roof.
	local ray = workspace:Raycast(spawnPos + Vector3.new(0, 2, 0), Vector3.new(0, -20, 0), rayParams)
	local groundY = ray and ray.Position.Y or (spawnPos.Y - 2.5)
	local lift = (humanoid.HipHeight > 0 and humanoid.HipHeight or 2) + root.Size.Y / 2
	rig:PivotTo(CFrame.new(Vector3.new(spawnPos.X, groundY + lift + 0.5, spawnPos.Z)))
	rig.Parent = workspace

	return {
		Model = rig, Root = root, Humanoid = humanoid,
		WalkSpeed = walkSpeed, WalkTrack = walkTrack,
		CarryParts = {},
	}
end

--// Walk there as a REAL character: pathfind, then Humanoid:MoveTo each
--// waypoint. The Humanoid collides with anchored kitchen parts (no phasing)
--// and grounds itself. Distance + timeout so it never hangs on a stuck path.
local function cookWalkTo(cook, position)
	if not cook or not position then return false end
	local humanoid = cook.Humanoid
	local root = cook.Root
	if not humanoid or not root or not root.Parent then return false end

	local toward = Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z)
	local target = position
	if toward.Magnitude > 3 then
		target = position - toward.Unit * 2.5
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = false,
	})
	local ok = pcall(function()
		path:ComputeAsync(root.Position, target)
	end)

	if cook.WalkTrack and not cook.WalkTrack.IsPlaying then
		cook.WalkTrack:Play(0.15)
	end

	--// Steer toward one point until within reach or a short timeout
	local function stepTo(pos)
		humanoid:MoveTo(pos)
		local deadline = os.clock() + 5
		while cook.Model and root.Parent and os.clock() < deadline do
			local flat = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
			if flat.Magnitude < 3 then return true end
			humanoid:MoveTo(pos) --// keep steering (re-paths past obstacles)
			task.wait(0.12)
		end
		return cook.Model ~= nil
	end

	local arrived = true
	if ok and path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()
		for index = 2, #waypoints do
			if not stepTo(waypoints[index].Position) then
				arrived = false
				break
			end
			if not cook.Model then arrived = false; break end
		end
	else
		arrived = stepTo(target)
	end

	if cook.Model and cook.WalkTrack and cook.WalkTrack.IsPlaying then
		cook.WalkTrack:Stop(0.15)
	end
	return arrived and cook.Model ~= nil
end

--// Dress a small part into the right hand and carry it (raw or plated dish)
local function cookCarry(cook, itemName)
	for _, part in ipairs(cook.CarryParts) do part:Destroy() end
	cook.CarryParts = {}
	if not itemName then return end
	local hand = cook.Model:FindFirstChild("RightHand") or cook.Model:FindFirstChild("Right Arm")
	if not hand then return end
	local base = Instance.new("Part")
	base.Name = "CookCarry"
	base.Size = Vector3.new(0.4, 0.4, 0.4)
	base.Transparency = 1
	base.CanCollide = false
	base.CanQuery = false
	base.Massless = true
	base.CFrame = hand.CFrame * CFrame.new(0, -0.6, -0.3)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = base
	weld.Parent = base
	base.Parent = cook.Model
	DishModels.dress(base, itemName)
	table.insert(cook.CarryParts, base)
end

--// A soft poof: fade everything, then destroy
local function cookPoof(cook)
	if not cook or not cook.Model then return end
	for _, d in ipairs(cook.Model:GetDescendants()) do
		if (d:IsA("BasePart") or d:IsA("Decal")) and d.Transparency < 1 then
			TweenService:Create(d, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		end
	end
	local model = cook.Model
	task.delay(0.35, function() if model then model:Destroy() end end)
	cook.Model = nil
end

--// Pick the most desperate waiting table's first cookable dish
local function pickJob()
	local snap = bridgeInvoke("HelperSnapshot")
	if not snap or type(snap.Waiting) ~= "table" then return nil end
	table.sort(snap.Waiting, function(a, b)
		return (a.Patience or 1) < (b.Patience or 1)
	end)
	for _, entry in ipairs(snap.Waiting) do
		for _, dishName in ipairs(entry.Dishes or {}) do
			local recipe = Config.Recipes[dishName]
			if recipe then
				return { TableId = entry.TableId, Dish = dishName, Recipe = recipe }
			end
		end
	end
	return nil
end

--// A cooking cue floated over the station so players SEE the sous chef is
--// busy there and WHICH station: a house-style card with the dish name and a
--// mustard progress bar that fills over the cook time. Sizzle steam too.
local function showCookingCue(station, dishName, duration)
	if not station then return nil end
	local display = (Config.Recipes[dishName] and Config.Recipes[dishName].Display) or dishName

	local gui = Instance.new("BillboardGui")
	gui.Name = "SousChefCooking"
	gui.Size = UDim2.fromScale(4.6, 1.7)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 100
	gui.Adornee = station
	gui.Parent = station

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(59, 43, 32)
	frame.BackgroundTransparency = 0.1
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.22, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(245, 184, 65)
	stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromScale(0.04, 0.06)
	label.Size = UDim2.fromScale(0.92, 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "🍳 Cooking " .. display
	label.TextColor3 = Color3.fromRGB(255, 246, 233)
	label.TextStrokeColor3 = Color3.fromRGB(30, 20, 14)
	label.TextStrokeTransparency = 0.3
	label.Parent = frame

	local barBg = Instance.new("Frame")
	barBg.Position = UDim2.fromScale(0.08, 0.64)
	barBg.Size = UDim2.fromScale(0.84, 0.24)
	barBg.BackgroundColor3 = Color3.fromRGB(40, 30, 22)
	barBg.Parent = frame
	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(1, 0)
	bgCorner.Parent = barBg
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(245, 184, 65)
	fill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill
	TweenService:Create(fill, TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 1) }):Play()

	--// a puff of steam off the station while it cooks
	local steam = Instance.new("ParticleEmitter")
	steam.Name = "SousChefSteam"
	steam.Texture = "rbxassetid://243660364" --// soft smoke puff (Roblox stock)
	steam.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	steam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1),
	})
	steam.Size = NumberSequence.new(1.4, 2.6)
	steam.Lifetime = NumberRange.new(0.9, 1.4)
	steam.Rate = 10
	steam.Speed = NumberRange.new(1.5, 2.5)
	steam.VelocityInheritance = 0
	steam.Acceleration = Vector3.new(0, 3, 0)
	steam.Parent = station

	return { Gui = gui, Steam = steam }
end

local function clearCookingCue(cue)
	if not cue then return end
	if cue.Gui then cue.Gui:Destroy() end
	if cue.Steam then cue.Steam:Destroy() end
end

--// The whole loop for one dish: fetch -> cook -> plate -> serve
local function cookOneDish(cook, job, skillDef)
	local recipe = job.Recipe

	--// 1. Fetch the raw from its source (Fridge / DryShelf)
	local ingredient = Config.Ingredients[recipe.Ingredient]
	local source = ingredient and tagPart(ingredient.Source)
	if source then cookWalkTo(cook, source.Position) end
	if not cook.Model then return end
	task.wait(skillDef.GrabSeconds or 0.6)
	cookCarry(cook, recipe.Ingredient)

	--// 2. Carry it to the matching cook station
	local station = stationFor(recipe.Method)
	if station then cookWalkTo(cook, station.Position) end
	if not cook.Model then return end

	--// 3. Cook: stand at the station while the dish cooks (real timing;
	--// this is the NPC's own wait, not a player's window - THE LAW holds).
	--// A cue over the station tells players it is busy and with what.
	cookCarry(cook, nil) --// raw goes on the grill (empty hands)
	local timing = Config.Cooking[recipe.Timing]
	local cookSecs = (timing and timing.CookTime or 10) * (skillDef.CookSpeedMult or 1)
		+ (skillDef.ExtraCookSeconds or 0)
	local cue = showCookingCue(station, job.Dish, cookSecs)
	task.wait(cookSecs)
	clearCookingCue(cue)
	if not cook.Model then return end

	--// 4. Carry the finished dish to the PASS and plate it there. The sous
	--// chef is a COOK, not a waiter (owner call): it leaves the plated dish
	--// on the pass for a player/waiter/Helper to serve, then moves on.
	cookCarry(cook, job.Dish)
	local pass = tagPart("Pass")
	if pass then cookWalkTo(cook, pass.Position) end
	if not cook.Model then return end
	bridgeInvoke("HelperPlateDish", job.Dish, skillDef.Quality or "Good")
	cookCarry(cook, nil)
end

local function summonSousChef(player, skillDef)
	local character = player.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart")

	--// Spawn right next to the Chef (3 studs to their side), or by the pass
	--// if the Chef has no body
	local spawnPos
	if playerRoot then
		spawnPos = (playerRoot.CFrame * CFrame.new(3, 0, 0)).Position
	else
		local pass = tagPart("Pass")
		spawnPos = pass and (pass.Position + Vector3.new(3, 0, 3)) or Vector3.new(0, 5, 0)
	end

	local cook = spawnCook(spawnPos, skillDef.WalkSpeed or 15, character)
	if not cook then return false, "Kitchen's not ready!" end

	task.spawn(function()
		local deadline = os.clock() + (skillDef.DurationSeconds or 26)
		while os.clock() < deadline and cook.Model do
			local job = pickJob()
			if job then
				local ok, err = pcall(cookOneDish, cook, job, skillDef)
				if not ok then warn("[Skill] Sous Chef cook failed: " .. tostring(err)) end
			else
				--// Nothing to cook right now: hover, re-check shortly
				local pass = tagPart("Pass")
				if pass and cook.Model
					and (cook.Root.Position - pass.Position).Magnitude > 8 then
					cookWalkTo(cook, pass.Position + Vector3.new(3, 0, 3))
				end
				task.wait(1)
			end
		end
		cookPoof(cook)
	end)

	return true
end

--// DOUBLE BATCH: a bobbing "2x" badge floats over the Chef's head while
--// the skill is armed. It clears itself the moment the ChefDoubleBatch
--// flag clears - whether that is the arm timeout (below) or the cook
--// consuming it (KitchenService). Server-built so every player sees it.
local function showDoubleBatchTag(player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then return end

	local existing = head:FindFirstChild("DoubleBatchTag")
	if existing then existing:Destroy() end --// never stack two

	local gui = Instance.new("BillboardGui")
	gui.Name = "DoubleBatchTag"
	gui.Size = UDim2.fromScale(2.4, 1.2)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 80
	gui.Adornee = head
	gui.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "2×"
	label.TextColor3 = Color3.fromRGB(245, 184, 65)    --// mustard
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32) --// chocolate
	label.TextStrokeTransparency = 0
	label.Parent = gui

	--// a gentle bob so it reads as "active"
	TweenService:Create(gui, TweenInfo.new(0.6, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true),
		{ StudsOffset = Vector3.new(0, 2.95, 0) }):Play()

	--// live exactly as long as the flag lives
	local conn
	conn = player:GetAttributeChangedSignal("ChefDoubleBatch"):Connect(function()
		if not player:GetAttribute("ChefDoubleBatch") then
			gui:Destroy()
			conn:Disconnect()
		end
	end)
end

--// PLATE JUGGLER (3D throw): press R holding a plated dish with a table in
--// range (the client highlights valid ones blue) and it throws - a dressed
--// plate arcs from the waiter to the nearest ordering table, which is served.
--// No aiming; range is the gate. Plays the hired throw animation client-side.
local function flyPlate(from, to, dishName, arcHeight, seconds)
	local plate = Instance.new("Part")
	plate.Name = "ThrownPlate"
	plate.Size = Vector3.new(1.7, 0.2, 1.7)
	plate.Color = Color3.fromRGB(243, 236, 224)
	plate.Material = Enum.Material.SmoothPlastic
	plate.Anchored = true
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CFrame = CFrame.new(from)
	plate.Parent = workspace
	DishModels.dress(plate, dishName)

	task.spawn(function()
		local lift = Vector3.new(0, 1.5, 0)
		local t0 = os.clock()
		while plate.Parent do
			local a = math.clamp((os.clock() - t0) / seconds, 0, 1)
			local pos = (from + lift):Lerp(to + lift, a)
				+ Vector3.new(0, math.sin(a * math.pi) * arcHeight, 0)
			plate.CFrame = CFrame.new(pos) * CFrame.Angles(0, a * math.pi * 5, 0)
			if a >= 1 then break end
			task.wait()
		end
		plate:Destroy()
	end)
end

local function doPlateThrow(player, skillDef)
	local throw = ServerStorage:FindFirstChild("WaiterThrowNearest")
	if not throw then return false, "..." end
	local range = skillDef.ThrowRangeStuds or 45

	--// PRE-CHECK: is there a valid throw right now? (dry run - no serve yet)
	local okc, pre = pcall(throw.Invoke, throw, player, range, true)
	if not okc or type(pre) ~= "table" then
		return false, "Get near a table that ordered it!"
	end

	--// play the throw animation now; the plate leaves the hand at the throw
	--// beat (ThrowReleaseDelay in), then the serve + arc happen
	skillRemote:FireClient(player, "PlayAnim", skillDef.ThrowAnimId or "")
	task.delay(skillDef.ThrowReleaseDelay or 0.4, function()
		local ok, result = pcall(throw.Invoke, throw, player, range, false)
		if ok and type(result) == "table" then
			flyPlate(result.From, result.To, result.Dish,
				skillDef.ArcHeightStuds or 8, skillDef.ThrowSeconds or 0.55)
		end
	end)
	return true
end

----------------------------------------------------------------
-- Effects, dispatched by skill Id
----------------------------------------------------------------
local function runSkill(player, skillDef, aim)
	local id = skillDef.Id

	if id == "DoubleBatch" then
		--// arm the next cook to plate two; clear it if unused in time
		player:SetAttribute("ChefDoubleBatch", true)
		showDoubleBatchTag(player) --// "2x" over the head until it fires/expires
		local armFor = skillDef.ArmSeconds or 20
		task.delay(armFor, function()
			if player and player.Parent then
				player:SetAttribute("ChefDoubleBatch", nil)
			end
		end)
		return true

	elseif id == "SousChef" then
		return summonSousChef(player, skillDef)

	elseif id == "Toolbelt" then
		local give = ServerStorage:FindFirstChild("GiveEventTool")
		if not give then return false, "No emergency right now!" end
		local ok, msg = give:Invoke(player)
		return ok, msg

	elseif id == "RushIn" then
		local target = eventTarget()
		if not target then return false, "No emergency to rush to!" end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return false, "..." end
		--// fade out, then blink in just above the problem (0.6s of vanish)
		rushTeleport(character, root, target.Position + Vector3.new(0, 4, 0))
		return true

	elseif id == "Dash" then
		--// Movement is client-authoritative (SprintClient's exception), so the
		--// server only gates the cooldown and tells the client to burst forward.
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return false, "Get on the floor first!" end
		skillRemote:FireClient(player, "Dash",
			skillDef.DashSpeed or 85, skillDef.DashSeconds or 0.28)
		return true

	elseif id == "PlateJuggler" then
		return doPlateThrow(player, skillDef) --// 3D throw to the nearest in-range table
	end

	return false, "Unknown skill"
end

----------------------------------------------------------------
-- The one entry point
----------------------------------------------------------------
skillRemote.OnServerEvent:Connect(function(player, action, a, b)
	if action ~= "Use" then return end
	local slot, aim = a, b
	if slot ~= "Q" and slot ~= "R" then return end

	local skillDef = skillFor(player, slot)
	if not skillDef then return end --// this class has no skill in that slot

	--// (LEVEL GATE TODO: SkillR unlocks later. For now every owned skill is
	--// usable - StudioUnlockAll keeps it that way until the gate exists.)

	local now = os.clock()
	cooldowns[player] = cooldowns[player] or {}
	if now < (cooldowns[player][slot] or 0) then
		return --// still cooling; the client already greys it out
	end

	local ok, reason = runSkill(player, skillDef, aim)
	if ok then
		local cd = skillDef.CooldownSeconds or 20
		cooldowns[player][slot] = now + cd
		skillRemote:FireClient(player, "Cooldown", slot, cd)
	else
		skillRemote:FireClient(player, "Denied", slot, reason or "Can't use that now")
	end
end)

Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil
end)
