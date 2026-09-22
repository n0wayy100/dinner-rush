--[[
	Dinner Rush - MusicClient (LOBBY)
	StarterPlayerScripts.Client.MusicClient

	One playlist, playing while they mill about picking classes and parties.
	All the logic lives in ReplicatedStorage.Shared.MusicPlayer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Music = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MusicPlayer"))

Music.Start()
Music.Play("Lobby")
