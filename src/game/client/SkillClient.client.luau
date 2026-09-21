--[[
	Dinner Rush - SkillClient
	StarterPlayer.StarterPlayerScripts.Client.SkillClient  (LocalScript)

	The two CLASS SKILL buttons (Q + R), bottom-centre. Each shows the
	class's skill for that slot with a cooldown sweep. Render + intent only:
	the SERVER (SkillService) runs and gates every skill.

	  keys      Q / R           touch: tap the button
	  gamepad   B (Q) / DPadUp (R)

	Rebuilds whenever the player's ClassKey changes (class applies late).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SKILLS = Config.Skills
if not (SKILLS and SKILLS.Enabled) then
	return
end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local skillRemote = remotes:WaitForChild("SkillRemote")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CREAM = Color3.fromRGB(255, 246, 233)
local CHOC = Color3.fromRGB(59, 43, 32)
local TOMATO = Color3.fromRGB(229, 72, 77)
local MUSTARD = Color3.fromRGB(245, 184, 65)
local BASIL = Color3.fromRGB(76, 175, 109)
local WHITE = Color3.fromRGB(255, 255, 255)

local gui = Instance.new("ScreenGui")
gui.Name = "Skills_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 18
gui.Parent = playerGui

local BUTTON_PX = 84 --// bigger than before

local row = Instance.new("Frame")
row.AnchorPoint = Vector2.new(0, 1)
row.Size = UDim2.fromOffset(BUTTON_PX, BUTTON_PX * 2 + 12)
row.BackgroundTransparency = 1
row.Visible = false
row.Parent = gui
local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Vertical --// stacked column
rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
rowLayout.Padding = UDim.new(0, 12)
rowLayout.Parent = row

--// Sit the column just ABOVE the ultimate circle (bottom-left), matching
--// how ChargeClient places the ult on touch vs desktop.
local function applyLayout()
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	row.Position = touchOnly and UDim2.fromScale(0.02, 0.52)
		or UDim2.fromScale(0.03, 0.79)
end
applyLayout()
UserInputService.LastInputTypeChanged:Connect(applyLayout)

--// slot -> widget { Button, Cover, Count, Def, ReadyAt }
local widgets = {}

local function classSkill(slot)
	local classKey = player:GetAttribute("ClassKey") or ""
	local class = classKey ~= "" and Config.Classes[classKey] or nil
	if not class then return nil end
	return class[slot == "Q" and "SkillQ" or "SkillR"]
end

local function useSlot(slot)
	local w = widgets[slot]
	if not w then return end
	if os.clock() < (w.ReadyAt or 0) then return end --// cooling; ignore
	skillRemote:FireServer("Use", slot)
end

local function hasIcon(id)
	return type(id) == "string" and id ~= "" and not id:match("//0$")
end

local function makeButton(slot, def, order)
	local button = Instance.new("TextButton")
	button.Name = "Skill" .. slot
	button.LayoutOrder = order
	button.Size = UDim2.fromOffset(BUTTON_PX, BUTTON_PX)
	button.BackgroundColor3 = CREAM
	button.AutoButtonColor = false
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	--// the uploaded art when it exists, the emoji until then
	button.Text = hasIcon(def.IconId) and "" or (def.Emoji or "?")
	button.TextColor3 = CHOC
	button.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.28, 0)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CHOC
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 30
	cap.Parent = button

	if hasIcon(def.IconId) then
		local icon = Instance.new("ImageLabel")
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.78, 0.78)
		icon.BackgroundTransparency = 1
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = def.IconId
		icon.Parent = button
	end

	--// key hint bottom-right
	local key = Instance.new("TextLabel")
	key.AnchorPoint = Vector2.new(1, 1)
	key.Position = UDim2.fromScale(0.98, 0.98)
	key.Size = UDim2.fromScale(0.42, 0.34)
	key.BackgroundColor3 = CHOC
	key.Font = Enum.Font.FredokaOne
	key.TextScaled = true
	key.Text = slot
	key.TextColor3 = WHITE
	key.ZIndex = 3
	key.Parent = button
	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(0.3, 0)
	keyCorner.Parent = key

	--// cooldown cover (drains top-down) + countdown number
	local cover = Instance.new("Frame")
	cover.AnchorPoint = Vector2.new(0.5, 0)
	cover.Position = UDim2.fromScale(0.5, 0)
	cover.Size = UDim2.fromScale(1, 0)
	cover.BackgroundColor3 = Color3.new(0, 0, 0)
	cover.BackgroundTransparency = 0.5
	cover.ZIndex = 2
	cover.Visible = false
	cover.Parent = button
	local coverCorner = Instance.new("UICorner")
	coverCorner.CornerRadius = UDim.new(0.28, 0)
	coverCorner.Parent = cover

	local count = Instance.new("TextLabel")
	count.Size = UDim2.fromScale(1, 1)
	count.BackgroundTransparency = 1
	count.Font = Enum.Font.FredokaOne
	count.TextScaled = true
	count.Text = ""
	count.TextColor3 = WHITE
	count.TextStrokeColor3 = CHOC
	count.TextStrokeTransparency = 0
	count.ZIndex = 3
	count.Visible = false
	count.Parent = button
	local countCap = Instance.new("UITextSizeConstraint")
	countCap.MaxTextSize = 26
	countCap.Parent = count

	button.Activated:Connect(function() useSlot(slot) end)

	return { Button = button, Cover = cover, Count = count, Def = def, ReadyAt = 0 }
end

local function rebuild()
	for _, w in pairs(widgets) do
		w.Button:Destroy()
	end
	widgets = {}

	local q = classSkill("Q")
	local r = classSkill("R")
	if q then widgets.Q = makeButton("Q", q, 1) end
	if r then widgets.R = makeButton("R", r, 2) end
	row.Visible = (q ~= nil) or (r ~= nil)
end

--// cooldown ticker: drains each cover, updates the number
RunService.RenderStepped:Connect(function()
	local now = os.clock()
	for _, w in pairs(widgets) do
		local left = (w.ReadyAt or 0) - now
		if left > 0 then
			local total = (w.Def.CooldownSeconds or 20)
			w.Cover.Visible = true
			w.Count.Visible = true
			w.Cover.Size = UDim2.fromScale(1, math.clamp(left / total, 0, 1))
			w.Count.Text = string.format("%.1f", left) --// 1 decimal, ticking down
		elseif w.Cover.Visible then
			w.Cover.Visible = false
			w.Count.Visible = false
		end
	end
end)

skillRemote.OnClientEvent:Connect(function(action, slot, a)
	local w = widgets[slot]
	if not w then return end
	if action == "Cooldown" then
		w.ReadyAt = os.clock() + (a or w.Def.CooldownSeconds or 20)
	elseif action == "Denied" then
		--// red flash + the reason briefly on the button
		local btn = w.Button
		btn.BackgroundColor3 = TOMATO
		local old = w.Button.Text
		w.Button.Text = "✕"
		task.delay(0.6, function()
			if btn.Parent then
				btn.BackgroundColor3 = CREAM
				btn.Text = old
			end
		end)
	end
end)

--// keys + gamepad
ContextActionService:BindAction("SkillQ", function(_, s)
	if s == Enum.UserInputState.Begin then useSlot("Q") end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)

ContextActionService:BindAction("SkillR", function(_, s)
	if s == Enum.UserInputState.Begin then useSlot("R") end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.R, Enum.KeyCode.DPadUp)

player:GetAttributeChangedSignal("ClassKey"):Connect(rebuild)
rebuild()
