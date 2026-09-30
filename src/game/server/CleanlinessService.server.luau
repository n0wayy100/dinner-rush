--[[
	Dinner Rush - CleanlinessService
	ServerScriptService.Server.CleanlinessService  (Script)

	Owns the TIDINESS bar (Sep 27 2026): a shared cleanliness meter that drips
	down over the shift and from messes, and that players raise by cleaning GRIME
	spots (vacuum). The Health Inspector event judges it (Phase 2). Server-
	authoritative: grime is cleaned via a server-handled ProximityPrompt.

	Publishes to ShiftState:
	  Tidiness, TidinessMax   - drives the HUD tidiness bar (HudClient)

	Exposes ServerStorage bridges (BindableFunctions) for events + mechanics:
	  AdjustTidiness(delta, why)  - nudge the bar (e.g. a customer dirties the
	                                restroom, the inspector's clean bonus)
	  GetTidiness()               - read { Value, Max, Fraction } (the inspector)

	Only the passive drip / grime spawn are DEMAND (difficulty-scaled). The clean
	action's power (Config.Tidiness.CleanRestore) is FLAT - THE LAW holds.
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local TID = Config.Tidiness

local ShiftState = ReplicatedStorage:WaitForChild("ShiftState")

--// ---- shift info (shared bridge, same one EventSystem reads) --------------
local function shiftInfo()
	local bridge = ServerStorage:FindFirstChild("GetShiftInfo")
	if not bridge then
		return { State = "WAITING", Elapsed = 0, Difficulty = "NORMAL" }
	end
	return bridge:Invoke()
end

local function difficultyName()
	local name = shiftInfo().Difficulty
	return Config.IsValidDifficulty(name) and name or "NORMAL"
end

--// per-difficulty DEMAND number out of a { EASY=, NORMAL=, HARD= } table
local function demand(tbl, fallback)
	if type(tbl) ~= "table" then return fallback end
	return tbl[difficultyName()] or fallback
end

--// ---- state ----------------------------------------------------------------
local tidiness = TID.Start
local grimeSpots = {}   --// list of the grime Parts currently on the floor
local poopMess = nil    --// the single poop-in-the-toilet mess, or nil
local generation = 0    --// bumped each RUNNING so old loops die
local tidinessEnded = false --// once the inspector has judged, the challenge is
                            --// over for the shift: bar hides, grime stops

local function publish()
	ShiftState:SetAttribute("Tidiness", tidiness)
	ShiftState:SetAttribute("TidinessMax", TID.Max)
	ShiftState:SetAttribute("TidinessActive", not tidinessEnded)
end
publish()

local function adjust(delta, why)
	local before = tidiness
	tidiness = math.clamp(tidiness + delta, 0, TID.Max)
	if tidiness ~= before then
		publish()
		if math.abs(delta) >= 1 then
			print(("[Tidiness] %+d (%s) -> %d"):format(
				math.floor(delta), tostring(why or "?"), math.floor(tidiness)))
		end
	end
end

--// ---- THE VACUUM (a fetch tool, like the Spill's broom) --------------------
--// Players grab a vacuum from the tagged VacuumMount and clean grime with it.
--// Owner may drop a custom PARTS-BUILT Tool named "VacuumTool" into
--// ServerStorage (no Toolbox); otherwise a parts vacuum is code-built.
local Players = game:GetService("Players")
local vacuumTools = {} --// player -> their vacuum Tool

local function buildVacuumTool()
	--// owner-provided template wins (must be a parts-built Tool)
	local template = ServerStorage:FindFirstChild("VacuumTool")
	if template and template:IsA("Tool") then
		local clone = template:Clone()
		clone.Name = "Vacuum"
		clone.CanBeDropped = false
		clone:SetAttribute("Vacuum", true)
		return clone
	end

	--// code-built parts vacuum: a wand handle + nozzle + a red canister
	local tool = Instance.new("Tool")
	tool.Name = "Vacuum"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute("Vacuum", true)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.6, 3, 0.6)
	handle.Color = Color3.fromRGB(60, 60, 70)
	handle.Material = Enum.Material.SmoothPlastic
	handle.Parent = tool

	local nozzle = Instance.new("Part")
	nozzle.Name = "Nozzle"
	nozzle.Size = Vector3.new(1.2, 0.5, 0.9)
	nozzle.Color = Color3.fromRGB(40, 40, 48)
	nozzle.Material = Enum.Material.SmoothPlastic
	nozzle.CanCollide = false
	nozzle.Massless = true
	nozzle.Parent = tool
	local nw = Instance.new("WeldConstraint")
	nw.Part0 = handle ; nw.Part1 = nozzle ; nw.Parent = nozzle
	nozzle.CFrame = handle.CFrame * CFrame.new(0, -1.6, 0)

	local body = Instance.new("Part")
	body.Name = "Canister"
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(2, 1.4, 1.4)
	body.Color = Color3.fromRGB(229, 72, 77) --// tomato-red canister
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.Massless = true
	body.Parent = tool
	local bw = Instance.new("WeldConstraint")
	bw.Part0 = handle ; bw.Part1 = body ; bw.Parent = body
	body.CFrame = handle.CFrame * CFrame.new(0.9, 1.4, 0) * CFrame.Angles(0, 0, math.rad(90))

	return tool
end

local function returnVacuumFor(player)
	local tool = vacuumTools[player]
	if tool then
		tool:Destroy()
		vacuumTools[player] = nil
	end
end

local function holdingVacuum(player)
	local char = player and player.Character
	if not char then return false end
	local tool = char:FindFirstChildOfClass("Tool")
	return tool ~= nil and tool:GetAttribute("Vacuum") == true
end

local function giveVacuumTo(player)
	local character = player.Character
	if not character then return end
	if holdingVacuum(player) then return end
	returnVacuumFor(player)
	local tool = buildVacuumTool()
	tool.Parent = character
	vacuumTools[player] = tool
	print(("[Tidiness] %s grabbed the vacuum"):format(player.Name))
end

local function setupVacuumMount()
	local mount = nil
	for _, inst in ipairs(CollectionService:GetTagged("VacuumMount")) do
		if inst:IsDescendantOf(workspace) then
			mount = (inst:IsA("BasePart") and inst)
				or (inst:IsA("Model") and (inst.PrimaryPart
					or inst:FindFirstChildWhichIsA("BasePart", true)))
			if mount then break end
		end
	end
	if not mount then
		warn("[Tidiness] no part tagged VacuumMount - players cannot grab a vacuum")
		return false
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TakeVacuum"
	prompt.ActionText = "Take"
	prompt.ObjectText = "Vacuum"
	prompt.HoldDuration = (Config.Kitchen and Config.Kitchen.PickupHoldSeconds) or 0
	prompt.MaxActivationDistance = (Config.Interaction and Config.Interaction.PromptRangeStuds) or 10
	prompt.RequiresLineOfSight = (Config.Interaction and Config.Interaction.PromptRequiresLineOfSight) or false
	prompt.Parent = mount
	prompt.Triggered:Connect(function(player)
		giveVacuumTo(player)
	end)
	print(("[Tidiness] vacuum mount ready at %s"):format(mount:GetFullName()))
	return true
end

Players.PlayerRemoving:Connect(returnVacuumFor)
Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function() returnVacuumFor(player) end)
end)

--// ---- grime spots -----------------------------------------------------------
local function tables()
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged("Table")) do
		if inst:IsDescendantOf(workspace) then
			local part = (inst:IsA("BasePart") and inst)
				or (inst:IsA("Model") and (inst.PrimaryPart
					or inst:FindFirstChildWhichIsA("BasePart", true)))
			if part then table.insert(out, part) end
		end
	end
	return out
end

local function removeGrime(part)
	for i, g in ipairs(grimeSpots) do
		if g == part then table.remove(grimeSpots, i) break end
	end
	if part then part:Destroy() end
end

--// score-only signal (unmapped in Config.Score, so it awards nothing today -
--// it is here so the tutorial's AddScore-bus watcher can count a clean, and so
--// a future "tidy" score/stat is a one-line Config addition, not a rewire).
local function creditClean(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local bus = ServerStorage:FindFirstChild("AddScore")
	if bus then bus:Fire(player, "GrimeCleaned", 1) end
end

local function cleanGrime(part, player)
	removeGrime(part)
	adjust(TID.CleanRestore, ("%s vacuumed grime"):format(player and player.Name or "?"))
	creditClean(player)
end

--// ---- DUST cleaning via the VACUUM HOVER minigame (owner spec Sep 27) -------
--// Unique to the vacuum (not the Spill's drag-broom): the panel scatters dust
--// specks at random spots and you HOVER the nozzle over each to suck it up. The
--// SERVER deals the count and validates each suck (vacuum in hand, in range,
--// rate-capped); DustVacuumClient renders the panel and reports sucks.
local vacuumRemote do
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	vacuumRemote = remotes:FindFirstChild("VacuumRemote")
	if not vacuumRemote then
		vacuumRemote = Instance.new("RemoteEvent")
		vacuumRemote.Name = "VacuumRemote"
		vacuumRemote.Parent = remotes
	end
end

local dustSession = nil --// { Player, Grime, Sucked, Needed, LastAt, Token }
local dustToken = 0

local function cancelDust()
	if not dustSession then return end
	local s = dustSession
	dustSession = nil
	if s.Player and s.Player.Parent then
		vacuumRemote:FireClient(s.Player, "Close", s.Token, false)
	end
end

local function beginDustVacuum(player, grime)
	if dustSession then return end --// one at a time
	local needed = math.max(1, math.ceil(
		(TID.DustSpecks or 6) * (player:GetAttribute("ChannelMult") or 1)))
	dustToken += 1
	local token = dustToken
	dustSession = {
		Player = player, Grime = grime, Sucked = 0,
		Needed = needed, LastAt = 0, Token = token,
	}
	vacuumRemote:FireClient(player, "Open", { Token = token, DustCount = needed })
	local myToken = token
	task.delay(TID.DustTimeoutSeconds or 20, function()
		if dustSession and dustSession.Token == myToken then
			cancelDust()
		end
	end)
end

vacuumRemote.OnServerEvent:Connect(function(player, action, token)
	local s = dustSession
	if not s or s.Token ~= token or s.Player ~= player then return end
	if action == "Abandon" then cancelDust() return end
	if action ~= "Suck" then return end

	local grime = s.Grime
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not grime or not grime.Parent or not holdingVacuum(player) or not root
		or (root.Position - grime.Position).Magnitude > (TID.DustWalkAwayStuds or 14) then
		cancelDust()
		return
	end

	--// each Suck is hover-gated to one-per-speck client-side, so no rate cap is
	--// needed (and a cap could drop a legit fast suck and hang the panel). The
	--// vacuum-in-hand + proximity re-check above is the real validation.
	s.Sucked += 1

	if s.Sucked >= s.Needed then
		dustSession = nil
		vacuumRemote:FireClient(player, "Close", token, true)
		cleanGrime(grime, player)
		return
	end
	vacuumRemote:FireClient(player, "Progress", token, s.Sucked / s.Needed)
end)

--// build one grime splat near a random table, on the floor
local function spawnGrime()
	local tbls = tables()
	if #tbls == 0 then return end
	local anchor = tbls[math.random(#tbls)]

	--// random horizontal offset from the table, dropped to the floor
	local ang = math.random() * math.pi * 2
	local dist = 3 + math.random() * TID.GrimeOffsetStuds
	local from = anchor.Position + Vector3.new(math.cos(ang) * dist, 3, math.sin(ang) * dist)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { anchor }
	local hit = workspace:Raycast(from, Vector3.new(0, -20, 0), rp)
	local pos = hit and (hit.Position + Vector3.new(0, 0.05, 0))
		or (anchor.Position + Vector3.new(math.cos(ang) * dist, -2.5, math.sin(ang) * dist))

	local grime = Instance.new("Part")
	grime.Name = "GrimeSpot"
	grime.Shape = Enum.PartType.Cylinder
	grime.Size = Vector3.new(0.15, 2.6, 2.6)
	grime.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	grime.Anchored = true
	grime.CanCollide = false
	grime.CanQuery = true      --// clickable/hit-testable for future tools
	grime.Material = Enum.Material.SmoothPlastic
	grime.Color = Color3.fromRGB(96, 82, 60)   --// muddy grime
	grime.Transparency = 0.15
	grime.Parent = workspace

	--// a little floating cue so players can spot it
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "GrimeCue"
	billboard.Size = UDim2.fromScale(1.6, 1.6)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = grime
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "🧹"
	label.Parent = billboard

	--// server-handled clean prompt (E, press - owner ruling: E means press)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CleanGrime"
	prompt.ActionText = "Vacuum"
	prompt.ObjectText = "Grime"
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = (Config.Interaction and Config.Interaction.PromptRangeStuds) or 10
	prompt.Parent = grime
	prompt.Triggered:Connect(function(player)
		if not holdingVacuum(player) then
			prompt.ObjectText = "Grab the vacuum!"
			task.delay(1.2, function()
				if prompt.Parent then prompt.ObjectText = "Grime" end
			end)
			return
		end
		if grime.Parent then beginDustVacuum(player, grime) end --// opens the vacuum panel
	end)

	table.insert(grimeSpots, grime)
	adjust(-TID.GrimeDropOnSpawn, "grime appeared")
end

local function clearAllGrime()
	for _, g in ipairs(grimeSpots) do
		if g then g:Destroy() end
	end
	grimeSpots = {}
	if poopMess then poopMess:Destroy() poopMess = nil end
end

--// ---- POOP in the toilet, cleaned via the PLUNGE TAP minigame (owner spec) --
--// Ambient like grime: a poop appears in the toilet during the tidiness phase
--// (never while the toilet-overflow EVENT runs). Grab the plunger and TAP to
--// clear it - reuses the toilet's PlungeClient panel via PlungeRemote, with
--// STRING tokens so it never clashes with the real toilet fix on the shared
--// remote.
local PLUNGE = Config.PlungeTap or {}

local function firstToilet()
	for _, inst in ipairs(CollectionService:GetTagged("Toilet")) do
		if inst:IsDescendantOf(workspace) then
			if inst:IsA("BasePart") then return inst end
			if inst:IsA("Model") then
				return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	return nil
end

local function toiletEventActive()
	local es = ReplicatedStorage:FindFirstChild("EventState")
	return es ~= nil and es:GetAttribute("ActiveEvent") == "ToiletEmergency"
end

local function holdingPlunger(player)
	local char = player and player.Character
	if not char then return false end
	local tool = char:FindFirstChildOfClass("Tool")
	return tool ~= nil and tool:GetAttribute("Plunger") == true
end

--// take the player's plunger away (character + backpack). EventSystem hands out
--// a fresh one from the mount when it is next needed, so destroying it here is
--// safe - its plungerTools record just points at a gone tool.
local function removePlunger(player)
	local char = player and player.Character
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	for _, container in ipairs({ char, backpack }) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and child:GetAttribute("Plunger") then
					child:Destroy()
				end
			end
		end
	end
end

local function cleanPoop(player)
	if poopMess then poopMess:Destroy() poopMess = nil end
	removePlunger(player) --// the plunger is spent once the poop is cleared
	adjust(TID.PoopCleanRestore or (TID.CleanRestore * 1.5),
		("%s plunged the toilet"):format(player and player.Name or "?"))
end

--// plunge session for the poop (reuses PlungeRemote)
local plungeRemote = nil
local poopSession = nil
local poopToken = 0

local function cancelPoop()
	if not poopSession then return end
	local s = poopSession
	poopSession = nil
	if plungeRemote and s.Player and s.Player.Parent then
		plungeRemote:FireClient(s.Player, "Close", s.Token, false)
	end
end

local function beginPoopPlunge(player)
	if poopSession or not poopMess or not plungeRemote then return end
	local needed = math.max(1, math.ceil(
		(PLUNGE.TapsToFill or 12) * (player:GetAttribute("ChannelMult") or 1)))
	poopToken += 1
	local token = "poop-" .. poopToken
	poopSession = {
		Player = player, Fill = 0, Needed = needed, LastAt = os.clock(), Token = token,
	}
	local toilet = firstToilet()
	plungeRemote:FireClient(player, "Open", {
		Token = token,
		FillPerTap = 1 / needed,
		ToiletPosition = (toilet and toilet.Position) or Vector3.zero,
	})
	local myToken = token
	task.delay(PLUNGE.TimeoutSeconds or 20, function()
		if poopSession and poopSession.Token == myToken then cancelPoop() end
	end)
end

task.spawn(function()
	local rem = ReplicatedStorage:WaitForChild("Remotes", 20)
	plungeRemote = rem and rem:WaitForChild("PlungeRemote", 20)
	if not plungeRemote then
		warn("[Tidiness] no PlungeRemote - poop cannot be cleaned")
		return
	end
	plungeRemote.OnServerEvent:Connect(function(player, action, token)
		local s = poopSession
		if not s or s.Token ~= token or s.Player ~= player then return end --// not ours
		if action == "Abandon" then cancelPoop() return end
		if action ~= "Tap" then return end

		local toilet = firstToilet()
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not poopMess or not holdingPlunger(player) or not root or not toilet
			or (root.Position - toilet.Position).Magnitude > (PLUNGE.WalkAwayStuds or 10) + 6 then
			cancelPoop()
			return
		end

		--// bar decays while idle; each tap pushes it back up (rate-capped)
		local now = os.clock()
		local since = now - s.LastAt
		if since < 1 / (PLUNGE.MaxTapsPerSecond or 10) then return end
		s.Fill = math.max(0, s.Fill - (PLUNGE.DecayPerSecond or 0.1) * since)
		s.Fill += 1 / s.Needed
		s.LastAt = now

		if s.Fill >= 1 then
			poopSession = nil
			plungeRemote:FireClient(player, "Close", token, true)
			cleanPoop(player)
			return
		end
		plungeRemote:FireClient(player, "Progress", token, s.Fill)
	end)
end)

--// build the poop mess sitting in the toilet, with a plunge prompt
local function spawnPoop()
	if poopMess or toiletEventActive() then return end
	local toilet = firstToilet()
	if not toilet then return end

	local model = Instance.new("Model")
	model.Name = "PoopMess"

	local base = Instance.new("Part")
	base.Name = "Poop"
	base.Shape = Enum.PartType.Ball
	base.Size = Vector3.new(1.2, 0.9, 1.2)
	base.Color = Color3.fromRGB(90, 58, 30)
	base.Material = Enum.Material.SmoothPlastic
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = true
	base.CFrame = CFrame.new(toilet.Position + Vector3.new(0, 1.1, 0))
	base.Parent = model
	model.PrimaryPart = base

	local top = Instance.new("Part")
	top.Name = "PoopTop"
	top.Shape = Enum.PartType.Ball
	top.Size = Vector3.new(0.8, 0.6, 0.8)
	top.Color = Color3.fromRGB(102, 66, 36)
	top.Material = Enum.Material.SmoothPlastic
	top.Anchored = true
	top.CanCollide = false
	top.CanQuery = false
	top.CFrame = base.CFrame * CFrame.new(0, 0.6, 0)
	top.Parent = model

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PoopCue"
	billboard.Size = UDim2.fromScale(2, 2)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = base
	billboard.Parent = base
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.FredokaOne
	lbl.TextScaled = true
	lbl.Text = "💩"
	lbl.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PlungePoop"
	prompt.ActionText = "Plunge"
	prompt.ObjectText = "Poop"
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = (Config.Interaction and Config.Interaction.PromptRangeStuds) or 10
	prompt.Parent = base
	prompt.Triggered:Connect(function(player)
		if not holdingPlunger(player) then
			prompt.ObjectText = "Grab the plunger!"
			task.delay(1.2, function()
				if prompt.Parent then prompt.ObjectText = "Poop" end
			end)
			return
		end
		if poopMess then beginPoopPlunge(player) end
	end)

	model.Parent = workspace
	poopMess = model
	adjust(-(TID.PoopDropOnSpawn or 6), "poop appeared")
end

--// ---- bridges (events + mechanics talk to the bar through these) -----------
do
	local adjustBridge = Instance.new("BindableFunction")
	adjustBridge.Name = "AdjustTidiness"
	adjustBridge.OnInvoke = function(delta, why)
		adjust(tonumber(delta) or 0, why)
		return tidiness
	end
	adjustBridge.Parent = ServerStorage

	local getBridge = Instance.new("BindableFunction")
	getBridge.Name = "GetTidiness"
	getBridge.OnInvoke = function()
		return {
			Value = tidiness,
			Max = TID.Max,
			Fraction = TID.Max > 0 and (tidiness / TID.Max) or 0,
		}
	end
	getBridge.Parent = ServerStorage

	--// GRIME CONTROL: the Health Inspector event dumps a batch of grime on
	--// arrival, counts what is left at the verdict, and clears it (SPEED DIAL /
	--// event end). SpawnBatch ignores the ambient cap - it is a special mess.
	local grimeBridge = Instance.new("BindableFunction")
	grimeBridge.Name = "GrimeControl"
	grimeBridge.OnInvoke = function(action, n)
		if action == "SpawnBatch" then
			for _ = 1, math.max(tonumber(n) or 1, 0) do
				spawnGrime()
			end
			return #grimeSpots
		elseif action == "Count" then
			return #grimeSpots
		elseif action == "ClearAll" then
			clearAllGrime()
			return true
		elseif action == "Stop" then
			--// the inspection is over: end the tidiness challenge for the shift
			--// (bar hides via TidinessActive, grime + drip loops go quiet)
			tidinessEnded = true
			clearAllGrime()
			publish()
			return true
		end
		return false
	end
	grimeBridge.Parent = ServerStorage
end

--// ---- lifecycle: run the drip + grime loops through a RUNNING shift --------
local function tutorialMode()
	return workspace:GetAttribute("MatchMode") == "TUTORIAL"
end

local function startShift()
	generation += 1
	local myGen = generation
	tidiness = TID.Start
	tidinessEnded = false --// fresh shift, the tidiness challenge is back on
	clearAllGrime()
	publish()

	--// the tutorial freezes the shift to teach one loop - never dirty it there
	if tutorialMode() then return end

	--// passive ambient drip (stops once the inspection ends the challenge)
	task.spawn(function()
		while generation == myGen do
			task.wait(1)
			if generation ~= myGen then break end
			local state = ShiftState:GetAttribute("State")
			if not tidinessEnded and (state == "RUNNING" or state == "CLOSING") then
				adjust(-demand(TID.DripPerSecond, 0.25), "ambient drip")
			end
		end
	end)

	--// grime spawns (stops once the inspection ends the challenge)
	task.spawn(function()
		while generation == myGen do
			task.wait(demand(TID.GrimeSpawnEverySeconds, 15))
			if generation ~= myGen then break end
			local state = ShiftState:GetAttribute("State")
			if not tidinessEnded and (state == "RUNNING" or state == "CLOSING") then
				if #grimeSpots < TID.MaxGrimeSpots then
					spawnGrime()
				end
				--// occasionally a poop appears in the toilet (spawnPoop self-
				--// guards against an existing poop / the toilet-overflow event)
				if math.random() < (TID.PoopChance or 0.3) then
					spawnPoop()
				end
			end
		end
	end)
end

local function endShift()
	generation += 1  --// kills the loops
	clearAllGrime()
end

if TID.Enabled then
	ShiftState:GetAttributeChangedSignal("State"):Connect(function()
		local state = ShiftState:GetAttribute("State")
		if state == "RUNNING" then
			startShift()
		elseif state == "ENDED" or state == "WAITING" then
			endShift()
		end
	end)
	setupVacuumMount() --// owner places a VacuumMount tag; grime needs the vacuum
	--// in case the shift is already RUNNING when this boots
	if ShiftState:GetAttribute("State") == "RUNNING" then
		startShift()
	end
	print("[Tidiness] CleanlinessService ready")
end
