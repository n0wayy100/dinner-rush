--[[
	Dinner Rush - MusicPlayer
	ReplicatedStorage.Shared.MusicPlayer     (ModuleScript, CLIENT use)

	Background music. A place's MusicClient decides WHICH playlist should be
	running; this decides how to get there.

	Only the LOBBY has music today. The module is not lobby-specific - when the
	restaurant gets its own soundtrack, add playlists to Config.Music and a
	client script that calls Play with their names. Nothing here changes.

	Client-side on purpose: the music belongs to the player, not the server.
	They can mute it, it costs the server nothing, and one person muting has no
	effect on anybody else. Nothing here touches gameplay.

	Usage:
		local Music = require(ReplicatedStorage.Shared.MusicPlayer)
		Music.Start()             -- once, from a client script
		Music.Play("Lobby")       -- a key in Config.Music.Playlists
		Music.Stop()

	Behaviour worth knowing:
	  * Calling Play with the playlist already running does nothing, so it is
	    safe to call every time state changes.
	  * A playlist with no ids - or a name that is not in Config at all - is
	    silence plus one warning. An empty Config is quiet, never broken.
	  * ONE track in a list loops itself seamlessly (Sound.Looped). SEVERAL
	    hand over to each other early, so the crossfade actually overlaps.
	  * A track that fails to load is skipped after LoadTimeoutSeconds rather
	    than ending the playlist forever.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local MusicPlayer = {}

local SETTINGS = Config.Music

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local started = false
local muted = false

local current = nil       --// the live Sound
local currentList = nil   --// playlist name currently running
local trackIndex = 0
local generation = 0      --// bumped on every Play/Stop, so a stale track's
                          --// Ended handler cannot advance the new playlist

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local warned = {}

local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn(message)
end

--// Accepts "rbxassetid://123" or a bare number/numeric string, because both
--// are things people paste out of the Creator Dashboard.
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
		--// "rbxassetid://0" is the placeholder in Config, not a real track
		return trimmed:match("//0$") == nil and trimmed or nil
	end

	warnOnce("id:" .. trimmed,
		("[Music] '%s' is not an asset id - expected rbxassetid://123"):format(trimmed))
	return nil
end

local function resolveList(name)
	local chosen = SETTINGS.Playlists[name]
	if not chosen then
		return {}
	end

	local ids = {}
	for _, entry in ipairs(chosen) do
		local id = normaliseId(entry)
		if id then
			table.insert(ids, id)
		end
	end
	return ids
end

local function fadeTo(sound, volume, seconds, onDone)
	if not sound or not sound.Parent then
		if onDone then onDone() end
		return
	end

	local tween = TweenService:Create(
		sound,
		TweenInfo.new(seconds, Enum.EasingStyle.Linear),
		{ Volume = volume })

	if onDone then
		tween.Completed:Once(onDone)
	end
	tween:Play()
	return tween
end

local function targetVolume()
	return muted and 0 or SETTINGS.Volume
end

----------------------------------------------------------------
-- PLAYBACK
----------------------------------------------------------------

local playTrack --// forward declared: advance() calls it

--// Moves to the next track in the running playlist, guarded by generation so
--// a track that ends after the playlist changed is ignored.
local function advance(myGeneration)
	if myGeneration ~= generation then
		return
	end

	local ids = resolveList(currentList)
	if #ids == 0 then
		return
	end

	trackIndex = (trackIndex % #ids) + 1
	playTrack(ids[trackIndex], myGeneration, #ids)
end

--// Waits for the track to load, bounded, then answers whether it did.
local function waitForLoad(sound, myGeneration)
	local deadline = os.clock() + SETTINGS.LoadTimeoutSeconds
	while not sound.IsLoaded and os.clock() < deadline do
		if myGeneration ~= generation or not sound.Parent then
			return false
		end
		task.wait(0.1)
	end
	return sound.IsLoaded
end

--// THE HAND-OFF. Ended fires when a track has ALREADY finished, so starting
--// the next one there means a gap and then a fade up from silence. To make a
--// crossfade real the next track has to begin BEFORE this one runs out, so
--// this watches the clock and hands over early.
--//
--// A single-track playlist never gets here: it uses Sound.Looped instead,
--// which is seamless in a way nothing scripted can match.
local function scheduleHandoff(sound, myGeneration, count)
	task.spawn(function()
		if not waitForLoad(sound, myGeneration) then
			if myGeneration ~= generation or sound ~= current then
				return
			end
			warnOnce("load:" .. sound.SoundId,
				("[Music] %s did not load."):format(sound.SoundId)
				.. " Check the id, and that this experience has permission to use it.")
			--// Retrying the only track in a list would just spin, so stop
			if count > 1 then
				advance(myGeneration)
			end
			return
		end

		if count <= 1 then
			return --// Looped handles the repeat
		end

		--// Never hand over before halfway, or a very short track would spend
		--// its whole length crossfading
		local lead = math.min(SETTINGS.CrossfadeSeconds, sound.TimeLength * 0.5)

		while myGeneration == generation and sound == current and sound.Parent do
			local remaining = sound.TimeLength - sound.TimePosition
			if remaining <= lead then
				advance(myGeneration)
				return
			end
			task.wait(math.clamp(remaining - lead, 0.05, 0.5))
		end
	end)
end

function playTrack(assetId, myGeneration, count)
	local previous = current

	local sound = Instance.new("Sound")
	sound.Name = "Music"
	sound.SoundId = assetId
	--// One track loops itself, seamlessly. Several hand over to each other.
	sound.Looped = (count <= 1)
	sound.Volume = 0
	sound.Parent = SoundService

	current = sound

	--// Old track fades out and dies while the new one fades in over it
	if previous then
		fadeTo(previous, 0, SETTINGS.CrossfadeSeconds, function()
			previous:Destroy()
		end)
	end

	sound:Play()
	fadeTo(sound, targetVolume(), SETTINGS.CrossfadeSeconds)

	--// Safety net: if the hand-off is ever missed, Ended still moves things
	--// on. It cannot double-advance, because advance() replaces `current`.
	sound.Ended:Connect(function()
		if sound == current then
			advance(myGeneration)
		end
	end)

	scheduleHandoff(sound, myGeneration, count)
end

----------------------------------------------------------------
-- PUBLIC
----------------------------------------------------------------

--// Safe to call repeatedly with the same name - only a real change restarts
--// anything, so callers can fire it on every state update.
function MusicPlayer.Play(playlistName)
	if not SETTINGS.Enabled then
		return
	end
	if playlistName == currentList then
		return
	end

	local ids = resolveList(playlistName)
	currentList = playlistName
	generation += 1

	if #ids == 0 then
		warnOnce("empty:" .. tostring(playlistName),
			("[Music] playlist '%s' is empty - add ids to Config.Music.Playlists")
				:format(tostring(playlistName)))
		MusicPlayer.Stop()
		currentList = playlistName --// remember it so a later Play still no-ops
		return
	end

	trackIndex = SETTINGS.Shuffle and math.random(#ids) or 1
	playTrack(ids[trackIndex], generation, #ids)
end

function MusicPlayer.Stop()
	generation += 1
	currentList = nil

	local sound = current
	current = nil
	if sound then
		fadeTo(sound, 0, SETTINGS.CrossfadeSeconds, function()
			sound:Destroy()
		end)
	end
end

function MusicPlayer.SetMuted(value)
	muted = value and true or false
	if current then
		fadeTo(current, targetVolume(), 0.25)
	end
	print(("[Music] %s"):format(muted and "muted" or "unmuted"))
end

function MusicPlayer.ToggleMuted()
	MusicPlayer.SetMuted(not muted)
end

function MusicPlayer.IsMuted()
	return muted
end

--// Binds the mute key. Call once per client.
function MusicPlayer.Start()
	if started then
		return
	end
	started = true

	if not SETTINGS.Enabled then
		print("[Music] disabled in Config.Music")
		return
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		--// gameProcessed is true while they are typing in chat
		if gameProcessed then return end
		if input.KeyCode == SETTINGS.ToggleKey then
			MusicPlayer.ToggleMuted()
		end
	end)
end

return MusicPlayer
