--[[
	Dinner Rush - Sfx
	ServerStorage.Shared.Sfx         SERVER ONLY

	One-shot and looping sound effects, played by the server so every player
	hears the same thing at the same moment. Ids, volumes and falloff all live
	in Config.Sfx - nothing is hard-coded here.

	MAP-AGNOSTIC. Nothing in this module names an instance or a path. Callers
	hand it whatever part they already found by TAG, so dropping the same
	systems into a new map needs no code changes - only the tags.

	Usage:
		local Sfx = require(game:GetService("ServerStorage").Shared.Sfx)

		Sfx.Play("ShiftStart")            -- global, heard everywhere
		Sfx.Play("CustomerAngry", pawn)   -- 3D, at that customer

		local frying = Sfx.Loop("CookFry", stationPart)
		...
		frying:Stop()                     -- always safe, even twice

	3D vs global is decided per sound in Config, not per call: a sound with
	Global = true ignores the target and plays flat for everyone.

	Anything missing is silent, never fatal. An empty Id, an unknown name or a
	target that has since been destroyed each warn once and carry on - a
	missing sound must never take a shift down with it.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Sfx = {}

local SETTINGS = Config.Sfx

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local warned = {}

local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn(message)
end

--// Accepts "rbxassetid://123" or a bare number, because both are things
--// people paste out of the Creator Dashboard. Empty means "not set yet".
local function normaliseId(value)
	if type(value) == "number" then
		return ("rbxassetid://%d"):format(value)
	end
	if type(value) ~= "string" then
		return nil
	end

	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end
	if trimmed:match("^%d+$") then
		return ("rbxassetid://%s"):format(trimmed)
	end
	if trimmed:match("^rbxassetid://%d+$") then
		return trimmed:match("//0$") == nil and trimmed or nil
	end

	warnOnce("id:" .. trimmed,
		("[Sfx] '%s' is not an asset id - expected rbxassetid://123"):format(trimmed))
	return nil
end

--// A caller may hand over a BasePart, a Model, or an Attachment - whatever
--// its own tag lookup produced. Reduce all of that to something a Sound can
--// be parented to.
local function resolveTarget(target)
	if typeof(target) ~= "Instance" then
		return nil
	end
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end
	if target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

--// Builds the Sound but does not start it
local function build(name, target)
	if not SETTINGS.Enabled then
		return nil
	end

	local entry = SETTINGS.Sounds[name]
	if not entry then
		warnOnce("unknown:" .. tostring(name),
			("[Sfx] no sound called '%s' in Config.Sfx.Sounds"):format(tostring(name)))
		return nil
	end

	local id = normaliseId(entry.Id)
	if not id then
		warnOnce("empty:" .. name,
			("[Sfx] '%s' has no asset id yet - staying silent"):format(name))
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = "Sfx_" .. name
	sound.SoundId = id
	sound.Volume = (entry.Volume or 1) * (SETTINGS.MasterVolume or 1)
	sound.Looped = entry.Loop == true

	if entry.Global then
		--// Parented to SoundService: no position, flat for everyone
		sound.Parent = SoundService
		return sound, entry
	end

	local anchor = resolveTarget(target)
	if not anchor then
		--// The system that asked had nothing to point at - a station that was
		--// deleted, a customer already despawned. Falling back to global is
		--// wrong for a positional sound, so say so and stay quiet.
		warnOnce("target:" .. name,
			("[Sfx] '%s' is positional but got no usable part - not played."):format(name)
			.. " Check the tag it should be attached to exists in this map.")
		sound:Destroy()
		return nil
	end

	--// THE FALLOFF. Full volume within MinStuds, silent past MaxStuds,
	--// tapering between. This is what lets the dining room hear the fryer
	--// faintly instead of either fully or not at all.
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = entry.MinStuds or SETTINGS.DefaultMinStuds
	sound.RollOffMaxDistance = entry.MaxStuds or SETTINGS.DefaultMaxStuds
	sound.Parent = anchor

	return sound, entry
end

----------------------------------------------------------------
-- PUBLIC
----------------------------------------------------------------

--// Fire and forget. Cleans itself up whether or not Ended ever fires - a
--// sound that fails to load would otherwise sit in the world forever.
function Sfx.Play(name, target)
	local sound = build(name, target)
	if not sound then
		return nil
	end

	sound.Looped = false --// a one-shot, whatever Config says
	sound:Play()

	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, 30)

	return sound
end

--// Returns a handle with :Stop(). Safe to call Stop more than once, and safe
--// to hold across a target being destroyed.
local Handle = {}
Handle.__index = Handle

function Handle:Stop()
	local sound = self._sound
	self._sound = nil
	if sound and sound.Parent then
		sound:Stop()
		sound:Destroy()
	end
end

function Handle:IsPlaying()
	return self._sound ~= nil and self._sound.Parent ~= nil
end

--// A dead handle, so callers never have to nil-check what Loop returned
local SILENT = setmetatable({ _sound = nil }, Handle)

function Sfx.Loop(name, target)
	local sound = build(name, target)
	if not sound then
		return SILENT
	end

	sound.Looped = true
	sound:Play()

	return setmetatable({ _sound = sound }, Handle)
end

return Sfx
