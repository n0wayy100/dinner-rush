--[[
	Dinner Rush - HudSkin
	StarterPlayer.StarterPlayerScripts.Client.HudSkin  (ModuleScript)

	The ART version of the shift HUD (owner, Oct 2026 - Claude Design art):
	the shift timer, the REP and TIDY bars and the money readout, drawn
	with the team's images from Config.HudArt. HudClient uses it as soon
	as the four bar pieces (SideFrame, SideFill, TimerFrame, TimerFill)
	have ids; until then the old code-drawn bars stay.

	DRAWN AS MADE: every piece is shown at its own shape (never stretched),
	and a fill is revealed through a window that grows from the left - the
	same method as the minigame bars. The fills are white art recoloured
	here (green / yellow / red), so the colours never live in the picture.

	Effects: fills slide, a white flash + shine sweep when a bar goes up,
	a shake when it drops, badge bounce + glow, sparkle burst on rep gain,
	tidy pulses red (and a fly buzzes) when dirty, the phase plaque swings
	in with rays on a new phase, steam off the timer's food badge, and a
	"+$12" that floats off the money.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MinigameJuice = require(Shared:WaitForChild("MinigameJuice"))

local CHOC = Color3.fromRGB(59, 43, 32)
local GOLD = Color3.fromRGB(245, 184, 65)
local TOMATO = Color3.fromRGB(229, 72, 77)
local WHITE = Color3.new(1, 1, 1)

local HudSkin = {}

local function art()
	return Config.HudArt or {}
end

--// "123", "rbxassetid://123" or a table { Id = "123" } -> a usable id or nil
local function idOf(entry)
	if type(entry) == "table" then entry = entry.Id end
	if type(entry) == "number" then entry = tostring(entry) end
	if type(entry) ~= "string" or entry == "" then return nil end
	return entry:match("^%d+$") and ("rbxassetid://" .. entry) or entry
end

function HudSkin.Ready()
	local a = art()
	return idOf(a.SideFrame) ~= nil and idOf(a.SideFill) ~= nil
		and idOf(a.TimerFrame) ~= nil and idOf(a.TimerFill) ~= nil
end

local function tween(object, seconds, goal, style, direction)
	local t = TweenService:Create(object, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

local function image(name, id, parent, z)
	local label = Instance.new("ImageLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Image = id or ""
	label.ScaleType = Enum.ScaleType.Stretch --// only ever used at the art's own shape
	label.ZIndex = z or 1
	label.Parent = parent
	return label
end

local function screen(playerGui, name, order)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = order or 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = playerGui
	return gui
end

--// a square badge: ring + the icon inside it (an image, or text such as an
--// emoji when there is no image). Bounces through its own UIScale.
local function badge(parent, spec, z)
	local a = art()
	local holder = Instance.new("Frame")
	holder.Name = "Badge"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(spec.X, spec.Y or 0.5)
	holder.Size = UDim2.fromScale(spec.Size, spec.Size)
	holder.SizeConstraint = Enum.SizeConstraint.RelativeYY
	holder.ZIndex = z
	holder.Parent = parent

	local glow = image("Glow", idOf(a.SoftGlow), holder, 1)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(1.9, 1.9)
	glow.ImageTransparency = 1
	glow.Visible = glow.Image ~= ""

	local ring = image("Ring", idOf(a.BadgeRing), holder, 2)
	ring.Size = UDim2.fromScale(1, 1)
	ring.Visible = ring.Image ~= ""

	local iconImage = image("Icon", nil, holder, 3)
	iconImage.AnchorPoint = Vector2.new(0.5, 0.5)
	iconImage.Position = UDim2.fromScale(0.5, 0.5)
	local inner = a.BadgeIconSize or 0.62
	iconImage.Size = UDim2.fromScale(inner, inner)

	local iconText = Instance.new("TextLabel")
	iconText.Name = "IconText"
	iconText.BackgroundTransparency = 1
	iconText.AnchorPoint = Vector2.new(0.5, 0.5)
	iconText.Position = UDim2.fromScale(0.5, 0.5)
	iconText.Size = UDim2.fromScale(inner, inner)
	iconText.Font = Enum.Font.FredokaOne
	iconText.TextScaled = true
	iconText.Text = ""
	iconText.ZIndex = 3
	iconText.Parent = holder

	local b = { Holder = holder, Glow = glow }
	function b.SetIcon(id, fallbackText)
		iconImage.Image = id or ""
		iconImage.Visible = id ~= nil
		iconText.Text = id and "" or (fallbackText or "")
		iconText.Visible = id == nil
	end
	function b.Flash(color)
		if not glow.Visible then return end
		glow.ImageColor3 = color or WHITE
		glow.ImageTransparency = 0.15
		tween(glow, 0.6, { ImageTransparency = 1 })
	end
	return b
end

--// THE BAR: a frame picture, a fill revealed through a growing window, a
--// badge in the socket. spec = the Config piece (FillStart/FillEnd are
--// where the track starts and ends, as fractions of the picture's width).
local function bar(parent, frameEntry, fillEntry, height, z)
	local a = art()
	local px = frameEntry.Size or { 640, 128 }
	local aspect = px[1] / px[2]
	local fillStart = frameEntry.FillStart or 0.16
	local fillEnd = frameEntry.FillEnd or 0.96
	local nudge = frameEntry.FillNudge or { 0, 0 }

	local box = Instance.new("Frame")
	box.Name = "Bar"
	box.BackgroundTransparency = 1
	box.Size = UDim2.fromScale(height * aspect, height)
	box.SizeConstraint = Enum.SizeConstraint.RelativeYY
	box.ZIndex = z or 1
	box.Parent = parent

	local frame = image("Frame", idOf(frameEntry), box, 1)
	frame.Size = UDim2.fromScale(1, 1)

	--// a window over the picture that grows from the left, with a full-size
	--// copy of the fill inside it - so the fill is uncovered, never squashed
	local function window(name, zIndex)
		local w = Instance.new("Frame")
		w.Name = name
		w.BackgroundTransparency = 1
		w.ClipsDescendants = true
		w.Size = UDim2.fromScale(fillStart, 1)
		w.ZIndex = zIndex
		w.Parent = box
		local f = image("Fill", idOf(fillEntry), w, 1)
		return w, f
	end
	local fillWindow, fill = window("FillWindow", 2)

	local copies = { fill }
	local function sync()
		local size = box.AbsoluteSize
		for _, copy in ipairs(copies) do
			copy.Size = UDim2.fromOffset(size.X, size.Y)
			copy.Position = UDim2.fromOffset(nudge[1] * size.X, nudge[2] * size.Y)
		end
	end
	box:GetPropertyChangedSignal("AbsoluteSize"):Connect(sync)

	local streak = image("Shine", idOf(a.ShineStreak), fillWindow, 2)
	streak.Visible = false
	streak.ImageTransparency = 0.25

	local self = {
		Box = box, Fill = fill, FillWindow = fillWindow,
		FillStart = fillStart, FillEnd = fillEnd, Fraction = nil,
	}

	function self.At(fraction)
		return fillStart + (fillEnd - fillStart) * math.clamp(fraction, 0, 1)
	end

	function self.Window(name, zIndex)
		local w, f = window(name, zIndex)
		table.insert(copies, f)
		sync()
		return w, f
	end

	function self.SetFraction(fraction, seconds)
		self.Fraction = fraction
		local goal = { Size = UDim2.fromScale(self.At(fraction), 1) }
		if seconds and seconds > 0 then
			tween(fillWindow, seconds, goal)
		else
			fillWindow.Size = goal.Size
		end
	end

	function self.Shine()
		if streak.Image == "" then return end
		local size = box.AbsoluteSize
		local w = size.Y * 2
		streak.Size = UDim2.fromOffset(w, size.Y)
		streak.Position = UDim2.fromOffset(-w, 0)
		streak.Visible = true
		local t = tween(streak, 0.55, { Position = UDim2.fromOffset(size.X * self.At(self.Fraction or 1), 0) },
			Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		t.Completed:Once(function() streak.Visible = false end)
	end

	function self.Flash(color)
		fill.ImageColor3 = WHITE
		tween(fill, 0.35, { ImageColor3 = color })
	end

	sync()
	return self
end

----------------------------------------------------------------
-- THE SKIN
----------------------------------------------------------------

function HudSkin.new(playerGui)
	local a = art()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local skin = {}

	------------------------------------------------ the shift timer
	local timerGui = screen(playerGui, "ShiftProgressArt_UI", 20)
	--// the bars size themselves from the SCREEN's height (so their shape
	--// never changes), so each sits in a full-screen holder
	local timer = bar(timerGui, a.TimerFrame, a.TimerFill, a.TimerHeight or 0.07, 1)
	timer.Box.AnchorPoint = Vector2.new(0.5, 0)
	timer.Box.Position = UDim2.fromScale(0.5, a.TimerY or 0.02)

	--// the phase colours ride the fill (white art x gradient = coloured,
	--// gloss kept)
	local timerGradient = Instance.new("UIGradient")
	timerGradient.Parent = timer.Fill

	--// time already gone: a darkened copy over the elapsed stretch
	local elapsedWindow, elapsedFill = timer.Window("Elapsed", 3)
	elapsedFill.ImageColor3 = Color3.new(0, 0, 0)
	elapsedFill.ImageTransparency = a.TimerElapsedDarkness and (1 - a.TimerElapsedDarkness) or 0.55

	local notches = {}
	for index = 1, 2 do
		local notch = image("Notch", idOf(a.PhaseNotch), timer.Box, 4)
		notch.AnchorPoint = Vector2.new(0.5, 0.5)
		notch.Size = UDim2.fromScale(0.5 * (a.NotchHeight or 0.55), a.NotchHeight or 0.55)
		notch.SizeConstraint = Enum.SizeConstraint.RelativeYY
		notch.Visible = false
		notches[index] = notch
	end

	--// rays behind the badge on a new phase (the minigame art)
	local rays = image("Rays", idOf(Config.MinigameArt and Config.MinigameArt.Rays), timer.Box, 5)
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.SizeConstraint = Enum.SizeConstraint.RelativeYY
	rays.Size = UDim2.fromScale(2.6, 2.6)
	rays.ImageColor3 = GOLD
	rays.Visible = false

	local timerBadge = badge(timer.Box, {
		X = a.TimerFrame.BadgeX or 0.044, Size = a.TimerFrame.BadgeSize or 1.05,
	}, 6)
	rays.Position = timerBadge.Holder.Position

	local pointer = image("Now", idOf(a.NowPointer), timer.Box, 7)
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Size = UDim2.fromScale(a.PointerSize or 0.5, a.PointerSize or 0.5)
	pointer.SizeConstraint = Enum.SizeConstraint.RelativeYY
	pointer.Position = UDim2.fromScale(timer.At(0), a.PointerY or 0.12)
	pointer.Visible = pointer.Image ~= ""

	local plaque = image("Plaque", idOf(a.PhasePlaque), timer.Box, 0)
	plaque.AnchorPoint = Vector2.new(0.5, 0)
	plaque.Position = UDim2.fromScale(0.5, a.PlaqueY or 0.82)
	local plaqueH = a.PlaqueHeight or 0.8
	plaque.Size = UDim2.fromScale(plaqueH * 4, plaqueH)
	plaque.SizeConstraint = Enum.SizeConstraint.RelativeYY
	local plaqueScale = Instance.new("UIScale")
	plaqueScale.Parent = plaque
	if plaque.Image == "" then
		--// no plaque art: a plain cream tab so the words still have a home
		plaque.BackgroundTransparency = 0
		plaque.BackgroundColor3 = Color3.fromRGB(255, 244, 224)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.3, 0)
		corner.Parent = plaque
		local stroke = Instance.new("UIStroke")
		stroke.Color = CHOC
		stroke.Thickness = 2
		stroke.Parent = plaque
	end
	local plaqueText = Instance.new("TextLabel")
	plaqueText.BackgroundTransparency = 1
	plaqueText.AnchorPoint = Vector2.new(0.5, 0.5)
	plaqueText.Position = UDim2.fromScale(0.5, a.PlaqueTextY or 0.6)
	plaqueText.Size = UDim2.fromScale(0.78, 0.48)
	plaqueText.Font = Enum.Font.FredokaOne
	plaqueText.TextScaled = true
	plaqueText.TextColor3 = CHOC
	plaqueText.Text = ""
	plaqueText.ZIndex = 2
	plaqueText.Parent = plaque

	--// the food in the timer's badge: this map's dish icon
	local function applyMapIcon()
		local mapId = workspace:GetAttribute("MatchMapId") or ""
		local icons = a.TimerIcons or {}
		local row = Config.MapById and Config.MapById(mapId)
		timerBadge.SetIcon(idOf(icons[mapId]), (row and row.ShiftBarIcon) or "🍔")
	end
	applyMapIcon()
	workspace:GetAttributeChangedSignal("MatchMapId"):Connect(applyMapIcon)

	local paintedFor = nil
	local lastPhase = nil

	function skin.Timer(enabled, fraction, phaseText, calmAt, buildAt, colors)
		timerGui.Enabled = enabled
		if not enabled then
			lastPhase = nil
			return
		end
		local key = ("%.3f/%.3f"):format(calmAt, buildAt)
		if paintedFor ~= key then
			paintedFor = key
			--// phase fractions -> spots on the PICTURE (the track does not
			--// span the whole image)
			--// THE GRADIENT (owner, Oct 2026: keep the old bar's look): the
			--// colours BLEND into each other around each phase change
			--// instead of a hard line. TimerBlend = how wide each blend is,
			--// as a share of the track (0 = hard line).
			local blend = math.clamp(a.TimerBlend or 0.06, 0.001, 0.07)
			--// two phase changes close together: the blends must not overlap
			blend = math.max(math.min(blend, (buildAt - calmAt) / 2 - 0.002,
				calmAt - 0.002, 1 - buildAt - 0.002), 0.001)
			timerGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, colors[1]),
				ColorSequenceKeypoint.new(timer.At(calmAt - blend), colors[1]),
				ColorSequenceKeypoint.new(timer.At(calmAt + blend), colors[2]),
				ColorSequenceKeypoint.new(timer.At(buildAt - blend), colors[2]),
				ColorSequenceKeypoint.new(timer.At(buildAt + blend), colors[3]),
				ColorSequenceKeypoint.new(1, colors[3]),
			})
			timer.SetFraction(1)
			for index, at in ipairs({ calmAt, buildAt }) do
				notches[index].Position = UDim2.fromScale(timer.At(at), 0.5)
				notches[index].Visible = notches[index].Image ~= ""
			end
		end

		local x = timer.At(fraction)
		tween(elapsedWindow, 0.12, { Size = UDim2.fromScale(x, 1) }, Enum.EasingStyle.Linear)
		tween(pointer, 0.12, { Position = UDim2.fromScale(x, a.PointerY or 0.12) }, Enum.EasingStyle.Linear)

		if phaseText ~= lastPhase then
			local first = lastPhase == nil
			lastPhase = phaseText
			plaqueText.Text = phaseText
			if not first then
				--// a new phase: the plaque swings in, rays behind the badge
				plaqueScale.Scale = 0.5
				plaque.Rotation = 10
				tween(plaqueScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
				tween(plaque, 1.1, { Rotation = 0 }, Enum.EasingStyle.Elastic)
				MinigameJuice.Bounce(timerBadge.Holder)
				timerBadge.Flash(GOLD)
				if rays.Image ~= "" then
					rays.Visible = true
					rays.ImageTransparency = 0.2
					rays.Rotation = 0
					local t = tween(rays, 1.6, { ImageTransparency = 1, Rotation = 90 })
					t.Completed:Once(function() rays.Visible = false end)
				end
			end
		end
	end

	------------------------------------------------ REP + TIDY
	local function sideBar(name, anchorX, x, iconKey)
		local gui = screen(playerGui, name, 20)
		local b = bar(gui, a.SideFrame, a.SideFill, a.SideHeight or 0.055, 1)
		b.Box.AnchorPoint = Vector2.new(anchorX, 0)
		b.Box.Position = UDim2.fromScale(x, touchOnly and 0.19 or 0.1)
		local bdg = badge(b.Box, {
			X = a.SideFrame.BadgeX or 0.098, Size = a.SideFrame.BadgeSize or 1.05,
		}, 5)
		bdg.SetIcon(idOf(a[iconKey]), iconKey == "StarIcon" and "⭐" or "✨")
		return gui, b, bdg
	end

	local repGui, rep, repBadge = sideBar("RepMeterArt_UI", 0, 0.02, "StarIcon")
	local tidyGui, tidy, tidyBadge = sideBar("TidinessMeterArt_UI", 1, 0.98, "BubblesIcon")

	local function feed(b, bdg, fraction, color, burstColor)
		local before = b.Fraction
		if before == nil then
			b.SetFraction(fraction)
			b.Fill.ImageColor3 = color
			return
		end
		if math.abs(fraction - before) < 0.004 then
			b.Fill.ImageColor3 = color
			return
		end
		b.SetFraction(fraction, 0.35)
		if fraction > before then
			b.Flash(color)
			b.Shine()
			MinigameJuice.Bounce(bdg.Holder)
			bdg.Flash(burstColor)
			if burstColor then
				MinigameJuice.Burst(bdg.Holder, burstColor)
			end
		else
			b.Fill.ImageColor3 = color
			MinigameJuice.Shake(b.Box, 4, 0.25)
			bdg.Flash(TOMATO)
		end
	end

	function skin.Rep(enabled, fraction, color)
		repGui.Enabled = enabled
		if not enabled then return end
		feed(rep, repBadge, fraction, color, GOLD)
	end

	local tidyLow = false
	function skin.Tidy(enabled, fraction, color)
		tidyGui.Enabled = enabled
		tidyLow = enabled and fraction < (a.TidyWarnBelow or 0.3)
		if not enabled then return end
		feed(tidy, tidyBadge, fraction, color, nil)
	end

	------------------------------------------------ steam, fly, red pulse
	local fly = image("Fly", idOf(a.Fly), tidyBadge.Holder, 4)
	fly.AnchorPoint = Vector2.new(0.5, 0.5)
	fly.Size = UDim2.fromScale(0.35, 0.35)
	fly.Visible = false

	local steamId = idOf(a.SteamPuff)
	local nextSteam = 0
	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		--// dirty: the tidy badge glows red in a slow pulse, a fly circles it
		if tidyLow and tidyGui.Enabled then
			local glow = tidyBadge.Glow
			if glow.Visible then
				glow.ImageColor3 = TOMATO
				glow.ImageTransparency = 0.45 + 0.35 * math.sin(clock * 5)
			end
			if fly.Image ~= "" then
				fly.Visible = true
				fly.Position = UDim2.fromScale(0.5 + 0.75 * math.cos(clock * 3.1),
					0.5 + 0.45 * math.sin(clock * 6.2))
				fly.Rotation = math.sin(clock * 20) * 15
			end
		else
			fly.Visible = false
		end
		--// steam curling off the food on the timer badge
		if steamId and timerGui.Enabled and clock >= nextSteam then
			nextSteam = clock + (a.SteamEverySeconds or 1.4)
			local puff = image("Steam", steamId, timerBadge.Holder, 5)
			puff.AnchorPoint = Vector2.new(0.5, 1)
			puff.Position = UDim2.fromScale(0.5 + (math.random() - 0.5) * 0.3, 0.3)
			puff.Size = UDim2.fromScale(0.45, 0.45)
			puff.ImageTransparency = 0.25
			tween(puff, 1.3, {
				Position = puff.Position - UDim2.fromScale(0, 0.55),
				Size = UDim2.fromScale(0.65, 0.65),
				ImageTransparency = 1,
			}, Enum.EasingStyle.Sine)
			Debris:AddItem(puff, 1.4)
		end
	end)

	------------------------------------------------ money
	local moneyLabel, moneyBefore = nil, nil
	function skin.DressMoney(label)
		moneyLabel = label
		local holder = badge(label, { X = 0, Size = a.MoneyBadgeSize or 1.15 }, 2)
		holder.Holder.AnchorPoint = Vector2.new(0, 0.5)
		holder.SetIcon(idOf(a.CoinIcon), "💰")
		local pad = Instance.new("UIPadding")
		pad.Parent = label
		local function fit()
			pad.PaddingLeft = UDim.new(0, label.AbsoluteSize.Y * ((a.MoneyBadgeSize or 1.15) + 0.2))
		end
		label:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		fit()
		skin.MoneyBadge = holder
	end

	function skin.Money(value)
		if not moneyLabel then return end
		moneyLabel.Text = ("$%d"):format(value)
		if moneyBefore and value > moneyBefore then
			local gain = Instance.new("TextLabel")
			gain.BackgroundTransparency = 1
			gain.AnchorPoint = Vector2.new(0, 0.5)
			gain.Position = UDim2.new(0, moneyLabel.TextBounds.X + moneyLabel.AbsoluteSize.Y * 1.6, 0.5, 0)
			gain.Size = UDim2.fromScale(0.5, 0.8)
			gain.Font = Enum.Font.FredokaOne
			gain.TextScaled = true
			gain.TextXAlignment = Enum.TextXAlignment.Left
			gain.TextColor3 = GOLD
			gain.TextStrokeColor3 = CHOC
			gain.TextStrokeTransparency = 0
			gain.Text = ("+$%d"):format(value - moneyBefore)
			gain.ZIndex = 5
			gain.Parent = moneyLabel
			tween(gain, 0.9, {
				Position = gain.Position - UDim2.fromScale(0, 0.9),
				TextTransparency = 1, TextStrokeTransparency = 1,
			})
			Debris:AddItem(gain, 1)
			if skin.MoneyBadge then
				MinigameJuice.Bounce(skin.MoneyBadge.Holder)
				skin.MoneyBadge.Flash(GOLD)
			end
		end
		moneyBefore = value
	end

	return skin
end

return HudSkin
