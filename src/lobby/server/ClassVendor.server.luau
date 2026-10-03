--[[
	Dinner Rush - ClassVendor (lobby)
	ServerScriptService.Server.ClassVendor  (regular Script, server-side)

	The class-shop NPC. A rig tagged ClassVendor (owner places + tags it)
	gets a floating "CLASSES" nametag, a Talk prompt, and a speech bubble
	that shows a rotating greeting when someone talks to it.

	All shop STATE goes through ProfileAPI (the module next to this script)
	- purchases and equips are validated server-side in there, never here
	and never on the client. This script is the doorman: it opens the
	screen, relays button taps to the API, and pushes fresh snapshots when
	the API says something changed.

	ClassShopRemote protocol:
	  server -> client  ("Open", snapshot, vendorRootPart)
	                    ("Profile", snapshot)          - something changed
	                    ("Result", ok, reason, action, classKey)
	  client -> server  ("Purchase", classKey)
	                    ("Equip", classKey)
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[ClassVendor] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))
--// ProfileAPI moved to ServerStorage.Shared (src/shared-server) so the
--// MAIN GAME can reach it too - Gap 4 from the class handoff
local ProfileAPI = require(game:GetService("ServerStorage"):WaitForChild("Shared"):WaitForChild("ProfileAPI"))

local SHOP = Config.ClassShop

print("[ClassVendor] script started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local shopRemote = remotes:FindFirstChild("ClassShopRemote")
if not shopRemote then
	shopRemote = Instance.new("RemoteEvent")
	shopRemote.Name = "ClassShopRemote"
	shopRemote.Parent = remotes
end

local function resolvePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

----------------------------------------------------------------
-- Vendor setup
----------------------------------------------------------------
local bubbleLabel, bubbleGui
local bubbleSerial = 0

local function buildVendorUi(root)
	--// Floating nametag, in the lobby's chunky sticker style.
	--// STUDS-sized, not pixel-sized: pixel billboards stay the same size on
	--// screen at any distance, which made CLASSES loom over the whole street.
	--// Studs shrink with perspective like a real sign, MaxDistance hides it
	--// entirely from afar, and walls are allowed to occlude it.
	local tag = Instance.new("BillboardGui")
	tag.Name = "VendorTag"
	tag.Size = UDim2.new(5, 0, 1.4, 0)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	tag.AlwaysOnTop = false
	tag.MaxDistance = SHOP.TagMaxDistanceStuds
	tag.Parent = root

	local tagLabel = Instance.new("TextLabel")
	tagLabel.Size = UDim2.fromScale(1, 1)
	tagLabel.BackgroundTransparency = 1
	tagLabel.Font = Enum.Font.FredokaOne
	tagLabel.TextScaled = true
	tagLabel.TextColor3 = Color3.fromRGB(245, 184, 65)
	tagLabel.TextStrokeColor3 = Color3.fromRGB(59, 43, 32)
	tagLabel.TextStrokeTransparency = 0
	tagLabel.Text = "CLASSES"
	tagLabel.Parent = tag

	--// Speech bubble: hidden until someone talks. Same studs treatment -
	--// only the player standing at the vendor needs to read it anyway.
	bubbleGui = Instance.new("BillboardGui")
	bubbleGui.Name = "VendorBubble"
	bubbleGui.Size = UDim2.new(7, 0, 1.9, 0)
	bubbleGui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	bubbleGui.AlwaysOnTop = false
	bubbleGui.MaxDistance = SHOP.TagMaxDistanceStuds
	bubbleGui.Enabled = false
	bubbleGui.Parent = root

	local bubble = Instance.new("Frame")
	bubble.Size = UDim2.fromScale(1, 1)
	bubble.BackgroundColor3 = Color3.fromRGB(255, 246, 233)
	bubble.Parent = bubbleGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = bubble

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(59, 43, 32)
	stroke.Parent = bubble

	bubbleLabel = Instance.new("TextLabel")
	bubbleLabel.Size = UDim2.fromScale(0.92, 0.8)
	bubbleLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	bubbleLabel.Position = UDim2.fromScale(0.5, 0.5)
	bubbleLabel.BackgroundTransparency = 1
	bubbleLabel.Font = Enum.Font.FredokaOne
	bubbleLabel.TextScaled = true
	bubbleLabel.TextWrapped = true
	bubbleLabel.TextColor3 = Color3.fromRGB(59, 43, 32)
	bubbleLabel.Text = ""
	bubbleLabel.Parent = bubble
end

local function showGreeting()
	if not bubbleGui then return end
	bubbleSerial += 1
	local mySerial = bubbleSerial

	bubbleLabel.Text = SHOP.VendorGreetings[math.random(#SHOP.VendorGreetings)]
	bubbleGui.Enabled = true
	task.delay(SHOP.BubbleSeconds, function()
		if bubbleSerial == mySerial and bubbleGui then
			bubbleGui.Enabled = false
		end
	end)
end

local function setupVendor(root)
	--// Silence the rig's own overhead name ("Shopkeeper") - the CLASSES
	--// tag is the only label this NPC needs
	local rigModel = root:FindFirstAncestorOfClass("Model") or root.Parent
	local rigHumanoid = rigModel and rigModel:FindFirstChildOfClass("Humanoid")
	if rigHumanoid then
		rigHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	buildVendorUi(root)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TalkToVendor"
	prompt.ActionText = "Talk"
	prompt.ObjectText = "Classes"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = root

	prompt.Triggered:Connect(function(player)
		showGreeting()
		shopRemote:FireClient(player, "Open", ProfileAPI.GetSnapshot(player), root)
	end)

	print(("[ClassVendor] vendor ready at %s"):format(root:GetFullName()))
end

----------------------------------------------------------------
-- Shop traffic: the client asks, ProfileAPI decides
----------------------------------------------------------------
shopRemote.OnServerEvent:Connect(function(player, action, classKey)
	if action == "Purchase" then
		local ok, reason = ProfileAPI.PurchaseClass(player, classKey)
		shopRemote:FireClient(player, "Result", ok, reason, "Purchase", classKey)
	elseif action == "Equip" then
		local ok, reason = ProfileAPI.EquipClass(player, classKey)
		shopRemote:FireClient(player, "Result", ok, reason, "Equip", classKey)
	elseif action == "Upgrade" then
		local ok, reason = ProfileAPI.UpgradeClass(player, classKey)
		shopRemote:FireClient(player, "Result", ok, reason, "Upgrade", classKey)
	end
end)

--// Any profile change -> that player's screen refreshes from the source
ProfileAPI.Changed:Connect(function(player)
	if player.Parent then
		shopRemote:FireClient(player, "Profile", ProfileAPI.GetSnapshot(player))
	end
end)

----------------------------------------------------------------
-- Boot: wait for the tagged rig
----------------------------------------------------------------
task.spawn(function()
	local waited = 0
	local root
	while waited < 20 do
		for _, instance in ipairs(CollectionService:GetTagged("ClassVendor")) do
			if instance:IsDescendantOf(workspace) then
				root = resolvePart(instance)
				if root then break end
			end
		end
		if root then break end
		task.wait(0.5)
		waited += 0.5
	end

	if not root then
		warn("[ClassVendor] no rig tagged ClassVendor - the class shop is disabled")
		return
	end

	setupVendor(root)
end)
