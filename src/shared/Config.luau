--[[
	Dinner Rush - Config
	ReplicatedStorage.Shared.Config

	THE one place every tunable number lives. Systems read from here; nothing
	hard-codes a value. Sources: Gameplay Review & Tuning Spec, Improvement
	catalog, Easy/Normal/Hard, Map Details v2, Rates and Bars (Aug 2026).

	Rules:
	  * THE EASY FREEZE: EASY is the frozen baseline (the game as it felt
	    Aug 2026). Do not retune EASY values; new mechanics ship EASY-neutral
	    (weight 0 / flag false / mult 1) and ramp on NORMAL/HARD upward.
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

	--// OWNER RULING (Aug 2026): E means PRESS, everywhere. Every
	--// default-key prompt is a tap - the only holds left in the game are
	--// EASY's frozen fix channels, the 3s pitcher fill, and the F/G
	--// prompts (water pour / water trap / payment collect).
	PickupHoldSeconds = 0,        -- fridge / dry shelf prompt
	StationLoadHoldSeconds = 0,   -- starting a cook
	CollectHoldSeconds = 0,       -- taking the result off the station
	                              -- (NOTE: Chef's CollectHoldMult passive now
	                              -- has nothing to scale - re-spec pending)
	BurntCleanupSeconds = 0,      -- clearing a ruined pan
	BinHoldSeconds = 0,           -- the TrashBin taps too, per the ruling

	--// One cook per station. Several burners = several CookStation anchors
	--// side by side, each with its own prompt and its own small bar.
	--// Bars are narrow on purpose: wide ones overlap when the anchors are
	--// only a few studs apart.
	StationBarWidth = 80,
	StationBarHeight = 30,

	--// Tighter than Config.Interaction.PromptRangeStuds (8). Neighbouring
	--// burners sit within a few studs, so a wide range would put every
	--// station's prompt in reach at once and E would fire an arbitrary one.
	StationPromptRangeStuds = 5,

	--// Payout multipliers applied when the dish is served.
	--// "Good" is the cook-minigame's middle tier (yellow saved by green);
	--// the yellow-yellow "OK" result reuses the Overcooked tier.
	PerfectPayMult = 1.5,
	GoodPayMult = 1.0,
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

	--// Seating: where members of a party stand around their table anchor.
	--// Computed from the anchor's own facing, so no extra seat parts are
	--// needed - member 1 takes the near side, member 2 the far side.
	SeatOffsetStuds = 4,

	--// Customers wear real avatars pulled from players' friend lists. Both
	--// Roblox calls behind this yield and are rate-limited, so AvatarPool
	--// fetches in the background and the spawner only reads the cache.
	Avatars = {
		Enabled = true,
		FallbackUserId = 5191267798,      -- OWNER'S USER ID - set this, or a server with
		                         -- no reachable friend lists gets plain rigs
		PoolTarget = 12,         -- how many descriptions to keep cached
		FetchDelaySeconds = 1,   -- gap between web calls, to stay under limits
		FriendsPerPlayer = 20,   -- how many of each player's friends to consider

		--// Testing: put user IDs here and the pool uses ONLY these, skipping
		--// friend lists entirely. Deterministic, and works on an alt with no
		--// friends. Empty = normal behaviour.
		--//   e.g. { 156, 1, 261 }
		DebugUserIds = {},
	},

	WaterPourFirstBonus = 18,
	WaterPourRepeatBonus = 10,        -- diminishing, same table
	WaterStationHoldSeconds = 3,

	--// Table prompts: TAPS, per the E-means-press ruling (the server
	--// still validates the dish, so a mistap serve is denied, not wasted)
	TakeOrderHoldSeconds = 0,
	ServeHoldSeconds = 0,
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
	CollectHoldSeconds = 0,           -- E on a crate (press, per the ruling)
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
		--// FROZEN (THE EASY FREEZE, Aug 2026): these values are the locked
		--// baseline - EASY must forever feel like the game felt today.
		--// Tune NORMAL/HARD instead; new mechanics arrive here as neutral
		--// (weight 0 / false / 1) only.
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
		ExtinguishChannelSeconds = 4,  -- per burning station (GreaseFire)
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
			FireBurnoutEndsGame = false, -- EASY mercy: a fully burning kitchen
			                             -- drains rep but does not end the shift
			ToiletFloodRep = -30,     -- bathroom also closes 60s
			BathroomClosedSeconds = 60,
			SeatedWalkoutRep = -7,
			DoorWalkoutRep = -3,
			DashUncaughtRep = 0,
			InspectorFinePerMess = 5,
			InspectorFirstVisitWarns = true,
			InspectorCleanBonus = 40,
			FireSpreadSeconds = 45,   -- fuse before the fire jumps stations (retuned
			                          -- from 12 when GreaseFire shipped: the old value
			                          -- predated the extinguisher fetch, unwinnable)
		},
		Reputation = { SatisfiedParty = 3, VIPSatisfied = 5 },
		--// THE EASY FREEZE: interactions stay simple here, forever.
		Interactions = {
			BreakerMinigame = false,  -- hold-E, as the game shipped
			CookMinigame = false,     -- window-collect, as the game shipped
			PlungeMinigame = false,   -- hold-E plunge, as the game shipped
		},
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
		ExtinguishChannelSeconds = 5,
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
			FireBurnoutEndsGame = true,  -- every station ablaze = shift over
			SeatedWalkoutRep = -10,
			DoorWalkoutRep = -5,
			DashUncaughtRep = 0,
			InspectorFinePerMess = 10,
			InspectorFirstVisitWarns = false,
			InspectorCleanBonus = 60,
			FireSpreadSeconds = 35,   -- retuned from 8, see EASY note
		},
		Reputation = { SatisfiedParty = 2, VIPSatisfied = 4 },
		Interactions = {
			BreakerMinigame = true,   -- the wire-matching panel
			BreakerWires = 4,
			CookMinigame = true,      -- the timing-arrow collect
			PlungeMinigame = true,    -- the spam-tap plunge bar
		},
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
		ExtinguishChannelSeconds = 6,
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
			FireBurnoutEndsGame = true,
			SeatedWalkoutRep = -13,
			DoorWalkoutRep = -7,
			DashUncaughtRep = -3,
			InspectorFinePerMess = 15,
			InspectorFirstVisitWarns = false,
			InspectorCleanBonus = 90,
			FireSpreadSeconds = 25,   -- retuned from 6, see EASY note
		},
		Reputation = { SatisfiedParty = 2, VIPSatisfied = 4 },
		Interactions = {
			BreakerMinigame = true,
			BreakerWires = 5,         -- one more wire than NORMAL
			CookMinigame = true,
			PlungeMinigame = true,
		},
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
--   fire fuse      Difficulty[*].Consequences.FireSpreadSeconds (45 / 35 / 25)
--   douse time     Difficulty[*].ExtinguishChannelSeconds       (4 / 5 / 6)
--   roll weights   Config.EventWeights.* via Config.WeightFor
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

	GreaseFire = {
		SpreadRadiusStuds = 12,       -- a burning station ignites others in this range
		                              -- (grill/fryer anchors must sit within it!)
		DouseRangeStuds = 10,         -- click-to-spray works within this range;
		                              -- walking out of it cancels the douse
		RepDrainPer10sPerFire = 1,    -- each burning station bleeds independently
		FixRepReward = 1,             -- for spraying the blaze out
		WaterTrapMessage = "NEVER put water on a grease fire!",
		ToastSeconds = 4,             -- how long the water-trap lesson fills the screen

		--// Cosmetics
		FireSize = 12,                -- Roblox Fire instance size on the blaze
		BlazeCoverStuds = 7,          -- footprint of the invisible pad the flames
		                              -- ride on - ONE big fire covering the whole
		                              -- appliance, not a candle on the anchor
		LightRange = 14,              -- orange glow radius
	},

	PowerOutage = {
		--// Hold at the breaker. Per-difficulty, like the toilet's channel.
		FixChannelSeconds = { EASY = 6, NORMAL = 8, HARD = 10 },

		RepDrainPer10s = 1,           -- bleed while the lights are out
		FixRepReward = 1,             -- for restoring power

		--// Seated patience melts faster in the dark. Applied ONLY while the
		--// outage is active, via EventState.PatienceMultiplier.
		PatienceDrainMultiplier = 1.25,

		--// Dim, never black. Young players on bright phone screens still have
		--// to navigate the restaurant, so this stays readable on purpose.
		DarkAmbient = Color3.fromRGB(74, 64, 54),
		DarkOutdoorAmbient = Color3.fromRGB(64, 56, 48),
		DarkBrightness = 0.6,
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
	--// Double-tap W to sprint, then keep W held. LeftShift is Roblox's own
	--// shift-lock toggle, so binding sprint to it fought the camera.
	DoubleTapSeconds = 0.35,      -- max gap between the two W presses
	StopOnRelease = true,         -- letting go of W ends the sprint

	--// 1.5x Roblox's default 16. The restaurant is big enough that stock
	--// walking made every trip feel like a chore; sprint keeps its 1.5x
	--// margin on top so it still reads as a burst rather than the norm.
	BaseWalkSpeed = 24,           -- was 16 (Roblox default)
	SprintSpeed = 36,             -- was 24; still 1.5x the base
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
-- PAYMENT COLLECTION (money waits on the table at full value - see
-- ServiceLoop's payment section)
--
-- The split, as implemented:
--   BASE = what a plain order pays with zero perfect cooks and no VIP:
--          BASE_COINS_PER_PARTY * Size * CoinMult * OvercookedPayMult
--   TIP  = everything the actual payout adds above that (the perfect-cook
--          surplus and the VIP surplus)
-- Both are paid in full whenever the money is collected. The split is kept
-- because it is what a future pressure mechanic would act on.
----------------------------------------------------------------
Config.Payment = {
	--// Payments no longer melt. Money sits on the table at full value until
	--// someone collects it, or until the shift ends and it is swept into the
	--// till. Removed for now pending a different answer to "don't let money
	--// pile up as a free buffer" - see LingerSeconds below for the one piece
	--// of pressure kept.
	LingerSeconds = 0,            -- 0 = never vanishes; >0 = seconds on the table
	CollectHoldSeconds = 1.0,     -- hold time on the collect prompt
}

----------------------------------------------------------------
-- SHIFT REPORT (the end-of-shift results panel - see ShiftReportClient)
-- The server computes every number and the verdict; the client renders.
----------------------------------------------------------------
Config.ShiftReport = {
	AutoDismissSeconds = 12,      -- panel dismisses itself after this long
	RowRevealSeconds = 0.35,      -- drumroll: pause between row reveals

	--// Checked top to bottom, first match wins. ServedFraction is of the
	--// difficulty's TargetParties; a missing key means "don't care".
	--// Tone picks the stamp colour: "good" basil / "mid" mustard / "bad" tomato.
	GradeThresholds = {
		{ Grade = "5 STARS!",       Tone = "good", ServedFraction = 1.0, MinReputation = 60 },
		{ Grade = "GREAT SHIFT!",   Tone = "good", ServedFraction = 1.0 },
		{ Grade = "NOT BAD!",       Tone = "mid",  ServedFraction = 0.7 },
		{ Grade = "ROUGH NIGHT...", Tone = "bad" },
	},

	--// Any FAILED shift (reputation zero, kitchen burned down) stamps this
	--// regardless of the thresholds; the failure reason prints under it.
	FailGrade = { Grade = "CLOSED DOWN!", Tone = "bad" },
}

----------------------------------------------------------------
-- ORDER TICKET BOARD (wall SurfaceGui on the part tagged OrderBoard -
-- see OrderBoardService). Most desperate party is always leftmost.
----------------------------------------------------------------
Config.OrderBoard = {
	MaxTickets = 8,               -- cards on the board; overflow shows a "+N more"
	                              -- chip (unreachable with 4 tables - future-proofing)
	TicketsPerRow = 4,
	UpdateHz = 4,                 -- refresh rate; plenty for a wall sign
	CriticalPulseBelow = 0.25,    -- the leftmost ticket pulses under this patience
	WalkoutFlashSeconds = 1.2,    -- tomato flash before a walkout's card drops
	SortTweenSeconds = 0.25,      -- cards slide (never teleport) when re-sorting
	Face = "Auto",                -- "Auto" = find the big face not buried in the
	                              -- wall (raycast); or pin "Front"/"Back"/"Left"/
	                              -- "Right"/"Top"/"Bottom" manually
	PixelsPerStud = 50,           -- SurfaceGui resolution
}

----------------------------------------------------------------
-- CLASSES (the lobby class shop - see ClassVendor / ClassShopClient).
-- SHARED deliberately: passives and ultimates are main-game mechanics, so
-- the main place will read this same table when they get implemented.
-- Until then they are DISPLAY ONLY - the shop sells and equips, nothing
-- more. Purchase/equip validation lives server-side in ProfileAPI.
----------------------------------------------------------------
Config.Classes = {
	Trainee = {
		Display = "The Trainee",
		Rarity = "Starter", RarityColor = Color3.fromRGB(150, 150, 150),
		Price = 0,                -- never buyable: every profile starts owning it
		IconId = "rbxassetid://71049237083171",
		FlavorText = "First day on the job. The apron is still stiff.",
		PassiveText = "Eager to learn (no perks yet!)",
		UltimateName = "", UltimateText = "",
	},
	Chef = {
		Display = "The Chef",
		Rarity = "Common", RarityColor = Color3.fromRGB(76, 175, 109),
		Price = 1500,
		IconId = "rbxassetid://79387702760394",
		FlavorText = "Heard you can burn water. Prove me wrong.",
		PassiveText = "Collects cooked dishes a little faster",
		--// FLAT passive values (owner call: levels are a badge for now, no
		--// per-level scaling until the numbers have been playtested).
		--// Multiplies the collect-prompt hold on cook stations + the pass.
		CollectHoldMult = 0.6,
		UltimateName = "FLASH FRY!",
		UltimateText = "Instantly cooks the raw ingredient you're holding to PERFECT",
		--// Levels 1->5: finish the task, then PAY to upgrade. Steps[L] is the
		--// cumulative counter needed to leave level L; Costs[L] the coins.
		--// Tuned for ~10-15 perfects per focused shift: Lv2 in a shift or two,
		--// max level a real career. Counters counted in the MAIN GAME
		--// (future phase) and persisted via ProfileService.
		UpgradeTrack = {
			Counter = "PerfectCooks", Label = "Perfect cooks",
			Steps = { 15, 40, 80, 150 },
			Costs = { 300, 600, 1200, 2000 },
		},
	},
	Waiter = {
		Display = "The Waiter",
		Rarity = "Common", RarityColor = Color3.fromRGB(76, 175, 109),
		Price = 1500,
		IconId = "rbxassetid://102266349813244",
		FlavorText = "Three plates, one arm, zero fear.",
		PassiveText = "Sprint drains slower and refills faster",
		--// Owner ruled: the Waiter's passive is STAMINA EFFICIENCY (the old
		--// "quicker while carrying" text described a perk that never existed).
		--// SprintClient reads these off replicated Player attributes.
		StaminaDrainMult = 0.65,
		StaminaRegenMult = 1.35,
		UltimateName = "THIRD HAND!",
		UltimateText = "Carry a third item for the rest of the shift",
		--// ~10-15 serves per focused shift
		UpgradeTrack = {
			Counter = "DishesServed", Label = "Dishes served",
			Steps = { 20, 60, 120, 220 },
			Costs = { 300, 600, 1200, 2000 },
		},
	},
	Fixer = {
		Display = "The Fixer",
		Rarity = "Rare", RarityColor = Color3.fromRGB(245, 184, 65),
		Price = 4000,
		IconId = "rbxassetid://99068683562920",
		FlavorText = "Toilets fear them. Fires respect them.",
		PassiveText = "Fixes emergencies a little faster",
		--// Multiplies every event channel: plunge + douse + breaker. Channels
		--// are chores, not skill windows - legal under THE LAW.
		ChannelMult = 0.7,
		UltimateName = "SPEED DIAL!",
		UltimateText = "Instantly resolves the active emergency",
		--// ~1-3 event fixes per shift; rarer actions, shorter track
		UpgradeTrack = {
			Counter = "EventChannels", Label = "Emergencies fixed",
			Steps = { 3, 8, 16, 30 },
			Costs = { 500, 1000, 2000, 3500 },
		},
	},
	Charmer = {
		Display = "The Charmer",
		Rarity = "Epic", RarityColor = Color3.fromRGB(229, 72, 120),
		Price = 8000,
		IconId = "rbxassetid://137270991870999",
		FlavorText = "Could talk a burnt burger into a five-star review.",
		PassiveText = "Earns extra on payments they collect",
		--// Money minted on top of the payment they pick up, plus a bigger
		--// patience bonus when their recommendation lands.
		MoneyMult = 1.25,
		RecommendBonusMult = 2,
		UltimateName = "SWEET TALK!",
		UltimateText = "Refills one table's patience by half",
		--// ~4-8 collected payments per shift
		UpgradeTrack = {
			Counter = "PaymentsCollected", Label = "Payments collected",
			Steps = { 12, 35, 70, 130 },
			Costs = { 800, 1600, 3200, 5500 },
		},
	},
}

Config.ClassShop = {
	CardOrder = { "Trainee", "Chef", "Waiter", "Fixer", "Charmer" },
	VendorGreetings = {
		"Lookin' to move up in the world?",
		"Aprons, skills, destinies - take your pick!",
		"The Trainee look suits you. But so would a promotion...",
		"Every legend started with a name tag!",
	},
	CameraFocus = true,           -- brief camera tween toward the vendor on talk
	TagMaxDistanceStuds = 45,     -- vendor nametag/bubble hidden beyond this range
	CameraTweenSeconds = 0.35,
	WalkAwayCloseStuds = 14,      -- wandering off closes the screen
	BubbleSeconds = 3,            -- vendor speech bubble lifetime
}

----------------------------------------------------------------
-- PLAYER STATS (the lobby STATS screen - see StatsServer/StatsClient).
-- THE REGISTRY is the single source of truth for every lifetime stat:
-- its key, where it lives, its label, format, and default. The save
-- layer merges defaults from here; the UI builds its rows from here.
-- Adding a stat = adding ONE entry below (plus the gameplay hook that
-- increments it). Never touch UI code for a new stat.
--
-- Source:  "Stats"        -> profile.Stats[Key] (lifetime counters)
--          "TaskProgress" -> profile.TaskProgress[Key] (already stored
--                            for class tasks - NOT duplicated here)
--          "Computed"     -> derived server-side at payload time
-- Format:  "int" (1,234 / 12K) · "money" ($1,234) · "duration" (2h 14m)
----------------------------------------------------------------
Config.PlayerStats = {
	LevelShiftsPerLevel = 5,      -- passport LVL = 1 + ShiftsCompleted/this
	                              -- (derived, never stored - cannot desync)
	BestShiftsCap = 5,            -- hard ceiling, sorted+trimmed at insert

	Registry = {
		{ Key = "ShiftsCompleted",   Source = "Stats",        Label = "Shifts Completed",   Format = "int",      Default = 0 },
		{ Key = "ShiftsFailed",      Source = "Stats",        Label = "Shifts Failed",      Format = "int",      Default = 0 },
		{ Key = "CustomersServed",   Source = "Stats",        Label = "Customers Served",   Format = "int",      Default = 0 },
		{ Key = "DishesServed",      Source = "TaskProgress", Label = "Dishes Served",      Format = "int",      Default = 0 },
		{ Key = "PerfectCooks",      Source = "TaskProgress", Label = "Perfect Cooks",      Format = "int",      Default = 0 },
		{ Key = "EventChannels",     Source = "TaskProgress", Label = "Emergencies Fixed",  Format = "int",      Default = 0 },
		{ Key = "PaymentsCollected", Source = "TaskProgress", Label = "Payments Collected", Format = "int",      Default = 0 },
		{ Key = "Greetings",         Source = "TaskProgress", Label = "Warm Greetings",     Format = "int",      Default = 0 },
		{ Key = "Recommendations",   Source = "TaskProgress", Label = "Recommendations",    Format = "int",      Default = 0 },
		{ Key = "MoneyDeposited",    Source = "Stats",        Label = "Lifetime Earnings",  Format = "money",    Default = 0 },
		{ Key = "TimeOnFloorSeconds", Source = "Stats",       Label = "Time On Floor",      Format = "duration", Default = 0 },
		{ Key = "KitchenCrimes",     Source = "Stats",        Label = "Kitchen Crimes",     Format = "int",      Default = 0 },
		{ Key = "ClassesOwned",      Source = "Computed",     Label = "Classes Owned",      Format = "int",      Default = 0 },
	},
}

----------------------------------------------------------------
-- WIRE FIX (the breaker minigame - see EventSystem + WireFixClient).
-- The first gated interaction under the EASY FREEZE: EASY holds E, the
-- gated difficulties match wires. The SERVER deals the shuffle and checks
-- the answer; the client only renders and reports taps. The puzzle is
-- unfailable by design (only matching colours connect) - the fun is the
-- fingers, the anti-exploit is the server check.
----------------------------------------------------------------
Config.WireFix = {
	FixerWireDiscount = 1,        -- the Fixer's passive in minigame grammar:
	                              -- one fewer wire to connect
	MinWires = 3,                 -- the discount never goes below this
	TimeoutSeconds = 25,          -- abandoned panel auto-unlocks the breaker
	WalkAwayStuds = 12,           -- leaving the breaker closes the panel

	--// Wire palette, in deal order (HARD's 5th wire = the 5th colour)
	Colors = {
		Color3.fromRGB(229, 72, 77),    -- tomato
		Color3.fromRGB(245, 184, 65),   -- mustard
		Color3.fromRGB(76, 175, 109),   -- basil
		Color3.fromRGB(80, 150, 255),   -- blue
		Color3.fromRGB(170, 110, 220),  -- grape
	},
}

----------------------------------------------------------------
-- COOK TIMING (the cooking minigame - see KitchenService + CookTimingClient)
-- Gated by Difficulty.Interactions.CookMinigame (EASY keeps the frozen
-- window-collect). Replaces the COLLECT step only: the cook timer, the
-- station flow and the burn threat are untouched. An arrow sweeps a bar;
-- the GREEN zone sits at a RANDOM position each swing (owner call):
--   green (1st swing)          -> Perfect
--   yellow -> green            -> Good
--   yellow -> yellow           -> Overcooked ("OK")
--   red                        -> swing again (dish keeps aging - it can
--                                 still burn under a fumbling cook!)
-- LAW NOTE (owner-sanctioned): quality comes from the arrow on gated
-- difficulties. Zone widths are IDENTICAL on every gated difficulty -
-- the law holds within the mechanic, and EASY's windows are untouched.
----------------------------------------------------------------
Config.CookTiming = {
	--// Every swing rolls a fresh pace from this pool (server-dealt) so
	--// there is no metronome to memorise - each swing needs a real read.
	--// Same pool on every gated difficulty (THE LAW).
	SweepSecondsMin = 0.8,        -- fastest end-to-end arrow pass
	SweepSecondsMax = 1.4,        -- slowest

	--// Where the minigame runs, EVERY station cooks in the same flat time
	--// (owner ruling: the arrow is the skill, the wait is uniform - and
	--// the late game is hard enough already). Follows the GATE, not the
	--// difficulty (THE LAW); EASY keeps its frozen per-method timers.
	MinigameCookSeconds = 5,      -- flat cook time on gated difficulties
	GreenWidth = 0.09,            -- fraction of the bar; NEVER per-difficulty
	YellowWidth = 0.11,           -- each side of the green
	StopToleranceSeconds = 0.13,  -- claim-vs-server-clock slack in SECONDS of lag,
	                              -- so fast swings don't punish ping harder
	ResultFlashSeconds = 0.6,     -- PERFECT!/GOOD!/OK!/MISS! beat between swings
	TimeoutSeconds = 20,          -- abandoned panel frees the station
	WalkAwayStuds = 10,           -- leaving the station closes the panel
}

----------------------------------------------------------------
-- THE PLUNGE TAP (Difficulty.Interactions.PlungeMinigame - EASY keeps
-- the frozen hold-E plunge). Spam tap / left-click to fill the bar;
-- it leaks while you rest. The SERVER counts its own taps (rate-capped
-- against autoclickers) and succeeds through stopToilet's normal path.
-- Same numbers on every gated difficulty (THE LAW).
----------------------------------------------------------------
Config.PlungeTap = {
	TapsToFill = 12,           -- taps to fill the bar (before class scaling)
	FloodTapsMultiplier = 1.5, -- a FLOODED toilet needs this x more taps
	DecayPerSecond = 0.10,     -- bar fraction leaking away per idle second
	MaxTapsPerSecond = 10,     -- server ignores taps faster than this
	TimeoutSeconds = 20,       -- abandoned panel frees the toilet
	WalkAwayStuds = 10,        -- wander this far and the panel closes
}

----------------------------------------------------------------
-- THE SHIFT SCORE (owner ruling, Aug 2026: HIDDEN by design). Every
-- useful moment quietly earns points through the same credit calls
-- that write careers - NOTHING is shown during the shift, so the only
-- winning strategy is being useful. At shift end the awards ceremony
-- reveals one title per player (warm fallbacks guarantee everyone
-- holds something - never a mock), then the MVP with receipt lines
-- (evidence, never the point math). Values identical on every
-- difficulty; the point table never leaves the server.
----------------------------------------------------------------
Config.Score = {
	--// Parity target: a busy shift in ANY emergent role should land in
	--// the same band. One 2-dish party ~ 30 kitchen pts ~ 31 floor pts.
	PointsPer = {
		Seats = 4,              -- seating a queued party (score-only stat)
		Greetings = 4,          -- the timed warm welcome
		OrdersTaken = 4,        -- finishing the take-order dialogue (score-only)
		Recommendations = 10,   -- the dialogue skill play
		DishesServed = 7,       -- per dish carried to its table
		PaymentsCollected = 5,  -- beating the melt timer
		PerfectCooks = 15,      -- the full fetch->cook->collect chain
		GoodCooks = 8,          -- the yellow->green save (score-only)
		OvercookedCooks = 2,    -- near-zero so bad dishes can't be farmed (score-only)
		EventChannels = 20,     -- any emergency fixed - rare, worth ~a table,
		                        -- low enough that nobody drops a pan to race for it
		KitchenCrimes = -20,    -- water on a grease fire
	},

	--// Title registry in claim-priority order. Keys sum into the
	--// category; the best untitled player with a count > 0 claims it.
	Titles = {
		{ Name = "Top Chef",      Emoji = "🍳", Keys = { "PerfectCooks", "GoodCooks" } },
		{ Name = "Speedy Server", Emoji = "🏃", Keys = { "DishesServed" } },
		{ Name = "Floor Captain", Emoji = "🛎️", Keys = { "Seats", "Greetings" } },
		{ Name = "Money Magnet",  Emoji = "💰", Keys = { "PaymentsCollected" } },
		{ Name = "Fix-It Hero",   Emoji = "🔧", Keys = { "EventChannels" } },
		{ Name = "Smooth Talker", Emoji = "😎", Keys = { "OrdersTaken", "Recommendations" } },
	},
	--// Nobody leaves empty-handed - warm, never mocking
	FallbackTitles = {
		{ Name = "Team Spirit", Emoji = "🌟" },
		{ Name = "Good Vibes",  Emoji = "🎈" },
		{ Name = "Rising Star", Emoji = "🧢" },
		{ Name = "Lucky Charm", Emoji = "🍀" },
		{ Name = "Crew Member", Emoji = "🧡" },
		{ Name = "The Backbone", Emoji = "💪" },
	},

	--// MVP receipts: friendly evidence lines (%d = the count)
	ReceiptText = {
		PerfectCooks = "%d perfect dishes",
		GoodCooks = "%d good saves",
		DishesServed = "%d dishes served",
		Seats = "%d parties seated",
		Greetings = "%d warm welcomes",
		OrdersTaken = "%d orders taken",
		Recommendations = "%d smooth recommends",
		PaymentsCollected = "%d payments collected",
		EventChannels = "%d emergencies fixed",
	},
	MaxReceipts = 3,            -- evidence lines under the crown

	--// Ceremony pacing (client-side theatre, before the report card)
	CardRevealSeconds = 0.9,    -- gap between title-card pop-ins
	TitlesHoldSeconds = 2.5,    -- admire the crew before the MVP screen
	MVPHoldSeconds = 4,         -- crown screen before the report card
	SoloBanner = "SHIFT HERO",  -- the crown's banner when playing alone
}

----------------------------------------------------------------
-- MANAGER BRUNO (the commentator - ManagerService + ManagerClient).
-- A 2D portrait card bottom-right that pipes in one-liners at story
-- moments. With every number hidden (score, clock, target, served),
-- Bruno IS the game's soft warning system: phase turns, closing and
-- crises get called in VIBES, never digits. PortraitImage = "" shows
-- the name placeholder until Bruno's PNG arrives. Cutscenes (start /
-- end / fail) are a later build on the same rig.
----------------------------------------------------------------
Config.Manager = {
	Name = "MANAGER BRUNO",
	PortraitImage = "",           -- rbxassetid://... when the 2D face arrives

	MinSecondsBetweenLines = 6,   -- global cooldown; urgent lines ignore it
	LineHoldBaseSeconds = 2.5,    -- bubble lingers this long...
	LineHoldPerChar = 0.045,      -- ...plus this per character of the line
	TypeSeconds = 0.6,            -- typewriter reveal duration
	WalkoutGrumbleCooldown = 25,  -- at most one walkout grumble per window
	RepWorryFraction = 0.5,       -- rep below this = worried lines
	RepPanicFraction = 0.25,      -- rep below this = panic lines
	RepRecoverFraction = 0.6,     -- back above this = relief (hysteresis)

	Lines = {
		ShiftStart = {
			"Doors are open! Make me proud out there!",
			"Deep breaths, team. Here they come!",
			"A brand new shift! Keep 'em smiling!",
		},
		PhaseBusy = {
			"It's filling up... look alive, team!",
			"Word's getting out about us - stay sharp!",
			"More hungry faces incoming!",
		},
		PhaseRush = {
			"HERE COMES THE DINNER RUSH!!",
			"This is it, people! RUSH TIME!",
			"Hold onto your aprons - it's RUSH hour!",
		},
		Closing = {
			"Last call! Finish those tables and collect!",
			"Doors are shut! Land every last dish!",
		},
		ToiletStart = {
			"The toilet's erupting! Grab the plunger, QUICK!",
			"Not the bathroom again... somebody plunge it!",
		},
		ToiletFlood = {
			"IT'S FLOODING! My beautiful floors!!",
			"The bathroom is a LAKE! Fix it, fix it!",
		},
		ToiletDone = {
			"Phew. We never speak of the bathroom again.",
			"Toilet's calm. My heart is not.",
		},
		FireStart = {
			"FIRE IN THE KITCHEN! Get the extinguisher!",
			"THE KITCHEN'S ABLAZE! And NO water, you hear me?!",
		},
		FireDone = {
			"Fire's out... someone check my eyebrows.",
			"Crisis over. Back to cooking - CAREFULLY!",
		},
		OutageStart = {
			"The power's out! Someone hit the breaker!",
			"Who forgot the electric bill?! The BREAKER, go!",
		},
		OutageDone = {
			"Lights! Beautiful lights! Back to work!",
			"Power's back. I can see the mess again...",
		},
		RepWorry = {
			"The customers are grumbling... turn it around!",
			"I'm seeing frowns out there. FEED them!",
		},
		RepPanic = {
			"We're one bad table from CLOSING DOWN!",
			"My diner is DYING! Save it, please!",
		},
		RepRecovered = {
			"That's more like it! They love us again!",
			"Smiles everywhere - keep it going!",
		},
		Walkout = {
			"We just lost a table! Move faster!",
			"They walked out! My heart breaks...",
		},
	},
}

----------------------------------------------------------------
-- ULTIMATES (charge + the four abilities - see ChargeService/ChargeClient)
-- Charge is SERVER-owned, 0..MaxCharge per player, earned at the same
-- moments the career counters fire, spent by activation (Q / touch / pad Y).
-- Only a SUCCESSFUL ability consumes the charge; a denial keeps it.
----------------------------------------------------------------
Config.Ultimates = {
	MaxCharge = 100,

	--// Charge per counted moment, keyed by PlayerStats registry keys.
	--// A missing key gives 0 (Kitchen Crimes build character, not charge).
	--// Multiplied by the count (CustomersServed arrives as party size).
	ChargePer = {
		PerfectCooks = 12,
		DishesServed = 8,
		CustomersServed = 4,
		PaymentsCollected = 10,
		Greetings = 5,
		Recommendations = 12,
		EventChannels = 25,
	},

	--// Ability numbers
	SweetTalkRefillFraction = 0.5,   -- half the table's patience bar back
	ThirdHandExtraSlots = 1,         -- carry 2 -> 3 for the rest of the shift

	--// Bar feel (client)
	BarTweenSeconds = 0.2,
	ReadyPulseSeconds = 0.8,
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
-- THE PASS (plate hand-off between kitchen and floor)
----------------------------------------------------------------
Config.Pass = {
	--// Plating is mandatory: a bare dish cannot be served. The pass is the
	--// only route from kitchen to floor.
	RequirePlateToServe = true,

	--// Taps, matching the cook/order prompts. Nobody holds E on a plate.
	PlaceHoldSeconds = 0,
	TakeHoldSeconds = 0,

	--// Slots sit side by side on the counter, so the prompt range is tight
	--// for the same reason the cook stations are - otherwise E hits whichever
	--// neighbour the engine felt like.
	PromptRangeStuds = 5,

	--// The food sits this far above the top face of the plate.
	FoodLiftStuds = 0.12,
	FoodSize = Vector3.new(1.1, 0.34, 1.1),

	--// Extra nudge for the portion if it sinks into or floats over the plate.
	--// Local to the plate: X/Z slide it across the surface, Y raises it.
	FoodOffset = Vector3.new(0, 0, 0),

	--// HOW THE PLATE SITS IN A PLAYER'S HAND.
	--// Roblox welds a Tool's Handle to the hand through Tool.Grip. Left at
	--// identity a flat object stands on its edge, so a plate needs tipping.
	--// Degrees, applied X then Y then Z.
	--//
	--// The Tool builds its own invisible, axis-aligned Handle, so 0,0,0 now
	--// means "held exactly as it sits on the counter" - the union's own axes
	--// no longer leak in. Only change this to tilt the plate on purpose.
	GripAngles = Vector3.new(0, 0, 0),

	--// Slides the plate within the hand once the rotation is right.
	GripOffset = Vector3.new(0, 0, 0),

	--// How far BELOW the plate the invisible handle sits, so the hand reads as
	--// a palm under a plate rather than a fist through one. Raise it if the
	--// plate still clips the hand; 0 puts the hand at the plate's underside.
	HandleDropStuds = 0.15,

	--// Where a served plate lands: 0 = table centre, 1 = the customer's seat
	--// position. Just past halfway puts it in front of them, on the table.
	TablePlateInset = 0.55,
	TablePlateLiftStuds = 0.05,

	--// Keeps a served plate off the very edge of the table. Raise it if plates
	--// look like they are about to slide off.
	TablePlateEdgeMargin = 0.9,

	--// THE PLATE ECONOMY. However many PassSlot models exist is how many
	--// dishes can be in flight at once. A plate is only free again once its
	--// table's payment has been collected (owner's ruling), so an uncollected
	--// payment holds a plate hostage - see the reclaim paths in PassService.
	ReclaimOnPlayerLeave = true,   -- carrier disconnects or dies -> plate home
	ReclaimOnShiftEnd = true,      -- never start a shift short of plates
}

----------------------------------------------------------------
-- SOUND EFFECTS
--
-- Server-played, so everyone hears the same thing at the same moment.
--
-- HOW 3D SOUND WORKS HERE: a Sound parented to a BasePart is positional
-- automatically. MinStuds is the radius of full volume; past MaxStuds it is
-- silent, tapering between the two. So a fryer with MinStuds 8 / MaxStuds 35
-- is loud at the station, faint across the dining room, and gone outside.
-- Global = true skips all that and plays flat for everyone, wherever they are.
--
-- MAP-AGNOSTIC BY DESIGN: nothing here names an instance. Every sound is
-- attached to whatever the calling system already found by TAG, so a new map
-- only needs its tags placed - no code changes, no paths to update.
--
-- Leave an Id empty and that sound is simply silent. Nothing breaks, and the
-- log says once which one is missing.
----------------------------------------------------------------
Config.Sfx = {
	Enabled = true,

	--// Scales every sound below, for balancing against the music in one place
	MasterVolume = 1,

	--// Used by any sound that does not override them
	DefaultMinStuds = 10,
	DefaultMaxStuds = 60,

	--// Per-sound. Volume is 0..1 before MasterVolume.
	--//   Loop   = true   plays until the system stops it
	--//   Global = true   heard everywhere at flat volume, ignores distance
	Sounds = {

		--// KITCHEN -------------------------------------------------------
		--// Tight radius on purpose: the kitchen should sound busy from the
		--// pass and only murmur from the dining room.
		CookFry = {
			Id = "75511010485145", Volume = 0.5, Loop = true,
			MinStuds = 8, MaxStuds = 35,
		},
		CookGrill = {
			Id = "77924122314675", Volume = 0.5, Loop = true,
			MinStuds = 8, MaxStuds = 35,
		},

		--// EMERGENCIES ---------------------------------------------------
		--// Alerts carry across the whole restaurant - the point is that
		--// nobody can miss them - so they are global.
		ToiletAlert = { Id = "", Volume = 0.7, Global = true },
		FireAlert   = { Id = "133849873643710", Volume = 0.8, Global = true },
		PowerAlert  = { Id = "", Volume = 0.7, Global = true },

		--// The FIXES are positional: you hear them where the work is.
		ToiletFix = {
			Id = "", Volume = 0.6, Loop = true,
			MinStuds = 6, MaxStuds = 30,
		},
		BreakerFix = {
			Id = "87055568032543", Volume = 0.6, Loop = true,
			MinStuds = 6, MaxStuds = 30,
		},
		FireExtinguish = {
			Id = "84243999556475", Volume = 0.7, Loop = true,
			MinStuds = 8, MaxStuds = 40,
		},

		--// Relief beat when the lights come back. Global - everyone was in
		--// the dark together.
		PowerRestored = { Id = "", Volume = 0.7, Global = true },

		--// CUSTOMERS -----------------------------------------------------
		--// At the customer, so you can tell WHICH table just gave up.
		CustomerAngry = {
			Id = "119046821634222", Volume = 0.7,
			MinStuds = 10, MaxStuds = 55,
		},

		--// SUPPLIER ------------------------------------------------------
		--// The order confirmation plays at the board you just used; the
		--// arrival plays at the truck so it pulls your attention outside.
		SupplyOrdered = {
			Id = "", Volume = 0.6,
			MinStuds = 8, MaxStuds = 35,
		},
		TruckArrived = {
			Id = "110342333875026", Volume = 0.8,
			MinStuds = 15, MaxStuds = 90,
		},

		--// SHIFT ---------------------------------------------------------
		--// Everyone hears these together, wherever they happen to be.
		ShiftStart = { Id = "", Volume = 0.8, Global = true },
		ShiftEnd   = { Id = "", Volume = 0.8, Global = true },
	},
}

----------------------------------------------------------------
-- MUSIC
--
-- Client-side by design: every player owns their own music so they can mute
-- it, and the server spends nothing on it. Nothing here affects gameplay.
----------------------------------------------------------------
Config.Music = {
	Enabled = true,

	--// 0..1. Background music should sit UNDER the prompts and event stings -
	--// if players turn it off to hear the game, it is too loud.
	Volume = 0.95,

	--// Seconds to fade between tracks. Long enough not to jolt, short enough
	--// that a phase change still reads as a change.
	CrossfadeSeconds = 2.5,

	--// Tapping this mutes/unmutes for that player only.
	ToggleKey = Enum.KeyCode.M,

	--// Start each playlist on a random track, so the same shift twice does
	--// not open on the same bar.
	Shuffle = true,

	--// A track that never loads would end the playlist silently, so give up
	--// on one and move to the next after this long.
	LoadTimeoutSeconds = 8,

	--// PLAYLISTS. Each entry is a full asset string:
	--//     "rbxassetid://1234567890"
	--//
	--// More than one id in a list plays them in rotation.
	--//
	--// LOBBY ONLY for now. The restaurant gets its own soundtrack later - when
	--// it does, add its playlists here and a MusicClient in src/game/client
	--// that calls Music.Play with the right name. The player itself needs no
	--// changes; it takes any playlist name in this table.
	Playlists = {
		Lobby = {
			-- "rbxassetid://0",
			"rbxassetid://88152996529508",
		},
	},
}

----------------------------------------------------------------
-- PERSISTENCE (the savefile)
----------------------------------------------------------------
Config.Profile = {
	--// DataStore name. NEVER rename this once players have saves - a new name
	--// is a new, empty store and every existing profile is orphaned with no
	--// way back. The _v1 suffix is the escape hatch: if the schema ever breaks
	--// unrecoverably, bump to _v2 rather than trying to migrate broken data.
	StoreName = "DinnerRush_Profiles_v1",

	--// Profile key is KeyPrefix .. UserId
	KeyPrefix = "Player_",

	--// Studio writes to the LIVE store by default - that is what makes the
	--// "earn -> leave -> rejoin" test actually prove anything. Flip to true to
	--// run against a throwaway in-memory store where nothing persists.
	UseMockInStudio = false,

	--// A player with no profile would earn progress into nothing, so we kick
	--// instead of letting them play. This is how long we let the load run.
	LoadTimeoutSeconds = 30,
	KickMessage = "Couldn't load your save. Please rejoin - your progress is safe.",

	--// Mirrors Wallet into leaderstats so it is visible without any UI. Coins
	--// stays what it already is: this shift's team money, session-only.
	ShowWalletInLeaderstats = true,

	--// THE SAVEFILE. Every key here is created for new players and back-filled
	--// into existing ones on load, so adding a key later is always safe.
	--//
	--// Never store in here: Instances, Vector3/Color3/CFrame, functions, or
	--// arrays with gaps. None of those survive a DataStore round-trip.
	Template = {
		SchemaVersion = 1,

		Wallet = 0,                   -- persistent personal money (spec 6)

		--// Sets, not arrays: OwnedClasses.Chef = true. Arrays with gaps are the
		--// documented DataStore hazard, and set lookup is what every call site
		--// actually wants. Deviates from spec 4 deliberately.
		OwnedClasses = {},            -- ["Chef"] = true
		ClassLevels = {},             -- ["Chef"] = 1..5
		EquippedClass = "",           -- "" = classless, which is legal

		--// Cumulative, lifetime. Single-shift challenge counts live in server
		--// memory (spec 4) - only their completions land here.
		TaskProgress = {
			PerfectCooks = 0,
			DishesServed = 0,
			EventChannels = 0,
			PaymentsCollected = 0,
			Greetings = 0,
			Recommendations = 0,
		},

		TutorialDone = false,         -- false = next shift runs guided (spec 7)

		--// Set once if DevSeedProgress ever ran on this profile, so a dev seed
		--// cannot stack every time they rejoin.
		DevSeeded = false,

		--// Lifetime stats behind the passport screen. Keys and defaults come
		--// from Config.PlayerStats.Registry and are merged in on load, so a
		--// stat added to the registry later appears on old profiles too.
		Stats = {},

		--// Best shifts, sorted and trimmed to PlayerStats.BestShiftsCap at
		--// insert - the saved array has a hard ceiling forever.
		BestShifts = {},

		--// Absorbed from the lobby (spec 3) - one profile per player, not one
		--// per feature. Neither system is built yet; the keys are here so the
		--// schema does not need a migration when they are.
		RedeemedCodes = {},           -- ["CODE"] = true
		DailyGift = { LastClaim = 0, Streak = 0 },
	},

	--// The tutorial that awards the Trainee is a later phase. Until it exists
	--// every profile is handed the Trainee on first load, so the CLASSES
	--// screen is never empty. Phase 3 sets this false and the tutorial grants it.
	GrantTraineeOnJoin = true,

	--// DEV ONLY. Fills TaskProgress with fake numbers so the class upgrade
	--// buttons can be tested without playing shifts first.
	--// WARNING: this writes into the REAL save. Anything it grants is
	--// permanent for that player. Off unless you are deliberately testing.
	DevSeedProgress = false,
	DevSeedWallet = 0,            -- coins granted on first load when seeding
}

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
