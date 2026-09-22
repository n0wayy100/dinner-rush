--[[
	Dinner Rush - PlateThrowClient
	StarterPlayer.StarterPlayerScripts.Client.PlateThrowClient  (LocalScript)

	THE PLATE-THROW SLINGSHOT (Waiter's Plate Juggler). When the server sends
	"ThrowGame" (fired after SkillService confirms the waiter holds a plated
	dish someone ordered), this opens a GUI minigame:

	  - a slingshot on the left with the dish loaded
	  - one TABLE card per table that ordered the dish (up to MaxTargets)
	  - drag the plate back (Angry Birds), release, and a 2D arc flies under
	    gravity; landing on a table card serves that real table

	Render + intent only: the client reports the table its plate hit via
	"ThrowHit"; SkillService/ServiceLoop re-validate and serve with credit.
	Tuning in Config.PlateThrow.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local PT = Config.PlateThrow
if not PT then return end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local skillRemote = remotes:WaitForChild("SkillRemote")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local WOOD = Color3.fromRGB(150, 104, 62)

local function dishIcon(dish)
	local r = Config.Recipes and Config.Recipes[dish]
	return r and r.Icon or ""
end
local function dishDisplay(dish)
	local r = Config.Recipes and Config.Recipes[dish]
	return (r and r.Display) or dish
end

----------------------------------------------------------------
-- one session at a time
----------------------------------------------------------------
local session = nil

local function closeSession()
	if not session then return end
	if session.conn then session.conn:Disconnect() end
	if session.downConn then session.downConn:Disconnect() end
	if session.moveConn then session.moveConn:Disconnect() end
	if session.upConn then session.upConn:Disconnect() end
	if session.gui then session.gui:Destroy() end
	session = nil
end

--// a rounded frame helper
local function rounded(parent, corner)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(corner or 0.15, 0)
	c.Parent = parent
end
local function stroke(parent, thick, color)
	local s = Instance.new("UIStroke")
	s.Thickness = thick or 2.5
	s.Color = color or CHOC
	s.Parent = parent
	return s
end

----------------------------------------------------------------
-- open the minigame
----------------------------------------------------------------
local function openGame(dish, targets)
	closeSession()
	if type(targets) ~= "table" or #targets == 0 then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "PlateThrow_UI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 45
	gui.Parent = playerGui

	--// dim
	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.Parent = gui

	--// the play panel
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.82, 0.64)
	panel.BackgroundColor3 = Color3.fromRGB(214, 232, 240) --// a soft "dining room" wash
	panel.Parent = gui
	rounded(panel, 0.05)
	stroke(panel, 3, CHOC)
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1.7
	ratio.Parent = panel

	--// title
	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.03)
	title.Size = UDim2.fromScale(0.9, 0.12)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "Sling the " .. dishDisplay(dish) .. " to a table!"
	title.TextColor3 = CHOC
	title.Parent = panel
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 30
	titleCap.Parent = title

	--// close (cancel - nothing lost)
	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.99, 0.02)
	close.Size = UDim2.fromScale(0.07, 0.11)
	close.BackgroundColor3 = TOMATO
	close.Font = Enum.Font.FredokaOne
	close.TextScaled = true
	close.Text = "X"
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Parent = panel
	rounded(close, 0.3)
	close.Activated:Connect(closeSession)

	--// the sling base (decorative)
	local slingBase = Instance.new("Frame")
	slingBase.AnchorPoint = Vector2.new(0.5, 0)
	slingBase.Position = UDim2.fromScale(0.16, 0.7)
	slingBase.Size = UDim2.fromScale(0.03, 0.28)
	slingBase.BackgroundColor3 = WOOD
	slingBase.Parent = panel
	rounded(slingBase, 0.4)

	--// the flying plate (dish on a plate)
	local plate = Instance.new("Frame")
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Size = UDim2.fromScale(0.11, 0.11 * ratio.AspectRatio) --// squareish
	plate.BackgroundColor3 = Color3.fromRGB(243, 236, 224)
	plate.ZIndex = 5
	plate.Parent = panel
	rounded(plate, 1)
	stroke(plate, 2, CHOC)
	local plateAspect = Instance.new("UIAspectRatioConstraint")
	plateAspect.AspectRatio = 1
	plateAspect.Parent = plate
	local pIcon = Instance.new("ImageLabel")
	pIcon.Size = UDim2.fromScale(0.86, 0.86)
	pIcon.Position = UDim2.fromScale(0.07, 0.07)
	pIcon.BackgroundTransparency = 1
	pIcon.ScaleType = Enum.ScaleType.Fit
	pIcon.Image = dishIcon(dish)
	pIcon.ZIndex = 6
	pIcon.Parent = plate

	--// trajectory dots
	local dots = {}
	for i = 1, (PT.TrailDots or 22) do
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Size = UDim2.fromOffset(7, 7)
		d.BackgroundColor3 = CHOC
		d.BackgroundTransparency = 1
		d.ZIndex = 4
		d.Parent = panel
		rounded(d, 1)
		dots[i] = d
	end

	--// target table cards - one per table that ordered the dish
	local maxT = math.min(#targets, PT.MaxTargets or 4)
	local cards = {} --// { CenterScale = Vector2, TableId, Frame }
	for i = 1, maxT do
		local t = targets[i]
		local cx = 0.66 + 0.08 * ((i - 1) % 2)
		local cy = 0.26 + (i - 1) * (0.5 / math.max(maxT - 1, 1))
		if maxT == 1 then cx, cy = 0.72, 0.5 end

		local card = Instance.new("Frame")
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(cx, cy)
		card.Size = UDim2.fromScale(0.14, 0.14 * ratio.AspectRatio)
		card.BackgroundColor3 = CREAM
		card.Parent = panel
		rounded(card, 0.18)
		stroke(card, 2.5, CHOC)
		local cAspect = Instance.new("UIAspectRatioConstraint")
		cAspect.AspectRatio = 1
		cAspect.Parent = card

		local num = Instance.new("TextLabel")
		num.Size = UDim2.fromScale(1, 0.32)
		num.BackgroundTransparency = 1
		num.Font = Enum.Font.FredokaOne
		num.TextScaled = true
		num.Text = "Table " .. tostring(t.TableId)
		num.TextColor3 = CHOC
		num.Parent = card
		local cIcon = Instance.new("ImageLabel")
		cIcon.Position = UDim2.fromScale(0.15, 0.32)
		cIcon.Size = UDim2.fromScale(0.7, 0.62)
		cIcon.BackgroundTransparency = 1
		cIcon.ScaleType = Enum.ScaleType.Fit
		cIcon.Image = dishIcon(dish)
		cIcon.Parent = card

		cards[i] = { CenterScale = Vector2.new(cx, cy), TableId = t.TableId, Frame = card }
	end

	----------------------------------------------------------------
	-- geometry: work in PANEL PIXELS (from AbsoluteSize), so the arc is not
	-- aspect-distorted. anchor = the sling pocket.
	----------------------------------------------------------------
	local function panelSize()
		return panel.AbsoluteSize
	end
	local anchorScale = Vector2.new(0.16, 0.62)
	local function anchorPx()
		local s = panelSize()
		return Vector2.new(anchorScale.X * s.X, anchorScale.Y * s.Y)
	end
	local function setPlatePx(px)
		local s = panelSize()
		plate.Position = UDim2.fromScale(px.X / s.X, px.Y / s.Y)
	end

	--// gravity/power normalized to a 400px-tall reference so the feel is the
	--// same on every screen size
	local function scaleFactor()
		return panelSize().Y / 400
	end

	session = {
		gui = gui, dish = dish, cards = cards, dots = dots, plate = plate,
		flying = false, dragging = false, dragStart = Vector2.new(),
	}

	local function plateScalePx()
		local s = panelSize()
		return Vector2.new(plate.Position.X.Scale * s.X, plate.Position.Y.Scale * s.Y)
	end
	--// launch from the plate's pulled-back spot toward/through the sling
	local function launchVelocity()
		return (anchorPx() - plateScalePx()) * (PT.PowerScale or 6.5)
	end

	local function hideTrajectory()
		for _, d in ipairs(dots) do d.BackgroundTransparency = 1 end
	end
	local function drawTrajectory()
		local s = panelSize()
		local from = plateScalePx()
		local vel = launchVelocity()
		local g = (PT.Gravity or 2200) * scaleFactor()
		for i, d in ipairs(dots) do
			local t = i * 0.045
			local pos = from + vel * t + Vector2.new(0, 0.5 * g * t * t)
			if pos.Y > s.Y or pos.X < 0 or pos.X > s.X then
				d.BackgroundTransparency = 1
			else
				d.Position = UDim2.fromScale(pos.X / s.X, pos.Y / s.Y)
				d.BackgroundTransparency = 0.25
			end
		end
	end

	local function resetPlate()
		session.flying = false
		setPlatePx(anchorPx())
	end
	resetPlate()

	--// success: flash the hit card, tell the server, close
	local function serveTable(tableId, card)
		session.flying = true --// lock further input
		hideTrajectory()
		skillRemote:FireServer("ThrowHit", tableId)
		if card and card.Frame then
			card.Frame.BackgroundColor3 = BASIL
			local tick = Instance.new("TextLabel")
			tick.Size = UDim2.fromScale(1, 1)
			tick.BackgroundTransparency = 1
			tick.Font = Enum.Font.FredokaOne
			tick.TextScaled = true
			tick.Text = "✓"
			tick.TextColor3 = Color3.new(1, 1, 1)
			tick.ZIndex = 10
			tick.Parent = card.Frame
		end
		task.delay(0.5, closeSession)
	end

	----------------------------------------------------------------
	-- input: press to grab, drag to pull, release to fling
	----------------------------------------------------------------
	local function moveTo(screenPos)
		if not session.dragging or session.flying then return end
		local a = anchorPx()
		local p = Vector2.new(screenPos.X, screenPos.Y) - panel.AbsolutePosition
		local pull = p - a
		local maxPull = (PT.MaxPullPixels or 240) * scaleFactor()
		if pull.Magnitude > maxPull then pull = pull.Unit * maxPull end
		setPlatePx(a + pull)
		drawTrajectory()
	end

	local function endDrag()
		if not session.dragging or session.flying then return end
		session.dragging = false
		hideTrajectory()
		local a = anchorPx()
		local platePx = plateScalePx()
		if (platePx - a).Magnitude < (PT.MinPullPixels or 12) * scaleFactor() then
			resetPlate() --// a tiny tap, not a throw
			return
		end
		session.flying = true
		local vel = (a - platePx) * (PT.PowerScale or 6.5)
		local pos = platePx
		local g = (PT.Gravity or 2200) * scaleFactor()
		local plateR = (PT.PlateRadiusPx or 26) * scaleFactor()
		local targetR = (PT.TargetRadiusPx or 54) * scaleFactor()

		session.conn = RunService.RenderStepped:Connect(function(dt)
			if not session or not session.flying then return end
			vel = vel + Vector2.new(0, g) * dt
			pos = pos + vel * dt
			setPlatePx(pos)
			local s = panelSize()
			for _, card in ipairs(cards) do
				local c = Vector2.new(card.CenterScale.X * s.X, card.CenterScale.Y * s.Y)
				if (pos - c).Magnitude <= (plateR + targetR) then
					if session.conn then session.conn:Disconnect(); session.conn = nil end
					serveTable(card.TableId, card)
					return
				end
			end
			if pos.Y > s.Y + 80 or pos.X < -80 or pos.X > s.X + 80 then
				if session.conn then session.conn:Disconnect(); session.conn = nil end
				resetPlate()
			end
		end)
	end

	--// global so a press on the plate/card (Frames don't bubble) still grabs;
	--// gameProcessed skips the X button so it can close normally
	session.downConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or session.flying then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			session.dragging = true
			moveTo(input.Position)
		end
	end)
	session.moveConn = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			moveTo(input.Position)
		end
	end)
	session.upConn = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			endDrag()
		end
	end)
end

----------------------------------------------------------------
skillRemote.OnClientEvent:Connect(function(action, a, b)
	if action == "ThrowGame" then
		openGame(a, b) --// a = dish, b = targets
	end
end)
