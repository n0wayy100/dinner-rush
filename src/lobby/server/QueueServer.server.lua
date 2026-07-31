--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local ZoneModule = require(ReplicatedStorage.Modules.Zone)

--// Objects
local Teleport_zone = game.Workspace.Teleport_zone
local Configuration = Teleport_zone.Configuration
local QueueRemote = ReplicatedStorage.Remotes.QueueRemote
--// Variables

local ZoneData = {}

function JoinParty(Plr,ZoneContainer, TpZones)
    table.insert(ZoneData[TpZones]["Players"], Plr)
    QueueRemote:FireClient(Plr, "JoinParty")
    local Char = Plr.Character
    if not Char then return end
    local RootPart = Char:FindFirstChild("HumanoidRootPart")
    RootPart.Position = ZoneContainer.Position
end

function LeaveParty(Plr, TpZones)
    table.remove(ZoneData[TpZones]["Players"], table.find(ZoneData[TpZones]["Players"], Plr))
    
    local Char = Plr.Character
    if not Char then return end
    local RootPart = Char:FindFirstChild("HumanoidRootPart")
    RootPart.Position = Teleport_zone.LobbyPos.Position
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