--[[
	Dinner Rush - Config
	ReplicatedStorage.Shared.Config

	THE one place every tunable number lives. Systems read from here; nothing
	hard-codes a value. Sources: Gameplay Review & Tuning Spec, Improvement
	catalog, Easy/Normal/Hard, Map Details v2, Rates and Bars (Aug 2026).

	Rules:
	  * NORMAL is the balance reference. EASY/HARD are defined relative to it.
	  * Cooking windows NEVER scale with difficulty (demand scales, not dexterity).
	  * All timers run on the SERVER; clients only render replicated values.

	Usage:
		local Config = require(ReplicatedStorage.Shared.Config)
		local diff = Config.ForDifficulty(shiftDifficulty)   -- "EASY"/"NORMAL"/"HARD"
		local interval = Config.Customers.PhaseIntervals.Crescendo / diff.SpawnRate
		local weight = Config.WeightFor("RushHour", shiftDifficulty)
]]

local Config = {}

----------------------------------------------------------------
-- SHIFT STRUCTURE
----------------------------------------------------------------
Config.Shift = {
	LengthSeconds = 480,              -- 8 min MVP shift
	PrepTimeSeconds = 45,             -- vote-skippable

	--// When the clock runs out the doors close but the room is not empty.
	--// CLOSING lets everyone already inside finish eating and paying; no new
	--// customers arrive. This is a safety cap so a stuck party cannot hold the
	--// shift open forever.
	ClosingMaxSeconds = 150,
	Phases = {                        -- shift-time boundaries (seconds)
		CalmEndsAt = 120,             -- 0:00-2:00 tutorial-in-motion
		BuildingEndsAt = 300,         -- 2:00-5:00 pressure ramps
		-- 5:00-8:00 = Crescendo
	},
}

----------------------------------------------------------------
-- COOKING (identical across difficulties - non-negotiable)
----------------------------------------------------------------
Config.Cooking = {
	Frying   = { CookTime = 10, PerfectWindow = 5, OvercookAfter = 4, BurntAfter = 5 },
	Grilling = { CookTime = 14, PerfectWindow = 6, OvercookAfter = 5, BurntAfter = 6 },
	-- Baking reserved for post-MVP update (20-30s, wide windows, fire-and-forget)
}

--// CookStation parts carry a Method attribute of "Fry"/"Grill", while the
--// timing table above is keyed "Frying"/"Grilling". Map both ways so neither
--// spelling silently misses.
Config.CookMethodAliases = {
	Fry = "Frying", Frying = "Frying",
	Grill = "Grilling", Grilling = "Grilling",
}

function Config.CookingFor(method)
	local key = Config.CookMethodAliases[method]
	return key and Config.Cooking[key], key
end

----------------------------------------------------------------
-- INGREDIENTS
-- Source is the tag of the part that dispenses it: cold things come from
-- parts tagged Fridge, dry things from parts tagged DryShelf. Any part with
-- that tag works, so three dry shelves are three valid pickup points.
----------------------------------------------------------------
--// Icon: fill these in with your uploaded images.
--//   RawPatty -> raw_patty   RawSteak -> raw_steak   RawPotato -> raw_potato
Config.Ingredients = {
	--// Stock is what the kitchen opens the shift with. Deliberately generous:
	--// until the Supplier delivery system exists there is no way to refill,
	--// so running dry would soft-lock a shift rather than create pressure.
	--// Potato is highest because fries are the cheap, common order.
	--// Patty/steak bumped for 3-player playtests (burger demand at 3p NORMAL
	--// is ~15-16 patties); retune DOWN when the Supplier restock ships.
	RawPatty = {
		Display = "Raw Patty", Icon = "rbxassetid://126279923200605",
		Source = "Fridge", Color = Color3.fromRGB(190, 95, 95),
		Stock = 18,
	},
	RawSteak = {
		Display = "Raw Steak", Icon = "rbxassetid://95127663931794",
		Source = "Fridge", Color = Color3.fromRGB(160, 70, 80),
		Stock = 12,
	},
	RawPotato = {
		Display = "Raw Potato", Icon = "rbxassetid://136806783641400",
		Source = "DryShelf", Color = Color3.fromRGB(200, 175, 130),
		Stock = 15,
	},
}

----------------------------------------------------------------
-- RECIPES: the three starter dishes
-- Ingredients must all be carried to the station before cooking starts, so
-- keep these at 1-2 items while the carry limit is 2.
----------------------------------------------------------------
--// Keyed by dish. A recipe is (Ingredient + Method) -> dish, so RawPatty and
--// RawSteak can both use the Grill and still make different things.
--// Timing names the Config.Cooking table this dish cooks by - difficulty
--// never scales those.
--//   Burger -> burger   GrilledSteak -> grilled_steak   Fries -> fries
Config.Recipes = {
	Burger = {
		Display = "Burger", Icon = "rbxassetid://124168239195461",
		Ingredient = "RawPatty", Method = "Grill", Timing = "Grilling",
		Color = Color3.fromRGB(180, 120, 70), PriceMult = 1.0,
	},
	GrilledSteak = {
		Display = "Grilled Steak", Icon = "rbxassetid://76036299162989",
		Ingredient = "RawSteak", Method = "Grill", Timing = "Grilling",
		Color = Color3.fromRGB(140, 85, 70), PriceMult = 1.4,
	},
	Fries = {
		Display = "Fries", Icon = "rbxassetid://92544312542938",
		Ingredient = "RawPotato", Method = "Fry", Timing = "Frying",
		Color = Color3.fromRGB(240, 205, 110), PriceMult = 0.8,
	},
}

--// What customers order, and how often
Config.OrderWeights = {
	Burger = 5,
	Fries = 4,
	GrilledSteak = 3,
}

----------------------------------------------------------------
-- KITCHEN: carrying, stations, and what a cook is worth
----------------------------------------------------------------
Config.Kitchen = {
	MaxCarriedItems = 2,          -- the design's two-item inventory rule
	PickupHoldSeconds = 0.4,      -- fridge / dry shelf prompt
	StationLoadHoldSeconds = 0.5, -- starting a cook
	CollectHoldSeconds = 0.4,     -- taking the result off the station
	BurntCleanupSeconds = 1.0,    -- clearing a ruined pan

	--// Payout multipliers applied when the dish is served
	PerfectPayMult = 1.5,
	OvercookedPayMult = 0.6,

	--// Reputation. PerfectDish already exists in Config.Reputation and is
	--// awarded on serving a perfect dish; these are the other two outcomes.
	OvercookedRep = 0,
	BurntRep = -1,                -- charged when a burnt dish is binned
}

--// (ingredient, method) -> dishName, recipe. Returns nil when this station
--// cannot cook what the player is carrying.
function Config.RecipeFor(ingredient, method)
	if ingredient == nil or method == nil then
		return nil
	end

	local wanted = Config.CookMethodAliases[method]
	for dishName, recipe in pairs(Config.Recipes) do
		if recipe.Ingredient == ingredient
			and Config.CookMethodAliases[recipe.Method] == wanted then
			return dishName, recipe
		end
	end

	return nil
end

--// Picks a dish name using OrderWeights
function Config.RollDish()
	local total = 0
	for _, weight in pairs(Config.OrderWeights) do
		total += weight
	end

	local roll = math.random() * total
	local acc = 0
	for name, weight in pairs(Config.OrderWeights) do
		acc += weight
		if roll <= acc then
			return name
		end
	end

	return "Burger"
end

----------------------------------------------------------------
-- CUSTOMERS: spawning, patience, eating
-- Base values = NORMAL. Difficulty table scales them (see usage note above).
----------------------------------------------------------------
Config.Customers = {
	PhaseIntervals = {                -- seconds per party, NORMAL base
		Calm = 35, Building = 22, Crescendo = 15,
	},
	QueueSpotsOnMap = 5,              -- physical spots; DoorQueueMax caps per mode

	DoorPatienceSeconds = 40,         -- spawn -> seating INITIATED
	VIPDoorPatienceSeconds = 25,
	SeatedPatienceSeconds = 75,       -- seated -> LAST dish served (one bar!)
	VIPSeatedPatienceSeconds = 45,

	WaterPourFirstBonus = 18,
	WaterPourRepeatBonus = 10,        -- diminishing, same table
	WaterStationHoldSeconds = 3,
	PerDishServeBonus = 5,            -- multi-dish orders: grace per dish landed
	PaySeconds = 5,
	SeatingWalkIsFree = true,         -- door bar dies on INITIATE; walk untimed
	WrongDishPausesBar = false,       -- punishing; revisit for EASY in playtest
	TakingOrderRefreshesBar = false,  -- NEVER true - deletes kitchen urgency
}

----------------------------------------------------------------
-- TOILET / BUSSING / CLEANING
-- Fuse length is per-difficulty: Difficulty[*].ToiletFuseSeconds
----------------------------------------------------------------
Config.Toilet = {
	WarningAtFraction = 0.5,          -- second, louder cue at 50% fuse
	PlungerRequired = true,           -- fetched from kitchen PlungerMount
}

Config.Bussing = {
	HoldSeconds = 5,
	-- AutoBusAfterSeconds lives in Difficulty (EASY-only mercy)
}

----------------------------------------------------------------
-- SUPPLIER
-- Delivery time is per-difficulty: Difficulty[*].SupplierDeliverySeconds
----------------------------------------------------------------
Config.Supplier = {
	PriceEventDecisionSeconds = 10,
	FreeItemThreshold = 5,            -- failure odds scale per item over this

	--// Delivery time is NOT here: Difficulty[*].SupplierDeliverySeconds
	--// already holds 22 / 25 / 30, so difficulty changes it for free.

	UnitsPerCrate = 5,                -- one crate restocks this many
	MaxCratesPerIngredient = 3,       -- per order, so a single order caps at 15
	CollectHoldSeconds = 0.6,         -- holding E on a crate
	TruckLingerSeconds = 45,          -- truck leaves; uncollected crates go with it

	--// Money is OFF for the MVP. Coins are per-player leaderstats, so charging
	--// one player for the whole restaurant's supplies is odd in co-op, and a
	--// broke team could soft-lock. Flip this on once there is a shared till.
	ChargeForOrders = true,
	CratePrice = {                    -- coins per crate when charging is on
		RawPatty = 20,
		RawSteak = 30,
		RawPotato = 12,
	},

	--// Placeholder delivery props, replaced by your own truck model later
	TruckSize = Vector3.new(10, 8, 18),
	TruckColor = Color3.fromRGB(210, 90, 80),
	CrateSize = Vector3.new(3, 3, 3),
	CrateColor = Color3.fromRGB(178, 138, 88),
	CrateSpacingStuds = 4,
}

----------------------------------------------------------------
-- REPUTATION (bar 0-100, empty = angry-manager early game over)
----------------------------------------------------------------
Config.Reputation = {
	Start = 60,
	Max = 100,
	PerfectDish = 1,                  -- flat everywhere: HARD's oxygen
	-- per-difficulty values live in Difficulty[*].Reputation
	UpdateEventScale = { EASY = 0.7, NORMAL = 1.0, HARD = 1.3 },
}

----------------------------------------------------------------
-- DIFFICULTY: the three evenings
--
-- PartySizeWeights = how many CUSTOMERS arrive in one group. Capped at 2 for
-- the MVP; add a [3]/[4] entry per mode to raise it and the spawner picks it
-- up on its own. Weights must sum to 1.0 within a mode.
-- Not to be confused with Config.PartySizeSpawnMult, which is keyed by
-- how many PLAYERS are in the shift (1-6).
----------------------------------------------------------------
Config.Difficulty = {

	EASY = {
		Label = "Cozy Shift",
		Patience = 1.2,               -- multiplies both bars
		SpawnRate = 0.8,              -- interval = base / SpawnRate
		PartySizeWeights = { [1] = 0.35, [2] = 0.65 },
		VIPChance = 0.05,
		DoorQueueMax = 3,
		GreetingBonus = 12,
		PitcherCapacity = 5,
		EatingSeconds = 10,
		DashWindowSeconds = 20,
		ToiletFuseSeconds = 120,
		UnclogChannelSeconds = 6,
		AutoBusAfterSeconds = 30,     -- EASY-only training wheels
		SupplierDeliverySeconds = 22,
		SupplierScenarioOdds = { Normal = 0.80, PriceHike = 0.10, Lucky = 0.10 },
		DeliveryFailBase = 0.05, DeliveryFailPerItem = 0.02,
		SafetyFloorPriceMult = 2, SafetyFloorDeliveryMult = 1,
		Events = {
			IntervalSeconds = 90,
			MaxConcurrent = 1,
			SecondEventAt = nil,      -- never 2 at once
			FirstEventAt = 150,       -- 2:30
			RushHourGuaranteed = false,
			WeightSet = "EASY",
			ExclusivePool = {},
		},
		Consequences = {
			ToiletFloodEndsGame = false,
			ToiletFloodRep = -30,     -- bathroom also closes 60s
			BathroomClosedSeconds = 60,
			SeatedWalkoutRep = -7,
			DoorWalkoutRep = -3,
			DashUncaughtRep = 0,
			InspectorFinePerMess = 5,
			InspectorFirstVisitWarns = true,
			InspectorCleanBonus = 40,
			FireSpreadSeconds = 12,
		},
		Reputation = { SatisfiedParty = 3, VIPSatisfied = 5 },
		Rewards = {
			CoinMult = 0.8, CompletionBonus = 100,
			StreakCap = 2.0, XPMult = 0.9,
			TargetParties = 11,       -- of ~18 arrivals
		},
	},

	NORMAL = {
		Label = "Dinner Rush",
		Patience = 1.0,
		SpawnRate = 1.0,
		PartySizeWeights = { [1] = 0.25, [2] = 0.75 },
		VIPChance = 0.10,
		DoorQueueMax = 4,
		GreetingBonus = 10,
		PitcherCapacity = 4,
		EatingSeconds = 12,
		DashWindowSeconds = 15,
		ToiletFuseSeconds = 105,
		UnclogChannelSeconds = 8,
		AutoBusAfterSeconds = nil,    -- no mercy
		SupplierDeliverySeconds = 25,
		SupplierScenarioOdds = { Normal = 0.65, PriceHike = 0.20, Lucky = 0.15 },
		DeliveryFailBase = 0.10, DeliveryFailPerItem = 0.03,
		SafetyFloorPriceMult = 3, SafetyFloorDeliveryMult = 1,
		Events = {
			IntervalSeconds = 60,
			MaxConcurrent = 2,
			SecondEventAt = 300,      -- 2 allowed only in crescendo
			FirstEventAt = 120,       -- 2:00
			RushHourGuaranteed = true,
			WeightSet = "NORMAL",
			ExclusivePool = {},
		},
		Consequences = {
			ToiletFloodEndsGame = true,
			SeatedWalkoutRep = -10,
			DoorWalkoutRep = -5,
			DashUncaughtRep = 0,
			InspectorFinePerMess = 10,
			InspectorFirstVisitWarns = false,
			InspectorCleanBonus = 60,
			FireSpreadSeconds = 8,
		},
		Reputation = { SatisfiedParty = 2, VIPSatisfied = 4 },
		Rewards = {
			CoinMult = 1.0, CompletionBonus = 150,
			StreakCap = 2.5, XPMult = 1.0,
			TargetParties = 15,       -- of ~23 arrivals
		},
	},

	HARD = {
		Label = "Friday Frenzy",
		Patience = 0.85,
		SpawnRate = 1.3,
		PartySizeWeights = { [1] = 0.20, [2] = 0.80 },
		VIPChance = 0.15,
		DoorQueueMax = 5,
		GreetingBonus = 8,
		PitcherCapacity = 3,
		EatingSeconds = 14,           -- slow eaters throttle table turnover
		DashWindowSeconds = 10,
		ToiletFuseSeconds = 90,
		UnclogChannelSeconds = 10,
		AutoBusAfterSeconds = nil,
		SupplierDeliverySeconds = 30,
		SupplierScenarioOdds = { Normal = 0.55, PriceHike = 0.30, Lucky = 0.15 },
		DeliveryFailBase = 0.15, DeliveryFailPerItem = 0.04,
		SafetyFloorPriceMult = 4, SafetyFloorDeliveryMult = 2,
		Events = {
			IntervalSeconds = 45,
			MaxConcurrent = 2,
			SecondEventAt = 120,      -- 2 allowed from 2:00
			FirstEventAt = 90,        -- 1:30
			RushHourGuaranteed = true, -- + weighted second
			WeightSet = "HARD",
			ExclusivePool = { "CelebrityVisit", "BloggerLivestream" },
			ExclusiveUnlockAt = 240,  -- 4:00
		},
		Consequences = {
			ToiletFloodEndsGame = true,
			SeatedWalkoutRep = -13,
			DoorWalkoutRep = -7,
			DashUncaughtRep = -3,
			InspectorFinePerMess = 15,
			InspectorFirstVisitWarns = false,
			InspectorCleanBonus = 90,
			FireSpreadSeconds = 6,
		},
		Reputation = { SatisfiedParty = 2, VIPSatisfied = 4 },
		Rewards = {
			CoinMult = 1.5, CompletionBonus = 250,
			StreakCap = 3.0, XPMult = 1.25,
			TargetParties = 19,       -- of ~30 arrivals
		},
	},
}

----------------------------------------------------------------
-- EVENT WEIGHTS (relative within active pool; 0 = never in that mode)
-- Launch pool at MVP; update-tier entries pre-tuned for when they ship.
-- Read these through Config.WeightFor - the E/N/H keys do not match the
-- "EASY"/"NORMAL"/"HARD" strings used everywhere else.
----------------------------------------------------------------
Config.EventWeights = {
	--                          EASY  NORMAL  HARD
	Spill              = { E = 8, N = 6, H = 5 },  -- launch
	ToiletEmergency    = { E = 5, N = 6, H = 7 },  -- launch
	GreaseFire         = { E = 2, N = 5, H = 8 },  -- launch
	RushHour           = { E = 4, N = 6, H = 8 },  -- launch
	HealthInspector    = { E = 3, N = 5, H = 7 },  -- MVP candidate
	PowerOutage        = { E = 2, N = 4, H = 6 },  -- MVP candidate
	BirthdayTable      = { E = 7, N = 5, H = 3 },  -- update
	MysteryOrder       = { E = 6, N = 5, H = 4 },  -- update
	BulkDiscount       = { E = 6, N = 5, H = 4 },  -- update
	DishPileup         = { E = 4, N = 5, H = 6 },  -- update
	RainStorm          = { E = 4, N = 4, H = 5 },  -- update
	FreezerMalfunction = { E = 3, N = 4, H = 5 },  -- update
	WrongDelivery      = { E = 3, N = 5, H = 6 },  -- update
	BigFamilyWalkIn    = { E = 3, N = 5, H = 6 },  -- update
	TheComplainer      = { E = 2, N = 5, H = 7 },  -- update
	BrokenStove        = { E = 1, N = 4, H = 6 },  -- update
	TruckBreakdown     = { E = 2, N = 4, H = 6 },  -- update
	TheRat             = { E = 5, N = 5, H = 5 },  -- update: comedy is universal
	CelebrityVisit     = { E = 0, N = 0, H = 5 },  -- update, HARD exclusive
	BloggerLivestream  = { E = 0, N = 0, H = 4 },  -- update, HARD exclusive
}

--// Maps a difficulty name onto the shorthand key used by EventWeights
local WEIGHT_KEY = { EASY = "E", NORMAL = "N", HARD = "H" }

----------------------------------------------------------------
-- EVENTS: scheduling, and the per-event numbers that are not already
-- somewhere else in this file.
--
-- Deliberately NOT redefined here, because they already exist:
--   fuse length    Difficulty[*].ToiletFuseSeconds     (120 / 105 / 90)
--   plunge time    Difficulty[*].UnclogChannelSeconds  (6 / 8 / 10)
--   roll weights   Config.EventWeights.ToiletEmergency via Config.WeightFor
--   warning cue    Config.Toilet.WarningAtFraction
----------------------------------------------------------------
Config.Events = {
	Scheduler = {
		FirstEventAfterSeconds = 60,  -- the opening calm stays calm
		MinGapSeconds = 45,           -- breathing room between events
		RollIntervalSeconds = 10,     -- how often a roll is considered
		MaxActive = 1,                -- MVP: never two at once
	},

	ToiletEmergency = {
		FloodInstantRepHit = 3,       -- charged the moment it floods
		FloodRepDrainPer10s = 1,      -- ongoing bleed until someone plunges
		FixRepReward = 1,             -- for fixing it at any stage
		FloodChannelMultiplier = 1.5, -- plunging a flooded toilet takes longer

		--// Cosmetic flood spread
		PuddleCount = 7,
		PuddleRadiusStuds = 14,
		PuddleSizeStuds = 6,
		PuddleGrowSeconds = 6,        -- puddles fade in over this long
	},
}

----------------------------------------------------------------
-- MONEY
-- Every shift opens a shared till at zero. Customer payments go into it,
-- the Supplier spends out of it, and whatever survives to the buzzer is
-- split evenly into each player's own balance.
----------------------------------------------------------------
Config.Money = {
	ShiftStartingTill = 0,
	RemainderToFirstPlayer = true,  -- odd coins go somewhere rather than vanishing
}

----------------------------------------------------------------
-- PARTY-SIZE SCALING (stacks multiplicatively with Difficulty.SpawnRate)
-- Keyed by PLAYER count in the shift, not customer group size.
-- Open decision: solo players default to EASY at matchmaking (recommended).
----------------------------------------------------------------
Config.PartySizeSpawnMult = {
	[1] = 0.6, [2] = 0.75, [3] = 0.9, [4] = 1.0, [5] = 1.15, [6] = 1.3,
}

Config.MinPlayers = 1
Config.MaxPlayers = 6

----------------------------------------------------------------
-- INTERACTION / UI CONSTANTS
----------------------------------------------------------------
Config.Interaction = {
	PromptRangeStuds = 8,
	PromptRequiresLineOfSight = false, -- mobile mercy
	EatingIsUntimedPressure = true,    -- eating/pay happen AFTER bars die
}

----------------------------------------------------------------
-- SPRINT / STAMINA (client-side movement feel - see SprintClient)
-- Difficulty NEVER touches these: hands feel the same everywhere.
----------------------------------------------------------------
Config.Sprint = {
	BaseWalkSpeed = 16,           -- Roblox default; THE source of truth for normal speed
	SprintSpeed = 24,             -- while sprinting (1.5x)
	StaminaMax = 100,
	DrainPerSecond = 20,          -- ~5s of continuous full sprint
	RegenPerSecond = 15,          -- empty -> full in ~6.7s once regen starts
	RegenDelaySeconds = 1.0,      -- pause after sprinting stops before regen begins
	MinStaminaToStart = 15,       -- can't START a sprint below this; an ongoing one may run to 0
	SprintAnimationId = "",       -- optional custom sprint anim; "" = default run anim,
	                              -- which already speeds up with WalkSpeed on its own
	FovKick = 6,                  -- degrees added to camera FOV while sprinting; 0 disables

	--// Stamina bar feel
	LowStaminaFraction = 0.2,     -- below this the fill flips mustard -> tomato
	BarLingerSeconds = 1.0,       -- bar stays this long after refilling, then fades out
	TweenSeconds = 0.25,          -- FOV kick and bar fade tween length
}

----------------------------------------------------------------
-- ORDER DIALOGUE (the take-order conversation - see DialogueClient)
-- {DISH} in a phrase is replaced at runtime with the dish display name
-- (or the whole ticket, e.g. "Burger + Fries", in the direct flow).
----------------------------------------------------------------
Config.Dialogue = {
	RecommendChance = 0.25,       -- chance the customer asks for a recommendation
	TimeoutSeconds = 15,          -- unfinished dialogue auto-resolves; party never stuck
	RecommendPatienceBonus = 5,   -- seated-bar refresh for a great suggestion; 0 disables
	CloseAfterSeconds = 1.0,      -- panel lingers this long after the closing line

	--// Customer-voiced pools come in Singular/Plural: a party of one says
	--// "I", a party of two or more says "we". The server picks the voice
	--// from party.Size.
	WaiterGreetings = {
		"Welcome in! What can I get you?",
		"Hi there! What are you craving today?",
		"Good evening! Ready to order?",
		"What'll it be, friend?",
		"Hey hey! Hungry tonight?",
		"Welcome to Dinner Rush! What sounds good?",
	},
	--// The small-talk opener: the second button at the start of the chat.
	--// Customer rigs have no gender, so these stay neutral.
	WaiterSmallTalk = {
		Singular = {
			"How is your day going?",
			"Lovely evening! How are you doing?",
			"How's everything today, friend?",
		},
		Plural = {
			"How's everyone's day going?",
			"You all look cheerful! Good day so far?",
			"How's everything with you folks tonight?",
		},
	},
	--// Reply to small talk; the order/ask line is appended after it, so
	--// these read like "It's been great! I'll have the Burger, please!"
	CustomerMoods = {
		Singular = {
			"It's been great, thanks for asking!",
			"Long day... I am SO hungry!",
			"Wonderful as always!",
		},
		Plural = {
			"We've been having the best day!",
			"Busy day - we're all starving!",
			"It's been lovely, thanks for asking!",
		},
	},
	CustomerOrders = {
		Singular = {
			"I'll have the {DISH}, please!",
			"One {DISH} for me!",
			"Ooh, the {DISH} sounds perfect!",
			"{DISH}! I've been thinking about it all day!",
		},
		Plural = {
			"We'll have the {DISH}, please!",
			"The {DISH} for us, please!",
			"We've been dreaming about the {DISH} all day!",
			"Ooh, the {DISH} sounds perfect for us!",
		},
	},
	CustomerAsksRecommend = {
		Singular = {
			"Hmm... what do YOU recommend?",
			"I can't decide - what's good here?",
			"Surprise me! What's the chef's favorite?",
			"First time here - what should I try?",
		},
		Plural = {
			"We can't decide - what's good here?",
			"What do YOU recommend for us?",
			"Surprise us! What's the chef's favorite?",
			"First time here - what should we try?",
		},
	},
	WaiterRecommends = {
		"The {DISH} is excellent here!",
		"You can't go wrong with the {DISH}.",
		"Chef's special today: the {DISH}!",
		"Between us? The {DISH} is the best thing on the menu.",
		"Folks drive across town for the {DISH}!",
		"Trust me - the {DISH}. Every time.",
	},
	CustomerAccepts = {
		Singular = {
			"Perfect, I'll have that!",
			"Sold! One of those, please!",
			"You're the expert - {DISH} it is!",
			"Ooh yes, that's the one!",
		},
		Plural = {
			"Perfect, we'll have that!",
			"Sold! That's what we're having!",
			"You're the expert - {DISH} for the table!",
			"Great choice - we're in!",
		},
	},
	WaiterConfirms = {
		"Coming right up!",
		"Excellent choice!",
		"On its way!",
		"One {DISH}, coming up!",
		"Won't be long!",
		"Great pick - kitchen's on it!",
	},
}

----------------------------------------------------------------
-- PAYMENT COLLECTION (money waits on the table and melts - see
-- ServiceLoop's payment section)
--
-- The split, as implemented:
--   BASE = what a plain order pays with zero perfect cooks and no VIP:
--          BASE_COINS_PER_PARTY * Size * CoinMult * OvercookedPayMult
--   TIP  = everything the actual payout adds above that (the perfect-cook
--          surplus and the VIP surplus)
-- Base decays to BaseFloorPercent and stops; tip decays all the way out.
-- Hustle is rewarded, success is never zeroed.
----------------------------------------------------------------
Config.Payment = {
	GraceSeconds = 8,             -- full value this long; walking over isn't a sin
	DecaySeconds = 20,            -- after grace, the melt takes this long to finish
	BaseFloorPercent = 0.45,      -- base never drops below this fraction
	TipFloorPercent = 0,          -- tips melt completely (kept tunable anyway)
	LingerSeconds = 6,            -- fully-decayed money stays this long, then vanishes
	CollectHoldSeconds = 1.0,     -- hold time on the collect prompt
}

----------------------------------------------------------------
-- Accessors
----------------------------------------------------------------

--// Merged view for a difficulty (base + mode table)
function Config.ForDifficulty(name)
	local diff = Config.Difficulty[name]
	assert(diff ~= nil, "Unknown difficulty: " .. tostring(name))
	return diff
end

function Config.IsValidDifficulty(name)
	return type(name) == "string" and Config.Difficulty[name] ~= nil
end

--// Weight of one event in one mode. 0 means it never appears in that mode,
--// which is also what an unknown event name returns.
function Config.WeightFor(eventName, difficultyName)
	local weights = Config.EventWeights[eventName]
	if not weights then
		return 0
	end

	local key = WEIGHT_KEY[difficultyName]
	assert(key ~= nil, "Unknown difficulty: " .. tostring(difficultyName))

	return weights[key] or 0
end

--// Spawn interval for a phase, after difficulty and player count.
--// Phase is "Calm" / "Building" / "Crescendo".
function Config.SpawnIntervalFor(phase, difficultyName, playerCount)
	local base = Config.Customers.PhaseIntervals[phase]
	assert(base ~= nil, "Unknown phase: " .. tostring(phase))

	local diff = Config.ForDifficulty(difficultyName)
	local clamped = math.clamp(playerCount or 1, Config.MinPlayers, Config.MaxPlayers)
	local partyMult = Config.PartySizeSpawnMult[clamped]

	--// Higher rate means shorter gaps between arrivals
	return base / (diff.SpawnRate * partyMult)
end

--// Which shift phase a given elapsed time falls in
function Config.PhaseAt(elapsedSeconds)
	if elapsedSeconds < Config.Shift.Phases.CalmEndsAt then
		return "Calm"
	elseif elapsedSeconds < Config.Shift.Phases.BuildingEndsAt then
		return "Building"
	end
	return "Crescendo"
end

----------------------------------------------------------------
-- Config is read-only: a system that writes to it would silently
-- rebalance the game for everything else sharing this module.
----------------------------------------------------------------
local function deepFreeze(t)
	for _, value in pairs(t) do
		if type(value) == "table" and not table.isfrozen(value) then
			deepFreeze(value)
		end
	end
	return table.freeze(t)
end

return deepFreeze(Config)
