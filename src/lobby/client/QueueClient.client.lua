--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[QueueClient] script started")

--// Player Stuff
local Plr = game.Players.LocalPlayer
local PlayerGui = Plr:WaitForChild("PlayerGui")

--// Objects
local QueueRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("QueueRemote")

--// UI ------------------------------------------------------------------
--// Everything below tolerates the UI being missing or misnamed in Studio,
--// so the Leave button always exists and is always clickable.

--// Nested under the Inparty folder from StarterGui, so search descendants
local MatchMaking_UI
local Elapsed = 0
repeat
    MatchMaking_UI = PlayerGui:FindFirstChild("MatchMaking_UI", true)
    if not MatchMaking_UI then
        task.wait(0.1)
        Elapsed += 0.1
    end
until MatchMaking_UI or Elapsed >= 10

if not MatchMaking_UI then
    warn("[QueueClient] No MatchMaking_UI anywhere in PlayerGui - building a fallback one")
    MatchMaking_UI = Instance.new("ScreenGui")
    MatchMaking_UI.Name = "MatchMaking_UI"
    MatchMaking_UI.Parent = PlayerGui
end

print("[QueueClient] using", MatchMaking_UI:GetFullName())

--// Keeps our connections valid after the player respawns
MatchMaking_UI.ResetOnSpawn = false

local InParty = MatchMaking_UI:FindFirstChild("InParty", true)
if not InParty then
    warn("[QueueClient] No InParty frame found - building a fallback one")
    InParty = Instance.new("Frame")
    InParty.Name = "InParty"
    InParty.AnchorPoint = Vector2.new(0.5, 1)
    InParty.Position = UDim2.fromScale(0.5, 0.95)
    InParty.Size = UDim2.fromOffset(220, 60)
    InParty.BackgroundTransparency = 1
    InParty.Parent = MatchMaking_UI
end

--// Exact name first, then any button with "leave" in it (catches typos like "LeaveButoon")
local function FindLeaveButton()
    local Button = InParty:FindFirstChild("LeaveButton", true)
    if Button and Button:IsA("GuiButton") then
        return Button
    end

    for _, Child in ipairs(InParty:GetDescendants()) do
        if Child:IsA("GuiButton") and string.find(string.lower(Child.Name), "leave", 1, true) then
            warn(("[QueueClient] Using '%s' as the leave button - rename it to LeaveButton"):format(Child.Name))
            return Child
        end
    end

    return nil
end

local LeaveButton = FindLeaveButton()
if not LeaveButton then
    warn("[QueueClient] No leave button found - building a fallback one")
    LeaveButton = Instance.new("TextButton")
    LeaveButton.Name = "LeaveButton"
    LeaveButton.AnchorPoint = Vector2.new(0.5, 0.5)
    LeaveButton.Position = UDim2.fromScale(0.5, 0.5)
    LeaveButton.Size = UDim2.fromOffset(180, 48)
    LeaveButton.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    LeaveButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    LeaveButton.Font = Enum.Font.GothamBold
    LeaveButton.TextSize = 20
    LeaveButton.Text = "Leave"
    LeaveButton.AutoButtonColor = true
    LeaveButton.Parent = InParty

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 8)
    Corner.Parent = LeaveButton
end

--// MainPanel shares this ScreenGui, so only toggle our own branch of it -
--// PartySettings owns MainPanel and would fight us over ScreenGui.Enabled.
local function SetPartyVisible(State)
    local Object = LeaveButton
    while Object and Object ~= MatchMaking_UI do
        if Object:IsA("GuiObject") then
            Object.Visible = State
        end
        Object = Object.Parent
    end
end

MatchMaking_UI.Enabled = true

--// Behaviour ------------------------------------------------------------

LeaveButton.Active = true
LeaveButton.Selectable = true
SetPartyVisible(false)

QueueRemote.OnClientEvent:Connect(function(Action)
    if Action == "JoinParty" then
        --// Joiners never see the settings panel, so their Leave button is
        --// ready the moment they are in.
        SetPartyVisible(true)

    elseif Action == "HostParty" then
        --// The host is looking at the party settings panel right now. Two
        --// buttons over the same corner of the screen read as one broken
        --// button, so Leave stays hidden and the panel's X is their way out
        --// until the party exists (see PartySettings).
        SetPartyVisible(false)

    elseif Action == "PartyCreated" then
        --// Panel is gone, so the host gets the same Leave button as everyone
        SetPartyVisible(true)

    elseif Action == "LeaveParty" then
        SetPartyVisible(false)
    elseif Action == "PartyNotReady" then
        warn("[QueueClient] That party is still being set up by its host")
    elseif Action == "PartyFull" then
        warn("[QueueClient] That party is full")
    end
end)

LeaveButton.MouseButton1Click:Connect(function()
    SetPartyVisible(false) --// instant feedback, server confirms with a LeaveParty event
    QueueRemote:FireServer("LeaveParty")
end)
