--[[
	Dinner Rush - EventClient
	StarterPlayer.StarterPlayerScripts.Client.EventClient  (LocalScript)

	Renders whatever EventSystem publishes to ReplicatedStorage.EventState.
	Same split as the HUD: the server owns the numbers, this only draws them.

	THE ALERT BANNER (Oct 2026 art pass, Config.EventAlert):
	  * drops in from the top with a bounce; the event's icon pops into a
	    badge tinted the event's colour; two sirens sit on the banner with
	    blinking (the light beams were removed - owner call)
	  * the fuse bar hangs under it - a spark fizzes on the burning end
	  * URGENT (fuse at/below UrgentFraction, or flooded/soaked): the banner
	    shakes, the sirens spin faster and the screen edges pulse red
	  * the closing message ("X fixed the toilet!") slams the ALL CLEAR
	    stamp onto the banner, then it slides away
	Nothing here decides anything - every state change is the server's.

	The centre-screen TOAST (EventState.Toast) is unchanged.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(Shared:WaitForChild("UIKit"))

local REFRESH_INTERVAL = 0.1

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local WATER = Color3.fromRGB(120, 170, 200)

local ALERT = Config.EventAlert or { Art = {}, Events = {}, UrgentFraction = 0.25 }
local kit = UIKit.artKit(ALERT.Art)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local EventState = ReplicatedStorage:WaitForChild("EventState", 30)
if not EventState then
	warn("[EventClient] ReplicatedStorage.EventState never appeared - is EventSystem running?")
	return
end

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function sprite(parent, slot, name)
	local image = Instance.new("ImageLabel")
	image.Name = name or slot
	image.BackgroundTransparency = 1
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.ScaleType = Enum.ScaleType.Fit
	image.Image = kit.id(slot) or ""
	image.Parent = parent
	return image
end

----------------------------------------------------------------
-- Built once, hidden
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "EventAlert_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 30 --// above the HUD, below the shift intro
gui.Enabled = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

--// the red danger glow round the screen edges (urgent only)
local edgeGlow = sprite(gui, "Alarm_EdgeGlow")
edgeGlow.ScaleType = Enum.ScaleType.Stretch
edgeGlow.Position = UDim2.fromScale(0.5, 0.5)
edgeGlow.Size = UDim2.fromScale(1, 1)
edgeGlow.ImageTransparency = 1
edgeGlow.ZIndex = 0

local BANNER_Y = 0.165 --// below the shift bar (was 0.13, overlapped OPENING)
local HIDDEN_Y = -0.25

--// the holder moves (drop-in, shake); everything rides on it
local holder = Instance.new("Frame")
holder.Name = "Holder"
holder.BackgroundTransparency = 1
holder.AnchorPoint = Vector2.new(0.5, 0)
holder.Position = UDim2.fromScale(0.5, HIDDEN_Y)
holder.Size = UDim2.fromOffset(600, 126) --// real size set by layoutBanner() from the screen
holder.Parent = gui
local holderScale = Instance.new("UIScale")
holderScale.Parent = holder

local banner = Instance.new("Frame")
banner.Name = "Banner"
banner.Size = UDim2.fromScale(1, 1)
banner.BackgroundColor3 = CREAM
banner.ZIndex = 2
banner.Parent = holder
local bannerStroke = UIKit.stroke(banner, 3, CHOC)
UIKit.corner(banner, UDim.new(0, 12))
local bannerHasArt = kit.skin(banner, "Alert_Banner")

local text = UIKit.label(banner, "Text", Enum.Font.FredokaOne, CHOC)
text.AnchorPoint = Vector2.new(0, 0)
text.ZIndex = 4
local textCap = Instance.new("UITextSizeConstraint") --// short lines stay a sensible size
textCap.MaxTextSize = 28
textCap.MinTextSize = 11
textCap.Parent = text

----------------------------------------------------------------
-- LAYOUT (PC + MOBILE). The banner is sized from the SCREEN: ~46% wide
-- on a monitor, up to ~88% on a phone, capped so it never gets huge.
-- The text is fitted to the art's CREAM WINDOW in pixels - the window
-- sits at these insets inside the 1024x256 art (measured off the PNG),
-- and SliceScale is set so the striped bands stay slim and the window
-- gets the room. Text then TextScales inside the window, so it can
-- never spill onto the stripes.
----------------------------------------------------------------
local wantedSlice = nil --// the SliceScale layoutBanner chose (UIKit's own resize would undo it)
local WINDOW = { Left = 56, Right = 57, Top = 66, Bottom = 85 } --// art px
local BAND_SCALE = 0.62 --// how thick the bands draw vs the art (1 = as drawn)

local function layoutBanner()
	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(1366, 768)
	local width = math.clamp(view.X * 0.46, math.min(view.X * 0.88, 430), 700)
	local height = math.floor(width * 0.21)
	holder.Size = UDim2.fromOffset(math.floor(width), height)

	local s = (height / 256) * BAND_SCALE
	wantedSlice = s
	local art = banner:FindFirstChild("Art")
	if art then
		art.SliceScale = s
	end
	--// the window in screen pixels, then clear of the badge on the left
	local left = bannerHasArt and WINDOW.Left * s or 10
	local right = bannerHasArt and WINDOW.Right * s or 10
	local top = bannerHasArt and WINDOW.Top * s or 8
	local bottom = bannerHasArt and WINDOW.Bottom * s or 8
	local badgeEdge = width * 0.17
	left = math.max(left, badgeEdge) + 6
	local pad = 3
	text.Position = UDim2.fromOffset(left, top + pad)
	text.Size = UDim2.fromOffset(math.max(40, width - left - right - 8),
		math.max(16, height - top - bottom - pad * 2))
	--// phones: a smaller ceiling keeps two lines
	textCap.MaxTextSize = view.Y < 500 and 20 or 28
end

--// keep OUR slice scale: UIKit re-derives it whenever the frame resizes
do
	local art = banner:FindFirstChild("Art")
	if art then
		art:GetPropertyChangedSignal("SliceScale"):Connect(function()
			if wantedSlice and math.abs(art.SliceScale - wantedSlice) > 1e-3 then
				art.SliceScale = wantedSlice
			end
		end)
	end
	layoutBanner()
	local function watchCamera()
		local camera = workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutBanner)
		end
		layoutBanner()
	end
	watchCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
end

--// the event's badge, popped over the banner's left end
local badge = sprite(holder, "Icon_Badge")
badge.Position = UDim2.fromScale(0.08, 0.5)
badge.Size = UDim2.fromScale(0.2, 1.45)
badge.ZIndex = 6
UIKit.aspect(badge, 1)
local badgeFill = Instance.new("Frame") --// a cream disc behind the icon
badgeFill.AnchorPoint = Vector2.new(0.5, 0.5)
badgeFill.Position = UDim2.fromScale(0.5, 0.5)
badgeFill.Size = UDim2.fromScale(0.6, 0.6) --// inside the ring (children draw over the ring art)
badgeFill.BackgroundColor3 = CREAM
badgeFill.ZIndex = 5
badgeFill.Parent = badge
UIKit.corner(badgeFill, UDim.new(1, 0))
local badgeIcon = Instance.new("ImageLabel")
badgeIcon.BackgroundTransparency = 1
badgeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
badgeIcon.Position = UDim2.fromScale(0.5, 0.5)
badgeIcon.Size = UDim2.fromScale(0.62, 0.62)
badgeIcon.ScaleType = Enum.ScaleType.Fit
badgeIcon.ZIndex = 7
badgeIcon.Parent = badge
local badgeScale = Instance.new("UIScale")
badgeScale.Parent = badge

--// two sirens perched on the banner's top edge (no light beams - owner call)
local sirens = {}
for _, x in ipairs({ 0.22, 0.86 }) do
	local siren = sprite(holder, "Alert_Siren")
	siren.AnchorPoint = Vector2.new(0.5, 1)
	siren.Position = UDim2.fromScale(x, 0.12)
	siren.Size = UDim2.fromScale(0.1, 0.62)
	siren.ZIndex = 3
	UIKit.aspect(siren, 1)
	table.insert(sirens, { Siren = siren, Base = siren.Size })
end

--// the fuse bar, hanging under the banner
local fuse = Instance.new("Frame")
fuse.Name = "Fuse"
fuse.AnchorPoint = Vector2.new(0.5, 0)
fuse.Position = UDim2.fromScale(0.55, 0.9)
fuse.Size = UDim2.fromScale(0.74, 0.22)
fuse.BackgroundColor3 = CHOC
fuse.ZIndex = 3
fuse.Parent = holder
UIKit.corner(fuse, UDim.new(1, 0))
local fuseArt = kit.skin(fuse, "Fuse_BarFrame")
if fuseArt then fuse.Art.ZIndex = 4 end
local TRACK_X, TRACK_W, TRACK_H = 0.045, 0.91, 0.42
local fuseFill = Instance.new("Frame")
fuseFill.Name = "Fill"
fuseFill.AnchorPoint = Vector2.new(0, 0.5)
fuseFill.Position = UDim2.fromScale(TRACK_X, 0.5)
fuseFill.Size = UDim2.fromScale(TRACK_W, TRACK_H)
fuseFill.BackgroundColor3 = MUSTARD
fuseFill.ZIndex = 5 --// above the frame art (its track is solid)
fuseFill.Parent = fuse
UIKit.corner(fuseFill, UDim.new(1, 0))
do
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(195, 195, 195))
	grad.Parent = fuseFill
	local shine = Instance.new("Frame")
	shine.AnchorPoint = Vector2.new(0.5, 0)
	shine.Position = UDim2.fromScale(0.5, 0.14)
	shine.Size = UDim2.new(1, -8, 0.24, 0)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.45
	shine.ZIndex = 6
	shine.Parent = fuseFill
	UIKit.corner(shine, UDim.new(1, 0))
end
--// the spark rides the burning end of the fill
local spark = sprite(fuse, "Fuse_Spark")
spark.Size = UDim2.fromScale(0.13, 1.9)
spark.ZIndex = 7
UIKit.aspect(spark, 1)

--// the ALL CLEAR stamp, slammed onto the banner's right side
local stamp = sprite(holder, "Fixed_Stamp")
stamp.Position = UDim2.fromScale(0.9, 0.45)
stamp.Size = UDim2.fromScale(0.2, 1.6)
stamp.ZIndex = 9
stamp.Visible = false
UIKit.aspect(stamp, 1)
local stampScale = Instance.new("UIScale")
stampScale.Parent = stamp

----------------------------------------------------------------
-- Centre-screen toast: the water-trap lesson ("NEVER put water on a
-- grease fire!"). Driven by EventState.Toast; big, tomato, unmissable.
----------------------------------------------------------------
local toastGui = Instance.new("ScreenGui")
toastGui.Name = "EventToast_UI"
toastGui.ResetOnSpawn = false
toastGui.IgnoreGuiInset = true
toastGui.DisplayOrder = 40 --// above the banner - the lesson interrupts
toastGui.Enabled = false
toastGui.Parent = playerGui

local toastFrame = Instance.new("Frame")
toastFrame.AnchorPoint = Vector2.new(0.5, 0.5)
toastFrame.Position = UDim2.fromScale(0.5, 0.35)
toastFrame.Size = UDim2.fromScale(0.52, 0.12)
toastFrame.BackgroundColor3 = TOMATO
toastFrame.Parent = toastGui

local toastCorner = Instance.new("UICorner")
toastCorner.CornerRadius = UDim.new(0, 14)
toastCorner.Parent = toastFrame

local toastStroke = Instance.new("UIStroke")
toastStroke.Thickness = 3
toastStroke.Color = CHOC
toastStroke.Parent = toastFrame

local toastLabel = Instance.new("TextLabel")
toastLabel.AnchorPoint = Vector2.new(0.5, 0.5)
toastLabel.Position = UDim2.fromScale(0.5, 0.5)
toastLabel.Size = UDim2.fromScale(0.92, 0.7)
toastLabel.BackgroundTransparency = 1
toastLabel.Font = Enum.Font.FredokaOne
toastLabel.TextScaled = true
toastLabel.TextWrapped = true
toastLabel.TextColor3 = Color3.new(1, 1, 1)
toastLabel.TextStrokeColor3 = CHOC
toastLabel.TextStrokeTransparency = 0
toastLabel.Text = ""
toastLabel.Parent = toastFrame

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local shown = false       --// banner on screen
local lastEvent = ""      --// the event the banner is about (kept for the closing message)
local mode = "hidden"     --// "alarm" | "closing" | "hidden"
local urgent = false
local fuseLive = false    --// a fuse is burning (spark on)
local stampedFor = nil    --// closing text we already stamped
local hideToken = 0

local function eventInfo(name)
	return ALERT.Events[name] or { Color = MUSTARD }
end

local function showBanner()
	if shown then return end
	shown = true
	hideToken += 1
	gui.Enabled = true
	holder.Position = UDim2.fromScale(0.5, HIDDEN_Y)
	tween(holder, 0.55, { Position = UDim2.fromScale(0.5, BANNER_Y) }, Enum.EasingStyle.Back)
	badgeScale.Scale = 0
	task.delay(0.25, function()
		tween(badgeScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

local function hideBanner()
	if not shown then return end
	shown = false
	hideToken += 1
	local mine = hideToken
	tween(holder, 0.35, { Position = UDim2.fromScale(0.5, HIDDEN_Y) }, Enum.EasingStyle.Quad,
		Enum.EasingDirection.In)
	tween(edgeGlow, 0.3, { ImageTransparency = 1 })
	task.delay(0.4, function()
		if hideToken == mine and not shown then
			gui.Enabled = false
			stamp.Visible = false
		end
	end)
end

local function setEvent(name)
	if name == lastEvent then return end
	lastEvent = name
	local info = eventInfo(name)
	badge.ImageColor3 = info.Color
	badgeIcon.Image = info.Icon or ""
	--// a fresh event mid-banner: pop the badge so the change reads
	if shown then
		badgeScale.Scale = 0.6
		tween(badgeScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

local function slamStamp()
	stamp.Visible = true
	stamp.ImageTransparency = 1
	stamp.Rotation = -30
	stampScale.Scale = 2.6
	tween(stamp, 0.18, { ImageTransparency = 0, Rotation = -12 })
	tween(stampScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
	--// the thump: the whole banner dips when the stamp lands
	task.delay(0.18, function()
		holderScale.Scale = 0.94
		tween(holderScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

----------------------------------------------------------------
-- Render (state, on a throttle)
----------------------------------------------------------------
local function refresh()
	local active = EventState:GetAttribute("ActiveEvent") or ""
	local alert = EventState:GetAttribute("AlertText") or ""
	local phase = EventState:GetAttribute("Phase") or ""

	--// Toast is independent of the banner: it may outlive the event
	local toast = EventState:GetAttribute("Toast") or ""
	toastGui.Enabled = toast ~= ""
	toastLabel.Text = toast

	if alert == "" then
		mode = "hidden"
		urgent, fuseLive = false, false
		stampedFor = nil
		hideBanner()
		return
	end

	text.Text = alert
	showBanner()

	if active ~= "" then
		--// THE ALARM
		mode = "alarm"
		stamp.Visible = false
		stampedFor = nil
		setEvent(active)

		local total = EventState:GetAttribute("FuseTotal") or 0
		local remaining = EventState:GetAttribute("FuseRemaining") or 0
		local overrun = phase == "FLOODED" or phase == "SOAKED"
		if total > 0 and remaining > 0 then
			local fraction = math.clamp(remaining / total, 0, 1)
			fuse.Visible = true
			fuseLive = true
			fuseFill.Visible = true
			fuseFill.Size = UDim2.fromScale(math.max(0.04, TRACK_W * fraction), TRACK_H)
			fuseFill.BackgroundColor3 = fraction <= 0.5 and TOMATO or eventInfo(active).Color
			urgent = fraction <= (ALERT.UrgentFraction or 0.25)
		elseif overrun then
			fuse.Visible = true
			fuseLive = false
			fuseFill.Visible = true
			fuseFill.Size = UDim2.fromScale(TRACK_W, TRACK_H)
			fuseFill.BackgroundColor3 = WATER
			urgent = true
		else
			--// no fuse (the power outage): banner + sirens only
			fuse.Visible = false
			fuseLive = false
			urgent = false
		end
		text.TextColor3 = CHOC
	else
		--// THE CLOSING MESSAGE ("X fixed the toilet!" / an inspection verdict)
		mode = "closing"
		urgent, fuseLive = false, false
		fuse.Visible = false
		local failed = alert:upper():find("FAILED") or alert:upper():find("WARNING")
			or alert:upper():find("TOO LATE")
		text.TextColor3 = failed and TOMATO or CHOC
		if not failed and stampedFor ~= alert then
			stampedFor = alert
			slamStamp()
		end
	end
end

refresh()

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < REFRESH_INTERVAL then return end
	since = 0
	refresh()
end)

----------------------------------------------------------------
-- Motion (every frame, only while the banner is up)
----------------------------------------------------------------
local clock = 0
RunService.RenderStepped:Connect(function(dt)
	if not gui.Enabled then return end
	clock += dt

	local alarm = mode == "alarm"
	--// sirens: pulse and blink, faster when urgent; dark when closing
	for index, s in ipairs(sirens) do
		local pulse = 1 + math.sin(clock * (urgent and 18 or 9) + index) * 0.06
		s.Siren.Size = UDim2.fromScale(s.Base.X.Scale * pulse, s.Base.Y.Scale * pulse)
		s.Siren.ImageColor3 = (alarm and math.sin(clock * (urgent and 16 or 8)) > 0)
			and Color3.new(1, 1, 1) or Color3.fromRGB(200, 190, 185)
	end

	--// the badge bobs and wobbles like a sticker
	badge.Rotation = math.sin(clock * 2.4) * (urgent and 10 or 5)

	--// the spark fizzes at the burning end of the fuse
	spark.Visible = fuse.Visible and fuseLive
	if spark.Visible then
		local endX = TRACK_X + fuseFill.Size.X.Scale
		spark.Position = UDim2.fromScale(endX, 0.5)
		spark.Rotation = (spark.Rotation + dt * 540) % 360
		local flicker = 1 + math.random() * 0.25
		spark.Size = UDim2.fromScale(0.13 * flicker, 1.9 * flicker)
	end

	--// URGENT: shake the banner, pulse the screen edges
	if urgent and alarm then
		local amount = 3
		holder.Position = UDim2.new(0.5, math.random(-amount, amount), BANNER_Y,
			math.random(-amount, amount))
		edgeGlow.ImageTransparency = 0.35 + (math.sin(clock * 7) * 0.5 + 0.5) * 0.45
		bannerStroke.Color = math.sin(clock * 8) > 0 and TOMATO or CHOC
	elseif shown then
		if holder.Position.X.Offset ~= 0 or holder.Position.Y.Offset ~= 0 then
			holder.Position = UDim2.fromScale(0.5, BANNER_Y)
		end
		if edgeGlow.ImageTransparency < 1 then
			edgeGlow.ImageTransparency = math.min(1, edgeGlow.ImageTransparency + dt * 2)
		end
		bannerStroke.Color = CHOC
	end
end)
