--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Modules
local ZoneModule = require(ReplicatedStorage.Modules.Zone)

--// Objects
local Teleport_zone = game.Workspace.Teleport_zone
local Configuration = Teleport_zone.Configuration
local QueueRemote = ReplicatedStorage.Remotes.QueueRemote
--// Variables

local ZoneData = {}
local PlayerZone = {} --// [Player] = TpZones the player is currently queued in

function JoinParty(Plr, ZoneContainer, TpZones)
    if PlayerZone[Plr] then return end --// already in a party

    table.insert(ZoneData[TpZones]["Players"], Plr)
    PlayerZone[Plr] = TpZones
    QueueRemote:FireClient(Plr, "JoinParty")

    local Char = Plr.Character
    if not Char then return end
    local RootPart = Char:FindFirstChild("HumanoidRootPart")
    if not RootPart then return end
    RootPart.Position = ZoneContainer.Position
end

function LeaveParty(Plr)
    local TpZones = PlayerZone[Plr]
    if not TpZones then return end

    local PartyPlayers = ZoneData[TpZones]["Players"]
    local Index = table.find(PartyPlayers, Plr)
    if Index then
        table.remove(PartyPlayers, Index)
    end
    PlayerZone[Plr] = nil

    QueueRemote:FireClient(Plr, "LeaveParty")

    local Char = Plr.Character
    if not Char then return end
    local RootPart = Char:FindFirstChild("HumanoidRootPart")
    if not RootPart then return end

    local LobbyPos = Teleport_zone:FindFirstChild("LobbyPos")
    if not LobbyPos then
        warn("[QueueServer] Teleport_zone.LobbyPos is missing - cannot return player to the lobby")
        return
    end

    local Target = LobbyPos:IsA("BasePart") and LobbyPos.CFrame or LobbyPos:GetPivot()
    Char:PivotTo(Target + Vector3.new(0, 5, 0))
end


for _, TpZones in pairs(Teleport_zone:GetChildren()) do
    if TpZones:IsA("Model") then

        ZoneData[TpZones] = {
            ["IsReady"] = false,
            ["MaxPlayers"] = 0,
            ["Players"] = {},
        }

        local ZoneContainer = TpZones.ZoneContainer
        local Zone = ZoneModule.new(ZoneContainer)

        Zone.playerEntered:Connect(function(Plr)
            JoinParty(Plr, ZoneContainer, TpZones)
        end)
    end
end

QueueRemote.OnServerEvent:Connect(function(Plr, Action)
    if Action == "LeaveParty" then
        LeaveParty(Plr)
    end
end)

Players.PlayerRemoving:Connect(function(Plr)
    LeaveParty(Plr)
end)
