--[[
	Dinner Rush - FootstepsClient
	StarterPlayer.StarterPlayerScripts.Client.FootstepsClient  (LocalScript)

	Placeholder movement sounds (Config.Footsteps): a looping footstep while
	running on the ground (faster when sprinting), a hop on jump, a thud on
	landing. Uses Roblox's built-in rbxasset:// sound files, so nothing to
	upload. Local only - every player hears their own steps.

	Roblox's default character sounds (RbxCharacterSounds) are silenced on
	our character if present, so the two never double up.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local FOOT = Config.Footsteps
if not FOOT or not FOOT.Enabled then return end

local player = Players.LocalPlayer
local DEFAULT_SOUND_NAMES = { "Running", "Jumping", "Landing", "FreeFalling", "Climbing" }

local function makeSound(parent, name, id, volume, looped)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = id
	sound.Volume = volume
	sound.Looped = looped or false
	sound.RollOffMaxDistance = 60
	sound.Parent = parent
	return sound
end

local conn = nil

local function onCharacter(character)
	if conn then conn:Disconnect() conn = nil end
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root then return end

	--// silence Roblox's defaults if they exist, so nothing doubles up
	task.delay(1, function()
		for _, name in ipairs(DEFAULT_SOUND_NAMES) do
			local sound = root:FindFirstChild(name)
			if sound and sound:IsA("Sound") and sound:GetAttribute("DinnerRush") == nil then
				sound.Volume = 0
			end
		end
	end)

	local run = makeSound(root, "DR_Run", FOOT.RunSound, FOOT.RunVolume, true)
	local jump = makeSound(root, "DR_Jump", FOOT.JumpSound, FOOT.JumpVolume)
	local land = makeSound(root, "DR_Land", FOOT.LandSound, FOOT.LandVolume)
	for _, s in ipairs({ run, jump, land }) do s:SetAttribute("DinnerRush", true) end

	humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			jump:Play()
		elseif new == Enum.HumanoidStateType.Landed then
			land:Play()
		end
	end)

	--// the step loop plays only while actually moving on the ground
	conn = RunService.Heartbeat:Connect(function()
		if not humanoid.Parent then return end
		local onGround = humanoid.FloorMaterial ~= Enum.Material.Air
		local moving = humanoid.MoveDirection.Magnitude > 0.1
			and root.AssemblyLinearVelocity.Magnitude > 2
		if onGround and moving and humanoid.Health > 0 then
			run.PlaybackSpeed = FOOT.RunRateAtWalk * math.max(0.6, humanoid.WalkSpeed * FOOT.RunRatePerSpeed)
			if not run.IsPlaying then run:Play() end
		elseif run.IsPlaying then
			run:Stop()
		end
	end)
end

if player.Character then task.spawn(onCharacter, player.Character) end
player.CharacterAdded:Connect(onCharacter)
