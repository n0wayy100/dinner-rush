--[[
	Dinner Rush - MinigameSkin
	ReplicatedStorage.Shared.MinigameSkin  (ModuleScript, CLIENT use)

	Puts the minigame ART KIT (Config.MinigameArt) onto code-built minigame
	screens: the wooden frame, the title plaque, the timer bar, slot tiles,
	card backs and the Whack It pots. Owner + teammate art, Oct 2026.

	EVERY PIECE IS OPTIONAL. A piece whose Id is still empty is skipped and
	that part of the screen keeps its old code-drawn look, so the art can
	land one id at a time and nothing breaks in between.

	Stretching: pieces with a SliceCenter are 9-sliced - the corners stay
	crisp and only the plain middle stretches - so one image fits a panel of
	any size. SliceCenter = { left, top, right, bottom } in the image's own
	pixels (see Config.MinigameArt for how to read them off an image).

		MinigameSkin.Has("PotBack")              -- is that piece's id filled in?
		MinigameSkin.Frame(panel)                -- wooden frame round a panel
		MinigameSkin.Plaque(titleLabel)          -- title plaque behind a heading
		MinigameSkin.Bar(track, fill, color)     -- timer track + tinted fill
		MinigameSkin.Apply(imageGui, "SlotTile") -- dress any ImageLabel/Button
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local CHOC = Color3.fromRGB(59, 43, 32)

local MinigameSkin = {}

local function entry(key)
	local art = Config.MinigameArt
	return art and art[key]
end

--// "123", 123 or "rbxassetid://123" -> "rbxassetid://123"; empty -> nil
local function idOf(key)
	local piece = entry(key)
	local id = piece and piece.Id
	if type(id) == "number" then
		return ("rbxassetid://%d"):format(id)
	end
	if type(id) ~= "string" or id == "" then
		return nil
	end
	return id:match("^%d+$") and ("rbxassetid://" .. id) or id
end

function MinigameSkin.Has(key)
	return idOf(key) ~= nil
end

--// Dress an ImageLabel/ImageButton with one piece. Returns false (and
--// changes nothing) while that piece's id is empty.
function MinigameSkin.Apply(gui, key)
	local id = idOf(key)
	if not id then return false end
	local piece = entry(key)
	gui.Image = id
	local slice = piece.SliceCenter
	if type(slice) == "table" and #slice == 4 then
		gui.ScaleType = Enum.ScaleType.Slice
		gui.SliceCenter = Rect.new(slice[1], slice[2], slice[3], slice[4])
		gui.SliceScale = piece.SliceScale or 1
	else
		gui.ScaleType = Enum.ScaleType.Stretch
	end
	return true
end

local function artLabel(key, name)
	local label = Instance.new("ImageLabel")
	label.Name = name
	label.Active = false
	label.BackgroundTransparency = 1
	MinigameSkin.Apply(label, key)
	return label
end

--// THE FRAME. Drawn slightly OUTSIDE the panel, so the wood wraps the
--// panel's content instead of covering its edges - nothing inside has to
--// move to make room. The frame's cream middle becomes the panel's ground.
function MinigameSkin.Frame(panel)
	if not MinigameSkin.Has("Frame") then return false end
	local piece = entry("Frame")
	local border = piece.BorderPx or 26
	local slice = piece.SliceCenter

	local frame = artLabel("Frame", "SkinFrame")
	--// On-screen wood = the wood's thickness IN THE IMAGE x SliceScale. The
	--// slice margins can't stand in for it: the teammate's frame has leaves
	--// on its inner corners, so its margins reach well past the wood.
	local wood = piece.WoodPx or (type(slice) == "table" and slice[1])
	if wood and wood > 0 then
		frame.SliceScale = border / wood
	end
	--// mostly outside; a little overlap so the cream meets the content
	local out = math.floor(border * 0.8)
	frame.Position = UDim2.fromOffset(-out, -out)
	frame.Size = UDim2.new(1, out * 2, 1, out * 2)
	frame.ZIndex = 0
	frame.Parent = panel

	panel.BackgroundTransparency = 1
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("UIStroke") then
			child.Enabled = false
		end
	end
	return true
end

--// THE PLAQUE AS DRAWN: the art at its own proportions (AspectRatio in
--// Config; a wrong guess only changes its width, never distorts it), sat
--// on the panel's top edge over the heading's spot, with the heading moved
--// INTO it. Its width follows its height, so a long title gets smaller
--// letters rather than a stretched sign.
function MinigameSkin.PlaqueAsDrawn(label, piece)
	local plaque = artLabel("Plaque", "SkinPlaque")
	plaque.ScaleType = Enum.ScaleType.Fit --// never stretched, whatever the box

	local position, size, anchor = label.Position, label.Size, label.AnchorPoint
	local w, h = size.X.Scale, size.Y.Scale
	local x0 = position.X.Scale - anchor.X * w
	local y0 = position.Y.Scale - anchor.Y * h
	local signH = h * (piece.Grow or 1.9)
	local top = y0 + h * 1.1 - signH

	plaque.AnchorPoint = Vector2.new(0.5, 0)
	plaque.Position = UDim2.fromScale(x0 + w / 2, top)
	plaque.Size = UDim2.fromScale(w, signH)
	local shape = Instance.new("UIAspectRatioConstraint")
	shape.AspectRatio = piece.AspectRatio or (1024 / 192)
	shape.DominantAxis = Enum.DominantAxis.Height
	shape.Parent = plaque
	plaque.ZIndex = math.max(label.ZIndex, 1)
	plaque.Parent = label.Parent

	--// the heading moves onto the plaque's painted face
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(piece.TextWidth or 0.78, piece.TextHeight or 0.5)
	label.ZIndex = plaque.ZIndex + 1
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	if not label:FindFirstChildOfClass("UIStroke") then
		local outline = Instance.new("UIStroke")
		outline.Thickness = 2
		outline.Color = CHOC
		outline.Parent = label
	end
	label.Parent = plaque
	return true
end

--// THE TITLE PLAQUE: a proper-height SIGN behind the heading, sitting on
--// the panel's top edge (as STAFF ROOM sits on its frame), with the
--// heading re-centred on the board. Sized to the art's own height rather
--// than squeezed into the heading's thin strip - squeezed, a 4:1 sign
--// showed as a dark sliver (owner playtest, Oct 2026). It stretches only
--// SIDEWAYS (SliceCenter spans the full height), so its ends keep their
--// shape however long the title is.
--// The art is the heading's SIBLING (a child would draw over the text);
--// the heading turns white with a dark outline to read on the board.
function MinigameSkin.Plaque(label)
	if not MinigameSkin.Has("Plaque") or not label.Parent then return false end
	local piece = entry("Plaque")

	--// DRAWN AS MADE (default, owner playtest Oct 2026): the plaque keeps
	--// its own shape and is never stretched. Stretching needs the code to
	--// know the image's exact pixel layout, and a generated image rarely
	--// matches what its prompt asked for - so the stretch cut the custom
	--// plaque's bottom edge off. Here nothing can be cut: the title is
	--// written ON the plaque (as its child, so the text draws over it).
	--// Stretch = true in Config brings back the 9-sliced sign below.
	if piece.Stretch ~= true then
		return MinigameSkin.PlaqueAsDrawn(label, piece)
	end

	local plaque = artLabel("Plaque", "SkinPlaque")
	label.ZIndex = math.max(label.ZIndex, 2)
	plaque.ZIndex = label.ZIndex - 1

	local position, size, anchor = label.Position, label.Size, label.AnchorPoint
	local scaleOnly = position.X.Offset == 0 and position.Y.Offset == 0
		and size.X.Offset == 0 and size.Y.Offset == 0
	if scaleOnly then
		--// the heading's box, top-left corner, in its parent's scale
		local w, h = size.X.Scale, size.Y.Scale
		local x0 = position.X.Scale - anchor.X * w
		local y0 = position.Y.Scale - anchor.Y * h
		--// taller than the text, its bottom just under the heading's, so
		--// the extra height rises above the panel's top edge like a sign
		local signH = h * (piece.Grow or 1.9)
		local top = y0 + h * 1.1 - signH
		plaque.AnchorPoint = Vector2.new(0, 0)
		plaque.Position = UDim2.fromScale(x0, top)
		plaque.Size = UDim2.fromScale(w, signH)
		--// the heading moves onto the board's middle, inside its border
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(x0 + w / 2, top + signH / 2)
		label.Size = UDim2.fromScale(w * 0.84, signH * 0.5)
	else
		--// a heading laid out in pixels: just sit behind it
		plaque.AnchorPoint = anchor
		plaque.Position = position
		plaque.Size = size
	end
	plaque.Parent = label.Parent

	--// keep the caps the right thickness for the plaque's height
	local slice = piece.SliceCenter
	local imageHeight = piece.Height
	if type(slice) == "table" and imageHeight then
		local function fit()
			plaque.SliceScale = math.max(plaque.AbsoluteSize.Y / imageHeight, 0.01)
		end
		plaque:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		fit()
	end

	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	if not label:FindFirstChildOfClass("UIStroke") then
		local outline = Instance.new("UIStroke")
		outline.Thickness = 2
		outline.Color = CHOC
		outline.Parent = label
	end
	return true
end

--// One bar piece filling `holder`, its rounded caps kept round at any
--// height by scaling the slice to the bar's real height
local function barArt(holder, key, name)
	local label = artLabel(key, name)
	label.Size = UDim2.fromScale(1, 1)
	label.ZIndex = holder.ZIndex
	label.Parent = holder
	local imageHeight = (entry(key) and entry(key).Height) or 128
	local function fit()
		label.SliceScale = math.max(holder.AbsoluteSize.Y / imageHeight, 0.01)
	end
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	return label
end

--// THE TIMER BAR: the track behind, the fill on top TINTED to the game's
--// own colour. The caller keeps shrinking `fill` exactly as before.
function MinigameSkin.Bar(track, fill, fillColor)
	local skinned = false
	if MinigameSkin.Has("TimerTrack") then
		barArt(track, "TimerTrack", "SkinTrack")
		track.BackgroundTransparency = 1
		skinned = true
	end
	if MinigameSkin.Has("TimerFill") then
		--// one layer above the track art, under either way a ScreenGui
		--// sorts its layers (Sibling or Global)
		fill.ZIndex = track.ZIndex + 1
		local art = barArt(fill, "TimerFill", "SkinFill")
		art.ImageColor3 = fillColor or Color3.new(1, 1, 1)
		fill.BackgroundTransparency = 1
		skinned = true
	end
	return skinned
end

return MinigameSkin
