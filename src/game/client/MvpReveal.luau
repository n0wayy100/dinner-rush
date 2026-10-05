--[[
	Dinner Rush - MvpReveal
	StarterPlayer.StarterPlayerScripts.Client.MvpReveal  (ModuleScript)

	THE "ORDER UP!" REVEAL (owner design, Oct 2026). Played by MvpCutscene
	the moment the MVP's dance freezes on its final pose. The MVP is served
	like the dish of the night:

	  0.0s  midnight-teal backdrop, the checkered burst spins up
	  0.3s  the giant plate slides up
	  0.5s  a chrome cloche drops onto it - and jiggles...
	  1.6s  ...then flies off in a puff of steam: the MVP is revealed
	  1.8s  ketchup and mustard squirt across the screen
	  2.3s  the neon sign flickers on with their title
	  2.8s  their order ticket slides along the rail, 3.3s: stamped MVP
	  then  confetti rains, the burst spins, the neon hums - until it fades

	The MVP is the frozen stage rig COPIED into a ViewportFrame, so art can
	sit behind it (a ScreenGui always draws over the 3D world). Background
	only: the character is never animated here.

	Art: Config.MvpCutscene.Reveal.Art + the shop / Staff Room kits
	(Sparkle, PopBurst, GradeStamp) through UIKit. Everything is cosmetic and
	local; a missing piece is simply skipped.

	Usage (MvpCutscene):
		MvpReveal.Play({ Rig = rig, Name = "...", Title = "...", Receipts = {...} })
		-- yields until the card has faded out
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local UIKit = require(ReplicatedStorage.Shared:WaitForChild("UIKit"))

local SfxLocal = nil
pcall(function()
	SfxLocal = require(ReplicatedStorage.Shared:WaitForChild("SfxLocal", 5))
end)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C = UIKit.Colors
local MvpReveal = {}

local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then
		pcall(SfxLocal.Play, name)
	end
end

local function tween(obj, seconds, props, style, dir, repeats, reverses)
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad,
		dir or Enum.EasingDirection.Out, repeats or 0, reverses or false), props)
	t:Play()
	return t
end

--// copy the frozen stage rig into a viewport (parts keep their posed CFrames;
--// a plain ViewportFrame never re-solves joints, so the pose holds)
local function avatarViewport(rig, parent)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Mvp"
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(190, 180, 170)
	viewport.LightColor = Color3.fromRGB(255, 240, 220)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.Parent = parent

	local archivable = {}
	for _, inst in ipairs({ rig, table.unpack(rig:GetDescendants()) }) do
		if not inst.Archivable then
			archivable[inst] = true
			inst.Archivable = true
		end
	end
	local ok, copy = pcall(function() return rig:Clone() end)
	for inst in pairs(archivable) do
		inst.Archivable = false
	end
	if not ok or not copy then
		viewport:Destroy()
		return nil
	end
	for _, inst in ipairs(copy:GetDescendants()) do
		if inst:IsA("LuaSourceContainer") or inst:IsA("Sound") or inst:IsA("Light")
			or inst:IsA("BillboardGui") or inst:IsA("ParticleEmitter") then
			inst:Destroy()
		elseif inst:IsA("BasePart") then
			inst.LocalTransparencyModifier = 0
			if inst.Name == "CameraBone" then inst:Destroy() end
		end
	end
	copy.Parent = viewport

	local root = copy:FindFirstChild("HumanoidRootPart") or copy.PrimaryPart
	local boxCF, boxSize = copy:GetBoundingBox()
	local front = root and root.CFrame.LookVector or boxCF.LookVector
	front = Vector3.new(front.X, 0, front.Z)
	front = front.Magnitude > 0.01 and front.Unit or Vector3.new(0, 0, -1)
	local fov = 32
	local dist = (boxSize.Y * 0.5) / math.tan(math.rad(fov / 2)) * 1.12 + boxSize.Z
	local camera = Instance.new("Camera")
	camera.FieldOfView = fov
	--// a touch to the side and above, like a hero shot
	local side = front:Cross(Vector3.yAxis).Unit
	camera.CFrame = CFrame.lookAt(boxCF.Position + front * dist + side * dist * 0.18
		+ Vector3.new(0, boxSize.Y * 0.08, 0), boxCF.Position)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

--// a left-to-right "squirt": a gradient edge sweeps across the stroke
local function squirt(image, seconds)
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.49, 0),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Offset = Vector2.new(-0.5, 0)
	grad.Parent = image
	tween(grad, seconds, { Offset = Vector2.new(0.5, 0) }, Enum.EasingStyle.Quart)
end

function MvpReveal.Play(options)
	local settings = Config.MvpCutscene and Config.MvpCutscene.Reveal
	if not settings or settings.Enabled == false then return end
	options = options or {}
	local kit = UIKit.artKit(settings.Art or {},
		(Config.PlayerStats and Config.PlayerStats.StaffArt) or {},
		(Config.Monetization and Config.Monetization.ShopArt) or {})

	local gui = Instance.new("ScreenGui")
	gui.Name = "MvpReveal_UI"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 99 --// just under the cutscene's own fade
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local alive = true
	local function image(slot, name, z)
		local img = kit.image(gui, slot, name)
		if img then
			img.AnchorPoint = Vector2.new(0.5, 0.5)
			img.ZIndex = z or 1
		end
		return img
	end

	--// 0. BACKDROP: midnight teal, a white flash wipes it in
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = C.White
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 0
	backdrop.Parent = gui
	local backGrad = Instance.new("UIGradient")
	backGrad.Rotation = 90
	backGrad.Color = ColorSequence.new(settings.BackdropTop or Color3.fromRGB(18, 52, 59),
		settings.BackdropBottom or Color3.fromRGB(8, 26, 31))
	backGrad.Parent = backdrop
	local flash = Instance.new("Frame")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = C.White
	flash.BorderSizePixel = 0
	flash.ZIndex = 40
	flash.Parent = gui
	tween(flash, 0.35, { BackgroundTransparency = 1 })

	local CENTER_X = 0.34 --// the MVP's column; the right side holds sign + ticket

	--// 1. the checkered burst, spinning forever
	local burst = image("MvpCheckerBurst", "Burst", 1)
	if burst then
		burst.Position = UDim2.fromScale(CENTER_X, 0.5)
		burst.Size = UDim2.fromScale(1.5, 1.5)
		UIKit.aspect(burst, 1).DominantAxis = Enum.DominantAxis.Height
		burst.ImageTransparency = 0.15
		local s = Instance.new("UIScale")
		s.Scale = 0.2
		s.Parent = burst
		tween(s, 0.6, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(burst, 24, { Rotation = 360 }, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1)
	end

	--// 2. the plate slides up under the MVP's feet
	local PLATE_HOME = UDim2.fromScale(CENTER_X, 0.86)
	local plate = image("MvpPlate", "Plate", 2)
	if plate then
		plate.Position = PLATE_HOME + UDim2.fromScale(0, 0.6)
		plate.Size = UDim2.fromScale(0.6, 0.6)
		UIKit.aspect(plate, 1).DominantAxis = Enum.DominantAxis.Height
		task.delay(0.3, function()
			if alive then tween(plate, 0.5, { Position = PLATE_HOME }, Enum.EasingStyle.Back) end
		end)
	end

	--// 3. the MVP (frozen pose), hidden under the cloche until the reveal
	local holder = Instance.new("Frame")
	holder.Name = "MvpHolder"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.fromScale(CENTER_X, 0.9)
	holder.Size = UDim2.fromScale(0.62, 0.82)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 3
	holder.Parent = gui
	UIKit.aspect(holder, 0.75).DominantAxis = Enum.DominantAxis.Height
	local holderScale = Instance.new("UIScale")
	holderScale.Parent = holder
	local viewport = options.Rig and avatarViewport(options.Rig, holder)
	if viewport then
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.ZIndex = 3
		viewport.ImageTransparency = 1
	end

	--// 4. the cloche drops on the plate
	local CLOCHE_HOME = UDim2.fromScale(CENTER_X, 0.56)
	local cloche = image("MvpCloche", "Cloche", 5)
	if cloche then
		cloche.Position = CLOCHE_HOME - UDim2.fromScale(0, 1.2)
		cloche.Size = UDim2.fromScale(0.95, 0.66)
		UIKit.aspect(cloche, 1.5).DominantAxis = Enum.DominantAxis.Height
		task.delay(0.5, function()
			if alive then tween(cloche, 0.55, { Position = CLOCHE_HOME }, Enum.EasingStyle.Bounce) end
		end)
	end

	--// the right side: neon sign + ticket rail (built now, animated later)
	local neonOff = image("MvpNeonOff", "NeonOff", 4)
	local neonOn = image("MvpNeonOn", "NeonOn", 5)
	for _, neon in pairs({ Off = neonOff, On = neonOn }) do
		neon.Position = UDim2.fromScale(0.74, 0.24)
		neon.Size = UDim2.fromScale(0.46, 0.2)
		UIKit.aspect(neon, 4).DominantAxis = Enum.DominantAxis.Width
		neon.ImageTransparency = 1
	end
	if neonOn then neonOn.Visible = false end
	local title = UIKit.label(gui, "Title", Enum.Font.FredokaOne, C.White)
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.74, 0.24)
	title.Size = UDim2.fromScale(0.36, 0.1)
	title.Text = string.upper(options.Title or "MVP")
	title.TextStrokeColor3 = settings.NeonColor or Color3.fromRGB(255, 92, 170)
	title.TextStrokeTransparency = 1
	title.TextTransparency = 1
	title.ZIndex = 6

	local RAIL_Y = 0.42
	local rail = image("MvpTicketRail", "Rail", 4)
	if rail then
		rail.Position = UDim2.fromScale(0.74, RAIL_Y)
		rail.Size = UDim2.fromScale(0.5, 0.06)
		UIKit.aspect(rail, 12).DominantAxis = Enum.DominantAxis.Width
		rail.ImageTransparency = 1
	end
	local ticket = Instance.new("Frame")
	ticket.Name = "Ticket"
	ticket.AnchorPoint = Vector2.new(0.5, 0)
	local TICKET_HOME = UDim2.fromScale(0.74, RAIL_Y + 0.015)
	ticket.Position = TICKET_HOME + UDim2.fromScale(0.5, 0)
	ticket.Size = UDim2.fromScale(0.22, 0.48)
	ticket.BackgroundTransparency = 1
	ticket.ZIndex = 4
	ticket.Parent = gui
	UIKit.aspect(ticket, 0.8).DominantAxis = Enum.DominantAxis.Height
	local ticketArt = kit.image(ticket, "MvpOrderTicket", "Art")
	if ticketArt then
		ticketArt.Size = UDim2.fromScale(1, 1)
		ticketArt.ZIndex = 4
	else
		ticket.BackgroundTransparency = 0
		ticket.BackgroundColor3 = C.Cream
	end
	local orderHead = UIKit.label(ticket, "Order", Enum.Font.FredokaOne, C.White, 30)
	orderHead.Position = UDim2.fromScale(0.08, 0.09)
	orderHead.Size = UDim2.fromScale(0.84, 0.1)
	orderHead.Text = "ORDER UP!"
	orderHead.ZIndex = 5
	UIKit.stickerText(orderHead)
	local nameText = UIKit.label(ticket, "Name", Enum.Font.FredokaOne, C.Choc, 40)
	nameText.Position = UDim2.fromScale(0.08, 0.25)
	nameText.Size = UDim2.fromScale(0.84, 0.15)
	nameText.Text = options.Name or player.DisplayName
	nameText.ZIndex = 5
	for i, line in ipairs(options.Receipts or {}) do
		if i > 3 then break end
		local row = UIKit.label(ticket, "Line" .. i, Enum.Font.RobotoMono, Color3.fromRGB(70, 60, 54), 20)
		row.Position = UDim2.fromScale(0.1, 0.44 + (i - 1) * 0.1)
		row.Size = UDim2.fromScale(0.8, 0.08)
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Text = "1x " .. tostring(line)
		row.ZIndex = 5
	end
	local stamp = kit.image(ticket, "GradeStamp", "Stamp")
	local stampScale = Instance.new("UIScale")
	if stamp then
		stamp.AnchorPoint = Vector2.new(0.5, 0.5)
		stamp.Position = UDim2.fromScale(0.66, 0.8)
		stamp.Size = UDim2.fromScale(0.5, 0.4)
		stamp.Rotation = -14
		stamp.ZIndex = 6
		stamp.Visible = false
		UIKit.aspect(stamp, 1)
		local word = UIKit.label(stamp, "Word", Enum.Font.FredokaOne, C.Tomato)
		word.AnchorPoint = Vector2.new(0.5, 0.5)
		word.Position = UDim2.fromScale(0.5, 0.5)
		word.Size = UDim2.fromScale(0.6, 0.36)
		word.Text = "MVP"
		word.ZIndex = 7
		stampScale.Parent = stamp
	end

	--// sauces, laid across the screen on a slant (drawn in by a gradient)
	local ketchup = image("MvpSauceKetchup", "Ketchup", 7)
	local mustard = image("MvpSauceMustard", "Mustard", 7)
	if ketchup then
		ketchup.Position = UDim2.fromScale(0.5, 0.15)
		ketchup.Size = UDim2.fromScale(1.35, 0.17)
		ketchup.Rotation = -9
		ketchup.Visible = false
	end
	if mustard then
		mustard.Position = UDim2.fromScale(0.52, 0.93)
		mustard.Size = UDim2.fromScale(1.35, 0.15)
		mustard.Rotation = -6
		mustard.Visible = false
	end

	--// THE SHOW
	task.spawn(function()
		task.wait(1.1)
		if not alive then return end
		--// the cloche jiggles...
		if cloche then
			for i = 1, 5 do
				tween(cloche, 0.07, { Rotation = (i % 2 == 0) and -6 or 6 }).Completed:Wait()
			end
			tween(cloche, 0.07, { Rotation = 0 }).Completed:Wait()
		end
		if not alive then return end

		--// ...and flies off: steam, a pop, the MVP is served
		sfx("ShopClick")
		if cloche then
			tween(cloche, 0.55, {
				Position = UDim2.fromScale(CENTER_X + 0.5, -0.5),
				Rotation = 40,
				ImageTransparency = 0.2,
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
		for i = 1, 3 do
			local puff = image("MvpSteamPuff", "Steam", 6)
			if puff then
				puff.Position = UDim2.fromScale(CENTER_X + (i - 2) * 0.08, 0.62)
				puff.Size = UDim2.fromScale(0.2, 0.2)
				UIKit.aspect(puff, 1)
				tween(puff, 1.3, {
					Position = UDim2.fromScale(CENTER_X + (i - 2) * 0.18, 0.3 - i * 0.04),
					Size = UDim2.fromScale(0.75, 0.75),
					ImageTransparency = 1,
					Rotation = (i - 2) * 25,
				})
				Debris:AddItem(puff, 1.4)
			end
		end
		local pop = image("PopBurst", "Pop", 2)
		if pop then
			pop.Position = UDim2.fromScale(CENTER_X, 0.5)
			pop.Size = UDim2.fromScale(0.1, 0.1)
			UIKit.aspect(pop, 1)
			tween(pop, 0.6, { Size = UDim2.fromScale(1.1, 1.1), Rotation = 50, ImageTransparency = 1 })
			Debris:AddItem(pop, 0.7)
		end
		if viewport then
			holderScale.Scale = 0.6
			tween(viewport, 0.25, { ImageTransparency = 0 })
			tween(holderScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		for i = 1, 6 do
			local spark = image("Sparkle", "Spark", 6)
			if spark then
				local a = (i / 6) * math.pi * 2
				spark.Position = UDim2.fromScale(CENTER_X, 0.5)
				spark.Size = UDim2.fromScale(0.08, 0.08)
				UIKit.aspect(spark, 1)
				tween(spark, 0.7, {
					Position = UDim2.fromScale(CENTER_X + math.cos(a) * 0.22, 0.5 + math.sin(a) * 0.32),
					ImageTransparency = 1,
				})
				Debris:AddItem(spark, 0.8)
			end
		end

		--// the sauces squirt across
		task.wait(0.2)
		if ketchup and alive then ketchup.Visible = true squirt(ketchup, 0.4) end
		task.wait(0.2)
		if mustard and alive then mustard.Visible = true squirt(mustard, 0.4) end

		--// the neon flickers to life
		task.wait(0.3)
		if not alive then return end
		if neonOff then tween(neonOff, 0.2, { ImageTransparency = 0 }) end
		if rail then tween(rail, 0.3, { ImageTransparency = 0 }) end
		task.wait(0.2)
		local pattern = { 0.06, 0.08, 0.05, 0.14, 0.04, 0.2 }
		for i, gap in ipairs(pattern) do
			if not alive then return end
			local lit = i % 2 == 1
			if neonOn then
				neonOn.Visible = lit
				neonOn.ImageTransparency = 0
			end
			title.TextTransparency = lit and 0 or 0.7
			title.TextStrokeTransparency = lit and 0 or 1
			task.wait(gap)
		end
		if neonOn then neonOn.Visible = true end
		title.TextTransparency = 0
		title.TextStrokeTransparency = 0
		if neonOn then
			tween(neonOn, 0.9, { ImageTransparency = 0.25 }, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut, -1, true)
		end

		--// the order ticket rides the rail in, swings, and gets stamped
		task.wait(0.2)
		if not alive then return end
		tween(ticket, 0.45, { Position = TICKET_HOME }, Enum.EasingStyle.Quint)
		task.wait(0.45)
		ticket.Rotation = 8
		tween(ticket, 0.9, { Rotation = 0 }, Enum.EasingStyle.Elastic)
		task.wait(0.35)
		if stamp and alive then
			stamp.Visible = true
			stampScale.Scale = 2.4
			tween(stampScale, 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
			sfx("ShopPurchase")
		end
	end)

	--// food confetti rains the whole time
	task.spawn(function()
		task.wait(1.6)
		while alive do
			local bit = image("MvpFoodConfetti", "Confetti", 8)
			if bit then
				local x = math.random()
				local size = 0.18 + math.random() * 0.16
				bit.Position = UDim2.fromScale(x, -0.2)
				bit.Size = UDim2.fromScale(size, size)
				UIKit.aspect(bit, 1)
				bit.Rotation = math.random(0, 360)
				bit.ImageTransparency = 0.1
				tween(bit, 2.6 + math.random(), {
					Position = UDim2.fromScale(x + (math.random() - 0.5) * 0.2, 1.25),
					Rotation = bit.Rotation + math.random(-180, 180),
				}, Enum.EasingStyle.Linear)
				Debris:AddItem(bit, 4)
			end
			task.wait(0.45)
		end
	end)

	--// hold, then fade the whole card away (the frozen 3D shot shows again)
	task.wait(settings.Seconds or 7)
	local cover = Instance.new("Frame")
	cover.Size = UDim2.fromScale(1, 1)
	cover.BackgroundColor3 = Color3.new(0, 0, 0)
	cover.BackgroundTransparency = 1
	cover.BorderSizePixel = 0
	cover.ZIndex = 50
	cover.Parent = gui
	tween(cover, 0.4, { BackgroundTransparency = 0 }).Completed:Wait()
	alive = false
	for _, child in ipairs(gui:GetChildren()) do
		if child ~= cover then child:Destroy() end
	end
	tween(cover, 0.4, { BackgroundTransparency = 1 }).Completed:Wait()
	gui:Destroy()
end

return MvpReveal
