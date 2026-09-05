--[[
	Dinner Rush - DishModels
	ServerStorage.Shared.DishModels  (ModuleScript)

	Parts-built cartoon food. NOT meshes, NOT Toolbox - pure Parts
	composed in code (the no-free-models law), chunky on purpose to fit
	the house style. One builder per item; DishModels.decorate(tool,
	itemName) dresses a Tool's Handle and reports whether it did.
	Undecorated items keep their plain colored block, so a brand-new
	dish ships ugly-but-working before it ships pretty.

	SWAP PATH: when real meshes arrive (the builders' OWN Blender
	imports only), replace a builder's innards - callers never change.
--]]

local DishModels = {}

--// One decorative part: welded to the handle, physically inert
local function deco(handle, shape, size, color, offset)
	local part = Instance.new("Part")
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = handle.CFrame * offset

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = part

	--// CHILD of the base part, not a sibling: destroying, cloning or
	--// hiding the base always carries the whole meal with it
	part.Parent = handle
	return part
end

--// Cylinders lie along X; this stands one upright at the given offset
local function puck(handle, height, diameter, color, y, extraCFrame)
	local offset = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90))
	if extraCFrame then
		offset = CFrame.new(0, y, 0) * extraCFrame * CFrame.Angles(0, 0, math.rad(90))
	end
	return deco(handle, Enum.PartType.Cylinder,
		Vector3.new(height, diameter, diameter), color, offset)
end

local BUN = Color3.fromRGB(228, 180, 118)
local PATTY = Color3.fromRGB(110, 72, 46)
local CHEESE = Color3.fromRGB(250, 200, 70)
local LETTUCE = Color3.fromRGB(112, 190, 92)
local SESAME = Color3.fromRGB(255, 248, 230)
local CARTON = Color3.fromRGB(222, 62, 62)
local FRY = Color3.fromRGB(246, 206, 92)
local STEAK = Color3.fromRGB(132, 76, 50)
local CHAR = Color3.fromRGB(70, 42, 26)
local RAW_MEAT = Color3.fromRGB(204, 92, 92)
local RAW_STEAK = Color3.fromRGB(192, 54, 58)
local FAT = Color3.fromRGB(240, 230, 218)
local POTATO = Color3.fromRGB(172, 132, 82)

local BUILDERS = {
	Burger = function(handle)
		puck(handle, 0.32, 1.5, BUN, -0.45)                     -- bottom bun
		puck(handle, 0.28, 1.55, PATTY, -0.18)                  -- the patty
		deco(handle, Enum.PartType.Block,                       -- cheese, corners out
			Vector3.new(1.55, 0.1, 1.55), CHEESE,
			CFrame.new(0, 0.02, 0) * CFrame.Angles(0, math.rad(30), 0))
		puck(handle, 0.14, 1.6, LETTUCE, 0.14)                  -- lettuce frill
		puck(handle, 0.42, 1.5, BUN, 0.4)                       -- top bun
		puck(handle, 0.2, 1.1, BUN, 0.68)                       -- its dome
		for index = 1, 3 do                                     -- sesame dots
			local angle = index * 2.1
			deco(handle, Enum.PartType.Block,
				Vector3.new(0.12, 0.05, 0.14), SESAME,
				CFrame.new(math.cos(angle) * 0.4, 0.8, math.sin(angle) * 0.4))
		end
	end,

	Fries = function(handle)
		deco(handle, Enum.PartType.Block,                       -- the carton
			Vector3.new(1.05, 1.0, 0.62), CARTON, CFrame.new(0, -0.25, 0))
		local sticks = {
			{ -0.32, 0.35, -0.1, 8 }, { -0.11, 0.45, 0.08, -6 },
			{ 0.1, 0.38, -0.06, 4 }, { 0.3, 0.42, 0.1, -9 },
			{ -0.2, 0.5, 0.12, -3 }, { 0.22, 0.52, -0.12, 7 },
		}
		for _, stick in ipairs(sticks) do
			deco(handle, Enum.PartType.Block,
				Vector3.new(0.18, 0.95, 0.18), FRY,
				CFrame.new(stick[1], stick[2], stick[3])
					* CFrame.Angles(0, 0, math.rad(stick[4])))
		end
	end,

	GrilledSteak = function(handle)
		--// BIG like the burger (owner call - the bone version read as a
		--// chicken leg): one thick proud cut, rounded pill ends, darker
		--// seared top with angled char marks. v3.
		deco(handle, Enum.PartType.Block,                       -- the cut
			Vector3.new(1.5, 0.6, 1.25), STEAK, CFrame.new(-0.05, 0, 0))
		puck(handle, 0.6, 1.25, STEAK, 0, CFrame.new(0.7, 0, 0))
		puck(handle, 0.6, 1.15, STEAK, 0, CFrame.new(-0.78, 0, 0))
		deco(handle, Enum.PartType.Block,                       -- seared top
			Vector3.new(1.45, 0.08, 1.15), Color3.fromRGB(96, 54, 34),
			CFrame.new(-0.05, 0.32, 0))
		for index = -1, 1 do                                    -- char marks
			deco(handle, Enum.PartType.Block,
				Vector3.new(0.13, 0.05, 1.18), CHAR,
				CFrame.new(index * 0.48 - 0.05, 0.36, 0)
					* CFrame.Angles(0, math.rad(14), 0))
		end
	end,

	RawPatty = function(handle)
		puck(handle, 0.3, 1.4, RAW_MEAT, -0.1)
		puck(handle, 0.06, 1.45, Color3.fromRGB(178, 70, 70), 0.09) -- top sheen
	end,

	RawSteak = function(handle)
		--// Same pill silhouette as the cooked cut, in raw red with
		--// marbling - before/after reads instantly on the grill
		deco(handle, Enum.PartType.Block,
			Vector3.new(1.2, 0.32, 1.0), RAW_STEAK, CFrame.new(-0.1, -0.02, 0))
		puck(handle, 0.32, 1.0, RAW_STEAK, -0.02, CFrame.new(0.5, 0, 0))
		puck(handle, 0.32, 0.92, RAW_STEAK, -0.02, CFrame.new(-0.66, 0, 0))
		deco(handle, Enum.PartType.Block,                       -- marbling
			Vector3.new(1.15, 0.33, 0.13), FAT,
			CFrame.new(-0.05, -0.02, 0.22) * CFrame.Angles(0, math.rad(8), 0))
		deco(handle, Enum.PartType.Block,
			Vector3.new(0.8, 0.33, 0.11), FAT,
			CFrame.new(-0.15, -0.02, -0.2) * CFrame.Angles(0, math.rad(-12), 0))
	end,

	RawPotato = function(handle)
		deco(handle, Enum.PartType.Ball,
			Vector3.new(1.05, 1.05, 1.05), POTATO, CFrame.new(0, -0.1, 0))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.8, 0.8, 0.8), POTATO, CFrame.new(0.35, -0.02, 0.05))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.8, 0.8, 0.8), POTATO, CFrame.new(-0.35, -0.05, -0.05))
	end,
}

--// How far below its centre each model reaches differs per dish, so a
--// shared plate height leaves some hovering. This is the extra DROP a
--// dish needs on a PLATE to sit flush (reference: the burger, whose
--// bottom bun reaches 0.61 below centre). Unlisted = no drop.
local PLATE_DROP = {
	GrilledSteak = 0.31, --// 0.6-thick slab: bottom is only 0.3 below centre
	RawSteak = 0.43,
	RawPatty = 0.36,
}

function DishModels.plateDrop(itemName)
	return PLATE_DROP[itemName] or 0
end

--// The reference depth: every model's bottom is this far below its
--// (dropped) centre. anchor + BottomDepth - plateDrop(item) puts a
--// model's BOTTOM exactly at the anchor.
DishModels.BottomDepth = 0.61

--// Dresses ANY base part (a Tool Handle, the pass's Food portion...).
--// True = dressed (the caller should hide the plain base); false = no
--// builder for that name, keep the plain look.
function DishModels.dress(basePart, itemName)
	local builder = itemName and BUILDERS[itemName]
	if not builder or not basePart then
		return false
	end
	builder(basePart)
	return true
end

--// Tool convenience: dresses its Handle
function DishModels.decorate(tool, itemName)
	return DishModels.dress(tool:FindFirstChild("Handle"), itemName)
end

return DishModels
