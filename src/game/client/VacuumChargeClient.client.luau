--[[
	Dinner Rush - VacuumChargeClient
	StarterPlayer.StarterPlayerScripts.Client.VacuumChargeClient  (LocalScript)

	THE VACUUM CHARGE (the Janitor's ultimate, owner design Oct 2026). The
	vacuum yanks the Janitor off their feet and drags them along: it CANNOT
	be stopped, only steered, for the whole move.

	Two jobs:

	1. THE CASTER (only on their own screen): plays the start + loop
	   animations and drives the can't-stop movement. STEERING uses the
	   normal movement controls - WASD, the mobile joystick, the left stick -
	   read as the direction the player is trying to move, so it works the
	   same on every device and with shift lock on or off. Pushing a
	   direction turns the charge toward it at TurnDegreesPerSecond (a heavy
	   vacuum turns, it does not snap); letting go keeps it charging straight.

	2. EVERY VACUUM (on every screen): the server drops an anchored
	   "ChargeVacuum" model into the caster's character; each client places
	   it every frame with its Grip in the caster's HANDS and its floor head
	   on the floor ahead. It follows the push animation by itself and can
	   never end up inside the body.

	  S->C  UltimateRemote "VacuumCharge" (seconds, startAnimId, loopAnimId)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UltimateRemote")

local STEER_RENDER = "DinnerRushVacuumCharge"
local PLACE_RENDER = "DinnerRushVacuumPlace"

local function settings()
	return (Config.Ultimates and Config.Ultimates.VacuumCharge) or {}
end

local function flat(vector)
	local v = Vector3.new(vector.X, 0, vector.Z)
	return v.Magnitude > 0.001 and v.Unit or nil
end

----------------------------------------------------------------
-- 1. THE CASTER: animations + the can't-stop run
----------------------------------------------------------------

local stopCurrent = nil

local function loadTrack(animator, id)
	if type(id) ~= "string" or id == "" then return nil end
	local animation = Instance.new("Animation")
	animation.AnimationId = id:match("^%d+$") and ("rbxassetid://" .. id) or id
	local ok, track = pcall(animator.LoadAnimation, animator, animation)
	if not ok or not track then
		warn(("[VacuumCharge] animation '%s' would not load"):format(id))
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action4
	return track
end

local function charge(seconds, startId, loopId)
	if stopCurrent then stopCurrent() end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not animator or not root then return end

	local startTrack = loadTrack(animator, startId)
	local loopTrack = loadTrack(animator, loopId)
	if loopTrack then
		loopTrack.Looped = true
	end

	local alive = true
	local promptsWere = ProximityPromptService.Enabled
	local heading = flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)

	local function stop()
		if not alive then return end
		alive = false
		stopCurrent = nil
		RunService:UnbindFromRenderStep(STEER_RENDER)
		pcall(function() if startTrack then startTrack:Stop(0.2) end end)
		pcall(function() if loopTrack then loopTrack:Stop(0.2) end end)
		ProximityPromptService.Enabled = promptsWere
		if humanoid.Parent then
			humanoid:Move(Vector3.zero, false)
		end
	end
	stopCurrent = stop

	--// THE ANIMATIONS: the start once, then the loop - handed over a beat
	--// early so the two blend (the start's last frame matches the loop's)
	if startTrack then
		startTrack.Looped = false
		startTrack:Play(0.1)
		task.spawn(function()
			local deadline = os.clock() + 2
			while startTrack.Length <= 0 and alive and os.clock() < deadline do
				task.wait()
			end
			local hold = math.max(startTrack.Length - 0.12, 0)
			if hold > 0 then task.wait(hold) end
			if alive and loopTrack then
				loopTrack:Play(0.12)
			end
		end)
	elseif loopTrack then
		loopTrack:Play(0.1)
	end

	--// no grabbing ingredients mid-charge by accident
	ProximityPromptService.Enabled = false

	--// THE CHARGE. The default controls run first each frame and set
	--// MoveDirection to wherever the player is TRYING to go (keys, joystick
	--// or stick, already turned to match the camera). We read that as the
	--// steering, then overwrite the actual move with the charge's heading.
	local turnRate = math.rad(settings().TurnDegreesPerSecond or 200)
	RunService:BindToRenderStep(STEER_RENDER, Enum.RenderPriority.Character.Value + 1, function(dt)
		if not alive or not humanoid.Parent then return end
		local want = flat(humanoid.MoveDirection)
		if want and want:Dot(heading) < 0.9999 then
			local angle = math.atan2(heading:Cross(want).Y, heading:Dot(want))
			local step = math.clamp(angle, -turnRate * dt, turnRate * dt)
			heading = CFrame.Angles(0, step, 0):VectorToWorldSpace(heading)
		end
		humanoid:Move(heading, false)
	end)

	task.delay(seconds, stop)
	humanoid.Died:Once(stop)
end

remote.OnClientEvent:Connect(function(action, seconds, startId, loopId)
	if action ~= "VacuumCharge" then return end
	charge(tonumber(seconds) or 10, startId, loopId)
end)

----------------------------------------------------------------
-- 2. EVERY VACUUM: handle in the hands, floor head on the floor
----------------------------------------------------------------

--// What we need from a vacuum model, measured once in its OWN space: where
--// the Grip sits, where the floor head sits, and the distance between
local shapes = setmetatable({}, { __mode = "k" })

local function shapeOf(model)
	local shape = shapes[model]
	if shape then return shape end

	local pivot = model:GetPivot()
	local boxCF, boxSize = model:GetBoundingBox()
	local grip = model:FindFirstChild("Grip", true)
	--// no Grip marker: assume the hand is at the very top of the model
	local gripWorld = (grip and grip:IsA("BasePart")) and grip.Position
		or (boxCF.Position + Vector3.new(0, boxSize.Y / 2, 0))
	local headWorld = boxCF.Position - Vector3.new(0, boxSize.Y / 2, 0)

	local gripLocal = pivot:PointToObjectSpace(gripWorld)
	local headLocal = pivot:PointToObjectSpace(headWorld)
	local pole = headLocal - gripLocal
	if pole.Magnitude < 0.1 then return nil end

	--// the model's own frame: Z along the pole (grip -> floor head), X the
	--// floor head's width (the model's X), Y completing it
	local axis = pole.Unit
	local side = Vector3.xAxis - axis * Vector3.xAxis:Dot(axis)
	if side.Magnitude < 0.01 then side = Vector3.zAxis end
	side = side.Unit
	shape = {
		GripLocal = gripLocal,
		Length = pole.Magnitude,
		Basis = CFrame.fromMatrix(Vector3.zero, side, axis:Cross(side), axis),
	}
	shapes[model] = shape
	return shape
end

local function placeVacuum(character, model)
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then return end
	local shape = shapeOf(model)
	if not shape then return end
	local s = settings()

	local forward = flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local right = flat(root.CFrame.RightVector) or Vector3.new(1, 0, 0)

	--// THE GRIP POINT: between the two hands, wherever the animation has
	--// put them this frame (a body with no hands: just in front of the chest)
	local leftHand = character:FindFirstChild("LeftHand")
	local rightHand = character:FindFirstChild("RightHand")
	local grip
	if leftHand and rightHand then
		grip = (leftHand.Position + rightHand.Position) / 2
	else
		grip = root.Position + forward * 1.2 + Vector3.new(0, 0.5, 0)
	end

	--// THE FLOOR HEAD STAYS ON THE FLOOR, every frame (owner playtest: a
	--// fixed lean plus a push-pull surge left it hovering, because this
	--// vacuum is too short to lean that far with the handle in the hands).
	--// The lean is exactly the one that puts the head on the floor with the
	--// handle in the hands - so it tips further out as the animation pushes
	--// the hands forward and down, and never lifts.
	--// Lean = how far the pole tips OUT from straight down.
	local started = model:GetAttribute("StartedAt")
	local t = started and math.max(workspace:GetServerTimeNow() - started, 0) or 0
	local floorY = root.Position.Y - (humanoid.HipHeight + root.Size.Y / 2)
	local drop = math.max(grip.Y - floorY, 0.05)
	local lean = math.acos(math.clamp(drop / shape.Length, -1, 1))

	--// the side-to-side wobble swings the whole vacuum around the hands
	local sway = math.rad(s.WobbleDegrees or 3) * math.sin(t * 7)
	local swayTurn = CFrame.Angles(0, sway, 0)
	local outward = swayTurn:VectorToWorldSpace(forward)
	local axis = (Vector3.new(0, -1, 0) * math.cos(lean) + outward * math.sin(lean)).Unit

	--// the floor head lies across the Janitor's path
	local side = swayTurn:VectorToWorldSpace(s.FlipFacing and -right or right)
	side = side - axis * side:Dot(axis)
	if side.Magnitude < 0.01 then return end
	side = side.Unit
	local target = CFrame.fromMatrix(Vector3.zero, side, axis:Cross(side), axis)

	--// a little rattle, like a motor working hard
	local rattle = CFrame.fromAxisAngle(axis, math.sin(t * 18) * 0.04)
	local rotation = rattle * target * shape.Basis:Inverse()

	model:PivotTo(CFrame.new(grip) * rotation * CFrame.new(-shape.GripLocal))
end

RunService:BindToRenderStep(PLACE_RENDER, Enum.RenderPriority.Character.Value + 2, function()
	for _, other in ipairs(Players:GetPlayers()) do
		local character = other.Character
		local model = character and character:FindFirstChild("ChargeVacuum")
		--// a vacuum riding the animation's bone moves itself
		if model and model:IsA("Model") and not model:GetAttribute("OnBone") then
			placeVacuum(character, model)
		end
	end
end)
