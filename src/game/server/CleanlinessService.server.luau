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

	AFTER THE INSPECTION (Sep 30 2026): the bar hides and poop stops, but grime
	keeps spawning (slower) and marks its table Dirty - ServiceLoop drains the
	seated party there faster. Every clean credits MessesCleaned (career +
	charge + hidden score).

	THE JANITOR (Sep 30 2026) works through three more bridges:
	  JanitorQuickSweep(player, range)          - Q: nearest mess, gone
	  JanitorGuardZone(player, skillDef)        - R: caution cone + ring
	  JanitorBufferStart(player, seconds, radius) - ultimate: clean on contact
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MinigameIntro = require(ServerStorage:WaitForChild("Shared"):WaitForChild("MinigameIntro"))
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
local tidinessEnded = false --// once the inspector has judged, the BAR is over
                            --// for the shift: it hides and poop stops - but
                            --// grime keeps coming as DIRTY TABLES (Sep 30 2026)

--// JANITOR state (Sep 30 2026)
local guardZones = {}       --// [player] = { Position, Radius, CancelChance, Model }
local poopDeferred = false  --// a poop that rolled "survive" inside a guarded
                            --// zone - it appears once the toilet is unguarded

--// the guarded zone covering a world position (flat distance), or nil
local function guardZoneAt(pos)
	for _, zone in pairs(guardZones) do
		local flat = Vector3.new(pos.X - zone.Position.X, 0, pos.Z - zone.Position.Z)
		if flat.Magnitude <= zone.Radius then
			return zone
		end
	end
	return nil
end

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
--// the tagged tables: anchor part (where grime splats) + TableId (which table
--// the grime makes dirty)
local function tableEntries()
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged("Table")) do
		if inst:IsDescendantOf(workspace) then
			local part = (inst:IsA("BasePart") and inst)
				or (inst:IsA("Model") and (inst.PrimaryPart
					or inst:FindFirstChildWhichIsA("BasePart", true)))
			if part then
				table.insert(out, { Part = part, Inst = inst, Id = inst:GetAttribute("TableId") })
			end
		end
	end
	return out
end

--// DIRTY TABLES (Sep 30 2026): after the inspection, a table with grime next
--// to it is marked Dirty (attribute on the tagged Table). ServiceLoop drains
--// the seated party there faster and shows the gross face. Before the
--// inspection nothing is ever dirty - the bar is the stake then.
local function refreshDirty()
	local dirty = {}
	if tidinessEnded then
		for _, g in ipairs(grimeSpots) do
			local id = g:GetAttribute("NearTable")
			if id ~= nil then dirty[id] = true end
		end
	end
	for _, entry in ipairs(tableEntries()) do
		if entry.Id ~= nil then
			local want = dirty[entry.Id] == true
			if (entry.Inst:GetAttribute("Dirty") == true) ~= want then
				entry.Inst:SetAttribute("Dirty", want)
			end
		end
	end
end

local function removeGrime(part)
	for i, g in ipairs(grimeSpots) do
		if g == part then table.remove(grimeSpots, i) break end
	end
	if part then part:Destroy() end
	refreshDirty()
end

--// A CLEAN COUNTS (Sep 30 2026): career stat + ultimate charge + hidden
--// score, the same three-in-one ServiceLoop's creditStat does. Every class
--// earns it; the Janitor just cleans the most. (The tutorial's cleaning
--// lesson counts this on the AddScore bus too.) ProfileAPI loads lazily and
--// degrades to a no-op, so a missing profile never breaks cleaning.
local ProfileAPI = nil
local function profileApi()
	if ProfileAPI == nil then
		local ok, api = pcall(function()
			return require(ServerStorage:WaitForChild("Shared", 10):WaitForChild("ProfileAPI", 10))
		end)
		ProfileAPI = (ok and api) or false
		if not ProfileAPI then
			warn("[Tidiness] ProfileAPI unavailable - cleaning careers will NOT save")
		end
	end
	return ProfileAPI or nil
end

local function creditClean(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local api = profileApi()
	if api then pcall(api.AddStat, player, "MessesCleaned", 1) end
	local charge = ServerStorage:FindFirstChild("AddCharge")
	if charge then pcall(charge.Invoke, charge, player, "MessesCleaned", 1) end
	local bus = ServerStorage:FindFirstChild("AddScore")
	if bus then bus:Fire(player, "MessesCleaned", 1) end
end

--// how much work a clean takes for this player: Fixer's ChannelMult (the
--// older rule, kept) times the Janitor's ELBOW GREASE CleanMult
local function cleanWorkMult(player)
	return (player:GetAttribute("ChannelMult") or 1) * (player:GetAttribute("CleanMult") or 1)
end

--// a little sparkle puff where a mess vanished (Janitor skills + buffer)
local function sparkleAt(position)
	local holder = Instance.new("Part")
	holder.Name = "CleanSparkle"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
	holder.Parent = workspace
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 246, 233))
	sparkle.LightEmission = 0.6
	sparkle.Size = NumberSequence.new(0.6, 0)
	sparkle.Lifetime = NumberRange.new(0.4, 0.8)
	sparkle.Speed = NumberRange.new(4, 8)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Rate = 0
	sparkle.Parent = holder
	sparkle:Emit(18)
	Debris:AddItem(holder, 1.5)
end

local function cleanGrime(part, player)
	removeGrime(part)
	if not tidinessEnded then --// after the inspection the bar is hidden
		adjust(TID.CleanRestore, ("%s vacuumed grime"):format(player and player.Name or "?"))
	end
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
	--// The name banner first (MinigameIntro); re-check after it
	if not MinigameIntro.Announce(player, "Vacuum", "Vacuum") then return end
	if dustSession or not grime.Parent then return end
	local needed = math.max(1, math.ceil((TID.DustSpecks or 6) * cleanWorkMult(player)))
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

--// a floor spot near a random table: returns the position + that table's entry
local function pickGrimeSpot()
	local entries = tableEntries()
	if #entries == 0 then return nil end
	local entry = entries[math.random(#entries)]
	local anchor = entry.Part

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
	return pos, entry
end

--// build one grime splat near a random table, on the floor
local function spawnGrime()
	local pos, entry = pickGrimeSpot()
	if not pos then return end

	--// GUARDED ZONE (Janitor R): a spot inside a cone's ring rolls to be
	--// cancelled; if it survives it MOVES to a spot outside every ring
	local zone = guardZoneAt(pos)
	if zone then
		if math.random() < zone.CancelChance then
			print("[Tidiness] grime blocked by a guarded zone (cancelled)")
			return
		end
		local moved = false
		for _ = 1, 8 do
			local p2, e2 = pickGrimeSpot()
			if p2 and not guardZoneAt(p2) then
				pos, entry, moved = p2, e2, true
				break
			end
		end
		if not moved then
			print("[Tidiness] grime blocked by a guarded zone (nowhere else to go)")
			return
		end
	end

	local grime = Instance.new("Part")
	grime:SetAttribute("NearTable", entry.Id) --// which table it makes dirty
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
	if not tidinessEnded then --// after the inspection the bar is hidden
		adjust(-TID.GrimeDropOnSpawn, "grime appeared")
	end
	refreshDirty()
end

local function clearAllGrime()
	for _, g in ipairs(grimeSpots) do
		if g then g:Destroy() end
	end
	grimeSpots = {}
	if poopMess then poopMess:Destroy() poopMess = nil end
	poopDeferred = false
	refreshDirty()
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

--// keepPlunger: QUICK SWEEP cleans with no plunger at all, so it must not
--// take away one the Janitor happens to be carrying for a toilet emergency
local function cleanPoop(player, keepPlunger)
	if poopMess then poopMess:Destroy() poopMess = nil end
	if not keepPlunger then
		removePlunger(player) --// the plunger is spent once the poop is cleared
	end
	if not tidinessEnded then
		adjust(TID.PoopCleanRestore or (TID.CleanRestore * 1.5),
			("%s plunged the toilet"):format(player and player.Name or "?"))
	end
	creditClean(player)
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
	--// The name banner first (MinigameIntro); re-check after it
	if not MinigameIntro.Announce(player, "Plunge", "PoopPlunge") then return end
	if poopSession or not poopMess then return end
	local needed = math.max(1, math.ceil((PLUNGE.TapsToFill or 12) * cleanWorkMult(player)))
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
	--// poop is part of the BAR challenge: it stops once the inspector judged
	if poopMess or tidinessEnded or toiletEventActive() then return end
	local toilet = firstToilet()
	if not toilet then return end

	--// GUARDED ZONE (Janitor R): a guarded toilet rolls to cancel the poop;
	--// if it survives it WAITS until the cone is gone (one toilet - it has
	--// nowhere else to move to)
	local zone = guardZoneAt(toilet.Position)
	if zone then
		if math.random() < zone.CancelChance then
			print("[Tidiness] poop blocked by a guarded zone (cancelled)")
		else
			poopDeferred = true
			print("[Tidiness] poop waiting for the guarded zone to end")
		end
		return
	end
	poopDeferred = false

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

--// ---- THE JANITOR (Sep 30 2026) ---------------------------------------------
--// SkillService (Q/R) and ChargeService (the ultimate) only validate the class
--// and cooldown/charge; the mess work happens here, where the messes live.

local CONE_ORANGE = Color3.fromRGB(255, 122, 28)
local CONE_WHITE = Color3.fromRGB(250, 250, 250)
local BASIL = Color3.fromRGB(76, 175, 109)

local function conePart(model, name, size, cframe, color, shape)
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape or Enum.PartType.Block
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = model
	return part
end

--// a chunky traffic cone from parts (no Toolbox) + the basil ring on the floor
local function buildGuardCone(floorPos, radius)
	local model = Instance.new("Model")
	model.Name = "GuardedZoneCone"
	local up = CFrame.Angles(0, 0, math.rad(90)) --// cylinders lie on X; stand them up
	local base = conePart(model, "Base", Vector3.new(2.2, 0.25, 2.2),
		CFrame.new(floorPos + Vector3.new(0, 0.125, 0)), CONE_ORANGE)
	model.PrimaryPart = base
	conePart(model, "Low", Vector3.new(1, 1.5, 1.5),
		CFrame.new(floorPos + Vector3.new(0, 0.75, 0)) * up, CONE_ORANGE, Enum.PartType.Cylinder)
	conePart(model, "Stripe", Vector3.new(0.6, 1.2, 1.2),
		CFrame.new(floorPos + Vector3.new(0, 1.55, 0)) * up, CONE_WHITE, Enum.PartType.Cylinder)
	conePart(model, "High", Vector3.new(0.8, 0.85, 0.85),
		CFrame.new(floorPos + Vector3.new(0, 2.25, 0)) * up, CONE_ORANGE, Enum.PartType.Cylinder)
	conePart(model, "Tip", Vector3.new(0.6, 0.6, 0.6),
		CFrame.new(floorPos + Vector3.new(0, 2.7, 0)), CONE_ORANGE, Enum.PartType.Ball)

	local ring = conePart(model, "Ring", Vector3.new(0.08, radius * 2, radius * 2),
		CFrame.new(floorPos + Vector3.new(0, 0.06, 0)) * up, BASIL, Enum.PartType.Cylinder)
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.78

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ZoneTimer"
	billboard.Size = UDim2.fromOffset(70, 30)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = base
	billboard.Parent = base
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = CONE_WHITE
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	label.Text = "🚧"
	label.Parent = billboard

	model.Parent = workspace
	return model, ring, label
end

--// the deferred poop gets its turn once no cone guards the toilet any more
local function releaseDeferredPoop()
	if not poopDeferred or tidinessEnded then
		poopDeferred = false
		return
	end
	local toilet = firstToilet()
	if toilet and not guardZoneAt(toilet.Position) then
		poopDeferred = false
		spawnPoop()
	end
end

local function removeGuardZone(zone)
	if not zone then return end
	for owner, z in pairs(guardZones) do
		if z == zone then guardZones[owner] = nil end
	end
	local model = zone.Model
	if model and model.Parent then
		--// the cone tips over and fades; the ring stays flat and just fades
		local ring = model:FindFirstChild("Ring")
		if ring then ring.Parent = workspace end
		local pivot = model:GetPivot()
		task.spawn(function()
			for i = 1, 8 do
				if not model.Parent then break end
				model:PivotTo(pivot * CFrame.Angles(0, 0, math.rad(-80 * i / 8)))
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then part.Transparency = i / 8 end
				end
				if ring then ring.Transparency = 0.78 + 0.22 * i / 8 end
				task.wait(0.04)
			end
			model:Destroy()
			if ring then ring:Destroy() end
		end)
	end
	releaseDeferredPoop()
end

--// R - GUARDED ZONE: the cone lands PlaceAheadStuds in front (stopping short
--// of walls), one per Janitor (a new one picks the old one up)
local function placeGuardZone(player, def)
	if not TID.Enabled then return false, "Nothing to guard!" end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false, "Get on the floor first!" end

	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
	local ahead = def.PlaceAheadStuds or 6

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { character }
	local wall = workspace:Raycast(root.Position, flat * ahead, rp)
	local dist = wall and math.max(0, (wall.Position - root.Position).Magnitude - 1.5) or ahead
	local spot = root.Position + flat * dist
	local floor = workspace:Raycast(spot + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), rp)
	local floorPos = floor and floor.Position or (spot - Vector3.new(0, 3, 0))

	removeGuardZone(guardZones[player])

	local radius = def.RadiusStuds or 14
	local seconds = def.DurationSeconds or 25
	local model, ring, label = buildGuardCone(floorPos, radius)
	local zone = {
		Position = floorPos,
		Radius = radius,
		CancelChance = def.CancelChance or 0.5,
		Model = model,
	}
	guardZones[player] = zone

	--// countdown over the cone; the ring pulses for the last five seconds
	local endsAt = os.clock() + seconds
	task.spawn(function()
		while guardZones[player] == zone do
			local left = endsAt - os.clock()
			if left <= 0 then
				removeGuardZone(zone)
				break
			end
			label.Text = ("🚧 %d"):format(math.ceil(left))
			if left <= 5 then
				ring.Transparency = (math.floor(left * 4) % 2 == 0) and 0.6 or 0.85
			end
			task.wait(0.25)
		end
	end)
	print(("[Tidiness] %s placed a guarded zone (%ds)"):format(player.Name, seconds))
	return true
end

--// the nearest mess (grime or poop) within range of a point
local function nearestMess(pos, range)
	local bestKind, bestObj, bestD = nil, nil, range
	for _, g in ipairs(grimeSpots) do
		if g.Parent then
			local d = (g.Position - pos).Magnitude
			if d <= bestD then bestKind, bestObj, bestD = "grime", g, d end
		end
	end
	local poopPart = poopMess and poopMess.PrimaryPart
	if poopPart then
		local d = (poopPart.Position - pos).Magnitude
		if d <= bestD then bestKind, bestObj, bestD = "poop", poopPart, d end
	end
	return bestKind, bestObj
end

--// Q - QUICK SWEEP: the nearest mess in range is gone, no minigame
local function quickSweep(player, range)
	if not TID.Enabled then return false, "Nothing to clean!" end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false, "Get on the floor first!" end

	local kind, obj = nearestMess(root.Position, range or 25)
	if not obj then return false, "No mess nearby!" end

	sparkleAt(obj.Position)
	if kind == "grime" then
		if dustSession and dustSession.Grime == obj then cancelDust() end
		cleanGrime(obj, player)
	else
		if poopSession then cancelPoop() end
		cleanPoop(player, true) --// no plunger used, so none is taken away
	end
	print(("[Tidiness] %s QUICK SWEEP cleaned the %s"):format(player.Name, kind))
	return true
end

--// ULTIMATE - FLOOR BUFFER: for `seconds`, any floor grime within `radius`
--// of the Janitor's feet is cleaned on contact (poop is not floor mess).
--// The speed and the polisher prop are ChargeService's; this is the cleaning.
local bufferUntil = {} --// [player] = os.clock() the buffer stops cleaning
local function startBuffer(player, seconds, radius)
	if not TID.Enabled then return false, "Nothing to buff!" end
	local alreadyRunning = bufferUntil[player] ~= nil
	bufferUntil[player] = os.clock() + (seconds or 10)
	if alreadyRunning then return true end --// a re-cast just extends the loop

	task.spawn(function()
		while player.Parent and bufferUntil[player] and os.clock() < bufferUntil[player] do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				for i = #grimeSpots, 1, -1 do
					local g = grimeSpots[i]
					if g and g.Parent then
						local offset = g.Position - root.Position
						local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
						if flat <= (radius or 5) and math.abs(offset.Y) <= 6 then
							if dustSession and dustSession.Grime == g then cancelDust() end
							sparkleAt(g.Position)
							cleanGrime(g, player)
						end
					end
				end
			end
			task.wait(0.1)
		end
		bufferUntil[player] = nil
	end)
	return true
end

Players.PlayerRemoving:Connect(function(player)
	removeGuardZone(guardZones[player])
	bufferUntil[player] = nil
end)

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
			--// the inspection is over: the BAR challenge ends for the shift (bar
			--// hides via TidinessActive, drip + poop stop). The floor starts
			--// fresh, then grime keeps coming at AfterInspectionSpawnMult as
			--// DIRTY TABLES (owner spec, Sep 30 2026).
			tidinessEnded = true
			cancelDust()
			cancelPoop()
			clearAllGrime()
			publish()
			return true
		end
		return false
	end
	grimeBridge.Parent = ServerStorage

	--// THE JANITOR's three entry points (SkillService Q/R, ChargeService ult)
	local sweepBridge = Instance.new("BindableFunction")
	sweepBridge.Name = "JanitorQuickSweep"
	sweepBridge.OnInvoke = function(player, range)
		return quickSweep(player, tonumber(range))
	end
	sweepBridge.Parent = ServerStorage

	local zoneBridge = Instance.new("BindableFunction")
	zoneBridge.Name = "JanitorGuardZone"
	zoneBridge.OnInvoke = function(player, def)
		return placeGuardZone(player, type(def) == "table" and def or {})
	end
	zoneBridge.Parent = ServerStorage

	local bufferBridge = Instance.new("BindableFunction")
	bufferBridge.Name = "JanitorBufferStart"
	bufferBridge.OnInvoke = function(player, seconds, radius)
		return startBuffer(player, tonumber(seconds), tonumber(radius))
	end
	bufferBridge.Parent = ServerStorage
end

--// ---- lifecycle: run the drip + grime loops through a RUNNING shift --------
local function tutorialMode()
	return workspace:GetAttribute("MatchMode") == "TUTORIAL"
end

--// cones down, buffers off, no waiting poop - a fresh floor each shift
local function clearJanitorState()
	for _, zone in pairs(guardZones) do
		if zone.Model then zone.Model:Destroy() end
	end
	guardZones = {}
	poopDeferred = false
	bufferUntil = {}
end

local function startShift()
	generation += 1
	local myGen = generation
	tidiness = TID.Start
	tidinessEnded = false --// fresh shift, the tidiness challenge is back on
	clearJanitorState()
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

	--// grime spawns all shift. After the inspection it slows to
	--// AfterInspectionSpawnMult and lands as DIRTY TABLES; poop stops there.
	task.spawn(function()
		while generation == myGen do
			local interval = demand(TID.GrimeSpawnEverySeconds, 15)
			if tidinessEnded then
				interval /= math.max(TID.AfterInspectionSpawnMult or 0.6, 0.05)
			end
			task.wait(interval)
			if generation ~= myGen then break end
			local state = ShiftState:GetAttribute("State")
			if state == "RUNNING" or state == "CLOSING" then
				if #grimeSpots < TID.MaxGrimeSpots then
					spawnGrime()
				end
				--// occasionally a poop appears in the toilet (spawnPoop self-
				--// guards: existing poop, the toilet-overflow event, a guarded
				--// toilet, and the inspection being over)
				if not tidinessEnded and math.random() < (TID.PoopChance or 0.3) then
					spawnPoop()
				end
			end
		end
	end)
end

local function endShift()
	generation += 1  --// kills the loops
	clearJanitorState()
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
