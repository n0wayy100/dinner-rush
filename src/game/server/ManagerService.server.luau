--[[
	Dinner Rush - ManagerService
	ServerScriptService.Server.ManagerService  (Script)

	Manager Bruno's BRAIN. Decides when the commentator speaks and which
	phrase pool the line comes from; the client only renders. With every
	number hidden from players, Bruno is the soft warning system - phase
	turns, closing and crises get announced in vibes.

	Reads what already replicates - ReplicatedStorage.ShiftState (phases,
	rep, walkouts) and EventState (emergencies) - no new bridges into the
	other services. Publishes to a ReplicatedStorage ManagerState folder:
	  LineId (int, bumps per line)  ·  Line (string)  ·  Pool (string)

	Anti-spam: one global cooldown (Config.Manager.MinSecondsBetweenLines).
	Urgent moments (phase turns, fires, floods, panic) cut through it;
	casual grumbles (walkouts, relief) wait their turn or stay unsaid.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MANAGER = Config.Manager

local ManagerState = Instance.new("Folder")
ManagerState.Name = "ManagerState"
ManagerState:SetAttribute("LineId", 0)
ManagerState:SetAttribute("Line", "")
ManagerState:SetAttribute("Pool", "")
ManagerState.Parent = ReplicatedStorage

local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 30)
if not ShiftState then
	warn("[Manager] no ShiftState folder - Bruno stays silent")
	return
end

----------------------------------------------------------------
-- Speaking
----------------------------------------------------------------
local nextAllowedAt = 0
local lastPick = {} --// [poolName] = last index, so lines don't repeat back-to-back
local lineId = 0

local function shiftOpen()
	local state = ShiftState:GetAttribute("State")
	return state == "RUNNING" or state == "CLOSING"
end

local function speak(poolName, urgent)
	if not shiftOpen() then return end
	local pool = MANAGER.Lines[poolName]
	if not pool or #pool == 0 then return end

	local now = os.clock()
	if not urgent and now < nextAllowedAt then
		return --// Bruno just spoke; a casual line stays unsaid
	end

	local index = math.random(#pool)
	if #pool > 1 and index == lastPick[poolName] then
		index = index % #pool + 1
	end
	lastPick[poolName] = index

	nextAllowedAt = now + MANAGER.MinSecondsBetweenLines
	lineId += 1
	ManagerState:SetAttribute("Line", pool[index])
	ManagerState:SetAttribute("Pool", poolName)
	ManagerState:SetAttribute("LineId", lineId)
end

----------------------------------------------------------------
-- Shift story beats: start, phase turns, closing
----------------------------------------------------------------
local lastShiftState = ShiftState:GetAttribute("State")
ShiftState:GetAttributeChangedSignal("State"):Connect(function()
	local state = ShiftState:GetAttribute("State")
	if state == "RUNNING" and lastShiftState ~= "RUNNING" then
		task.delay(2, function() --// let the doors-open moment breathe first
			speak("ShiftStart", true)
		end)
	elseif state == "CLOSING" and lastShiftState ~= "CLOSING" then
		speak("Closing", true)
	end
	lastShiftState = state
end)

local lastPhase = ShiftState:GetAttribute("Phase")
ShiftState:GetAttributeChangedSignal("Phase"):Connect(function()
	local phase = ShiftState:GetAttribute("Phase")
	if phase == lastPhase then return end
	lastPhase = phase
	if phase == "Building" then
		speak("PhaseBusy", true)
	elseif phase == "Crescendo" then
		speak("PhaseRush", true) --// the big one: the rush is CALLED, not clocked
	end
	--// "Closing" is announced by the State watcher, not twice
end)

----------------------------------------------------------------
-- Reputation: worried / panicked / recovered, with hysteresis
----------------------------------------------------------------
local repMood = "fine" --// fine / worried / panicked
ShiftState:GetAttributeChangedSignal("Reputation"):Connect(function()
	local rep = ShiftState:GetAttribute("Reputation") or 0
	local max = ShiftState:GetAttribute("ReputationMax") or 100
	local fraction = rep / math.max(max, 1)

	if repMood ~= "panicked" and fraction <= MANAGER.RepPanicFraction then
		repMood = "panicked"
		speak("RepPanic", true)
	elseif repMood == "fine" and fraction <= MANAGER.RepWorryFraction then
		repMood = "worried"
		speak("RepWorry", false)
	elseif repMood ~= "fine" and fraction >= MANAGER.RepRecoverFraction then
		repMood = "fine"
		speak("RepRecovered", false)
	end
end)

----------------------------------------------------------------
-- Walkouts: an occasional grumble, never a nag
----------------------------------------------------------------
local lastWalkouts = 0
local lastGrumbleAt = 0

local function walkoutTotal()
	return (ShiftState:GetAttribute("DoorWalkouts") or 0)
		+ (ShiftState:GetAttribute("SeatedWalkouts") or 0)
end

local function onWalkoutChange()
	local total = walkoutTotal()
	if total > lastWalkouts and shiftOpen() then
		if os.clock() - lastGrumbleAt >= MANAGER.WalkoutGrumbleCooldown then
			lastGrumbleAt = os.clock()
			speak("Walkout", false)
		end
	end
	lastWalkouts = total
end

ShiftState:GetAttributeChangedSignal("DoorWalkouts"):Connect(onWalkoutChange)
ShiftState:GetAttributeChangedSignal("SeatedWalkouts"):Connect(onWalkoutChange)

--// A fresh shift resets the running mood
ShiftState:GetAttributeChangedSignal("State"):Connect(function()
	if ShiftState:GetAttribute("State") == "RUNNING" then
		repMood = "fine"
		lastWalkouts = walkoutTotal()
	end
end)

----------------------------------------------------------------
-- Emergencies: EventState transitions are the whole story
----------------------------------------------------------------
local EVENT_POOLS = {
	ToiletEmergency = { Start = "ToiletStart", Done = "ToiletDone" },
	GreaseFire = { Start = "FireStart", Done = "FireDone" },
	PowerOutage = { Start = "OutageStart", Done = "OutageDone" },
}

task.spawn(function()
	local EventState = ReplicatedStorage:WaitForChild("EventState", 30)
	if not EventState then
		warn("[Manager] no EventState folder - Bruno won't call emergencies")
		return
	end

	local lastEvent = EventState:GetAttribute("ActiveEvent") or ""
	EventState:GetAttributeChangedSignal("ActiveEvent"):Connect(function()
		local active = EventState:GetAttribute("ActiveEvent") or ""
		if active == lastEvent then return end

		if active ~= "" and EVENT_POOLS[active] then
			speak(EVENT_POOLS[active].Start, true)
		elseif active == "" and EVENT_POOLS[lastEvent] then
			speak(EVENT_POOLS[lastEvent].Done, false)
		end
		lastEvent = active
	end)

	--// The flood is its own scream, once per flood
	local flooded = false
	EventState:GetAttributeChangedSignal("Phase"):Connect(function()
		local phase = EventState:GetAttribute("Phase") or ""
		if phase == "FLOODED" and not flooded then
			flooded = true
			speak("ToiletFlood", true)
		elseif phase ~= "FLOODED" then
			flooded = false
		end
	end)
end)

print("[Manager] Bruno is on the floor")
