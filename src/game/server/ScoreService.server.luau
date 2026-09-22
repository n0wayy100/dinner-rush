--[[
	Dinner Rush - ScoreService
	ServerScriptService.Server.ScoreService  (Script)

	The HIDDEN shift score (owner ruling: never shown during play). Every
	credited moment - the same creditStat calls that write careers and
	charge ultimates - also fires ServerStorage.AddScore into here, plus
	a few score-only moments (seats, orders taken, good/overcooked
	collects) that have no career stat. Points come from
	Config.Score.PointsPer; a key with no mapping scores nothing.

	At shift end ServiceLoop invokes ServerStorage.GetShiftAwards and
	ships the result to every client inside the ShiftReport payload:
	  - one title per player (Config.Score.Titles claimed greedily by
	    category leaders; warm fallbacks for everyone else)
	  - the MVP (top score) with receipt lines - evidence, never points

	Scores reset when a new shift goes RUNNING, same trigger the charge
	system uses. Nothing here talks to clients directly.
--]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local SCORE = Config.Score

local scores = {} --// [player] = hidden points
local tally = {}  --// [player] = { statKey = count } for titles + receipts

local function resetAll()
	scores = {}
	tally = {}
end

Players.PlayerRemoving:Connect(function(player)
	scores[player] = nil
	tally[player] = nil
end)

----------------------------------------------------------------
-- The score bus: fire-and-forget from every credit chokepoint
----------------------------------------------------------------
do
	local bus = Instance.new("BindableEvent")
	bus.Name = "AddScore"
	bus.Event:Connect(function(player, key, amount)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
		local points = SCORE.PointsPer[key]
		if not points then return end --// uncounted keys (CustomersServed etc.)

		amount = math.max(tonumber(amount) or 1, 1)
		scores[player] = (scores[player] or 0) + points * amount

		local mine = tally[player]
		if not mine then
			mine = {}
			tally[player] = mine
		end
		mine[key] = (mine[key] or 0) + amount
	end)
	bus.Parent = ServerStorage
end

----------------------------------------------------------------
-- The awards: computed once, at shift end, on request
----------------------------------------------------------------
local function categoryCount(player, keys)
	local mine = tally[player]
	if not mine then return 0 end
	local total = 0
	for _, key in ipairs(keys) do
		total += mine[key] or 0
	end
	return total
end

local function buildAwards()
	local everyone = Players:GetPlayers()
	if #everyone == 0 then return nil end

	--// TITLES: each category in priority order goes to the best untitled
	--// player who actually did the thing; leftovers get warm fallbacks
	local titled = {} --// [player] = { Name, Emoji }
	for _, category in ipairs(SCORE.Titles) do
		local best, bestCount = nil, 0
		for _, member in ipairs(everyone) do
			if not titled[member] then
				local count = categoryCount(member, category.Keys)
				if count > bestCount then
					best, bestCount = member, count
				end
			end
		end
		if best then
			titled[best] = { Name = category.Name, Emoji = category.Emoji }
		end
	end
	local fallbackIndex = 0
	for _, member in ipairs(everyone) do
		if not titled[member] then
			fallbackIndex += 1
			local fallback = SCORE.FallbackTitles[fallbackIndex]
				or SCORE.FallbackTitles[#SCORE.FallbackTitles]
			titled[member] = { Name = fallback.Name, Emoji = fallback.Emoji }
		end
	end

	--// MVP: top hidden score; join order breaks ties (they were here first)
	local mvp, mvpScore = nil, -math.huge
	for _, member in ipairs(everyone) do
		local score = scores[member] or 0
		if score > mvpScore then
			mvp, mvpScore = member, score
		end
	end

	--// RECEIPTS: the MVP's biggest point-earners as friendly lines. The
	--// evidence ships; the math stays home.
	local receipts = {}
	if mvp then
		local mine = tally[mvp] or {}
		local entries = {}
		for key, count in pairs(mine) do
			local points = SCORE.PointsPer[key] or 0
			if points > 0 and SCORE.ReceiptText[key] then
				table.insert(entries, { Key = key, Count = count, Worth = points * count })
			end
		end
		table.sort(entries, function(a, b) return a.Worth > b.Worth end)
		for index = 1, math.min(SCORE.MaxReceipts, #entries) do
			local entry = entries[index]
			table.insert(receipts, SCORE.ReceiptText[entry.Key]:format(entry.Count))
		end
	end

	--// Plain data only - this crosses a RemoteEvent
	local cards = {}
	for _, member in ipairs(everyone) do
		table.insert(cards, {
			UserId = member.UserId,
			Name = member.DisplayName,
			Title = titled[member].Name,
			Emoji = titled[member].Emoji,
			IsMVP = member == mvp,
		})
	end

	return {
		Players = cards,
		MVP = mvp and {
			UserId = mvp.UserId,
			Name = mvp.DisplayName,
			Receipts = receipts,
		} or nil,
		Solo = #everyone == 1,
	}
end

do
	local bridge = Instance.new("BindableFunction")
	bridge.Name = "GetShiftAwards"
	bridge.OnInvoke = buildAwards
	bridge.Parent = ServerStorage
end

----------------------------------------------------------------
-- Fresh slate whenever a new shift goes RUNNING (charge-reset trigger)
----------------------------------------------------------------
task.spawn(function()
	local shiftState = ReplicatedStorage:WaitForChild("ShiftState", 30)
	if not shiftState then
		warn("[Score] no ShiftState folder - scores will never reset")
		return
	end
	local lastState = shiftState:GetAttribute("State")
	shiftState:GetAttributeChangedSignal("State"):Connect(function()
		local state = shiftState:GetAttribute("State")
		if state == "RUNNING" and lastState ~= "RUNNING" then
			resetAll()
			print("[Score] new shift - hidden scores reset")
		end
		lastState = state
	end)
end)

print("[Score] hidden shift score online")
