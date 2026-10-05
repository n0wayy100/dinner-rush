--[[
	Dinner Rush - DoorService
	ServerScriptService.Server.DoorService  (Script)

	Swinging doors (Config.Doors). Any Model or Part tagged "Door" gets
	a ProximityPrompt: E toggles it open/shut (E means PRESS - owner
	ruling), swung SERVER-side around its own hinge edge so every
	client sees the same door.

	The hinge is derived from the door's bounding box: the vertical
	edge on the width axis. Guessed wrong for a particular door?
	Boolean ATTRIBUTES on the tagged model fix it, no code:
	  FlipHinge = true   hinge on the opposite edge
	  FlipSwing = true   swing the other direction
	And for double doors, a Pair attribute:
	  Pair = true        (a tick-box) opens TOGETHER with every other
	                     ticked door in the SAME parent model - put both
	                     leaves in one model, tick Pair on each
	  Pair = "Kitchen"   (text) opens together with every door sharing
	                     that text, wherever they sit
	  Pair = ""          (empty text) treated like the tick-box
	A pair gets ONE E, halfway between its leaves (owner ask, Oct 2026),
	on an invisible marker that stays in the doorway while the leaves
	swing. Tag each leaf separately; the two leaves of a double door
	hinge on opposite edges, so one usually needs FlipHinge and
	FlipSwing to mirror the other and swing the same way.

	The tagged thing must be the swinging LEAF only (a frame inside the
	model would swing along), with all parts ANCHORED.
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local DOORS = Config.Doors

local function resolvePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function newPrompt(parent)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open"
	prompt.ObjectText = "Door"
	prompt.HoldDuration = 0 --// E means PRESS, everywhere (owner ruling)
	prompt.MaxActivationDistance = DOORS.PromptRangeStuds
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

local doors = {} --// [instance] = true (set up once)

----------------------------------------------------------------
-- ONE LEAF: knows how to swing, nothing about prompts
----------------------------------------------------------------

local function makeLeaf(door, part)
	--// The hinge: the vertical edge of the door's bounding box on its
	--// WIDTH axis (doors are thin one way, wide the other)
	local boxCF, boxSize
	if door:IsA("Model") then
		boxCF, boxSize = door:GetBoundingBox()
	else
		boxCF, boxSize = door.CFrame, door.Size
	end
	local widthIsX = boxSize.X >= boxSize.Z
	local width = widthIsX and boxSize.X or boxSize.Z
	local hingeSign = door:GetAttribute("FlipHinge") and 1 or -1
	local hingeOffset = widthIsX
		and Vector3.new(hingeSign * width / 2, 0, 0)
		or Vector3.new(0, 0, hingeSign * width / 2)

	--// A builder-placed part named "Hinge" beats the bounding-box guess.
	--// The hinge frame is WORLD-ALIGNED on purpose: a door swings around
	--// the vertical through its hinge, whatever its model's box tilt -
	--// anything else is interpretive dance, not a door.
	local hingePart = door:IsA("Model") and door:FindFirstChild("Hinge", true)
	local hingePos
	if hingePart and hingePart:IsA("BasePart") then
		hingePos = hingePart.Position
	else
		hingePos = (boxCF * CFrame.new(hingeOffset)).Position
	end
	local hinge = CFrame.new(hingePos)

	local closedPivot = door:GetPivot()
	local rel = hinge:Inverse() * closedPivot --// door's place on its hinge
	local swingSign = door:GetAttribute("FlipSwing") and -1 or 1

	--// SLIDE MODE (attribute Slide = true, e.g. shoji doors): the leaf
	--// translates its own width sideways instead of swinging
	local isSlide = door:GetAttribute("Slide") == true
	local slideDir = (widthIsX and boxCF.RightVector or boxCF.LookVector)
		* (swingSign * width * 0.92)

	local leaf = {
		Door = door,
		Part = part,
		Centre = boxCF.Position, --// where the leaf's middle sits when CLOSED
		Open = false,
		Busy = false,
	}

	--// Swing to a STATE (not a toggle), so a pair can be told "open" as
	--// one. `done` runs when this leaf has finished - straight away if it
	--// was already there.
	function leaf.SetOpen(target, done)
		if leaf.Busy or leaf.Open == target then
			if done then done() end
			return
		end
		leaf.Busy = true
		leaf.Open = target

		local from = target and 0 or DOORS.OpenAngleDeg
		local to = target and DOORS.OpenAngleDeg or 0
		local swing = Instance.new("NumberValue")
		swing.Value = from
		swing.Changed:Connect(function(angle)
			if isSlide then
				door:PivotTo(closedPivot
					+ slideDir * (angle / DOORS.OpenAngleDeg))
			else
				door:PivotTo(hinge
					* CFrame.Angles(0, math.rad(angle * swingSign), 0) * rel)
			end
		end)
		local tween = TweenService:Create(swing,
			TweenInfo.new(DOORS.SwingSeconds,
				Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = to })
		tween.Completed:Once(function()
			swing:Destroy()
			leaf.Busy = false
			if done then done() end
		end)
		tween:Play()
	end

	return leaf
end

----------------------------------------------------------------
-- THE E: one per single door, one per PAIR
----------------------------------------------------------------

--// Opens or closes every leaf in `leaves` together, with `prompt` greyed
--// out until the last one has finished
local function wirePrompt(prompt, leaves)
	prompt.Triggered:Connect(function()
		for _, leaf in ipairs(leaves) do
			if leaf.Busy then return end
		end
		local target = not leaves[1].Open
		prompt.Enabled = false

		local waiting = #leaves
		local function oneDone()
			waiting -= 1
			if waiting == 0 then
				prompt.ActionText = target and "Close" or "Open"
				prompt.Enabled = true
			end
		end
		for _, leaf in ipairs(leaves) do
			leaf.SetOpen(target, oneDone)
		end
	end)
end

--// pair key -> { Leaves, Marker, Prompt }
local pairGroups = {}

--// The pair's E lives on an invisible marker halfway between its leaves'
--// closed middles - NOT inside a leaf, or it would swing away with it
local function joinPair(key, leaf, home)
	local group = pairGroups[key]
	if not group then
		local marker = Instance.new("Part")
		marker.Name = "DoorPairPrompt"
		marker.Size = Vector3.new(0.2, 0.2, 0.2)
		marker.Transparency = 1
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Parent = home
		group = { Leaves = {}, Marker = marker }
		group.Prompt = newPrompt(marker)
		wirePrompt(group.Prompt, group.Leaves)
		pairGroups[key] = group
	end
	table.insert(group.Leaves, leaf)

	--// re-centre between however many leaves have joined so far
	local sum = Vector3.zero
	for _, member in ipairs(group.Leaves) do
		sum += member.Centre
	end
	group.Marker.CFrame = CFrame.new(sum / #group.Leaves)
	return #group.Leaves
end

--// What a door's Pair attribute pairs it with: text pairs by the text; a
--// ticked box or EMPTY text pairs within the door's parent model
local function pairKeyOf(door)
	local value = door:GetAttribute("Pair")
	if typeof(value) == "string" then
		--// forgiving: "Kitchen" and "kitchen " are the same pair - a stray
		--// space or capital must not quietly split a double door
		local cleaned = value:lower():match("^%s*(.-)%s*$")
		if cleaned ~= "" then
			return cleaned
		end
		return door.Parent --// empty text: the attribute was added to pair it
	elseif typeof(value) == "number" then
		return tostring(value)
	elseif value == true then
		return door.Parent
	end
	return nil, value
end

local function setupDoor(door)
	if doors[door] then return end
	if not door:IsDescendantOf(workspace) then return end
	local part = resolvePart(door)
	if not part then return end
	doors[door] = true

	local leaf = makeLeaf(door, part)
	local key, oddValue = pairKeyOf(door)

	if key then
		--// the marker sits beside the leaves, in their shared model
		local home = typeof(key) == "Instance" and key or door.Parent
		local count = joinPair(key, leaf, home)
		--// a pair that never finds its partner shows up here as two lines
		--// that each say "1 door"
		print(("[Doors] %s joined pair '%s' (%d door(s) in it)"):format(door:GetFullName(),
			typeof(key) == "Instance" and key.Name or tostring(key), count))
		return
	end

	if oddValue ~= nil then
		warn(("[Doors] %s has Pair = %s (%s), which pairs it with nothing - type a word, "
			.. "tick the box, or leave the text empty to pair within its model")
			:format(door:GetFullName(), tostring(oddValue), typeof(oddValue)))
	end

	--// A SINGLE door: its own E at its middle. An Attachment on the leaf's
	--// part keeps it centred as the door swings (it used to sit on
	--// whichever part the model listed first - often the hinge edge).
	local spot = Instance.new("Attachment")
	spot.Name = "DoorPrompt"
	spot.CFrame = part.CFrame:ToObjectSpace(CFrame.new(leaf.Centre))
	spot.Parent = part
	wirePrompt(newPrompt(spot), { leaf })
end

for _, door in ipairs(CollectionService:GetTagged("Door")) do
	setupDoor(door)
end
CollectionService:GetInstanceAddedSignal("Door"):Connect(setupDoor)

print("[Doors] service ready - tag a door 'Door' and E swings it")
