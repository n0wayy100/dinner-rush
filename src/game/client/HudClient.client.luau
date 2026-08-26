--[[
	Dinner Rush - HudClient
	StarterPlayer.StarterPlayerScripts.Client.HudClient  (LocalScript)

	Drives the shift HUD from ReplicatedStorage.ShiftState, which the server
	publishes ~10x a second.

	Build the HUD however you like in StarterGui - containers, folders and
	nesting are all irrelevant. Only these NAMES matter, and each slot accepts
	either name, so the current build works as-is:

	  slot         accepted names                    gets
	  ---------------------------------------------------------------------
	  clock        ClockLabel / TimerLabel           "6:41"
	  rep          RepText / RepLabel                "60"
	  repBar       FillArea / RepBar                 width scales 0-100%
	  served       ServedLabel                       "3 / 15"
	  phase        PhaseLabel                        "Building"
	  difficulty   DiffLabel / DifficultyLabel       "Dinner Rush"
	  status       StatusLabel                       prep countdown / end report
	  walkouts     WalkoutsLabel                     "2"

	Everything is optional - missing slots are skipped and listed in Output.
	With no StatusLabel, the prep countdown falls back into the clock.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REFRESH_INTERVAL = 0.1 --// matches the server's publish rate

--// Display wording. The Config phase names stay Calm/Building/Crescendo -
--// only what the player reads changes here.
local PHASE_LABELS = {
	Calm = "OPENING",
	Building = "BUSY",
	Crescendo = "RUSH",
	Closing = "LAST TABLES",   -- doors shut, finishing the room
}

--// Text templates, so the HUD wording lives in one place
local function repText(value) return ("REP %d"):format(value) end
local function servedText(done, target) return ("%d/%d"):format(done, target) end

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

--// The HUD stays hidden until the shift is actually running.
--// Enabling the ScreenGui is not enough: a frame between it and the labels
--// with Visible unticked hides everything while every property still reads
--// as fine. Walk the chain and force it open.
local moneyReadout = nil --// only set when we had to build our own

local function setHudVisible(visible)
	if not hudGui then return end

	hudGui.Enabled = visible
	if moneyReadout then
		moneyReadout.Enabled = visible --// follows the HUD, hidden during prep
	end
	if not visible then return end

	local node = ui.clock
	while node and node ~= hudGui do
		if node:IsA("GuiObject") then
			node.Visible = true
		end
		node = node.Parent
	end
end

setHudVisible(false)

--// MONEY READOUT. If the HUD has no TillLabel of its own, build a plain one:
--// green text, top-left, under the shift panel. Placeholder by design - name
--// a label TillLabel / MoneyLabel / CashLabel in ShiftHud_UI and this stands
--// down and drives yours instead.
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

local function fmtClock(seconds)
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
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
		introValue.Text = ("%d / %d"):format(
			ShiftState:GetAttribute("Satisfied") or 0,
			ShiftState:GetAttribute("TargetParties") or 0)
		setHudVisible(true)
	else
		intro.Enabled = false
		setHudVisible(true)
	end

	setText(ui.clock, fmtClock(attr("TimeRemaining", 0)))

	local phase = attr("Phase", "")
	setText(ui.phase, PHASE_LABELS[phase] or phase)

	--// "NORMAL", matching the design. Swap to "DifficultyLabel" for "Dinner Rush".
	setText(ui.difficulty, attr("Difficulty", ""))

	local rep = attr("Reputation", 0)
	local repMax = attr("ReputationMax", 100)
	setText(ui.rep, repText(math.floor(rep)))
	if ui.repBar then
		ui.repBar.Size = UDim2.fromScale(math.clamp(rep / repMax, 0, 1), 1)
	end

	setText(ui.served, servedText(attr("Satisfied", 0), attr("TargetParties", 0)))

	--// The shared shift till, not anyone's personal balance
	--// The built-in readout says "Money: $120"; a HUD-authored TillLabel gets
	--// the same string, so either way it reads the same
	setText(ui.till, ("Money: $%d"):format(attr("Till", 0)))

	setText(ui.walkouts, tostring(
		(ShiftState:GetAttribute("DoorWalkouts") or 0)
		+ (ShiftState:GetAttribute("SeatedWalkouts") or 0)))

	if ui.status then
		if state == "WAITING" then
			setText(ui.status, "Waiting for players...")
		elseif state == "PREP" then
			setText(ui.status, ("Shift starts in %d..."):format(prep))
		elseif state == "ENDED" then
			setText(ui.status, ShiftState:GetAttribute("EndText") or "Shift over")
		else
			setText(ui.status, "")
		end
	end
end

refresh()

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < REFRESH_INTERVAL then return end
	since = 0
	refresh()
end)
