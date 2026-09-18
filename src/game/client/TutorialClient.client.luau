--[[
	Dinner Rush - TutorialClient
	StarterPlayer.StarterPlayerScripts.Client.TutorialClient  (LocalScript)

	The tutorial's face: a top-centre OBJECTIVE banner ("STEP 3/15 -
	Take the order!") driven by ReplicatedStorage.TutorialState, a
	SKIP TUTORIAL pill (top-right, clear of mobile thumbs and the shift
	bar), and BRUNO'S DIALOGUE CARD (bottom-centre, owner ruling Sep
	2026): his teaching lines type on and then WAIT - tap the card to
	finish the typing instantly, tap again (or gamepad A) to send
	"Next" and get the following box. Normal ManagerClient commentary
	is muted on tutorial servers so only this Bruno speaks.

	The TutorialState folder only EXISTS on tutorial servers - on a
	normal shift the wait below times out and this script exits.
	Render-only: skip and box-advance are intents ("Skip"/"Next" on
	TutorialRemote); the server decides everything else.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")

local State = ReplicatedStorage:WaitForChild("TutorialState", 30)
if not State then return end --// not a tutorial server

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local TUT = Config.Tutorial
local MANAGER = Config.Manager

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local tutorialRemote = remotes:WaitForChild("TutorialRemote")

local CREAM = Color3.fromRGB(255, 246, 233)
local CREAM_DEEP = Color3.fromRGB(255, 236, 210)
local CHOC = Color3.fromRGB(59, 43, 32)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local TOMATO = Color3.fromRGB(229, 72, 77)

local gui = Instance.new("ScreenGui")
gui.Name = "Tutorial_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 28
gui.Parent = playerGui

--// THE BANNER: below the shift bar, above the action
local banner = Instance.new("Frame")
banner.Active = false
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.fromScale(0.5, 0.13)
banner.Size = UDim2.fromScale(0.44, 0.075)
banner.BackgroundColor3 = CREAM
banner.BorderSizePixel = 0
banner.Visible = false
banner.Parent = gui
local gradient = Instance.new("UIGradient")
gradient.Rotation = 90
gradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
gradient.Parent = banner
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.3, 0)
corner.Parent = banner
local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = CHOC
stroke.Parent = banner

--// Just the task, no STEP counter (owner call, Sep 2026)
local objective = Instance.new("TextLabel")
objective.Active = false
objective.Size = UDim2.fromScale(0.9, 0.72)
objective.Position = UDim2.fromScale(0.05, 0.14)
objective.BackgroundTransparency = 1
objective.Font = Enum.Font.FredokaOne
objective.TextScaled = true
objective.Text = ""
objective.TextColor3 = CHOC
objective.Parent = banner
local objectiveCap = Instance.new("UITextSizeConstraint")
objectiveCap.MaxTextSize = 24
objectiveCap.Parent = objective

--// SKIP: a small FIXED-SIZE pill top-right, out of every mobile
--// control's way - offset sizing so it never balloons on big screens
local skip = Instance.new("TextButton")
skip.AnchorPoint = Vector2.new(1, 0)
skip.Position = UDim2.new(1, -12, 0.24, 0)
skip.Size = UDim2.fromOffset(132, 30)
skip.BackgroundColor3 = CREAM
skip.Font = Enum.Font.FredokaOne
skip.TextSize = 16
skip.Text = "SKIP TUTORIAL"
skip.TextColor3 = TOMATO
skip.Parent = gui
local skipCorner = Instance.new("UICorner")
skipCorner.CornerRadius = UDim.new(0.5, 0)
skipCorner.Parent = skip
local skipStroke = Instance.new("UIStroke")
skipStroke.Thickness = 2.5
skipStroke.Color = CHOC
skipStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border --// box, not glyphs
skipStroke.Parent = skip

skip.Activated:Connect(function()
	tutorialRemote:FireServer("Skip")
	skip.Visible = false
end)

----------------------------------------------------------------
-- BRUNO'S DIALOGUE CARD: bottom-centre (ManagerClient's spot - the
-- normal commentator is muted on tutorial servers, so no collision).
-- The whole card is one big button: tap while typing = show it all,
-- tap when done = "Next". Gamepad A does the same.
----------------------------------------------------------------
local card = Instance.new("TextButton")
card.AnchorPoint = Vector2.new(0.5, 1)
card.Position = UDim2.fromScale(0.5, 0.97)
card.Size = UDim2.fromScale(0.52, 0.17)
card.BackgroundColor3 = CREAM
card.Text = ""
card.AutoButtonColor = false
card.Visible = false
card.Parent = gui
local cardGradient = Instance.new("UIGradient")
cardGradient.Rotation = 90
cardGradient.Color = ColorSequence.new(CREAM, CREAM_DEEP)
cardGradient.Parent = card
local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0.12, 0)
cardCorner.Parent = card
local cardStroke = Instance.new("UIStroke")
cardStroke.Thickness = 3
cardStroke.Color = CHOC
cardStroke.Parent = card

--// The portrait chip: Bruno's PNG when the owner has set
--// Config.Manager.PortraitImage; until then the LOCAL player's own
--// headshot stands in (owner call, Sep 2026) so the chip never sits
--// empty - swap happens by setting the config, no code change
local portrait = Instance.new("ImageLabel")
if MANAGER and MANAGER.PortraitImage and MANAGER.PortraitImage ~= "" then
	portrait.Image = MANAGER.PortraitImage
else
	portrait.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150")
		:format(player.UserId)
end
portrait.Active = false
portrait.AnchorPoint = Vector2.new(0, 0.5)
portrait.Position = UDim2.new(0, 12, 0.5, 0)
--// RelativeYY: BOTH axes follow the card's HEIGHT, so this is a
--// square chip a bit smaller than the card is tall
portrait.Size = UDim2.fromScale(0.74, 0.74)
portrait.SizeConstraint = Enum.SizeConstraint.RelativeYY
portrait.BackgroundColor3 = CHOC
portrait.Parent = card
local portraitCorner = Instance.new("UICorner")
portraitCorner.CornerRadius = UDim.new(0.2, 0)
portraitCorner.Parent = portrait

local speech = Instance.new("TextLabel")
speech.Active = false
speech.AnchorPoint = Vector2.new(1, 0.5)
speech.Position = UDim2.fromScale(0.97, 0.48)
speech.Size = UDim2.fromScale(0.72, 0.72)
speech.BackgroundTransparency = 1
speech.Font = Enum.Font.FredokaOne
speech.TextScaled = true
speech.TextWrapped = true
speech.TextXAlignment = Enum.TextXAlignment.Left
speech.Text = ""
speech.TextColor3 = CHOC
speech.Parent = card
--// TextScaled blows short lines up to poster size without this cap
local speechCap = Instance.new("UITextSizeConstraint")
speechCap.MaxTextSize = 26
speechCap.Parent = speech

local hint = Instance.new("TextLabel")
hint.Active = false
hint.AnchorPoint = Vector2.new(1, 1)
hint.Position = UDim2.fromScale(0.97, 0.97)
hint.Size = UDim2.fromScale(0.1, 0.2)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.FredokaOne
hint.TextScaled = true
hint.Text = "▼"
hint.TextColor3 = MUSTARD
hint.TextStrokeColor3 = CHOC
hint.TextStrokeTransparency = 0.4
hint.Visible = false
hint.Parent = card

--// the bobbing "your move" cue
task.spawn(function()
	while card.Parent do
		if hint.Visible then
			TweenService:Create(hint, TweenInfo.new(0.4, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut), { Position = UDim2.fromScale(0.97, 1.02) }):Play()
			task.wait(0.4)
			TweenService:Create(hint, TweenInfo.new(0.4, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut), { Position = UDim2.fromScale(0.97, 0.97) }):Play()
			task.wait(0.4)
		else
			task.wait(0.2)
		end
	end
end)

--// THE TYPEWRITER: reveal by character count via TextLabel's
--// MaxVisibleGraphemes, cancelled by a token when a new box arrives
local typeToken = 0
local fullShown = false
local charsPerSecond = (TUT and TUT.TypeCharsPerSecond) or 28

local function showBox(text)
	typeToken += 1
	local myToken = typeToken
	fullShown = false
	hint.Visible = false
	card.Visible = true
	speech.Text = text
	speech.MaxVisibleGraphemes = 0

	--// a small pop so a fresh box reads as fresh
	card.Size = UDim2.fromScale(0.5, 0.16)
	TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.52, 0.17) }):Play()

	task.spawn(function()
		local total = utf8.len(text) or #text
		for i = 1, total do
			if typeToken ~= myToken or fullShown then return end
			speech.MaxVisibleGraphemes = i
			task.wait(1 / charsPerSecond)
		end
		if typeToken == myToken then
			fullShown = true
			speech.MaxVisibleGraphemes = -1
			hint.Visible = true
		end
	end)
end

local function hideBox()
	typeToken += 1
	card.Visible = false
	hint.Visible = false
end

local function advance()
	if not card.Visible then return end
	if fullShown then
		hint.Visible = false
		tutorialRemote:FireServer("Next") --// the server sends the next box
	else
		--// impatient tap: finish the typing, next tap advances
		fullShown = true
		speech.MaxVisibleGraphemes = -1
		hint.Visible = true
	end
end

card.Activated:Connect(advance)

--// Gamepad A advances too; bound only while a box is up, and only
--// sinking when it actually acted
ContextActionService:BindAction("TutorialAdvance", function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin or not card.Visible then
		return Enum.ContextActionResult.Pass
	end
	advance()
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.ButtonA)

State:GetAttributeChangedSignal("DialogueId"):Connect(function()
	local text = State:GetAttribute("Dialogue") or ""
	if text ~= "" then
		showBox(text)
	end
end)
State:GetAttributeChangedSignal("Dialogue"):Connect(function()
	if (State:GetAttribute("Dialogue") or "") == "" then
		hideBox()
	end
end)

----------------------------------------------------------------
-- THE GUIDE LINE (owner spec, Sep 2026: "an actual line arrow"): a
-- mustard beam from the player's feet to the current target, plus a
-- bobbing ⬇ marker floating over it. Render-only, all client-side
-- instances; the edge 👉 badge still covers off-screen targets.
----------------------------------------------------------------
local GUIDE = (TUT and TUT.Guide) or {}

--// nearest instance wearing the tag (Method attribute narrows cook
--// stations) - same picking rule as the edge arrow
local function nearestTagged(tag, method)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local best, bestDistance = nil, math.huge
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			local part = instance:IsA("BasePart") and instance
				or (instance:IsA("Model")
					and (instance.PrimaryPart
						or instance:FindFirstChildWhichIsA("BasePart", true)))
			local methodOk = not method or method == ""
				or instance:GetAttribute("Method") == method
				or (part and part:GetAttribute("Method") == method)
			if part and methodOk then
				local distance = root
					and (part.Position - root.Position).Magnitude or 0
				if distance < bestDistance then
					best, bestDistance = part, distance
				end
			end
		end
	end
	return best
end

local MUSTARD_SEQ = ColorSequence.new(MUSTARD)
local guideAttach0, guideAttach1, guideBeam = nil, nil, nil

local marker = Instance.new("BillboardGui")
marker.Name = "TutorialMarker"
marker.Size = UDim2.fromOffset(46, 46)
marker.StudsOffsetWorldSpace = Vector3.new(0, GUIDE.MarkerHoverStuds or 4, 0)
marker.AlwaysOnTop = true
marker.Enabled = false
marker.Parent = gui
local markerLabel = Instance.new("TextLabel")
markerLabel.Size = UDim2.fromScale(1, 1)
markerLabel.BackgroundTransparency = 1
markerLabel.Font = Enum.Font.FredokaOne
markerLabel.TextScaled = true
markerLabel.Text = "⬇"
markerLabel.TextColor3 = MUSTARD
markerLabel.TextStrokeColor3 = CHOC
markerLabel.TextStrokeTransparency = 0
markerLabel.Parent = marker

--// the marker bobs so it reads as alive, not stuck scenery
task.spawn(function()
	local up = true
	while marker.Parent do
		local hover = GUIDE.MarkerHoverStuds or 4
		TweenService:Create(marker, TweenInfo.new(0.45, Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut), {
				StudsOffsetWorldSpace = Vector3.new(0, up and hover + 0.7 or hover, 0),
			}):Play()
		up = not up
		task.wait(0.45)
	end
end)

local function clearGuide()
	if guideBeam then guideBeam:Destroy() guideBeam = nil end
	if guideAttach0 then guideAttach0:Destroy() guideAttach0 = nil end
	if guideAttach1 then guideAttach1:Destroy() guideAttach1 = nil end
	marker.Enabled = false
	marker.Adornee = nil
end

task.spawn(function()
	while gui.Parent do
		local tag = State:GetAttribute("TargetTag") or ""
		local wantGuide = State:GetAttribute("Active") == true and tag ~= ""
		local part = wantGuide
			and nearestTagged(tag, State:GetAttribute("TargetMethod")) or nil
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")

		if part and root then
			--// rebuild whichever end moved to a new instance (respawn,
			--// re-picked target); beams follow their parts on their own
			if not guideAttach0 or guideAttach0.Parent ~= root then
				if guideAttach0 then guideAttach0:Destroy() end
				guideAttach0 = Instance.new("Attachment")
				guideAttach0.Name = "TutorialGuide0"
				guideAttach0.Parent = root
			end
			if not guideAttach1 or guideAttach1.Parent ~= part then
				if guideAttach1 then guideAttach1:Destroy() end
				guideAttach1 = Instance.new("Attachment")
				guideAttach1.Name = "TutorialGuide1"
				guideAttach1.Parent = part
			end
			if not guideBeam or not guideBeam.Parent then
				guideBeam = Instance.new("Beam")
				guideBeam.Name = "TutorialGuideBeam"
				guideBeam.Color = MUSTARD_SEQ
				guideBeam.FaceCamera = true
				guideBeam.Width0 = GUIDE.BeamWidthStuds or 0.5
				guideBeam.Width1 = (GUIDE.BeamWidthStuds or 0.5) * 0.4
				guideBeam.Transparency = NumberSequence.new(GUIDE.BeamTransparency or 0.3)
				guideBeam.Parent = root
			end
			guideBeam.Attachment0 = guideAttach0
			guideBeam.Attachment1 = guideAttach1
			guideBeam.Enabled = true
			marker.Adornee = part
			marker.Enabled = true
		else
			clearGuide()
		end
		task.wait(GUIDE.RefreshSeconds or 0.4)
	end
end)

local function refresh()
	local text = State:GetAttribute("Objective") or ""

	banner.Visible = text ~= ""
	objective.Text = text

	--// a little pop so a new objective catches the eye
	banner.Size = UDim2.fromScale(0.4, 0.068)
	TweenService:Create(banner,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(0.44, 0.075) }):Play()
end

State:GetAttributeChangedSignal("Objective"):Connect(refresh)
State:GetAttributeChangedSignal("Step"):Connect(refresh)

--// Wrap-up: a green flourish, then everything melts away
State:GetAttributeChangedSignal("Active"):Connect(function()
	if State:GetAttribute("Active") ~= false then return end
	skip.Visible = false
	hideBox()
	clearGuide()
	ContextActionService:UnbindAction("TutorialAdvance")
	objective.TextColor3 = BASIL --// the goodbye banner goes celebration green
	task.delay(4, function()
		TweenService:Create(banner, TweenInfo.new(0.5),
			{ Position = UDim2.fromScale(0.5, -0.15) }):Play()
		task.delay(0.55, function()
			gui:Destroy()
		end)
	end)
end)

refresh()
print("[Tutorial] banner up - class is in session")
