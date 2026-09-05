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
	            ExtinguisherMount (kitchen wall - grease fire)

	Published for the client at ReplicatedStorage.EventState:
	  ActiveEvent   "" / "ToiletEmergency" / "GreaseFire"
	  Phase         "" / "ERUPTING" / "FLOODED"
	  FuseRemaining seconds, 0 when not counting (GreaseFire: the SOONEST fuse)
	  FuseTotal     seconds
	  AlertText     what to shout at the team
	  Toast         center-screen lesson text ("" = hidden) - the water trap
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Sfx = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Sfx"))
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Events] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

--// Persistence contract - degrade over dying, same as ServiceLoop
local ProfileAPI
do
	local ok, api = pcall(function()
		return require(ServerStorage:WaitForChild("Shared", 20):WaitForChild("ProfileAPI", 20))
	end)
	if ok and api then
		ProfileAPI = api
	else
		warn("[Events] ProfileAPI unavailable - event careers will NOT save")
		ProfileAPI = { AddStat = function() return false end }
	end
end

--// Career + ultimate charge + hidden score in one call (same shape as
--// ServiceLoop's; ScoreService quietly counts every credited moment)
local function creditStat(player, key, amount)
	ProfileAPI.AddStat(player, key, amount)
	local charge = ServerStorage:FindFirstChild("AddCharge")
	if charge then
		pcall(function()
			charge:Invoke(player, key, amount)
		end)
	end
	local bus = ServerStorage:FindFirstChild("AddScore")
	if bus then
		bus:Fire(player, key, amount)
	end
end

print("[Events] script started")

local SCHEDULER = Config.Events.Scheduler
local TOILET = Config.Events.ToiletEmergency
local OUTAGE = Config.Events.PowerOutage

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
EventState:SetAttribute("PatienceMultiplier", 1) --// 1 = normal drain
EventState:SetAttribute("PowerOut", false) --// KitchenService freezes cooking on this
EventState:SetAttribute("Toast", "") --// independent of publish(): a toast may
                                     --// outlive the event that raised it

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
-- SHIFT REPORT COUNTERS. ServiceLoop pulls these at shift end through
-- GetEventStats; we reset them ourselves when a new shift goes RUNNING
-- (the heartbeat below watches for the transition).
----------------------------------------------------------------
local eventStats = {
	ToiletsPlunged = 0,
	FiresExtinguished = 0,
	OutagesFixed = 0,
	WaterIncidents = 0,
}
local lastShiftState = "WAITING"

do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "GetEventStats"
	bridge.OnInvoke = function()
		return table.clone(eventStats)
	end
	bridge.Parent = ServerStorage
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
	if diff.Interactions and diff.Interactions.PlungeMinigame then
		toilet.Prompt.HoldDuration = 0 --// gated: a TAP opens the tapping panel
	else
		toilet.Prompt.HoldDuration = channelSecondsFor(diff) --// ungated fallback
	end
end

local stopToilet --// forward declared, the scheduler needs it too
local cancelPlungeSession --// forward declared (plunge-tap section, below stopToilet)
local beginPlungeSession --// forward declared (same section)

local function startToilet()
	local diff = difficultyBlock()

	--// Global: an emergency nobody hears is an emergency nobody fixes
	Sfx.Play("ToiletAlert")

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
	if cancelPlungeSession then
		cancelPlungeSession() --// the flooded deal needs more taps - re-open
	end
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
	if cancelPlungeSession then
		cancelPlungeSession() --// an open tap panel closes with the event
	end
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
		eventStats.ToiletsPlunged += 1
		creditStat(fixedBy, "EventChannels", 1) --// the Fixer's career
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

----------------------------------------------------------------
-- THE PLUNGE TAP (gated by Difficulty.Interactions.PlungeMinigame -
-- ON for every difficulty). Spam tap/click fills a bar that
-- leaks while you rest. The server counts its OWN taps - rate-capped
-- against autoclickers, plunger-in-hand and proximity re-checked every
-- tap - and a full bar exits through stopToilet's normal success path.
-- One plumber at a time; every exit path frees the toilet.
----------------------------------------------------------------
local PLUNGE = Config.PlungeTap

local plungeRemoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not plungeRemoteFolder then
	plungeRemoteFolder = Instance.new("Folder")
	plungeRemoteFolder.Name = "Remotes"
	plungeRemoteFolder.Parent = ReplicatedStorage
end

local plungeRemote = plungeRemoteFolder:FindFirstChild("PlungeRemote")
if not plungeRemote then
	plungeRemote = Instance.new("RemoteEvent")
	plungeRemote.Name = "PlungeRemote"
	plungeRemote.Parent = plungeRemoteFolder
end

local plungeSession = nil --// { Player, Fill, TapsNeeded, LastTapAt, Token }
local plungeToken = 0

cancelPlungeSession = function()
	if not plungeSession then return end
	local session = plungeSession
	plungeSession = nil
	if session.Player and session.Player.Parent then
		plungeRemote:FireClient(session.Player, "Close", session.Token, false)
	end
end

beginPlungeSession = function(player)
	--// One plumber at a time
	if plungeSession then
		if plungeSession.Player ~= player and toilet.Prompt then
			toilet.Prompt.ObjectText = "Being plunged!"
			task.delay(1.5, function()
				if toilet.Active then
					refreshToiletPrompt()
				end
			end)
		end
		return
	end

	local tapsNeeded = PLUNGE.TapsToFill
	if toilet.Phase == "FLOODED" then
		tapsNeeded *= PLUNGE.FloodTapsMultiplier
	end
	--// FIXER PASSIVE in tap grammar: ChannelMult trims the taps needed
	tapsNeeded = math.max(1, math.ceil(tapsNeeded * (player:GetAttribute("ChannelMult") or 1)))

	plungeToken += 1
	plungeSession = {
		Player = player,
		Fill = 0,
		TapsNeeded = tapsNeeded,
		LastTapAt = os.clock(),
		Token = plungeToken,
	}

	plungeRemote:FireClient(player, "Open", {
		Token = plungeToken,
		FillPerTap = 1 / tapsNeeded, --// lets the client bump optimistically
		ToiletPosition = toilet.Part and toilet.Part.Position or Vector3.zero,
	})

	--// An abandoned panel must never deadlock the toilet
	local myToken = plungeToken
	task.delay(PLUNGE.TimeoutSeconds, function()
		if plungeSession and plungeSession.Token == myToken then
			print("[Events] plunge panel timed out - toilet freed")
			cancelPlungeSession()
		end
	end)

	print(("[Events] %s started plunging (%d taps)"):format(player.Name, tapsNeeded))
end

plungeRemote.OnServerEvent:Connect(function(player, action, token)
	local session = plungeSession
	if not session or session.Token ~= token or session.Player ~= player then return end

	if action == "Abandon" then
		cancelPlungeSession()
		return
	end
	if action ~= "Tap" then return end
	if not toilet.Active then
		cancelPlungeSession()
		return
	end

	--// The plunger must still be in hand and the plumber at the bowl
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not holdingPlunger(player) or not root or not toilet.Part
		or (root.Position - toilet.Part.Position).Magnitude > PLUNGE.WalkAwayStuds + 6 then
		cancelPlungeSession()
		return
	end

	--// Rate cap: taps beyond human speed simply don't count
	local now = os.clock()
	local sinceLast = now - session.LastTapAt
	if sinceLast < 1 / PLUNGE.MaxTapsPerSecond then
		return
	end

	--// The bar leaked while they rested; this tap pushes it back up
	session.Fill = math.max(0, session.Fill - PLUNGE.DecayPerSecond * sinceLast)
	session.Fill += 1 / session.TapsNeeded
	session.LastTapAt = now

	if session.Fill >= 1 then
		--// Filled: exit through the SAME success path as EASY's hold -
		--// reward, career credit, charge and announcement all come free
		plungeSession = nil --// before stopToilet so its cancel is a no-op
		plungeRemote:FireClient(player, "Close", session.Token, true)
		print(("[Events] %s tapped the toilet clear"):format(player.Name))
		stopToilet(player)
		return
	end

	plungeRemote:FireClient(player, "Progress", session.Token, session.Fill)
end)

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

	--// FIXER PASSIVE: channels scale per player. Same shared-prompt trick
	--// as the kitchen's collect holds: scale when THIS player's hold
	--// begins, restore on release.
	prompt.PromptButtonHoldBegan:Connect(function(player)
		local diffTable = difficultyBlock()
		if diffTable.Interactions and diffTable.Interactions.PlungeMinigame then
			return --// gated: tap-to-open, no hold to scale
		end
		local mult = player:GetAttribute("ChannelMult") or 1
		if mult ~= 1 and toilet.Active then
			prompt.HoldDuration = channelSecondsFor(diffTable) * mult
		end
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		if toilet.Active then
			refreshToiletPrompt()
		end
	end)

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

		local diffTable = difficultyBlock()
		if diffTable.Interactions and diffTable.Interactions.PlungeMinigame then
			beginPlungeSession(player) --// gated: the tap opens the tapping panel
		else
			print(("[Events] %s plunged the toilet"):format(player.Name))
			stopToilet(player) --// EASY: the channel hold just completed
		end
	end)

	print(("[Events] toilet ready at %s"):format(toilet.Part:GetFullName()))
	return true
end

----------------------------------------------------------------
-- THE EXTINGUISHER
-- Mirrors the plunger exactly: one exists, lives on its wall mount, and
-- returns the moment the fire ends or its carrier disappears. Deliberately
-- NOT counted by KitchenService's carry limit: that count filters on the
-- Ingredient and Dish attributes, and this tool has neither.
----------------------------------------------------------------
local extinguisherHolder = nil
local extinguisherTool = nil
local extinguisherMountPrompt = nil
local onExtinguisherActivated --// assigned in the grease-fire section below;
                              --// the tool connects its click to this

local function returnExtinguisher()
	if extinguisherTool then
		extinguisherTool:Destroy()
		extinguisherTool = nil
	end
	extinguisherHolder = nil

	if extinguisherMountPrompt then
		extinguisherMountPrompt.ActionText = "Take"
		extinguisherMountPrompt.ObjectText = "Extinguisher"
	end
end

local function setupExtinguisherMount()
	local mount = firstTaggedPart("ExtinguisherMount")
	if not mount then
		warn("[Events] no part tagged ExtinguisherMount - grease fires cannot be fought")
		return false
	end

	extinguisherMountPrompt = Instance.new("ProximityPrompt")
	extinguisherMountPrompt.Name = "TakeExtinguisher"
	extinguisherMountPrompt.ActionText = "Take"
	extinguisherMountPrompt.ObjectText = "Extinguisher"
	extinguisherMountPrompt.HoldDuration = Config.Kitchen.PickupHoldSeconds
	extinguisherMountPrompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	extinguisherMountPrompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	extinguisherMountPrompt.Parent = mount

	extinguisherMountPrompt.Triggered:Connect(function(player)
		local character = player.Character
		if not character then return end

		if extinguisherTool then
			extinguisherMountPrompt.ObjectText = "Extinguisher taken!"
			task.delay(1.5, function()
				if extinguisherMountPrompt and not extinguisherTool then
					extinguisherMountPrompt.ObjectText = "Extinguisher"
				end
			end)
			return
		end

		local tool = Instance.new("Tool")
		tool.Name = "Extinguisher"
		tool.RequiresHandle = true
		tool.CanBeDropped = false
		tool:SetAttribute("Extinguisher", true)

		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(0.9, 2.2, 0.9)
		handle.Color = Color3.fromRGB(200, 45, 45)
		handle.Material = Enum.Material.SmoothPlastic
		handle.Parent = tool

		local nozzle = Instance.new("Part")
		nozzle.Name = "Nozzle"
		nozzle.Size = Vector3.new(0.3, 0.6, 0.3)
		nozzle.Color = Color3.fromRGB(30, 30, 30)
		nozzle.Material = Enum.Material.SmoothPlastic
		nozzle.CanCollide = false
		nozzle.Massless = true
		nozzle.Parent = tool

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = nozzle
		weld.Parent = nozzle
		nozzle.CFrame = handle.CFrame * CFrame.new(0.4, 1.3, 0) * CFrame.Angles(0, 0, math.rad(-35))

		tool.Parent = character
		extinguisherTool = tool
		extinguisherHolder = player

		--// Left-click / tap / gamepad trigger = spray. The channel itself
		--// runs server-side in the heartbeat.
		tool.Activated:Connect(function()
			if onExtinguisherActivated then
				onExtinguisherActivated(player)
			end
		end)

		extinguisherMountPrompt.ObjectText = "Extinguisher taken!"
		print(("[Events] %s took the extinguisher"):format(player.Name))
	end)

	print(("[Events] extinguisher mount ready at %s"):format(mount:GetFullName()))
	return true
end

--// The extinguisher must never be lost with its carrier
Players.PlayerRemoving:Connect(function(player)
	if extinguisherHolder == player then
		returnExtinguisher()
		print("[Events] carrier left - extinguisher returned to the mount")
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function()
		if extinguisherHolder == player then
			returnExtinguisher()
			print("[Events] carrier died - extinguisher returned to the mount")
		end
	end)
end)

----------------------------------------------------------------
-- THE GREASE FIRE
-- A cook station ignites (its in-progress dish is destroyed) under ONE
-- big blaze covering the whole appliance, burns on a per-station fuse,
-- and when any fuse runs out every station within SpreadRadiusStuds of
-- any burning one catches too - chain spread is intended. The
-- extinguisher is the fix: ONE completed spray clears the ENTIRE fire
-- however far it spread (owner ruling, Aug 2026 - dousing station by
-- station dragged). Thrown water is an instant spread plus a lesson.
--
-- Stations are driven through ServerStorage.KitchenStationControl -
-- EventSystem never reaches into KitchenService's internals.
----------------------------------------------------------------
local FIRE = Config.Events.GreaseFire

local fire = {
	Active = false,
	Burning = {},        -- station Id -> burn record
	Count = 0,
	DrainAccum = 0,
	Dousing = nil,       -- the ONE shared spray channel { Player, Remaining, Total, Target }
	AlertOverride = nil, -- "<player> threw water..." wins the banner briefly
	AlertUntil = 0,
}

local function kitchenStations(...)
	local bridge = ServerStorage:FindFirstChild("KitchenStationControl")
	if not bridge then return nil end
	return bridge:Invoke(...)
end

local stopFire --// forward declared: the scheduler and heartbeat need it

local function fireAlertText()
	if fire.AlertOverride and os.clock() < fire.AlertUntil then
		return fire.AlertOverride
	end
	if fire.Count >= 2 then
		return ("%d stations ablaze - one good spray clears it all!"):format(fire.Count)
	end
	return "GREASE FIRE! Grab the extinguisher and CLICK the flames!"
end

--// The banner fuse is the SOONEST-to-spread fire
local function publishFire()
	local soonest, total = math.huge, 0
	for _, burn in pairs(fire.Burning) do
		if burn.Remaining < soonest then
			soonest, total = burn.Remaining, burn.Total
		end
	end
	if soonest == math.huge then
		soonest, total = 0, 0
	end
	publish("GreaseFire", "ERUPTING", math.max(0, soonest), total, fireAlertText())
end

--// Same attribute ServiceLoop stamps on the water pitcher Tool. Equipped
--// only: throwing water is a deliberate (mis)action, not a pocket check.
local function findHeldPitcher(player)
	local character = player.Character
	if not character then return nil end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("PitcherUses") ~= nil then
			return child
		end
	end
	return nil
end

local function showToast(message)
	EventState:SetAttribute("Toast", message)
	task.delay(FIRE.ToastSeconds, function()
		if EventState:GetAttribute("Toast") == message then
			EventState:SetAttribute("Toast", "")
		end
	end)
end

local function buildFireUi(part)
	local gui = Instance.new("BillboardGui")
	gui.Name = "FireAlert"
	gui.Size = UDim2.fromOffset(200, 56)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5.5, 0)
	gui.AlwaysOnTop = true
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.55)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.fromRGB(229, 72, 77)
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	label.TextStrokeTransparency = 0
	label.Text = "🔥 GREASE FIRE!"
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
	fill.BackgroundColor3 = Color3.fromRGB(245, 184, 65)
	fill.BorderSizePixel = 0
	fill.Parent = back

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	return gui, fill, label
end

local function refreshFireUi(burn)
	--// Someone is spraying: every burning station's bar becomes the one
	--// shared basil progress, and every spread fuse is on hold
	local douse = fire.Dousing
	if douse then
		burn.Label.Text = ("DOUSING... %ds"):format(math.max(0, math.ceil(douse.Remaining)))
		local progress = 1 - math.clamp(douse.Remaining / douse.Total, 0, 1)
		burn.Fill.Size = UDim2.fromScale(progress, 1)
		burn.Fill.BackgroundColor3 = Color3.fromRGB(76, 175, 109)
		return
	end

	burn.Label.Text = ("🔥 FIRE! %ds"):format(math.max(0, math.ceil(burn.Remaining)))
	local fraction = burn.Total > 0 and math.clamp(burn.Remaining / burn.Total, 0, 1) or 0
	burn.Fill.Size = UDim2.fromScale(fraction, 1)
	burn.Fill.BackgroundColor3 = fraction <= 0.5
		and Color3.fromRGB(229, 72, 77)
		or Color3.fromRGB(245, 184, 65)
end

local function clearBurnVisuals(burn)
	if burn.Gui then burn.Gui:Destroy() end
	if burn.Blaze then burn.Blaze:Destroy() end --// takes Fx/Light/Steam with it
	if burn.WaterPrompt then burn.WaterPrompt:Destroy() end
end

local igniteStation  --// forward declared: spreadFrom calls it
local igniteAppliance --// forward declared: spreadFrom calls this one too
                      --// (a plain local function below it would be invisible
                      --// to spreadFrom's compiled body - real crash, was live)

--// One fuse ran out (or water was thrown): every station within radius of
--// ANY burning station catches. The source keeps raging with a fresh fuse,
--// so it re-arms for stations that enter range later - future-proof for a
--// third station.
local function spreadFrom(sourceBurn, cause)
	local list = kitchenStations("List")
	if list then
		--// Targets are collected BEFORE any ignition: igniting while walking
		--// fire.Burning would mutate the table mid-iteration. It also means
		--// one spread moment doesn't chain instantly - a freshly caught
		--// station spreads on its OWN fuse, which is the intended pacing.
		local toIgnite = {}
		for _, entry in ipairs(list) do
			if not fire.Burning[entry.Id] then
				for _, burn in pairs(fire.Burning) do
					if (entry.Part.Position - burn.Part.Position).Magnitude <= FIRE.SpreadRadiusStuds then
						table.insert(toIgnite, entry)
						break
					end
				end
			end
		end

		--// Whatever catches brings its whole appliance with it
		for _, entry in ipairs(toIgnite) do
			igniteAppliance(entry, list)
		end
		if #toIgnite > 0 then
			print(("[Events] the fire spread to %d station(s) (%s)"):format(#toIgnite, cause))
		end
	end

	sourceBurn.Remaining = sourceBurn.Total
	publishFire()
end

--// Every station on the same physical appliance as this one, itself
--// included. Anchors with no Appliance name are alone.
local function applianceGroup(entry, list)
	local group = { entry }
	if not entry.Appliance or not list then
		return group
	end

	for _, other in ipairs(list) do
		if other.Id ~= entry.Id and other.Appliance == entry.Appliance then
			table.insert(group, other)
		end
	end
	return group
end

--// One stove catches all at once: three burners on one appliance is one
--// fire, not three that happen to be near each other.
igniteAppliance = function(entry, list)
	local group = applianceGroup(entry, list or kitchenStations("List"))
	for _, member in ipairs(group) do
		igniteStation(member)
	end
	return #group
end

igniteStation = function(entry)
	if fire.Burning[entry.Id] then return end
	local diff = difficultyBlock()
	local part = entry.Part

	--// The in-progress dish dies and the station stops taking orders
	kitchenStations("CancelCook", entry.Id)
	kitchenStations("SetDisabled", entry.Id, true)

	--// ONE big blaze: an invisible pad covering the whole appliance so the
	--// flames read as one fire engulfing the station, not a candle on the
	--// small anchor part
	local blaze = Instance.new("Part")
	blaze.Name = "GreaseBlaze"
	blaze.Size = Vector3.new(FIRE.BlazeCoverStuds, 1, FIRE.BlazeCoverStuds)
	blaze.CFrame = CFrame.new(part.Position + Vector3.new(0, 1, 0))
	blaze.Anchored = true
	blaze.CanCollide = false
	blaze.CanQuery = false
	blaze.CanTouch = false
	blaze.Transparency = 1
	blaze.Parent = workspace

	local fx = Instance.new("Fire")
	fx.Size = FIRE.FireSize
	fx.Heat = 12
	fx.Parent = blaze

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 140, 40)
	light.Range = FIRE.LightRange
	light.Brightness = 2
	light.Parent = blaze

	local gui, fill, label = buildFireUi(part)

	--// No extinguish prompt: putting a fire out is click-to-spray with the
	--// extinguisher equipped (see onExtinguisherActivated below)

	--// The trap. F like the water-pour at tables, so muscle memory walks
	--// straight into the lesson.
	local waterPrompt = Instance.new("ProximityPrompt")
	waterPrompt.Name = "ThrowWater"
	waterPrompt.ActionText = "Throw water"
	waterPrompt.ObjectText = "It might help...?"
	waterPrompt.KeyboardKeyCode = Enum.KeyCode.F
	waterPrompt.UIOffset = Vector2.new(0, 60)
	waterPrompt.HoldDuration = 0.4
	waterPrompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	waterPrompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	waterPrompt.Parent = part

	local burn = {
		Id = entry.Id,
		Method = entry.Method,
		Part = part,
		Total = diff.Consequences.FireSpreadSeconds,
		Remaining = diff.Consequences.FireSpreadSeconds,
		Gui = gui, Fill = fill, Label = label,
		Fx = fx, Light = light, Blaze = blaze,
		WaterPrompt = waterPrompt,
	}
	fire.Burning[entry.Id] = burn
	fire.Count += 1
	refreshFireUi(burn)

	--// Every station ablaze is the catastrophe this event threatens. EASY
	--// keeps its training wheels (rep drain only) - same shape as
	--// ToiletFloodEndsGame.
	local all = kitchenStations("List")
	if all and #all > 0 and fire.Count >= #all and diff.Consequences.FireBurnoutEndsGame then
		print("[Events] every station is burning - the kitchen is lost")
		local endBridge = ServerStorage:FindFirstChild("ForceEndShift")
		if endBridge then
			endBridge:Invoke("the kitchen burned down!")
		end
	end

	waterPrompt.Triggered:Connect(function(player)
		local active = fire.Burning[entry.Id]
		if not active then return end

		local pitcher = findHeldPitcher(player)
		if not pitcher or (pitcher:GetAttribute("PitcherUses") or 0) <= 0 then
			waterPrompt.ObjectText = "Need a filled pitcher!"
			task.delay(2, function()
				if fire.Burning[entry.Id] then
					waterPrompt.ObjectText = "It might help...?"
				end
			end)
			return
		end

		--// The lesson is the punishment: instant spread, no extra rep hit
		pitcher:SetAttribute("PitcherUses", 0)
		pitcher.Name = "Water Pitcher (0)"

		fire.AlertOverride = ("%s threw water on a grease fire!!"):format(player.Name)
		fire.AlertUntil = os.clock() + FIRE.ToastSeconds
		showToast(FIRE.WaterTrapMessage)
		eventStats.WaterIncidents += 1
		creditStat(player, "KitchenCrimes", 1) --// the permanent record (and
		                                       --// the hidden score's penalty)
		print(("[Events] %s threw water on the %s fire - it spreads!"):format(
			player.Name, active.Method))
		spreadFrom(active, "water!!")
	end)

	print(("[Events] the %s station is on fire - fuse %ds"):format(entry.Method, burn.Total))
end

--// Left-click / tap / gamepad trigger with the extinguisher equipped:
--// start THE spray - one shared channel aimed at the nearest flames that
--// clears the ENTIRE fire when it completes. It runs in the heartbeat;
--// walking away, dying, or unequipping cancels it, and every spread fuse
--// pauses while the spray is on.
onExtinguisherActivated = function(player)
	if not fire.Active then return end
	if fire.Dousing then return end --// one spray at a time
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local best, bestDist = nil, math.huge
	for _, burn in pairs(fire.Burning) do
		local dist = (burn.Part.Position - root.Position).Magnitude
		if dist <= FIRE.DouseRangeStuds and dist < bestDist then
			best, bestDist = burn, dist
		end
	end
	if not best then return end

	local diff = difficultyBlock()
	--// FIXER PASSIVE: the spray channel knows its player, so this one
	--// scales directly - no prompt trickery needed
	local channelSeconds = diff.ExtinguishChannelSeconds
		* (player:GetAttribute("ChannelMult") or 1)
	fire.Dousing = {
		Player = player,
		Remaining = channelSeconds,
		Total = channelSeconds,
		Target = best, --// range is held against these flames
	}

	--// Code-built spray: white steam billowing off EVERY burning station -
	--// the whole fire is dying together (the flames also shrink - heartbeat)
	for _, burn in pairs(fire.Burning) do
		if not burn.Steam then
			local steam = Instance.new("ParticleEmitter")
			steam.Name = "DouseSteam"
			steam.Color = ColorSequence.new(Color3.fromRGB(240, 240, 240))
			steam.Size = NumberSequence.new(2, 4)
			steam.Lifetime = NumberRange.new(0.6, 1.1)
			steam.Rate = 40
			steam.Speed = NumberRange.new(4, 7)
			steam.SpreadAngle = Vector2.new(35, 35)
			steam.Transparency = NumberSequence.new(0.3, 1)
			steam.Enabled = false
			steam.Parent = burn.Blaze
			burn.Steam = steam
		end
		burn.Steam.Enabled = true
	end

	print(("[Events] %s is spraying down the fire"):format(player.Name))
end

local function startFire()
	local list = kitchenStations("List")
	if not list or #list == 0 then
		warn("[Events] GreaseFire rolled but no cook stations exist - skipped")
		return
	end

	Sfx.Play("FireAlert")

	fire.Active = true
	fire.DrainAccum = 0
	fire.AlertOverride = nil

	--// Prefer a station mid-cook: grease + heat is the fiction, and losing
	--// the dish is the crueler, more memorable opening
	local busy = {}
	for _, entry in ipairs(list) do
		if entry.Busy then
			table.insert(busy, entry)
		end
	end
	local target = #busy > 0 and busy[math.random(#busy)] or list[math.random(#list)]

	local caught = igniteAppliance(target, list)
	publishFire()
	print(("[Events] grease fire started on the %s station (%d burner(s) alight)")
		:format(target.Method, caught))
end

stopFire = function(fixedBy)
	if not fire.Active then return end
	fire.Active = false

	for _, burn in pairs(fire.Burning) do
		clearBurnVisuals(burn)
	end
	fire.Burning = {}
	fire.Count = 0
	fire.DrainAccum = 0
	fire.Dousing = nil
	fire.AlertOverride = nil

	--// Defensive: EVERY station re-enabled no matter how the event died -
	--// a disabled station must never outlive its fire
	local list = kitchenStations("List")
	if list then
		for _, entry in ipairs(list) do
			kitchenStations("SetDisabled", entry.Id, false)
		end
	end

	returnExtinguisher()

	--// Stamp the scheduler gap directly (same reasoning as stopToilet)
	local elapsed = shiftInfo().Elapsed
	scheduler.LastEndedAt = elapsed
	scheduler.NextRollAt = elapsed + SCHEDULER.RollIntervalSeconds

	if fixedBy then
		applyRep(FIRE.FixRepReward, "fire extinguished")
		publish("", "", 0, 0, ("%s put out the fire!"):format(fixedBy.Name))
		task.delay(3, function()
			if not fire.Active and not toilet.Active then
				publish()
			end
		end)
	else
		publish()
	end

	print(("[Events] grease fire ended%s"):format(
		fixedBy and (" (last flame doused by " .. fixedBy.Name .. ")") or ""))
end

----------------------------------------------------------------
-- POWER OUTAGE
--
-- No fuse and no escalation: the darkness, the reputation bleed and the
-- faster-melting patience are the whole pressure. Cook stations deliberately
-- keep working - they are gas, and a second kitchen-disabling event on top of
-- the grease fire would be too cruel.
--
-- Lighting is snapshotted rather than assumed, so restore puts back exactly
-- what was there, including any light that was already switched off.
----------------------------------------------------------------
local Lighting = game:GetService("Lighting")

local outage = {
	Part = nil,
	Active = false,
	DrainAccum = 0,
	Lights = nil,     -- { {Light=, Enabled=}, ... }
	Sky = nil,        -- Lighting properties as they were
	Gui = nil,
	Prompt = nil,
}

local function snapshotAndDarken()
	local saved = {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight") then
			table.insert(saved, { Light = descendant, Enabled = descendant.Enabled })
			descendant.Enabled = false
		end
	end
	outage.Lights = saved

	outage.Sky = {
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		Brightness = Lighting.Brightness,
	}

	Lighting.Ambient = OUTAGE.DarkAmbient
	Lighting.OutdoorAmbient = OUTAGE.DarkOutdoorAmbient
	Lighting.Brightness = OUTAGE.DarkBrightness

	print(("[Events] power out - %d light(s) killed"):format(#saved))
end

local function restoreLighting()
	if outage.Lights then
		for _, entry in ipairs(outage.Lights) do
			--// The light may have been destroyed mid-outage
			if entry.Light.Parent then
				entry.Light.Enabled = entry.Enabled
			end
		end
		outage.Lights = nil
	end

	if outage.Sky then
		Lighting.Ambient = outage.Sky.Ambient
		Lighting.OutdoorAmbient = outage.Sky.OutdoorAmbient
		Lighting.Brightness = outage.Sky.Brightness
		outage.Sky = nil
	end
end

local function refreshOutageUi()
	if outage.Gui then
		outage.Gui.Enabled = outage.Active
	end
	if outage.Prompt then
		outage.Prompt.Enabled = outage.Active
		if outage.Active then
			local diffTable = difficultyBlock()
			if diffTable.Interactions and diffTable.Interactions.BreakerMinigame then
				--// Gated difficulties: a TAP opens the wire panel
				outage.Prompt.ActionText = "Fix the wires"
				outage.Prompt.HoldDuration = 0
			else
				--// ungated fallback: the original channel hold
				outage.Prompt.ActionText = "Restore power"
				local seconds = OUTAGE.FixChannelSeconds[
					Config.IsValidDifficulty(shiftInfo().Difficulty) and shiftInfo().Difficulty or "NORMAL"]
				outage.Prompt.HoldDuration = seconds or OUTAGE.FixChannelSeconds.NORMAL
			end
		end
	end
end

local stopOutage --// forward declared
local cancelWirePuzzle --// forward declared (wire-fix section, below stopOutage)
local beginWirePuzzle --// forward declared (same section)

local function startOutage()
	if outage.Active or not outage.Part then return end

	Sfx.Play("PowerAlert")

	outage.Active = true
	outage.DrainAccum = 0
	snapshotAndDarken()

	--// Seated bars drain faster while it is dark. ServiceLoop reads this.
	EventState:SetAttribute("PatienceMultiplier", OUTAGE.PatienceDrainMultiplier)

	--// The stoves die with the lights: KitchenService freezes every pan and
	--// refuses new cooks while this is true.
	EventState:SetAttribute("PowerOut", true)

	refreshOutageUi()
	publish("PowerOutage", "DARK", 0, 0,
		"The power is out! Someone get to the breaker box!")

	print("[Events] power outage started")
end

function stopOutage(fixedBy)
	--// Global relief beat: everyone was in the dark together
	if outage.Active then
		Sfx.Play("PowerRestored")
	end

	if not outage.Active then return end

	outage.Active = false
	outage.DrainAccum = 0
	if cancelWirePuzzle then
		cancelWirePuzzle() --// an open panel closes with the outage
	end
	restoreLighting()
	EventState:SetAttribute("PatienceMultiplier", 1)
	EventState:SetAttribute("PowerOut", false)
	refreshOutageUi()

	local elapsed = shiftInfo().Elapsed
	scheduler.LastEndedAt = elapsed
	scheduler.NextRollAt = elapsed + SCHEDULER.RollIntervalSeconds

	if fixedBy then
		applyRep(OUTAGE.FixRepReward, "power restored")
		eventStats.OutagesFixed += 1
		creditStat(fixedBy, "EventChannels", 1) --// the Fixer's career
		publish("", "", 0, 0, ("%s got the lights back on!"):format(fixedBy.Name))
		task.delay(3, function()
			if not outage.Active then publish() end
		end)
	else
		publish()
	end

	print(("[Events] power outage ended%s"):format(
		fixedBy and (" (fixed by " .. fixedBy.Name .. ")") or ""))
end

----------------------------------------------------------------
-- THE WIRE FIX (gated by Difficulty.Interactions.BreakerMinigame - the
-- first minigame under the EASY FREEZE). The server DEALS the shuffle
-- and CHECKS the answer; the client only renders and reports taps. One
-- solver holds the breaker at a time, the outage keeps draining while
-- they fumble, and every exit path unlocks. EASY never sees any of this.
----------------------------------------------------------------
local WIREFIX = Config.WireFix

local wireRemotes = ReplicatedStorage:FindFirstChild("Remotes")
if not wireRemotes then
	wireRemotes = Instance.new("Folder")
	wireRemotes.Name = "Remotes"
	wireRemotes.Parent = ReplicatedStorage
end

local wireRemote = wireRemotes:FindFirstChild("WireFixRemote")
if not wireRemote then
	wireRemote = Instance.new("RemoteEvent")
	wireRemote.Name = "WireFixRemote"
	wireRemote.Parent = wireRemotes
end

local wirePuzzle = nil --// { Player, RightSlots, Wires, Token }
local wireToken = 0

cancelWirePuzzle = function()
	if not wirePuzzle then return end
	local puzzle = wirePuzzle
	wirePuzzle = nil
	if puzzle.Player and puzzle.Player.Parent then
		wireRemote:FireClient(puzzle.Player, "Close", puzzle.Token)
	end
end

beginWirePuzzle = function(player)
	--// One electrician at a time
	if wirePuzzle then
		if wirePuzzle.Player ~= player and outage.Prompt then
			outage.Prompt.ObjectText = "Being fixed!"
			task.delay(1.5, function()
				if outage.Prompt and outage.Active then
					outage.Prompt.ObjectText = "Breaker box"
				end
			end)
		end
		return
	end

	local diffTable = difficultyBlock()
	local wires = (diffTable.Interactions and diffTable.Interactions.BreakerWires) or 4

	--// FIXER PASSIVE in minigame grammar: one fewer wire to match
	if player:GetAttribute("ClassKey") == "Fixer" then
		wires = math.max(WIREFIX.MinWires, wires - WIREFIX.FixerWireDiscount)
	end
	wires = math.min(wires, #WIREFIX.Colors)

	--// RightSlots[k] = which LEFT wire's colour sits in right slot k
	local rightSlots = {}
	for index = 1, wires do
		rightSlots[index] = index
	end
	for index = wires, 2, -1 do
		local swap = math.random(index)
		rightSlots[index], rightSlots[swap] = rightSlots[swap], rightSlots[index]
	end

	wireToken += 1
	wirePuzzle = {
		Player = player,
		RightSlots = rightSlots,
		Wires = wires,
		Token = wireToken,
	}

	wireRemote:FireClient(player, "Open", {
		Token = wireToken,
		Wires = wires,
		RightSlots = rightSlots, --// the colour layout IS the puzzle
		BreakerPosition = outage.Part and outage.Part.Position or Vector3.zero,
	})

	--// An abandoned panel must never deadlock the breaker
	local myToken = wireToken
	task.delay(WIREFIX.TimeoutSeconds, function()
		if wirePuzzle and wirePuzzle.Token == myToken then
			print("[Events] wire panel timed out - breaker unlocked")
			cancelWirePuzzle()
		end
	end)

	print(("[Events] %s opened the wire panel (%d wires)"):format(player.Name, wires))
end

wireRemote.OnServerEvent:Connect(function(player, action, token, answer)
	if action == "Abandon" then
		if wirePuzzle and wirePuzzle.Token == token and wirePuzzle.Player == player then
			cancelWirePuzzle()
		end
		return
	end
	if action ~= "Submit" then return end

	local puzzle = wirePuzzle
	if not puzzle or puzzle.Token ~= token or puzzle.Player ~= player then return end
	if not outage.Active then return end

	--// The server's own walk-away check (the client also closes itself)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not outage.Part
		or (root.Position - outage.Part.Position).Magnitude > WIREFIX.WalkAwayStuds + 6 then
		cancelWirePuzzle()
		return
	end

	--// THE CHECK: answer[leftIndex] = right slot. Every wire must land in
	--// the slot holding its own colour, each slot used exactly once.
	if type(answer) ~= "table" then return end
	local used = {}
	for leftIndex = 1, puzzle.Wires do
		local slot = tonumber(answer[leftIndex])
		if not slot or used[slot] or puzzle.RightSlots[slot] ~= leftIndex then
			wireRemote:FireClient(player, "Deny", puzzle.Token)
			return
		end
		used[slot] = true
	end

	--// Solved: exit through the SAME success path as EASY's hold -
	--// reward, career credit, charge and announcement all come free
	wirePuzzle = nil
	wireRemote:FireClient(player, "Close", puzzle.Token)
	print(("[Events] %s matched every wire - power restored"):format(player.Name))
	stopOutage(player)
end)

local function setupBreaker()
	outage.Part = firstTaggedPart("BreakerBox")
	if not outage.Part then
		warn("[Events] no part tagged BreakerBox - the power outage is disabled")
		return false
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "BreakerAlert"
	gui.Size = UDim2.fromOffset(120, 48)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.Parent = outage.Part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.fromRGB(255, 235, 120)
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	label.TextStrokeTransparency = 0
	label.Text = "!"
	label.Parent = gui

	outage.Gui = gui

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RestorePower"
	prompt.ActionText = "Restore power"
	prompt.ObjectText = "Breaker box"
	prompt.MaxActivationDistance = Config.Interaction.PromptRangeStuds
	prompt.RequiresLineOfSight = Config.Interaction.PromptRequiresLineOfSight
	prompt.Enabled = false
	prompt.Parent = outage.Part
	outage.Prompt = prompt

	--// FIXER PASSIVE: same per-player channel scaling as the plunge
	prompt.PromptButtonHoldBegan:Connect(function(player)
		local mult = player:GetAttribute("ChannelMult") or 1
		if mult ~= 1 and outage.Active then
			local diffName = Config.IsValidDifficulty(shiftInfo().Difficulty)
				and shiftInfo().Difficulty or "NORMAL"
			local seconds = OUTAGE.FixChannelSeconds[diffName] or OUTAGE.FixChannelSeconds.NORMAL
			prompt.HoldDuration = seconds * mult
		end
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		if outage.Active then
			refreshOutageUi()
		end
	end)

	--// No tool needed - the whole point is that anyone can run for it
	prompt.Triggered:Connect(function(player)
		if not outage.Active then return end
		local diffTable = difficultyBlock()
		if diffTable.Interactions and diffTable.Interactions.BreakerMinigame then
			beginWirePuzzle(player) --// gated: the tap opens the wire panel
		else
			stopOutage(player) --// EASY: the channel hold just completed
		end
	end)

	print(("[Events] breaker box ready at %s"):format(outage.Part:GetFullName()))
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

--// SPEED DIAL! bridge (the Fixer's ultimate): instantly resolves whatever
--// is active by calling the SAME success paths a hands-on fix uses -
--// cleanup, reward, career credit and announcement all come free.
--// False = nothing active = the caller must NOT consume the charge.
do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "ResolveActiveEvent"
	bridge.OnInvoke = function(player)
		if toilet.Active then
			stopToilet(player)
			return true
		elseif fire.Active then
			stopFire(player)
			return true
		elseif outage.Active then
			stopOutage(player)
			return true
		end
		return false, "No emergency right now!"
	end
	bridge.Parent = ServerStorage
end

--// FIX AUDIO. Each emergency has its own mini-game - tapping to plunge,
--// rewiring a breaker, spraying a fire - and each has several ways in and
--// several ways out (finished, walked away, died, event cancelled). Hooking
--// every one of those would leave a loop playing after a fix eventually.
--//
--// So this follows the SESSION instead. One place, and a loop can never
--// outlive the thing it belongs to.
local fixLoops = {}

local function syncFixLoop(key, active, soundName, part)
	local live = fixLoops[key]
	if active and part and not live then
		fixLoops[key] = Sfx.Loop(soundName, part)
	elseif (not active or not part) and live then
		live:Stop()
		fixLoops[key] = nil
	end
end

RunService.Heartbeat:Connect(function(dt)
	--// Positional: you hear the work where the work is happening.
	--// (No breaker loop - owner ruling: the wire fix sounds per wire
	--// CONNECTION, client-side in WireFixClient.)
	syncFixLoop("Toilet", plungeSession ~= nil, "ToiletFix", toilet.Part)
	syncFixLoop("Fire", fire.Dousing ~= nil, "FireExtinguish",
		fire.Dousing and fire.Dousing.Target and fire.Dousing.Target.Part or nil)

	local info = shiftInfo()

	--// Fresh shift, fresh report counters
	if info.State ~= lastShiftState then
		if info.State == "RUNNING" then
			for key in pairs(eventStats) do
				eventStats[key] = 0
			end
		end
		lastShiftState = info.State
	end

	--// Nothing runs outside a live shift, and anything mid-flight is cleared
	if info.State ~= "RUNNING" then
		if toilet.Active then
			stopToilet(nil)
		end
		if fire.Active then
			stopFire(nil)
		end
		if outage.Active then
			stopOutage(nil)
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

	--// Tick the outage: no fuse, just a steady bleed until someone fixes it
	if outage.Active then
		outage.DrainAccum += dt
		if outage.DrainAccum >= 10 then
			outage.DrainAccum -= 10
			applyRep(-OUTAGE.RepDrainPer10s, "power outage")
		end
	end

	--// Tick the fire: ONE shared spray channel fights the whole blaze,
	--// and every spread fuse pauses while it runs. No sprayer = the
	--// fuses burn down toward spread.
	if fire.Active then
		local douse = fire.Dousing
		if douse then
			--// Cancel if the sprayer let go of the tool, died, or wandered
			--// from the flames they aimed at; finish = the WHOLE fire out
			local character = douse.Player and douse.Player.Character
			local holding = character and extinguisherTool
				and extinguisherTool.Parent == character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local inRange = root and douse.Target
				and (douse.Target.Part.Position - root.Position).Magnitude <= FIRE.DouseRangeStuds

			if not (holding and inRange) then
				fire.Dousing = nil
				for _, burn in pairs(fire.Burning) do
					if burn.Steam then burn.Steam.Enabled = false end
					if burn.Fx then burn.Fx.Size = FIRE.FireSize end
				end
			else
				douse.Remaining -= dt
				--// Every flame in the kitchen dies back together
				local shrunk = math.max(2,
					FIRE.FireSize * math.clamp(douse.Remaining / douse.Total, 0, 1))
				for _, burn in pairs(fire.Burning) do
					if burn.Fx then burn.Fx.Size = shrunk end
				end
				if douse.Remaining <= 0 then
					eventStats.FiresExtinguished += 1
					creditStat(douse.Player, "EventChannels", 1) --// the Fixer's career
					print(("[Events] %s sprayed the fire out"):format(douse.Player.Name))
					stopFire(douse.Player)
				end
			end
		else
			local expired = nil
			for _, burn in pairs(fire.Burning) do
				burn.Remaining -= dt
				if burn.Remaining <= 0 then
					expired = expired or {}
					table.insert(expired, burn)
				end
			end
			if expired then
				for _, burn in ipairs(expired) do
					if fire.Active and fire.Burning[burn.Id] then
						spreadFrom(burn, "the fuse ran out")
					end
				end
			end
		end
	end

	--// The spray may have just ended the event - everything below is
	--// live-fire bookkeeping only
	if fire.Active then
		local soonest = math.huge
		for _, burn in pairs(fire.Burning) do
			refreshFireUi(burn)
			if burn.Remaining < soonest then
				soonest = burn.Remaining
			end
		end
		if soonest < math.huge then
			EventState:SetAttribute("FuseRemaining", math.max(0, soonest))
		end

		--// Each burning station bleeds reputation independently
		fire.DrainAccum += dt
		if fire.DrainAccum >= 10 then
			fire.DrainAccum -= 10
			if fire.Count > 0 then
				applyRep(-FIRE.RepDrainPer10sPerFire * fire.Count, "kitchen on fire")
			end
		end

		--// Let the "<player> threw water" banner line expire back to normal
		if fire.AlertOverride and os.clock() >= fire.AlertUntil then
			fire.AlertOverride = nil
			publishFire()
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

	--// GreaseFire needs its mount AND the kitchen's station bridge. The
	--// bridge appears when KitchenService boots; give it a moment.
	local hasMount = setupExtinguisherMount()
	local bridgeWaited = 0
	while not ServerStorage:FindFirstChild("KitchenStationControl") and bridgeWaited < 10 do
		task.wait(0.5)
		bridgeWaited += 0.5
	end

	if hasMount and ServerStorage:FindFirstChild("KitchenStationControl") then
		registerEvent("GreaseFire", {
			Start = startFire,
			Stop = function() stopFire(nil) end,
			IsActive = function() return fire.Active end,
		})
	elseif hasMount then
		warn("[Events] GreaseFire not registered - KitchenStationControl bridge never appeared")
	end

	if setupBreaker() then
		registerEvent("PowerOutage", {
			Start = startOutage,
			Stop = function() stopOutage(nil) end,
			IsActive = function() return outage.Active end,
		})
	end

	local names = {}
	for name in pairs(EVENTS) do
		table.insert(names, name)
	end
	print(("[Events] %d event(s) registered: %s"):format(
		#names, #names > 0 and table.concat(names, ", ") or "none"))
end)

