--[[
	Dinner Rush - MinigameIntro
	ServerStorage.Shared.MinigameIntro  (ModuleScript)

	THE MINIGAME INTRO BANNER (owner, Oct 2026). A minigame no longer opens
	the instant E is pressed: a bar under the shift timer pops up with the
	game's name first, then the game opens (MinigameIntroClient draws it).

	Lives on the SERVER on purpose. The server owns every minigame's clock -
	rhythm notes, quiz buzzers, deadlines - so delaying only the client's
	screen would quietly eat the player's time. Announce yields BEFORE the
	caller builds its session, so each game's clock starts when the player
	can actually see the game.

	Usage:
		if not MinigameIntro.Announce(player, "RhythmTap", station) then return end
		-- ...then build the session and send "Open" exactly as before

	Announce returns false - the caller must NOT start - when the player is
	already watching a banner, the lock key is already being announced (two
	people pressing the same station or spill), or the player left. The
	world moved on during the banner, so callers re-check their own state
	after it too (is the spill still there, did someone else start?).

	Names and the banner length live in Config.MinigameIntro.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end
local remote = remotes:FindFirstChild("MinigameIntroRemote")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "MinigameIntroRemote"
	remote.Parent = remotes
end

local MinigameIntro = {}

local busyPlayers = {} --// player -> true while their banner is up
local busyKeys = {}    --// lock key (a station, "Sweep", ...) -> true while announcing

function MinigameIntro.Announce(player, gameKey, lockKey)
	local settings = Config.MinigameIntro
	if not settings or settings.Enabled == false then
		return true
	end
	if busyPlayers[player] then
		return false
	end
	if lockKey ~= nil and busyKeys[lockKey] then
		return false
	end

	busyPlayers[player] = true
	if lockKey ~= nil then
		busyKeys[lockKey] = true
	end

	local name = (settings.Names and settings.Names[gameKey]) or tostring(gameKey)
	local seconds = settings.Seconds or 1.2
	remote:FireClient(player, "Show", name, seconds)
	task.wait(seconds)

	busyPlayers[player] = nil
	if lockKey ~= nil then
		busyKeys[lockKey] = nil
	end
	return player.Parent ~= nil
end

--// For a second press during the banner: the game is already on its way
function MinigameIntro.IsAnnouncing(lockKey)
	return lockKey ~= nil and busyKeys[lockKey] == true
end

return MinigameIntro
