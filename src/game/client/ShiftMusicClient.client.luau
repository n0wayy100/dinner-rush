--[[
	Dinner Rush - ShiftMusicClient
	StarterPlayerScripts.Client.ShiftMusicClient

	The restaurant soundtrack. Each map can have three tracks, one per shift
	phase, set in Config.Music.MapSoundtracks:

	  Tutorial   one track, looping for the whole lesson (Config.Music.TutorialTrack)
	  Calm       plays PlaySeconds (1:40), then slowly fades out
	  Building   plays PlaySeconds (2:40), then slowly fades out
	  Crescendo  loops until the last table leaves, then fades out

	Every track loops with Sound.Looped, which repeats at the engine level with
	no gap - so a track shorter than its play time just goes round again.

	Reads ReplicatedStorage.ShiftState and workspace.MatchMapId, both published
	by the server already. No remotes, no server code. Client-side on purpose:
	the music belongs to the player, M mutes it for them alone, and it costs
	the server nothing.

	A player who joins or rejoins mid-shift hears the right thing for that
	moment: the play window is measured from the start of the PHASE, not from
	when this script happened to start.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local MUSIC = Config.Music
local SOUNDTRACKS = MUSIC.MapSoundtracks or {}

--// Where each phase begins on the shift clock. Read from the same Config
--// the server uses to turn phases, so the two can never disagree.
local STAGE_START = {
	Calm = 0,
	Building = Config.Shift.Phases.CalmEndsAt,
	Crescendo = Config.Shift.Phases.BuildingEndsAt,
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local current = nil        --// the Sound playing right now, if any
local currentStage = false --// the phase last decided on; false = nothing yet
local generation = 0       --// bumped on every decision, so a stale fade-out
                           --// timer cannot touch a newer track
local muted = false

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local warned = {}

local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn(message)
end

--// Accepts "rbxassetid://123" or a bare number. Empty means "not set yet".
local function normaliseId(value)
	if type(value) == "number" then
		return ("rbxassetid://%d"):format(value)
	end
	if type(value) ~= "string" then
		return nil
	end

	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end
	if trimmed:match("^%d+$") then
		return ("rbxassetid://%s"):format(trimmed)
	end
	if trimmed:match("^rbxassetid://%d+$") then
		return trimmed:match("//0$") == nil and trimmed or nil
	end

	warnOnce("id:" .. trimmed,
		("[ShiftMusic] '%s' is not an asset id - expected rbxassetid://123"):format(trimmed))
	return nil
end

local function targetVolume()
	return muted and 0 or (MUSIC.ShiftVolume or MUSIC.Volume)
end

local function fadeTo(sound, volume, seconds, onDone)
	if not sound or not sound.Parent then
		if onDone then onDone() end
		return
	end

	local tween = TweenService:Create(
		sound,
		TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Volume = volume })

	if onDone then
		tween.Completed:Once(onDone)
	end
	tween:Play()
end

--// Fades whatever is playing out and forgets it
local function fadeOutCurrent()
	local sound = current
	current = nil
	if sound then
		fadeTo(sound, 0, MUSIC.ShiftFadeOutSeconds, function()
			sound:Destroy()
		end)
	end
end

----------------------------------------------------------------
-- DECIDING WHAT SHOULD PLAY
----------------------------------------------------------------

local shiftState = ReplicatedStorage:WaitForChild("ShiftState", 30)
if not shiftState then
	warn("[ShiftMusic] ReplicatedStorage.ShiftState never appeared - no shift music this session")
	return
end

--// Which phase's track belongs to this moment of the shift.
local function stageNow()
	local state = shiftState:GetAttribute("State")

	--// A TUTORIAL server has no phases to score: the shift clock is frozen
	--// and the night never turns. One track loops through the whole lesson,
	--// from before the doors open until the shift is over.
	if workspace:GetAttribute("MatchMode") == "TUTORIAL" then
		return state ~= "ENDED" and "Tutorial" or nil
	end

	if state == "RUNNING" then
		return shiftState:GetAttribute("Phase") --// Calm / Building / Crescendo
	elseif state == "CLOSING" then
		--// The server publishes Phase = "Closing" here. The busy track has to
		--// carry straight on until the last table leaves - mapping closing to
		--// Crescendo means the same track continues instead of restarting.
		return "Crescendo"
	end

	--// Waiting, prep, or the shift is over: silence
	return nil
end

--// Seconds already spent inside this phase. Lets a mid-shift joiner land in
--// the right place in the play window rather than getting a fresh 1:40.
local function secondsIntoStage(stage)
	local length = shiftState:GetAttribute("Length")
	local remaining = shiftState:GetAttribute("TimeRemaining")
	local start = STAGE_START[stage]
	if not (length and remaining and start) then
		return 0
	end
	return math.max(0, (length - remaining) - start)
end

--// Starts the looping body of a phase. Volume is passed in so an intro can
--// hand straight over at the level it was already playing, with no dip.
local function startLoop(stage, assetId, volume, myGeneration)
	if myGeneration ~= generation then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = "ShiftMusic_" .. stage
	sound.SoundId = assetId
	sound.Looped = true   --// seamless repeat, whatever the track's length
	sound.Volume = volume
	sound.Parent = SoundService

	local previous = current
	current = sound
	sound:Play()

	--// The intro is still sounding for a few milliseconds underneath. Let it
	--// finish rather than cutting it, then clear it away.
	if previous and previous ~= sound then
		task.delay(1, function()
			if previous.Parent then
				previous:Stop()
				previous:Destroy()
			end
		end)
	end

	task.delay(MUSIC.LoadTimeoutSeconds or 8, function()
		if sound.Parent and not sound.IsLoaded then
			warnOnce("load:" .. assetId, ("[ShiftMusic] %s (%s loop) did not load."):format(assetId, stage)
				.. " Check the id, and that this experience has permission to use it.")
		end
	end)
end

--// Plays the one-shot intro, then hands over to the loop the moment it ends.
--// NOT a crossfade: a tempo ramp has to land exactly where it was written, so
--// the loop simply starts as the intro runs out.
local function playIntroThenLoop(stage, introId, loopId, myGeneration)
	local intro = Instance.new("Sound")
	intro.Name = "ShiftMusic_" .. stage .. "_Intro"
	intro.SoundId = introId
	intro.Looped = false   --// the wind-up plays exactly once
	intro.Volume = 0
	intro.Parent = SoundService

	local previous = current
	current = intro
	if previous then
		fadeTo(previous, 0, MUSIC.ShiftFadeOutSeconds, function()
			previous:Destroy()
		end)
	end

	intro:Play()
	fadeTo(intro, targetVolume(), MUSIC.ShiftFadeInSeconds)

	--// Whichever comes first - the scheduled handover or Ended - only one of
	--// them may start the loop.
	local handedOver = false
	local function handOver()
		if handedOver or myGeneration ~= generation or current ~= intro then
			return
		end
		handedOver = true
		startLoop(stage, loopId, targetVolume(), myGeneration)
	end

	--// Ended fires AFTER the intro has finished, which would leave a hole.
	--// It is only the safety net; the timed handover below is the real path.
	intro.Ended:Once(handOver)

	task.spawn(function()
		local deadline = os.clock() + (MUSIC.LoadTimeoutSeconds or 8)
		while not intro.IsLoaded and os.clock() < deadline do
			if myGeneration ~= generation then return end
			task.wait(0.05)
		end

		if not intro.IsLoaded then
			warnOnce("load:" .. introId, ("[ShiftMusic] %s (%s intro) did not load."):format(introId, stage)
				.. " Skipping to the loop.")
			handOver()
			return
		end

		--// Start the loop a hair before the intro runs out, so the two butt
		--// together instead of leaving a gap at the tempo change.
		local lead = MUSIC.ShiftIntroHandoffSeconds or 0.05
		while myGeneration == generation and current == intro and intro.Parent do
			local remaining = intro.TimeLength - intro.TimePosition
			if remaining <= lead then
				break
			end
			task.wait(math.clamp(remaining - lead, 0.01, 0.25))
		end
		handOver()
	end)
end

local function playStage(stage, track, assetId, myGeneration)
	local into = secondsIntoStage(stage)

	--// Joined after this phase's music already finished
	if track.PlaySeconds and into >= track.PlaySeconds then
		fadeOutCurrent()
		return
	end

	--// A wind-up intro only makes sense to someone who was here when the
	--// phase turned. Anyone later joins the loop already at tempo.
	local introId = normaliseId(track.IntroId)
	if introId and into <= (MUSIC.ShiftIntroSkipAfterSeconds or 3) then
		playIntroThenLoop(stage, introId, assetId, myGeneration)
	else
		local previous = current
		local sound = Instance.new("Sound")
		sound.Name = "ShiftMusic_" .. stage
		sound.SoundId = assetId
		sound.Looped = true
		sound.Volume = 0
		sound.Parent = SoundService
		current = sound

		if previous then
			fadeTo(previous, 0, MUSIC.ShiftFadeOutSeconds, function()
				previous:Destroy()
			end)
		end

		sound:Play()
		fadeTo(sound, targetVolume(), MUSIC.ShiftFadeInSeconds)

		task.delay(MUSIC.LoadTimeoutSeconds or 8, function()
			if sound.Parent and not sound.IsLoaded then
				warnOnce("load:" .. assetId, ("[ShiftMusic] %s (%s) did not load."):format(assetId, stage)
					.. " Check the id, and that this experience has permission to use it.")
			end
		end)
	end

	--// Play window: once it runs out, whatever is playing for this phase
	--// slowly fades away. Checked by generation rather than by sound, so it
	--// still works after an intro has handed over to its loop.
	if track.PlaySeconds then
		task.delay(track.PlaySeconds - into, function()
			if myGeneration ~= generation then
				return --// a newer phase has taken over already
			end
			fadeOutCurrent()
		end)
	end
end

local function refresh()
	local stage = stageNow()

	--// Same phase as before: leave it alone. This is what stops the closing
	--// handover, or a mid-phase attribute update, from restarting the track.
	if stage == currentStage then
		return
	end
	currentStage = stage
	generation += 1

	if not stage then
		fadeOutCurrent()
		return
	end

	local mapId = workspace:GetAttribute("MatchMapId") or Config.DefaultMapId
	local set = SOUNDTRACKS[mapId]

	--// The tutorial has one track of its own rather than a per-map set
	local track = (stage == "Tutorial") and MUSIC.TutorialTrack or (set and set[stage])
	local assetId = track and normaliseId(track.Id)

	if not assetId then
		--// No music for this phase on this map. Quiet, not broken.
		if stage == "Tutorial" then
			warnOnce("empty:tutorial",
				"[ShiftMusic] Config.Music.TutorialTrack has no id yet - tutorial is silent")
		elseif set and track then
			warnOnce("empty:" .. mapId .. stage,
				("[ShiftMusic] %s has no %s track id yet - silent for this phase"):format(mapId, stage))
		end
		fadeOutCurrent()
		return
	end

	playStage(stage, track, assetId, generation)
end

----------------------------------------------------------------
-- MUTE
----------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end --// typing in chat
	if input.KeyCode ~= MUSIC.ToggleKey then return end

	muted = not muted
	if current then
		fadeTo(current, targetVolume(), 0.25)
	end
	print(("[ShiftMusic] %s"):format(muted and "muted" or "unmuted"))
end)

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------

shiftState:GetAttributeChangedSignal("State"):Connect(refresh)
shiftState:GetAttributeChangedSignal("Phase"):Connect(refresh)

--// The map is settled when the first player arrives, which can be after
--// this script starts. Re-decide from scratch once it is known.
workspace:GetAttributeChangedSignal("MatchMapId"):Connect(function()
	currentStage = false
	refresh()
end)

--// MatchMode lands at the same moment, and decides tutorial vs a real shift
workspace:GetAttributeChangedSignal("MatchMode"):Connect(function()
	currentStage = false
	refresh()
end)

refresh()
