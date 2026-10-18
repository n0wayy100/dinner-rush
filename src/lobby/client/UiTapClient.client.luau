--[[
	Dinner Rush - UiTapClient (LOBBY)
	StarterPlayer.StarterPlayerScripts.Client.UiTapClient  (LocalScript)

	THE TAP (owner, Oct 17 2026): every button the player presses in the
	lobby UI plays Config.Sfx.Sounds.UiTap. One hook on PlayerGui covers
	every screen - the dock, shop, crates, daily, free gift, stats, class
	shop, matchmaking - including buttons built later, so no screen has to
	remember to call it. Local only: nobody else hears your taps.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local SfxLocal = nil
pcall(function()
	SfxLocal = require(Shared:WaitForChild("SfxLocal", 5))
end)

local entry = Config.Sfx and Config.Sfx.Sounds and Config.Sfx.Sounds.UiTap
if not SfxLocal or not entry or entry.Id == "" then return end

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

--// one tap per press, even if a click lands on two stacked buttons
local MIN_GAP = 0.05
local lastTap = 0

local function tap()
	local now = os.clock()
	if now - lastTap < MIN_GAP then return end
	lastTap = now
	pcall(SfxLocal.Play, "UiTap")
end

local hooked = setmetatable({}, { __mode = "k" })

local function hook(instance)
	if instance:IsA("GuiButton") and not hooked[instance] then
		hooked[instance] = true
		instance.Activated:Connect(tap)
	end
end

for _, descendant in ipairs(playerGui:GetDescendants()) do
	hook(descendant)
end
playerGui.DescendantAdded:Connect(hook)
