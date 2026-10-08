--[[
	Dinner Rush - ToolModels
	ServerStorage.Shared.ToolModels  (ModuleScript)

	The team's own 3D tool models (Oct 2026): the same model hangs on its
	wall mount AND sits in the player's hand, instead of a code-built block
	that looked nothing like the prop in the map.

	Drop each imported model into ServerStorage.ToolModels named EXACTLY:
	  Extinguisher, Plunger, Broom, Vacuum, CautionCone
	A model that is not there keeps the old code-built look - nothing breaks.
	Models live in the place (like ServerStorage.DishMeshes), not loaded by
	id: InsertService is a backdoor primitive the security scan flags, and a
	runtime load could fail mid-shift.

	A model may carry a small part named "Grip" (from Blender): that is where
	the hand closes. It is hidden; without one the model's pivot is used.

		ToolModels.Get(name)                 -- the template, or nil
		ToolModels.Dress(tool, name)         -- put the model on a Tool's Handle
		ToolModels.ShowAtMount(part, name)   -- a display copy on a wall mount;
		                                        returns { Show(), Hide() } or nil

	Per-tool turns live in Config.ToolModels (a model imported facing the
	wrong way is one number to fix, not code).
--]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ToolModels = {}

--// Things a display or held copy must not carry over from an import
local STRIP = { "LuaSourceContainer", "ProximityPrompt", "ClickDetector", "Tool" }

local function settingsFor(name)
	return (Config.ToolModels and Config.ToolModels[name]) or {}
end

--// { x, y, z } in degrees -> a rotation (nil/empty = none)
local function turnOf(degrees)
	if type(degrees) ~= "table" then
		return CFrame.identity
	end
	return CFrame.Angles(math.rad(degrees[1] or 0), math.rad(degrees[2] or 0), math.rad(degrees[3] or 0))
end

function ToolModels.Get(name)
	local folder = ServerStorage:FindFirstChild("ToolModels")
	local template = folder and folder:FindFirstChild(name)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

--// A clean working copy: always a Model, scripts and prompts stripped, and
--// the Grip marker (if any) handed back separately
local function cleanCopy(name)
	local template = ToolModels.Get(name)
	if not template then return nil end

	local model
	if template:IsA("Model") then
		model = template:Clone()
	else
		model = Instance.new("Model")
		template:Clone().Parent = model
	end
	model.Name = name

	for _, descendant in ipairs(model:GetDescendants()) do
		for _, class in ipairs(STRIP) do
			if descendant:IsA(class) then
				descendant:Destroy()
				break
			end
		end
	end

	local grip = model:FindFirstChild("Grip", true)
	if grip and not grip:IsA("BasePart") then
		grip = nil
	end

	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant ~= grip then
			table.insert(parts, descendant)
		end
	end
	if #parts == 0 then
		warn(("[ToolModels] ToolModels.%s has no parts - keeping the old look"):format(name))
		model:Destroy()
		return nil
	end
	return model, parts, grip
end

--// For callers that place the model themselves (the cone, the ultimate's
--// vacuum): model, its parts (Grip excluded), and the Grip part or nil
function ToolModels.Copy(name)
	return cleanCopy(name)
end

----------------------------------------------------------------
-- IN THE HAND
----------------------------------------------------------------

--// The tool's code-built Handle stays as the (now invisible) grip and every
--// other code-built part hides; the model rides on the Handle with its Grip
--// marker at the Handle's centre. True = dressed. turnOverride ({x,y,z}
--// degrees) and offsetOverride ({x,y,z} studs) beat Config - the Studio
--// tuning command uses them.
function ToolModels.Dress(tool, name, turnOverride, offsetOverride)
	local handle = tool and tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then return false end
	local model, parts, grip = cleanCopy(name)
	if not model then return false end

	for _, codePart in ipairs(tool:GetDescendants()) do
		if codePart:IsA("BasePart") then
			codePart.Transparency = 1
		end
	end

	local anchor = grip and grip.CFrame or model:GetPivot() --// where the hand goes
	local turn = turnOf(turnOverride or settingsFor(name).GripTurn)
	--// GripOffset nudges the whole model in the hand's own space (studs):
	--// e.g. forward so it stops clipping the fist
	local offset = offsetOverride or settingsFor(name).GripOffset
	local shift = type(offset) == "table"
		and CFrame.new(offset[1] or 0, offset[2] or 0, offset[3] or 0) or CFrame.identity
	for _, part in ipairs(parts) do
		part.CFrame = handle.CFrame * shift * turn * anchor:ToObjectSpace(part.CFrame)
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = part
	end
	if grip then
		grip:Destroy()
	end

	model.Parent = handle --// goes wherever the tool goes, dies with it
	return true
end

----------------------------------------------------------------
-- ON THE WALL MOUNT
----------------------------------------------------------------

--// A display copy standing on the mount: the bottom of the model sits at
--// the mount part's centre, facing the way the mount's FRONT face points.
--// Make the mount a small invisible marker where the tool's foot rests.
function ToolModels.ShowAtMount(mountPart, name)
	if settingsFor(name).ShowOnMount == false then return nil end
	if not mountPart or not mountPart:IsA("BasePart") then return nil end
	local model, parts, grip = cleanCopy(name)
	if not model then return nil end
	if grip then
		grip:Destroy()
	end

	for _, part in ipairs(parts) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false --// never blocks the mount's own E prompt
		part.CanTouch = false
	end

	--// Face the mount's front, then drop the model's bounding-box BOTTOM
	--// onto the mount's centre - whatever pivot the import arrived with
	local look = mountPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	local facing = CFrame.lookAt(Vector3.zero, flat.Unit) * turnOf(settingsFor(name).MountTurn)
	model:PivotTo(CFrame.new(model:GetPivot().Position) * facing)
	local boxCF, boxSize = model:GetBoundingBox()
	local bottom = boxCF.Position - Vector3.new(0, boxSize.Y / 2, 0)
	model:PivotTo(model:GetPivot() + (mountPart.Position - bottom))

	model.Name = name .. "Display"
	model.Parent = mountPart.Parent

	local original = {}
	for _, part in ipairs(parts) do
		original[part] = part.Transparency
	end
	local display = {}
	function display.Show()
		for part, value in pairs(original) do
			if part.Parent then part.Transparency = value end
		end
	end
	function display.Hide()
		for part in pairs(original) do
			if part.Parent then part.Transparency = 1 end
		end
	end
	return display
end

----------------------------------------------------------------
-- THE PROP ON THE WALL
--
-- The model the builder already placed and tagged (BroomMount, ...) IS the
-- display: it disappears while its tool is out and comes back once every
-- copy has gone home - returned, the event over, or its carrier gone.
-- ONE OF EACH (owner, Oct 2026): the mount's E prompt goes away with it, so
-- nobody else can take one until it is back.
-- (A first version stood a SECOND copy on the mount, which floated above
-- the real one - owner playtest, Oct 2026.)
----------------------------------------------------------------

--// returnable = true (the vacuum): instead of switching the mount's prompt
--// OFF while the tool is out, it turns into "Put back" for the HOLDER only
--// (the prompt carries their UserId in an OnlyFor attribute, and
--// ToolMountClient hides it from everyone else).
function ToolModels.MountTracker(tagName, returnable)
	local holderOf = {} --// tool -> the player carrying it
	local out = {}    --// tool -> true while it is in someone's hands
	local hidden = {} --// part -> its original transparency
	local muted = {}  --// prompt -> whether it was on before we hid it

	--// collected when needed, so a map cloned in late is still found
	local function propParts()
		local list = {}
		for _, tagged in ipairs(CollectionService:GetTagged(tagName)) do
			if tagged:IsDescendantOf(workspace) then
				if tagged:IsA("BasePart") then
					table.insert(list, tagged)
				end
				for _, d in ipairs(tagged:GetDescendants()) do
					if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
						table.insert(list, d)
					end
				end
			end
		end
		return list
	end

	--// the mount's E prompt(s): wherever the setup code parented them
	local function mountPrompts()
		local list = {}
		for _, tagged in ipairs(CollectionService:GetTagged(tagName)) do
			if tagged:IsDescendantOf(workspace) then
				for _, d in ipairs(tagged:GetDescendants()) do
					if d:IsA("ProximityPrompt") then
						table.insert(list, d)
					end
				end
			end
		end
		return list
	end

	local function setHidden(on)
		if on then
			for _, part in ipairs(propParts()) do
				if hidden[part] == nil then
					hidden[part] = part.Transparency
					part.Transparency = 1
				end
			end
			for _, prompt in ipairs(mountPrompts()) do
				if muted[prompt] == nil then
					if returnable then
						muted[prompt] = prompt.ActionText
						local holder = nil
						for tool in pairs(out) do
							holder = holderOf[tool]
						end
						prompt.ActionText = "Put back"
						prompt:SetAttribute("OnlyFor", holder and holder.UserId or nil)
					else
						muted[prompt] = prompt.Enabled
						prompt.Enabled = false
					end
				end
			end
		else
			for part, value in pairs(hidden) do
				if part.Parent then part.Transparency = value end
			end
			hidden = {}
			for prompt, was in pairs(muted) do
				if prompt.Parent then
					if returnable then
						prompt.ActionText = was
						prompt:SetAttribute("OnlyFor", nil)
					else
						prompt.Enabled = was
					end
				end
			end
			muted = {}
		end
	end

	local tracker = {}
	--// true while ANY copy is in someone's hands - give functions refuse
	--// then, so the Fixer's Toolbelt cannot conjure a second one either
	function tracker.IsOut()
		for tool in pairs(out) do
			if tool:IsDescendantOf(game) then
				return true
			end
		end
		return false
	end
	--// A tool just left the mount: hide the prop until it (and any other
	--// copy) is gone from the game. The mount's E prompt keeps working.
	function tracker.Add(tool, holder)
		out[tool] = true
		holderOf[tool] = holder
		setHidden(true)
		tool.AncestryChanged:Connect(function()
			if out[tool] and not tool:IsDescendantOf(game) then
				out[tool] = nil
				holderOf[tool] = nil
				if next(out) == nil then
					setHidden(false)
				end
			end
		end)
	end
	return tracker
end

--// STUDIO-ONLY TUNING: re-tilt whatever tool the player is HOLDING, live, to
--// find its GripTurn without restarting. Command bar, SERVER view:
--//   print(game.ServerStorage.DebugToolTurn:Invoke(0, 0, 0))
--//   print(game.ServerStorage.DebugToolTurn:Invoke(0, 180, 0, 0, 0, -0.6))
--// The first three are the TURN in degrees (X, Y, Z); the optional last
--// three are the POSITION nudge in studs. When it looks right, copy them
--// into that tool's GripTurn / GripOffset in Config.ToolModels.
if game:GetService("RunService"):IsStudio()
	and not ServerStorage:FindFirstChild("DebugToolTurn") then
	local debugTurn = Instance.new("BindableFunction")
	debugTurn.Name = "DebugToolTurn"
	debugTurn.OnInvoke = function(x, y, z, ox, oy, oz)
		local player = game:GetService("Players"):GetPlayers()[1]
		local character = player and player.Character
		local tool = character and character:FindFirstChildOfClass("Tool")
		local handle = tool and tool:FindFirstChild("Handle")
		if not handle then
			return "hold a tool first (equip it so it is in your hand)"
		end
		local name = tool.Name
		if not ToolModels.Get(name) then
			return ("no ServerStorage.ToolModels.%s - nothing to turn"):format(name)
		end
		local old = handle:FindFirstChild(name)
		if old then
			old:Destroy()
		end
		local turn = { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
		local shift = { tonumber(ox) or 0, tonumber(oy) or 0, tonumber(oz) or 0 }
		ToolModels.Dress(tool, name, turn, shift)
		return ("%s: GripTurn = { %g, %g, %g }, GripOffset = { %g, %g, %g } - copy into Config.ToolModels.%s")
			:format(name, turn[1], turn[2], turn[3], shift[1], shift[2], shift[3], name)
	end
	debugTurn.Parent = ServerStorage
end

return ToolModels
