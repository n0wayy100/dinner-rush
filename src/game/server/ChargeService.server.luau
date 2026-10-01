--[[
	Dinner Rush - ChargeService
	ServerScriptService.Server.ChargeService  (regular Script, server-side)

	Phase 2, final step: CHARGE + THE FOUR ULTIMATES.

	Charge is SERVER-owned: a 0..MaxCharge number per player, stored as the
	UltimateCharge attribute (replicates to that client for the bar).
	It is earned through ServerStorage.AddCharge, invoked by the SAME
	creditStat calls that write careers - every counted moment is a charge
	moment, mapped by Config.Ultimates.ChargePer. Classless players earn
	nothing and can activate nothing.

	Activation (UltimateRemote "Activate", sent by ChargeClient on
	Q / touch / gamepad Y): validated end-to-end here - class equipped,
	charge full, shift live - then dispatched:

	  Chef     FLASH FRY!   EVERY carried raw becomes its Perfect dish;
	                        dish variants resolve to what open tickets
	                        want (neediest first), else by
	                        Config.Ultimates.FlashFryMethodOrder
	  Waiter   EXPRESS RUN! teleport to the pass, grab every plate, and
	                        flash-serve each to the neediest ordering table
	                        (ServiceLoop.WaiterExpress does the work)
	  Fixer    SPEED DIAL!  ServerStorage.ResolveActiveEvent (EventSystem's
	                        own stop* success paths - never re-implemented)
	  Charmer  SWEET TALK!  ServerStorage.SweetTalkTable (ServiceLoop's
	                        extendBar on the most desperate seated party)

	Only a SUCCESSFUL ability consumes charge; denials keep it and tell the
	player why. Charge survives respawn (it lives on the Player), dies with
	leaving, and resets - along with the Waiter's DOUBLE TIME speed boost -
	when a new shift goes RUNNING. (The Chef's CarryLimit is a class passive,
	not reset here - see the RUNNING block below.)

	THE LAW: FLASH FRY skips the cook timer entirely; it never modifies it.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Sfx = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Sfx"))

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[Charge] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

local ULT = Config.Ultimates

print("[Charge] script started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local ultimateRemote = remotes:FindFirstChild("UltimateRemote")
if not ultimateRemote then
	ultimateRemote = Instance.new("RemoteEvent")
	ultimateRemote.Name = "UltimateRemote"
	ultimateRemote.Parent = remotes
end

local function shiftInfo()
	local bridge = ServerStorage:FindFirstChild("GetShiftInfo")
	if not bridge then
		return { State = "WAITING" }
	end
	local ok, info = pcall(function() return bridge:Invoke() end)
	return (ok and type(info) == "table") and info or { State = "WAITING" }
end

----------------------------------------------------------------
-- Charge accrual
----------------------------------------------------------------
local function addCharge(player, key, count)
	if not player or not player.Parent then return end

	--// No class, no charge - classless play stays clean of the system
	local classKey = player:GetAttribute("ClassKey")
	if not classKey or classKey == "" then return end

	local per = ULT.ChargePer[key] or 0
	if per <= 0 then return end

	local current = player:GetAttribute("UltimateCharge") or 0
	if current >= ULT.MaxCharge then return end

	player:SetAttribute("UltimateCharge",
		math.min(ULT.MaxCharge, current + per * math.max(tonumber(count) or 1, 1)))
end

do
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "AddCharge"
	bindable.OnInvoke = addCharge
	bindable.Parent = ServerStorage
end

----------------------------------------------------------------
-- The abilities. Each returns ok, reasonText - false keeps the charge.
----------------------------------------------------------------

--// Same tool shape KitchenService hands out at collect, so the pass and
--// serving flow treat a flash-fried dish exactly like a cooked one
local function makeDishTool(recipe, dishName)
	local tool = Instance.new("Tool")
	tool.Name = recipe.Display
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	if recipe.Icon ~= "" and recipe.Icon ~= "rbxassetid://0" then
		tool.TextureId = recipe.Icon
	end
	tool:SetAttribute("Dish", dishName)
	tool:SetAttribute("Quality", "Perfect")

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1.6, 0.8, 1.6)
	handle.Color = recipe.Color
	handle.Material = Enum.Material.SmoothPlastic
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	--// Composed cartoon food, same as KitchenService's collect path
	local ok, DishModels = pcall(function()
		return require(ServerStorage:WaitForChild("Shared"):WaitForChild("DishModels"))
	end)
	if ok and DishModels and DishModels.decorate(tool, dishName) then
		handle.Transparency = 1
	end

	return tool
end

--// Every recipe an ingredient can become, sorted by FlashFryMethodOrder
--// (then name) so variant resolution is DETERMINISTIC - pairs() order
--// must never decide which steak the chef gets
local function recipesFor(ingredient)
	local rank = {}
	for index, method in ipairs(ULT.FlashFryMethodOrder) do
		rank[method] = index
	end
	local out = {}
	for name, recipe in pairs(Config.Recipes) do
		if recipe.Ingredient == ingredient then
			table.insert(out, { Name = name, Recipe = recipe })
		end
	end
	table.sort(out, function(a, b)
		local ra = rank[a.Recipe.Method] or math.huge
		local rb = rank[b.Recipe.Method] or math.huge
		if ra ~= rb then return ra < rb end
		return a.Name < b.Name
	end)
	return out
end

--// What the floor is waiting on right now: dish -> how many tickets
--// still want it, and the hungriest one's patience fraction
local function openWants()
	local bridge = ServerStorage:FindFirstChild("GetOpenOrders")
	if not bridge then return {} end
	local ok, orders = pcall(function() return bridge:Invoke() end)
	if not ok or type(orders) ~= "table" then return {} end

	local wants = {}
	for _, order in ipairs(orders) do
		if not order.Walkout then
			for _, dishName in ipairs(order.Dishes or {}) do
				local want = wants[dishName]
				if not want then
					want = { Count = 0, Neediest = 1 }
					wants[dishName] = want
				end
				want.Count += 1
				want.Neediest = math.min(want.Neediest, order.Patience or 1)
			end
		end
	end
	return wants
end

--// One raw -> one dish. A lone recipe just cooks; variants go to the
--// neediest open ticket asking for one, else the preference order.
--// Claiming decrements the want so two steaks can feed two tickets.
local function pickDish(candidates, wants)
	local pick = nil
	if #candidates > 1 then
		local bestNeed
		for _, candidate in ipairs(candidates) do
			local want = wants[candidate.Name]
			if want and want.Count > 0
				and (not pick or want.Neediest < bestNeed) then
				pick, bestNeed = candidate, want.Neediest
			end
		end
	end
	pick = pick or candidates[1]
	local want = wants[pick.Name]
	if want and want.Count > 0 then
		want.Count -= 1
	end
	return pick
end

--// FLASH FRY (reworked Sep 27 2026): instead of cooking carried raws, it
--// instantly FINISHES up to 2 pans that are CURRENTLY cooking - no wait, no
--// minigame. Each lands grab-ready as a Perfect dish at its station (its cooked
--// icon shows "READY"), for anyone to grab. All the work is KitchenService's
--// FlashFinish; here we find the cooking pans and fire it.
local function flashFry(player)
	local control = ServerStorage:FindFirstChild("KitchenStationControl")
	if not control then
		return false, "Kitchen's not ready!"
	end
	local ok, list = pcall(function() return control:Invoke("List") end)
	if not ok or type(list) ~= "table" then
		return false, "Kitchen's not ready!"
	end

	local cooking = {}
	for _, entry in ipairs(list) do
		if entry.State == "COOKING" then
			table.insert(cooking, entry.Id)
		end
	end
	if #cooking == 0 then
		return false, "Nothing's cooking to flash-fry!"
	end

	local maxPans = ULT.FlashFryMaxPans or 2
	local finished = 0
	for _, id in ipairs(cooking) do
		if finished >= maxPans then break end
		local okf, done = pcall(function() return control:Invoke("FlashFinish", id) end)
		if okf and done then finished += 1 end
	end
	if finished == 0 then
		return false, "Nothing's cooking to flash-fry!"
	end

	print(("[Charge] FLASH FRY! %s instantly finished %d cooking pan(s)"):format(
		player.Name, finished))
	return true
end

--// EXPRESS RUN (Waiter ultimate, revamped Sep 2026): teleport to the pass,
--// grab every plate, and flash-serve each to the neediest table that ordered
--// it. All the work is in ServiceLoop's WaiterExpress bridge (it owns the
--// tables, patience and serve flow); here we just fire it. No plates / no
--// matching tables = it keeps the charge.
--// DOUBLE TIME (Waiter ultimate, reworked Sep 27 2026): a big speed burst -
--// SpeedBoostMult on the Player for SpeedBoostSeconds. SprintClient scales
--// every WalkSpeed it writes by it AND plays/stops the run animation off the
--// same attribute. A token guards against an earlier cast's timer cutting a
--// later one short.
--// shared by DOUBLE TIME and FLOOR BUFFER: SprintClient scales WalkSpeed by
--// SpeedBoostMult (and picks the class's boost animation off ClassKey)
local function applySpeedBoost(player, mult, seconds)
	player:SetAttribute("SpeedBoostMult", mult)
	local token = (player:GetAttribute("SpeedBoostToken") or 0) + 1
	player:SetAttribute("SpeedBoostToken", token)
	task.delay(seconds, function()
		if player and player.Parent
			and player:GetAttribute("SpeedBoostToken") == token then
			player:SetAttribute("SpeedBoostMult", nil) --// boost + run anim end
		end
	end)
end

local function doubleTime(player)
	if not player.Character then
		return false, "Get on the floor first!"
	end
	local mult = ULT.SpeedBoostMult or 2
	local seconds = ULT.SpeedBoostSeconds or 20
	applySpeedBoost(player, mult, seconds)
	print(("[Charge] DOUBLE TIME! %s at x%.2g speed for %ds"):format(
		player.Name, mult, seconds))
	return true
end

local function speedDial(player)
	local bridge = ServerStorage:FindFirstChild("ResolveActiveEvent")
	if not bridge then
		return false, "Nothing to dial!"
	end
	local ok, resolved, reason = pcall(function()
		return bridge:Invoke(player)
	end)
	if not ok then
		return false, "The line is busy!"
	end
	if resolved then
		print(("[Charge] SPEED DIAL! %s resolved the emergency"):format(player.Name))
	end
	return resolved, reason
end

local function sweetTalk(player)
	local bridge = ServerStorage:FindFirstChild("SweetTalkTable")
	if not bridge then
		return false, "Nobody to charm!"
	end
	local ok, charmed, reason = pcall(function()
		return bridge:Invoke(player)
	end)
	if not ok then
		return false, "The charm fizzled!"
	end
	if charmed then
		print(("[Charge] SWEET TALK! %s soothed the neediest table"):format(player.Name))
	end
	return charmed, reason
end

--// The code-built parts REMOTE (a handheld body + a big red button). Pure
--// parts, no Toolbox. The Fixer taps it to SPEED DIAL the fix.
local function buildCodeRemote()
	local remote = Instance.new("Model")
	remote.Name = "SpeedDialRemote"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(1.0, 0.45, 1.7)
	body.Color = Color3.fromRGB(45, 48, 55)
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.CanQuery = false
	body.Massless = true
	body.Parent = remote
	remote.PrimaryPart = body

	local button = Instance.new("Part")
	button.Name = "RedButton"
	button.Shape = Enum.PartType.Cylinder
	button.Size = Vector3.new(0.3, 0.75, 0.75) --// cylinder along X -> a disc once rolled
	button.Color = Color3.fromRGB(229, 45, 45)
	button.Material = Enum.Material.Neon
	button.CanCollide = false
	button.CanQuery = false
	button.Massless = true
	button.Parent = remote
	local bw = Instance.new("WeldConstraint")
	bw.Part0 = body
	bw.Part1 = button
	bw.Parent = button
	--// the big red button sits on TOP of the body, toward the front, facing up
	button.CFrame = body.CFrame * CFrame.new(0, 0.3, -0.45) * CFrame.Angles(0, 0, math.rad(90))

	return remote
end

--// A code-built parts ROSE (green stem + red bud + leaves) - the Charmer's
--// SWEET TALK fallback if no SweetTalkRose model is provided. Pure parts.
local function buildCodeRose()
	local rose = Instance.new("Model")
	rose.Name = "SweetTalkRose"

	local stem = Instance.new("Part")
	stem.Name = "Stem"
	stem.Size = Vector3.new(0.12, 2.2, 0.12)
	stem.Color = Color3.fromRGB(76, 130, 70)
	stem.Material = Enum.Material.Grass
	stem.CanCollide = false
	stem.CanQuery = false
	stem.Massless = true
	stem.Parent = rose
	rose.PrimaryPart = stem

	local bud = Instance.new("Part")
	bud.Name = "Bud"
	bud.Shape = Enum.PartType.Ball
	bud.Size = Vector3.new(0.7, 0.85, 0.7)
	bud.Color = Color3.fromRGB(200, 40, 60)
	bud.Material = Enum.Material.SmoothPlastic
	bud.CanCollide = false
	bud.CanQuery = false
	bud.Massless = true
	bud.Parent = rose
	local bw = Instance.new("WeldConstraint")
	bw.Part0 = stem
	bw.Part1 = bud
	bw.Parent = bud
	bud.CFrame = stem.CFrame * CFrame.new(0, 1.2, 0)

	local function leaf(sign)
		local l = Instance.new("Part")
		l.Name = "Leaf"
		l.Size = Vector3.new(0.5, 0.08, 0.24)
		l.Color = Color3.fromRGB(90, 150, 80)
		l.Material = Enum.Material.Grass
		l.CanCollide = false
		l.CanQuery = false
		l.Massless = true
		l.Parent = rose
		local w = Instance.new("WeldConstraint")
		w.Part0 = stem
		w.Part1 = l
		w.Parent = l
		l.CFrame = stem.CFrame
			* CFrame.new(sign * 0.3, 0.2, 0) * CFrame.Angles(0, 0, math.rad(sign * 25))
	end
	leaf(1)
	leaf(-1)

	return rose
end

--// Owner may drop a SAFE parts/MeshPart prop of the given name in ServerStorage
--// - NEVER a Toolbox model (scripts = the backdoor vector). Every script is
--// STRIPPED on clone as a guard, so even a scripted model runs no code here. A
--// mesh is inert geometry and is fine. Returns a Model with a PrimaryPart.
local function makeProp(templateName, buildFn)
	local template = ServerStorage:FindFirstChild(templateName)
	if not template then
		return buildFn()
	end
	local clone = template:Clone()

	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then d:Destroy() end
	end

	local function tidy(p)   --// inert + weld-friendly
		p.CanCollide = false
		p.CanQuery = false
		p.Massless = true
		p.Anchored = false
	end

	--// a single MeshPart template: wrap it in a Model so the weld is uniform
	if clone:IsA("BasePart") then
		tidy(clone)
		local model = Instance.new("Model")
		model.Name = templateName
		clone.Parent = model
		model.PrimaryPart = clone
		return model
	end

	--// a Model template
	if clone:IsA("Model") then
		clone.Name = templateName
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then tidy(d) end
		end
		if not clone.PrimaryPart then
			clone.PrimaryPart = clone:FindFirstChildWhichIsA("BasePart", true)
		end
		if clone.PrimaryPart then return clone end
	end

	--// unexpected template shape - fall back to the code build
	clone:Destroy()
	return buildFn()
end

--// WELD a prop into the caster's RIGHT hand for the cast, remove after
--// `seconds`. Positions the WHOLE model then welds EVERY part to the hand so a
--// multi-part model rides as one (nothing falls off). grip = { Offset={x,y,z},
--// TiltDegrees={x,y,z} }, tunable so it sits right against each animation.
local function attachHandProp(character, seconds, prop, grip)
	if not prop then return end
	local hand = character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")
	local body = prop.PrimaryPart
	if not hand or not body then prop:Destroy() return end

	grip = grip or {}
	local offset = grip.Offset or { 0, 0.4, 0 }        --// studs from the hand center
	local tilt = grip.TiltDegrees or { 0, 0, 0 }       --// rotate the prop in-grip
	local target = hand.CFrame
		* CFrame.new(offset[1], offset[2], offset[3])
		* CFrame.Angles(math.rad(tilt[1]), math.rad(tilt[2]), math.rad(tilt[3]))

	prop.Parent = character
	prop:PivotTo(target)
	for _, p in ipairs(prop:GetDescendants()) do
		if p:IsA("BasePart") then
			local w = Instance.new("WeldConstraint")
			w.Part0 = hand
			w.Part1 = p
			w.Parent = p
		end
	end

	game:GetService("Debris"):AddItem(prop, seconds)
end

--// FLOOR BUFFER (Janitor ultimate): a parts-built floor polisher - a dark pad
--// on the floor, a motor housing, a pole back up to a mustard handlebar. Built
--// around the PAD (PrimaryPart) facing -Z; no assets, no Toolbox. The owner may
--// drop a safe "FloorBuffer" model in ServerStorage (scripts are stripped).
local function buildCodeBuffer()
	local model = Instance.new("Model")
	model.Name = "FloorBuffer"
	local function part(name, size, cframe, color, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = shape or Enum.PartType.Block
		p.Size = size
		p.CFrame = cframe
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Parent = model
		return p
	end
	--// an invisible, UNROTATED anchor at the pad centre is the pivot (the pad
	--// itself is a cylinder turned upright, which would tilt the whole prop)
	local anchor = part("Anchor", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, 0, 0),
		Color3.new(1, 1, 1))
	anchor.Transparency = 1
	model.PrimaryPart = anchor
	local up = CFrame.Angles(0, 0, math.rad(90)) --// cylinders lie on X; stand them up
	local pad = part("Pad", Vector3.new(0.35, 3, 3), CFrame.new(0, 0, 0) * up,
		Color3.fromRGB(45, 45, 50), Enum.PartType.Cylinder)
	part("Housing", Vector3.new(0.9, 2, 2), CFrame.new(0, 0.6, 0) * up,
		Color3.fromRGB(229, 72, 77), Enum.PartType.Cylinder)
	--// the pole runs back toward the rider (+Z) and up to hand height
	local poleFrom, poleTo = Vector3.new(0, 1, 0.4), Vector3.new(0, 3.3, 2.3)
	part("Pole", Vector3.new(0.22, 0.22, (poleTo - poleFrom).Magnitude),
		CFrame.lookAt((poleFrom + poleTo) / 2, poleTo), Color3.fromRGB(180, 180, 185))
	part("Handlebar", Vector3.new(1.8, 0.28, 0.28), CFrame.new(poleTo),
		Color3.fromRGB(245, 184, 65))

	--// a little shine kicking up off the pad while it runs
	local shine = Instance.new("ParticleEmitter")
	shine.Color = ColorSequence.new(Color3.fromRGB(255, 246, 233))
	shine.LightEmission = 0.5
	shine.Size = NumberSequence.new(0.35, 0)
	shine.Lifetime = NumberRange.new(0.3, 0.6)
	shine.Rate = 25
	shine.Speed = NumberRange.new(2, 4)
	shine.SpreadAngle = Vector2.new(70, 70)
	shine.EmissionDirection = Enum.NormalId.Top
	shine.Parent = pad
	return model
end

--// WELD a prop to the caster's ROOT (the buffer rides along the floor in
--// front of them, not in a hand). Same weld-every-part rule as hand props.
local function attachRootProp(character, seconds, prop, aheadStuds)
	if not prop then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local body = prop.PrimaryPart
	if not root or not humanoid or not body then prop:Destroy() return end

	--// root height above the floor: R15 stands on HipHeight, R6 on its legs
	local height = humanoid.RigType == Enum.HumanoidRigType.R15
		and (humanoid.HipHeight + root.Size.Y / 2) or 3
	prop.Parent = character
	prop:PivotTo(root.CFrame * CFrame.new(0, -height + 0.2, -(aheadStuds or 2.6)))
	for _, p in ipairs(prop:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.Massless = true
			local w = Instance.new("WeldConstraint")
			w.Part0 = root
			w.Part1 = p
			w.Parent = p
		end
	end
	game:GetService("Debris"):AddItem(prop, seconds)
end

--// FLOOR BUFFER (Janitor ultimate, Sep 30 2026): ride the polisher for
--// BufferSeconds - a speed boost (kept under DOUBLE TIME's) while
--// CleanlinessService cleans any floor grime the rider passes over.
local function floorBuffer(player)
	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then
		return false, "Get on the floor first!"
	end
	local seconds = ULT.BufferSeconds or 10
	local bridge = ServerStorage:FindFirstChild("JanitorBufferStart")
	if not bridge then
		return false, "No floor to buff!"
	end
	local ok, started, reason = pcall(bridge.Invoke, bridge, player, seconds,
		ULT.BufferCleanRadiusStuds or 5)
	if not ok or not started then
		return false, reason or "No floor to buff!"
	end
	applySpeedBoost(player, ULT.BufferSpeedMult or 1.4, seconds)
	attachRootProp(character, seconds, makeProp("FloorBuffer", buildCodeBuffer))
	print(("[Charge] FLOOR BUFFER! %s buffs the floor for %ds"):format(player.Name, seconds))
	return true
end

--// The cast's in-world flourish: the caster plays their ultimate animation
--// (client-side, via the same PlayAnim channel the skills use, so it shows to
--// everyone) plus any class particle - the Chef sprinkles salt from the hand.
local function playCastEffect(player, classKey)
	local character = player.Character
	if not character then return end

	local animId = ULT.ClassCastAnim and ULT.ClassCastAnim[classKey]
	if animId and animId ~= "" then
		local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
		local skillRemote = remotes and remotes:FindFirstChild("SkillRemote")
		if skillRemote then
			skillRemote:FireClient(player, "PlayAnim", animId)
		end
	end

	--// CHEF: SALT BAE sprinkle off the right hand, timed to the move
	if classKey == "Chef" then
		local hand = character:FindFirstChild("RightHand")
			or character:FindFirstChild("Right Arm")
		if hand then
			local salt = Instance.new("ParticleEmitter")
			salt.Name = "SaltSprinkle"
			salt.Texture = "rbxassetid://243660364" --// soft white grain
			salt.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
			salt.Size = NumberSequence.new(0.14, 0.02)
			salt.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			})
			salt.Lifetime = NumberRange.new(0.5, 0.9)
			salt.Rate = 70
			salt.Speed = NumberRange.new(1, 3)
			salt.SpreadAngle = Vector2.new(18, 18)
			salt.Acceleration = Vector3.new(0, -22, 0) --// the grains fall
			salt.Rotation = NumberRange.new(0, 360)
			salt.EmissionDirection = Enum.NormalId.Bottom
			salt.Parent = hand
			task.delay(ULT.SaltSeconds or 1.5, function()
				salt.Enabled = false
				game:GetService("Debris"):AddItem(salt, 1.2)
			end)
		end
	end

	--// FIXER: SPEED DIAL taps a remote (big red button). CHARMER: SWEET TALK
	--// offers a rose. Both welded into the hand for the cast (the animation
	--// poses the empty hand; the prop rides along). Owner may supply the model.
	if classKey == "Fixer" then
		attachHandProp(character, ULT.RemoteSeconds or 2,
			makeProp("SpeedDialRemote", buildCodeRemote), ULT.RemoteGrip)
	elseif classKey == "Charmer" then
		attachHandProp(character, ULT.RoseSeconds or 2,
			makeProp("SweetTalkRose", buildCodeRose), ULT.RoseGrip)
	end
end

local ABILITIES = {
	Chef = flashFry,
	Waiter = doubleTime,
	Fixer = speedDial,
	Charmer = sweetTalk,
	Janitor = floorBuffer,
}

----------------------------------------------------------------
-- Activation
----------------------------------------------------------------
ultimateRemote.OnServerEvent:Connect(function(player, action)
	if action ~= "Activate" then return end

	local info = shiftInfo()
	if info.State ~= "RUNNING" and info.State ~= "CLOSING" then
		ultimateRemote:FireClient(player, "Result", false, "Wait for the shift!")
		return
	end

	local classKey = player:GetAttribute("ClassKey")
	local ability = classKey and ABILITIES[classKey]
	if not ability then
		ultimateRemote:FireClient(player, "Result", false, "No class equipped!")
		return
	end

	local charge = player:GetAttribute("UltimateCharge") or 0
	if charge < ULT.MaxCharge then
		ultimateRemote:FireClient(player, "Result", false, "Not charged yet!")
		return
	end

	local ok, reason = ability(player)
	if ok then
		player:SetAttribute("UltimateCharge", 0) --// spent only on success

		--// At the caster, not global: the team hears WHO just did something
		--// big. Fires only after the ability actually succeeded, so a denied
		--// press stays silent.
		Sfx.Play("UltimateUsed", player.Character)

		--// in-world cast animation + class particle (Chef's salt)
		playCastEffect(player, classKey)

		ultimateRemote:FireClient(player, "Result", true)
		--// Everyone hears about it - ultimates are social moments. Sent
		--// only after the ability SUCCEEDED, so no client can show a
		--// banner for a denied cast. (CastBannerClient renders it.)
		ultimateRemote:FireAllClients("Cast", player, player:GetAttribute("ClassKey"))
	else
		ultimateRemote:FireClient(player, "Result", false, reason or "Not now!")
	end
end)

----------------------------------------------------------------
-- Lifecycle: zeroed on join, reset (with THIRD HAND) every new shift
----------------------------------------------------------------
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("UltimateCharge", 0)
end)
for _, player in ipairs(Players:GetPlayers()) do
	player:SetAttribute("UltimateCharge", 0)
end

task.spawn(function()
	local lastState = ""
	while true do
		local state = shiftInfo().State
		if state == "RUNNING" and lastState ~= "RUNNING" then
			for _, player in ipairs(Players:GetPlayers()) do
				player:SetAttribute("UltimateCharge", 0)
				--// NB: do NOT clear CarryLimit here - it is the CHEF'S PASSIVE
				--// now (set by ClassService), not a temporary ultimate. The
				--// old THIRD HAND ult that needed retracting is long gone.
				player:SetAttribute("SpeedBoostMult", nil) --// double time ends
			end
			print("[Charge] new shift - charges and boosts reset")
		end
		lastState = state
		task.wait(1)
	end
end)

--// STUDIO-ONLY (Config.Ultimates.StudioFullCharge): equips a class and
--// keeps the charge topped up so ultimate testing needs no command bar.
--// Re-tops every couple of seconds, so casts can be spammed. Never runs
--// on live servers.
if game:GetService("RunService"):IsStudio() and ULT.StudioFullCharge then
	warn("[Charge] ==============================================")
	warn("[Charge]  STUDIO FULL CHARGE IS ON (Config.Ultimates)")
	warn(("[Charge]  Everyone plays %s with an always-ready ultimate.")
		:format(ULT.StudioClassKey ~= "" and ULT.StudioClassKey or "their class"))
	warn("[Charge]  Set StudioFullCharge = false when testing ends.")
	warn("[Charge] ==============================================")
	task.spawn(function()
		while true do
			for _, player in ipairs(Players:GetPlayers()) do
				if (player:GetAttribute("ClassKey") or "") == ""
					and (ULT.StudioClassKey or "") ~= "" then
					player:SetAttribute("ClassKey", ULT.StudioClassKey)
				end
				player:SetAttribute("UltimateCharge", ULT.MaxCharge)
			end
			task.wait(2)
		end
	end)
end
