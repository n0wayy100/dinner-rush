--[[
	Dinner Rush - OrderPanelServer
	ServerScriptService.Server.OrderPanelServer  (regular Script, server-side)

	Broadcasts the open-order list to every client a few times a second, so
	OrderPanelClient can draw the on-screen ORDER panel (playtest feedback,
	Sep 20 2026: the wall board was easy to miss, especially on mobile).

	ServiceLoop stays the single owner of party state - this reads its
	GetOpenOrders bridge (the same data the wall OrderBoard renders) and
	pushes it out on the OrdersUpdate RemoteEvent. Render-only on the
	client; nothing here is authoritative.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local PANEL = Config.OrderPanel

if not (PANEL and PANEL.Enabled) then
	return
end

print("[OrderPanel] broadcaster started")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

local ordersRemote = remotes:FindFirstChild("OrdersUpdate")
if not ordersRemote then
	ordersRemote = Instance.new("RemoteEvent")
	ordersRemote.Name = "OrdersUpdate"
	ordersRemote.Parent = remotes
end

local getOrders = ServerStorage:WaitForChild("GetOpenOrders", 30)
local ShiftState = ReplicatedStorage:WaitForChild("ShiftState", 30)
if not getOrders or not ShiftState then
	warn("[OrderPanel] missing GetOpenOrders bridge or ShiftState - panel will stay empty")
	return
end

--// A late joiner needs the current list at once, not on their first tick
local function pushTo(player, orders)
	ordersRemote:FireClient(player, orders)
end

local function poll()
	local ok, list = pcall(function()
		return getOrders:Invoke()
	end)
	return (ok and list) or {}
end

game:GetService("Players").PlayerAdded:Connect(function(player)
	pushTo(player, poll())
end)

local interval = 1 / math.max(PANEL.BroadcastHz or 3, 1)
local wasActive = false

while true do
	task.wait(interval)
	local state = ShiftState:GetAttribute("State")
	local active = state == "RUNNING" or state == "CLOSING"
	if active then
		ordersRemote:FireAllClients(poll())
		wasActive = true
	elseif wasActive then
		--// leaving the shift: one empty push so panels clear, then quiet
		ordersRemote:FireAllClients({})
		wasActive = false
	end
end
