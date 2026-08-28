--[[
	Dinner Rush - SprintClient
	StarterPlayer.StarterPlayerScripts.Client.SprintClient  (LocalScript)

	Hold-to-sprint with a stamina bar. Every number lives in Config.Sprint.

	  keyboard   double-tap W, then keep W held
	  mobile     ContextActionService touch button (sits above the jump button)
	  gamepad    press the left thumbstick (L3)

	DELIBERATE exception to the server-authority rule: sprint is client-side.
	Roblox gives clients physics ownership of their own character, so local
	WalkSpeed is the standard, responsive pattern. The constitution's rule
	guards game STATE (money, stock, reputation) - not movement feel. Co-op
	PvE; no speed anti-cheat, by scope.

	Behavior:
	  * A sprint STARTS only while held + moving + stamina >= MinStaminaToStart.
	  * While a sprint is live, WalkSpeed stays at SprintSpeed, but stamina
	    only DRAINS while actually moving - idling with the key down is free.
	  * At 0 the sprint force-ends and cannot restart until MinStaminaToStart.
	  * Regen starts RegenDelaySeconds after the sprint ends, caps at max.
	  * Death/respawn: full stamina, base WalkSpeed, FOV restored - never a
	    stuck-fast or stuck-slow character.

	The bar (code-built, house style): slim cream pill, bottom-left corner,
	mustard fill flipping tomato below LowStaminaFraction.
	Deliberately NOT the rep bar's three-stage green/yellow/red - the two
	must never be confusable. Only on screen while stamina < max, fades out
	BarLingerSeconds after refilling.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Sprint = Config.Sprint

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)

local ACTION = "DinnerRushSprint"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local tweenInfo = TweenInfo.new(Sprint.TweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

----------------------------------------------------------------
-- Stamina bar (built once; CanvasGroup so the whole thing fades as one)
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Stamina_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 15 --// under the kitchen menu and event banner
gui.Parent = playerGui

local bar = Instance.new("CanvasGroup")
bar.Name = "StaminaBar"
bar.AnchorPoint = Vector2.new(0, 1)
bar.Position = UDim2.fromScale(0.03, 0.95) --// bottom-left corner
bar.Size = UDim2.fromScale(0.16, 0.018)
bar.BackgroundColor3 = CREAM
bar.GroupTransparency = 1 --// starts hidden: stamina starts full
bar.Parent = gui

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = bar

local barStroke = Instance.new("UIStroke")
barStroke.Thickness = 2
barStroke.Color = CHOC
barStroke.Parent = bar

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 2)
pad.PaddingBottom = UDim.new(0, 2)
pad.PaddingLeft = UDim.new(0, 2)
pad.PaddingRight = UDim.new(0, 2)
pad.Parent = bar

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(1, 1)
fill.BackgroundColor3 = MUSTARD
fill.BorderSizePixel = 0
fill.Parent = bar

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

local shown = false
local fadeTween

local function setShown(visible)
	if shown == visible then return end
	shown = visible
	if fadeTween then fadeTween:Cancel() end
	fadeTween = TweenService:Create(bar, tweenInfo, { GroupTransparency = visible and 0 or 1 })
	fadeTween:Play()
end

----------------------------------------------------------------
-- FOV kick
----------------------------------------------------------------
local baseFov = nil
local fovTween

local function setFovKick(on)
	if Sprint.FovKick == 0 then return end
	local camera = workspace.CurrentCamera
	if not camera then return end

	--// Captured once and kept: nothing else in this codebase moves FOV, and
	--// re-reading mid-tween would slowly drift the baseline
	if baseFov == nil then
		baseFov = camera.FieldOfView
	end

	if fovTween then fovTween:Cancel() end
	fovTween = TweenService:Create(camera, tweenInfo, {
		FieldOfView = baseFov + (on and Sprint.FovKick or 0),
	})
	fovTween:Play()
end

----------------------------------------------------------------
-- Sprint state machine
----------------------------------------------------------------
local stamina = Sprint.StaminaMax
local held = false
local active = false
local lastActiveAt = 0 --// os.clock() of the last sprinting moment (regen delay anchor)
local fullSince = 0

local humanoid = nil
local sprintTrack = nil
local animWarned = false

--// Optional custom sprint animation. With the id empty this whole path is
--// dormant and the default run animation's WalkSpeed scaling carries the feel.
local function playSprintAnim()
	if Sprint.SprintAnimationId == "" or not humanoid then return end

	if not sprintTrack then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then return end

		local animation = Instance.new("Animation")
		animation.AnimationId = Sprint.SprintAnimationId
		local ok, track = pcall(animator.LoadAnimation, animator, animation)
		if not ok then
			if not animWarned then
				animWarned = true
				warn("[SprintClient] SprintAnimationId failed to load: " .. tostring(track))
			end
			return
		end
		sprintTrack = track
	end

	sprintTrack:Play(0.15)
end

local function stopSprintAnim()
	if sprintTrack and sprintTrack.IsPlaying then
		sprintTrack:Stop(0.15)
	end
end

local function startSprint()
	if active then return end
	active = true
	if humanoid then
		humanoid.WalkSpeed = Sprint.SprintSpeed
	end
	setFovKick(true)
	playSprintAnim()
end

local function endSprint()
	if not active then return end
	active = false
	lastActiveAt = os.clock()
	if humanoid and humanoid.Health > 0 then
		humanoid.WalkSpeed = Sprint.BaseWalkSpeed
	end
	setFovKick(false)
	stopSprintAnim()
end

----------------------------------------------------------------
-- Input: one ContextActionService action covers all three platforms.
-- The third argument makes the mobile touch button; L3 is the console-
-- standard sprint press.
----------------------------------------------------------------
--// DOUBLE-TAP W. LeftShift is Roblox's own shift-lock toggle, so sprinting
--// on it meant every sprint fought the camera. Two quick taps of W start the
--// run; holding W keeps it; releasing W ends it.
local lastWTapAt = 0

local function onSprintAction(_, inputState, inputObject)
	local key = inputObject and inputObject.KeyCode

	if key == Enum.KeyCode.W then
		if inputState == Enum.UserInputState.Begin then
			local now = os.clock()
			if now - lastWTapAt <= Sprint.DoubleTapSeconds then
				held = true      --// second tap inside the window: run
				lastWTapAt = 0   --// consumed, so a third tap starts a fresh pair
			else
				lastWTapAt = now
			end
		elseif inputState == Enum.UserInputState.End
			or inputState == Enum.UserInputState.Cancel then
			if Sprint.StopOnRelease then
				held = false
			end
		end
	else
		--// Touch button and gamepad L3 stay plain hold-to-sprint: there is
		--// nothing to double-tap on a thumbstick.
		if inputState == Enum.UserInputState.Begin then
			held = true
		elseif inputState == Enum.UserInputState.End
			or inputState == Enum.UserInputState.Cancel then
			held = false
		end
	end

	--// Pass, never Sink: W still has to reach the movement controller, or
	--// binding sprint to it would stop the player walking forward.
	return Enum.ContextActionResult.Pass
end

ContextActionService:BindAction(ACTION, onSprintAction, true,
	Enum.KeyCode.W, Enum.KeyCode.ButtonL3)
ContextActionService:SetTitle(ACTION, "SPRINT")
--// Inside the touch-button frame (bottom-right cluster): roughly above the
--// jump button. Nudge to taste in the Device emulator.
ContextActionService:SetPosition(ACTION, UDim2.new(0.75, 0, 0.05, 0))

----------------------------------------------------------------
-- Character lifecycle
----------------------------------------------------------------
local function onCharacterAdded(character)
	sprintTrack = nil --// old track died with the old Animator
	humanoid = character:WaitForChild("Humanoid")

	--// Fresh spawn: full tank, normal speed - never stuck fast or slow
	stamina = Sprint.StaminaMax
	active = false
	humanoid.WalkSpeed = Sprint.BaseWalkSpeed

	humanoid.Died:Connect(function()
		endSprint() --// restores FOV; WalkSpeed reset happens on the next spawn
	end)
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end

----------------------------------------------------------------
-- Main loop
----------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()

	if humanoid and humanoid.Health > 0 then
		local moving = humanoid.MoveDirection.Magnitude > 0.05

		if active then
			if not held or stamina <= 0 then
				endSprint()
			elseif moving then
				--// WAITER PASSIVE: drain/regen multipliers arrive as Player
				--// attributes from the server's ClassService (default 1)
				stamina = math.max(0, stamina - Sprint.DrainPerSecond
					* (player:GetAttribute("StaminaDrainMult") or 1) * dt)
				lastActiveAt = now
				if stamina <= 0 then
					endSprint()
				end
			else
				--// Held but standing still: no drain, but still "sprinting",
				--// so the regen delay keeps waiting too
				lastActiveAt = now
			end
		elseif held and moving and stamina >= Sprint.MinStaminaToStart then
			startSprint()
		end

		if not active and stamina < Sprint.StaminaMax
			and now - lastActiveAt >= Sprint.RegenDelaySeconds then
			stamina = math.min(Sprint.StaminaMax, stamina + Sprint.RegenPerSecond
				* (player:GetAttribute("StaminaRegenMult") or 1) * dt)
		end
	end

	--// Bar render + visibility
	local frac = stamina / Sprint.StaminaMax
	fill.Size = UDim2.fromScale(frac, 1)
	fill.BackgroundColor3 = frac < Sprint.LowStaminaFraction and TOMATO or MUSTARD

	if frac < 1 then
		fullSince = nil
		setShown(true)
	else
		fullSince = fullSince or now
		if now - fullSince >= Sprint.BarLingerSeconds then
			setShown(false)
		end
	end
end)

print(("[SprintClient] ready - double-tap W / touch / L3, speed %d -> %d")
	:format(Sprint.BaseWalkSpeed, Sprint.SprintSpeed))
