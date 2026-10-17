--[[
	Dinner Rush - ProfileBoot (LOBBY)
	ServerScriptService.Server.ProfileBoot

	Starts the savefile. Deliberately tiny: all the logic lives in
	ServerStorage.Shared.Profiles, which both places share.

	This runs in the lobby AND in the restaurant. Same module, same DataStore,
	one profile per player - which is only possible because both places sit in
	one experience (spec 3).
]]

local ServerStorage = game:GetService("ServerStorage")

local Profiles = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Profiles"))

Profiles.Start()
