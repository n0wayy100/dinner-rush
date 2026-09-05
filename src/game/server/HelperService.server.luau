--[[
	Dinner Rush - HelperService
	ServerScriptService.Server.HelperService  (Script)

	The NPC coworker for short-handed shifts (Config.Helper). When a
	shift goes RUNNING with MaxPlayersForHelper players or fewer, a
	suited rig clocks in at the player spawn and runs the FLOOR: seats
	queued parties (politely in the calm open, on sight under pressure),
	takes plain orders, ferries plated dishes - up to MaxCarry per trip,
	gathering a table's whole order when patience allows - and collects
	payments. Plates travel WITH him (goCarried, holderless) and return
	to the pass on any abort, so the plate economy never leaks.

	Everything it does goes through ServiceLoop/PassService's Helper
	verbs - the same validated flows a player triggers, crediting
	nobody. It never cooks, never touches events, never greets,
	recommends or punches: deliberately worse than a human, so the
	Helper is a third pair of legs, not an autopilot.

	Movement reuses the customer treatment: an anchored root tweened at
	amble speed. Task brain: carry > fetch > collect > take order >
	seat > idle by the pass.
--]]

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local DishModels = require(ServerStorage:WaitForChild("Shared"):WaitForChild("DishModels"))
local HELPER = Config.Helper

local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 30)
if not ShiftState then
	warn("[Helper] no ShiftState folder - the Helper stays home")
	return
end

local function bridge(name, ...)
	local found = ServerStorage:FindFirstChild(name)
	if not found then return nil end
	local ok, a, b = pcall(found.Invoke, found, ...)
	if not ok then return nil end
	return a, b
end

local function tagPart(tag)
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			if instance:IsA("BasePart") then return instance end
			if instance:IsA("Model") then
				return instance.PrimaryPart
					or instance:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	return nil
end

----------------------------------------------------------------
-- The rig: a CustomerRig clone in a suit
----------------------------------------------------------------
local helper = nil --// see spawnHelper for the shape

local function dressForWork(rig)
	--// Clothing when the owner provided templates, charcoal suit
	--// colours as the fallback - either way, no Toolbox anywhere
	if HELPER.ShirtTemplate ~= "" then
		local shirt = Instance.new("Shirt")
		shirt.ShirtTemplate = HELPER.ShirtTemplate
		shirt.Parent = rig
	end
	if HELPER.PantsTemplate ~= "" then
		local pants = Instance.new("Pants")
		pants.PantsTemplate = HELPER.PantsTemplate
		pants.Parent = rig
	end
	if HELPER.ShirtTemplate == "" or HELPER.PantsTemplate == "" then
		local colors = rig:FindFirstChildOfClass("BodyColors")
			or Instance.new("BodyColors")
		local suit = Color3.fromRGB(38, 38, 44)
		colors.TorsoColor3 = suit
		colors.LeftArmColor3 = suit
		colors.RightArmColor3 = suit
		colors.LeftLegColor3 = Color3.fromRGB(28, 28, 32)
		colors.RightLegColor3 = Color3.fromRGB(28, 28, 32)
		colors.HeadColor3 = Color3.fromRGB(255, 204, 153)
		colors.Parent = rig
	end

	--// A little mustard bow tie, parts only
	local torso = rig:FindFirstChild("UpperTorso") or rig:FindFirstChild("Torso")
	if torso then
		local bow = Instance.new("Part")
		bow.Name = "BowTie"
		bow.Size = Vector3.new(0.55, 0.28, 0.18)
		bow.Color = Color3.fromRGB(245, 184, 65)
		bow.Material = Enum.Material.SmoothPlastic
		bow.CanCollide = false
		bow.CanQuery = false
		bow.Massless = true
		bow.CFrame = torso.CFrame * CFrame.new(0, torso.Size.Y * 0.32, -torso.Size.Z * 0.5 - 0.08)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = torso
		weld.Part1 = bow
		weld.Parent = bow
		bow.Parent = rig
	end

	--// The name tag, studs-sized like every other overhead in the game
	local head = rig:FindFirstChild("Head")
	if head then
		local gui = Instance.new("BillboardGui")
		gui.Name = "HelperTag"
		gui.Size = UDim2.fromScale(5, 1.1)
		gui.StudsOffset = Vector3.new(0, 1.4, 0)
		gui.MaxDistance = 90
		gui.Parent = head

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.Text = HELPER.Name
		label.TextColor3 = Color3.fromRGB(245, 184, 65)
		label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
		label.TextStrokeTransparency = 0
		label.Parent = gui
	end
end

local function spawnHelper()
	local template = ServerStorage:FindFirstChild("CustomerRig")
	if not template then
		warn("[Helper] no CustomerRig template in ServerStorage - the Helper cannot spawn")
		return
	end

	local rig = template:Clone()
	rig.Name = "TheHelper"
	local root = rig:FindFirstChild("HumanoidRootPart")
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		warn("[Helper] CustomerRig clone has no root/humanoid - the Helper cannot spawn")
		rig:Destroy()
		return
	end

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	root.Anchored = true
	dressForWork(rig)

	--// The walk cycle (same catalog asset the customers loop)
	local walkTrack = nil
	local walkId = Config.Gestures.Walk
	if walkId and walkId ~= "" then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = walkId
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Looped = true
			walkTrack = track
		end
	end

	--// He clocks in where the PLAYERS spawn (owner call), grounded by a
	--// raycast and lifted by this rig's own hip geometry
	local spawnPad = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	local home = tagPart("Pass")
	local at = spawnPad and spawnPad.Position
		or (home and home.Position + Vector3.new(3, 0, 3))
		or Vector3.new(0, 5, 0)
	local ray = workspace:Raycast(at + Vector3.new(0, 20, 0), Vector3.new(0, -80, 0))
	local groundY = ray and ray.Position.Y or at.Y
	local rootLift = (humanoid.HipHeight > 0 and humanoid.HipHeight or 2)
		+ root.Size.Y / 2
	root.CFrame = CFrame.new(Vector3.new(at.X, groundY + rootLift, at.Z))
	rig.Parent = workspace

	helper = {
		Model = rig, Root = root,
		RootLift = rootLift, --// waypoints are floor-level; the root is not
		WalkTrack = walkTrack,
		Carrying = {}, --// up to MaxCarry of { Dish, Quality, SlotId }
		CarryParts = {},
		TargetTableId = nil,
	}
	print("[Helper] clocked in (short-handed shift)")
end

--// Puts every carried plate back on the pass and empties the hands
local function dropCarry()
	if not helper then return end
	for _, item in ipairs(helper.Carrying) do
		bridge("HelperReturnDish", item.SlotId)
	end
	helper.Carrying = {}
	for _, part in ipairs(helper.CarryParts) do
		part:Destroy()
	end
	helper.CarryParts = {}
	helper.TargetTableId = nil
end

local function despawnHelper()
	if not helper then return end
	dropCarry()
	if helper.Model then
		helper.Model:Destroy()
	end
	helper = nil
	print("[Helper] clocked out")
end

----------------------------------------------------------------
-- Movement: PATHFOUND around walls (the customers' waypoint routes
-- only cover the entrance; the Helper roams everywhere), tween-ambled
-- segment by segment. Straight line only when no path exists.
----------------------------------------------------------------
local function moveSegment(toRootPos)
	local root = helper and helper.Root
	if not root or not root.Parent then return false end

	local delta = toRootPos - root.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if delta.Magnitude < 0.4 then return true end

	local look = flat.Magnitude > 0.1 and flat.Unit or root.CFrame.LookVector
	local goal = CFrame.lookAt(toRootPos, toRootPos + look)
	local tween = TweenService:Create(root,
		TweenInfo.new(delta.Magnitude / HELPER.WalkSpeed, Enum.EasingStyle.Linear),
		{ CFrame = goal })
	tween:Play()
	tween.Completed:Wait()
	return helper ~= nil
end

local function walkTo(position)
	if not helper or not position then return false end
	local root = helper.Root
	if not root or not root.Parent then return false end

	--// Stop beside the target, never inside it
	local toward = Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z)
	local target = position
	if toward.Magnitude > 3 then
		target = position - toward.Unit * 2.5
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
	})
	local ok = pcall(function()
		path:ComputeAsync(
			root.Position - Vector3.new(0, helper.RootLift, 0), target)
	end)

	--// Legs on for the whole trip, off when it ends however it ends
	if helper.WalkTrack and not helper.WalkTrack.IsPlaying then
		helper.WalkTrack:Play(0.15)
	end

	local arrived
	if ok and path.Status == Enum.PathStatus.Success then
		arrived = true
		local waypoints = path:GetWaypoints()
		for index = 2, #waypoints do
			local wp = waypoints[index].Position
			if not moveSegment(Vector3.new(wp.X, wp.Y + helper.RootLift, wp.Z)) then
				arrived = false
				break
			end
		end
	else
		--// No route found: amble straight and hope (better than freezing)
		arrived = moveSegment(Vector3.new(target.X, root.Position.Y, target.Z))
	end

	if helper and helper.WalkTrack and helper.WalkTrack.IsPlaying then
		helper.WalkTrack:Stop(0.15)
	end
	return arrived and helper ~= nil
end

--// One dressed meal per hand: right first, then left
local function attachCarryVisual(dishName)
	if not helper then return end
	local handName = #helper.CarryParts == 0
		and { "RightHand", "Right Arm" } or { "LeftHand", "Left Arm" }
	local hand = helper.Model:FindFirstChild(handName[1])
		or helper.Model:FindFirstChild(handName[2])
	if not hand then return end

	local base = Instance.new("Part")
	base.Name = "HelperCarry"
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
	base.Parent = helper.Model

	DishModels.dress(base, dishName)
	table.insert(helper.CarryParts, base)
end

----------------------------------------------------------------
-- The brain: one task at a time, most urgent first
----------------------------------------------------------------
--// The Waiting entry the helper is committed to, if it still exists
local function findTarget(snapshot)
	if not helper.TargetTableId then return nil end
	for _, entry in ipairs(snapshot.Waiting) do
		if entry.TableId == helper.TargetTableId then
			return entry
		end
	end
	return nil
end

--// A pass slot holding a dish this table still needs, beyond what the
--// helper already carries
local function findFetchable(entry)
	local plated = bridge("HelperPassSnapshot")
	if type(plated) ~= "table" then return nil end

	--// How many of each dish are still needed after the hands
	local need = {}
	for _, dishName in ipairs(entry.Dishes) do
		need[dishName] = (need[dishName] or 0) + 1
	end
	for _, item in ipairs(helper.Carrying) do
		if need[item.Dish] then
			need[item.Dish] -= 1
		end
	end

	for _, slot in ipairs(plated) do
		if (need[slot.Dish] or 0) > 0 then
			return slot
		end
	end
	return nil
end

local function deliverTo(entry)
	if not walkTo(entry.Position) or not helper then return end
	for index = #helper.Carrying, 1, -1 do
		local item = helper.Carrying[index]
		local ok = bridge("HelperServe", entry.TableId,
			item.Dish, item.Quality, item.SlotId)
		if ok then
			table.remove(helper.Carrying, index)
			local part = table.remove(helper.CarryParts)
			if part then part:Destroy() end
		end
	end
	--// Anything refused (walkout mid-walk) goes back with everything else
	if #helper.Carrying > 0 then
		dropCarry()
	else
		helper.TargetTableId = nil
		for _, part in ipairs(helper.CarryParts) do
			part:Destroy()
		end
		helper.CarryParts = {}
	end
end

local function think()
	if not helper then return end

	local snapshot = bridge("HelperSnapshot")
	if not snapshot then return end

	--// Most desperate tables first, everywhere below
	table.sort(snapshot.Waiting, function(a, b)
		return (a.Patience or 1) < (b.Patience or 1)
	end)

	--// 1. Hands full (or partly): finish the committed table's order
	if #helper.Carrying > 0 then
		local entry = findTarget(snapshot)
		if not entry then
			dropCarry() --// the table walked / paid out: plates go home
			return
		end

		--// A table of two deserves both plates in one trip - gather the
		--// second while the kitchen keeps up and patience allows
		local wantsMore = #entry.Dishes > #helper.Carrying
			and #helper.Carrying < HELPER.MaxCarry
		if wantsMore and (entry.Patience or 0) > HELPER.DeliverAnywayFraction then
			local slot = findFetchable(entry)
			if slot then
				if walkTo(slot.Position) and helper then
					local dish, quality = bridge("HelperTakeDish", slot.SlotId)
					if dish then
						table.insert(helper.Carrying,
							{ Dish = dish, Quality = quality, SlotId = slot.SlotId })
						attachCarryVisual(dish)
					end
				end
			else
				--// Waiting on the kitchen: hover at the pass, plates in hand
				local home = tagPart("Pass")
				if home and (helper.Root.Position - home.Position).Magnitude > 8 then
					walkTo(home.Position + Vector3.new(3, 0, 3))
				end
			end
			return
		end

		deliverTo(entry)
		return
	end

	if not snapshot.Open then return end

	--// 2. Fetch for the most desperate table with food on the pass -
	--// and commit to it, so gathering stays coherent
	for _, entry in ipairs(snapshot.Waiting) do
		local slot = findFetchable(entry)
		if slot then
			if walkTo(slot.Position) and helper then
				local dish, quality = bridge("HelperTakeDish", slot.SlotId)
				if dish then
					helper.TargetTableId = entry.TableId
					table.insert(helper.Carrying,
						{ Dish = dish, Quality = quality, SlotId = slot.SlotId })
					attachCarryVisual(dish)
				end
			end
			return
		end
	end

	--// 3. Money on a table
	if #snapshot.Payments > 0 then
		local target = snapshot.Payments[1]
		if walkTo(target.Position) and helper then
			bridge("HelperCollect", target.TableId)
		end
		return
	end

	--// 4. A seated party waiting to order
	if #snapshot.NeedOrder > 0 then
		local target = snapshot.NeedOrder[1]
		if walkTo(target.Position) and helper then
			bridge("HelperTakeOrder", target.Id)
		end
		return
	end

	--// 5. Seating, with manners (owner + Claude ruling): in the calm
	--// opening he lets full-patience parties browse a moment; any
	--// pressure signal - later phase, a line forming, a draining door
	--// bar - and he seats on sight
	if snapshot.FreeTable and #snapshot.Queued > 0 then
		local phase = ShiftState:GetAttribute("Phase")
		local rushed = (phase ~= "Calm")
			or #snapshot.Queued >= HELPER.SeatQueueRush
		local pick = nil
		for _, entry in ipairs(snapshot.Queued) do
			if rushed or (entry.DoorFraction or 1) <= HELPER.SeatAtDoorFraction then
				pick = entry
				break
			end
		end
		if pick then
			if walkTo(pick.Position) and helper then
				bridge("HelperSeat", pick.Id)
			end
			return
		end
	end

	--// 6. Nothing to do: hover by the pass
	local home = tagPart("Pass")
	if home and helper then
		local away = (helper.Root.Position - home.Position).Magnitude
		if away > 8 then
			walkTo(home.Position + Vector3.new(3, 0, 3))
		end
	end
end

----------------------------------------------------------------
-- Clock in / clock out with the shift
----------------------------------------------------------------
local lastState = ShiftState:GetAttribute("State")

task.spawn(function()
	while true do
		if helper then
			local ok, err = pcall(think)
			if not ok then
				warn("[Helper] think failed: " .. tostring(err))
			end
		end
		task.wait(HELPER.ThinkSeconds)
	end
end)

ShiftState:GetAttributeChangedSignal("State"):Connect(function()
	local state = ShiftState:GetAttribute("State")
	if state == "RUNNING" and lastState ~= "RUNNING" then
		if #Players:GetPlayers() <= HELPER.MaxPlayersForHelper then
			spawnHelper()
		end
	elseif state ~= "RUNNING" and state ~= "CLOSING" then
		despawnHelper()
	end
	lastState = state
end)

print("[Helper] service ready (spawns on short-handed shifts)")
