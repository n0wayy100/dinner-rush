--[[
	Dinner Rush - Purchases
	ServerStorage.Shared.Purchases          SERVER ONLY (ModuleScript)

	Everything bought with Robux goes through this file, in BOTH places (the
	lobby and the restaurant each run a PurchaseBoot that calls Start). It is
	built so a client cannot fake a purchase:

	  * NOTHING the client says grants anything. There is no "I bought it"
	    remote. The client may only ask for a purchase WINDOW to open
	    (PurchaseRemote "Prompt"), and only for an item listed in
	    Config.Monetization with a real id - Roblox then handles the payment.
	  * GAME PASSES: ownership is asked of Roblox, server-side
	    (UserOwnsGamePassAsync), and cached on the server. The Pass_<Key>
	    attributes on the Player exist ONLY so the shop can draw "Owned" -
	    no server code ever reads them (a client can fake its own copy).
	    If Roblox cannot be reached, the answer is "not owned" (fail closed).
	  * DEVELOPER PRODUCTS: granted only inside MarketplaceService
	    .ProcessReceipt - Roblox's own server-to-server callback - through
	    Profiles.ProcessPurchaseAsync, which grants each receipt EXACTLY ONCE
	    and tells Roblox "granted" only after the save is confirmed.

	Usage (server scripts):
		local Purchases = require(game:GetService("ServerStorage").Shared.Purchases)
		if Purchases.OwnsPass(player, "VIP") then ... end   -- yields on a cold cache

	RULE: only ONE script per server may set ProcessReceipt. That is Start()
	here. Never set it anywhere else, or one of them silently stops working.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Profiles = require(script.Parent.Profiles)
local ProfileAPI = require(script.Parent.ProfileAPI)

local MON = Config.Monetization

local Purchases = {}

----------------------------------------------------------------
-- Lookups (built once; id 0 = not created on the Creator Hub yet)
----------------------------------------------------------------
local productById = {} --// [productId] = { Key, Def }
for key, product in pairs(MON.Products) do
	if product.Id > 0 then
		productById[product.Id] = { Key = key, Def = product }
	end
end

local passKeyById = {} --// [passId] = passKey
for key, pass in pairs(MON.GamePasses) do
	if pass.Id > 0 then
		passKeyById[pass.Id] = key
	end
end

local remote do
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	remote = remotes:FindFirstChild("PurchaseRemote")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "PurchaseRemote"
		remote.Parent = remotes
	end
end

----------------------------------------------------------------
-- GAME PASSES - ownership comes from Roblox, never from the client
----------------------------------------------------------------
local passCache = {} --// [player][passKey] = { Owns = bool, At = os.clock() }

--// Roblox's answer, with a couple of retries. nil = could not reach Roblox.
local function askRoblox(player, passId)
	for attempt = 1, 3 do
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync,
			MarketplaceService, player.UserId, passId)
		if ok then
			return owns == true
		end
		task.wait(attempt)
	end
	return nil
end

local function remember(player, passKey, owns)
	local mine = passCache[player]
	if not mine then
		mine = {}
		passCache[player] = mine
	end
	mine[passKey] = { Owns = owns, At = os.clock() }
	if player.Parent == Players then
		player:SetAttribute("Pass_" .. passKey, owns) --// DISPLAY ONLY (see header)
	end
end

--// THE server-side ownership check. Yields when the cache is cold.
function Purchases.OwnsPass(player, passKey)
	local pass = MON.GamePasses[passKey]
	if not pass or pass.Id <= 0 then return false end
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return false
	end

	local entry = passCache[player] and passCache[player][passKey]
	if entry and entry.Owns then
		return true --// a bought pass stays bought for the session
	end
	if entry and os.clock() - entry.At < (MON.PassCacheSeconds or 300) then
		return entry.Owns
	end

	local owns = askRoblox(player, pass.Id)
	if owns == nil then
		warn(("[Purchases] could not reach Roblox to check %s for %s - treating as not owned")
			:format(passKey, player.Name))
		return entry and entry.Owns or false --// FAIL CLOSED
	end
	remember(player, passKey, owns)
	return owns
end

----------------------------------------------------------------
-- DEVELOPER PRODUCTS - granted only from Roblox's receipt callback
----------------------------------------------------------------
local function grantFor(player, def)
	return function()
		if def.Coins then
			if not ProfileAPI.Deposit(player, def.Coins) then
				error("the wallet deposit was refused") --// -> NotProcessedYet, retried
			end
			return
		end
		error("this product has no grant defined in Config.Monetization")
	end
end

local function processReceipt(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		--// not on this server: Roblox retries when they next join one
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local entry = productById[receipt.ProductId]
	if not entry then
		--// a product sold without a Config entry - never silently "grant"
		--// nothing. Unprocessed receipts are eventually refunded by Roblox.
		warn(("[Purchases] receipt for UNKNOWN product %s (%s) - add it to Config.Monetization.Products")
			:format(tostring(receipt.ProductId), player.Name))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local decision = Profiles.ProcessPurchaseAsync(player, receipt.PurchaseId,
		grantFor(player, entry.Def))

	if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
		print(("[Purchases] %s bought %s (receipt %s)"):format(
			player.Name, entry.Key, tostring(receipt.PurchaseId)))
		if player.Parent == Players then
			remote:FireClient(player, "ProductGranted", entry.Key)
		end
	end
	return decision
end

----------------------------------------------------------------
-- PROMPTS - the client may only ASK for a purchase window
----------------------------------------------------------------
local lastPrompt = {} --// [player] = os.clock()

local function onRemote(player, action, key)
	if action ~= "Prompt" or type(key) ~= "string" then return end

	local now = os.clock()
	if now - (lastPrompt[player] or 0) < (MON.PromptCooldownSeconds or 1.5) then
		return --// spam guard
	end
	lastPrompt[player] = now

	local pass = MON.GamePasses[key]
	if pass then
		if pass.Id <= 0 then return end
		if Purchases.OwnsPass(player, key) then
			remote:FireClient(player, "PassOwned", key)
			return
		end
		MarketplaceService:PromptGamePassPurchase(player, pass.Id)
		return
	end

	local product = MON.Products[key]
	if product and product.Id > 0 then
		MarketplaceService:PromptProductPurchase(player, product.Id)
	end
	--// anything else: not on the menu, ignored
end

--// Fired by ROBLOX (server-side) when a pass prompt closes. Even so, the
--// cache is refreshed by asking Roblox again rather than trusting the flag.
local function onPassPromptFinished(player, passId, wasPurchased)
	local passKey = passKeyById[passId]
	if not passKey or not wasPurchased then return end
	if passCache[player] then
		passCache[player][passKey] = nil
	end
	if Purchases.OwnsPass(player, passKey) then
		print(("[Purchases] %s bought the %s pass"):format(player.Name, passKey))
		remote:FireClient(player, "PassOwned", passKey)
	end
end

----------------------------------------------------------------
-- START (called once per server by PurchaseBoot)
----------------------------------------------------------------
local started = false

function Purchases.Start()
	if started then return end
	started = true

	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPromptFinished)
	remote.OnServerEvent:Connect(onRemote)

	--// warm the pass cache on join so the shop can show "Owned" at once
	local function onJoin(player)
		for _, passKey in pairs(passKeyById) do
			task.spawn(Purchases.OwnsPass, player, passKey)
		end
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, player in ipairs(Players:GetPlayers()) do
		onJoin(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		passCache[player] = nil
		lastPrompt[player] = nil
	end)

	local passes, products = 0, 0
	for _ in pairs(passKeyById) do passes += 1 end
	for _ in pairs(productById) do products += 1 end
	print(("[Purchases] started - %d pass(es), %d product(s) live"):format(passes, products))
end

return Purchases
