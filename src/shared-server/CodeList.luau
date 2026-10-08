--[[
	Dinner Rush - CodeList
	ServerStorage.Shared.CodeList  (ModuleScript, SERVER ONLY)

	The promo codes. This lives in ServerStorage on purpose: anything in
	ReplicatedStorage (like Config) is readable by every client, so codes
	there would be public the moment the game ships.

	Add a code = add a row. The key is the code players type (matching is
	case-insensitive; spaces are ignored). Each code works ONCE per player
	(ProfileAPI.RedeemCode records it in the save).

	  Coins     coins added to the wallet
	  Keys      free crate keys
	  Expires   os.time() after which it stops working (nil = never)
--]]

return {
	LAUNCH = { Coins = 500 },
	DINNERRUSH = { Coins = 250, Keys = 1 },
	--// EXAMPLE with an expiry (1 Jan 2027, 00:00 UTC):
	-- HALLOWEEN = { Coins = 400, Expires = 1798761600 },
}
