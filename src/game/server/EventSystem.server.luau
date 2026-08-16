--[[
	Dinner Rush - EventSystem
	ServerScriptService.Server.EventSystem  (regular Script, server-side)

	The random-event scheduler, plus the first event: the Toilet Emergency.

	Scheduling reads ServiceLoop's shift state through
	ServerStorage.GetShiftInfo - there is no second copy of "is the shift
	running" anywhere. Reputation goes through ServerStorage.ApplyReputation
	for the same reason: one ledger, in ServiceLoop.

	Adding an event later means registering it in EVENTS with a Start/Stop
	pair; the scheduler picks from whatever is registered and weighted, so the
	aspirational entries in Config.EventWeights are simply skipped until they
	exist.

	TAGS USED:  Toilet (one part or model)  ·  PlungerMount (kitchen wall)

	Published for the client at ReplicatedStorage.EventState:
	  ActiveEvent   "" or "ToiletEmergency"
	  Phase         "" / "ERUPTING" / "FLOODED"
	  FuseRemaining seconds, 0 when not counting
	  FuseTotal     seconds
	  AlertText     what to shout at the team
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Events] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

print("[Events] script started")

local SCHEDULER = Config.Events.Scheduler
local TOILET = Config.Events.ToiletEmergency

--// Declared up here because stopToilet writes to it. A local declared further
--// down would not be in scope for a function defined above it.
local scheduler = {
	LastEndedAt = 0,   -- shift time an event last finished; the gap runs from here
	NextRollAt = 0,
}

----------------------------------------------------------------
-- Published state (attributes replicate; no remote needed)
----------------------------------------------------------------
local EventState = ReplicatedStorage:FindFirstChild("EventState")
if not EventState then
	EventState = Instance.new("Folder")
	EventState.Name = "EventState"
	EventState.Parent = ReplicatedStorage
end

local function publish(activeEvent, phase, fuseRemaining, fuseTotal, alertText)
	EventState:SetAttribute("ActiveEvent", activeEvent or "")
	EventState:SetAttribute("Phase", phase or "")
	EventState:SetAttribute("FuseRemaining", fuseRemaining or 0)
	EventState:SetAttribute("FuseTotal", fuseTotal or 0)
	EventState:SetAttribute("AlertText", alertText or "")
end

publish()

----------------------------------------------------------------
-- Bridges into ServiceLoop
----------------------------------------------------------------
local function shiftInfo()
	local bridge = ServerStorage:FindFirstChild("GetShiftInfo")
	if not bridge then
		return { State = "WAITING", Elapsed = 0, Difficulty = "NORMAL" }
	end
	return bridge:Invoke()
end

local function applyRep(amount, why)
	local bridge = ServerStorage:FindFirstChild("ApplyReputation")
	if bridge then
		bridge:Invoke(amount, why)
	end
end

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function resolvePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function firstTaggedPart(tag)
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			local part = resolvePart(instance)
			if part then
				return part
			end
			warn(("[Events] %s is tagged %s but has no BasePart"):format(instance:GetFullName(), tag))
		end
	end
	return nil
end

local function difficultyBlock()
	local info = shiftInfo()
	local name = info.Difficulty
	if not Config.IsValidDifficulty(name) then
		name = "NORMAL"
	end
	return Config.ForDifficulty(name), name
end

----------------------------------------------------------------
-- THE PLUNGER
-- One exists. It lives on the mount, is carried by whoever took it, and
-- returns the moment the emergency ends or its carrier disappears.
--
-- It is deliberately NOT counted by KitchenService's carry limit: that count
-- filters on the Ingredient and Dish attributes, and this tool has neither.
----------------------------------------------------------------
local plungerHolder = nil
local plungerTool = nil
local mountPrompt = nil

local function returnPlunger()
	if plungerTool then
		plungerTool:Destroy()
		plungerTool = nil
	end
	plungerHolder = nil

	if mountPrompt then
		mountPrompt.ActionText = "Take"
		mountPrompt.ObjectText = "Plunger"
	end
end

local function holdingPlunger(player)
	local character = player.Character
	if not character then return false end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("Plunger") then
			return true
		end
	end
	return false
end

local function setupPlungerMount()
	local mount = firstTaggedPart("PlungerMount")
	if not mount then
		warn("[Events] no part tagged PlungerMount - the toilet cannot be fixed")
		return
	end

	mountPrompt = Instance.new("ProximityPrompt")
	mountPrompt.Name = "TakePlunger"
	mountPrompt.ActionText = "Take"
	mountPrompt.ObjectText = "Plunger"
	mountPrompt.HoldDuration = Config.Kitchen.PickupHoldSeconds
	mountPrompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	mountPrompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	mountPrompt.Parent = mount

	mountPrompt.Triggered:Connect(function(player)
		local character = player.Character
		if not character then return end

		if plungerTool then
			mountPrompt.ObjectText = "Plunger taken!"
			task.delay(1.5, function()
				if mountPrompt and not plungerTool then
					mountPrompt.ObjectText = "Plunger"
				end
			end)
			return
		end

		local tool = Instance.new("Tool")
		tool.Name = "Plunger"
		tool.RequiresHandle = true
		tool.CanBeDropped = false
		tool:SetAttribute("Plunger", true)

		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(0.6, 4, 0.6)
		handle.Color = Color3.fromRGB(150, 60, 60)
		handle.Material = Enum.Material.SmoothPlastic
		handle.Parent = tool

		local cup = Instance.new("Part")
		cup.Name = "Cup"
		cup.Shape = Enum.PartType.Cylinder
		cup.Size = Vector3.new(1.2, 2, 2)
		cup.Color = Color3.fromRGB(60, 45, 40)
		cup.Material = Enum.Material.SmoothPlastic
		cup.CanCollide = false
		cup.Massless = true
		cup.Parent = tool

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = cup
		weld.Parent = cup
		cup.CFrame = handle.CFrame * CFrame.new(0, -2, 0) * CFrame.Angles(0, 0, math.rad(90))

		tool.Parent = character
		plungerTool = tool
		plungerHolder = player

		mountPrompt.ObjectText = "Plunger taken!"
		print(("[Events] %s took the plunger"):format(player.Name))
	end)

	print(("[Events] plunger mount ready at %s"):format(mount:GetFullName()))
end

--// The plunger must never be lost with its carrier
Players.PlayerRemoving:Connect(function(player)
	if plungerHolder == player then
		returnPlunger()
		print("[Events] carrier left - plunger returned to the mount")
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function()
		if plungerHolder == player then
			returnPlunger()
			print("[Events] carrier died - plunger returned to the mount")
		end
	end)
end)

----------------------------------------------------------------
-- THE TOILET EMERGENCY
----------------------------------------------------------------
local toilet = {
	Part = nil,
	Active = false,
	Phase = nil,       -- "ERUPTING" / "FLOODED"
	Remaining = 0,
	Total = 0,
	DrainAccum = 0,
	Puddles = nil,
	Gui = nil,
	Fill = nil,
	Label = nil,
	Prompt = nil,
}

local function buildToiletUi()
	local gui = Instance.new("BillboardGui")
	gui.Name = "ToiletAlert"
	gui.Size = UDim2.fromOffset(200, 56)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.Parent = toilet.Part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.55)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.fromRGB(255, 235, 120)
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	label.TextStrokeTransparency = 0
	label.Text = "! TOILET !"
	label.Parent = gui

	local back = Instance.new("Frame")
	back.Position = UDim2.fromScale(0.05, 0.62)
	back.Size = UDim2.fromScale(0.9, 0.3)
	back.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	back.BorderSizePixel = 0
	back.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = back

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(229, 72, 77)
	fill.BorderSizePixel = 0
	fill.Parent = back

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	toilet.Gui, toilet.Fill, toilet.Label = gui, fill, label
end

local function clearPuddles()
	if toilet.Puddles then
		toilet.Puddles:Destroy()
		toilet.Puddles = nil
	end
end

--// Flat, non-colliding, cosmetic. Spread around the toilet, fading in so the
--// flood reads as spreading rather than appearing.
local function spawnFlood()
	clearPuddles()

	local folder = Instance.new("Folder")
	folder.Name = "ToiletFlood"
	folder.Parent = workspace
	toilet.Puddles = folder

	local origin = toilet.Part.Position
	for index = 1, TOILET.PuddleCount do
		local angle = (index / TOILET.PuddleCount) * math.pi * 2
		local distance = TOILET.PuddleRadiusStuds * (0.35 + 0.65 * (index / TOILET.PuddleCount))

		local puddle = Instance.new("Part")
		puddle.Name = "Puddle" .. index
		puddle.Shape = Enum.PartType.Cylinder
		puddle.Size = Vector3.new(0.2, TOILET.PuddleSizeStuds, TOILET.PuddleSizeStuds)
		puddle.CFrame = CFrame.new(
			origin + Vector3.new(math.cos(angle) * distance, -1.6, math.sin(angle) * distance)
		) * CFrame.Angles(0, 0, math.rad(90))
		puddle.Anchored = true
		puddle.CanCollide = false
		puddle.CanQuery = false
		puddle.CanTouch = false
		puddle.Material = Enum.Material.Glass
		puddle.Color = Color3.fromRGB(120, 170, 200)
		puddle.Transparency = 1
		puddle.Parent = folder

		--// staggered fade-in
		task.delay((index / TOILET.PuddleCount) * TOILET.PuddleGrowSeconds, function()
			if puddle.Parent then
				puddle.Transparency = 0.55
			end
		end)
	end
end

local function refreshToiletUi()
	if not toilet.Gui then return end

	toilet.Gui.Enabled = toilet.Active
	if not toilet.Active then return end

	if toilet.Phase == "FLOODED" then
		toilet.Label.Text = "FLOODED!"
		toilet.Fill.Size = UDim2.fromScale(1, 1)
		toilet.Fill.BackgroundColor3 = Color3.fromRGB(120, 170, 200)
	else
		toilet.Label.Text = ("! TOILET ! %ds"):format(math.max(0, math.ceil(toilet.Remaining)))
		local fraction = toilet.Total > 0 and math.clamp(toilet.Remaining / toilet.Total, 0, 1) or 0
		toilet.Fill.Size = UDim2.fromScale(fraction, 1)

		--// second, louder cue at the halfway mark, per Config.Toilet
		local warnAt = Config.Toilet.WarningAtFraction
		toilet.Fill.BackgroundColor3 = fraction <= warnAt
			and Color3.fromRGB(229, 72, 77)
			or Color3.fromRGB(245, 184, 65)
	end
end

local function channelSecondsFor(diff)
	local seconds = diff.UnclogChannelSeconds
	if toilet.Phase == "FLOODED" then
		seconds *= TOILET.FloodChannelMultiplier
	end
	return seconds
end

local function refreshToiletPrompt()
	if not toilet.Prompt then return end

	toilet.Prompt.Enabled = toilet.Active
	if not toilet.Active then return end

	local diff = difficultyBlock()
	toilet.Prompt.ActionText = "Plunge"
	toilet.Prompt.ObjectText = toilet.Phase == "FLOODED" and "Flooded!" or "Overflowing!"
	toilet.Prompt.HoldDuration = channelSecondsFor(diff)
end

local stopToilet --// forward declared, the scheduler needs it too

local function startToilet()
	local diff = difficultyBlock()

	toilet.Active = true
	toilet.Phase = "ERUPTING"
	toilet.Total = diff.ToiletFuseSeconds
	toilet.Remaining = toilet.Total
	toilet.DrainAccum = 0

	refreshToiletUi()
	refreshToiletPrompt()
	publish("ToiletEmergency", "ERUPTING", toilet.Remaining, toilet.Total,
		"The toilet is overflowing! Grab the plunger from the kitchen!")

	print(("[Events] toilet emergency started - fuse %ds"):format(toilet.Total))
end

local function floodToilet()
	toilet.Phase = "FLOODED"
	toilet.Remaining = 0
	spawnFlood()
	applyRep(-TOILET.FloodInstantRepHit, "toilet flood")

	refreshToiletUi()
	refreshToiletPrompt()
	publish("ToiletEmergency", "FLOODED", 0, toilet.Total,
		"The bathroom has FLOODED - reputation is bleeding until it is fixed!")

	print("[Events] toilet flooded")
end

function stopToilet(fixedBy)
	if not toilet.Active then return end

	toilet.Active = false
	toilet.Phase = nil
	toilet.Remaining = 0
	toilet.Total = 0
	toilet.DrainAccum = 0
	clearPuddles()
	refreshToiletUi()
	refreshToiletPrompt()
	returnPlunger()

	--// Stamp the gap here, directly. Relying on an attribute-changed signal
	--// meant it never fired when the value had not actually changed, and the
	--// scheduler re-rolled the same event on the very next Heartbeat.
	local elapsed = shiftInfo().Elapsed
	scheduler.LastEndedAt = elapsed
	scheduler.NextRollAt = elapsed + SCHEDULER.RollIntervalSeconds

	if fixedBy then
		applyRep(TOILET.FixRepReward, "toilet fixed")
		--// ActiveEvent goes empty immediately: the event is over. Only the
		--// closing message lingers, and only for a moment.
		publish("", "", 0, 0, ("%s fixed the toilet!"):format(fixedBy.Name))
		task.delay(3, function()
			if not toilet.Active then
				publish()
			end
		end)
	else
		publish()
	end

	print(("[Events] toilet emergency ended%s - next roll no sooner than %ds"):format(
		fixedBy and (" (fixed by " .. fixedBy.Name .. ")") or "",
		math.floor(elapsed + SCHEDULER.MinGapSeconds)))
end

local function setupToilet()
	toilet.Part = firstTaggedPart("Toilet")
	if not toilet.Part then
		warn("[Events] no part tagged Toilet - the toilet emergency is disabled")
		return false
	end

	buildToiletUi()

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Plunge"
	prompt.ActionText = "Plunge"
	prompt.ObjectText = "Overflowing!"
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Enabled = false
	prompt.Parent = toilet.Part
	toilet.Prompt = prompt

	prompt.Triggered:Connect(function(player)
		if not toilet.Active then return end

		if not holdingPlunger(player) then
			prompt.ObjectText = "Get the plunger from the kitchen!"
			task.delay(2, function()
				if toilet.Active then
					refreshToiletPrompt()
				end
			end)
			return
		end

		print(("[Events] %s plunged the toilet"):format(player.Name))
		stopToilet(player)
	end)

	print(("[Events] toilet ready at %s"):format(toilet.Part:GetFullName()))
	return true
end

----------------------------------------------------------------
-- Event registry. New events add an entry here; the scheduler only ever
-- picks from what is registered AND weighted, so unimplemented entries in
-- Config.EventWeights are skipped rather than crashing.
----------------------------------------------------------------
local EVENTS = {}

local function registerEvent(name, definition)
	EVENTS[name] = definition
end

----------------------------------------------------------------
-- Scheduler
----------------------------------------------------------------
local function anyEventActive()
	for _, definition in pairs(EVENTS) do
		if definition.IsActive() then
			return true
		end
	end
	return false
end

local function pickEvent(difficultyName)
	local pool, total = {}, 0
	for name, definition in pairs(EVENTS) do
		local weight = Config.WeightFor(name, difficultyName)
		if weight > 0 and not definition.IsActive() then
			table.insert(pool, { Name = name, Weight = weight, Definition = definition })
			total += weight
		end
	end

	if total <= 0 then
		return nil
	end

	local roll = math.random() * total
	local acc = 0
	for _, entry in ipairs(pool) do
		acc += entry.Weight
		if roll <= acc then
			return entry
		end
	end
	return pool[#pool]
end

RunService.Heartbeat:Connect(function(dt)
	local info = shiftInfo()

	--// Nothing runs outside a live shift, and anything mid-flight is cleared
	if info.State ~= "RUNNING" then
		if toilet.Active then
			stopToilet(nil)
		end
		return
	end

	--// Tick the toilet
	if toilet.Active then
		if toilet.Phase == "ERUPTING" then
			toilet.Remaining -= dt
			if toilet.Remaining <= 0 then
				floodToilet()
			else
				refreshToiletUi()
				EventState:SetAttribute("FuseRemaining", math.max(0, toilet.Remaining))
			end
		elseif toilet.Phase == "FLOODED" then
			toilet.DrainAccum += dt
			if toilet.DrainAccum >= 10 then
				toilet.DrainAccum -= 10
				applyRep(-TOILET.FloodRepDrainPer10s, "flooded bathroom")
			end
		end
	end

	--// Roll for a new event
	if info.Elapsed < SCHEDULER.FirstEventAfterSeconds then return end
	if anyEventActive() then return end
	if info.Elapsed < scheduler.LastEndedAt + SCHEDULER.MinGapSeconds then return end
	if info.Elapsed < scheduler.NextRollAt then return end

	scheduler.NextRollAt = info.Elapsed + SCHEDULER.RollIntervalSeconds

	local difficultyName = Config.IsValidDifficulty(info.Difficulty) and info.Difficulty or "NORMAL"
	local entry = pickEvent(difficultyName)
	if entry then
		entry.Definition.Start()
	end
end)

----------------------------------------------------------------
-- Boot: wait for the fixtures, then register what actually exists
----------------------------------------------------------------
task.spawn(function()
	local waited = 0
	while waited < 20 do
		if firstTaggedPart("Toilet") then
			break
		end
		task.wait(0.5)
		waited += 0.5
	end

	setupPlungerMount()

	if setupToilet() then
		registerEvent("ToiletEmergency", {
			Start = startToilet,
			Stop = function() stopToilet(nil) end,
			IsActive = function() return toilet.Active end,
		})
	end

	local names = {}
	for name in pairs(EVENTS) do
		table.insert(names, name)
	end
	print(("[Events] %d event(s) registered: %s"):format(
		#names, #names > 0 and table.concat(names, ", ") or "none"))
end)

