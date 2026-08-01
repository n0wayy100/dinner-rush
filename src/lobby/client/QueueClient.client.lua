--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Player Stuff
local Plr = game.Players.LocalPlayer
local PlayerGui = Plr:WaitForChild("PlayerGui")

--// Objects
local QueueRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("QueueRemote")

--// UI ------------------------------------------------------------------
--// Everything below tolerates the UI being missing or misnamed in Studio,
--// so the Leave button always exists and is always clickable.

local MatchMaking_UI = PlayerGui:WaitForChild("MatchMaking_UI", 5)
if not MatchMaking_UI then
    warn("[QueueClient] No MatchMaking_UI in StarterGui - building a fallback one")
    MatchMaking_UI = Instance.new("ScreenGui")
    MatchMaking_UI.Name = "MatchMaking_UI"
    MatchMaking_UI.Parent = PlayerGui
end

--// Keeps our connections valid after the player respawns
MatchMaking_UI.ResetOnSpawn = false
MatchMaking_UI.IgnoreGuiInset = true

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

--// A hidden parent hides the button even when the button itself is visible,
--// so walk up the chain from the button to the ScreenGui.
local function SetPartyVisible(State)
    MatchMaking_UI.Enabled = State

    local Object = LeaveButton
    while Object and Object ~= MatchMaking_UI do
        if Object:IsA("GuiObject") then
            Object.Visible = State
        end
        Object = Object.Parent
    end
end

--// Behaviour ------------------------------------------------------------

LeaveButton.Active = true
LeaveButton.Selectable = true
SetPartyVisible(false)

QueueRemote.OnClientEvent:Connect(function(Action)
    if Action == "JoinParty" then
        SetPartyVisible(true)
    elseif Action == "LeaveParty" then
        SetPartyVisible(false)
    end
end)

LeaveButton.MouseButton1Click:Connect(function()
    SetPartyVisible(false) --// instant feedback, server confirms with a LeaveParty event
    QueueRemote:FireServer("LeaveParty")
end)
