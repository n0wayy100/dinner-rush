--[[
	Dinner Rush - NameTagBoot
	ServerScriptService.Server.NameTagBoot  (Script)

	Starts our player name tags (ServerStorage.Shared.NameTags) - the same
	module runs in both the lobby and the main game.
--]]

local ServerStorage = game:GetService("ServerStorage")
local NameTags = require(ServerStorage:WaitForChild("Shared"):WaitForChild("NameTags"))
NameTags.Start()
print("[NameTags] running")
