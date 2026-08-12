--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

print("[QueueServer] script started")

--// Modules
local ZoneModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Zone"))

--// Objects
local QueueRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("QueueRemote")

--// Teleport_zone is nested somewhere under Workspace rather than sitting at
--// the top of it, so search the whole tree instead of assuming a direct child.
local function FindInWorkspace(Name, Timeout)
    local Deadline = os.clock() + (Timeout or 20)
    repeat
        local Found = workspace:FindFirstChild(Name, true)
        if Found then
            return Found
        end
        task.wait(0.1)
    until os.clock() > Deadline

    return nil
end

local Teleport_zone = FindInWorkspace("Teleport_zone", 20)
if not Teleport_zone then
    warn("[QueueServer] Teleport_zone not found anywhere in Workspace - the lobby will not work")
    return
end

print("[QueueServer] using", Teleport_zone:GetFullName())

--// Shared tuning
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

--// Variables
local MIN_PLAYERS = Config.MinPlayers
local MAX_PLAYERS = Config.MaxPlayers

local STATE_WAITING = "Waiting for players..."
local STATE_FULL = "Party Full"
local STATE_STARTING = "Starting in %ds"

local COUNTDOWN_SECONDS = 30

--// A full party has nobody left to wait for, so the countdown snaps down
local FULL_PARTY_SECONDS = 5

--// How many players a party needs before the countdown starts. At 1 the host
--// can start alone, which is what makes solo testing possible. Set it to 2 to
--// require someone other than the host.
local MIN_PLAYERS_TO_START = 1

--// The MainGame place inside the DinnerRush experience.
--// Left at 0 the countdown still runs, it just does not teleport anyone.
local GAME_PLACE_ID = 138360216187462

local ZoneData = {}
local PlayerZone = {} --// [Player] = TpZones the player is currently queued in

--// Helpers ---------------------------------------------------------------

--// The client picks the settings but is never trusted with them
function SanitizeSettings(Settings)
    local Clean = {
        MaxPlayers = 3,
        Difficulty = "NORMAL",
        FriendsOnly = false,
    }

    if typeof(Settings) ~= "table" then
        return Clean
    end

    local Max = tonumber(Settings.MaxPlayers)
    if Max then
        Clean.MaxPlayers = math.clamp(math.floor(Max), MIN_PLAYERS, MAX_PLAYERS)
    end

    if typeof(Settings.Difficulty) == "string" then
        local Difficulty = string.upper(Settings.Difficulty)
        if Config.IsValidDifficulty(Difficulty) then
            Clean.Difficulty = Difficulty
        end
    end

    Clean.FriendsOnly = Settings.FriendsOnly == true

    return Clean
end

--// Stands the player on the floor of the target rather than a fixed distance
--// above its centre - a hardcoded offset floats them as soon as a zone is
--// rescaled. Height comes from the part's own size plus the character's, so
--// the feet land on the bottom of the volume whatever shape it is.
function TeleportTo(Plr, Object)
    local Char = Plr.Character
    if not Char then return end

    local Root = Char:FindFirstChild("HumanoidRootPart")
    if not Root then return end

    local Target = Object:IsA("BasePart") and Object.CFrame or Object:GetPivot()

    local HalfHeight = Object:IsA("BasePart") and (Object.Size.Y / 2) or 0
    local Humanoid = Char:FindFirstChildOfClass("Humanoid")
    local HipHeight = Humanoid and Humanoid.HipHeight or 2
    local Lift = (Root.Size.Y / 2) + HipHeight

    local Position = Target.Position + Vector3.new(0, Lift - HalfHeight, 0)

    --// Built from scratch so a tilted zone part cannot tilt the character,
    --// but keeping the part's facing so players spawn looking the same way
    local Look = Target.LookVector
    local Flat = Vector3.new(Look.X, 0, Look.Z)
    if Flat.Magnitude < 0.01 then
        Char:PivotTo(CFrame.new(Position))
        return
    end

    Char:PivotTo(CFrame.lookAt(Position, Position + Flat.Unit))
end

function SendToLobby(Plr)
    local LobbyPos = Teleport_zone:FindFirstChild("LobbyPos", true)
        or workspace:FindFirstChild("LobbyPos", true)
    if not LobbyPos then
        warn("[QueueServer] Teleport_zone.LobbyPos is missing - cannot return player to the lobby")
        return
    end

    TeleportTo(Plr, LobbyPos)
end

--// Billboard ------------------------------------------------------------
--// These labels live in Workspace, so writing them on the server
--// replicates the new text to every client automatically.

function UpdateBillboard(TpZones)
    local Data = ZoneData[TpZones]
    local StateLabel = Data.StateLabel
    local PlayerCount = Data.PlayerCount

    --// No party yet, so the size is not decided - show the waiting text alone
    if not Data.Created then
        if StateLabel then
            StateLabel.Text = STATE_WAITING
            StateLabel.Visible = true
        end
        if PlayerCount then
            PlayerCount.Visible = false
        end
        return
    end

    local Count = #Data.Players
    local Max = Data.Settings.MaxPlayers

    if PlayerCount then
        PlayerCount.Text = ("%d/%d"):format(Count, Max)
        PlayerCount.Visible = true
    end

    if StateLabel then
        if Data.Remaining then
            StateLabel.Text = STATE_STARTING:format(Data.Remaining)
        elseif Count >= Max then
            StateLabel.Text = STATE_FULL
        else
            StateLabel.Text = STATE_WAITING
        end
        StateLabel.Visible = true
    end
end

--// Countdown ------------------------------------------------------------
--// Starts once someone other than the host is in the party, and is cancelled
--// if they leave again. Token comparison retires a superseded loop, so a
--// cancel-then-restart cannot leave two loops running at once.

function CancelCountdown(TpZones)
    local Data = ZoneData[TpZones]
    if not Data.Remaining then return end

    Data.CountdownToken += 1
    Data.Remaining = nil

    for _, Member in ipairs(Data.Players) do
        QueueRemote:FireClient(Member, "CountdownCancelled")
    end

    UpdateBillboard(TpZones)
end

--// Clears a zone without moving anyone, for when the party has left under
--// its own steam. DisbandParty is the variant that also sends them home.
function ResetZone(TpZones)
    local Data = ZoneData[TpZones]

    CancelCountdown(TpZones)

    for _, Member in ipairs(Data.Players) do
        PlayerZone[Member] = nil
    end

    Data.Host = nil
    Data.Created = false
    Data.Teleporting = false
    Data.Players = {}
    Data.Settings = SanitizeSettings(nil)

    UpdateBillboard(TpZones)
end

--// Retimes a countdown that is already running. Does nothing if there is no
--// countdown yet - StartCountdown owns that case.
function SetCountdown(TpZones, Seconds)
    local Data = ZoneData[TpZones]
    if not Data.Remaining then return end

    Data.Remaining = Seconds

    for _, Member in ipairs(Data.Players) do
        QueueRemote:FireClient(Member, "Countdown", Data.Remaining)
    end

    UpdateBillboard(TpZones)
end

--// Nobody left to wait for once every slot is taken
function TightenCountdownIfFull(TpZones)
    local Data = ZoneData[TpZones]
    if not Data.Remaining then return end
    if #Data.Players < Data.Settings.MaxPlayers then return end
    if Data.Remaining <= FULL_PARTY_SECONDS then return end

    SetCountdown(TpZones, FULL_PARTY_SECONDS)
end

function StartMatch(TpZones)
    local Data = ZoneData[TpZones]

    print(("[QueueServer] match starting: %d player(s), difficulty %s"):format(
        #Data.Players, Data.Settings.Difficulty))

    for _, Member in ipairs(Data.Players) do
        QueueRemote:FireClient(Member, "MatchStarting", Data.Settings)
    end

    if GAME_PLACE_ID == 0 then
        warn("[QueueServer] GAME_PLACE_ID is not set yet - nobody is being teleported")
        return
    end

    --// Stops a passer-by claiming the zone during the teleport, which takes a
    --// moment and leaves the party standing in it
    Data.Teleporting = true

    --// A reserved server keeps the party together instead of dropping them
    --// into a public server with strangers
    local Ok, Code = pcall(function()
        return TeleportService:ReserveServer(GAME_PLACE_ID)
    end)

    if not Ok then
        warn("[QueueServer] ReserveServer failed:", Code)
        return
    end

    local Options = Instance.new("TeleportOptions")
    Options.ReservedServerAccessCode = Code
    Options:SetTeleportData({
        MaxPlayers = Data.Settings.MaxPlayers,
        Difficulty = Data.Settings.Difficulty,
        FriendsOnly = Data.Settings.FriendsOnly,
        MapId = Data.Settings.MapId or "Diner",
    })

    local Sent, Err = pcall(function()
        TeleportService:TeleportAsync(GAME_PLACE_ID, Data.Players, Options)
    end)

    if not Sent then
        --// Leave the party intact so they can retry rather than stranding them
        warn("[QueueServer] TeleportAsync failed:", Err)
        Data.Teleporting = false
        for _, Member in ipairs(Data.Players) do
            QueueRemote:FireClient(Member, "MatchFailed")
        end
        return
    end

    --// They are on their way out, so free the zone for the next party
    ResetZone(TpZones)
end

function StartCountdown(TpZones)
    local Data = ZoneData[TpZones]
    if Data.Remaining then return end --// already counting

    Data.CountdownToken += 1
    local Token = Data.CountdownToken
    Data.Remaining = COUNTDOWN_SECONDS

    task.spawn(function()
        while Data.Remaining and Data.Remaining > 0 do
            for _, Member in ipairs(Data.Players) do
                QueueRemote:FireClient(Member, "Countdown", Data.Remaining)
            end
            UpdateBillboard(TpZones)

            task.wait(1)

            --// Cancelled or restarted while we were waiting
            if Data.CountdownToken ~= Token then return end

            Data.Remaining -= 1
        end

        Data.Remaining = nil
        UpdateBillboard(TpZones)
        StartMatch(TpZones)
    end)
end

--// Party flow ------------------------------------------------------------

function JoinParty(Plr, ZoneContainer, TpZones)
    if PlayerZone[Plr] then return end --// already in a party

    local Data = ZoneData[TpZones]

    print(("[QueueServer] %s entered a zone (host: %s, created: %s)"):format(
        Plr.Name, tostring(Data.Host), tostring(Data.Created)))

    --// Party is mid-teleport, so this zone is not accepting anyone
    if Data.Teleporting then
        QueueRemote:FireClient(Plr, "PartyNotReady")
        SendToLobby(Plr)
        return
    end

    --// First player into an empty zone becomes the host and configures the party
    if not Data.Host then
        Data.Host = Plr
        PlayerZone[Plr] = TpZones
        table.insert(Data.Players, Plr)

        TeleportTo(Plr, ZoneContainer)
        print("[QueueServer] sending HostParty to", Plr.Name)
        QueueRemote:FireClient(Plr, "HostParty", Data.Settings)
        UpdateBillboard(TpZones)
        return
    end

    --// Host is still picking settings, nobody else gets in yet
    if not Data.Created then
        QueueRemote:FireClient(Plr, "PartyNotReady")
        SendToLobby(Plr)
        return
    end

    if #Data.Players >= Data.Settings.MaxPlayers then
        QueueRemote:FireClient(Plr, "PartyFull")
        SendToLobby(Plr)
        return
    end

    PlayerZone[Plr] = TpZones
    table.insert(Data.Players, Plr)

    TeleportTo(Plr, ZoneContainer)
    QueueRemote:FireClient(Plr, "JoinParty", Data.Settings)
    UpdateBillboard(TpZones)

    if #Data.Players >= MIN_PLAYERS_TO_START then
        StartCountdown(TpZones)
    end

    TightenCountdownIfFull(TpZones)
end

--// Host confirmed the settings panel, the zone now accepts other players
function CreateParty(Plr, Settings)
    local TpZones = PlayerZone[Plr]
    if not TpZones then return end

    local Data = ZoneData[TpZones]
    if Data.Host ~= Plr then return end --// only the host configures
    if Data.Created then return end

    Data.Settings = SanitizeSettings(Settings)
    Data.Created = true

    QueueRemote:FireClient(Plr, "PartyCreated", Data.Settings)
    UpdateBillboard(TpZones) --// size is decided, so the count can show now

    --// At MIN_PLAYERS_TO_START = 1 the host alone is enough, so the countdown
    --// begins the moment the party exists
    if #Data.Players >= MIN_PLAYERS_TO_START then
        StartCountdown(TpZones)
    end

    --// A party capped at 1 is full the moment it exists
    TightenCountdownIfFull(TpZones)
end

function DisbandParty(TpZones)
    local Data = ZoneData[TpZones]

    CancelCountdown(TpZones)

    for _, Member in ipairs(Data.Players) do
        if Member.Parent then --// still in the game
            QueueRemote:FireClient(Member, "LeaveParty")
            SendToLobby(Member)
        end
    end

    ResetZone(TpZones)
end

function LeaveParty(Plr)
    local TpZones = PlayerZone[Plr]
    if not TpZones then return end

    local Data = ZoneData[TpZones]

    --// Host leaving tears the whole party down and frees the zone
    if Data.Host == Plr then
        DisbandParty(TpZones)
        return
    end

    local Index = table.find(Data.Players, Plr)
    if Index then
        table.remove(Data.Players, Index)
    end
    PlayerZone[Plr] = nil

    QueueRemote:FireClient(Plr, "LeaveParty")
    SendToLobby(Plr)

    --// Dropped below the threshold, so there is nothing to count down to
    if #Data.Players < MIN_PLAYERS_TO_START then
        CancelCountdown(TpZones)
    else
        --// A slot reopened, so give the party the full window to refill it
        SetCountdown(TpZones, COUNTDOWN_SECONDS)
    end

    UpdateBillboard(TpZones)
end

--// Setup -----------------------------------------------------------------

local Connected = 0

for _, TpZones in pairs(Teleport_zone:GetChildren()) do
    if TpZones:IsA("Model") then

        --// A zone with no ZoneContainer is skipped rather than allowed to
        --// throw, otherwise one unfinished model breaks every zone after it.
        local ZoneContainer = TpZones:FindFirstChild("ZoneContainer", true)
        if not ZoneContainer then
            warn(("[QueueServer] %s has no ZoneContainer - skipping this zone"):format(TpZones.Name))
            continue
        end

        local Billboard = TpZones:FindFirstChildWhichIsA("BillboardGui", true)
        if not Billboard then
            warn(("[QueueServer] %s has no BillboardGui - its sign will not update"):format(TpZones.Name))
        end

        ZoneData[TpZones] = {
            ["Host"] = nil,
            ["Created"] = false,
            ["Settings"] = SanitizeSettings(nil),
            ["Players"] = {},
            ["Remaining"] = nil, --// seconds left, nil when not counting down
            ["CountdownToken"] = 0,
            ["Teleporting"] = false,
            ["StateLabel"] = Billboard and Billboard:FindFirstChild("StateLabel", true),
            ["PlayerCount"] = Billboard and Billboard:FindFirstChild("PlayerCount", true),
        }

        --// Selection boxes and highlights left over from building show up
        --// in-game as coloured outlines around the zone
        for _, Adornment in ipairs(TpZones:GetDescendants()) do
            if Adornment:IsA("SelectionBox")
                or Adornment:IsA("Highlight")
                or Adornment:IsA("SelectionSphere")
                or Adornment:IsA("BoxHandleAdornment") then
                print(("[QueueServer] removing %s from %s"):format(Adornment.ClassName, TpZones.Name))
                Adornment:Destroy()
            end
        end

        if Billboard then
            if not ZoneData[TpZones].StateLabel then
                warn(("[QueueServer] %s billboard has no StateLabel"):format(TpZones.Name))
            end
            if not ZoneData[TpZones].PlayerCount then
                warn(("[QueueServer] %s billboard has no PlayerCount"):format(TpZones.Name))
            end
        end

        UpdateBillboard(TpZones) --// start every zone in the waiting state

        local Zone = ZoneModule.new(ZoneContainer)
        Zone.playerEntered:Connect(function(Plr)
            JoinParty(Plr, ZoneContainer, TpZones)
        end)

        Connected += 1
        print(("[QueueServer] zone ready: %s"):format(TpZones.Name))
    end
end

print(("[QueueServer] %d zone(s) connected"):format(Connected))

if Connected == 0 then
    warn("[QueueServer] No zones connected - nothing under Teleport_zone is a Model with a ZoneContainer")
end

QueueRemote.OnServerEvent:Connect(function(Plr, Action, Payload)
    if Action == "LeaveParty" then
        LeaveParty(Plr)
    elseif Action == "CreateParty" then
        CreateParty(Plr, Payload)
    end
end)

Players.PlayerRemoving:Connect(function(Plr)
    LeaveParty(Plr)
end)
