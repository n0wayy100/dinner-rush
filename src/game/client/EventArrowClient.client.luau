--[[
	Dinner Rush - EventArrowClient
	StarterPlayer.StarterPlayerScripts.Client.EventArrowClient  (LocalScript)

	The "which way do I run" arrow. When an emergency is active, a badge
	+ pointer hugs the screen edge in the direction of the thing that
	needs you:

	  ToiletEmergency   the PlungerMount until you hold the plunger,
	                    then the toilet itself
	  GreaseFire        the ExtinguisherMount until you hold the
	                    extinguisher, then the nearest blaze
	  PowerOutage       the breaker box
	  (always)          any party mid dine-and-dash bolt

	Hidden whenever the target is actually on screen - the world
	billboards (fuse bars, the dash ❗) take over there. Render-only:
	everything read here is replicated state or tagged world geometry.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ARROW = Config.EventArrow

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local EventState = ReplicatedStorage:WaitForChild("EventState", 30)

local gui = Instance.new("ScreenGui")
gui.Name = "EventArrow_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 24
gui.Parent = playerGui

----------------------------------------------------------------
-- Two reusable widgets (an emergency + a dasher can overlap)
----------------------------------------------------------------
local function buildWidget()
	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.fromOffset(44, 44)
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.BackgroundColor3 = CREAM
	badge.Font = Enum.Font.FredokaOne
	badge.TextScaled = true
	badge.Text = ""
	badge.Visible = false
	badge.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = badge

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = CHOC
	stroke.Parent = badge

	local pointer = Instance.new("TextLabel")
	pointer.Size = UDim2.fromOffset(30, 30)
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.BackgroundTransparency = 1
	pointer.Font = Enum.Font.FredokaOne
	pointer.TextScaled = true
	pointer.Text = "➤"
	pointer.TextColor3 = TOMATO
	pointer.TextStrokeColor3 = CHOC
	pointer.TextStrokeTransparency = 0
	pointer.Visible = false
	pointer.Parent = gui

	return { Badge = badge, Pointer = pointer, Target = nil }
end

local widgets = { buildWidget(), buildWidget() }

----------------------------------------------------------------
-- Target picking (cheap, a few times a second)
----------------------------------------------------------------
local function tagPart(tag)
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if instance:IsDescendantOf(workspace) then
			if instance:IsA("BasePart") then
				return instance
			end
			if instance:IsA("Model") then
				return instance.PrimaryPart
					or instance:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	return nil
end

local function holding(attribute)
	local containers = { player.Character, player:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute(attribute) then
					return true
				end
			end
		end
	end
	return false
end

local function nearestBlaze()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local best, bestDistance = nil, math.huge
	for _, instance in ipairs(workspace:GetChildren()) do
		if instance.Name == "GreaseBlaze" and instance:IsA("BasePart") then
			local distance = root
				and (instance.Position - root.Position).Magnitude or 0
			if distance < bestDistance then
				best, bestDistance = instance, distance
			end
		end
	end
	return best
end

local function computeTargets()
	local targets = {}

	local active = EventState and EventState:GetAttribute("ActiveEvent") or ""
	if active == "ToiletEmergency" then
		if holding("Plunger") then
			table.insert(targets, { Part = tagPart("Toilet"), Emoji = "🚽" })
		else
			table.insert(targets, { Part = tagPart("PlungerMount"), Emoji = "🚽" })
		end
	elseif active == "GreaseFire" then
		if holding("Extinguisher") then
			table.insert(targets, {
				Part = nearestBlaze() or tagPart("ExtinguisherMount"),
				Emoji = "🔥",
			})
		else
			table.insert(targets, { Part = tagPart("ExtinguisherMount"), Emoji = "🔥" })
		end
	elseif active == "PowerOutage" then
		table.insert(targets, { Part = tagPart("BreakerBox"), Emoji = "⚡" })
	end

	--// A bolting dasher gets an arrow regardless of events
	for _, pawn in ipairs(CollectionService:GetTagged("CustomerParty")) do
		if pawn:IsDescendantOf(workspace)
			and pawn:GetAttribute("PartyState") == "DINE AND DASH!!" then
			local part = pawn:IsA("BasePart") and pawn
				or (pawn:IsA("Model")
					and (pawn.PrimaryPart or pawn:FindFirstChildWhichIsA("BasePart", true)))
			if part then
				table.insert(targets, { Part = part, Emoji = "💨" })
				break --// one dash arrow is plenty
			end
		end
	end

	return targets
end

task.spawn(function()
	while true do
		local targets = computeTargets()
		for index, widget in ipairs(widgets) do
			widget.Target = targets[index]
		end
		task.wait(ARROW.RefreshSeconds)
	end
end)

----------------------------------------------------------------
-- Projection: clamp to the screen edge, point outward
----------------------------------------------------------------
local function updateWidget(widget)
	local target = widget.Target
	local part = target and target.Part
	if not part or not part.Parent then
		widget.Badge.Visible = false
		widget.Pointer.Visible = false
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then return end
	local viewport = camera.ViewportSize
	local point, inView = camera:WorldToViewportPoint(part.Position)

	--// On screen (with a little margin): the world billboard has it
	if inView and point.X > 40 and point.X < viewport.X - 40
		and point.Y > 40 and point.Y < viewport.Y - 40 then
		widget.Badge.Visible = false
		widget.Pointer.Visible = false
		return
	end

	local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
	local direction = Vector2.new(point.X, point.Y) - center
	if point.Z < 0 then
		direction = -direction --// behind the camera: flip
	end
	if direction.Magnitude < 1 then
		direction = Vector2.new(0, -1)
	end
	direction = direction.Unit

	--// Rectangular clamp to the edge, minus the margin
	local margin = ARROW.EdgeMarginPx
	local limitX = (center.X - margin) / math.max(math.abs(direction.X), 0.001)
	local limitY = (center.Y - margin) / math.max(math.abs(direction.Y), 0.001)
	local reach = math.min(limitX, limitY)
	local badgePos = center + direction * reach
	local pointerPos = badgePos + direction * 34

	widget.Badge.Text = target.Emoji
	widget.Badge.Position = UDim2.fromOffset(badgePos.X, badgePos.Y)
	widget.Badge.Visible = true

	widget.Pointer.Position = UDim2.fromOffset(pointerPos.X, pointerPos.Y)
	widget.Pointer.Rotation = math.deg(math.atan2(direction.Y, direction.X))
	widget.Pointer.Visible = true
end

RunService.RenderStepped:Connect(function()
	for _, widget in ipairs(widgets) do
		updateWidget(widget)
	end
end)
