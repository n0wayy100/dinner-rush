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

--// Yamasaki Sushi menu
local KARA = Color3.fromRGB(208, 138, 58)
local KARA_DARK = Color3.fromRGB(172, 102, 42)
local RAW_CHICKEN = Color3.fromRGB(235, 180, 160)
local CHICKEN_SKIN = Color3.fromRGB(242, 205, 185)
local RAW_SHRIMP = Color3.fromRGB(226, 182, 175)
local SHRIMP_TAIL = Color3.fromRGB(236, 120, 112)
local BATTER = Color3.fromRGB(236, 192, 120)
local NOODLE = Color3.fromRGB(242, 224, 150)
local NOODLE_DRY = Color3.fromRGB(230, 208, 132)
local BOWL_RED = Color3.fromRGB(198, 64, 58)
local BOWL_WHITE = Color3.fromRGB(243, 236, 224)
local BROTH = Color3.fromRGB(224, 192, 140)
local NARUTO_PINK = Color3.fromRGB(240, 140, 160)
local YOLK = Color3.fromRGB(247, 190, 70)
local ONION = Color3.fromRGB(112, 190, 92)
local CHOPSTICK = Color3.fromRGB(196, 150, 96)
local CHASHU = Color3.fromRGB(158, 102, 62)
local PARSLEY = Color3.fromRGB(92, 168, 82)
local KARA_LIGHT = Color3.fromRGB(236, 182, 102)
local TEMPURA_TAIL = Color3.fromRGB(243, 140, 72)

--// One curled shrimp lying down: three arched body segments + a fan
--// tail. Shared by the raw and tempura builders - only the coat and
--// girth change. `at` places and turns the whole shrimp.
local function shrimp(handle, at, girth, body, tail)
	local seg = Vector3.new(0.5, girth, girth)
	deco(handle, Enum.PartType.Block, seg, body,
		at * CFrame.new(-0.26, 0.06, 0) * CFrame.Angles(0, 0, math.rad(38)))
	deco(handle, Enum.PartType.Block, seg, body,
		at * CFrame.new(0, 0.16, 0))
	deco(handle, Enum.PartType.Block, seg, body,
		at * CFrame.new(0.26, 0.06, 0) * CFrame.Angles(0, 0, math.rad(-38)))
	deco(handle, Enum.PartType.Block, Vector3.new(0.32, 0.3, 0.1), tail,
		at * CFrame.new(-0.5, 0.2, 0) * CFrame.Angles(0, 0, math.rad(55)))
end

local RICE = Color3.fromRGB(250, 248, 240)
local PORK_MEAT = Color3.fromRGB(214, 120, 118)
local PORK_FAT = Color3.fromRGB(245, 232, 220)
local PORK_SKIN = Color3.fromRGB(236, 200, 170)

--// One cube of pork belly: meat / fat / meat / skin, bottom on the base's
--// floor (-BottomDepth). `x, z` place it, `turn` spins it (degrees).
local function porkChunk(handle, x, z, turn)
	local at = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(turn), 0)
	local layers = {
		{ 0.18, PORK_MEAT }, { 0.08, PORK_FAT }, { 0.12, PORK_MEAT }, { 0.07, PORK_SKIN },
	}
	local y = -0.61
	for _, layer in ipairs(layers) do
		local height, color = layer[1], layer[2]
		deco(handle, Enum.PartType.Block, Vector3.new(0.55, height, 0.42), color,
			at * CFrame.new(0, y + height / 2, 0))
		y += height
	end
end

local BUILDERS = {
	--// Manila: pork belly cubes in the ADOBO POT. The RawPork mesh is ONE
	--// part with its cutting board baked in (PorkBelly_Board), so it cannot
	--// be trimmed - Config.Kitchen.StationFoodItem falls back to this.
	PotPork = function(handle)
		porkChunk(handle, -0.34, -0.12, 15)
		porkChunk(handle, 0.32, -0.16, -20)
		porkChunk(handle, 0.02, 0.3, 40)
	end,

	--// Manila: rice cooking LOOSE in the cooker. Config.Kitchen
	--// .StationFoodItem shows this on the station instead of the RawRice
	--// sack (the sack is what you carry, not what you cook). A low puck of
	--// rice with a soft domed top; a DishMeshes.CookerRice mesh overrides it.
	CookerRice = function(handle)
		puck(handle, 0.3, 1.3, RICE, -0.46)                     -- the rice bed
		deco(handle, Enum.PartType.Ball,                        -- domed middle
			Vector3.new(0.8, 0.8, 0.8), RICE, CFrame.new(0, -0.38, 0))
		for index = 1, 4 do                                     -- soft lumps
			local angle = index * math.pi / 2 + 0.4
			deco(handle, Enum.PartType.Ball,
				Vector3.new(0.5, 0.5, 0.5), RICE,
				CFrame.new(math.cos(angle) * 0.36, -0.36, math.sin(angle) * 0.36))
		end
	end,

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

	Karaage = function(handle)
		--// Golden boneless chunks in a loose pile (no bones ANYWHERE -
		--// the steak saga proved bone shapes read as the wrong food).
		--// v2 matches the imported icon: craggier, lighter tops, and the
		--// little parsley sprig on the summit.
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.85, 0.85, 0.85), KARA, CFrame.new(-0.25, -0.18, 0.05))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.75, 0.75, 0.75), KARA, CFrame.new(0.28, -0.22, -0.12))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.7, 0.7, 0.7), KARA, CFrame.new(0.05, -0.26, 0.32))
		--// craggy fried bits, dark and light
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.34, 0.34, 0.34), KARA_DARK, CFrame.new(-0.12, 0.1, 0.02))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.3, 0.3, 0.3), KARA_DARK, CFrame.new(0.38, 0.02, -0.02))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.26, 0.26, 0.26), KARA_LIGHT, CFrame.new(-0.34, 0.06, 0.22))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.24, 0.24, 0.24), KARA_LIGHT, CFrame.new(0.14, 0.02, 0.4))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.22, 0.22, 0.22), KARA_LIGHT, CFrame.new(0.08, 0.14, -0.24))
		--// the parsley sprig
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.24, 0.1, 0.2), PARSLEY, CFrame.new(-0.04, 0.24, 0.08))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.18, 0.09, 0.16), PARSLEY, CFrame.new(0.1, 0.26, -0.02))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.16, 0.08, 0.16), PARSLEY, CFrame.new(-0.14, 0.26, -0.06))
	end,

	TempuraShrimp = function(handle)
		--// Two fat battered curls crossed on the plate, bright orange
		--// tails out (tail colour matched to the imported icon)
		shrimp(handle, CFrame.new(-0.08, -0.38, 0.2)
			* CFrame.Angles(0, math.rad(18), 0), 0.44, BATTER, TEMPURA_TAIL)
		shrimp(handle, CFrame.new(0.12, -0.38, -0.26)
			* CFrame.Angles(0, math.rad(-155), 0), 0.44, BATTER, TEMPURA_TAIL)
	end,

	Ramen = function(handle)
		--// v2 bowl matches the imported icon AND the builder's dishware:
		--// white ceramic with the red band at the rim, chashu slices,
		--// twin narutos
		puck(handle, 0.6, 1.8, BOWL_WHITE, -0.3)                -- the bowl
		puck(handle, 0.14, 1.82, BOWL_RED, -0.1)                -- red rim band
		puck(handle, 0.08, 1.62, BROTH, 0.04)                   -- broth surface
		puck(handle, 0.09, 0.52, CHASHU, 0.11, CFrame.new(0.32, 0, -0.22)) -- chashu
		puck(handle, 0.09, 0.46, CHASHU, 0.13, CFrame.new(0.12, 0, -0.4))
		local strands = { { -0.1, 0.05, 8 }, { 0.12, -0.12, -14 }, { -0.28, -0.3, 22 } }
		for _, strand in ipairs(strands) do                     -- noodle waves
			deco(handle, Enum.PartType.Block,
				Vector3.new(0.6, 0.05, 0.16), NOODLE,
				CFrame.new(strand[1], 0.1, strand[2])
					* CFrame.Angles(0, math.rad(strand[3]), 0))
		end
		puck(handle, 0.07, 0.42, SESAME, 0.12, CFrame.new(0.42, 0, 0.28))   -- narutos
		puck(handle, 0.08, 0.16, NARUTO_PINK, 0.125, CFrame.new(0.42, 0, 0.28))
		puck(handle, 0.07, 0.38, SESAME, 0.12, CFrame.new(0.08, 0, 0.44))
		puck(handle, 0.08, 0.14, NARUTO_PINK, 0.125, CFrame.new(0.08, 0, 0.44))
		deco(handle, Enum.PartType.Ball,                        -- egg half
			Vector3.new(0.36, 0.22, 0.28), SESAME, CFrame.new(-0.45, 0.12, 0.2))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.18, 0.12, 0.18), YOLK, CFrame.new(-0.45, 0.19, 0.2))
		deco(handle, Enum.PartType.Block,                       -- green onion
			Vector3.new(0.14, 0.05, 0.14), ONION, CFrame.new(0.08, 0.12, -0.38))
		deco(handle, Enum.PartType.Block,
			Vector3.new(0.12, 0.05, 0.12), ONION, CFrame.new(-0.18, 0.12, -0.45))
		for index = 0, 1 do                                     -- chopsticks on the rim
			deco(handle, Enum.PartType.Block,
				Vector3.new(1.7, 0.07, 0.07), CHOPSTICK,
				CFrame.new(0.15 + index * 0.14, 0.34, -0.42 + index * 0.13)
					* CFrame.Angles(0, math.rad(18), 0))
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

	RawChicken = function(handle)
		--// Pale boneless chunks - the before to Karaage's after
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.85, 0.85, 0.85), RAW_CHICKEN, CFrame.new(-0.22, -0.18, 0.02))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.72, 0.72, 0.72), RAW_CHICKEN, CFrame.new(0.3, -0.24, 0.12))
		deco(handle, Enum.PartType.Ball,
			Vector3.new(0.62, 0.62, 0.62), RAW_CHICKEN, CFrame.new(0.08, -0.28, -0.3))
		deco(handle, Enum.PartType.Ball,                        -- skin sheen
			Vector3.new(0.4, 0.4, 0.4), CHICKEN_SKIN, CFrame.new(-0.1, 0.08, 0.1))
	end,

	RawShrimp = function(handle)
		shrimp(handle, CFrame.new(-0.1, -0.45, 0.2)
			* CFrame.Angles(0, math.rad(15), 0), 0.3, RAW_SHRIMP, SHRIMP_TAIL)
		shrimp(handle, CFrame.new(0.15, -0.45, -0.25)
			* CFrame.Angles(0, math.rad(-160), 0), 0.3, RAW_SHRIMP, SHRIMP_TAIL)
	end,

	RawNoodles = function(handle)
		--// The instant-noodle brick, wavy strands suggested on top
		deco(handle, Enum.PartType.Block,
			Vector3.new(1.15, 0.48, 0.85), NOODLE, CFrame.new(0, -0.36, 0))
		local waves = { { -0.22, 6 }, { 0, -8 }, { 0.22, 5 } }
		for _, wave in ipairs(waves) do
			deco(handle, Enum.PartType.Block,
				Vector3.new(1.05, 0.06, 0.1), NOODLE_DRY,
				CFrame.new(0, -0.09, wave[1]) * CFrame.Angles(0, math.rad(wave[2]), 0))
		end
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

--// Filled per imported mesh by dressWithMesh (the mesh swap path below)
local meshDrop = {}

function DishModels.plateDrop(itemName, trim)
	--// A measured mesh drop (see dressWithMesh) outranks the hand-tuned
	--// parts table. A trimmed display is measured under its own key.
	if trim then
		return meshDrop[itemName .. "#trim"] or 0 --// same key as trimKey below
	end
	return meshDrop[itemName] or PLATE_DROP[itemName] or 0
end

--// The Manila plate is not flat - it has a shallow well in the middle,
--// so a dish resting on the plate's TOP face reads as hovering above
--// its own dinnerware. This is the EXTRA drop that settles a dish down
--// into that well.
--//
--// It belongs to the PLATE, not to the model, which is why it lives
--// apart from plateDrop: the same dish on a cooking station must not
--// sink, or it ends up buried in the counter (see KitchenService's
--// station placement). Only plateOffset below adds it in.
local PLATE_SINK = {
	AdoboPork = 0.2,
	SteamedRice = 0.2,
	Lumpia = 0.2,

	--// THE PARIS BISTRO (Oct 2026): all three hovered over their plates
	Croissant = 0.3,
	Ratatouille = 0.3,
	Bouillabaisse = 0.3,
}

--// Placing a dish ON A PLATE: how far down from the plate's surface the
--// model's centre goes. Stations want plateDrop on its own instead.
function DishModels.plateOffset(itemName)
	return DishModels.plateDrop(itemName) + (PLATE_SINK[itemName] or 0)
end

--// The reference depth: every model's bottom is this far below its
--// (dropped) centre. anchor + BottomDepth - plateDrop(item) puts a
--// model's BOTTOM exactly at the anchor.
DishModels.BottomDepth = 0.61

--// One warning per problem per item: a dish taken fifty times a shift
--// must not bury the output window
local warned = {}
local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn("[DishModels] " .. message)
end

--// TOOL GRIPS ONLY. A mesh is modelled centred on its pivot (see the
--// pivot rule above), so welding it straight onto a Handle puts the
--// player's fist in the MIDDLE of the food - half a bowl of adobo
--// swallowed by the hand. Lifting it by half its own height plus a gap
--// rests its base on the grip plane, and the hand reads as holding it
--// up. Height-derived, so a tall bowl and a flat plate both sit right.
--//
--// Plates and stations do NOT get this: there the caller already places
--// the food off the anchor maths (see BottomDepth).
local GRIP_GAP = 0.15

--// Half-height works for something deep like a bowl, but a FLAT prop -
--// a cutting board, a plate of lumpia - is barely moved by half of
--// almost nothing, and the fist stays inside it. This is the floor on
--// the lift, so flat food rests on an open palm instead.
local GRIP_MIN_LIFT = 0.45

--// Fine-tuning on top of the lift, in HANDLE space:
--//   +X out to the character's right (the tool hand) - away from the torso
--//   +Y further up
--//   -Z forward, away from the chest
--// Height is handled by the lift; this is for WIDTH. A prop wider than
--// about two studs reaches back across the chest when the hand holds its
--// middle, and no amount of lifting fixes that - it has to move out.
--// If a nudge sends a dish the wrong way, flip the sign.
local GRIP_NUDGE = {
	RawPork = Vector3.new(0.35, 0, -0.35), --// the board is wide; hold it nearer one end

	--// THE PARIS BISTRO (Oct 2026): every French model is 1.1-1.3 studs
	--// across, as wide as the pork board, and half of each sat in the
	--// hand - the same push out and forward, plus a touch more lift
	RawCroissant = Vector3.new(0.3, 0.1, -0.3),
	Croissant = Vector3.new(0.3, 0.1, -0.3),
	RawVeggies = Vector3.new(0.3, 0.1, -0.3),
	Ratatouille = Vector3.new(0.3, 0.1, -0.3),
	RawSeafood = Vector3.new(0.3, 0.1, -0.3),
	Bouillabaisse = Vector3.new(0.3, 0.1, -0.3),
}

--// THE MESH SWAP PATH (Sep 2026): the team's OWN generated meshes -
--// GLBs from Claude Design, imported via Import 3D, NEVER Toolbox.
--// Drop each imported Model into ServerStorage.DishMeshes named EXACTLY
--// as its item (Karaage, RawChicken, ...). Any item with a mesh there
--// wears it; everything else keeps its parts build. Callers unchanged.
--//
--// Everything past the clone is defence against what Import 3D actually
--// hands you: sometimes a Model, sometimes one loose MeshPart, often at
--// the wrong scale, and with the pivot left at the file's origin rather
--// than on the food. Each of those used to end the same way - dress()
--// reported success, the caller hid the plain block (see makeTool), and
--// the player held an invisible grip. Now each one names itself.
--// TRIM (Oct 2026): show only PART of a mesh - e.g. the rice out of the
--// RawRice sack, for the rice cooker. trim = { Keep = {...}, Skip = {...} }
--// lowercase name keywords: a part stays if its name has a Keep word and no
--// Skip word. A trimmed copy is measured under its own key, so it never
--// disturbs where the whole model sits in a hand or on a plate.
local function trimKey(itemName, trim)
	return trim and (itemName .. "#trim") or itemName
end

local function nameHasAny(name, words)
	for _, word in ipairs(words or {}) do
		if string.find(name, word, 1, true) then return true end
	end
	return false
end

local function applyTrim(model, itemName, trim)
	--// no Keep list = keep everything that isn't on the Skip list
	local keepAll = not trim.Keep or #trim.Keep == 0
	local kept, removed, names = 0, 0, {}
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") and inst.Parent then
			local lower = string.lower(inst.Name)
			table.insert(names, inst.Name)
			if (keepAll or nameHasAny(lower, trim.Keep)) and not nameHasAny(lower, trim.Skip) then
				kept += 1
			else
				removed += 1
				inst:Destroy()
			end
		end
	end
	if kept == 0 then
		warnOnce("trim:" .. itemName,
			("DishMeshes.%s: the trim left nothing - its parts are: %s")
				:format(itemName, table.concat(names, ", ")))
	elseif removed == 0 then
		--// a skip-only trim that caught nothing: the unwanted part has a name
		--// we did not guess - list them so the Config words can be fixed
		warnOnce("trimnone:" .. itemName,
			("DishMeshes.%s: the trim removed nothing (skip words %s) - its parts are: %s")
				:format(itemName, table.concat(trim.Skip or {}, "/"), table.concat(names, ", ")))
	end
	return kept > 0
end

local function dressWithMesh(basePart, itemName, forGrip, trim)
	local folder = game:GetService("ServerStorage"):FindFirstChild("DishMeshes")
	local template = folder and folder:FindFirstChild(itemName)
	if not template or not basePart then
		return false
	end
	local dropKey = trimKey(itemName, trim)

	--// Normalise to a Model: GetBoundingBox is Model-only, and a lone
	--// MeshPart has no descendants for the weld loop to find
	local model
	if template:IsA("Model") then
		model = template:Clone()
	elseif template:IsA("BasePart") then
		model = Instance.new("Model")
		local only = template:Clone()
		only.Parent = model
		model.PrimaryPart = only
		model:PivotTo(only.CFrame)
	else
		warnOnce("class:" .. itemName,
			("DishMeshes.%s is a %s - it has to be a Model or a MeshPart"):format(itemName, template.ClassName))
		return false
	end

	if trim and not applyTrim(model, itemName, trim) then
		model:Destroy()
		return false --// nothing matched: the caller shows its fallback
	end

	local parts = {}
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
		end
	end
	if #parts == 0 then
		--// An honest ugly cube beats invisible food, so hand the plain
		--// build back to the caller
		warnOnce("empty:" .. itemName,
			("DishMeshes.%s holds no parts - keeping the plain block"):format(itemName))
		model:Destroy()
		return false
	end

	local boxCF, boxSize = model:GetBoundingBox()
	local pivot = model:GetPivot()

	--// Import 3D leaves the pivot wherever the file's origin was, which
	--// can sit well off the food. Welding against that puts the meal an
	--// arm's length from the hand, so measure off the geometry instead.
	local stray = (pivot.Position - boxCF.Position).Magnitude
	if stray > boxSize.Magnitude then
		warnOnce("pivot:" .. itemName,
			("DishMeshes.%s has its pivot %.1f studs off the mesh - using the mesh's centre instead")
				:format(itemName, stray))
		pivot = CFrame.new(boxCF.Position) * pivot.Rotation
	end

	--// Scale is the usual reason a mesh loads yet cannot be seen. The
	--// parts builds are about 1.5 studs across; match that.
	local widest = math.max(boxSize.X, boxSize.Y, boxSize.Z)
	if widest < 0.2 or widest > 12 then
		warnOnce("scale:" .. itemName,
			("DishMeshes.%s is %.2f studs across (%.2f x %.2f x %.2f) - resize it in ServerStorage; the parts builds are about 1.5")
				:format(itemName, widest, boxSize.X, boxSize.Y, boxSize.Z))
	end

	--// How deep this mesh reaches below its pivot decides its plate
	--// drop, same convention as the parts builds (see BottomDepth)
	if meshDrop[dropKey] == nil then
		local depth = pivot.Position.Y - (boxCF.Position.Y - boxSize.Y / 2)
		meshDrop[dropKey] = DishModels.BottomDepth - depth
	end

	--// Deliberately after the meshDrop measurement: plate placement is
	--// measured off the real pivot, never off the lifted grip position
	local anchor = basePart.CFrame
	if forGrip then
		local nudge = GRIP_NUDGE[itemName] or Vector3.zero
		local lift = math.max(boxSize.Y / 2 + GRIP_GAP, GRIP_MIN_LIFT)
		anchor = anchor * CFrame.new(nudge.X, lift + nudge.Y, nudge.Z)
	end

	local allInvisible = true
	for _, inst in ipairs(parts) do
		if inst.Transparency < 1 then
			allInvisible = false
		end
		inst.Anchored = false
		inst.CanCollide = false
		inst.CanQuery = false
		inst.CanTouch = false
		inst.Massless = true
		inst.CastShadow = false
		inst.CFrame = anchor * pivot:ToObjectSpace(inst.CFrame)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = basePart
		weld.Part1 = inst
		weld.Parent = inst
	end

	if allInvisible then
		warnOnce("transparent:" .. itemName,
			("every part of DishMeshes.%s is fully transparent"):format(itemName))
	end

	model.Parent = basePart
	return true
end

--// Dresses ANY base part (a Tool Handle, the pass's Food portion...).
--// True = dressed (the caller should hide the plain base); false = no
--// builder for that name, keep the plain look. A mesh in
--// ServerStorage.DishMeshes wins over the parts build.
--// forGrip: this base part is a Tool Handle in someone's hand, so an
--// imported mesh gets lifted clear of the fist (see GRIP_GAP)
--// trim: show only some of the mesh's parts (see applyTrim). A trim has no
--// parts-build to fall back on, so it simply returns false when it misses.
function DishModels.dress(basePart, itemName, forGrip, trim)
	if dressWithMesh(basePart, itemName, forGrip, trim) then
		return true
	end
	if trim then
		return false
	end
	local builder = itemName and BUILDERS[itemName]
	if not builder or not basePart then
		return false
	end
	builder(basePart)
	return true
end

--// Tool convenience: dresses its Handle
function DishModels.decorate(tool, itemName)
	return DishModels.dress(tool:FindFirstChild("Handle"), itemName, true)
end

return DishModels
