--[[
	Dinner Rush - MinigameJuice
	ReplicatedStorage.Shared.MinigameJuice  (ModuleScript, CLIENT use)

	FEEDBACK EFFECTS for minigames (owner, Oct 2026): short effects that fire
	BECAUSE the player did something, last under a second, then clean
	themselves up. Nothing here runs on its own in the background - the games
	are played against a timer, and anything that moves without the player
	causing it pulls the eye off the cards.

		MinigameJuice.Burst(gui, color)       -- sparkle burst on a right answer
		MinigameJuice.Bounce(gui)             -- a quick happy bounce
		MinigameJuice.Wrong(gui)              -- red flash + shake on a wrong one
		MinigameJuice.Shake(gui, px, seconds) -- jolt anything (a whole panel)
		MinigameJuice.Verdict(label, quality) -- the end-of-game verdict: spinning
		                                         rays + a burst for Perfect, a
		                                         heavy thud for a flop

	Art (Config.MinigameArt): SparkleBurst and Rays. Both optional - with no
	SparkleBurst id the burst is a code-drawn expanding ring, and with no Rays
	id the Perfect verdict simply skips its rays.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local MUSTARD = Color3.fromRGB(245, 184, 65)
local TOMATO = Color3.fromRGB(229, 72, 77)

--// Effects drawn over a whole screen sit above everything on it
local OVERLAY_Z = 50

local MinigameJuice = {}

local function artId(key)
	local piece = Config.MinigameArt and Config.MinigameArt[key]
	local id = piece and piece.Id
	if type(id) == "number" then
		return ("rbxassetid://%d"):format(id)
	end
	if type(id) ~= "string" or id == "" then
		return nil
	end
	return id:match("^%d+$") and ("rbxassetid://" .. id) or id
end

local function tween(object, seconds, goal, style, direction)
	local t = TweenService:Create(object, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

--// Where `gui`'s centre is, measured from `inside`'s top-left - so an effect
--// can be parented somewhere that outlives `gui` (a whacked item is
--// destroyed a moment after its burst starts)
local function centreWithin(gui, inside)
	local centre = gui.AbsolutePosition + gui.AbsoluteSize / 2
	return centre - inside.AbsolutePosition
end

--// The UIScale an effect may borrow - the object's own if it has one
--// (UiPop's PopScale, a pulse scale), so two never fight over one object
local function scaleOf(gui)
	local scale = gui:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "JuiceScale"
		scale.Parent = gui
	end
	return scale
end

----------------------------------------------------------------
-- BURST
----------------------------------------------------------------

function MinigameJuice.Burst(gui, color)
	local screen = gui and gui:FindFirstAncestorWhichIsA("LayerCollector")
	if not screen then return end

	local centre = centreWithin(gui, screen)
	local size = math.max(gui.AbsoluteSize.X, gui.AbsoluteSize.Y)

	local burst
	local id = artId("SparkleBurst")
	if id then
		burst = Instance.new("ImageLabel")
		burst.Image = id
		burst.BackgroundTransparency = 1
	else
		--// no art yet: a ring that expands and fades does the same job
		burst = Instance.new("Frame")
		burst.BackgroundTransparency = 1
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = burst
		local ring = Instance.new("UIStroke")
		ring.Thickness = 5
		ring.Color = color or MUSTARD
		ring.Parent = burst
		tween(ring, 0.45, { Transparency = 1 })
	end

	burst.Name = "JuiceBurst"
	burst.Active = false
	burst.AnchorPoint = Vector2.new(0.5, 0.5)
	burst.Position = UDim2.fromOffset(centre.X, centre.Y)
	burst.Size = UDim2.fromOffset(size * 0.6, size * 0.6)
	burst.Rotation = math.random(0, 359)
	burst.ZIndex = OVERLAY_Z
	burst.Parent = screen

	local goal = {
		Size = UDim2.fromOffset(size * 1.7, size * 1.7),
		Rotation = burst.Rotation + 45,
	}
	if burst:IsA("ImageLabel") then
		goal.ImageTransparency = 1
	end
	tween(burst, 0.45, goal)
	Debris:AddItem(burst, 0.5)
end

----------------------------------------------------------------
-- BOUNCE / SHAKE / WRONG
----------------------------------------------------------------

function MinigameJuice.Bounce(gui)
	if not gui then return end
	local scale = scaleOf(gui)
	scale.Scale = 1.18
	tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

--// The latest shake per object; an older one stops when a newer starts
local shaking = setmetatable({}, { __mode = "k" })

function MinigameJuice.Shake(gui, strength, seconds)
	if not gui then return end
	strength = strength or 6
	seconds = seconds or 0.2

	--// The resting spot is remembered once, so a shake that starts while
	--// another is mid-jolt can never leave the object off-centre
	local home = gui:GetAttribute("JuiceHome")
	if typeof(home) ~= "UDim2" then
		home = gui.Position
		gui:SetAttribute("JuiceHome", home)
	end

	local mine = {}
	shaking[gui] = mine
	task.spawn(function()
		local steps = math.max(1, math.floor(seconds / 0.03))
		for step = 1, steps do
			if shaking[gui] ~= mine or not gui.Parent then return end
			local falloff = 1 - (step - 1) / steps
			gui.Position = home + UDim2.fromOffset(
				(math.random() * 2 - 1) * strength * falloff,
				(math.random() * 2 - 1) * strength * falloff)
			task.wait(0.03)
		end
		if shaking[gui] == mine then
			gui.Position = home
			gui:SetAttribute("JuiceHome", nil)
			shaking[gui] = nil
		end
	end)
end

function MinigameJuice.Wrong(gui)
	if not gui then return end
	local flash = Instance.new("Frame")
	flash.Name = "JuiceFlash"
	flash.Active = false
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = TOMATO
	flash.BackgroundTransparency = 0.35
	flash.BorderSizePixel = 0
	flash.ZIndex = gui.ZIndex + 1
	--// same rounded corners as what it covers
	local corner = gui:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = flash
	end
	flash.Parent = gui
	tween(flash, 0.35, { BackgroundTransparency = 1 })
	Debris:AddItem(flash, 0.4)

	MinigameJuice.Shake(gui, 5, 0.22)
end

----------------------------------------------------------------
-- THE VERDICT
----------------------------------------------------------------

--// `label` is the game's verdict text, already showing its words.
--// quality: "Perfect" / "Good" / "Overcooked" / "Ruined"
function MinigameJuice.Verdict(label, quality)
	if not label or not label.Parent then return end
	local scale = scaleOf(label)
	--// above the board, so rays behind it still sit over the cards
	label.ZIndex = math.max(label.ZIndex, 20)

	--// Measured at REST, before the punch-in scales it: a label pinned by
	--// its corner drifts while scaled, and the rays would land off-centre
	local parent = label.Parent
	local restCentre = parent:IsA("GuiObject") and centreWithin(label, parent)
	local restSize = math.max(label.AbsoluteSize.X, label.AbsoluteSize.Y)

	if quality == "Perfect" then
		--// THE PAYOFF: punch in big, rays spinning behind, a burst as it lands
		scale.Scale = 2.2
		tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)

		local raysId = artId("Rays")
		if raysId and restCentre then
			local centre = restCentre
			local size = restSize * 1.3
			local rays = Instance.new("ImageLabel")
			rays.Name = "JuiceRays"
			rays.Active = false
			rays.BackgroundTransparency = 1
			rays.Image = raysId
			rays.ImageTransparency = 1
			rays.AnchorPoint = Vector2.new(0.5, 0.5)
			rays.Position = UDim2.fromOffset(centre.X, centre.Y)
			rays.Size = UDim2.fromOffset(size, size)
			rays.ZIndex = label.ZIndex - 1
			rays.Parent = parent
			tween(rays, 0.15, { ImageTransparency = 0.15 })
			tween(rays, 1.3, { Rotation = 90 }, Enum.EasingStyle.Linear)
			task.delay(0.95, function()
				if rays.Parent then
					tween(rays, 0.3, { ImageTransparency = 1 })
				end
			end)
			Debris:AddItem(rays, 1.35)
		end
		--// the burst waits for the landing, when the label is back at rest
		task.delay(0.3, function()
			if label.Parent then
				MinigameJuice.Burst(label, MUSTARD)
			end
		end)

	elseif quality == "Ruined" or quality == "Overcooked" then
		--// THE FLOP: dropped on hard, like the report's stamp
		scale.Scale = 1.8
		local land = tween(scale, 0.16, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		land.Completed:Once(function()
			if label.Parent then
				MinigameJuice.Shake(label.Parent, 10, 0.3)
			end
		end)

	else
		--// a middling result: a friendly pop, no fanfare
		scale.Scale = 1.6
		tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

return MinigameJuice
