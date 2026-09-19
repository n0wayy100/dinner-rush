--[[
	Dinner Rush - SfxLocal
	ReplicatedStorage.Shared.SfxLocal        (ModuleScript, CLIENT use)

	One-shot sound effects played LOCALLY, for the player who caused them.

	The server's ServerStorage.Shared.Sfx is for things the whole room should
	hear: an alarm, a truck, a customer storming out. This is the other half -
	feedback on YOUR screen, for YOUR action. A right-or-wrong blip from a
	minigame nobody else can see should not carry across the restaurant, and
	four people answering questions at once should not stack.

	Ids and volumes come from the same Config.Sfx table the server reads, so
	there is one list of sounds for the whole project.

	Usage (client scripts):
		local SfxLocal = require(ReplicatedStorage.Shared.SfxLocal)
		SfxLocal.Play("AnswerRight")

	Always 2D: no position, no falloff, same level wherever the player is
	standing. An empty id or an unknown name is silence plus one warning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local SfxLocal = {}

local warned = {}

local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn(message)
end

--// Accepts "rbxassetid://123" or a bare number, same as everywhere else
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
		("[SfxLocal] '%s' is not an asset id - expected rbxassetid://123"):format(trimmed))
	return nil
end

function SfxLocal.Play(name)
	local settings = Config.Sfx
	if not settings or settings.Enabled == false then
		return nil
	end

	local entry = settings.Sounds[name]
	if not entry then
		warnOnce("unknown:" .. tostring(name),
			("[SfxLocal] no sound called '%s' in Config.Sfx.Sounds"):format(tostring(name)))
		return nil
	end

	local id = normaliseId(entry.Id)
	if not id then
		warnOnce("empty:" .. name,
			("[SfxLocal] '%s' has no asset id yet - staying silent"):format(name))
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = "SfxLocal_" .. name
	sound.SoundId = id
	sound.Volume = (entry.Volume or 1) * (settings.MasterVolume or 1)
	sound.Looped = false   --// a one-shot, whatever Config says
	sound.Parent = SoundService

	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	--// A sound that never loads would otherwise sit here forever
	Debris:AddItem(sound, 15)

	return sound
end

return SfxLocal
