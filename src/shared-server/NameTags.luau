--[[
	Dinner Rush - NameTags
	ServerStorage.Shared.NameTags  (ModuleScript, server - used by BOTH places)

	Our own name tag over every player's head (Oct 2026), in the game's
	sticker style: the player's display name in white with a chocolate
	outline. Built on the SERVER so everyone sees the same tag; Roblox's
	default name is hidden on the player so the two never stack.

	VIP (the shop's VIP pass): when the server-verified Pass_VIP attribute is
	true, the name turns GOLD and a "VIP" chip sits beside it. Purchases sets
	that attribute from Roblox's own ownership check, so it can't be faked.

	Usage (each place's NameTagBoot):  require(...NameTags).Start()
--]]

local Players = game:GetService("Players")

local NameTags = {}

local CHOC = Color3.fromRGB(59, 43, 32)
local WHITE = Color3.new(1, 1, 1)
local GOLD = Color3.fromRGB(255, 205, 60)
local VIP_PURPLE = Color3.fromRGB(110, 60, 190)

local function build(player, character)
	local head = character:WaitForChild("Head", 10)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not head or not humanoid then return end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None --// ours replaces Roblox's

	local old = head:FindFirstChild("DR_NameTag")
	if old then old:Destroy() end

	local gui = Instance.new("BillboardGui")
	gui.Name = "DR_NameTag"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(220, 34)
	gui.StudsOffset = Vector3.new(0, 2.1, 0)
	gui.MaxDistance = 80
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = head

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromScale(1, 1)
	row.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 5)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local name = Instance.new("TextLabel")
	name.Name = "PlayerName"
	name.LayoutOrder = 1
	name.BackgroundTransparency = 1
	name.AutomaticSize = Enum.AutomaticSize.X
	name.Size = UDim2.new(0, 0, 1, 0)
	name.Font = Enum.Font.FredokaOne
	name.TextSize = 22
	name.TextColor3 = WHITE
	name.TextStrokeColor3 = CHOC
	name.TextStrokeTransparency = 0
	name.Text = player.DisplayName
	name.Parent = row

	local chip = Instance.new("TextLabel")
	chip.Name = "VipChip"
	chip.LayoutOrder = 2
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.new(0, 0, 0, 22)
	chip.BackgroundColor3 = VIP_PURPLE
	chip.Font = Enum.Font.FredokaOne
	chip.TextSize = 16
	chip.TextColor3 = GOLD
	chip.Text = " VIP "
	chip.Visible = false
	chip.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.4, 0)
	corner.Parent = chip
	local stroke = Instance.new("UIStroke")
	stroke.Color = CHOC
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = chip

	local function applyVip()
		local vip = player:GetAttribute("Pass_VIP") == true
		name.TextColor3 = vip and GOLD or WHITE
		chip.Visible = vip
	end
	applyVip()
	player:GetAttributeChangedSignal("Pass_VIP"):Connect(applyVip)
end

function NameTags.Start()
	local function watch(player)
		if player.Character then task.spawn(build, player, player.Character) end
		player.CharacterAdded:Connect(function(character)
			build(player, character)
		end)
	end
	for _, player in ipairs(Players:GetPlayers()) do watch(player) end
	Players.PlayerAdded:Connect(watch)
end

return NameTags
