--[[
	Dinner Rush - PurchaseBoot (MAIN GAME)
	ServerScriptService.Server.PurchaseBoot

	Starts Robux purchase handling. Deliberately tiny: all the logic lives in
	ServerStorage.Shared.Purchases, which both places share.

	It runs in the restaurant too (not just the lobby shop) because Roblox
	re-delivers an unfinished developer-product receipt to whichever server
	the player is in next - a purchase must be grantable anywhere.

	The ONLY place ProcessReceipt is set. Never set it in another script.
]]

local ServerStorage = game:GetService("ServerStorage")

local Purchases = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Purchases"))

Purchases.Start()
