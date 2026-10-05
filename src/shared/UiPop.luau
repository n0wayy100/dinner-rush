--[[
	Dinner Rush - UiPop
	ReplicatedStorage.Shared.UiPop  (ModuleScript, CLIENT use)

	The little "pop" every minigame panel makes as it appears (owner, Oct
	2026): it starts small and springs up to full size.

		UiPop.Pop(screenGui)   -- pops each panel on it
		UiPop.Pop(frame)       -- pops just that one

	Full-screen pieces (dim backdrops, invisible tap catchers) are left
	alone - a whole screen springing open reads as a glitch, not a pop.

	A panel that already has a UIScale (the plunge panel pulses with one)
	shares it: every panel here rests at scale 1, so the pop springs from
	small back to 1 and the panel's own effects carry on from there.
--]]

local TweenService = game:GetService("TweenService")

local UiPop = {}

local START_SCALE = 0.55
local POP = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function isFullScreen(object)
	return object.Size.X.Scale >= 0.98 and object.Size.Y.Scale >= 0.98
end

local function popOne(object)
	local scale = object:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "PopScale"
		scale.Parent = object
	end
	scale.Scale = START_SCALE
	TweenService:Create(scale, POP, { Scale = 1 }):Play()
end

function UiPop.Pop(target)
	if typeof(target) ~= "Instance" then return end

	if target:IsA("LayerCollector") then
		for _, child in ipairs(target:GetChildren()) do
			if child:IsA("GuiObject") and child.Visible and not isFullScreen(child) then
				popOne(child)
			end
		end
	elseif target:IsA("GuiObject") then
		popOne(target)
	end
end

return UiPop
