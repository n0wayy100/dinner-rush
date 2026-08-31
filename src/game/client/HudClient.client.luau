--[[
	Dinner Rush - HudClient
	StarterPlayer.StarterPlayerScripts.Client.HudClient  (LocalScript)

	Drives the shift HUD from ReplicatedStorage.ShiftState, which the server
	publishes ~10x a second.

	OWNER RULING (Aug 2026): the old Studio-built ShiftHud_UI panel is
	RETIRED - this script finds it (name-based slot resolution, kept so
	the anchor/geometry plumbing still works) and keeps its ScreenGui
	DISABLED forever. The owner can delete it from StarterGui whenever.

	What the player actually sees, all code-built here:
	  - the SHIFT BAR: a burger travels a phase-map track (basil OPENING /
	    mustard BUSY / tomato RUSH) with a phase-word chip - NO numeric
	    clock anywhere, the burger's position is all the time info
	  - the REP METER: left-edge pill, three-stage bar
	  - the MONEY READOUT: green "Money: $X", top-left
	  - the intro overlay: waiting / prep countdown / end-of-shift reveal
	    ("N parties served" - no target framing)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REFRESH_INTERVAL = 0.1 --// matches the server's publish rate

local Config = require(game:GetService("ReplicatedStorage")
	:WaitForChild("Shared"):WaitForChild("Config"))

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)

--// Display wording. The Config phase names stay Calm/Building/Crescendo -
--// only what the player reads changes here.
local PHASE_LABELS = {
	Calm = "OPENING",
	Building = "BUSY",
	Crescendo = "RUSH",
	Closing = "LAST TABLES",   -- doors shut, finishing the room
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--// Created by ServiceLoop once grey-box validation passes. If that is stuck,
--// waiting forever here would leave the player staring at nothing - so give up
--// after a while, say so, and keep the HUD on screen regardless.
local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 20)
if not ShiftState then
	warn("[HudClient] ReplicatedStorage.ShiftState never appeared - is ServiceLoop still waiting on the grey-box?")
	warn("[HudClient] showing the HUD anyway; values will not update")
end

--// Each slot lists the names it will answer to, most specific first
local SLOTS = {
	{ key = "clock",      names = { "ClockLabel", "TimerLabel" } },
	{ key = "rep",        names = { "RepText", "RepLabel" } },
	{ key = "repBar",     names = { "FillArea", "RepBar" } },
	{ key = "served",     names = { "ServedLabel" } },
	{ key = "phase",      names = { "PhaseLabel" } },
	{ key = "difficulty", names = { "DiffLabel", "DifficultyLabel" } },
	{ key = "status",     names = { "StatusLabel" } },
	{ key = "walkouts",   names = { "WalkoutsLabel" } },
	{ key = "till",       names = { "TillLabel", "MoneyLabel", "CashLabel" } },
}

local ui = {}

local function resolve()
	local found, missing = {}, {}

	for _, slot in ipairs(SLOTS) do
		local instance
		for _, name in ipairs(slot.names) do
			instance = playerGui:FindFirstChild(name, true)
			if instance then break end
		end
		ui[slot.key] = instance
		table.insert(instance and found or missing, slot.key)
	end

	return found, missing
end

--// Wait until at least one slot exists, so the script survives the HUD being
--// built or re-parented after the player spawns
--// StarterGui clones into PlayerGui around the first spawn, a moment after
--// this script starts. Poll quickly so the intro overlay is up immediately,
--// and only complain once it is late enough to mean a real problem.
local found, missing = resolve()
local waited = 0
while #found == 0 do
	task.wait(0.1)
	waited += 0.1
	if waited % 5 < 0.1 then
		warn("[HudClient] No HUD elements found in PlayerGui yet - still waiting")
	end
	found, missing = resolve()
end

--// ResetOnSpawn belongs to the ScreenGui, not the frame inside it. Left true,
--// respawning destroys the HUD and clones a fresh one, leaving every
--// reference here pointing at a deleted object.
local hudGui
do
	local anchor = ui[found[1]]
	hudGui = anchor and anchor:FindFirstAncestorOfClass("ScreenGui")
	if hudGui then
		hudGui.ResetOnSpawn = false
		print(("[HudClient] HUD at %s"):format(hudGui:GetFullName()))
	end
end

--// Full path of each slot, so a label that is not updating can be traced to
--// the exact instance the script grabbed (or did not)
print("[HudClient] driving:")
for _, key in ipairs(found) do
	print(("   %s -> %s"):format(key, ui[key]:GetFullName()))
end
if #missing > 0 then
	print("[HudClient] not present (optional): " .. table.concat(missing, ", "))
end

----------------------------------------------------------------
-- Centre-screen shift intro: the prep countdown, then out of the way
----------------------------------------------------------------
local intro, introTitle, introValue
do
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShiftIntro"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50 --// above the HUD
	gui.Parent = playerGui

	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.45)
	holder.Size = UDim2.fromScale(0.6, 0.3)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = holder

	introTitle = Instance.new("TextLabel")
	introTitle.Name = "Title"
	introTitle.Size = UDim2.fromScale(1, 0.3)
	introTitle.BackgroundTransparency = 1
	introTitle.Font = Enum.Font.FredokaOne
	introTitle.TextScaled = true
	introTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	introTitle.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	introTitle.TextStrokeTransparency = 0
	introTitle.Text = "SHIFT STARTS IN"
	introTitle.LayoutOrder = 1
	introTitle.Parent = holder

	introValue = Instance.new("TextLabel")
	introValue.Name = "Value"
	introValue.Size = UDim2.fromScale(1, 0.6)
	introValue.BackgroundTransparency = 1
	introValue.Font = Enum.Font.FredokaOne
	introValue.TextScaled = true
	introValue.TextColor3 = Color3.fromRGB(245, 184, 65)
	introValue.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	introValue.TextStrokeTransparency = 0
	introValue.Text = "0"
	introValue.LayoutOrder = 2
	introValue.Parent = holder

	intro = gui
end

--// Owner ruling (Aug 2026): the old Studio panel is RETIRED - its
--// ScreenGui stays disabled forever (the code-built shift bar, rep
--// meter and money readout own the screen now). "Visible" only governs
--// the code-built pieces. The owner can delete StarterGui's ShiftHud_UI
--// in Studio whenever; nothing reads from it any more.
local moneyReadout = nil --// only set when we had to build our own

local function setHudVisible(visible)
	if hudGui then
		hudGui.Enabled = false
	end
	if moneyReadout then
		moneyReadout.Enabled = visible --// hidden during prep, like the rest
	end
end

setHudVisible(false)

--// MONEY READOUT. The old panel is retired, so a TillLabel found inside
--// it counts as missing - the code-built green readout takes over.
if ui.till and hudGui and ui.till:IsDescendantOf(hudGui) then
	ui.till = nil
end
if not ui.till then
	local moneyGui = Instance.new("ScreenGui")
	moneyGui.Name = "MoneyReadout_UI"
	moneyGui.ResetOnSpawn = false
	moneyGui.IgnoreGuiInset = true
	moneyGui.DisplayOrder = 15
	moneyGui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Name = "TillLabel"
	label.AnchorPoint = Vector2.new(0, 0)
	label.Position = UDim2.fromScale(0.02, 0.16)
	label.Size = UDim2.fromScale(0.2, 0.05)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(76, 175, 109) --// basil green
	label.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	label.TextStrokeTransparency = 0
	label.Text = "Money: $0"
	label.Parent = moneyGui

	ui.till = label
	moneyReadout = moneyGui
	print("[HudClient] no TillLabel in the HUD - built a placeholder money readout")
end

local function setText(label, text)
	if label then
		label.Text = text
	end
end

--// Reading through a helper so a missing ShiftState degrades to defaults
--// instead of erroring every frame
local function attr(name, fallback)
	if not ShiftState then return fallback end
	local value = ShiftState:GetAttribute(name)
	if value == nil then return fallback end
	return value
end

----------------------------------------------------------------
-- THE SHIFT BAR (owner request, Aug 2026): the clock is a journey now.
-- A burger travels a track painted with the night's actual phase map -
-- basil OPENING, mustard BUSY, tomato RUSH, boundaries at the real
-- Config.Shift.Phases fractions - from the opening bell to the moon.
-- A dark chip below reads "BUSY · 5:12". Replaces the old panel's
-- clock + phase slots (parked hidden in refresh).
----------------------------------------------------------------
local shiftBarGui, trackGradient, marker, chipText
do
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShiftProgress_UI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Track"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.fromScale(0.5, 0.025)
	frame.Size = UDim2.fromScale(0.4, 0.05)
	frame.BackgroundColor3 = CREAM
	frame.Parent = gui

	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(1, 0)
	fc.Parent = frame

	local fs = Instance.new("UIStroke")
	fs.Thickness = 3
	fs.Color = CHOC
	fs.Parent = frame

	--// The phase map: one gradient, painted per shift length
	local lane = Instance.new("Frame")
	lane.Name = "Lane"
	lane.AnchorPoint = Vector2.new(0.5, 0.5)
	lane.Position = UDim2.fromScale(0.5, 0.5)
	lane.Size = UDim2.fromScale(0.965, 0.6)
	lane.BackgroundColor3 = Color3.new(1, 1, 1)
	lane.BorderSizePixel = 0
	lane.Parent = frame

	local lc = Instance.new("UICorner")
	lc.CornerRadius = UDim.new(1, 0)
	lc.Parent = lane

	trackGradient = Instance.new("UIGradient")
	trackGradient.Color = ColorSequence.new(BASIL, TOMATO)
	trackGradient.Parent = lane

	--// The ends of the night: opening bell -> the moon
	local openIcon = Instance.new("TextLabel")
	openIcon.AnchorPoint = Vector2.new(0, 0.5)
	openIcon.Position = UDim2.fromScale(-0.015, 0.5)
	openIcon.Size = UDim2.fromScale(0.08, 1.3)
	openIcon.BackgroundTransparency = 1
	openIcon.Font = Enum.Font.FredokaOne
	openIcon.TextScaled = true
	openIcon.Text = "🔔"
	openIcon.ZIndex = 4
	openIcon.Parent = frame

	local closeIcon = Instance.new("TextLabel")
	closeIcon.AnchorPoint = Vector2.new(1, 0.5)
	closeIcon.Position = UDim2.fromScale(1.015, 0.5)
	closeIcon.Size = UDim2.fromScale(0.08, 1.3)
	closeIcon.BackgroundTransparency = 1
	closeIcon.Font = Enum.Font.FredokaOne
	closeIcon.TextScaled = true
	closeIcon.Text = "🌙"
	closeIcon.ZIndex = 4
	closeIcon.Parent = frame

	--// The traveller
	marker = Instance.new("TextLabel")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.fromScale(0.02, 0.5)
	marker.Size = UDim2.fromScale(0.09, 1.55)
	marker.BackgroundTransparency = 1
	marker.Font = Enum.Font.FredokaOne
	marker.TextScaled = true
	marker.Text = "🍔"
	marker.TextStrokeColor3 = CHOC
	marker.TextStrokeTransparency = 0.6
	marker.ZIndex = 6
	marker.Parent = lane

	--// The chip: "BUSY · 5:12", dark like a road sign
	local chip = Instance.new("Frame")
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.Position = UDim2.fromScale(0.5, 1.18)
	chip.Size = UDim2.fromScale(0.3, 0.85)
	chip.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	chip.BackgroundTransparency = 0.12
	chip.Parent = frame

	local chc = Instance.new("UICorner")
	chc.CornerRadius = UDim.new(0, 8)
	chc.Parent = chip

	chipText = Instance.new("TextLabel")
	chipText.AnchorPoint = Vector2.new(0.5, 0.5)
	chipText.Position = UDim2.fromScale(0.5, 0.5)
	chipText.Size = UDim2.fromScale(0.9, 0.78)
	chipText.BackgroundTransparency = 1
	chipText.Font = Enum.Font.FredokaOne
	chipText.TextScaled = true
	chipText.TextColor3 = Color3.new(1, 1, 1)
	chipText.Text = ""
	chipText.Parent = chip

	shiftBarGui = gui
end

local lastPaintedLength = nil

local function updateShiftBar(state)
	local onDuty = state == "RUNNING" or state == "CLOSING"
	shiftBarGui.Enabled = onDuty
	if not onDuty then return end

	local length = attr("Length", 0)
	if length <= 0 then length = 480 end

	--// Paint the night's phase map once per shift (sharp-ish handovers)
	if lastPaintedLength ~= length then
		lastPaintedLength = length
		local calmAt = math.clamp(Config.Shift.Phases.CalmEndsAt / length, 0.08, 0.8)
		local buildAt = math.clamp(Config.Shift.Phases.BuildingEndsAt / length,
			calmAt + 0.08, 0.92)
		trackGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, BASIL),
			ColorSequenceKeypoint.new(calmAt - 0.03, BASIL),
			ColorSequenceKeypoint.new(calmAt + 0.03, MUSTARD),
			ColorSequenceKeypoint.new(buildAt - 0.03, MUSTARD),
			ColorSequenceKeypoint.new(buildAt + 0.03, TOMATO),
			ColorSequenceKeypoint.new(1, TOMATO),
		})
	end

	local remaining = attr("TimeRemaining", 0)
	local fraction = state == "CLOSING" and 1
		or 1 - math.clamp(remaining / length, 0, 1)
	marker.Position = UDim2.fromScale(math.clamp(fraction, 0.02, 0.98), 0.5)

	--// Owner ruling: players never see the clock as a NUMBER - the
	--// burger's position is all the time information they get
	local phase = attr("Phase", "")
	chipText.Text = PHASE_LABELS[phase] or phase
end

----------------------------------------------------------------
-- THE REP METER (owner request: rep lives apart from the clock now).
-- Small top-left pill: "REP" + a bar in the three-stage language -
-- basil healthy, mustard worried, tomato dying.
----------------------------------------------------------------
local repMeterGui, repFill
do
	local gui = Instance.new("ScreenGui")
	gui.Name = "RepMeter_UI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0, 0)
	--// Below Roblox's own chat/mic buttons (top-left corner) and above
	--// the money readout at 0.16 - the one strip of left edge nobody owns
	panel.Position = UDim2.fromScale(0.02, 0.1)
	panel.Size = UDim2.fromScale(0.16, 0.045)
	panel.BackgroundColor3 = CREAM
	panel.Parent = gui

	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(1, 0)
	pc.Parent = panel

	local ps = Instance.new("UIStroke")
	ps.Thickness = 3
	ps.Color = CHOC
	ps.Parent = panel

	local tag = Instance.new("TextLabel")
	tag.AnchorPoint = Vector2.new(0, 0.5)
	tag.Position = UDim2.fromScale(0.06, 0.5)
	tag.Size = UDim2.fromScale(0.24, 0.72)
	tag.BackgroundTransparency = 1
	tag.Font = Enum.Font.FredokaOne
	tag.TextScaled = true
	tag.TextColor3 = CHOC
	tag.Text = "REP"
	tag.Parent = panel

	local back = Instance.new("Frame")
	back.AnchorPoint = Vector2.new(1, 0.5)
	back.Position = UDim2.fromScale(0.94, 0.5)
	back.Size = UDim2.fromScale(0.6, 0.55)
	back.BackgroundColor3 = Color3.fromRGB(235, 220, 200)
	back.ClipsDescendants = true
	back.Parent = panel

	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(1, 0)
	bc.Parent = back

	local bs = Instance.new("UIStroke")
	bs.Thickness = 2
	bs.Color = CHOC
	bs.Parent = back

	repFill = Instance.new("Frame")
	repFill.Size = UDim2.fromScale(1, 1)
	repFill.BackgroundColor3 = BASIL
	repFill.BorderSizePixel = 0
	repFill.Parent = back

	local rfc = Instance.new("UICorner")
	rfc.CornerRadius = UDim.new(1, 0)
	rfc.Parent = repFill

	repMeterGui = gui
end

local function updateRepMeter(state, rep, repMax)
	local onDuty = state == "RUNNING" or state == "CLOSING"
	repMeterGui.Enabled = onDuty
	if not onDuty then return end

	local fraction = math.clamp(rep / math.max(repMax, 1), 0, 1)
	repFill.Size = UDim2.fromScale(fraction, 1)
	repFill.BackgroundColor3 = fraction > 0.5 and BASIL
		or fraction > 0.25 and MUSTARD
		or TOMATO
end

local lastState
local dumpedGeometry = false

--// Walks from a label up to the ScreenGui reporting what each ancestor does
--// to visibility. A zero AbsoluteSize, an off-screen AbsolutePosition, or a
--// Visible=false anywhere in the chain all render the HUD invisible while
--// every property you would think to check still looks correct.
function dumpHudGeometry()
	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	print(("[HudClient] === geometry dump === viewport %s"):format(tostring(viewport)))

	local node = ui.clock
	while node and node ~= playerGui do
		if node:IsA("GuiObject") then
			print(("   %s (%s) Visible=%s Pos=%s Size=%s BgTransparency=%.2f")
				:format(node.Name, node.ClassName, tostring(node.Visible),
					tostring(node.AbsolutePosition), tostring(node.AbsoluteSize),
					node.BackgroundTransparency))
		elseif node:IsA("ScreenGui") then
			print(("   %s (ScreenGui) Enabled=%s DisplayOrder=%d")
				:format(node.Name, tostring(node.Enabled), node.DisplayOrder))
		else
			print(("   %s (%s)"):format(node.Name, node.ClassName))
		end
		node = node.Parent
	end
	print("[HudClient] === end dump ===")
end

local function refresh()
	--// No ShiftState at all: show the HUD rather than hide it behind an
	--// overlay that will never clear
	if not ShiftState then
		intro.Enabled = false
		setHudVisible(true)
		return
	end

	local state = attr("State", "WAITING")
	local prep = math.ceil(attr("PrepRemaining", 0))

	local hudHidden = (state == "WAITING") or (state == "PREP")
	if state ~= lastState then
		lastState = state
		print(("[HudClient] shift state -> %s (hud %s)"):format(
			state, hudHidden and "hidden" or "visible"))

		--// One-shot geometry dump the first time the HUD should be on screen.
		--// AbsolutePosition/AbsoluteSize are what actually decides whether you
		--// can see it - Enabled being true proves nothing on its own.
		if state == "RUNNING" and not dumpedGeometry then
			dumpedGeometry = true
			task.defer(dumpHudGeometry)
		end
	end

	--// Intro overlay owns the screen until the shift starts, then hands over
	if state == "WAITING" then
		intro.Enabled = true
		introTitle.Text = "WAITING FOR PLAYERS"
		introValue.Text = "..."
		setHudVisible(false)
	elseif state == "PREP" then
		intro.Enabled = true
		introTitle.Text = "SHIFT STARTS IN"
		introValue.Text = tostring(math.max(0, prep))
		setHudVisible(false)
	elseif state == "ENDED" then
		intro.Enabled = true
		introTitle.Text = ShiftState:GetAttribute("EndText") or "SHIFT OVER"
		--// The end-of-shift reveal: just the count, no target framing
		introValue.Text = ("%d parties served"):format(
			ShiftState:GetAttribute("Satisfied") or 0)
		setHudVisible(true)
	else
		intro.Enabled = false
		setHudVisible(true)
	end

	--// The old Studio panel is disabled outright (see setHudVisible) -
	--// these two code-built pieces are the whole shift readout now
	updateShiftBar(state)
	updateRepMeter(state, attr("Reputation", 0), attr("ReputationMax", 100))

	--// The shared shift till, not anyone's personal balance
	setText(ui.till, ("Money: $%d"):format(attr("Till", 0)))
end

refresh()

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < REFRESH_INTERVAL then return end
	since = 0
	refresh()
end)
