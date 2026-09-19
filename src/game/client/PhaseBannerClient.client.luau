--[[
	Dinner Rush - PhaseBannerClient
	StarterPlayer.StarterPlayerScripts.Client.PhaseBannerClient  (LocalScript)

	Big animated PHASE ANNOUNCEMENTS (owner spec, Sep 18 2026): when the
	shift changes stage the words slam onto the screen over a brief dim -
	OPENING! drops in and bounces, MID SHIFT! slides through, RUSH! slams
	huge and pulses, CLOSING! fades up gently. Pure UI tweens, driven by
	the ShiftState folder's Phase/State attributes - render-only, steals
	no input (nothing here is Active), and each stage fires once a shift.

	Words + timings in Config.PhaseBanner.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 60)
if not ShiftState then return end

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local BANNER = Config.PhaseBanner

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local TOMATO = Color3.fromRGB(229, 72, 77)
local CREAM = Color3.fromRGB(255, 246, 233)

local PHASE_COLORS = {
	Calm = BASIL,
	Building = MUSTARD,
	Crescendo = TOMATO,
	Closing = CREAM,
}

local gui = Instance.new("ScreenGui")
gui.Name = "PhaseBanner_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 45 --// over the HUD, under the shift report (60)
gui.Parent = playerGui

--// the dim: never Active, so taps pass straight through it
local dim = Instance.new("Frame")
dim.Size = UDim2.fromScale(1, 1)
dim.BackgroundColor3 = Color3.new(0, 0, 0)
dim.BackgroundTransparency = 1
dim.BorderSizePixel = 0
dim.Visible = false
dim.Parent = gui

local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0.5, 0.5)
label.Position = UDim2.fromScale(0.5, 0.42)
label.Size = UDim2.fromScale(0.8, 0.17)
label.BackgroundTransparency = 1
label.Font = Enum.Font.FredokaOne
label.TextScaled = true
label.Text = ""
label.TextColor3 = CREAM
label.Visible = false
label.Parent = gui
local labelCap = Instance.new("UITextSizeConstraint")
labelCap.MaxTextSize = 84
labelCap.Parent = label
--// Contextual on purpose: on display text the chunky GLYPH outline is
--// exactly the sticker look (Border is for boxes)
local outline = Instance.new("UIStroke")
outline.Thickness = 4
outline.Color = CHOC
outline.Parent = label
local scale = Instance.new("UIScale")
scale.Parent = label

local function tween(object, seconds, style, direction, props)
	local t = TweenService:Create(object,
		TweenInfo.new(seconds, style, direction), props)
	t:Play()
	return t
end

--// put every animated property back where the next entrance expects it
local function resetLabel()
	label.Visible = false
	label.Position = UDim2.fromScale(0.5, 0.42)
	label.TextTransparency = 0
	outline.Transparency = 0
	scale.Scale = 1
end

----------------------------------------------------------------
-- One entrance per stage - variety is the point (owner spec)
----------------------------------------------------------------
local ENTRANCES = {
	--// OPENING! drops from the sky and bounces on its landing
	Calm = function()
		label.Position = UDim2.fromScale(0.5, -0.2)
		label.Visible = true
		tween(label, 0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out,
			{ Position = UDim2.fromScale(0.5, 0.42) })
		task.wait(0.55 + BANNER.HoldSeconds)
		tween(label, 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
			{ Position = UDim2.fromScale(0.5, 0.3), TextTransparency = 1 })
		tween(outline, 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
			{ Transparency = 1 })
		task.wait(0.4)
	end,

	--// MID SHIFT! marches through, left to right
	Building = function()
		label.Position = UDim2.fromScale(-0.5, 0.42)
		label.Visible = true
		tween(label, 0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out,
			{ Position = UDim2.fromScale(0.5, 0.42) })
		task.wait(0.45 + BANNER.HoldSeconds)
		tween(label, 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
			{ Position = UDim2.fromScale(1.5, 0.42) })
		task.wait(0.35)
	end,

	--// RUSH! slams in huge, then pulses like a heartbeat
	Crescendo = function()
		scale.Scale = 3
		label.TextTransparency = 0.3
		label.Visible = true
		tween(label, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out,
			{ TextTransparency = 0 })
		tween(scale, 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out,
			{ Scale = 1 })
		task.wait(0.35)
		for _ = 1, 2 do
			tween(scale, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out,
				{ Scale = 1.15 })
			task.wait(0.12)
			tween(scale, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
				{ Scale = 1 })
			task.wait(0.14)
		end
		task.wait(BANNER.HoldSeconds * 0.6)
		tween(scale, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
			{ Scale = 0.7 })
		tween(label, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
			{ TextTransparency = 1 })
		tween(outline, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In,
			{ Transparency = 1 })
		task.wait(0.3)
	end,

	--// CLOSING! breathes in softly and drifts away - the night winds down
	Closing = function()
		label.Position = UDim2.fromScale(0.5, 0.48)
		label.TextTransparency = 1
		outline.Transparency = 1
		label.Visible = true
		tween(label, 0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.Out,
			{ Position = UDim2.fromScale(0.5, 0.42), TextTransparency = 0 })
		tween(outline, 0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.Out,
			{ Transparency = 0 })
		task.wait(0.7 + BANNER.HoldSeconds)
		tween(label, 0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.In,
			{ TextTransparency = 1 })
		tween(outline, 0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.In,
			{ Transparency = 1 })
		task.wait(0.8)
	end,
}

----------------------------------------------------------------
-- The player queue: stages announce one at a time, never on top of
-- each other (a lightning-fast shift just shows them back to back)
----------------------------------------------------------------
local queue = {}

task.spawn(function()
	while true do
		local phaseKey = table.remove(queue, 1)
		if phaseKey then
			label.Text = BANNER.Labels[phaseKey] or phaseKey
			label.TextColor3 = PHASE_COLORS[phaseKey] or CREAM

			dim.Visible = true
			tween(dim, BANNER.DimSeconds, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out,
				{ BackgroundTransparency = BANNER.DimTransparency })

			--// a label with no matching entrance borrows the gentle one
			local entrance = ENTRANCES[phaseKey] or ENTRANCES.Closing
			entrance()

			tween(dim, BANNER.DimSeconds, Enum.EasingStyle.Quad,
				Enum.EasingDirection.In, { BackgroundTransparency = 1 })
			task.wait(BANNER.DimSeconds)
			dim.Visible = false
			resetLabel()
		else
			task.wait(0.1)
		end
	end
end)

----------------------------------------------------------------
-- Triggers: each stage once per shift, transitions only - a player
-- who joins mid-shift is not shouted at about the stage already on
----------------------------------------------------------------
local seen = {}

local function onPhase()
	local state = ShiftState:GetAttribute("State")
	if state ~= "RUNNING" and state ~= "CLOSING" then return end
	local phase = ShiftState:GetAttribute("Phase") or ""
	if BANNER.Labels[phase] and not seen[phase] then
		seen[phase] = true
		table.insert(queue, phase)
	end
end

--// joining mid-shift: the current stage is old news, not an event
if ShiftState:GetAttribute("State") == "RUNNING"
	or ShiftState:GetAttribute("State") == "CLOSING" then
	seen[ShiftState:GetAttribute("Phase") or ""] = true
end

--// STUDIO KNOB (live-ignored): parade all four banners back to back a
--// few seconds in, so the whole set can be reviewed in one Play
if game:GetService("RunService"):IsStudio() and BANNER.StudioParade then
	task.delay(3, function()
		for _, key in ipairs({ "Calm", "Building", "Crescendo", "Closing" }) do
			seen[key] = true --// the real transitions stay quiet meanwhile
			table.insert(queue, key)
		end
	end)
end

ShiftState:GetAttributeChangedSignal("Phase"):Connect(onPhase)
ShiftState:GetAttributeChangedSignal("State"):Connect(function()
	local state = ShiftState:GetAttribute("State")
	if state == "RUNNING" then
		seen = {} --// a fresh shift announces from the top
		onPhase()
	elseif state == "CLOSING" then
		onPhase()
	end
end)
