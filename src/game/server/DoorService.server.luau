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

local doors = {} --// [instance] = true (set up once)

local function setupDoor(door)
	if doors[door] then return end
	if not door:IsDescendantOf(workspace) then return end
	local part = resolvePart(door)
	if not part then return end
	doors[door] = true

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

	local isOpen = false
	local busy = false

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open"
	prompt.ObjectText = "Door"
	prompt.HoldDuration = 0 --// E means PRESS, everywhere (owner ruling)
	prompt.MaxActivationDistance = DOORS.PromptRangeStuds
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	prompt.Triggered:Connect(function()
		if busy then return end
		busy = true
		prompt.Enabled = false
		isOpen = not isOpen

		local from = isOpen and 0 or DOORS.OpenAngleDeg
		local to = isOpen and DOORS.OpenAngleDeg or 0
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
			prompt.ActionText = isOpen and "Close" or "Open"
			prompt.Enabled = true
			busy = false
		end)
		tween:Play()
	end)
end

for _, door in ipairs(CollectionService:GetTagged("Door")) do
	setupDoor(door)
end
CollectionService:GetInstanceAddedSignal("Door"):Connect(setupDoor)

print("[Doors] service ready - tag a door 'Door' and E swings it")
