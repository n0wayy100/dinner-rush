--[[
	Dinner Rush - RecipeBoardService
	ServerScriptService.Server.RecipeBoardService   (regular Script, server-side)

	THE RECIPE CHART on the kitchen wall. Read-only: no prompt, no clicks,
	nothing to interact with. It is there so a new player can look up what
	goes where without opening a menu.

	Each row reads:   [raw ingredient]  +  [cook station]  =  [dish]

	Build contract:
	  Tag a wall part  RecipeBoard  (Config.RecipeBoard.Tag). Anchored.
	  Optional attribute  ScreenFace  ("Front"/"Back"/"Left"/"Right"/
	  "Top"/"Bottom") picks the side; without it the widest face wins,
	  the same rule the supplier screen uses.

	EVERY MAP GETS ITS OWN CHART FOR FREE. The rows come from
	Config.MenuForMap(MatchMapId) - the same menu the customers order from
	and the fridge stocks - so Yamasaki shows ramen, Route 67 shows burgers,
	and neither is written down twice. A new map needs a Menu in Config.Maps
	and a tagged wall part; no code, no per-map list.

	Built on the SERVER because it is identical for everyone and never
	changes: one build replicates to every client, rather than each of them
	drawing the same static chart.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local BOARD = Config.RecipeBoard
local TAG = BOARD.Tag

--// House palette, the same one the lobby panels use
local CREAM = Color3.fromRGB(247, 236, 214)
local PAPER = Color3.fromRGB(255, 250, 240)
local INK = Color3.fromRGB(59, 43, 32)
local RED = Color3.fromRGB(229, 72, 77)
local FADED = Color3.fromRGB(140, 118, 96)
local FONT = Enum.Font.FredokaOne

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function resolvePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

--// A chart belongs on the widest side of a slab, so work it out from the
--// part's own dimensions rather than making anyone guess.
local function largestFace(part)
	local size = part.Size
	local faces = {
		{ face = Enum.NormalId.Front, area = size.X * size.Y },
		{ face = Enum.NormalId.Back, area = size.X * size.Y },
		{ face = Enum.NormalId.Left, area = size.Z * size.Y },
		{ face = Enum.NormalId.Right, area = size.Z * size.Y },
		{ face = Enum.NormalId.Top, area = size.X * size.Z },
		{ face = Enum.NormalId.Bottom, area = size.X * size.Z },
	}
	table.sort(faces, function(a, b) return a.area > b.area end)
	return faces[1].face
end

local function resolveFace(part)
	local wanted = part:GetAttribute("ScreenFace")
	if type(wanted) == "string" then
		local named = Enum.NormalId[wanted]
		if named then
			return named
		end
		warn(("[RecipeBoard] %s has ScreenFace '%s', which is not a face - using the widest")
			:format(part:GetFullName(), wanted))
	end
	return largestFace(part)
end

local function imageOrNil(value)
	if type(value) ~= "string" or value == "" or value:match("//0$") then
		return nil
	end
	return value
end

----------------------------------------------------------------
-- WHAT GOES ON THE CHART
----------------------------------------------------------------

--// One row per dish on THIS map's menu, commonest order first so the thing
--// a new player sees most is at the top.
local function rowsForMap(mapId)
	local menu = Config.MenuForMap(mapId) or {}
	local rows = {}

	for dishName, weight in pairs(menu) do
		local recipe = Config.Recipes[dishName]
		if recipe then
			local ingredient = Config.Ingredients[recipe.Ingredient]
			local method = Config.CookMethodDisplay[recipe.Method]
			table.insert(rows, {
				Weight = weight,
				DishName = recipe.Display or dishName,
				DishIcon = imageOrNil(recipe.Icon),
				IngredientName = ingredient and ingredient.Display or recipe.Ingredient,
				IngredientIcon = ingredient and imageOrNil(ingredient.Icon),
				Source = ingredient and Config.IngredientSourceDisplay[ingredient.Source] or nil,
				StationLabel = method and method.Label or string.upper(tostring(recipe.Method)),
				StationIcon = method and imageOrNil(method.IconId) or nil,
			})
		else
			warn(("[RecipeBoard] map '%s' lists dish '%s', which is not in Config.Recipes")
				:format(tostring(mapId), tostring(dishName)))
		end
	end

	table.sort(rows, function(a, b)
		if a.Weight ~= b.Weight then
			return a.Weight > b.Weight
		end
		return a.DishName < b.DishName
	end)

	while #rows > (BOARD.MaxRows or 6) do
		table.remove(rows)
	end
	return rows
end

----------------------------------------------------------------
-- DRAWING
----------------------------------------------------------------

--// An icon if there is art, the name in text if there is not. Every slot on
--// the chart degrades this way, so a missing upload is a readable word
--// rather than a blank square.
local function makeSlot(parent, order, widthScale, icon, caption, captionColor)
	local holder = Instance.new("Frame")
	holder.Name = "Slot"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(widthScale, 1)
	holder.LayoutOrder = order
	holder.Parent = parent

	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.AnchorPoint = Vector2.new(0.5, 0)
	art.Position = UDim2.fromScale(0.5, 0.02)
	art.Size = UDim2.fromScale(0.72, 0.62)
	art.ScaleType = Enum.ScaleType.Fit
	art.Image = icon or ""
	art.Visible = icon ~= nil
	art.Parent = holder

	local label = Instance.new("TextLabel")
	label.Name = "Caption"
	label.BackgroundTransparency = 1
	--// With no icon the text takes the whole tile instead of a strip
	label.Position = UDim2.fromScale(0, icon and 0.64 or 0.2)
	label.Size = UDim2.fromScale(1, icon and 0.34 or 0.6)
	label.Font = FONT
	label.TextScaled = true
	label.TextColor3 = captionColor or INK
	label.Text = caption or ""
	label.Parent = holder

	return holder
end

local function makeGlyph(parent, order, text)
	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(0.08, 1)
	glyph.LayoutOrder = order
	glyph.Font = FONT
	glyph.TextScaled = true
	glyph.TextColor3 = RED
	glyph.Text = text
	glyph.Parent = parent
	return glyph
end

local function drawRow(parent, row, order)
	local strip = Instance.new("Frame")
	strip.Name = row.DishName .. "Row"
	strip.BackgroundColor3 = PAPER
	strip.BorderSizePixel = 0
	strip.Size = UDim2.new(1, 0, 0, 0)
	strip.LayoutOrder = order
	strip.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = strip

	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = 2
	stroke.Parent = strip

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = strip

	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.Parent = strip

	--// raw ingredient  +  station  =  dish
	local ingredientCaption = row.IngredientName
	if BOARD.ShowSource and row.Source then
		ingredientCaption = ("%s\n%s"):format(row.IngredientName, row.Source)
	end

	makeSlot(strip, 1, 0.28, row.IngredientIcon, ingredientCaption, INK)
	makeGlyph(strip, 2, "+")
	makeSlot(strip, 3, 0.26, row.StationIcon, row.StationLabel, RED)
	makeGlyph(strip, 4, "=")
	makeSlot(strip, 5, 0.30, row.DishIcon, row.DishName, INK)

	return strip
end

local function build(part, mapId)
	--// Idempotent: a rebuild (map change, re-run) replaces rather than stacks
	local existing = part:FindFirstChild("RecipeBoardGui")
	if existing then
		existing:Destroy()
	end

	local rows = rowsForMap(mapId)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "RecipeBoardGui"
	gui.Face = resolveFace(part)
	gui.LightInfluence = 0          --// readable in a dim kitchen
	gui.PixelsPerStud = BOARD.PixelsPerStud
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	--// STATIC BY DESIGN: nothing here takes a click, so it can never swallow
	--// a prompt or freeze the camera in shift lock.
	gui.Active = false
	gui.Adornee = part
	gui.Parent = part

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = CREAM
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.PaddingTop = UDim.new(0.05, 0)
	pad.PaddingBottom = UDim.new(0.05, 0)
	pad.Parent = panel

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.BackgroundColor3 = RED
	header.BorderSizePixel = 0
	header.Size = UDim2.fromScale(1, 0.16)
	header.Font = FONT
	header.TextScaled = true
	header.TextColor3 = Color3.new(1, 1, 1)
	local map = Config.MapById and Config.MapById(mapId)
	header.Text = map and ("%s  %s"):format(string.upper(map.Display), BOARD.Title)
		or BOARD.Title
	header.Parent = panel

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 8)
	headerCorner.Parent = header

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0, 0.19)
	list.Size = UDim2.fromScale(1, 0.81)
	list.Parent = panel

	local lay = Instance.new("UIListLayout")
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0.03, 0)
	lay.Parent = list

	if #rows == 0 then
		local empty = Instance.new("TextLabel")
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.fromScale(1, 0.4)
		empty.Font = FONT
		empty.TextScaled = true
		empty.TextColor3 = FADED
		empty.Text = "No menu for this map yet"
		empty.Parent = list
		warn(("[RecipeBoard] map '%s' has no usable menu - chart is empty"):format(tostring(mapId)))
	else
		--// Rows share the height evenly, so three dishes or six both fill it
		local share = (1 - (lay.Padding.Scale * (#rows - 1))) / #rows
		for index, row in ipairs(rows) do
			local strip = drawRow(list, row, index)
			strip.Size = UDim2.fromScale(1, share)
		end
	end

	print(("[RecipeBoard] %s: %d dish(es) for map '%s' on %s")
		:format(part:GetFullName(), #rows, tostring(mapId), gui.Face.Name))
end

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------

local built = {}   --// part -> true, so a re-scan does not redraw needlessly

local function setup(instance, mapId)
	local part = resolvePart(instance)
	if not part then
		warn(("[RecipeBoard] %s is tagged %s but has no BasePart - skipped")
			:format(instance:GetFullName(), TAG))
		return
	end

	local ok, err = pcall(build, part, mapId)
	if not ok then
		--// One bad board must not take the others with it
		warn(("[RecipeBoard] %s failed to draw: %s"):format(part:GetFullName(), tostring(err)))
		return
	end
	built[part] = true
end

local function buildAll()
	local mapId = workspace:GetAttribute("MatchMapId") or Config.DefaultMapId
	for _, instance in ipairs(CollectionService:GetTagged(TAG)) do
		if instance:IsDescendantOf(workspace) then
			setup(instance, mapId)
		end
	end
end

task.spawn(function()
	--// The map is cloned in when the first player arrives, so the tag can
	--// appear well after this script starts. Same patient wait the other
	--// services use rather than scanning once and giving up.
	local waited = 0
	while waited < 20 do
		if #CollectionService:GetTagged(TAG) > 0
			and workspace:GetAttribute("MatchMapId") then
			break
		end
		task.wait(0.5)
		waited += 0.5
	end

	if #CollectionService:GetTagged(TAG) == 0 then
		warn(("[RecipeBoard] no part tagged %s - this map has no recipe chart"):format(TAG))
		return
	end

	buildAll()
end)

--// A board tagged later (or a map swapped in) still gets drawn
CollectionService:GetInstanceAddedSignal(TAG):Connect(function(instance)
	if instance:IsDescendantOf(workspace) then
		setup(instance, workspace:GetAttribute("MatchMapId") or Config.DefaultMapId)
	end
end)

--// The map decides the menu, so a late MatchMapId means a redraw
workspace:GetAttributeChangedSignal("MatchMapId"):Connect(function()
	if next(built) then
		buildAll()
	end
end)
