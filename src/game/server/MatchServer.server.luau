--// Receives a party teleported in from the lobby and sets the match up.
--//
--// Party settings arrive as TeleportData attached by the lobby server. They
--// are read through Player:GetJoinData() rather than the client's
--// GetLocalPlayerTeleportData, because only the server-side copy is
--// trustworthy - an exploiter controls what their own client reports.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

print("[MatchServer] script started")

local DEFAULTS = {
	MaxPlayers = 3,
	Difficulty = "NORMAL",
	MapId = "Diner",
}

--// Settled by whoever arrives first, then reused for everyone else in the
--// party so late arrivals cannot change the map out from under the match.
local MatchSettings = nil
local Tuning = nil --// Config.Difficulty block for this shift
local MapLoaded = false

local function ReadTeleportData(Plr)
	local JoinData = Plr:GetJoinData()
	local Data = JoinData and JoinData.TeleportData

	if typeof(Data) ~= "table" then
		return nil
	end

	return Data
end

local function LoadMap(MapId)
	if MapLoaded then return end

	local Maps = ServerStorage:FindFirstChild("Maps")
	if not Maps then
		warn("[MatchServer] ServerStorage.Maps does not exist yet - no map to load")
		return
	end

	local Map = Maps:FindFirstChild(MapId)
	if not Map then
		warn(("[MatchServer] no map named '%s' in ServerStorage.Maps"):format(tostring(MapId)))
		return
	end

	Map:Clone().Parent = workspace
	MapLoaded = true
	print(("[MatchServer] loaded map '%s'"):format(MapId))
end

local function OnPlayerAdded(Plr)
	local Data = ReadTeleportData(Plr)

	if not Data then
		--// Joined this place directly rather than through the lobby, which is
		--// normal while testing in Studio
		warn(("[MatchServer] %s arrived with no teleport data - using defaults"):format(Plr.Name))
		Data = DEFAULTS
	end

	if not MatchSettings then
		--// Anything the lobby sent that is not a real difficulty falls back,
		--// so a bad handoff cannot crash the shift before it starts
		if not Config.IsValidDifficulty(Data.Difficulty) then
			warn(("[MatchServer] unknown difficulty %s - falling back to %s"):format(
				tostring(Data.Difficulty), DEFAULTS.Difficulty))
			Data.Difficulty = DEFAULTS.Difficulty
		end

		MatchSettings = Data
		Tuning = Config.ForDifficulty(Data.Difficulty)

		--// Published as attributes so other server systems (and later the HUD,
		--// since attributes replicate) read the shift settings from one place
		workspace:SetAttribute("MatchDifficulty", Data.Difficulty)
		workspace:SetAttribute("MatchPlayerCount", #Players:GetPlayers())
		workspace:SetAttribute("MatchMapId", Data.MapId or DEFAULTS.MapId)

		print(("[MatchServer] match settings: map %s, %s (%s), up to %s players"):format(
			tostring(Data.MapId), Tuning.Label, Data.Difficulty, tostring(Data.MaxPlayers)))
		print(("[MatchServer] shift is %ds, first spawn interval %.1fs"):format(
			Config.Shift.LengthSeconds,
			Config.SpawnIntervalFor("Calm", Data.Difficulty, Data.MaxPlayers)))

		LoadMap(Data.MapId or DEFAULTS.MapId)
	end

	--// TODO: seat the player, hand out their class, start the service loop
end

for _, Plr in ipairs(Players:GetPlayers()) do
	OnPlayerAdded(Plr)
end

Players.PlayerAdded:Connect(OnPlayerAdded)
