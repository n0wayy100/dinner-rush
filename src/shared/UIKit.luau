--[[
	Dinner Rush - UIKit
	ReplicatedStorage.Shared.UIKit        (ModuleScript, CLIENT use)

	The shared toolbox for the code-built, art-skinned panels (Oct 2026) -
	the house palette, the small builders, and the ART KIT that swaps a
	code-drawn placeholder for an uploaded image:

		local UIKit = require(ReplicatedStorage.Shared.UIKit)
		local kit = UIKit.artKit(Config.PlayerStats.StaffArt, Config.Monetization.ShopArt)
		kit.skin(frame, "PanelFrame")         -- frame becomes the art (9-sliced if Slice)
		local glow = kit.image(card, "SoftGlow") -- a sprite, or nil if the slot is empty

	Art tables map slot -> { Image = "rbxassetid://...", Size = {w, h},
	Slice = {minX, minY, maxX, maxY} }. Sliced art keeps its border in
	proportion to the frame's on-screen size (SliceScale follows the frame),
	so a frame looks right on a phone and a monitor alike. Plain art is drawn
	with Fit so it never squashes.

	Cosmetic only - nothing here decides anything.
]]

local TweenService = game:GetService("TweenService")

local UIKit = {}

UIKit.Colors = {
	Cream = Color3.fromRGB(255, 246, 233),
	Warm = Color3.fromRGB(255, 236, 210),
	Choc = Color3.fromRGB(59, 43, 32),
	Tomato = Color3.fromRGB(229, 72, 77),
	Mustard = Color3.fromRGB(245, 184, 65),
	Basil = Color3.fromRGB(76, 175, 109),
	Wood = Color3.fromRGB(150, 98, 56),
	WoodDark = Color3.fromRGB(110, 70, 38),
	White = Color3.new(1, 1, 1),
}
local C = UIKit.Colors

UIKit.Quick = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function UIKit.corner(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, 14)
	c.Parent = obj
	return c
end

function UIKit.stroke(obj, thickness, color)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 3
	s.Color = color or C.Choc
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = obj
	return s
end

function UIKit.label(parent, name, font, color, maxSize)
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Font = font or Enum.Font.FredokaOne
	t.TextColor3 = color or C.Choc
	t.TextScaled = true
	t.TextWrapped = true
	t.Text = ""
	t.Parent = parent
	if maxSize then
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = maxSize
		cap.Parent = t
	end
	return t
end

--// white letters with a chocolate outline - the lobby sticker look
function UIKit.stickerText(t)
	t.TextColor3 = C.White
	t.TextStrokeColor3 = C.Choc
	t.TextStrokeTransparency = 0
end

function UIKit.aspect(obj, ratio)
	local a = Instance.new("UIAspectRatioConstraint")
	a.AspectRatio = ratio
	a.Parent = obj
	return a
end

function UIKit.commas(n)
	local s = tostring(math.floor(n or 0))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--// hover grows a little, a press squashes - every button feels pressable
function UIKit.bouncy(button)
	local scale = Instance.new("UIScale")
	scale.Parent = button
	button.MouseEnter:Connect(function()
		TweenService:Create(scale, UIKit.Quick, { Scale = 1.06 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, UIKit.Quick, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, UIKit.Quick, { Scale = 0.94 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, UIKit.Quick, { Scale = 1.06 }):Play()
	end)
	return scale
end

--// counts a label up from 0 to `target` over `seconds`, formatted each frame
function UIKit.countUp(textLabel, target, seconds, formatter)
	local value = Instance.new("NumberValue")
	value.Value = 0
	local fmt = formatter or function(n) return UIKit.commas(n) end
	value.Changed:Connect(function(n)
		textLabel.Text = fmt(n)
	end)
	textLabel.Text = fmt(0)
	local tween = TweenService:Create(value, TweenInfo.new(seconds or 0.8,
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = tonumber(target) or 0 })
	tween:Play()
	tween.Completed:Connect(function()
		textLabel.Text = fmt(tonumber(target) or 0)
		value:Destroy()
	end)
	return tween
end

----------------------------------------------------------------
-- THE ART KIT: slot lookups across one or more art tables (first wins)
----------------------------------------------------------------
function UIKit.artKit(...)
	local tables = { ... }
	local kit = {}

	function kit.entry(slot)
		for _, t in ipairs(tables) do
			local e = t and t[slot]
			if e and type(e.Image) == "string" and e.Image ~= "" then
				return e
			end
		end
		return nil
	end

	function kit.id(slot)
		local e = kit.entry(slot)
		return e and e.Image or nil
	end

	--// The code-drawn look (stroke, corner, gradient, and any child named
	--// "Placeholder") steps aside and the image fills the frame
	function kit.skin(frame, slot)
		local e = kit.entry(slot)
		if not e then return false end
		frame.BackgroundTransparency = 1
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("UIStroke") or child:IsA("UICorner") or child:IsA("UIGradient")
				or child.Name == "Placeholder" then
				child:Destroy()
			end
		end
		local image = Instance.new("ImageLabel")
		image.Name = "Art"
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(1, 1)
		image.ZIndex = 0 --// behind live text and buttons
		image.Image = e.Image
		if e.Slice then
			local s = e.Slice
			image.ScaleType = Enum.ScaleType.Slice
			image.SliceCenter = Rect.new(s[1], s[2], s[3], s[4])
			local nativeW = e.Size and e.Size[1] or 512
			local nativeH = e.Size and e.Size[2] or 512
			local function rescale()
				local size = frame.AbsoluteSize
				if size.X > 0 and size.Y > 0 then
					image.SliceScale = math.clamp(math.min(size.X / nativeW, size.Y / nativeH), 0.05, 4)
				end
			end
			frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)
			rescale()
		else
			image.ScaleType = Enum.ScaleType.Fit
		end
		image.Parent = frame
		if frame:IsA("TextButton") then
			frame.AutoButtonColor = false
		end
		return true
	end

	--// a free-standing sprite (Fit), or nil when the slot is empty
	function kit.image(parent, slot, name)
		local id = kit.id(slot)
		if not id then return nil end
		local image = Instance.new("ImageLabel")
		image.Name = name or slot
		image.BackgroundTransparency = 1
		image.ScaleType = Enum.ScaleType.Fit
		image.Image = id
		image.Parent = parent
		return image
	end

	return kit
end

return UIKit
