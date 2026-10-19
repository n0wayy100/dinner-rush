--[[
	Dinner Rush - HoldTool
	ServerStorage.Shared.HoldTool  (ModuleScript)

	ONE THING IN THE HAND AT A TIME (owner bug report, Oct 2026). A Tool
	parented straight onto a character is equipped WITHOUT the one already
	in the hand being put away - so grabbing an ingredient while holding a
	dish left BOTH selected on the hotbar, overlapping in one fist.

	  HoldTool.Give(player, tool)   put away what is held, then hold this
	  HoldTool.Stow(player, tool)   into the backpack (hotbar), not the hand

	Carried items are counted across the hand AND the backpack everywhere
	(carry limit, serving, cooking), so putting one away changes nothing
	but what the player sees.
--]]

local HoldTool = {}

function HoldTool.Give(player, tool)
	local character = player.Character
	if not character then
		tool.Parent = player:FindFirstChildOfClass("Backpack")
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:UnequipTools() --// the old item goes back to its hotbar slot
	end
	tool.Parent = character
end

function HoldTool.Stow(player, tool)
	tool.Parent = player:FindFirstChildOfClass("Backpack") or player.Character
end

return HoldTool
