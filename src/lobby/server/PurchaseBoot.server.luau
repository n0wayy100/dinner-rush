--[[
	Dinner Rush - PurchaseBoot (LOBBY)
	ServerScriptService.Server.PurchaseBoot

	Starts Robux purchase handling. Deliberately tiny: all the logic lives in
	ServerStorage.Shared.Purchases, which both places share.

	The ONLY place ProcessReceipt is set. Never set it in another script.
]]

local ServerStorage = game:GetService("ServerStorage")

local Purchases = require(ServerStorage:WaitForChild("Shared"):WaitForChild("Purchases"))

Purchases.Start()
