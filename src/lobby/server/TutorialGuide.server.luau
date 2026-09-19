--[[
	Dinner Rush - TutorialGuide (lobby)
	ServerScriptService.Server.TutorialGuide  (regular Script, server-side)

	The HOW TO PLAY NPC, cut from the ClassVendor's cloth: a rig tagged
	TutorialGuide (owner places + tags it) gets a floating HOW TO PLAY
	nametag, a Talk prompt and a speech bubble. E opens the client's
	YES / NO card (TutorialPortalClient); a YES - server-validated to be
	standing near the guide - reserves a PRIVATE solo server on the main
	game place and teleports the player with Mode = "TUTORIAL" in the
	teleport data - MatchServer on the other side reads that and starts
	Bruno's guided first shift.

	TutorialPortalRemote protocol:
	  server -> client  ("Ask")            - open the YES / NO card
	  client -> server  ("Yes") / ("No")   - the player's answer

	All numbers and lines live in Config.TutorialPortal. TeleportAsync
	cannot run in Studio, so there the bubble just says so.
--]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
assert(sharedFolder, "[TutorialGuide] ReplicatedStorage.Shared not found")
local Config = require(sharedFolder:WaitForChild("Config", 10))

local PORTAL = Config.TutorialPortal
local TAG = "TutorialGuide"

--// The MainGame place - the same id QueueServer sends shifts to
local GAME_PLACE_ID = 97952115394249

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)

print("[TutorialGuide] script started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local portalRemote = remotes:FindFirstChild("TutorialPortalRemote")
if not portalRemote then
	portalRemote = Instance.new("RemoteEvent")
	portalRemote.Name = "TutorialPortalRemote"
	portalRemote.Parent = remotes
end

local guideRoots = {} --// every set-up guide, for the YES range check

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
-- Guide setup
----------------------------------------------------------------
local bubbleLabel, bubbleGui
local bubbleSerial = 0

local function buildGuideUi(root)
	--// Floating nametag, studs-sized like the vendor's so it shrinks
	--// with distance instead of looming over the street
	local tag = Instance.new("BillboardGui")
	tag.Name = "GuideTag"
	tag.Size = UDim2.new(5, 0, 1.4, 0)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	tag.AlwaysOnTop = false
	tag.MaxDistance = PORTAL.TagMaxDistanceStuds
	tag.Parent = root

	local tagLabel = Instance.new("TextLabel")
	tagLabel.Size = UDim2.fromScale(1, 1)
	tagLabel.BackgroundTransparency = 1
	tagLabel.Font = Enum.Font.FredokaOne
	tagLabel.TextScaled = true
	tagLabel.TextColor3 = MUSTARD
	tagLabel.TextStrokeColor3 = CHOC
	tagLabel.TextStrokeTransparency = 0
	tagLabel.Text = "HOW TO PLAY"
	tagLabel.Parent = tag

	--// Speech bubble: hidden until someone talks
	bubbleGui = Instance.new("BillboardGui")
	bubbleGui.Name = "GuideBubble"
	bubbleGui.Size = UDim2.new(7, 0, 1.9, 0)
	bubbleGui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	bubbleGui.AlwaysOnTop = false
	bubbleGui.MaxDistance = PORTAL.TagMaxDistanceStuds
	bubbleGui.Enabled = false
	bubbleGui.Parent = root

	local bubble = Instance.new("Frame")
	bubble.Size = UDim2.fromScale(1, 1)
	bubble.BackgroundColor3 = CREAM
	bubble.Parent = bubbleGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = bubble

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CHOC
	stroke.Parent = bubble

	bubbleLabel = Instance.new("TextLabel")
	bubbleLabel.Size = UDim2.fromScale(0.92, 0.8)
	bubbleLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	bubbleLabel.Position = UDim2.fromScale(0.5, 0.5)
	bubbleLabel.BackgroundTransparency = 1
	bubbleLabel.Font = Enum.Font.FredokaOne
	bubbleLabel.TextScaled = true
	bubbleLabel.TextWrapped = true
	bubbleLabel.TextColor3 = CHOC
	bubbleLabel.Text = ""
	bubbleLabel.Parent = bubble
end

local function say(text)
	if not bubbleGui then return end
	bubbleSerial += 1
	local mySerial = bubbleSerial
	bubbleLabel.Text = text
	bubbleGui.Enabled = true
	task.delay(PORTAL.BubbleSeconds, function()
		if bubbleSerial == mySerial and bubbleGui then
			bubbleGui.Enabled = false
		end
	end)
end

----------------------------------------------------------------
-- The teleport: a RESERVED server so the rookie trains alone -
-- Mode = "TUTORIAL" is the whole handshake, MatchServer does the rest
----------------------------------------------------------------
local function sendToTutorial(player)
	if RunService:IsStudio() then
		say(PORTAL.StudioLine)
		warn("[TutorialGuide] TeleportAsync cannot run in Studio - test from the Roblox app")
		return
	end

	local ok, code = pcall(function()
		return TeleportService:ReserveServer(GAME_PLACE_ID)
	end)
	if not ok then
		warn("[TutorialGuide] ReserveServer failed:", code)
		say(PORTAL.FailLine)
		return
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	options:SetTeleportData({
		Mode = "TUTORIAL",
		Difficulty = PORTAL.Difficulty,
		MapId = PORTAL.MapId,
		MaxPlayers = 1,
	})

	say(PORTAL.SendLine)
	local sent, err = pcall(function()
		TeleportService:TeleportAsync(GAME_PLACE_ID, { player }, options)
	end)
	if not sent then
		warn("[TutorialGuide] TeleportAsync failed:", err)
		say(PORTAL.FailLine)
	end
end

----------------------------------------------------------------
-- The answer: the card is client-side comfort, the server only obeys
-- a YES from someone actually standing at a guide
----------------------------------------------------------------
local function nearAnyGuide(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	for _, guideRoot in ipairs(guideRoots) do
		if guideRoot.Parent
			and (guideRoot.Position - root.Position).Magnitude
				<= PORTAL.ConfirmRangeStuds then
			return true
		end
	end
	return false
end

portalRemote.OnServerEvent:Connect(function(player, answer)
	if answer ~= "Yes" then return end --// NO closes client-side only
	if not nearAnyGuide(player) then return end --// walked off: stale card
	sendToTutorial(player)
end)

local function setupGuide(root)
	--// Silence the rig's own overhead name - HOW TO PLAY is the label
	local rigModel = root:FindFirstAncestorOfClass("Model") or root.Parent
	local rigHumanoid = rigModel and rigModel:FindFirstChildOfClass("Humanoid")
	if rigHumanoid then
		rigHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	buildGuideUi(root)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TalkToGuide"
	prompt.ActionText = "Talk"
	prompt.ObjectText = "How to Play"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = root

	prompt.Triggered:Connect(function(player)
		say(PORTAL.Greetings[math.random(#PORTAL.Greetings)])
		portalRemote:FireClient(player, "Ask")
	end)

	table.insert(guideRoots, root)
	print(("[TutorialGuide] guide ready at %s"):format(root:GetFullName()))
end

local function trySetup(instance)
	local root = resolvePart(instance)
	if root then
		setupGuide(root)
	else
		warn(("[TutorialGuide] %s is tagged %s but has no BasePart - skipped")
			:format(instance:GetFullName(), TAG))
	end
end

for _, instance in ipairs(CollectionService:GetTagged(TAG)) do
	trySetup(instance)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(trySetup)

if #CollectionService:GetTagged(TAG) == 0 then
	print(("[TutorialGuide] no rig tagged %s yet - place one and tag it, no restart needed"):format(TAG))
end
