--[[
	Dinner Rush - DailyClient (lobby)
	StarterPlayer.StarterPlayerScripts.Client.DailyClient  (LocalScript)

	THE DAILY MISSIONS board (Oct 2026, Config.Daily). Opens from the
	owner's CODES! dock button (OpenCodesButton, becoming DAILY!).

	  top     DAILY MISSIONS, the streak flame, the reset clock
	  middle  three pinned mission tickets: tier badge, text, progress bar,
	          the coin reward and CLAIM (or the check stamp once claimed)
	  bottom  the bonus chest: finish all three -> a FREE CRATE (shown as the crate)

	Render only: every claim goes through DailyRemote and ProfileAPI.
	Effects: tickets pin in one by one, a ready CLAIM pulses, claiming slams
	the check stamp and pops coins, the bonus chest wobbles when ready and
	bursts open (rays, coins, the key flying out, confetti).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UIKit = require(Shared:WaitForChild("UIKit"))
local DAILY = Config.Daily
if not DAILY then return end

local SfxLocal = nil
pcall(function() SfxLocal = require(Shared:WaitForChild("SfxLocal", 5)) end)

local C = UIKit.Colors
local kit = UIKit.artKit(DAILY.Art, Config.Passives and Config.Passives.Art,
	Config.Monetization and Config.Monetization.ShopArt)
local corner, stroke, label, stickerText, aspect = UIKit.corner, UIKit.stroke,
	UIKit.label, UIKit.stickerText, UIKit.aspect

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DailyRemote", 30)
if not remote then
	warn("[Daily] DailyRemote missing - is DailyServer synced?")
	return
end

local TIER_COLOR = { Easy = C.Basil, Medium = C.Mustard, Hard = C.Tomato }

local function sfx(name)
	local sounds = Config.Sfx and Config.Sfx.Sounds
	local entry = sounds and sounds[name]
	if SfxLocal and entry and entry.Id ~= "" then pcall(SfxLocal.Play, name) end
end

local function tween(obj, seconds, props, style, direction)
	local t = TweenService:Create(obj, TweenInfo.new(seconds,
		style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function sprite(parent, slot, name)
	local img = Instance.new("ImageLabel")
	img.Name = name or slot
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Image = kit.id(slot) or ""
	img.Parent = parent
	return img
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	return ("%d:%02d:%02d"):format(seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

----------------------------------------------------------------
-- The board
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "Daily_UI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 36
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local blur = Instance.new("BlurEffect")
blur.Name = "DailyBlur"
blur.Size = 0
blur.Enabled = false
blur.Parent = Lighting

local backdrop = Instance.new("TextButton")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 1
backdrop.AutoButtonColor = false
backdrop.Text = ""
backdrop.Parent = gui

local root = Instance.new("Frame")
root.Name = "MainPanel"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.5, 0.53)
root.Size = UDim2.fromScale(0.62, 0.8)
root.BackgroundTransparency = 1
root.Parent = gui
aspect(root, 1.3)
local rootScale = Instance.new("UIScale")
rootScale.Parent = root

local board = Instance.new("Frame")
board.Size = UDim2.fromScale(1, 1)
board.BackgroundColor3 = C.Cream
board.Parent = root
corner(board, UDim.new(0, 22))
stroke(board, 7, C.Wood)
kit.skin(board, "Daily_Panel")

local title = Instance.new("Frame")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.035)
title.Size = UDim2.fromScale(0.5, 0.11)
title.BackgroundColor3 = Color3.fromRGB(74, 144, 226)
title.ZIndex = 5
title.Parent = root
corner(title, UDim.new(0.4, 0))
stroke(title, 4, C.Choc)
local titleText = label(title, "Text")
titleText.AnchorPoint = Vector2.new(0.5, 0.5)
titleText.Position = UDim2.fromScale(0.5, 0.5)
titleText.Size = UDim2.fromScale(0.9, 0.72)
titleText.Text = "DAILY MISSIONS"
titleText.ZIndex = 6
stickerText(titleText)

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.AnchorPoint = Vector2.new(0.5, 0.5)
closeButton.Position = UDim2.fromScale(0.965, 0.05)
closeButton.Size = UDim2.fromScale(0.08, 0.08)
closeButton.BackgroundColor3 = C.Tomato
closeButton.Font = Enum.Font.FredokaOne
closeButton.TextScaled = true
closeButton.Text = "X"
closeButton.ZIndex = 8
stickerText(closeButton)
closeButton.Parent = root
aspect(closeButton, 1)
corner(closeButton, UDim.new(1, 0))
stroke(closeButton, 3, C.Choc)
if kit.skin(closeButton, "CloseButton") then closeButton.Text = "" end
UIKit.bouncy(closeButton)

--// streak (left) and reset clock (right), under the title
local streakFlame = sprite(root, "Streak_Flame")
--// the flame FLICKERS from its 4x4 flipbook when there is one
local flameSheet = kit.id("Flame_Sheet")
if flameSheet then
	streakFlame.Image = flameSheet
	streakFlame.ImageRectSize = Vector2.new(256, 256)
end
streakFlame.Position = UDim2.fromScale(0.45, 0.16) -- re-placed after the text each frame
streakFlame.Size = UDim2.fromScale(0.09, 0.12)
streakFlame.ZIndex = 4
aspect(streakFlame, 1)
local streakText = label(root, "Streak", nil, C.Choc, 26)
streakText.AnchorPoint = Vector2.new(0, 0.5)
streakText.Position = UDim2.fromScale(0.17, 0.165) -- clear of the board's corner pin
streakText.Size = UDim2.fromScale(0.3, 0.05)
streakText.TextXAlignment = Enum.TextXAlignment.Left
streakText.ZIndex = 4

local clock = sprite(root, "Calendar_Clock")
clock.Position = UDim2.fromScale(0.6, 0.165)
clock.Size = UDim2.fromScale(0.06, 0.08)
clock.ZIndex = 4
aspect(clock, 1)
local resetText = label(root, "Reset", nil, C.Choc, 24)
resetText.AnchorPoint = Vector2.new(0, 0.5)
resetText.Position = UDim2.fromScale(0.64, 0.165)
resetText.Size = UDim2.fromScale(0.3, 0.05)
resetText.TextXAlignment = Enum.TextXAlignment.Left
resetText.ZIndex = 4

local notice = label(root, "Notice", nil, C.Tomato, 24)
notice.AnchorPoint = Vector2.new(0.5, 0.5)
notice.Position = UDim2.fromScale(0.5, 1.035)
notice.Size = UDim2.fromScale(0.7, 0.04)
notice.TextStrokeColor3 = C.Cream
notice.TextStrokeTransparency = 0
notice.ZIndex = 9
local noticeToken = 0
local function flashNotice(text, color)
	noticeToken += 1
	local mine = noticeToken
	notice.Text = text
	notice.TextColor3 = color or C.Tomato
	notice.TextTransparency = 0
	task.delay(2.5, function()
		if noticeToken == mine then tween(notice, 0.4, { TextTransparency = 1 }) end
	end)
end

local cardHolder = Instance.new("Frame")
cardHolder.BackgroundTransparency = 1
cardHolder.Position = UDim2.fromScale(0.07, 0.215)
cardHolder.Size = UDim2.fromScale(0.86, 0.5)
cardHolder.ClipsDescendants = true --// sliding tickets stay inside the board
cardHolder.Parent = root

--// the bonus row
local bonusRow = Instance.new("Frame")
bonusRow.BackgroundTransparency = 1
bonusRow.Position = UDim2.fromScale(0.09, 0.73)
bonusRow.Size = UDim2.fromScale(0.82, 0.155)
bonusRow.Parent = root
local chest = Instance.new("ImageButton")
chest.Name = "Chest"
chest.BackgroundTransparency = 1
chest.AnchorPoint = Vector2.new(0.5, 0.5)
chest.Position = UDim2.fromScale(0.09, 0.5)
chest.Size = UDim2.fromScale(0.16, 0.95)
chest.ScaleType = Enum.ScaleType.Fit
chest.Image = kit.id("Reward_Chest_Closed") or ""
chest.AutoButtonColor = false
chest.ZIndex = 4
chest.Parent = bonusRow
aspect(chest, 1)
local chestScale = Instance.new("UIScale")
chestScale.Parent = chest
local chestGlow = sprite(bonusRow, "Glow_Orb")
chestGlow.Position = chest.Position
chestGlow.Size = UDim2.fromScale(0.24, 1.4)
chestGlow.ImageColor3 = C.Mustard
chestGlow.ImageTransparency = 1
chestGlow.ZIndex = 3
aspect(chestGlow, 1)
local bonusText = label(bonusRow, "BonusText", nil, C.Choc, 28)
bonusText.AnchorPoint = Vector2.new(0, 0.5)
bonusText.Position = UDim2.fromScale(0.2, 0.3)
bonusText.Size = UDim2.fromScale(0.78, 0.4)
bonusText.TextXAlignment = Enum.TextXAlignment.Left
bonusText.ZIndex = 4
local bonusSub = label(bonusRow, "BonusSub", Enum.Font.GothamBold, C.Choc, 20)
bonusSub.AnchorPoint = Vector2.new(0, 0.5)
bonusSub.Position = UDim2.fromScale(0.2, 0.74)
bonusSub.Size = UDim2.fromScale(0.16, 0.34)
bonusSub.TextXAlignment = Enum.TextXAlignment.Left
bonusSub.ZIndex = 4
local bonusKey = sprite(bonusRow, "Crate_Closed")
bonusKey.Position = UDim2.fromScale(0.42, 0.72) -- the reward IS the crate picture
bonusKey.Size = UDim2.fromScale(0.1, 0.5)
bonusKey.ZIndex = 4
aspect(bonusKey, 1)

----------------------------------------------------------------
-- State + rendering
----------------------------------------------------------------
local state = nil
local isOpen = false
local busy = false
local cards = {}
local resetAt = 0

local function fetch()
	local ok, result = pcall(function() return remote:InvokeServer("State") end)
	if ok and type(result) == "table" then
		state = result
		resetAt = os.clock() + (result.ResetIn or 0)
	end
	return state
end

local function coinPop(parent, at, amount)
	for i = 1, 6 do
		local coin = sprite(parent, "FlyingCoin")
		coin.Position = at
		coin.Size = UDim2.fromScale(0.05, 0.3)
		coin.ZIndex = 12
		aspect(coin, 1)
		local dx, dy = (math.random() - 0.5) * 0.3, -0.6 - math.random() * 0.6
		tween(coin, 0.5, { Position = at + UDim2.fromScale(dx, dy), Rotation = math.random(-180, 180) })
		task.delay(0.35 + i * 0.02, function()
			tween(coin, 0.3, { ImageTransparency = 1 })
			task.delay(0.32, function() coin:Destroy() end)
		end)
	end
	local plus = label(parent, "Plus", nil, C.Mustard, 40)
	plus.AnchorPoint = Vector2.new(0.5, 0.5)
	plus.Position = at
	plus.Size = UDim2.fromScale(0.3, 0.5)
	plus.Text = ("+%d"):format(amount)
	plus.TextStrokeColor3 = C.Choc
	plus.TextStrokeTransparency = 0
	plus.ZIndex = 13
	tween(plus, 0.8, { Position = at + UDim2.fromScale(0, -0.7), TextTransparency = 1, TextStrokeTransparency = 1 })
	task.delay(0.82, function() plus:Destroy() end)
end

local claim -- set below

local function buildCard(mission, index)
	local card = Instance.new("Frame")
	card.Name = "Mission" .. index
	card.BackgroundColor3 = C.Warm
	card.Position = UDim2.fromScale(0, (index - 1) * 0.345)
	card.Size = UDim2.fromScale(1, 0.315)
	card.Parent = cardHolder
	corner(card, UDim.new(0, 12))
	stroke(card, 3, C.Choc)
	kit.skin(card, mission.Claimed and "Mission_Card_Done" or "Mission_Card")
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card

	local badge = sprite(card, "Tier_" .. mission.Tier)
	badge.Position = UDim2.fromScale(0.08, 0.52)
	badge.Size = UDim2.fromScale(0.12, 0.72)
	badge.ZIndex = 3
	aspect(badge, 1)

	local text = label(card, "Text", nil, C.Choc, 28)
	text.Position = UDim2.fromScale(0.16, 0.16)
	text.Size = UDim2.fromScale(0.52, 0.32)
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Text = mission.Text
	text.ZIndex = 3

	--// progress bar (code-drawn fill over the track art)
	local track = Instance.new("Frame")
	track.BackgroundColor3 = C.Choc
	track.Position = UDim2.fromScale(0.16, 0.56)
	track.Size = UDim2.fromScale(0.52, 0.3)
	track.ZIndex = 3
	track.Parent = card
	corner(track, UDim.new(1, 0))
	local trackArt = sprite(track, "Progress_Track")
	trackArt.ScaleType = Enum.ScaleType.Stretch
	trackArt.Position = UDim2.fromScale(0.5, 0.5)
	trackArt.Size = UDim2.fromScale(1, 1)
	trackArt.ZIndex = 4
	if trackArt.Image ~= "" then track.BackgroundTransparency = 1 end
	local fraction = math.clamp(mission.Progress / math.max(1, mission.Goal), 0, 1)
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0.035, 0.5)
	fill.Size = UDim2.fromScale(0, 0.46)
	fill.BackgroundColor3 = TIER_COLOR[mission.Tier] or C.Basil
	fill.ZIndex = 5
	fill.Parent = track
	corner(fill, UDim.new(1, 0))
	fill.Visible = fraction > 0
	tween(fill, 0.6, { Size = UDim2.fromScale(math.max(0.05, 0.93 * fraction), 0.46) })
	local count = label(track, "Count", nil, C.White, 22)
	count.AnchorPoint = Vector2.new(0.5, 0.5)
	count.Position = UDim2.fromScale(0.5, 0.5)
	count.Size = UDim2.fromScale(0.7, 0.92)
	count.Text = ("%d / %d"):format(mission.Progress, mission.Goal)
	count.ZIndex = 6
	stickerText(count)

	--// right side: reward + claim / stamp
	local done = mission.Progress >= mission.Goal
	local reward = label(card, "Reward", nil, C.Choc, 26)
	reward.AnchorPoint = Vector2.new(0.5, 0.5)
	reward.Position = UDim2.fromScale(0.84, 0.28)
	reward.Size = UDim2.fromScale(0.22, 0.3)
	reward.Text = ("%d"):format(mission.Reward)
	reward.ZIndex = 3
	local coinIcon = sprite(card, "FlyingCoin")
	coinIcon.Position = UDim2.fromScale(0.74, 0.28)
	coinIcon.Size = UDim2.fromScale(0.06, 0.34)
	coinIcon.ZIndex = 3
	aspect(coinIcon, 1)

	if mission.Claimed then
		local stamp = sprite(card, "Check_Stamp")
		stamp.Position = UDim2.fromScale(0.84, 0.62)
		stamp.Size = UDim2.fromScale(0.13, 0.75)
		stamp.Rotation = -12
		stamp.ZIndex = 6
		aspect(stamp, 1)
	else
		local button = Instance.new("TextButton")
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.fromScale(0.84, 0.66)
		button.Size = UDim2.fromScale(0.24, 0.4)
		button.BackgroundColor3 = done and C.Basil or Color3.fromRGB(170, 160, 150)
		button.Text = ""
		button.AutoButtonColor = false
		button.ZIndex = 4
		button.Parent = card
		corner(button, UDim.new(0.3, 0))
		stroke(button, 3, C.Choc)
		if done then kit.skin(button, "Claim_Button") end
		local bText = label(button, "Text")
		bText.AnchorPoint = Vector2.new(0.5, 0.5)
		bText.Position = UDim2.fromScale(0.5, 0.46)
		bText.Size = UDim2.fromScale(0.8, 0.6)
		bText.Text = done and "CLAIM!" or "NOT YET"
		bText.ZIndex = 6
		stickerText(bText)
		UIKit.bouncy(button)
		button.Activated:Connect(function()
			if done then claim(mission.Index, card) else flashNotice("Finish it in a shift first!") end
		end)
		if done then
			--// a ready claim breathes
			task.spawn(function()
				local scale = button:FindFirstChildOfClass("UIScale")
				while button.Parent and scale do
					tween(scale, 0.45, { Scale = 1.08 }, Enum.EasingStyle.Sine)
					task.wait(0.45)
					if not button.Parent then break end
					tween(scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Sine)
					task.wait(0.45)
				end
			end)
		end
	end
	return card, cardScale
end

local function renderBonus()
	local claimedCount = 0
	for _, m in ipairs(state.Missions) do if m.Claimed then claimedCount += 1 end end
	local ready = state.AllClaimed and not state.BonusClaimed
	chest.Image = kit.id(state.BonusClaimed and "Reward_Chest_Open" or "Reward_Chest_Closed") or ""
	if state.BonusClaimed then
		bonusText.Text = "BONUS CLAIMED! See you tomorrow"
		bonusSub.Text = "COLLECTED"
	elseif ready then
		bonusText.Text = "TAP THE CHEST!"
		bonusSub.Text = "READY!"
	else
		bonusText.Text = ("Finish all 3 missions (%d/3)"):format(claimedCount)
		bonusSub.Text = "REWARD:"
	end
	bonusKey.ImageTransparency = state.BonusClaimed and 0.5 or 0
	chestGlow.ImageTransparency = ready and 0.3 or 1
end

local function render(animateIn)
	for _, c in ipairs(cards) do c:Destroy() end
	cards = {}
	if not state then return end
	for index, mission in ipairs(state.Missions) do
		local card, scale = buildCard(mission, index)
		table.insert(cards, card)
		if animateIn then
			--// tickets SLIDE in from the side, one after another (scaling a
			--// 9-sliced card from zero made its art jitter)
			local home = card.Position
			card.Position = home + UDim2.fromScale(1.2, 0)
			task.delay((index - 1) * 0.08, function()
				tween(card, 0.4, { Position = home }, Enum.EasingStyle.Back)
			end)
		end
		local _ = scale
	end
	streakText.Text = state.Streak > 0 and ("%d DAY STREAK!"):format(state.Streak) or "Start a streak!"
	streakFlame.ImageTransparency = 0 --// always bright: it invites a streak too
	renderBonus()
end

claim = function(index, card)
	if busy then return end
	busy = true
	local ok, success, result = pcall(function() return remote:InvokeServer("Claim", index) end)
	busy = false
	if not ok or not success then
		flashNotice(type(result) == "string" and result or "Try again!")
		return
	end
	sfx("ShopPurchase")
	--// the stamp slams onto the ticket, coins pop
	local stamp = sprite(card, "Check_Stamp")
	stamp.Position = UDim2.fromScale(0.84, 0.62)
	stamp.Size = UDim2.fromScale(0.13, 0.75)
	stamp.ZIndex = 9
	aspect(stamp, 1)
	local s = Instance.new("UIScale")
	s.Scale = 2.6
	s.Parent = stamp
	stamp.Rotation = -35
	tween(s, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(stamp, 0.2, { Rotation = -12 })
	coinPop(root, UDim2.fromScale(0.86, 0.2 + (index - 1) * 0.19), result.Coins or 0)
	task.delay(0.6, function()
		fetch()
		render(false)
	end)
end

local function openBonus()
	if busy or not state or not (state.AllClaimed and not state.BonusClaimed) then
		if state and not state.AllClaimed then flashNotice("Claim all 3 missions first!") end
		return
	end
	busy = true
	local ok, success, result = pcall(function() return remote:InvokeServer("Bonus") end)
	busy = false
	if not ok or not success then
		flashNotice(type(result) == "string" and result or "Try again!")
		return
	end
	sfx("UltimateReady")
	--// shake, then BURST open: rays, the key flies out, confetti
	for _ = 1, 6 do
		chest.Rotation = math.random(-12, 12)
		task.wait(0.05)
	end
	chest.Rotation = 0
	chest.Image = kit.id("Reward_Chest_Open") or ""
	chestScale.Scale = 1.3
	tween(chestScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	local rays = sprite(bonusRow, "Burst_Rays")
	rays.Position = chest.Position
	rays.Size = UDim2.fromScale(0.2, 1)
	rays.ImageColor3 = C.Mustard
	rays.ZIndex = 2
	aspect(rays, 1)
	tween(rays, 0.5, { Size = UDim2.fromScale(0.5, 3), ImageTransparency = 1 })
	task.delay(0.55, function() rays:Destroy() end)
	local key = sprite(root, "Crate_Closed")
	key.Position = UDim2.fromScale(0.13, 0.85)
	key.Size = UDim2.fromScale(0.08, 0.1)
	key.ZIndex = 14
	aspect(key, 1)
	tween(key, 0.6, { Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(0.22, 0.28), Rotation = 360 },
		Enum.EasingStyle.Back)
	task.delay(1.4, function()
		tween(key, 0.4, { Position = UDim2.fromScale(0.93, 0.82), Size = UDim2.fromScale(0.06, 0.08), ImageTransparency = 0.2 })
		task.delay(0.42, function() key:Destroy() end)
	end)
	local palette = { C.Mustard, C.Tomato, C.Basil, C.Cream }
	local confettiId = kit.id("FX_Confetti_Sheet")
	if confettiId then
		for _ = 1, 30 do
			local piece = Instance.new("ImageLabel")
			piece.BackgroundTransparency = 1
			piece.Image = confettiId
			piece.ImageRectSize = Vector2.new(256, 256)
			local cell = math.random(0, 7)
			piece.ImageRectOffset = Vector2.new((cell % 4) * 256, (cell // 4) * 256)
			piece.ImageColor3 = palette[math.random(#palette)]
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Size = UDim2.fromOffset(28, 28)
			piece.Position = UDim2.fromScale(math.random(), -0.05)
			piece.ZIndex = 15
			piece.Parent = gui
			local secs = math.random(18, 30) / 10
			tween(piece, secs, { Position = UDim2.fromScale(piece.Position.X.Scale, 1.1), Rotation = math.random(-400, 400) },
				Enum.EasingStyle.Sine, Enum.EasingDirection.In)
			task.delay(secs, function() piece:Destroy() end)
		end
	end
	flashNotice(("+%d FREE crate! %s"):format(result.Keys or 1,
		(result.Coins or 0) > 0 and ("+%d streak coins"):format(result.Coins) or ""), C.Basil)
	task.delay(1.9, function()
		fetch()
		render(false)
	end)
end
chest.Activated:Connect(openBonus)

----------------------------------------------------------------
-- Open / close + idle life
----------------------------------------------------------------
local idleToken = 0
local function setOpen(open)
	isOpen = open
	if open then
		gui.Enabled = true
		blur.Enabled = true
		tween(blur, 0.3, { Size = 14 })
		tween(backdrop, 0.3, { BackgroundTransparency = 0.45 })
		rootScale.Scale = 0.85
		tween(rootScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		fetch()
		render(true)
		idleToken += 1
		local mine = idleToken
		task.spawn(function()
			local t = 0
			while idleToken == mine and isOpen do
				local dt = RunService.RenderStepped:Wait()
				t += dt
				resetText.Text = "New in " .. formatTime(resetAt - os.clock())
				clock.Rotation = math.sin(t * 6) * 6
				if flameSheet then
					local frame = math.floor(t * 14) % 16
					streakFlame.ImageRectOffset = Vector2.new((frame % 4) * 256, (frame // 4) * 256)
				end
				--// the flame sits just RIGHT of the sentence, and bobs
				local rootPos, rootSize = root.AbsolutePosition, root.AbsoluteSize
				if rootSize.X > 0 then
					local textEnd = streakText.AbsolutePosition.X + streakText.TextBounds.X
					local x = (textEnd - rootPos.X) / rootSize.X + 0.045
					local pulse = 1 + math.sin(t * 9) * 0.08
					streakFlame.Position = UDim2.fromScale(x, 0.16 + math.sin(t * 4) * 0.004)
					streakFlame.Size = UDim2.fromScale(0.09 * pulse, 0.12 * pulse)
				end
				if state and state.AllClaimed and not state.BonusClaimed then
					chest.Rotation = math.sin(t * 10) * 5
					chestScale.Scale = 1 + math.sin(t * 5) * 0.05
				end
				bonusKey.Rotation = math.sin(t * 2) * 8
			end
		end)
	else
		idleToken += 1
		tween(blur, 0.2, { Size = 0 })
		tween(backdrop, 0.2, { BackgroundTransparency = 1 })
		task.delay(0.2, function()
			if not isOpen then
				gui.Enabled = false
				blur.Enabled = false
			end
		end)
	end
end

closeButton.Activated:Connect(function() setOpen(false) end)
backdrop.Activated:Connect(function() setOpen(false) end)
----------------------------------------------------------------
-- Opener: the owner's CODES! dock button (OpenCodesButton - its art is
-- becoming DAILY!). OpenDailyButton works too, if the button is renamed.
-- Codes themselves moved into the FREE! screen (GiftClient).
----------------------------------------------------------------
local OPENER_NAMES = { OpenCodesButton = true, OpenDailyButton = true }
local bound = {}
local function bindOpenButton(inst)
	if not OPENER_NAMES[inst.Name] or not inst:IsA("GuiButton") or bound[inst] then return end
	bound[inst] = true
	inst.Activated:Connect(function() sfx("ShopClick") setOpen(not isOpen) end)
end
for _, inst in ipairs(playerGui:GetDescendants()) do bindOpenButton(inst) end
playerGui.DescendantAdded:Connect(bindOpenButton)

print("[Daily] board ready")
