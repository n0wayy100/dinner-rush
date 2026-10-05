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
local Sfx = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Sfx"))
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

--// The cook station nearest a point (any method). The Sous Chef is a magic
--// helper: she cooks whatever the ticket wants at her HOME station, so she
--// never walks to a method-matched station across the map (that trip is what
--// broke on cluttered maps). She summons at the nearest one and only shuttles
--// the plated dish to the pass.
local function nearestTagged(tag, pos)
	local best, bestD = nil, math.huge
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		if inst:IsDescendantOf(workspace) then
			local part = (inst:IsA("BasePart") and inst)
				or (inst:IsA("Model") and (inst.PrimaryPart
					or inst:FindFirstChildWhichIsA("BasePart", true)))
			if part then
				local d = (part.Position - pos).Magnitude
				if d < bestD then best, bestD = part, d end
			end
		end
	end
	return best
end

local function nearestStation(pos)
	return nearestTagged("CookStation", pos)
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

--// Walk there as a REAL character: compute ONE route and follow the whole
--// path (so she commits to a direct route, not a wobble), stepping waypoint to
--// waypoint. Only if she genuinely WEDGES does she side-step + re-path. Tight
--// agent radius so she turns through kitchen gaps. NOTE: PathfindingService
--// only routes around COLLIDABLE parts - the map's counters must be solid.
local function cookWalkTo(cook, position)
	if not cook or not position then return false end
	local humanoid = cook.Humanoid
	local root = cook.Root
	if not humanoid or not root or not root.Parent then return false end

	local function flatDist(a, b)
		return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
	end

	--// stop just short of the target part, never inside it
	local toward = Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z)
	local target = position
	if toward.Magnitude > 3 then
		target = position - toward.Unit * 2.5
	end

	--// PROJECT TO THE FLOOR: fridge/station/pass anchors sit up ON counters,
	--// but pathfinding runs on the floor - an elevated target reads as
	--// unreachable (NoPath). Drop the target straight down to the floor she
	--// actually stands on, so a route can be found.
	do
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { cook.Model }
		local hit = workspace:Raycast(target + Vector3.new(0, 10, 0),
			Vector3.new(0, -80, 0), rp)
		if hit then
			target = hit.Position + Vector3.new(0, 1, 0)
		end
	end

	if cook.WalkTrack and not cook.WalkTrack.IsPlaying then
		cook.WalkTrack:Play(0.15)
	end

	--// walk to ONE waypoint: returns "reached" / "stalled" / "gone"
	local function stepTo(pos)
		humanoid:MoveTo(pos)
		local deadline = os.clock() + 4
		local last, stalledSince = root.Position, os.clock()
		while cook.Model and root.Parent and os.clock() < deadline do
			if flatDist(root.Position, pos) < 3 then return "reached" end
			humanoid:MoveTo(pos)
			if flatDist(root.Position, last) < 0.4 then
				if os.clock() - stalledSince > 1.2 then return "stalled" end
			else
				stalledSince = os.clock()
			end
			last = root.Position
			task.wait(0.12)
		end
		return cook.Model and "reached" or "gone"
	end

	local logged = false
	local attempts = 0
	while cook.Model and root.Parent and attempts < 5 do
		attempts += 1
		if flatDist(root.Position, target) < 3 then break end

		local path = PathfindingService:CreatePath({
			AgentRadius = 1.4, AgentHeight = 5, AgentCanJump = false,
		})
		local okc = pcall(function() path:ComputeAsync(root.Position, target) end)
		if not logged then
			logged = true
			print(("[Skill] SousChef walk DIAG: pathStatus=%s  floor=%s  wp=%d")
				:format(okc and tostring(path.Status) or "COMPUTE-ERROR",
					tostring(humanoid.FloorMaterial),
					okc and #path:GetWaypoints() or 0))
		end

		if okc and path.Status == Enum.PathStatus.Success then
			--// commit to the WHOLE route, waypoint by waypoint
			local wps = path:GetWaypoints()
			local wedged = false
			for i = 2, #wps do
				local r = stepTo(wps[i].Position)
				if r == "gone" then wedged = true break end
				if r == "stalled" then
					--// peel off the obstacle, then re-path from where she is
					humanoid:MoveTo(root.Position + root.CFrame.RightVector * 4)
					task.wait(0.3)
					wedged = true
					break
				end
				if flatDist(root.Position, target) < 3 then break end
			end
			if not wedged then break end --// finished the route cleanly
		else
			--// no route (target unreachable / open floor): head straight a bit
			if stepTo(target) == "reached" then break end
			task.wait(0.2)
		end
	end

	if cook.Model and cook.WalkTrack and cook.WalkTrack.IsPlaying then
		cook.WalkTrack:Stop(0.15)
	end
	return cook.Model ~= nil and flatDist(root.Position, target) < 5
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

--// The loop for one dish: walk to the RIGHT station -> cook -> plate at pass.
--// Only the fridge fetch is GONE (owner call): that cross-map supply walk broke
--// and was never the fun. She still WALKS to whichever station the ticket needs
--// (rice cooker for rice, fryer for fried) from wherever she is - that walk is
--// the point - she just magics her own raw once she arrives.
local function cookOneDish(cook, job, skillDef)
	local recipe = job.Recipe

	--// 1. Walk to the station this dish needs. She spawns at a marker but
	--// travels to the matching cooker (fryer -> rice cooker if the ticket is
	--// rice). Falls back to her spawn spot only if no matching station exists.
	local station = stationFor(recipe.Method) or cook.HomeStation
	if station then cookWalkTo(cook, station.Position) end
	if not cook.Model then return end

	--// a short "prepping" beat: she holds the raw, then it goes on the grill
	cookCarry(cook, recipe.Ingredient)
	task.wait(skillDef.GrabSeconds or 0.6)
	if not cook.Model then return end
	cookCarry(cook, nil) --// raw goes on the grill (empty hands)

	--// 2. Cook: stand at the station while the dish cooks (real timing; this
	--// is the NPC's own wait, not a player's window - THE LAW holds). A cue
	--// over the station tells players it is busy and with what.
	local timing = Config.Cooking[recipe.Timing]
	local cookSecs = (timing and timing.CookTime or 10) * (skillDef.CookSpeedMult or 1)
		+ (skillDef.ExtraCookSeconds or 0)
	local cue = station and showCookingCue(station, job.Dish, cookSecs) or nil
	task.wait(cookSecs)
	clearCookingCue(cue)
	if not cook.Model then return end

	--// 3. Carry the finished dish to the PASS and plate it there. The sous
	--// chef is a COOK, not a waiter (owner call): it leaves the plated dish
	--// on the pass for a player/waiter/Helper to serve, then moves on.
	cookCarry(cook, job.Dish)
	local pass = tagPart("Pass")
	if pass then cookWalkTo(cook, pass.Position) end
	if not cook.Model then return end
	bridgeInvoke("HelperPlateDish", job.Dish, skillDef.Quality or "Good")
	cookCarry(cook, nil)
end

--// SUMMONING-JUTSU effect (owner call - "like Naruto"): a white smoke burst
--// + a quick ground shockwave ring at the spot the Sous Chef materializes.
local function summonPoof(pos)
	local anchor = Instance.new("Part")
	anchor.Name = "SummonPoof"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(pos)
	anchor.Parent = workspace

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxassetid://243660364" --// soft smoke puff (Roblox stock)
	smoke.Color = ColorSequence.new(Color3.fromRGB(245, 245, 245))
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Size = NumberSequence.new(3, 7)
	smoke.Lifetime = NumberRange.new(0.5, 0.95)
	smoke.Speed = NumberRange.new(9, 15)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Rate = 0
	smoke.Parent = anchor
	smoke:Emit(34) --// one big burst she appears out of

	local ring = Instance.new("Part")
	ring.Name = "SummonRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 255, 255)
	ring.Size = Vector3.new(0.4, 2, 2)
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Transparency = 0.15
	ring.Parent = workspace
	TweenService:Create(ring, TweenInfo.new(0.4, Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, 15, 15), Transparency = 1 }):Play()

	Debris:AddItem(ring, 0.5)
	Debris:AddItem(anchor, 1.3) --// let the smoke live out its lifetime
end

--// Bring her in at a chosen spot: play the summon anim, poof, spawn, then run
--// her cook loop for the duration. homeStation is where she cooks; spawnPos is
--// where she materializes.
local function beginSousChef(player, skillDef, homeStation, spawnPos)
	local character = player.Character
	--// The animation plays FIRST; she POOFS in (smoke burst) after the wind-up.
	skillRemote:FireClient(player, "PlayAnim", skillDef.AnimId or "")
	Sfx.Play("SousChefSummon", character)

	task.delay(skillDef.SummonDelay or 0.6, function()
		summonPoof(spawnPos) --// the jutsu smoke burst she appears from
		local cook = spawnCook(spawnPos, skillDef.WalkSpeed or 15, character)
		if not cook then return end
		cook.HomeStation = homeStation --// spawn/idle spot; she walks to each ticket's station

		local deadline = os.clock() + (skillDef.DurationSeconds or 26)
		while os.clock() < deadline and cook.Model do
			local job = pickJob()
			if job then
				local ok, err = pcall(cookOneDish, cook, job, skillDef)
				if not ok then warn("[Skill] Sous Chef cook failed: " .. tostring(err)) end
			else
				--// Nothing to cook right now: idle at her station, re-check shortly
				local station = cook.HomeStation
				if station and cook.Model
					and (cook.Root.Position - station.Position).Magnitude > 8 then
					cookWalkTo(cook, station.Position)
				end
				task.wait(1)
			end
		end
		cookPoof(cook)
	end)
end

--// Light a spawn marker ORANGE with a floating "SUMMON HERE" prompt so a
--// player can pick which one she appears at. Returns the built instances (for
--// cleanup) with the ProximityPrompt at key .Prompt.
local function markSpot(part)
	local ORANGE = Color3.fromRGB(245, 140, 40)

	local hi = Instance.new("Highlight")
	hi.FillColor = ORANGE
	hi.FillTransparency = 0.45
	hi.OutlineColor = Color3.fromRGB(255, 200, 120)
	hi.OutlineTransparency = 0
	hi.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hi.Adornee = part
	hi.Parent = part
	TweenService:Create(hi, TweenInfo.new(0.6, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true), { FillTransparency = 0.12 }):Play()

	--// a glowing orb hovering over the spot - visible across the kitchen
	local orb = Instance.new("Part")
	orb.Name = "SousChefPickOrb"
	orb.Shape = Enum.PartType.Ball
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.Material = Enum.Material.Neon
	orb.Color = ORANGE
	orb.Size = Vector3.new(1.4, 1.4, 1.4)
	orb.CFrame = CFrame.new(part.Position + Vector3.new(0, 4, 0))
	orb.Parent = workspace
	TweenService:Create(orb, TweenInfo.new(0.8, Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut, -1, true),
		{ CFrame = orb.CFrame + Vector3.new(0, 0.8, 0) }):Play()

	local label = Instance.new("BillboardGui")
	label.Name = "SousChefPickLabel"
	label.Size = UDim2.fromScale(5, 1.2)
	label.StudsOffset = Vector3.new(0, 2.6, 0)
	label.AlwaysOnTop = true
	label.Adornee = orb
	label.Parent = orb
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.fromScale(1, 1)
	txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.FredokaOne
	txt.TextScaled = true
	txt.Text = "👩‍🍳 SUMMON HERE"
	txt.TextColor3 = Color3.fromRGB(255, 240, 220)
	txt.TextStrokeColor3 = Color3.fromRGB(80, 40, 10)
	txt.TextStrokeTransparency = 0
	txt.Parent = label

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SousChefPickPrompt"
	prompt.ActionText = "Summon here"
	prompt.ObjectText = "Sous Chef"
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 12
	prompt.Parent = part

	return { hi, orb, prompt, Prompt = prompt }
end

--// Every SousChefSpot marker currently in the world (as parts).
local function gatherSpots()
	local spots = {}
	for _, inst in ipairs(CollectionService:GetTagged("SousChefSpot")) do
		if inst:IsDescendantOf(workspace) then
			local part = (inst:IsA("BasePart") and inst)
				or (inst:IsA("Model") and (inst.PrimaryPart
					or inst:FindFirstChildWhichIsA("BasePart", true)))
			if part then table.insert(spots, part) end
		end
	end
	return spots
end

local function summonSousChef(player, skillDef)
	local character = player.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart")

	--// need a rig to summon (deny cleanly if the kitchen has none)
	if not (ServerStorage:FindFirstChild("SousChefRig")
		or ServerStorage:FindFirstChild("CustomerRig")) then
		return false, "Kitchen's not ready!"
	end

	local anchorPos = playerRoot and playerRoot.Position
		or (tagPart("Pass") and tagPart("Pass").Position)
		or Vector3.new(0, 5, 0)

	local spots = gatherSpots()

	--// NO markers placed: fall back to the nearest cook station, spawn at once.
	if #spots == 0 then
		local station = nearestStation(anchorPos)
		local spawnPos = (station and (station.Position + Vector3.new(2, 0, 2)))
			or (playerRoot and (playerRoot.CFrame * CFrame.new(0, 0, -5)).Position)
			or (anchorPos + Vector3.new(3, 0, 3))
		beginSousChef(player, skillDef, station, spawnPos)
		return true
	end

	--// ONE marker: no choice to make, use it.
	if #spots == 1 then
		beginSousChef(player, skillDef, spots[1], spots[1].Position)
		return true
	end

	--// SEVERAL markers (owner call): light them ORANGE and let the caster PICK
	--// one. First one they trigger wins; a timeout auto-picks the nearest so a
	--// cast is never wasted. Cooldown already started on the R press.
	local markers, chosen, done = {}, nil, false
	for _, part in ipairs(spots) do
		local m = markSpot(part)
		m.Prompt.Triggered:Connect(function(who)
			if done or who ~= player then return end
			done, chosen = true, part
		end)
		table.insert(markers, m)
	end

	task.spawn(function()
		local deadline = os.clock() + (skillDef.PickSeconds or 8)
		while not done and os.clock() < deadline do
			task.wait(0.1)
		end
		for _, m in ipairs(markers) do
			for _, item in ipairs(m) do
				if typeof(item) == "Instance" then item:Destroy() end
			end
		end
		if not chosen then --// no pick in time: nearest to the chef
			local best, bestD = spots[1], math.huge
			for _, part in ipairs(spots) do
				local d = (part.Position - anchorPos).Magnitude
				if d < bestD then best, bestD = part, d end
			end
			chosen = best
		end
		beginSousChef(player, skillDef, chosen, chosen.Position)
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
			Sfx.Play("PlateThrow", player.Character)
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
		--// play the teleport animation NOW (visible), then blink after the
		--// wind-up - the fade would otherwise hide the animation entirely
		skillRemote:FireClient(player, "PlayAnim", skillDef.AnimId or "")
		local dest = target.Position + Vector3.new(0, 4, 0)
		task.delay(skillDef.TeleportDelay or 0.5, function()
			if root and root.Parent then
				Sfx.Play("RushInTeleport", character)
				rushTeleport(character, root, dest) --// fade out, blink in
			end
		end)
		return true

	elseif id == "Dash" then
		--// Movement is client-authoritative (SprintClient's exception), so the
		--// server only gates the cooldown and tells the client to burst forward.
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return false, "Get on the floor first!" end
		Sfx.Play("Dash", character)
		skillRemote:FireClient(player, "Dash",
			skillDef.DashSpeed or 85, skillDef.DashSeconds or 0.28)
		return true

	elseif id == "PlateJuggler" then
		return doPlateThrow(player, skillDef) --// 3D throw to the nearest in-range table

	elseif id == "WorkTheRoom" then
		--// Charmer Q: sweep every uncollected table payment to the Charmer.
		local ok, reason = bridgeInvoke("WorkTheRoom", player)
		if not ok then return false, reason or "No tips to grab!" end
		return true

	elseif id == "Superfan" then
		--// Charmer R: open the pick mode. The charm animation plays ON SELECT
		--// (inside ServiceLoop), not on the press. Denies with no cooldown when
		--// there is nobody to charm.
		local ok, reason = bridgeInvoke("Superfan", player)
		if not ok then return false, reason or "No table to charm!" end
		return true

	elseif id == "QuickSweep" then
		--// Janitor Q: the nearest mess in range is cleaned on the spot.
		--// Nothing close = denied, and the cooldown is not spent.
		local ok, reason = bridgeInvoke("JanitorQuickSweep", player, skillDef.RangeStuds)
		if not ok then return false, reason or "No mess nearby!" end
		return true

	elseif id == "GuardedZone" then
		--// Janitor R: a caution cone a few steps ahead; new messes stay out
		--// of its ring (CleanlinessService owns the spawn rule)
		local ok, reason = bridgeInvoke("JanitorGuardZone", player, skillDef)
		if not ok then return false, reason or "Can't place that here!" end
		return true
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

	--// THE LEVEL GATE: the slot must be unlocked at this class level
	--// (ClassLevel is server-set by ClassService - Q 1, R 3)
	local need = Config.SkillUnlockLevel(slot == "Q" and "SkillQ" or "SkillR")
	if (player:GetAttribute("ClassLevel") or 0) < need then
		skillRemote:FireClient(player, "Denied", slot, ("Unlocks at class level %d!"):format(need))
		return
	end

	local now = os.clock()
	cooldowns[player] = cooldowns[player] or {}
	if now < (cooldowns[player][slot] or 0) then
		return --// still cooling; the client already greys it out
	end

	local ok, reason = runSkill(player, skillDef, aim)
	if ok then
		--// QUICK RECHARGE passive trims the cooldown
		local cd = (skillDef.CooldownSeconds or 20) * (player:GetAttribute("CooldownMult") or 1)
		cooldowns[player][slot] = now + cd
		skillRemote:FireClient(player, "Cooldown", slot, cd)
	else
		skillRemote:FireClient(player, "Denied", slot, reason or "Can't use that now")
	end
end)

Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil
end)
