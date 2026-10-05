--[[
	Dinner Rush - Config
	ReplicatedStorage.Shared.Config

	THE one place every tunable number lives. Systems read from here; nothing
	hard-codes a value. Sources: Gameplay Review & Tuning Spec, Improvement
	catalog, Easy/Normal/Hard, Map Details v2, Rates and Bars (Aug 2026).

	Rules:
	  * EASY IS GENTLE, NOT FROZEN (owner ruling Sep 2026, supersedes THE
	    EASY FREEZE): mechanics and minigames ship on EVERY difficulty -
	    they are the fun, not the pressure. Gentleness lives in NUMBERS
	    only: demand (spawn/patience/targets), event weights, consequence
	    severity. The per-difficulty Interactions gates REMAIN as
	    architecture for a future mechanic that truly earns an exclusive.
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
	PrepTimeSeconds = 20,             -- the "SHIFT STARTS IN" countdown
	--// SKIP VOTE (Oct 2026): a SKIP button under the countdown. Once at
	--// least SkipVoteFraction of the players in the server press it, the
	--// countdown drops straight to SkipToSeconds (never lengthens it).
	SkipToSeconds = 5,
	SkipVoteFraction = 0.5,           -- 0.5 = half the team (rounded up), min 1 vote

	--// When the clock runs out the doors close but the room is not empty.
	--// CLOSING lets everyone already inside finish eating and paying; no new
	--// customers arrive. This is a safety cap so a stuck party cannot hold the
	--// shift open forever.
	ClosingMaxSeconds = 150,

	--// The ride home: seconds from shift END until everyone teleports
	--// back to the lobby. Sized to cover the MVP cutscene (~7s), the
	--// awards ceremony (~15s, skippable) + the report card (12s
	--// auto-dismiss) + a breather - the owner's "10-15s after they've
	--// seen everything". Raised 35 -> 42 for the cutscene (Oct 2026); a
	--// LONGER MVP animation needs this raised to match, or a full lobby
	--// gets sent home mid-report.
	ReturnToLobbySeconds = 42,

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
	--// The ramen cooker (Yamasaki Sushi map). Frying's numbers on purpose:
	--// a new METHOD is not a new difficulty, and hands feel the same at
	--// every pot - THE LAW holds.
	Boiling  = { CookTime = 10, PerfectWindow = 5, OvercookAfter = 4, BurntAfter = 5 },
	-- Baking reserved for post-MVP update (20-30s, wide windows, fire-and-forget)
}

--// CookStation parts carry a Method attribute of "Fry"/"Grill"/"Ramen",
--// while the timing table above is keyed "Frying"/"Grilling"/"Boiling".
--// Map both ways so neither spelling silently misses.
Config.CookMethodAliases = {
	Fry = "Frying", Frying = "Frying",
	Grill = "Grilling", Grilling = "Grilling",
	Ramen = "Boiling", Boiling = "Boiling",
	--// Manila's rice cooker and adobo pot. Both boil, so both borrow
	--// Boiling's window - a new METHOD is not a new difficulty (THE LAW).
	--// Split them into their own Config.Cooking entries if they ever need
	--// different timing.
	Rice = "Boiling",
	Pot = "Boiling",
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

	--// YAMASAKI SUSHI (only stocked on maps whose Menu cooks them).
	--// Icons pending the owner's uploads - "" ships ugly-but-working.
	RawChicken = {
		Display = "Raw Chicken", Icon = "rbxassetid://129069316269579",
		Source = "Fridge", Color = Color3.fromRGB(235, 180, 160),
		Stock = 18,
	},
	RawShrimp = {
		Display = "Raw Shrimp", Icon = "rbxassetid://130809960695275",
		Source = "Fridge", Color = Color3.fromRGB(238, 168, 158),
		Stock = 15,
	},
	RawNoodles = {
		Display = "Noodle Brick", Icon = "rbxassetid://134060384410956",
		Source = "DryShelf", Color = Color3.fromRGB(238, 220, 150),
		Stock = 12,
	},

	--// MANILA KITCHEN. Icons pending the owner's uploads - "" ships
	--// ugly-but-working, the same as every other dish before its art.
	RawPork = {
		Display = "Pork Belly", Icon = "rbxassetid://133374495233508", -- raw_pork
		Source = "Fridge", Color = Color3.fromRGB(214, 146, 140),
		Stock = 18,
	},
	RawRice = {
		Display = "Rice", Icon = "rbxassetid://120240808119103", -- uncooked_rice
		Source = "DryShelf", Color = Color3.fromRGB(245, 240, 228),
		Stock = 18,
	},
	RawLumpia = {
		Display = "Lumpia Rolls", Icon = "rbxassetid://91680745975302", -- uncooked_lumpia
		Source = "Fridge", Color = Color3.fromRGB(236, 214, 170),
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
		Display = "Grilled Steak", Short = "Steak", Icon = "rbxassetid://76036299162989",
		Ingredient = "RawSteak", Method = "Grill", Timing = "Grilling",
		Color = Color3.fromRGB(140, 85, 70), PriceMult = 1.4,
	},
	Fries = {
		Display = "Fries", Icon = "rbxassetid://92544312542938",
		Ingredient = "RawPotato", Method = "Fry", Timing = "Frying",
		Color = Color3.fromRGB(240, 205, 110), PriceMult = 0.8,
	},

	--// THE YAMASAKI MENU. Karaage and tempura share the fryers; ramen has
	--// its own cooker (Method "Ramen"). Price ladder mirrors the diner's:
	--// cheap staple -> mid -> signature.
	Karaage = {
		Display = "Karaage", Icon = "rbxassetid://113472909646068",
		Ingredient = "RawChicken", Method = "Fry", Timing = "Frying",
		Color = Color3.fromRGB(205, 140, 60), PriceMult = 1.0,
	},
	TempuraShrimp = {
		Display = "Tempura Shrimp", Short = "Tempura", Icon = "rbxassetid://81991543373834",
		Ingredient = "RawShrimp", Method = "Fry", Timing = "Frying",
		Color = Color3.fromRGB(236, 188, 108), PriceMult = 1.2,
	},
	Ramen = {
		Display = "Ramen", Icon = "rbxassetid://111083951169268",
		Ingredient = "RawNoodles", Method = "Ramen", Timing = "Boiling",
		Color = Color3.fromRGB(222, 190, 140), PriceMult = 1.4,
	},

	--// THE MANILA MENU. Lumpia shares the fryers; rice has its cooker and
	--// adobo its pot. Price ladder mirrors the others: staple, mid, signature.
	SteamedRice = {
		--// Short is what the ORDER BOARD prints when a dish has no icon
		--// yet - its text slot is narrow and long names get clipped.
		Display = "Rice", Short = "Rice", Icon = "rbxassetid://87007459314481", -- cooked_rice
		Ingredient = "RawRice", Method = "Rice", Timing = "Boiling",
		Color = Color3.fromRGB(248, 244, 232), PriceMult = 0.8,
	},
	Lumpia = {
		Display = "Lumpia", Short = "Lumpia", Icon = "rbxassetid://102396531470381", -- cooked_lumpia
		Ingredient = "RawLumpia", Method = "Fry", Timing = "Frying",
		Color = Color3.fromRGB(226, 176, 96), PriceMult = 1.0,
	},
	AdoboPork = {
		Display = "Adobo Pork", Short = "Adobo", Icon = "rbxassetid://126823141441254", -- cooked_pork
		Ingredient = "RawPork", Method = "Pot", Timing = "Boiling",
		Color = Color3.fromRGB(120, 72, 44), PriceMult = 1.4,
	},
}

----------------------------------------------------------------
-- THE RECIPE BOARD (the wall chart in every kitchen)
--
-- The board DERIVES ITSELF from the active map's Menu, so a new map needs
-- no list here: build it, give it a Menu in Config.Maps, tag a wall part
-- RecipeBoard, done. Yamasaki shows ramen, Route 67 shows burgers, and
-- neither one is written down twice.
----------------------------------------------------------------

--// How a cook station reads on the chart. Keyed by a recipe's Method.
--// IconId is optional: empty falls back to the label text, so the board
--// works before the art exists.
Config.CookMethodDisplay = {
	Grill = { Label = "GRILL",     IconId = "" },
	Fry   = { Label = "FRYER",     IconId = "" },
	Ramen = { Label = "RAMEN POT", IconId = "" },
	Rice  = { Label = "RICE COOKER", IconId = "" },
	Pot   = { Label = "POT",         IconId = "" },
}

--// Where a raw ingredient is kept, in words. Keyed by Ingredients[x].Source.
Config.IngredientSourceDisplay = {
	Fridge = "FRIDGE",
	DryShelf = "DRY SHELF",
}

Config.RecipeBoard = {
	--// Tag a wall part RecipeBoard. Optional attribute ScreenFace
	--// ("Front"/"Back"/"Left"/"Right"/"Top"/"Bottom") picks the side;
	--// without it the widest face wins, same as the supplier screen.
	Tag = "RecipeBoard",

	Title = "RECIPES",          -- the map's own name sits above this
	PixelsPerStud = 60,         -- raise for crisper text on a big slab
	ShowSource = true,          -- the little FRIDGE / DRY SHELF line
	MaxRows = 6,                -- more dishes than this and the rest are cut
}

--// What customers order, and how often - the FALLBACK menu, used only
--// when the active map has no Menu of its own (see Config.Maps: each map
--// row carries the menu its customers order from).
Config.OrderWeights = {
	Burger = 5,
	Fries = 4,
	GrilledSteak = 3,
}

----------------------------------------------------------------
-- KITCHEN: carrying, stations, and what a cook is worth
----------------------------------------------------------------
----------------------------------------------------------------
-- DOORS (Sep 2026): tag "Door" on a swinging door Model (the LEAF
-- only - a frame inside the model would swing too). E toggles it open
-- and shut, swung server-side around its own hinge edge. If a door
-- swings the wrong way: FlipHinge / FlipSwing boolean attributes on
-- the model fix it without touching code.
----------------------------------------------------------------
Config.Doors = {
	OpenAngleDeg = 105,           -- how far open
	SwingSeconds = 0.35,          -- swing time, eased
	PromptRangeStuds = 8,
}

----------------------------------------------------------------
-- THE MINIGAME ROLL (owner spec, Sep 2026): EVERY gated cook, on every
-- method and every map, rolls which minigame it gets - the timing
-- ARROW (game 1), RECIPE MATH (game 2), or the memory CARD MATCH
-- (game 3; KitchenService owns the list). Base odds are EVEN across
-- the pool. Streaks self-correct: each same-game pick IN A ROW moves
-- a slice of that game's odds to the others (split evenly), and the
-- moment the streak breaks the bias falls back to the single-pick
-- baseline (1-1-2 -> the 2 rolls at baseline again). Tracked per
-- PLAYER, on the server.
----------------------------------------------------------------
Config.CookMinigamePick = {
	StreakBiasPerRepeat = 0.12,   -- each same-game pick in a row moves this
	                              -- much of its odds to the other games
	MaxBias = 0.24,               -- bias cap: a long streak can never push
	                              -- its game below ~9% (1/3 - 0.24)

	--// STUDIO KNOB (live-ignored, like StudioSpawnBurst): pin EVERY
	--// roll to one game while testing it. 0 = off (normal roll),
	--// 1 = arrow, 2 = recipe math (RETIRED from the live pool),
	--// 3 = card match, 4 = rhythm tap, 5 = whack. REVERT TO 0 when done.
	StudioForceGame = 0, --// OFF: normal random roll across the pool

	--// THE LIVE POOL (Sep 21 2026): recipe math was cut (playtest: kids
	--// found it un-fun / a struggle) and replaced by TWO reflex games,
	--// rhythm tap + whack. Math's code stays for the tutorial but is no
	--// longer rolled. These are the game ids the live roll draws from.
	--// RHYTHM TAP RETIRED (owner, Oct 3 2026): pulled from the live roll,
	--// the way recipe math was. Its code stays (and StudioForceGame = 4
	--// still opens it) in case it comes back.
	Pool = { 1, 3, 5 }, -- arrow, cards, whack
}

----------------------------------------------------------------
-- RECIPE MATH (owner design, Sep 17 2026 - game 2 of the roll,
-- REPLACING the colour smash, which was retired for being the one
-- minigame whose difficulty scaled with the player's PING: its
-- bouncing, rerolling arcs could never be predicted client-side, so
-- high-latency kids aimed at ghosts. This game is perfectly
-- latency-proof: nothing is timing-precise beyond a 7 SECOND clock).
-- SAME ENTRY AS THE ARROW: flat cook, bar fills, READY, E opens it.
-- TWO recipe questions (add, subtract, multiply or divide - dressed
-- as kitchen problems, not homework), THREE answer buttons each, a
-- per-question timer. Both right = Perfect, one = Good, none =
-- RUINED (bin it - and a pure guesser lands there ~44% of the time,
-- so mashing buttons is a losing strategy). Aging pauses during the
-- game; ramen still never burns. THE LAW: ONE question pool for
-- every difficulty - EASY and HARD kids get the same math, exactly
-- like cook windows. Ungated fallback = the plain timed cook.
----------------------------------------------------------------
Config.RecipeMath = {
	Questions = 2,                -- asked per cook
	QuestionSeconds = 7,          -- answer clock per question; the buzzer
	                              -- counts as a wrong answer
	ResultFlashSeconds = 1.2,     -- right/wrong feedback beat between
	                              -- questions (the correct answer glows)
	AnswerGraceSeconds = 1.5,     -- transport slack past the buzzer - a
	                              -- slow connection never eats an answer
	                              -- that LEFT the client in time

	--// THE NUMBER RANGES (kid-fair, age 8-13; owner tunes):
	AddMin = 3,  AddMax = 12,     -- a + b, both in this range
	SubMax = 20,                  -- a - b: a up to this, b < a, never negative
	MultMin = 2, MultMax = 9,     -- a x b: times tables territory
	DivMin = 2,  DivMax = 9,      -- a / b built BACKWARD from quotient x
	                              -- divisor in this range - always divides
	                              -- evenly, never a remainder

	--// Wrong options sit this close to the truth (distinct, never
	--// negative, never equal to the answer) - close enough to punish
	--// guessing, far enough to reward actually knowing
	WrongOffsetMax = 3,

	--// THE SCORELINES (correct out of Questions):
	PerfectCorrect = 2,           -- both right = Perfect
	GoodCorrect = 1,              -- one right = Good
	                              -- none right = RUINED, bin it (ramen
	                              -- keeps its RUINED-never-"burnt" labels)

	--// THE DRESSING: every question reads as a kitchen problem. {A}
	--// {B} {ITEM} fill in; the equation renders big underneath anyway,
	--// so the sentence is flavour, not homework. Basic punctuation only.
	Items = {
		"tomatoes", "noodles", "shrimps", "onions", "mushrooms",
		"carrots", "peppers", "eggs", "buns", "pickles",
	},
	Prompts = {
		Add = "The recipe needs {A} {ITEM} plus {B} more!",
		Sub = "We had {A} {ITEM} but {B} fell on the floor!",
		Mult = "{A} plates each need {B} {ITEM}!",
		Div = "Split {A} {ITEM} between {B} plates!",
	},
}

----------------------------------------------------------------
-- THE CARD MATCH (owner design, Sep 2026): game 3 of the minigame
-- roll - memory pairs with a shift-kitchen clock. Same entry as the
-- others: flat cook, READY, E opens it. The server deals Pairs from
-- the ACTIVE MAP's food art (menu dishes + their raws - Diner cards
-- on the Diner, Yamasaki cards at Yamasaki), shows the whole board
-- for the PEEK, then it's flip-two-to-match against the clock. Pairs
-- found decide the dish; finding them ALL is Perfect ON THE SPOT.
-- THE LAW: one set of numbers for every difficulty.
----------------------------------------------------------------
Config.CardMatch = {
	GameSeconds = 10,             -- the playable clock, AFTER the peek
	                              -- (memory needs a touch more than the
	                              -- smash's 7 - flip-backs eat time)
	PeekSeconds = 1.0,            -- the whole board shows face-up first:
	                              -- turns luck into actual memory
	Pairs = 4,                    -- 4 pairs = 8 cards, a 4x2 board
	MismatchLockSeconds = 0.5,    -- a wrong pair sits face-up this long
	                              -- (input locked) before flipping back -
	                              -- the read-it-and-learn beat
	FlipCooldownSeconds = 0.08,   -- server-side min gap between flips:
	                              -- humans never notice, autoclickers do

	--// THE SCORELINES (pairs found when the clock lands):
	PerfectPairs = 4,             -- sweep the board = Perfect, instantly
	GoodPairs = 3,
	OvercookedPairs = 2,          -- below this = RUINED, bin it
}

----------------------------------------------------------------
-- RHYTHM TAP (Sep 21 2026 - replaces recipe math, game 4). Notes slide
-- toward a target line; tap each as it lands. Latency-safe by design:
-- the SERVER owns each note's arrival time and judges a tap against that
-- note's window (widened by GraceSeconds for transport lag) - there is
-- no client-side precision to corrupt, same safety as the arrow game.
-- Hit all = Perfect, most = Good, some = Overcooked, few = RUINED.
----------------------------------------------------------------
Config.RhythmTap = {
	Notes = 6,                    -- notes in a round (mix of taps + holds)
	FirstNoteSeconds = 1.2,       -- when the first note reaches the line
	NoteSpacingSeconds = 1.05,    -- base gap between notes reaching the line
	SpacingVariation = 0.4,       -- +/- random wobble on tap spacing, so it
	                              -- reads as a rhythm, not a metronome
	NoteTravelSeconds = 1.7,      -- how long a note is visible approaching
	HitWindowSeconds = 0.42,      -- +/- around a line-time a tap/press counts
	GraceSeconds = 0.25,          -- extra window for transport lag

	--// HOLD NOTES: press when the head reaches the ring, HOLD, release when
	--// the tail reaches it. Judged as press-window AND release-window.
	HoldChance = 0.4,             -- odds a given note is a hold (>=1 guaranteed)
	HoldSeconds = 1.2,            -- how long a hold lasts

	--// SCORELINES (notes hit when the clock lands - a hold counts as one):
	PerfectHits = 6,              -- all of them = Perfect (ends on the spot)
	GoodHits = 4,
	OvercookedHits = 2,           -- below this = RUINED, bin it
}

----------------------------------------------------------------
-- WHACK (Sep 21 2026 - replaces recipe math, game 5). Ingredient icons
-- pop up around the pan; tap them before they vanish. Pure reflex, fully
-- latency-tolerant (a target is up for a WINDOW; any tap in it counts,
-- server-validated - no precise timing). Hit most = Perfect down to a
-- RUINED floor, exactly like the card match tiers.
----------------------------------------------------------------
Config.Whack = {
	Targets = 12,                 -- how many pop up across the round
	SpawnEverySeconds = 0.65,     -- cadence of new pop-ups
	TargetUpSeconds = 1.4,        -- how long each stays tappable
	GraceSeconds = 0.25,          -- extra window for transport lag
	Slots = 9,                    -- 3x3 grid of holes the pop-ups rise from

	--// WHACK-A-MOLE RULE (owner spec, Sep 21): only the DISH's own
	--// ingredient counts - decoys (other food) pop up too and hitting one
	--// is a mistake. A minimum of PerfectHits good ones is guaranteed.
	DecoyChance = 0.35,           -- odds a given pop-up is a WRONG ingredient
	WrongHitPenalty = 1,          -- score lost for hitting a decoy (min 0)

	--// SCORELINES (correct ingredients hit when the clock lands):
	PerfectHits = 8,              -- >= this = Perfect
	GoodHits = 5,
	OvercookedHits = 3,           -- below this = RUINED, bin it
}

----------------------------------------------------------------
-- THE TUTORIAL (owner design, Sep 2026): a guided first shift in the
-- real restaurant. Opt-in only - a live server enters it via lobby
-- teleport data (Mode = "TUTORIAL"; button lands with the lobby
-- wiring pass) - Manager Bruno teaches one full customer loop with
-- one scripted party: seat, greet, order, then fetch-cook-serve THREE
-- dishes (one per cook minigame, pinned in CookGameOrder), collect
-- the payment, done. While MatchMode is TUTORIAL: patience bars are
-- FROZEN, the shift clock is frozen (so events never roll and the
-- night never ends), natural spawns/dash/critic/VIP/Helper are all
-- off. After the wrap-up the kitchen stays open as FREE PRACTICE.
-- TutorialService runs the steps; TutorialClient draws the objective
-- banner + SKIP button; the EventArrow points at each target.
----------------------------------------------------------------
Config.Tutorial = {
	--// STUDIO KNOB (live-ignored): boot Studio playtests straight
	--// into the tutorial for testing. REVERT to false when done.
	StudioTutorial = false, --// OFF: tutorial polish pass done (Sep 18)

	--// STUDIO KNOB (live-ignored): sprint silently past the main
	--// lesson straight to the finale (fire drill + critic) - no boxes,
	--// no scripted tables, waits auto-pass. REVERT to false when done.
	StudioSkipToFinale = false, --// finale verified (Sep 2026)

	--// THE EXIT: when the tutorial ends, everyone teleports back to
	--// the lobby (owner-provided PlaceId, Sep 2026). Studio always
	--// stays put (TeleportAsync cannot run there).
	LobbyPlaceId = 132877152120112,
	TeleportDelaySeconds = 3,     -- goodbye breath before the send

	TypeCharsPerSecond = 28,      -- Bruno's typewriter pace on the card
	WrapSeconds = 6,              -- the send-off lingers this long
	StepSettleSeconds = 1.0,      -- breath between a step done and the next

	--// The three teaching cooks pin the minigame roll in this order
	--// (1 = arrow, 2 = smash, 3 = card match)
	CookGameOrder = { 1, 2, 3 },

	--// TWO TABLES (owner spec, Sep 2026): party sizes in arrival
	--// order - a pair first (they order the first two dishes), then a
	--// solo customer for the last dish. Sizes must sum to
	--// #CookGameOrder, one dish per person.
	Parties = { 2, 1 },

	--// THE GUIDE LINE (owner spec: "an actual line arrow") - a beam
	--// from the player to the current target plus a bobbing marker
	--// over it; the edge arrow still covers off-screen targets
	Guide = {
		BeamWidthStuds = 0.5,     -- at the player's end (tapers to 40%)
		BeamTransparency = 0.3,
		MarkerHoverStuds = 4,     -- ⬇ marker height over the target
		RefreshSeconds = 0.4,     -- how often the nearest target re-picks
	},

	--// Bruno's script + the objective banner per step. Runtime fills
	--// {DISH} {INGREDIENT} {SOURCE} {METHOD} from the scripted ticket.
	--// OWNER RULINGS (Sep 2026): basic punctuation ONLY in Bruno's
	--// lines and the objectives - commas, periods, ! and ?, nothing
	--// else, ever. And Bruno WAITS: each Bruno entry is a list of
	--// short dialogue BOXES the player clicks through at their own
	--// pace (tap to finish the typing, tap again for the next box);
	--// the objective and arrow only appear after the last box.
	Text = {
		Welcome = {
			Bruno = {
				"Welcome to the crew, rookie! I'm Bruno, your manager.",
				"See that big arrow? It points where you need to go.",
				"Follow it and do what I say. Time to serve your first table!",
			},
			Objective = "Listen to Bruno!",
		},
		Seat = {
			Bruno = { "Customers at the door! Walk over and give them a table." },
			Objective = "Seat the customers!",
		},
		Patience = {
			Bruno = {
				"See the bars over their heads? That is their patience.",
				"When a bar runs out, they storm off and your reputation takes the hit!",
				"No stress today though. Patience is frozen while you learn.",
			},
			Objective = "",
		},
		Order = {
			Bruno = {
				"Time to take their order! A tablet slides in on the right.",
				"Just tap the food they ask for. Tick off every dish on their ticket and it sends!",
			},
			Objective = "Take the order on the tablet!",
		},
		Cooking = {
			Bruno = {
				"Now for the fun part. Cooking!",
				"Every cook plays one of three little games. The arrow, Recipe Math, or Memory Match.",
				"Which one you get is a surprise each time. Today I will show you all three!",
			},
			Objective = "",
		},
		Fetch = {
			Bruno = { "To the kitchen! Grab {INGREDIENT} from the {SOURCE}." },
			Objective = "Get {INGREDIENT} from the {SOURCE}!",
		},
		--// Every game gets its FULL rules up front (owner spec): how to
		--// play, what earns perfect, decent and garbage, and every way
		--// to lose points or waste time. Number placeholders fill from
		--// the real minigame Config at runtime, so a retune never makes
		--// Bruno a liar.
		Cook = {
			{
				Bruno = {
					"Load the {METHOD} station and let the bar fill up. When it reads READY, the arrow game begins!",
					"The arrow slides side to side. Tap to stop it!",
					"Stop it in the green on your first try for a PERFECT cook. Yellow gives you one more swing, and green on that one is a DECENT cook.",
					"Yellow twice makes a sloppy cook. Red just wastes a swing. And the food keeps cooking the whole time you aim, so too slow means burnt garbage!",
				},
				Objective = "Cook {DISH}, stop the arrow in the green!",
			},
			{
				Bruno = {
					"Next dish! This station asks RECIPE MATH questions.",
					"Two quick kitchen questions, three answers each. Tap the right one!",
					"Each question has a timer. Too slow counts as wrong, and wild guessing usually ruins the dish!",
					"Both right is a PERFECT cook. One right is a DECENT cook. None right is garbage for the bin!",
				},
				Objective = "Cook {DISH}, solve the recipe math!",
			},
			{
				Bruno = {
					"Last one! This station plays Memory Match.",
					"The cards peek face up for a moment. Remember them! Then flip two at a time to find matching pairs before the clock runs out.",
					"A wrong pair freezes your hands for a moment, so wild guessing just wastes precious time.",
					"Match all {CARDPAIRS} pairs for a PERFECT cook, it ends the game right away! {CARDGOOD} pairs is a DECENT cook, {CARDOK} pairs is a sloppy one, and less is garbage for the bin!",
				},
				Objective = "Cook {DISH}, match the pairs!",
			},
		},
		Plate = { --// arrow at the pass until a plated dish is in hand
			Bruno = {
				"Smells amazing! But no bare hands service in my restaurant.",
				"Take the dish to the pass counter and set it on a plate first.",
			},
			Objective = "Plate {DISH} at the pass!",
		},
		Serve = { --// arrow jumps to the customer once the plate is picked up
			Bruno = { "Now carry the plate to the table and hand it over!" },
			Objective = "Serve {DISH} to the table!",
		},
		PlateAgain = { --// dishes after the first: the plate rule, short
			Bruno = { "Plate it at the pass first!" },
			Objective = "Plate {DISH} at the pass!",
		},
		ServeAgain = { --// no box - the arrow simply moves to the table
			Objective = "Serve {DISH} to the table!",
		},
		Seat2 = {
			Bruno = {
				"A new customer just walked in!",
				"Real shifts juggle lots of tables at once. Seat them too!",
			},
			Objective = "Seat the new customer!",
		},
		Order2 = {
			Bruno = {
				"Take their order too. Every table wants something!",
				"This one cannot decide! They will ask what YOU recommend, so tap a dish on the tablet to pick for them.",
			},
			Objective = "Recommend a dish on the tablet!",
		},
		Collect = {
			Bruno = {
				"They loved it! Scoop up the money waiting at each table.",
				"Collecting also sends your plates back to the pass, ready for the next dish!",
			},
			Objective = "Collect the payments at the tables!",
		},
		--// THE CLEANING LESSON (Sep 29 2026): hands on the vacuum, plus a
		--// spoken heads up about the Health Inspector. Skipped whole if the
		--// map has no VacuumMount (nothing to grab), so it never wedges.
		Tidy = {
			Bruno = {
				"One more floor skill, rookie! See that TIDY bar? A messy diner makes everyone grumpy.",
				"Grime builds up as you work. Grab the vacuum off the wall, then clean the mess up!",
				"Oh, and watch for the HEALTH INSPECTOR. He drops by to judge how clean we are, so keep that bar high and he will love us!",
			},
			Objective = "Vacuum up the grime!",
		},
		--// THE FINALE (owner spec, Sep 2026): a taste of what a real
		--// shift throws at you - a live fire drill, then a VIP served
		--// with zero hand holding as the graduation exam
		FireDrill = {
			Bruno = {
				"Before I let you go, two more things you WILL meet out there.",
				"RANDOM EVENTS! Sometimes the restaurant itself goes wrong. Toilets flood, the power cuts out, and worse.",
				"The worst one? FIRE! Sometimes a station just catches fire. Grease and heat are a spicy couple.",
				"When it happens, run for the extinguisher on the kitchen wall and spray the flames. One good spray clears the whole fire!",
				"Ready? FIRE DRILL!",
			},
			Objective = "Put out the fire with the extinguisher!",
		},
		Critic = {
			Bruno = {
				"Nicely done, firefighter! Last thing. Some guests are SPECIAL.",
				"Here comes the FOOD CRITIC. One picky eater with a notebook. Their review can lift this restaurant or sink it!",
				"Serve them start to finish all by yourself, and cook it PERFECTLY if you can. Show me what you learned!",
			},
			Objective = "Serve the food critic all by yourself!",
		},
		Wrap = {
			Bruno = {
				"Out there you will also meet gold star VIP guests, sneaky runners who skip the bill, and surprises I will not spoil. Expect anything!",
				"And that's the whole job, rookie! Seat them, feed them, get paid. See you on a real shift!",
			},
			Objective = "Tutorial complete!",
		},
	},
}

--// HOVERING SOURCE ICONS (Sep 20 2026, playtest feedback: "put the food
--// icons on the fridges and shelves"): a floating row of the ingredient
--// icons each Fridge / DryShelf holds on the active map, so a player sees
--// what is inside without opening the menu. Built server-side by
--// KitchenService (world UI, like the boards). Counts stay in the menu.
Config.SourceIcons = {
	Enabled = true,
	HoverStuds = 3,          -- how high above the source the icons float
	IconStuds = 1.2,         -- size of each icon (billboard studs)
	MaxDistanceStuds = 45,   -- hidden past this, like the wall signs
	ShowLabel = false,       -- a "FRIDGE" / "DRY SHELF" caption under them
}

Config.Kitchen = {
	MaxCarriedItems = 2,          -- the design's two-item inventory rule

	--// OWNER RULING (Aug 2026): E means PRESS, everywhere. Every
	--// default-key prompt is a tap - the only holds left in the game are
	--// the 3s pitcher fill and the F/G prompts (water pour / water trap /
	--// payment collect). The old channel-hold fix paths still exist in
	--// code but no difficulty uses them since the Sep 2026 un-freeze.
	--// The cooking food's BOTTOM relative to each station's anchor -
	--// RAYCAST-MEASURED per method (the anchors sit at different heights
	--// over their cook surfaces in this map). Re-measure after moving
	--// appliances: the one-liner lives in the session notes.
	--// Fry sits DEEP on purpose (owner call, Sep 2026): raw food sinks
	--// into the oil with just the tops peeking out - chicken, shrimp,
	--// and the Diner's potatoes alike. 0.55 was the measured surface;
	--// 0.0 puts the food's bottom half a stud under it.
	--// Rice and Pot start at the ramen cooker's lift; nudge per station
	--// once the Manila props are placed.
	StationFoodLiftStuds = { Grill = -0.49, Fry = 0.0, Ramen = 0.20,
		Rice = 0.20, Pot = 0.20 },
	--// What a station SHOWS while cooking, when it isn't the raw item you
	--// carried in (owner call, Oct 2026: rice goes in the cooker loose, not
	--// in its sack). A value is either a DishModels item name, or a TRIM of
	--// a mesh: Item's DishMeshes model showing only parts whose names have a
	--// Keep word and no Skip word (lowercase); Fallback shows when nothing
	--// matches (the Output then lists the mesh's real part names).
	--// Anything not listed shows its own raw model.
	StationFoodItem = {
		RawRice = {
			Item = "RawRice",                -- the rice out of YOUR sack mesh
			Keep = { "rice", "grain" },
			Skip = { "bag", "sack", "tie", "rope", "string" },
			Fallback = "CookerRice",         -- the parts-built mound
		},
		--// the pork goes in the adobo pot, its cutting board does not. The
		--// current RawPork mesh is ONE part (PorkBelly_Board) with the board
		--// baked in, so the trim leaves nothing and the parts-built PotPork
		--// cubes show instead. A future mesh with the board as its own part
		--// trims automatically. (No Keep list = all but the Skip words.)
		RawPork = {
			Item = "RawPork",
			Skip = { "board", "cutting", "plank", "wood", "tray", "plate" },
			Fallback = "PotPork",
		},
	},

	--// Which looping sound a station makes while it cooks, by Method.
	--// A method missing here falls back to the grill sizzle.
	CookSfxByMethod = {
		Fry = "CookFry", Grill = "CookGrill", Ramen = "CookRamen",
		Rice = "CookRice", Pot = "CookPot",
	},
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

	--// A station cooks a recipe when the METHODS match. The alias table is
	--// only a spelling bridge ("Fry" ~ "Frying"): two different appliances
	--// that share a timing family (the rice cooker and the adobo pot both
	--// Boil) must NOT cook each other's food - pork in the rice cooker was
	--// the bug (Oct 2026). So the family match only counts when one side
	--// is the family name itself.
	local wanted = Config.CookMethodAliases[method]
	for dishName, recipe in pairs(Config.Recipes) do
		if recipe.Ingredient == ingredient then
			local exact = recipe.Method == method
			local spelling = wanted ~= nil
				and Config.CookMethodAliases[recipe.Method] == wanted
				and (Config.Cooking[method] ~= nil or Config.Cooking[recipe.Method] ~= nil)
			if exact or spelling then
				return dishName, recipe
			end
		end
	end

	return nil
end

--// Picks a dish name from a weights table - the active map's Menu when
--// the caller passes one, the global OrderWeights fallback otherwise.
function Config.RollDish(weights)
	weights = weights or Config.OrderWeights
	local total, first = 0, nil
	for name, weight in pairs(weights) do
		first = first or name
		total += weight
	end

	local roll = math.random() * total
	local acc = 0
	for name, weight in pairs(weights) do
		acc += weight
		if roll <= acc then
			return name
		end
	end

	--// Float rounding can leave roll a hair past acc: any menu dish is
	--// right, a HARDCODED one would put burgers on the sushi menu
	return first or "Burger"
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

	ChairSearchStuds = 9,             -- ChairSeat-tagged parts this close to a
	                                  -- table anchor are that table's chairs
	SitHipStuds = 1.1,                -- root height above the seat surface when
	                                  -- parked on a chair (tune to the chairs)

	TicketVisibleStuds = 30,          -- wanted-dish icons draw only this close
	                                  -- (walls occlude them too - the kitchen
	                                  -- reads the OrderBoard, not heads)

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
		RawPork = 30,
		RawRice = 12,
		RawLumpia = 20,
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

--// TIDINESS: the restaurant's cleanliness bar (Sep 27 2026). A second shared
--// meter beside Reputation - it drips down over the shift and from messes, and
--// players raise it by CLEANING (vacuuming grime spots, sweeping). The Health
--// Inspector event judges it. Per-difficulty drip/grime rate is DEMAND (like
--// spawn rate), NOT a skill window - so THE LAW holds: the clean action's power
--// (CleanRestore) is FLAT on every difficulty.
Config.Tidiness = {
	Enabled = true,
	Start = 100,
	Max = 100,
	--// passive ambient drip per second (DEMAND - scales by difficulty)
	DripPerSecond = { EASY = 0.15, NORMAL = 0.25, HARD = 0.40 },
	--// GRIME SPOTS: cleanable messes that splat on the floor over the shift.
	--// Each that appears knocks tidiness down; cleaning one restores some.
	GrimeSpawnEverySeconds = { EASY = 13, NORMAL = 9, HARD = 6 }, -- DEMAND (frequent mess)
	MaxGrimeSpots = 8,           -- cap on active grime at once
	GrimeDropOnSpawn = 4,        -- tidiness lost when a grime spot appears
	CleanRestore = 10,           -- tidiness restored per spot cleaned (FLAT - skill)
	--// VACUUM HOVER minigame: dust specks scattered in the panel, hover the
	--// nozzle over each to suck it up. Fixer's ChannelMult trims the count.
	DustSpecks = 6,              -- dust specks to suck to clean one spot
	DustTimeoutSeconds = 20,     -- abandoned panel frees the grime
	DustWalkAwayStuds = 14,      -- drift further from the spot and the panel closes
	GrimeOffsetStuds = 9,        -- how far from a random table a spot can splat
	--// POOP in the toilet: cleaned with the PLUNGER via the toilet TAP panel
	--// (Config.PlungeTap drives the tap mechanic). Ambient, one at a time.
	PoopChance = 0.30,           -- chance per grime tick a poop appears
	PoopDropOnSpawn = 6,         -- tidiness lost when a poop appears
	PoopCleanRestore = 15,       -- tidiness restored for plunging it (bigger mess)
	--// HUD bar colour thresholds (fraction of Max)
	CleanFraction = 0.70,        -- at/above = basil (clean)
	DirtyFraction = 0.35,        -- below = tomato (filthy)

	--// REWARD (owner spec): while the place is REALLY tidy (bar at/above this
	--// fraction), rare customers (VIPs) spawn more often - VIPChance is
	--// multiplied by TidyVIPMult. Keeping it clean pays off.
	TidyBonusFraction = 0.75,
	TidyVIPMult = 2.0,

	--// AFTER THE INSPECTION (owner spec, Sep 30 2026): the bar still hides and
	--// poop stops, but GRIME KEEPS COMING as DIRTY TABLES - a seated party
	--// whose table has grime next to it loses patience faster until it is
	--// cleaned. Keeps cleaning (and the Janitor) useful through the rush.
	AfterInspectionSpawnMult = 0.6, -- grime spawns this often vs before (0.6 = 60%)
	--// consequence severity per difficulty (multiplies the seated bar's drain)
	DirtyTableDrainMult = { EASY = 1.15, NORMAL = 1.25, HARD = 1.35 },
	DirtyFace = "🤢",               -- shown over a party eating next to grime
}

--// THE HEALTH INSPECTOR (reworked Sep 27 2026): a WARNING event. He announces
--// he is coming in WarningSeconds, then judges how TIDY the place is right now
--// (the ambient mess spawns all shift - Config.Tidiness - and players vacuum
--// it). Tidiness bar at/above PassFraction = PASS + money CleanBonus; below =
--// a rep FINE that scales with how far below (FineScale). Fine/bonus/warn per
--// difficulty in Difficulty[*].Consequences.Inspector*. PassFraction is DEMAND
--// (harder = must be tidier); cleaning power stays flat (THE LAW).
Config.HealthInspector = {
	WarningSeconds = 30,   -- heads-up before he judges (owner spec)
	--// tidiness fraction (0-1) needed to PASS
	PassFraction = { EASY = 0.40, NORMAL = 0.55, HARD = 0.70 },
	--// each ~1/FineScale of tidiness below the pass line = one FinePerMess unit
	FineScale = 10,
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
		--// GENTLE, NOT FROZEN (Sep 2026): EASY gets every mechanic - its
		--// kindness is in these NUMBERS (slow spawns, long patience, soft
		--// consequences), never in withholding the fun parts.
		Label = "Cozy Shift",
		Patience = 1.3,               -- multiplies both bars (kindest tier)
		SpawnRate = 0.8,              -- interval = base / SpawnRate
		PartySizeWeights = { [1] = 0.35, [2] = 0.65 },
		VIPChance = 0.05,
		DoorQueueMax = 3,
		PitcherCapacity = 5,
		EatingSeconds = 10,
		DashWindowSeconds = 20,
		ToiletFuseSeconds = 120,
		SpillFuseSeconds = 40,        -- sweep window before guests are grossed out
		SweepChannelSeconds = 2,      -- broom hold on the puddle (Fixer scales it)
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
		--// The minigames are the FUN - every difficulty gets them (owner
		--// ruling Sep 2026; the old freeze kept EASY on hold-E chores)
		Interactions = {
			BreakerMinigame = true,
			BreakerWires = 3,         -- the gentlest wire count
			CookMinigame = true,
			PlungeMinigame = true,
			SweepMinigame = true,     -- the drag-the-broom spill panel
		},
		Rewards = {
			CoinMult = 0.8, CompletionBonus = 100,
			StreakCap = 2.0, XPMult = 0.9,
			TargetParties = 11,       -- of ~18 arrivals
		},
	},

	NORMAL = {
		Label = "Dinner Rush",
		--// EASED (Sep 21 2026, playtest: "too fast / too intense, needs to
		--// be easier"). Demand only - cook windows are untouched. More
		--// patience + slower arrivals + later, rarer events. Still clearly
		--// above EASY (1.2 / 0.8). Tune freely from here.
		Patience = 1.2,               -- was 1.0: more time on both bars
		SpawnRate = 0.9,              -- was 1.0: parties arrive ~10% less often
		PartySizeWeights = { [1] = 0.25, [2] = 0.75 },
		VIPChance = 0.10,
		DoorQueueMax = 4,
		PitcherCapacity = 4,
		EatingSeconds = 12,
		DashWindowSeconds = 15,
		ToiletFuseSeconds = 105,
		SpillFuseSeconds = 32,
		SweepChannelSeconds = 2.5,
		UnclogChannelSeconds = 8,
		ExtinguishChannelSeconds = 5,
		AutoBusAfterSeconds = nil,    -- no mercy
		SupplierDeliverySeconds = 25,
		SupplierScenarioOdds = { Normal = 0.65, PriceHike = 0.20, Lucky = 0.15 },
		DeliveryFailBase = 0.10, DeliveryFailPerItem = 0.03,
		SafetyFloorPriceMult = 3, SafetyFloorDeliveryMult = 1,
		Events = {
			IntervalSeconds = 75,     -- eased from 60: more breathing room
			MaxConcurrent = 2,
			SecondEventAt = 360,      -- eased from 300: doubles only late crescendo
			FirstEventAt = 150,       -- eased from 120 (2:00) -> 2:30
			RushHourGuaranteed = true,
			WeightSet = "NORMAL",
			ExclusivePool = {},
		},
		Consequences = {
			ToiletFloodEndsGame = true,
			FireBurnoutEndsGame = true,  -- every station ablaze = shift over
			SeatedWalkoutRep = -8,    -- eased from -10: mistakes sting less
			DoorWalkoutRep = -4,      -- eased from -5
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
			SweepMinigame = true,     -- the drag-the-broom spill panel
		},
		Rewards = {
			CoinMult = 1.0, CompletionBonus = 150,
			StreakCap = 2.5, XPMult = 1.0,
			TargetParties = 13,       -- eased from 15: fewer arrivals now
		},
	},

	HARD = {
		Label = "Friday Frenzy",
		--// EASED (Sep 21 2026): now that NORMAL is gentler, HARD is retuned
		--// to "a real challenge, still fair" - roughly the OLD NORMAL feel
		--// testers found tough-but-playable. The brutal old-HARD numbers
		--// move up to the new EXTREME tier. Demand only; cook windows fixed.
		Patience = 1.0,               -- was 0.85: the base reference; HARD's
		                             -- pressure comes from spawns/events, not
		                             -- from stingy patience (owner, Sep 21)
		SpawnRate = 1.15,             -- was 1.3: busy, not a flood
		PartySizeWeights = { [1] = 0.20, [2] = 0.80 },
		VIPChance = 0.15,
		DoorQueueMax = 5,
		PitcherCapacity = 3,
		EatingSeconds = 14,           -- slow eaters throttle table turnover
		DashWindowSeconds = 10,
		ToiletFuseSeconds = 90,
		SpillFuseSeconds = 25,
		SweepChannelSeconds = 3,
		UnclogChannelSeconds = 10,
		ExtinguishChannelSeconds = 6,
		AutoBusAfterSeconds = nil,
		SupplierDeliverySeconds = 30,
		SupplierScenarioOdds = { Normal = 0.55, PriceHike = 0.30, Lucky = 0.15 },
		DeliveryFailBase = 0.15, DeliveryFailPerItem = 0.04,
		SafetyFloorPriceMult = 4, SafetyFloorDeliveryMult = 2,
		Events = {
			IntervalSeconds = 55,     -- eased from 45
			MaxConcurrent = 2,
			SecondEventAt = 180,      -- eased from 120: doubles from 3:00
			FirstEventAt = 105,       -- eased from 90 (1:30) -> 1:45
			RushHourGuaranteed = true, -- + weighted second
			WeightSet = "HARD",
			ExclusivePool = { "CelebrityVisit", "BloggerLivestream" },
			ExclusiveUnlockAt = 240,  -- 4:00
		},
		Consequences = {
			ToiletFloodEndsGame = true,
			FireBurnoutEndsGame = true,
			SeatedWalkoutRep = -11,   -- eased from -13
			DoorWalkoutRep = -6,      -- eased from -7
			DashUncaughtRep = -2,     -- eased from -3
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
			SweepMinigame = true,     -- the drag-the-broom spill panel
		},
		Rewards = {
			CoinMult = 1.5, CompletionBonus = 250,
			StreakCap = 3.0, XPMult = 1.25,
			TargetParties = 17,       -- eased from 19
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

	--// THE SPILL (owner design, Sep 17 2026 - GLOBAL, both maps): a
	--// puddle splats near a random table with a fuse
	--// (Difficulty[*].SpillFuseSeconds). Fetch the BROOM from the
	--// BroomMount and hold-sweep it (SweepChannelSeconds, the Fixer's
	--// ChannelMult trims it). Swept in time = nothing happens. Fuse
	--// out = HALF the currently seated parties lose HALF their
	--// remaining patience in one hit, then the puddle dries by itself
	--// and the event ends. Roadmap note: this is the mess system the
	--// parked HealthInspector has been waiting for.
	Spill = {
		AffectedFraction = 0.5,       -- share of seated parties hit at fuse-out
		PatienceCutMult = 0.5,        -- what remains of their bar after the hit
		PuddleRadiusStuds = 5,        -- visual size of the puddle
		PuddleOffsetStuds = 6,        -- how far from the chosen table it lands
		EvaporateAfterHitSeconds = 8, -- post-hit linger before it dries itself
		FuseOutRep = -4,              -- small rep sting on fuse-out (0 = none)
	},

	--// THE SWEEP MINIGAME (owner design, Sep 17 2026 - gated by
	--// Difficulty.Interactions.SweepMinigame, ON everywhere; the plain
	--// hold-sweep stays as the ungated fallback per the constitution).
	--// E on the puddle with the broom opens a SQUARE panel: wooden
	--// floor, water droplets, and the broom icon you DRAG left and
	--// right - each full pass wipes water away until the floor shines.
	--// The SERVER counts the strokes (plunge-tap grammar: rate-capped,
	--// broom-in-hand + proximity re-checked per stroke); the Fixer's
	--// ChannelMult trims the strokes needed.
	SpillSweep = {
		StrokesNeeded = 8,            -- full drag passes to come clean
		MaxStrokesPerSecond = 4,      -- server rate cap vs auto-draggers
		StrokeTravelFraction = 0.55,  -- panel-widths one pass must cover
		TimeoutSeconds = 20,          -- abandoned panel frees the puddle
		WalkAwayStuds = 12,           -- drift further and the session ends
		FloorImage = "",              -- optional owner art: square floor
		                              -- background ("" = code-drawn planks)
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
	--// THE GROUP SHARE (owner, Oct 5 2026): at shift end EVERY player takes
	--// home this fraction of the whole till (never less than an even split).
	--// 0.45 with 4 players = 180% paid out in total - bigger teams earn more
	--// each, which suits the 3-6 player game. nil = the old even split.
	PlayerShareFraction = 0.45,
	--// the shift's MVP takes this much MORE of the till on top (0.10 = the
	--// MVP gets 55% where everyone else gets 45%). Groups only - a solo
	--// player already takes the whole till.
	MvpBonusFraction = 0.10,
}

----------------------------------------------------------------
-- PARTY-SIZE SCALING (stacks multiplicatively with Difficulty.SpawnRate)
-- Keyed by PLAYER count in the shift, not customer group size.
-- Open decision: solo players default to EASY at matchmaking (recommended).
----------------------------------------------------------------
Config.PartySizeSpawnMult = {
	[1] = 0.6, [2] = 0.75, [3] = 0.9, [4] = 1.0, [5] = 1.15, [6] = 1.3,
}

--// THE HARD MINIMUM (owner ruling, Oct 5 2026): a shift needs at least 3
--// players - "it really cannot work with less than 3". The lobby queue will
--// not start a party below this, and the party-size picker starts here.
--// (Studio is exempt in QueueServer so the lobby flow can be tested solo.)
Config.MinPlayers = 3
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

	--// The touch sprint button's icon (owner's runner art, Sep 18).
	--// "" falls back to the SPRINT text label.
	TouchButtonImage = "rbxassetid://135068780639329",

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
	BubbleSeconds = 4,            -- chat bubbles fade after this (owner: snappy).
	                              -- NOTE: sets the GLOBAL bubble duration, so
	                              -- player chat bubbles share the same pace

	--// THE ORDER ANIMATION. Two clips played on the WAITER who pressed E:
	--// PullOut runs ONCE as they produce the tablet, then Tap LOOPS while
	--// the conversation plays out. Both stop the moment the order
	--// resolves - taken, timed out, or walked out on.
	--//
	--// TO FILL THESE IN: open the .fbx in Studio's Animation Editor
	--// (Avatar tab > Animation Editor), then the "..." menu > Publish to
	--// Roblox. Copy the asset id off the published page and paste it
	--// below. It MUST be published by the account or group that owns this
	--// experience, or it loads for nobody but you.
	--//
	--// An empty id skips that half, and empty ids on both skip the whole
	--// thing - orders still get taken either way.
	OrderAnim = {
		Enabled = true,
		PullOut = "106507550256453",       --// once: the waiter produces the tablet
		Tap = "77443526108220",           --// loops: tapping it while they order
		FadeSeconds = 0.15, --// blend out, and between the two clips
		StartFadeSeconds = 0.05, --// blend IN on the press - keep it tiny, it is the moment the player feels
	},

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
----------------------------------------------------------------
-- THE MINIGAME ART KIT (MinigameSkin). Paste each image's id into its Id.
-- Every piece is optional: an empty Id keeps that part of the screen's old
-- code-drawn look, so ids can go in one at a time. Upload under the GROUP.
--
-- Wired so far: MEMORY MATCH (Frame, Plaque, SlotTile, CardBack, Timer*)
-- and WHACK IT (Frame, Plaque, PotBack, PotFront). The other minigames
-- pick these up as they are converted.
--
-- SliceCenter = { left, top, right, bottom } in the IMAGE's own pixels:
-- the box whose inside may stretch. Everything outside it (the corners,
-- the rounded ends) stays crisp. The numbers below suit the kit as it was
-- generated; your teammate's Frame and Plaque need THEIR numbers. Easiest
-- way to get them: put an ImageLabel in StarterGui with that image, set
-- ScaleType = Slice, click the "..." beside SliceCenter to open the 9-Slice
-- Editor, drag the four lines just inside the decorated edges, and copy
-- the four numbers here.
----------------------------------------------------------------
Config.MinigameArt = {
	--// THE FRAME PIECES (custom-made to stretch, Oct 2026)
	Frame = {            -- the CUSTOM panel border (512x512, made to stretch)
		Id = "72543721211848",          -- <- paste the new border's id here
		--// From the prompt's layout: corners within 88 px, wood 44 px thick.
		--// (The teammate's PanelFrame, 71849129735816, was retired - its
		--// corner leaves and edges did not stretch cleanly.)
		SliceCenter = { 88, 88, 424, 424 },
		WoodPx = 44,     -- the wood + gold trim's thickness IN THE IMAGE, in pixels
		BorderPx = 22,   -- how thick that wood looks ON SCREEN, in pixels
	},
	Plaque = {           -- the CUSTOM title plaque (1024x192, stretches sideways)
		Id = "103598655242334",
		--// (Replaces the teammate's HeaderChalkboard, 73273922196950.)
		--// DRAWN AS MADE: shown at its own shape, never stretched, with the
		--// title written on it - so nothing can get cut off.
		AspectRatio = 1024 / 192, -- its width / height; only changes how wide it draws
		Grow = 1.9,      -- the sign's height, as a multiple of the title text's;
		                 -- the extra rises above the panel's top edge
		TextWidth = 0.78,  -- how much of the plaque the title may cover, across
		TextHeight = 0.5,  -- ...and down (keep it inside the painted face)
		--// Stretch = true would 9-slice it instead, using these - only if
		--// they match the image's REAL pixels (check in the 9-Slice Editor)
		Stretch = false,
		SliceCenter = { 160, 0, 864, 192 },
		Height = 192,
	},
	Button = {           -- not wired yet: for the games with buttons
		Id = "78479238895262",
		SliceCenter = { 128, 0, 384, 256 },
	},

	--// THE NEW KIT
	SlotTile = {         -- a card face-up / an answer's tile
		Id = "89504353404743",
		SliceCenter = { 70, 70, 442, 442 },
		SliceScale = 0.3, -- shrinks the border to suit card-sized tiles
	},
	CardBack = { Id = "74737597881328" },
	TimerTrack = { Id = "89063117767836", SliceCenter = { 70, 0, 954, 128 }, Height = 128 },
	TimerFill = { Id = "104573399119788", SliceCenter = { 80, 0, 944, 128 }, Height = 128 },
	PotBack = {
		Id = "137276501691090",
		OpeningY = 0.33,      -- how far down the image the opening's centre sits (0-1)
		AspectRatio = 512 / 384,
		--// How big an item rises out of a pot, as a fraction of the play
		--// area. Smaller than the old flat holes' pop-ups: much taller and
		--// an item's top slips behind the pot in the row above it.
		PopWidth = 0.17,
		PopHeight = 0.15,
		PopBase = 0.02,       -- how far below the opening's centre an item starts
	},
	PotFront = { Id = "112371762120602" },

	--// FEEDBACK EFFECTS (MinigameJuice). Optional: with no SparkleBurst the
	--// burst is a code-drawn ring; with no Rays the Perfect verdict skips them.
	SparkleBurst = { Id = "132160840576767" }, -- pops on a right answer, and on a Perfect verdict
	Rays = { Id = "126022175679712" },         -- spins behind "MASTER COOK!"
}

----------------------------------------------------------------
-- THE MINIGAME INTRO BANNER (MinigameIntro server, MinigameIntroClient).
-- Pressing E no longer drops you straight into a minigame: a bar pops up
-- under the shift timer with the game's name, then the game opens.
--
-- Costs no cook window: the cooking games HOLD the dish's aging for the
-- banner and put it back exactly where it was, so no burn timer had to
-- grow to pay for the wait. Every game's own clock starts only once the
-- game is on screen.
----------------------------------------------------------------
Config.MinigameIntro = {
	Enabled = true,
	Seconds = 1.2,   -- how long the name shows before the game opens
	BannerY = 0.17,  -- fraction of screen height: under the shift bar and its phase chip

	--// What the banner says, per game. Rename freely.
	Names = {
		CookTiming = "PERFECT TIMING!",  -- the stop-the-arrow cook
		RecipeMath = "RECIPE MATH!",
		CardMatch = "CARD MATCH!",
		RhythmTap = "RHYTHM TAP!",
		Whack = "WHACK IT!",
		Sweep = "MOP IT UP!",            -- the spill
		Plunge = "PLUNGE IT!",           -- the toilet, and the poop mess
		WireFix = "FIX THE WIRES!",      -- the power outage
		Vacuum = "VACUUM IT!",           -- floor grime
	},
}

----------------------------------------------------------------
-- THE MVP CUTSCENE (MvpCutscene, client). At shift end the screen fades to
-- black and the MVP celebrates on the map's MvpSpot, filmed by a camera
-- animated in Blender. It FREEZES on the final pose, and the awards
-- ceremony and report card pop up over the frozen shot, which holds until
-- everyone is sent back to the lobby (Shift.ReturnToLobbySeconds).
--
-- EACH MAP needs one part tagged MvpSpot inside its model: on the floor
-- where the MVP stands, its FRONT face pointing where they should face,
-- with about 12 studs clear in front for the camera. No spot = the
-- cutscene is skipped and the report shows as normal.
--
-- EACH ANIMATION needs a bone named CameraBone, parented to
-- HumanoidRootPart, animated as the camera. That bone IS the camera move.
----------------------------------------------------------------
Config.MvpCutscene = {
	Enabled = true,

	FadeSeconds = 0.6,       -- each fade to and from black
	HoldBlackSeconds = 0.3,  -- a beat of black before the scene appears
	LetterboxScale = 0.1,    -- film bars, as a fraction of screen height
	MaxSeconds = 10,         -- cap, whatever the animation's length

	--// "Aim": position from CameraBone, always looking at the MVP's chest -
	--//        can never face the wrong way (the Studio test's mode 0).
	--// "Bone": CameraBone's own rotation too, corrected by BoneFix (the
	--//        number from the Studio test that looked right, 1-6). Only
	--//        needed for shots that look AWAY from the MVP.
	CameraMode = "Aim",
	BoneFix = 1,

	FieldOfView = 50,        -- default lens (was 40 to match the Blender camera; owner: wider, Oct 2026)
	--// ZOOM OUT (owner, Oct 2026): the camera is pushed back along its own line
	--// of sight to this many times its animated distance from the MVP, so the
	--// whole body is in frame. 1 = the animation as authored. It stops short of
	--// walls on its way back, so a tight corner cannot put it inside one.
	CameraDistanceMult = 1.6,
	Blur = true,             -- soft background so the MVP pops
	BlurIntensity = 0.5,
	Light = true,            -- a temporary light on the MVP for the shot
	LightBrightness = 1.5,
	LightRange = 16,

	--// One entry per MVP animation; the server picks one at random each
	--// shift and every screen plays the same one.
	--//   AnimId     the published id (published under the GROUP)
	--//   Keyframes  STUDIO ONLY: name of a KeyframeSequence anywhere in
	--//              ReplicatedStorage, played without publishing. Live
	--//              servers ignore it - fill AnimId before release.
	--//   FieldOfView / CameraMode / BoneFix  optional per-animation overrides
	--//   SoundId     THIS animation's own sound, started with it ("" = silent).
	--//               Upload under the GROUP, like every other asset.
	--//   SoundVolume 0..10 (Roblox allows above 1 for quiet recordings)
	--//   SoundDelay  seconds into the animation before the sound starts - nudge
	--//               it to land a beat on a moment (the fist hitting the top)
	--//   SoundFadeOutSeconds  the sound eases down to silence over its LAST
	--//               this-many seconds instead of stopping dead (0 = no fade)
	--// The sound plays out in full, carrying on over the report if it is
	--// longer than the animation.
	Animations = {
		{
			Name = "Victory Fist",
			AnimId = "137252127254351",
			Keyframes = "MvpTest",
			FieldOfView = 50,
			SoundId = "139638022608077",
			SoundVolume = 1,
			SoundDelay = 0,
			SoundFadeOutSeconds = 3,
		},
	},

	--// THE "ORDER UP!" REVEAL (owner, Oct 2026 - Claude Design art). When the
	--// dance freezes, the MVP is SERVED: a checkered burst spins up, a cloche
	--// drops on a giant plate, jiggles, and lifts in a puff of steam to reveal
	--// the MVP's frozen pose (copied into a viewport so the art layers around
	--// it), ketchup + mustard squirt across, a neon sign flickers on with
	--// their title, and their order ticket slides along the rail and gets
	--// stamped MVP. Background only - the character is never animated here.
	--// MvpReveal.luau plays it; the ceremony follows when it fades.
	Reveal = {
		Enabled = true,
		Seconds = 7,                      -- how long the card holds before fading
		BackdropTop = Color3.fromRGB(18, 52, 59),    -- midnight teal (#12343B)
		BackdropBottom = Color3.fromRGB(8, 26, 31),
		NeonColor = Color3.fromRGB(255, 92, 170),    -- the hot-pink neon title
		Art = {
			MvpCheckerBurst = { Image = "rbxassetid://131713646001635" },
			MvpPlate        = { Image = "rbxassetid://130305115638738" },
			MvpCloche       = { Image = "rbxassetid://75267589505639" },
			MvpSteamPuff    = { Image = "rbxassetid://130554494820106" },
			MvpSauceKetchup = { Image = "rbxassetid://92781663376344" },
			MvpSauceMustard = { Image = "rbxassetid://130640847386310" },
			MvpTicketRail   = { Image = "rbxassetid://97854060559517" },
			MvpOrderTicket  = { Image = "rbxassetid://125607750074480" },
			MvpNeonOff      = { Image = "rbxassetid://127979901374228" },
			MvpNeonOn       = { Image = "rbxassetid://122180643310439" },
			MvpFoodConfetti = { Image = "rbxassetid://87343937539848" },
		},
	},
}

Config.ShiftReport = {
	AutoDismissSeconds = 12,      -- panel dismisses itself after this long
	RowRevealSeconds = 0.55,      -- drumroll: pause between row slaps (room for each impact)
	StampPauseSeconds = 0.5,      -- the held breath after the last row, before the stamp drops

	--// THE STAT COLOURS (owner, Oct 2026): the report shows only three
	--// stats, each coloured green (good) / yellow (mid) / red (bad). The
	--// SERVER judges them - the client only paints what it is told.
	--// A stat at or above Good is green, at or above Mid yellow, else red.
	StatTones = {
		--// fraction of the difficulty's TargetParties
		Served = { Good = 1.0, Mid = 0.7 },
		--// MONEY EARNED as a fraction of a benchmark: TargetParties x
		--// PerTargetParty x the difficulty's CoinMult. ~30 is roughly a
		--// party of two plus an ordinary tip - raise it if green comes
		--// too easily, lower it if nobody ever sees it
		Money = { Good = 1.0, Mid = 0.6, PerTargetParty = 30 },
		--// the final reputation itself. Every shift STARTS at 60
		--// (Config.Reputation.Start), so 60 means "held steady" = yellow
		Reputation = { Good = 70, Mid = 45 },
	},

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
--// THE ON-SCREEN ORDER PANEL (Sep 20 2026, from playtest feedback): a
--// code-built HUD list of open orders, always legible on mobile and PC -
--// the wall OrderBoard was too easy to miss. Server broadcasts the same
--// GetOpenOrders data a few times a second; OrderPanelClient renders.
--// Sorted by order number = the order they were TAKEN (Hora's ask).
Config.OrderPanel = {
	Enabled = true,
	BroadcastHz = 3,             -- server -> client refresh rate
	MaxRows = 6,                 -- rows shown before a "+N more" chip
	LowPatienceBelow = 0.25,     -- a ticket flags red/❗ under this patience
	                             -- (same threshold as the wall board's pulse)
}

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
		PassiveText = "Carries 3 ingredients at once",
		--// THE CHEF'S EDGE (Sep 21 2026, playtest: roles felt
		--// interchangeable): +1 to the 2-item carry limit = real kitchen
		--// throughput. Drives the CarryLimit attribute (carryLimitFor).
		--// Cook windows untouched - THE LAW holds. (The old CollectHoldMult
		--// passive was dead: E is press-everywhere, so there was no hold to
		--// scale.)
		CarryBonus = 1,
		--// TWO ACTIVE SKILLS (Q + R, cooldown-based)
		SkillQ = {
			Id = "DoubleBatch",
			Name = "DOUBLE BATCH",
			Text = "Your next cook makes two dishes!",
			Emoji = "🍳",
			IconId = "rbxassetid://77017928564773",
			CooldownSeconds = 25,
			ArmSeconds = 20,          -- the armed cook must happen within this
		},
		SkillR = {
			Id = "SousChef",
			Name = "SOUS CHEF",
			Text = "Summon a helper who cooks and serves for a while.",
			Emoji = "👨‍🍳",
			IconId = "rbxassetid://135527262830265",
			CooldownSeconds = 45,
			--// The sous chef walks the real fetch->cook->serve loop (see
			--// SkillService). These tune the summoned NPC only - never a
			--// player's cook window, so THE LAW is untouched.
			DurationSeconds = 30,     -- how long it works the kitchen before it poofs
			WalkSpeed = 15,           -- studs/sec ambling pace (a touch quicker than the Helper)
			CookSpeedMult = 1,        -- scales its OWN wait at the station (<1 = faster cook)
			ExtraCookSeconds = 5,     -- flat seconds ADDED to each cook (owner: longer, clearer cook)
			GrabSeconds = 0.6,        -- pause at the fridge/shelf, reads as picking up
			Quality = "Good",         -- what it plates: Good clears tickets with no rep bonus (kept un-OP)
			AnimId = "rbxassetid://98127606934003", -- the hired summon animation
			SummonDelay = 0.6, -- play the animation this long BEFORE she poofs in
			PickSeconds = 8,   -- with 2+ SousChefSpot markers, seconds to pick one
			                   -- (orange glow); no pick in time = nearest is used
		},
		UltimateName = "FLASH FRY!",
		UltimateText = "Instantly finish every pan that is cooking, perfectly!",
		--// Levels 1->5: finish the task, then PAY to upgrade. Steps[L] is the
		--// cumulative counter needed to leave level L; Costs[L] the coins.
		--// Tuned for ~10-15 perfects per focused shift: Lv2 in a shift or two,
		--// max level a real career. Counters counted in the MAIN GAME
		--// (future phase) and persisted via ProfileService.
		UpgradeTrack = {
			Counter = "PerfectCooks", Label = "Perfect cooks",
			Steps = { 15, 40, 80, 150 },
			Costs = { 600, 1200, 2400, 4000 }, -- coins-only levelling (Oct 5 2026, 2x the old prices)
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
		--// TWO ACTIVE SKILLS (Sep 22 2026, cooldown-based, keys Q + R).
		SkillQ = {
			Id = "Dash",
			Name = "DASH",
			Text = "Dash forward fast, great for catching runaways!",
			Emoji = "💨",
			IconId = "rbxassetid://132505436889109",
			CooldownSeconds = 8,
			DashSpeed = 85,       -- studs/sec during the burst (client-side, like sprint)
			DashSeconds = 0.28,   -- burst length (~24 studs)
		},
		SkillR = {
			Id = "PlateJuggler",
			Name = "PLATE JUGGLER",
			Text = "Throw a ready dish straight to its table!",
			Emoji = "🍽️",
			IconId = "rbxassetid://115646653487779",
			CooldownSeconds = 30, -- a strong shortcut (serve without walking), so it's rationed
			--// 3D THROW (Sep 26 2026): press R holding a plated dish - the plate
			--// arcs to the NEAREST table in range that ordered it. In range =
			--// highlighted blue (client). No aiming.
			ThrowRangeStuds = 45,  -- how close to a table you must be to throw it
			ThrowSeconds = 0.55,   -- arc flight time
			ArcHeightStuds = 8,    -- how high the plate arcs
			ThrowAnimId = "rbxassetid://133331799440670", -- the hired throw animation
			ThrowReleaseDelay = 0.4, -- wait this long into the animation before the
			                         -- plate leaves the hand (sync to the throw beat)
		},
		UltimateName = "DOUBLE TIME!",
		UltimateText = "Move at double speed for 20 seconds!",
		--// ~10-15 serves per focused shift
		UpgradeTrack = {
			Counter = "DishesServed", Label = "Dishes served",
			Steps = { 20, 60, 120, 220 },
			Costs = { 600, 1200, 2400, 4000 }, -- coins-only levelling (Oct 5 2026, 2x the old prices)
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
		UltimateText = "Fix the current emergency instantly!",
		--// TWO ACTIVE SKILLS (Sep 21 2026, cooldown-based, keys Q + R).
		--// SkillQ unlocks first, SkillR later (level gate TBD). Both act on
		--// the CURRENT emergency, so they do nothing when nothing is wrong.
		SkillQ = {
			Id = "Toolbelt",
			Name = "TOOLBELT",
			Text = "Get the right tool for the emergency.",
			Emoji = "🧰",              -- shown until IconId is set
			IconId = "rbxassetid://128685287031429",
			CooldownSeconds = 18,
		},
		SkillR = {
			Id = "RushIn",
			Name = "RUSH IN",
			Text = "Teleport straight to the emergency!",
			Emoji = "💨",
			IconId = "rbxassetid://83591326702130",
			CooldownSeconds = 28,
			AnimId = "rbxassetid://100559736443155", -- the hired teleport animation
			TeleportDelay = 0.5, -- play the animation this long BEFORE the blink
			                     -- (so the teleport pose is visible first)
		},
		--// ~1-3 event fixes per shift; rarer actions, shorter track
		UpgradeTrack = {
			Counter = "EventChannels", Label = "Emergencies fixed",
			Steps = { 3, 8, 16, 30 },
			Costs = { 1000, 2000, 4000, 7000 }, -- coins-only levelling (Oct 5 2026, 2x the old prices)
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
		--// TWO ACTIVE SKILLS (Q + R, cooldown-based)
		SkillQ = {
			Id = "WorkTheRoom",
			Name = "WORK THE ROOM",
			Text = "Grab the tips off the nearest couple of tables.",
			Emoji = "💰",
			IconId = "rbxassetid://138682637065156",
			CooldownSeconds = 40,
			MaxTables = 2, -- how many of the CLOSEST paying tables it sweeps at once
		},
		SkillR = {
			Id = "Superfan",
			Name = "SUPERFAN",
			Text = "Charm a table into fans. They tip big and leave a rave review!",
			Emoji = "💖",
			IconId = "rbxassetid://73072528687335",
			CooldownSeconds = 60, -- strong single-table buff (money + rep); kept rare
			AnimId = "rbxassetid://135597748643578", -- hired charm animation; plays BEFORE the pick opens
			AnimDelay = 0.4,         -- play the animation this long before the pick mode opens
			PickSeconds = 10,        -- seconds to pick a table; miss it = skill lost, still on cooldown
			SuperfanMoneyMult = 1.5, -- their bill is multiplied by this when they pay
			SuperfanRepBonus = 6,    -- extra reputation when they leave happy
		},
		UltimateName = "SWEET TALK!",
		UltimateText = "Refill half of one table's patience bar!",
		--// ~4-8 collected payments per shift
		UpgradeTrack = {
			Counter = "PaymentsCollected", Label = "Payments collected",
			Steps = { 12, 35, 70, 130 },
			Costs = { 1600, 3200, 6400, 11000 }, -- coins-only levelling (Oct 5 2026, 2x the old prices)
		},
	},
	--// THE JANITOR (Sep 30 2026): owns the TIDINESS system (CleanlinessService).
	--// Cleaning is a chore, not a skill window, so every number here is legal
	--// under THE LAW. After the inspection grime keeps coming as DIRTY TABLES
	--// (Config.Tidiness.AfterInspection*), so the kit works all shift.
	Janitor = {
		Display = "The Janitor",
		Rarity = "Rare", RarityColor = Color3.fromRGB(245, 184, 65),
		Price = 4000,
		IconId = "rbxassetid://133689458575801", -- class card (Sep 30 2026)
		FlavorText = "Mops first, asks questions never.",
		PassiveText = "Cleans messes faster",
		--// ELBOW GREASE: multiplies the dust specks (vacuum) and plunge taps
		--// (poop) a clean needs. Its OWN attribute (CleanMult), separate from
		--// the Fixer's ChannelMult.
		CleanMult = 0.6,
		SkillQ = {
			Id = "QuickSweep",
			Name = "QUICK SWEEP",
			Text = "Instantly clean the nearest mess!",
			Emoji = "🧹",
			IconId = "rbxassetid://120473172893577", -- QUICK SWEEP (Sep 30 2026)
			CooldownSeconds = 25,
			RangeStuds = 25, -- the mess must be this close (no cross-map zaps)
		},
		SkillR = {
			Id = "GuardedZone",
			Name = "GUARDED ZONE",
			Text = "Drop a caution cone. New messes stay out of its ring!",
			Emoji = "🚧",
			IconId = "rbxassetid://131823394771936", -- GUARDED ZONE (Sep 30 2026)
			CooldownSeconds = 45,
			PlaceAheadStuds = 6,   -- the cone lands this far in front of you
			RadiusStuds = 14,      -- the protected ring's radius
			DurationSeconds = 25,  -- then the cone tips over and fades
			--// A mess that would spawn inside the ring rolls this chance to be
			--// cancelled; if it survives, grime MOVES outside the ring and a
			--// poop WAITS until the cone is gone (one toilet - nowhere to move).
			CancelChance = 0.5,
		},
		UltimateName = "FLOOR BUFFER!",
		UltimateText = "Ride a floor buffer! Move faster and clean any mess you run over.",
		--// ~15-25 cleans in a busy shift
		UpgradeTrack = {
			Counter = "MessesCleaned", Label = "Messes cleaned",
			Steps = { 25, 70, 140, 250 },
			Costs = { 1000, 2000, 4000, 7000 }, -- coins-only levelling (Oct 5 2026, 2x the old prices)
		},
	},
}

--// CLASS SKILLS (Sep 21 2026): each class has up to TWO active, cooldown-
--// based skills on Q and R (the ultimate moved to T / gamepad Y / its
--// on-screen circle). SkillService validates + runs them; SkillClient
--// draws the two buttons. Only the Fixer has skills so far.
Config.Skills = {
	Enabled = true,
	--// STUDIO KNOB (live-ignored): true = every skill unlocked in Studio,
	--// ignoring UnlockLevels below (handy for testing one class's full kit).
	StudioUnlockAll = false, --// the level gate applies in Studio too
	--// keyboard keys per slot (the client also wires touch buttons + gamepad)
	QKey = "Q",
	RKey = "R",
	--// DISPLAY ONLY - the class shop shows it on the ultimate tile.
	--// ChargeClient binds the ultimate to T itself; change both together.
	UltKey = "T",

	--// THE LEVEL GATE (owner spec, Oct 4 2026): the CLASS level each slot
	--// unlocks at. Buying a class = level 1 = Q. Enforced on the game SERVER
	--// (SkillService, ChargeService) off the ClassLevel attribute that
	--// ClassService publishes; the HUD and the lobby only draw it.
	UnlockLevels = { SkillQ = 1, SkillR = 3, Ultimate = 5 },
}

--// the class level a slot ("SkillQ" / "SkillR" / "Ultimate") unlocks at
function Config.SkillUnlockLevel(slot)
	local levels = Config.Skills.UnlockLevels or {}
	return levels[slot] or 1
end

Config.ClassShop = {
	CardOrder = { "Trainee", "Chef", "Waiter", "Fixer", "Charmer", "Janitor" },
	CameraFocus = true,           -- brief camera tween toward the vendor on talk
	TagMaxDistanceStuds = 45,     -- vendor nametag hidden beyond this range
	CameraTweenSeconds = 0.35,
	WalkAwayCloseStuds = 14,      -- wandering off closes the screen

	--// THE CLASSES SCREEN ART KIT (Claude Design, uploaded Oct 4 2026 - all
	--// 18). Skins the ORIGINAL layout (owner call). "Tintable" pieces are
	--// drawn white and coloured in code (rarity / skill-slot colours). The
	--// shop + Staff Room kits fill in the shared sprites (glow, sparkle,
	--// confetti, pop burst, XP bar frame). SliceBy = "Height": the border
	--// scales with the piece's height, so wide rows keep crisp ends.
	Art = {
		ListPanel       = { Image = "rbxassetid://131870514431302", Size = { 512, 1024 }, Slice = { 80, 80, 432, 944 } },
		DetailPanel     = { Image = "rbxassetid://115708091698333", Size = { 640, 1024 }, Slice = { 80, 80, 560, 944 } },
		ClassCard       = { Image = "rbxassetid://118746531994785", Size = { 512, 160 }, Slice = { 150, 40, 472, 112 }, SliceBy = "Height" },
		IconFrame       = { Image = "rbxassetid://76555218449100",  Size = { 192, 192 } },
		StateChip       = { Image = "rbxassetid://125620583793495", Size = { 384, 96 }, Slice = { 48, 30, 336, 66 }, SliceBy = "Height" },
		HeaderBand      = { Image = "rbxassetid://125481457140498", Size = { 640, 160 }, Slice = { 60, 50, 580, 110 } },
		ShowcaseFrame   = { Image = "rbxassetid://101932098176579", Size = { 384, 384 } },
		XPBarFillGold   = { Image = "rbxassetid://93696390740312",  Size = { 768, 96 }, Slice = { 48, 20, 720, 76 }, SliceBy = "Height" },
		SectionBanner   = { Image = "rbxassetid://101957517626262", Size = { 640, 96 }, Slice = { 110, 30, 530, 66 }, SliceBy = "Height" },
		SkillTile       = { Image = "rbxassetid://118731362801245", Size = { 256, 256 } },
		PriceButtonGold = { Image = "rbxassetid://78325364323740",  Size = { 512, 160 }, Slice = { 90, 50, 422, 110 } },
		WalletPill      = { Image = "rbxassetid://86532770174788",  Size = { 512, 128 } },
		CloseBar        = { Image = "rbxassetid://96219733448585",  Size = { 384, 128 } },
		SkillCard       = { Image = "rbxassetid://95814778305310",  Size = { 512, 640 } },
		--// the lock on unowned classes + its UNLOCK animation pieces (the three
		--// padlock images stack pixel-perfectly; the key's teeth point right)
		PadlockClosed   = { Image = "rbxassetid://96229176346722" },
		PadlockBody     = { Image = "rbxassetid://98712535402678" },
		PadlockShackle  = { Image = "rbxassetid://109630743838323" },
		PadlockKey      = { Image = "rbxassetid://84410120304580" },
	},
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
	RecentShiftsCap = 10,         -- the SHIFT LOG keeps this many, newest first

	--// THE STAFF ROOM art kit (Claude Design, uploaded Oct 3 2026 - all 23).
	--// StatsClient also borrows the shop kit's shared pieces (PanelFrame,
	--// CloseButton, Sunburst, Sparkle, ShineStreak, SoftGlow, PopBurst,
	--// FlyingCoin, BistroLights) from Config.Monetization.ShopArt.
	--// "" in any slot = a code-drawn placeholder. Size = the art's pixels;
	--// Slice = the stretchable middle (corners/ends never stretch).
	StaffArt = {
		StaffBadge       = { Image = "rbxassetid://117121583134619", Size = { 1024, 640 } },
		PhotoFrame       = { Image = "rbxassetid://90651633123946",  Size = { 512, 512 } },
		LevelMedal       = { Image = "rbxassetid://125032475036748", Size = { 384, 448 } },
		XPBarFrame       = { Image = "rbxassetid://136175340962616", Size = { 768, 96 }, Slice = { 48, 20, 720, 76 }, SliceBy = "Height" },
		XPBarFill        = { Image = "rbxassetid://78479238895262",  Size = { 768, 96 }, Slice = { 48, 20, 720, 76 }, SliceBy = "Height" },
		Receipt          = { Image = "rbxassetid://87202672687941",  Size = { 512, 1024 }, Slice = { 40, 60, 472, 934 } },
		RegisterSlot     = { Image = "rbxassetid://125034055855124", Size = { 768, 256 } },
		TrophyGold       = { Image = "rbxassetid://119285661184565", Size = { 384, 512 } },
		TrophySilver     = { Image = "rbxassetid://80469846596701",  Size = { 384, 512 } },
		TrophyBronze     = { Image = "rbxassetid://109123348031993", Size = { 384, 512 } },
		--// brackets sit ~64-214 / 809-959 px in: only the plank between stretches
		TrophyShelf      = { Image = "rbxassetid://134825786933706", Size = { 1024, 192 }, Slice = { 230, 0, 794, 192 } },
		ShiftPhotoFrame  = { Image = "rbxassetid://95086881513447",  Size = { 384, 320 } },
		GradeStamp       = { Image = "rbxassetid://77295166646791",  Size = { 256, 256 } },
		HeaderChalkboard = { Image = "rbxassetid://73273922196950",  Size = { 1024, 256 } },
		CorkPattern      = { Image = "rbxassetid://103207561554679" },
		PushPin          = { Image = "rbxassetid://98114023689048" },
	},
	--// the short word inked on a trophy's grade stamp (the full grade shows
	--// in the trophy's hover card). Keys = Config.ShiftReport grades.
	StampText = {
		["5 STARS!"] = "5★",
		["GREAT SHIFT!"] = "GREAT",
		["NOT BAD!"] = "OK!",
		["ROUGH NIGHT..."] = "ROUGH",
		["CLOSED DOWN!"] = "CLOSED",
	},
	--// one icon per stat on screen (registry Key -> image)
	StatIcons = {
		ShiftsCompleted    = "rbxassetid://122006251068260",
		CustomersServed    = "rbxassetid://121098336244793",
		TimeOnFloorSeconds = "rbxassetid://92328396815516",
		PerfectCooks       = "rbxassetid://128765494333574",
		EventChannels      = "rbxassetid://129743100655030",
		MessesCleaned      = "rbxassetid://129680830001902",
		MoneyDeposited     = "rbxassetid://93684001821077",
	},

	--// Hidden = true: the stat still COUNTS and SAVES (ProfileAPI.AddStat only
	--// accepts keys listed here, and class upgrade tracks read some of them) -
	--// it just is not drawn on the stats screen. Owner trim, Oct 2026: shifts /
	--// customers / time on floor live on the badge card; dishes ~= customers;
	--// failures and crimes are no fun to read; greetings / recommendations /
	--// payments / classes owned were clutter.
	Registry = {
		{ Key = "ShiftsCompleted",   Source = "Stats",        Label = "Shifts Completed",   Format = "int",      Default = 0, Hidden = true },
		{ Key = "ShiftsFailed",      Source = "Stats",        Label = "Shifts Failed",      Format = "int",      Default = 0, Hidden = true },
		{ Key = "CustomersServed",   Source = "Stats",        Label = "Customers Served",   Format = "int",      Default = 0, Hidden = true },
		{ Key = "DishesServed",      Source = "TaskProgress", Label = "Dishes Served",      Format = "int",      Default = 0, Hidden = true },
		{ Key = "PerfectCooks",      Source = "TaskProgress", Label = "Perfect Cooks",      Format = "int",      Default = 0 },
		{ Key = "EventChannels",     Source = "TaskProgress", Label = "Emergencies Fixed",  Format = "int",      Default = 0 },
		{ Key = "PaymentsCollected", Source = "TaskProgress", Label = "Payments Collected", Format = "int",      Default = 0, Hidden = true },
		{ Key = "Greetings",         Source = "TaskProgress", Label = "Warm Greetings",     Format = "int",      Default = 0, Hidden = true },
		{ Key = "Recommendations",   Source = "TaskProgress", Label = "Recommendations",    Format = "int",      Default = 0, Hidden = true },
		{ Key = "MessesCleaned",     Source = "TaskProgress", Label = "Messes Cleaned",     Format = "int",      Default = 0 },
		{ Key = "MoneyDeposited",    Source = "Stats",        Label = "Lifetime Earnings",  Format = "money",    Default = 0 },
		{ Key = "TimeOnFloorSeconds", Source = "Stats",       Label = "Time On Floor",      Format = "duration", Default = 0, Hidden = true },
		{ Key = "KitchenCrimes",     Source = "Stats",        Label = "Kitchen Crimes",     Format = "int",      Default = 0, Hidden = true },
		{ Key = "ClassesOwned",      Source = "Computed",     Label = "Classes Owned",      Format = "int",      Default = 0, Hidden = true },
	},
}

----------------------------------------------------------------
-- WIRE FIX (the breaker minigame - see EventSystem + WireFixClient).
-- Every difficulty matches wires now (EASY deals 3, the gentlest); the
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
-- Gated by Difficulty.Interactions.CookMinigame (ON for everyone since
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
	--// OFF (owner, Oct 2026: the ask was visuals only, not gameplay).
	--// true = an optional ONE-stop variant: green Perfect, yellow Good, red
	--// Overcooked, no second swing. false = the game as designed (below).
	OneStop = false,

	--// Every swing rolls a fresh pace from this pool (server-dealt) so
	--// there is no metronome to memorise - each swing needs a real read.
	--// Same pool on every gated difficulty (THE LAW).
	SweepSecondsMin = 0.8,        -- fastest end-to-end arrow pass
	SweepSecondsMax = 1.4,        -- slowest

	--// Where the minigame runs, EVERY station cooks in the same flat time
	--// (owner ruling: the arrow is the skill, the wait is uniform - and
	--// the late game is hard enough already). Follows the GATE, not the
	--// difficulty (THE LAW); an ungated difficulty would keep full timers.
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
-- ON for every difficulty). Spam tap / left-click to fill the bar;
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
-- DINE AND DASH (per-party roll at meal end - NOT a scheduler event).
-- The party bolts for the door instead of paying. Any EMPTY-HANDED
-- player punches them (left-click / tap / gamepad X - no prompt, no
-- hold) to stop them: the bill pays itself instantly with a catch
-- bonus and the whole party gets LAUNCHED. An escape loses the money
-- (and rep, on HARD - Difficulty.Consequences.DashUncaughtRep).
----------------------------------------------------------------
Config.Dash = {
	Chance = { EASY = 0.04, NORMAL = 0.08, HARD = 0.15 }, -- per party, at meal end
	                            -- (EASY at a whisper: the chase is fun, and
	                            -- an escape there costs no rep - money only)
	VIPCanDash = { EASY = false, NORMAL = false, HARD = true }, -- double bills run too
	WarnSeconds = 5,            -- the ❗ window: they sit there LOOKING shifty
	                            -- first - punch them at the table before they bolt
	RunSpeed = 22,              -- dashers sprint (the amble is 12)
	CatchBonusMult = 1.25,      -- caught = the bill plus this (justice pays)
	PunchRangeStuds = 8,        -- server-checked reach
	PunchCooldownSeconds = 0.4, -- per player, so click spam does nothing
	LaunchStuds = 24,           -- how far a punched party flies
	LaunchSeconds = 0.8,        -- airtime of the comedy arc
}

----------------------------------------------------------------
-- THE FOOD CRITIC (at most one per shift - a party of ONE with a
-- restaurant-sized appetite, never a VIP, never dashes). Judges the
-- NORMAL service pipeline, weighted where the owner ruled: PATIENCE
-- and COOKING only (no greet star). Review = 1 base star + up to 2
-- for the patience left when the last dish lands + up to 2 for
-- quality (all Perfect = 2, none Overcooked = 1, any Overcooked = 0).
-- A walkout is an automatic 1 star. The rep swing is the biggest
-- single hit/boost in the game (halved on EASY via RepMult).
----------------------------------------------------------------
Config.Critic = {
	ShiftChance = { EASY = 0.2, NORMAL = 0.35, HARD = 0.5 }, -- rolled at shift start
	EarliestFraction = 0.2,     -- never during the opening calm...
	LatestFraction = 0.75,      -- ...or too late to finish the meal
	MinDishes = 2,              -- one person, orders like a table
	MaxDishes = 2,              -- owner: 3 for one person is kinda awkward
	PatienceMult = 1.25,        -- a bit more patient than regular customers -
	                            -- professionals take their time
	PatienceTwoStars = 0.6,     -- bar fraction left at the last dish for +2
	PatienceOneStar = 0.3,      -- ...for +1
	RepByStars = { -12, -6, 0, 6, 12 }, -- [stars] -> the swing, scaled by...
	RepMult = { EASY = 0.5, NORMAL = 1, HARD = 1 }, -- EASY reviews sting, not wound
	StarsHoldSeconds = 5,       -- the verdict floats overhead this long
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
		MessesCleaned = 4,      -- grime vacuumed / poop plunged (a routine chore, like Seats)
		DashesCaught = 12,      -- punching a dine-and-dasher (rare, heroic)
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
		{ Name = "Door Guard",    Emoji = "🚓", Keys = { "DashesCaught" } },
		{ Name = "Clean Machine", Emoji = "🧹", Keys = { "MessesCleaned" } },
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
		DashesCaught = "%d dashers punched",
		MessesCleaned = "%d messes cleaned",
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

	--// OWNER RULING (Sep 2026): Bruno speaks ONLY at important stages -
	--// at most this many lines per shift, NOT counting the shift-start
	--// and closing calls (those are always allowed). Wired triggers:
	--// phase turns, rep PANIC, emergency STARTS, flood, dash alert.
	--// The other pools below are a phrase library, currently unwired.
	MaxLinesPerShift = 6,

	MinSecondsBetweenLines = 6,   -- global cooldown; urgent lines ignore it
	LineHoldBaseSeconds = 2.5,    -- bubble lingers this long...
	LineHoldPerChar = 0.045,      -- ...plus this per character of the line
	TypeSeconds = 0.6,            -- typewriter reveal duration
	WalkoutGrumbleCooldown = 25,  -- at most one walkout grumble per window
	RepWorryFraction = 0.5,       -- rep below this = worried lines
	RepPanicFraction = 0.25,      -- rep below this = panic lines
	RepRecoverFraction = 0.6,     -- back above this = relief (hysteresis)
	TidyLowFraction = 0.35,       -- tidiness below this = "getting filthy" line
	TidyRecoverFraction = 0.6,    -- back above this = ready to warn again (hysteresis)

	--// PUNCTUATION RULE (owner ruling Sep 29 2026): Bruno's lines use
	--// : ; ! ? , ' . and ellipses (...). NO dashes. Keep new lines to that set.
	Lines = {
		ShiftStart = {
			"Doors are open! Make me proud out there!",
			"Deep breaths, team. Here they come!",
			"A brand new shift! Keep 'em smiling!",
		},
		PhaseBusy = {
			"It's filling up... look alive, team!",
			"Word's getting out about us, stay sharp!",
			"More hungry faces incoming!",
		},
		PhaseRush = {
			"HERE COMES THE DINNER RUSH!!",
			"This is it, people! RUSH TIME!",
			"Hold onto your aprons, it's RUSH hour!",
		},
		Closing = {
			"Last call! Finish those tables and collect!",
			"Doors are shut! Land every last dish!",
		},
		ToiletStart = {
			"The toilet's erupting! Grab the plunger, QUICK!",
			"Not the bathroom again... somebody plunge it!",
		},
		SpillStart = {
			"SPILL on the floor! Broom, broom, BROOM!",
			"Who dropped that?! Sweep it before the guests see!",
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
			"Crisis over. Back to cooking, CAREFULLY!",
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
			"Smiles everywhere, keep it going!",
		},
		Walkout = {
			"We just lost a table! Move faster!",
			"They walked out! My heart breaks...",
		},
		DashStart = {
			"THEY'RE RUNNING WITHOUT PAYING! STOP THEM!",
			"Dine and dash!! Somebody PUNCH them!",
		},
		DashCaught = {
			"HA! Nobody skips a bill in MY diner!",
			"Beautiful punch. Beautiful. I'm so proud.",
		},
		DashEscaped = {
			"They got away... my beautiful money...",
			"Gone! Without paying! I need to sit down.",
		},
		CriticArrive = {
			"A FOOD CRITIC! Act natural! PERFECT dishes only!",
			"That's a critic! One person, big appetite, bigger opinions!",
		},
		CriticHappy = {
			"THE REVIEW IS IN! Frame it! FRAME IT!",
			"Stars! Beautiful stars! I could cry!",
		},
		CriticOkay = {
			"Three stars... we live to cook another day.",
			"An average review. I have complicated feelings.",
		},
		CriticAngry = {
			"A TERRIBLE review!! My grandmother's recipes...",
			"The review is bad. Do NOT read the review.",
		},
		InspectorStart = {
			"Health inspector's on the way! Get this place SPOTLESS!",
			"Inspector incoming! Vacuum, plunge, SCRUB, go go go!",
			"He's coming to judge us! No dust, no mess, MOVE!",
		},
		InspectorPass = {
			"PASSED! Cleanest little diner in town, baby!",
			"Spotless! The inspector LOVED us!",
			"Top marks! I could frame that clipboard!",
		},
		InspectorFail = {
			"He was NOT impressed... keep it tidy next time!",
			"A fine?! My money! CLEAN as you go, team!",
			"Failed the inspection... my poor reputation.",
		},
		TidyLow = {
			"This place is getting FILTHY! Clean it up!",
			"I see dust everywhere, grab a vacuum!",
			"We're a mess! Somebody tidy up before the inspector!",
		},
	},
}

--// THE ORDER TABLET (owner design Sep 29 2026): take orders by pressing food
--// icons on a black tablet with a blue screen. When Enabled, the take-order
--// prompt opens this minigame INSTEAD of the dialogue conversation
--// (OrderTabletClient renders it). No recommend flow - the order is the party's
--// fixed ticket; the waiter just inputs it visually. Set false for the old
--// chat-bubble dialogue.
Config.OrderTablet = {
	Enabled = true,
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
		MessesCleaned = 8,      -- every class earns it; the Janitor just cleans the most
	},

	--// Ability numbers
	SweetTalkRefillFraction = 0.5,   -- half the table's patience bar back

	--// DOUBLE TIME (Waiter ultimate, reworked Sep 27 2026): a big burst of
	--// hustle. Walk AND sprint speeds scale; the feel is applied by
	--// SprintClient (the documented client-side movement exception), the truth
	--// (attribute + timer) stays server-owned. SprintClient also plays the run
	--// animation below for the whole boost, stopping it when it wears off.
	SpeedBoostMult = 2,              -- owner spec: 2x speed
	SpeedBoostSeconds = 20,          -- owner spec: 20s
	WaiterRunAnim = "rbxassetid://74191612940709", -- the DOUBLE TIME run (Sep 27 2026)

	--// FLASH FRY (reworked Sep 27 2026): instantly FINISHES the pans that are
	--// currently cooking (up to FlashFryMaxPans) - grab-ready Perfect at the
	--// station, no wait, no minigame. FlashFryMethodOrder is kept for the old
	--// carried-raw resolution helpers (now unused by the ultimate).
	FlashFryMaxPans = 2,        -- how many currently-cooking pans it finishes
	FlashFryMethodOrder = { "Grill", "Fry", "Ramen" },

	--// FLOOR BUFFER (Janitor ultimate, Sep 30 2026): ride a parts-built floor
	--// polisher. Reuses DOUBLE TIME's SpeedBoostMult attribute (SprintClient
	--// scales WalkSpeed by it) - kept BELOW the Waiter's x2 so the Waiter stays
	--// the speed class. Any floor GRIME within the clean radius of your feet is
	--// cleaned on contact (poop is not floor mess - the buffer skips it).
	BufferSpeedMult = 1.4,
	BufferSeconds = 10,
	BufferCleanRadiusStuds = 5,
	JanitorBufferAnim = "", -- a hired "pushing" animation slots in here later ("" = none)

	--// IN-WORLD CAST ANIMATION per class (hired, plays on the caster - the same
	--// PlayAnim channel the skills use, so everyone sees it). "" = no animation.
	ClassCastAnim = {
		Chef = "rbxassetid://139680062857395", -- SALT BAE (Sep 27 2026)
		Fixer = "rbxassetid://79766154892612", -- REMOTE TAP (Sep 27 2026)
		Charmer = "rbxassetid://83399392691489", -- SWEET TALK rose (Sep 27 2026)
	},
	SaltSeconds = 1.5,          -- how long the Chef's salt sprinkles from the hand

	--// HAND PROPS welded in for the cast (owner may supply a SAFE parts/MeshPart
	--// model of the matching name in ServerStorage - never a Toolbox model).
	--// Grips are tunable so each prop sits right against its animation.
	--// FIXER: "SpeedDialRemote" (big red button, SPEED DIAL).
	RemoteSeconds = 2,          -- how long the remote stays welded (match the anim)
	RemoteClickDelay = 0.5,     -- seconds into the cast that the thumb hits the button
	                            -- (times Sfx.SpeedDialButton - nudge until it lands on the press)
	RemoteGrip = {
		Offset = { 0, 0.4, 0 },      -- studs from the hand center (X, Y, Z)
		TiltDegrees = { 0, 0, 0 },   -- rotate the remote in-grip if it sits wrong
	},
	--// CHARMER: "SweetTalkRose" (a rose offered on SWEET TALK).
	RoseSeconds = 2,            -- how long the rose stays welded (match the anim)
	RoseGrip = {
		Offset = { 0, 0.4, 0 },       -- studs from the hand center (X, Y, Z)
		TiltDegrees = { 0, 0, -90 },  -- stem straight UP, bud at the top (presented)
	},

	--// Bar feel (client)
	BarTweenSeconds = 0.2,
	ReadyPulseSeconds = 0.8,

	--// STUDIO-ONLY (banner testing, Sep 2026): every playtest equips
	--// this class and keeps the ultimate charge FULL - no command bar.
	--// Ignored on live servers. Set StudioFullCharge = false (and the
	--// key "") when ultimate testing ends, or charge earning can never
	--// be playtested in Studio.
	StudioFullCharge = true, --// TEMP Janitor test (Sep 30 2026) - set false for real play
	StudioClassKey = "Janitor", --// TEMP Janitor test - set "" for real play

	--// THE CAST BANNER (Sep 2026). Cosmetic only - nothing here touches
	--// charge, abilities or THE LAW. Caster sees their own avatar posed
	--// for their class sliding in from the left; teammates get a toast.
	--// OWNER RULING SCOPE: static UI-viewport poses are allowed; live
	--// in-world character animation remains hired-out animator work.
	CastBanner = {
		Enabled = true,

		SlideInSeconds = 0.35,      -- Back/Out: a small overshoot snap
		HoldSeconds = 1.4,          -- also the length of the camera push
		SlideOutSeconds = 0.3,
		WidthScale = 0.34,          -- fraction of screen width
		HeightScale = 0.36,         -- fraction of screen height

		CameraDistance = 8.5,       -- studs from the focus point at rest
		CameraPushStuds = 0.8,      -- starts this much further back
		CameraOrbitDegrees = 25,    -- three-quarter view
		FieldOfView = 32,           -- narrow = portrait, wide = fish-eye
		FocusBelowHeadStuds = 1.3,  -- lower = more chest/arms in frame
		                            -- (raise CameraDistance too for R6's big heads)

		ToastSeconds = 2.5,         -- teammates' "X used Y!" line

		--// The Chef's banner clone wears a code-built toque (parts, no
		--// assets); existing HAT accessories come off first (hair stays).
		ChefHatOnBanner = true,

		--// Owner-imported art behind the avatar, per class ("" = the
		--// plain cream panel). Cropped to fill; keep image centers calm
		--// so the avatar reads over them.
		BackgroundImages = {
			Chef = "rbxassetid://126303036451477", -- flame burst (Sep 2026)
			Waiter = "rbxassetid://126138757523220", -- plate rush (Sep 2026)
			Fixer = "rbxassetid://131314378577972", -- tool lightning (Sep 2026)
			Charmer = "rbxassetid://124463219290182", -- hearts & rose (Sep 2026)
		},

		--// Poses are per-class: a class with NO Poses entry shows its
		--// natural stance + camera push (the Chef does - owner call,
		--// Sep 2026, after posing read badly on his bundle rig).
		PosesEnabled = true,

		--// Degrees {X, Y, Z} added to each joint's rest rotation.
		--// Chest-up only, so legs are never posed; missing joints are
		--// skipped. STARTING POINTS - signs may need flipping once seen.
		Poses = {
			--// Chef: SALT BAE (Sep 27 2026) - right arm up pinched to sprinkle,
			--// left forearm held across the body, head tilted down watching.
			--// Swings into Motion.Chef (the sprinkle downstroke). Signs may need
			--// flipping once seen on the rig.
			Chef = {
				Waist = { 0, 15, 0 },
				Neck = { 12, 0, 0 },
				RightShoulder = { -100, 0, 25 },
				RightElbow = { 70, 0, 0 },
				LeftShoulder = { -30, 0, -20 },
				LeftElbow = { 90, 0, 0 },
			},
			Waiter = {   -- mid-SPRINT, stride A: lean in, arms pumping
				Waist = { 15, -10, 0 },
				Neck = { -10, 10, 0 },
				RightShoulder = { -75, 0, 10 },
				RightElbow = { 60, 0, 0 },
				LeftShoulder = { 45, 0, -10 },
				LeftElbow = { 25, 0, 0 },
			},
			Fixer = {    -- wrench over the shoulder
				Waist = { 0, 20, 0 },
				Neck = { 0, -15, 0 },
				RightShoulder = { -60, 0, 60 },
				RightElbow = { 90, 0, 0 },
			},
			Charmer = {  -- finger-guns, head tilt
				Waist = { 0, -10, 5 },
				Neck = { 0, 10, -12 },
				RightShoulder = { 0, 0, 80 },
				LeftShoulder = { 0, 0, -30 },
			},
		},

		--// R6 OVERRIDES: R6 joints hinge on different axes, so translated
		--// R15 numbers can read as nothing. A class listed here uses
		--// these tables DIRECTLY on R6 rigs (keys are R6 joint names).
		--// R6 hand-tuned overrides, filled per class only when the
		--// auto-translated numbers read wrong on a REAL R6 rig
		PosesR6 = {},
		MotionR6 = {},

		--// BANNER MOTION (owner request, Sep 2026): a class listed here
		--// SWINGS between its Pose (above) and this second pose for the
		--// banner's hold - joints lerped and the rig re-solved per frame,
		--// entirely inside the viewport. NOT animation assets, NOT the
		--// live character. Classes without an entry stay a static pose.
		Motion = {
			Chef = {     -- SALT BAE sprinkle: the right forearm swings DOWN and
				Waist = { 0, 12, 0 },     -- back up, releasing the salt; left arm holds
				Neck = { 16, 0, 0 },
				RightShoulder = { -85, 0, 25 },
				RightElbow = { 40, 0, 0 },
				LeftShoulder = { -30, 0, -20 },
				LeftElbow = { 90, 0, 0 },
			},
			Waiter = {   -- stride B: the OPPOSITE arm swing - swinging
				Waist = { 15, 10, 0 },   -- between A and B is a run cycle
				Neck = { -10, -10, 0 },
				RightShoulder = { 45, 0, 10 },
				RightElbow = { 25, 0, 0 },
				LeftShoulder = { -75, 0, -10 },
				LeftElbow = { 60, 0, 0 },
			},
			Fixer = {    -- the wrench CRANK: arm pumps down from the
				Waist = { 0, 10, 0 },     -- shoulder carry and back up
				Neck = { 0, -8, 0 },
				RightShoulder = { -25, 0, 35 },
				RightElbow = { 45, 0, 0 },
			},
			Charmer = {  -- the SWAY: finger-guns swap sides, head tilts
				Waist = { 0, 10, -5 },    -- the other way - maximum smug
				Neck = { 0, -10, 12 },
				RightShoulder = { 0, 0, 30 },
				LeftShoulder = { 0, 0, -80 },
			},
		},
		MotionSwingsPerHold = 3,    -- full there-and-back swings per hold
	},
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
	--// counts from 1, not MinPlayers: a Studio solo test keeps solo pacing
	local clamped = math.clamp(playerCount or 1, 1, Config.MaxPlayers)
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
	HandleDropStuds = 0.5,

	--// Where a served plate lands: 0 = table centre, 1 = the customer's seat
	--// position. Just past halfway puts it in front of them, on the table.
	TablePlateInset = 0.55,
	--// Sits the plate this far ABOVE the wood. Raise it if a plate looks
	--// sunk (a mesh plate whose crockery dips below its own bounding box,
	--// like Yamasaki's - the flush calc rests the BOX on the wood, so the
	--// dip needs covering here). Lower it if plates float.
	TablePlateLiftStuds = 0.35,

	--// PER-MAP override of the lift above. Each map lays its tables with
	--// its own plate model, and how much air a plate needs is a property
	--// of that crockery, so one number cannot serve every map. A map
	--// listed here uses its own value; anything unlisted keeps the
	--// default. Manila's plates rest flush, Yamasaki's need the 0.35.
	TablePlateLiftByMap = {
		Filipino = 0.02,
	},

	--// Keeps a served plate off the very edge of the table. Raise it if plates
	--// look like they are about to slide off.
	TablePlateEdgeMargin = 0.9,

	--// A landing ray that stops THIS far above the table's own top hit
	--// DECOR (a cup, a vase), not tabletop - the plate slides sideways to
	--// a clear patch instead of perching on it (Yamasaki's matcha cups).
	TablePlateDecorToleranceStuds = 0.4,

	--// HOW FAR a landing ray may disagree with the tagged table part's own
	--// top before it is thrown out as "that is not the table".
	--//
	--// The landing ray ignores everything tagged Table, because in Yamasaki
	--// the tag sits on an invisible anchor a stud off the visible wood. When
	--// the tag is instead on the REAL tabletop (Manila), that same exclusion
	--// makes the ray pass clean through and hit the FLOOR - and a plate
	--// served onto the floor is exactly what it looks like. Rays this far
	--// out are discarded and the tagged part's own top is used instead, so
	--// both ways of tagging a table work.
	--//
	--// Raise it only if a map's anchor genuinely sits further from its wood
	--// than this; it is the ceiling on how wrong a mis-tag can go.
	TablePlateSanityStuds = 2,

	--// THE PLATE ECONOMY. However many PassSlot models exist is how many
	--// dishes can be in flight at once. A plate is only free again once its
	--// table's payment has been collected (owner's ruling), so an uncollected
	--// payment holds a plate hostage - see the reclaim paths in PassService.
	ReclaimOnPlayerLeave = true,   -- carrier disconnects or dies -> plate home
	ReclaimOnShiftEnd = true,      -- never start a shift short of plates
}

----------------------------------------------------------------
-- MAPS
--
-- One place, many restaurants. Id is the MODEL NAME inside
-- ServerStorage.Maps - MatchServer clones it by that name, so a typo here is
-- a shift with no restaurant.
--
-- The lobby renders this list and the lobby SERVER validates against it, so a
-- modified client cannot ask for a map that does not exist.
--
-- Adding a map later: build the model, drop it in ServerStorage.Maps, add a
-- row here. No code changes anywhere.
----------------------------------------------------------------
Config.Maps = {
	{
		Id = "Diner",                 -- model name in ServerStorage.Maps
		Display = "Route 67 Diner",   -- used in logs and as the art placeholder
		--// The bar IS this image. Empty shows a lettered placeholder instead,
		--// so a map without art yet is still a correct-looking card.
		ImageId = "rbxassetid://126553494895194",
		Available = true,
		ShiftBarIcon = "🍔", --// the traveller on the HUD's shift bar
		--// THE MENU: what this restaurant's customers order (dish -> roll
		--// weight), and through it which ingredients its kitchen stocks -
		--// the recommend picker and the fridge/shelf menus follow this
		--// list too. A map with no Menu falls back to Config.OrderWeights.
		Menu = { Burger = 5, Fries = 4, GrilledSteak = 3 },
	},
	{
		Id = "Sushi", --// the Id is plumbing and never changes; the NAME is below
		Display = "Yamasaki Ramen", --// matches the banner art (owner, Sep 17)
		ImageId = "rbxassetid://130991090145749", --// owner's banner, de-bordered (Sep 17 2026)
		Available = true, --// LIVE (Sep 17 2026): pickable in the lobby
		ShiftBarIcon = "🍜", --// the ramen bowl walks Yamasaki's shift bar
		--// Full Japanese - no diner carry-overs (owner ruling, Sep 2026).
		Menu = { Karaage = 5, TempuraShrimp = 4, Ramen = 3 },
		--// Seated guests DISSOLVE at the table instead of walking back
		--// out (owner ruling: upstairs rooms, nobody hikes down). Also
		--// disables dine-and-dash here - you cannot bolt for the door on
		--// a map where leaving is a fade. Queue walkouts still walk.
		LeaveByFade = true,
	},
	{
		Id = "Filipino", --// MUST match the model name in ServerStorage.Maps
		Display = "Manila Kitchen", --// rename freely; the Id is the plumbing
		ImageId = "", --// owner's banner pending; shows a lettered placeholder
		Available = true,
		ShiftBarIcon = "🍚",
		Menu = { SteamedRice = 5, Lumpia = 4, AdoboPork = 3 },
	},
}

--// The map a party gets when nothing valid was chosen. Must be an Available
--// Id above, or the first shift of a fresh install has nowhere to happen.
--// THE MAP BAR in the picker: WIDTH ON WIDTH DIVIDED BY HEIGHT of your art.
--//
--// The bar takes the panel's full width and derives its HEIGHT from this, so
--// the image fills it exactly with no border showing and nothing cropped -
--// and it stays exact if the panel is ever resized.
--//
--// Current art is 1024 x 205, so 1024/205. Keep new map art to the same
--// shape and nothing here needs touching.
Config.MapCardAspect = 1024 / 205

--// ===== DEV SWITCH - PUT THIS BACK TO true BEFORE PUBLISHING =====
--// false stops the stored map being cloned in at match start, so a map being
--// built directly in Workspace is not buried under a second copy of another
--// one. Whatever is already in Workspace is what gets played.
--// Every system still finds its objects by tag, so a half-built map works as
--// far as its tags go and warns about the rest.
Config.LoadMapOnStart = true --// ON (Sep 17 2026): MatchServer clones
                             --// ServerStorage.Maps[MapId] at boot - the
                             --// Workspace must hold NO map copy anymore

Config.DefaultMapId = "Diner"

--// THE TUTORIAL GUIDE (lobby NPC, Sep 18 2026): a rig tagged
--// TutorialGuide offers the guided first shift. First E asks, a second
--// E within ConfirmSeconds reserves a PRIVATE solo server and
--// teleports with Mode = "TUTORIAL" - MatchServer reads that on the
--// game side. Numbers only; the script is the lobby's TutorialGuide.
Config.TutorialPortal = {
	TagMaxDistanceStuds = 60, -- the HOW TO PLAY sign fades past this
	BubbleSeconds = 5,        -- speech bubble linger
	ConfirmRangeStuds = 16,   -- a YES from farther away than this is stale
	Difficulty = "EASY",      -- the training shift runs gentle
	MapId = "Diner",          -- Bruno teaches at the Diner
	Greetings = {
		"New here? I can get you trained!",
		"The best training shift in town!",
		"Every great cook started somewhere!",
	},
	AskTitle = "TRAINING SHIFT",
	AskLine = "Do you want to play the tutorial?",
	YesLabel = "YES!",
	NoLabel = "NO",
	StudioLine = "Teleports do not run in Studio!",
	SendLine = "Off you go! Your trainer is waiting!",
	FailLine = "Hmm, the door is stuck. Try again!",
}

--// PHASE BANNERS (owner spec, Sep 18 2026): big animated centre-screen
--// announcements when the shift changes stage, each with its own
--// entrance (drop / slide / slam / fade) and a brief screen dim.
--// Pure UI animation - PhaseBannerClient. Keys match shift.Phase.
Config.PhaseBanner = {
	StudioParade = false,   -- STUDIO KNOB (live-ignored): play all four
	                        -- banners back to back shortly after joining,
	                        -- for review without a full shift.
	DimTransparency = 0.45, -- how dark the room gets behind the words
	DimSeconds = 0.25,      -- dim fade in/out time
	HoldSeconds = 1.4,      -- how long the words sit before leaving
	Labels = {
		Calm = "OPENING!",
		Building = "MID SHIFT!",
		Crescendo = "RUSH!",
		Closing = "CLOSING!",
	},
}

--// STUDIO-ONLY map override: while building a map, point every Studio
--// playtest at it - customers order ITS menu, the kitchen stocks ITS
--// ingredients - without the lobby handoff or a per-test command line.
--// "" falls back to DefaultMapId. Live servers ignore this completely:
--// the lobby's teleport data always wins there.
Config.StudioMapId = "Filipino" --// building out Manila (Sep 27)

--// STUDIO-ONLY spawn burst: this many parties march in the moment the
--// shift goes RUNNING, so route/seating tests need no command bar.
--// The normal spawn trickle continues after the burst. 0 = off (normal
--// opening). Ignored on live servers - set 0 anyway when map testing ends.
Config.StudioSpawnBurst = 0 --// real pacing (set N to spawn a busy room at the start for testing)

--// STUDIO-ONLY (live-ignored): the moment the shift goes RUNNING, auto-spawn
--// a full house AND auto-seat + auto-order them, so a skill/cooking test has
--// open orders instantly with no manual seating. Uses StudioSpawnBurst for
--// the count (min 4). true = on. TEMP for the Sous Chef test - set false for
--// normal play.
Config.StudioPreSeat = false --// was TEMP-on for skill tests; off so orders are taken manually (tablet)

--// STUDIO-ONLY (live-ignored): auto-fire this event a few seconds after
--// the shift goes RUNNING, so an emergency test needs no command bar.
--// "" = off. Names: Spill / ToiletEmergency / GreaseFire / PowerOutage.
Config.StudioForceEventOnStart = "" --// off (rapid events below drive testing now)

--// STUDIO ONLY (live-ignored): keep emergencies coming for testing. When on,
--// the scheduler shrinks its gaps so a new event rolls a few seconds after the
--// last one clears. Set false for real pacing.
Config.StudioRapidEvents = false --// real event pacing (set true to spam events for testing)
Config.StudioRapidGapSeconds = 6 --// seconds of quiet before the next event rolls
Config.StudioForceEventDelaySeconds = 3

--// Whether a given id is a real, playable map. The lobby server gates every
--// party on this - never trust a MapId that arrived from a client.
function Config.IsPlayableMap(mapId)
	if type(mapId) ~= "string" then
		return false
	end
	for _, map in ipairs(Config.Maps) do
		if map.Id == mapId and map.Available then
			return true
		end
	end
	return false
end

function Config.MapById(mapId)
	for _, map in ipairs(Config.Maps) do
		if map.Id == mapId then
			return map
		end
	end
	return nil
end

--// The menu the active map's customers order from. Callers pass
--// workspace:GetAttribute("MatchMapId") (published by MatchServer);
--// unknown or unset ids get the global fallback, so a Studio session
--// with no teleport data still serves the diner menu.
function Config.MenuForMap(mapId)
	local map = Config.MapById(mapId)
	return (map and map.Menu) or Config.OrderWeights
end

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
----------------------------------------------------------------
-- EVENT ARROW (EventArrowClient): an edge-of-screen pointer toward
-- whatever the current crisis needs - the TOOL mount first when the
-- fix needs a tool you aren't holding, then the emergency itself, and
-- any dine-and-dasher mid-bolt. Hidden while the target is on screen
-- (its own billboards take over there).
----------------------------------------------------------------
Config.EventArrow = {
	EdgeMarginPx = 56,            -- how far the arrow floats from the edge
	RefreshSeconds = 0.2,         -- how often targets are re-picked

	--// THE GUIDE LINE (Sep 21 2026, playtest: a plunger "in the kitchen"
	--// that nobody could find). A beam runs from the player to the
	--// emergency target, so you follow a LINE to it instead of hunting.
	--// The edge badge stays, but only when the target is off screen.
	BeamEnabled = true,
	BeamColor = Color3.fromRGB(229, 72, 77), -- tomato: urgent
	BeamWidthStuds = 0.6,
	BeamTransparency = 0.25,
}

----------------------------------------------------------------
-- GESTURES (Roblox's own catalog emote animations - PLAYED on customer
-- rigs at story moments, never authored: the hired-animator ruling
-- covers custom poses, not prefab Roblox assets). Classic R15 emote
-- ids, Roblox-owned so they play in any experience. Empty = off.
-- If one stays silent in a test, the id needs re-checking in Studio.
----------------------------------------------------------------
Config.Gestures = {
	Wave = "rbxassetid://507770239",   -- greeted at the door: the party waves back
	Point = "rbxassetid://507770453",  -- ordering: the speaker points it out
	Cheer = "rbxassetid://507770677",  -- a dish lands: the table celebrates
	Sit = "rbxassetid://2506281703",   -- held (looped) while parked on a chair
	Walk = "rbxassetid://507777826",   -- the catalog R15 walk cycle - looped by
	                                   -- customers AND the Helper while moving
}

----------------------------------------------------------------
-- THE ENTRANCE CUTSCENE (owner trial, Oct 2026). When a shift's PREP
-- begins, each player gets a short film: an aerial sweep of the map, their
-- character walking in along the queue line, a look around the restaurant,
-- then the "fire up" pose (the catalog Cheer emote - PLAYED, never
-- authored) with a title slam. Skippable. EntranceCutscene.client.luau
-- plays it; everything is local to each player.
-- TO REMOVE: set Enabled = false (or delete that script + this block).
----------------------------------------------------------------
Config.EntranceCutscene = {
	Enabled = false, --// OFF (owner, Oct 4 2026): not up to standard yet - true to bring it back
	OncePerSession = true,       -- false = every shift's PREP, not just the first
	Skippable = true,
	--// the walk-in starts this far BEHIND the back of the queue (along the
	--// queue line) and ends at the front. Parts tagged EntranceStart /
	--// EntranceEnd (owner-placed, optional) override the automatic path.
	WalkBackStuds = 18,
	WalkTimeoutSeconds = 6,      -- never wait forever on a blocked walk
	--// THE SHIFT WAITS for every player's film to finish before it starts
	--// (no customers meanwhile) - but never longer than this past the prep
	--// countdown, so one stuck / AFK player cannot hold everyone up
	MaxHoldSeconds = 20,
	--// shot lengths (seconds)
	AerialSeconds = 3.2,         -- the opening SHOWCASE view (a part tagged
	                             -- EntranceCam sets it; no rotation)
	ShowcaseDriftStuds = 3,      -- slow push-in over that shot (0 = dead still)
	LookAroundSeconds = 2.6,
	PoseSeconds = 3.2,
	PoseGesture = "Cheer",       -- a key of Config.Gestures (the "fire up")
	TitleText = "LET'S COOK!",
	LetterboxScale = 0.1,
}

----------------------------------------------------------------
-- PLACES (the two-place experience, both under Magistrate Studios).
-- Shared Config on purpose: either place can address the other.
----------------------------------------------------------------
Config.Places = {
	LobbyPlaceId = 132877152120112,
	GamePlaceId = 97952115394249,
}

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
		--// Owner ruling (Sep 2026): kitchen-only - audible near the
		--// stations, gone by the dining room
		CookFry = {
			Id = "75511010485145", Volume = 0.5, Loop = true,
			MinStuds = 8, MaxStuds = 25,
		},
		--// The ramen cooker's bubbling broth. Id pending the sound
		--// person - "" is silent, same as every unset sound here.
		--// Manila: the rice cooker's hiss and the adobo pot's simmer
		CookRice = {
			Id = "", Volume = 0.45, Loop = true,
			MinStuds = 8, MaxStuds = 25,
		},
		CookPot = {
			Id = "", Volume = 0.5, Loop = true,
			MinStuds = 8, MaxStuds = 28,
		},

		CookRamen = {
			Id = "106600879170754", Volume = 0.5, Loop = true,
			MinStuds = 8, MaxStuds = 25,
		},
		CookGrill = {
			Id = "77924122314675", Volume = 0.5, Loop = true,
			MinStuds = 8, MaxStuds = 25,
		},

		--// EMERGENCIES ---------------------------------------------------
		--// Alerts carry across the whole restaurant - the point is that
		--// nobody can miss them - so they are global.
		ToiletAlert = { Id = "", Volume = 0.9, Global = true },
		FireAlert   = { Id = "133849873643710", Volume = 0.7, Global = true },
		PowerAlert  = { Id = "", Volume = 0.7, Global = true }, -- owner: louder.
		SpillAlert  = { Id = "", Volume = 0.9, Global = true }, -- the splat (owner: id pending)

		--// Mopping it up. Positional and looping, like the other fixes, so
		--// the room can hear someone dealing with it.
		MopSweep = {
			Id = "86605317124827", Volume = 0.9, Loop = true,
			MinStuds = 6, MaxStuds = 30,
		},

		--// MINIGAME FEEDBACK -----------------------------------------------
		--// Played LOCALLY, only for the player who answered - a blip about a
		--// panel nobody else can see should not carry across the restaurant,
		--// and four people answering at once should not stack. Shared by all
		--// three games: the maths quiz, the card match, and the cook timing
		--// bar (green = right, red = wrong).
		AnswerRight = { Id = "100414462804328", Volume = 0.9 },
		AnswerWrong = { Id = "96876122441863", Volume = 0.9 },
		--// THE SHOP (Oct 2026). ShopPurchase borrows AnswerRight's chime until
		--// a proper cha-ching is picked; ShopClick is silent until one is set.
		ShopPurchase = { Id = "100414462804328", Volume = 0.9 },
		ShopClick = { Id = "", Volume = 0.5 },

		--// THE SHIFT REPORT. LOCAL - every player has their own report on
		--// screen. A thud as each stat slaps onto the board, and a heavier
		--// one for the verdict stamp dropping onto it last.
		ReportSlap = { Id = "", Volume = 0.9 },
		ReportStamp = { Id = "", Volume = 1.0 },

		--// ULTIMATES --------------------------------------------------------
		--// The bar hitting 100%. LOCAL, for that player only - it is a
		--// private "you can fire now", and four bars filling during a busy
		--// Crescendo should not all sound across the room.
		UltimateReady = { Id = "127718379694875", Volume = 0.7 },

		--// Firing it. Positional at the caster with a wide radius, so the
		--// team hears WHO just did something big without it being a global
		--// blast every single time.
		UltimateUsed = {
			Id = "84105506913051", Volume = 0.85,
			MinStuds = 12, MaxStuds = 80,
		},
		                              -- NOTE: Id still empty = silent until set!

		--// The FIXES are positional: you hear them where the work is.
		ToiletFix = {
			Id = "", Volume = 0.9, Loop = true,
			MinStuds = 6, MaxStuds = 30,
		},
		BreakerFix = {
			--// UNWIRED since the owner ruling (Sep 2026): the wire fix
			--// sounds per CONNECTION (WireConnect below), not per session
			Id = "87055568032543", Volume = 0.9, Loop = true,
			MinStuds = 6, MaxStuds = 30,
		},
		--// Client-local one-shot: a little zap each time a wire seats
		--// (played by WireFixClient directly, not the server module)
		WireConnect = { Id = "87055568032543", Volume = 0.9 },
		FireExtinguish = {
			Id = "84243999556475", Volume = 0.9, Loop = true,
			MinStuds = 8, MaxStuds = 40,
		},

		--// Relief beat when the lights come back. Global - everyone was in
		--// the dark together.
		PowerRestored = { Id = "", Volume = 0.9, Global = true },

		--// CUSTOMERS -----------------------------------------------------
		--// The greeting when a party gives you their order - the "hi!" beat
		--// Work at a Pizza Place uses. At the table, so a busy room still
		--// tells you WHICH party just ordered.
		OrderTaken = {
			--// Well above 1.0 (Roblox allows up to 10): the source clip is
			--// a quiet recording, so the number has to carry it (owner, Sep 19)
			Id = "118548572543142", Volume = 3.0,
			MinStuds = 12, MaxStuds = 45,
		},

		--// The whole party finally has everything they asked for. Plays on
		--// the LAST dish only, not on every plate - it is the payoff beat.
		PartyServed = {
			--// Well above 1.0: quiet source clip, the payoff beat must land (Sep 19)
			Id = "115870238254338", Volume = 3.0,
			MinStuds = 12, MaxStuds = 50,
		},

		--// At the customer, so you can tell WHICH table just gave up.
		CustomerAngry = {
			Id = "119046821634222", Volume = 0.9,
			MinStuds = 10, MaxStuds = 55,
		},

		--// SUPPLIER ------------------------------------------------------
		--// The order confirmation plays at the board you just used; the
		--// arrival plays at the truck so it pulls your attention outside.
		SupplyOrdered = {
			Id = "", Volume = 0.9,
			MinStuds = 8, MaxStuds = 35,
		},
		TruckArrived = {
			Id = "110342333875026", Volume = 0.9,
			MinStuds = 15, MaxStuds = 90,
		},

		--// CLASS SKILLS ----------------------------------------------------
		--// Positional at the caster unless noted, so teammates hear WHO
		--// did it and roughly where. Paste ids between the quotes; an empty
		--// Id is silence, never an error.

		--// Cash in hand: any player collecting a table's payment, and the
		--// Charmer's Q (WORK THE ROOM) - which plays it ONCE for the whole
		--// sweep, not once per table.
		ChaChing = { Id = "", Volume = 0.9, MinStuds = 10, MaxStuds = 45 },

		--// Charmer R (SUPERFAN): the blown kiss, on the charm animation as
		--// the table is picked
		BlowKiss = { Id = "", Volume = 0.9, MinStuds = 10, MaxStuds = 45 },

		--// Waiter Q (DASH): the burst forward
		Dash = { Id = "", Volume = 0.9, MinStuds = 10, MaxStuds = 45 },

		--// Waiter R (PLATE JUGGLER): the plate leaving the hand, on the throw
		--// beat (Classes.Waiter.SkillR.ThrowReleaseDelay), not the key press
		PlateThrow = { Id = "", Volume = 0.9, MinStuds = 10, MaxStuds = 45 },

		--// Fixer R (RUSH IN): the instant-transmission blink. Rides on the
		--// Fixer, so it travels with them to the emergency.
		RushInTeleport = { Id = "", Volume = 0.9, MinStuds = 12, MaxStuds = 60 },

		--// Chef R (SOUS CHEF): the summon, from the moment the Chef starts the
		--// gesture - covers the wind-up and the smoke burst she appears from
		SousChefSummon = { Id = "", Volume = 0.9, MinStuds = 12, MaxStuds = 60 },

		--// Fixer ULTIMATE (SPEED DIAL): the thumb hitting the big red button.
		--// Timed by Config.Ultimates.RemoteClickDelay to land on the press in
		--// the animation. Plays ON TOP of UltimateUsed, which fires at the cast.
		SpeedDialButton = { Id = "", Volume = 0.9, MinStuds = 12, MaxStuds = 60 },

		--// RHYTHM TAP (the cooking minigame). LOCAL, for the player playing it
		--// only - same reasoning as AnswerRight/Wrong. Played on the press
		--// itself, not the server's reply, because a rhythm game whose hit
		--// sound arrives a round trip late feels broken. Only fires when a
		--// note is actually in reach, so mashing stays quiet.
		RhythmTap = { Id = "", Volume = 0.8 },  --// a round note, tapped
		RhythmHold = { Id = "", Volume = 0.8 }, --// a long note, as the hold begins

		--// HEALTH INSPECTOR verdict. Global: the whole team passed or failed
		--// together. The first-visit WARNING ("let it slide") plays neither.
		InspectorPass = { Id = "", Volume = 0.9, Global = true },
		InspectorFail = { Id = "", Volume = 0.9, Global = true },

		--// SHIFT ---------------------------------------------------------
		--// Everyone hears these together, wherever they happen to be.
		ShiftStart = { Id = "", Volume = 0.9, Global = true },
		ShiftEnd   = { Id = "", Volume = 0.9, Global = true },
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
	Volume = 0.65, --// dropped 0.1 so it sits further under the louder SFX (Sep 19)

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

	--// RESTAURANT SOUNDTRACKS - one set per map, keyed by the map's Id in
	--// Config.Maps. Played by ShiftMusicClient, following the shift clock:
	--//
	--//   Calm       0:00-2:00   phase 1, shift start
	--//   Building   2:00-5:00   phase 2, mid shift
	--//   Crescendo  5:00-end    phase 3, busy - and it keeps playing through
	--//                          closing until the last table has left
	--//
	--// Every track LOOPS seamlessly (Sound.Looped), so a track shorter than
	--// its play time just goes round again with no cut.
	--//
	--// PlaySeconds = how long the phase's track plays before it starts to
	--// fade out. Leave it out to loop until the shift ends.
	--//
	--// Paste ids between the quotes. An empty Id is silence for that phase,
	--// never an error. A map with no entry here has no shift music.
	--// To hear a map in Studio, point Config.StudioMapId at it.
	--// THE TUTORIAL'S OWN TRACK. A tutorial server has no phases worth
	--// scoring - the clock is frozen and the night never turns - so this one
	--// track loops for the whole lesson, whatever map it runs on, and takes
	--// priority over MapSoundtracks below. Empty = silence, never an error.
	TutorialTrack = {
		Id = "99467510202385",
	},

	MapSoundtracks = {
		Sushi = {
			Calm = {
				Id = "99467510202385",
				PlaySeconds = 100,   -- 1:40 of the 2:00 phase, then fades
			},
			Building = {
				Id = "108056046088233",
				PlaySeconds = 160,   -- 2:40 of the 3:00 phase, then fades
			},
			Crescendo = {
				--// TWO PARTS. The intro plays ONCE and is never looped - it is
				--// the slow-tempo opening that winds up to speed. The instant
				--// it finishes, Id takes over and loops until the last table
				--// leaves. The handover is butt-joined, not crossfaded, so the
				--// tempo lands where the composer put it.
				--//
				--// Leave IntroId empty to just loop Id from the start.
				IntroId = "118748463664902",
				Id = "126450480293212",
				--// no PlaySeconds: loops until the last table leaves
			},
		},
	},

	--// How the shift music moves between states
	ShiftFadeInSeconds = 2,      -- a phase track rises in rather than cutting on
	ShiftFadeOutSeconds = 6,     -- "slowly fade out" at the end of PlaySeconds,
	                             -- and when the shift ends
	ShiftVolume = 0.6,           -- sits under prompts and event alerts

	--// Intro -> loop handover. The loop starts this long before the intro
	--// actually ends, so they butt together instead of leaving a hole. Small
	--// enough that the overlap is inaudible; 0 would risk a gap.
	ShiftIntroHandoffSeconds = 0.05,

	--// Someone joining mid-phase has missed the wind-up, so past this many
	--// seconds into a phase the intro is skipped and the loop starts straight
	--// away. Without it, a late joiner would hear the slow opening while
	--// everyone else is already at full tempo.
	ShiftIntroSkipAfterSeconds = 3,
}

----------------------------------------------------------------
-- PASSIVES (Oct 2026, owner design): passives moved OFF the classes and
-- into the crate system. Each passive has ONE fixed rarity and ONE value.
-- A player equips one (SlotCount) and ClassService publishes its Effects
-- as Player attributes - the same attribute seam the old class passives
-- used, so every system reads them the same way. Everything here is
-- PERSONAL: a passive only ever affects the player who has it.
--
-- Effect attributes (missing = the Defaults value, i.e. no effect):
--   StaminaDrainMult / StaminaRegenMult  sprint feel (SprintClient)
--   WalkSpeedMult                        all movement (SprintClient)
--   RushSpeedMult                        movement during RUSH only
--   MoneyMult                            payments you collect
--   WalletBonusMult                      your shift-end wallet deposit
--   SeatBonusFraction                    seated bar +fraction when you seat
--   OrderBonusFraction                   seated bar +fraction when you take an order
--   RecommendBonusMult                   your recommendation patience bonus
--   ServeBonusMult                       per-dish serve patience bonus
--   PerfectBonusFraction                 Perfect dish you cook adds this x a
--                                        dish's value to the till
--   StreakBonusStep                      each Perfect in a row adds this more
--   FillHoldMult                         pitcher fill hold time
--   ChargeMult                           ultimate charge earned
--   CooldownMult                         Q / R cooldowns
--   CarryBonus                           extra carry slots (a COUNT)
--
-- THE LAW: nothing here touches cook times or PERFECT windows.
----------------------------------------------------------------
Config.Passives = {
	SlotCount = 1,

	--// STUDIO ONLY (live-ignored): force this passive on every Studio
	--// player for testing, whatever the save says. "" = off.
	StudioEquip = "",

	--// Fixed rarity odds (crate system). A rarity's chance never changes
	--// however many passives sit inside it; its passives split it evenly.
	Rarities = {
		Common    = { Order = 1, Weight = 62, Color = Color3.fromRGB(214, 206, 196) },
		Rare      = { Order = 2, Weight = 32, Color = Color3.fromRGB(74, 144, 226) },
		Epic      = { Order = 3, Weight = 5,  Color = Color3.fromRGB(155, 89, 214) },
		Legendary = { Order = 4, Weight = 1,  Color = Color3.fromRGB(255, 196, 46) },
	},
	PityEpic = 30,        -- Epic or better guaranteed within this many crates
	PityLegendary = 80,   -- Legendary guaranteed within this many crates

	HotStreakCap = 10,    -- Hot Streak stops growing after this many Perfects in a row

	--// What "no passive" means for each attribute
	Defaults = {
		StaminaDrainMult = 1, StaminaRegenMult = 1, WalkSpeedMult = 1,
		RushSpeedMult = 1, MoneyMult = 1, WalletBonusMult = 1,
		SeatBonusFraction = 0, OrderBonusFraction = 0, RecommendBonusMult = 1,
		ServeBonusMult = 1, PerfectBonusFraction = 0, StreakBonusStep = 0,
		FillHoldMult = 1, ChargeMult = 1, CooldownMult = 1, CarryBonus = 0,
	},

	--// Display order (also the crate odds table order)
	Order = {
		"SecondWind", "Waterboy", "SeatMaster", "OrderAce", "SmoothTalker",
		"LightFeet", "RushHourHero", "FastService", "ChefsKiss", "ChargedUp",
		"QuickStep", "HotStreak", "SilverTongue", "QuickRecharge",
		"Overtime", "BigPockets",
	},

	List = {
		--// COMMON
		SecondWind = { Display = "Second Wind", Rarity = "Common", Icon = "",
			Description = "Stamina refills 25% faster",
			Effects = { StaminaRegenMult = 1.25 } },
		Waterboy = { Display = "Waterboy", Rarity = "Common", Icon = "",
			Description = "Fill the water pitcher 35% faster",
			Effects = { FillHoldMult = 1 / 1.35 } },
		SeatMaster = { Display = "Seat Master", Rarity = "Common", Icon = "",
			Description = "Parties you seat get 10% more patience",
			Effects = { SeatBonusFraction = 0.10 } },
		OrderAce = { Display = "Order Ace", Rarity = "Common", Icon = "",
			Description = "Orders you take give 10% more patience",
			Effects = { OrderBonusFraction = 0.10 } },
		SmoothTalker = { Display = "Smooth Talker", Rarity = "Common", Icon = "",
			Description = "Your recommendations calm tables 35% more",
			Effects = { RecommendBonusMult = 1.35 } },

		--// RARE
		LightFeet = { Display = "Light Feet", Rarity = "Rare", Icon = "",
			Description = "Sprint drains 20% slower",
			Effects = { StaminaDrainMult = 0.80 } },
		RushHourHero = { Display = "Rush Hour Hero", Rarity = "Rare", Icon = "",
			Description = "Move 12% faster during the RUSH",
			Effects = { RushSpeedMult = 1.12 } },
		FastService = { Display = "Fast Service", Rarity = "Rare", Icon = "",
			Description = "Dishes you serve give 30% more patience",
			Effects = { ServeBonusMult = 1.30 } },
		ChefsKiss = { Display = "Chef's Kiss", Rarity = "Rare", Icon = "",
			Description = "Perfect dishes you cook earn 15% extra",
			Effects = { PerfectBonusFraction = 0.15 } },
		ChargedUp = { Display = "Charged Up", Rarity = "Rare", Icon = "",
			Description = "Your ultimate charges 15% faster",
			Effects = { ChargeMult = 1.15 } },

		--// EPIC
		QuickStep = { Display = "Quick Step", Rarity = "Epic", Icon = "",
			Description = "Move 7% faster, always",
			Effects = { WalkSpeedMult = 1.07 } },
		HotStreak = { Display = "Hot Streak", Rarity = "Epic", Icon = "",
			Description = "Each Perfect in a row earns 4% more, a miss resets it",
			Effects = { StreakBonusStep = 0.04 } },
		SilverTongue = { Display = "Silver Tongue", Rarity = "Epic", Icon = "",
			Description = "Payments you collect are worth 12% more",
			Effects = { MoneyMult = 1.12 } },
		QuickRecharge = { Display = "Quick Recharge", Rarity = "Epic", Icon = "",
			Description = "Q and R cool down 15% faster",
			Effects = { CooldownMult = 0.85 } },

		--// LEGENDARY
		Overtime = { Display = "Overtime", Rarity = "Legendary", Icon = "",
			Description = "15% bonus coins into your wallet every shift",
			Effects = { WalletBonusMult = 1.15 } },
		BigPockets = { Display = "Big Pockets", Rarity = "Legendary", Icon = "",
			Description = "Carry 3 items instead of 2",
			Effects = { CarryBonus = 1 } },
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

		--// PASSIVES (Oct 2026): owned set + the one equipped (Config.Passives)
		OwnedPassives = {},           -- ["LightFeet"] = true
		EquippedPassive = "",         -- "" = none

		--// Cumulative, lifetime. Single-shift challenge counts live in server
		--// memory (spec 4) - only their completions land here.
		TaskProgress = {
			PerfectCooks = 0,
			DishesServed = 0,
			EventChannels = 0,
			PaymentsCollected = 0,
			Greetings = 0,
			Recommendations = 0,
			MessesCleaned = 0,
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

		--// THE SHIFT LOG (Oct 2026): the most recent shifts, NEWEST FIRST,
		--// trimmed to PlayerStats.RecentShiftsCap at insert - your own coin
		--// share, title and MVP ride along with the shift's grade.
		RecentShifts = {},

		--// Absorbed from the lobby (spec 3) - one profile per player, not one
		--// per feature. Neither system is built yet; the keys are here so the
		--// schema does not need a migration when they are.
		RedeemedCodes = {},           -- ["CODE"] = true
		DailyGift = { LastClaim = 0, Streak = 0 },

		--// ROBUX RECEIPTS (Oct 2026): the PurchaseId of every developer-product
		--// receipt already granted, newest last, capped at
		--// Config.Monetization.PurchaseIdCacheSize. This is what makes a grant
		--// happen EXACTLY ONCE - Roblox retries receipts, and a retry whose id
		--// is already here is confirmed without granting twice.
		PurchaseIdCache = {},
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

	--// PLAYTEST WALLET GRANT (Sep 19): named players are topped up to
	--// GrantWallet coins whenever they load below it, so testers can buy
	--// and equip any class. Works on LIVE servers (the real DataStore),
	--// not just Studio. ONLY the usernames listed get it - never public
	--// players. Empty the list (or set Enabled = false) after the
	--// playtest. This writes to the REAL save, exactly like a shift's
	--// earnings would.
	PlaytestGrant = {
		Enabled = true,
		GrantWallet = 10000,

		--// PLAYTEST: give the 10k to EVERY player who joins, so no name
		--// list to maintain. Set false to fall back to the Usernames list.
		GrantEveryone = true,

		--// Only used when GrantEveryone = false: exact Roblox usernames
		--// (case-insensitive) that get the wallet grant.
		Usernames = {
			"Uneven876",
			"no_wayyman12",
			"Kenny_ze",
			"raptor_Rexz96",
			"JordonChia0019",
			"WingzXYZ",
			"M2RichU2Poor",
			"YoloaXD",
		},

		--// PLAYTEST: unlock EVERY class for EVERY player who joins, so any
		--// class can be equipped without buying. Written to the REAL save.
		--// Set false after the playtest.
		UnlockAllClasses = true,
	},
}

----------------------------------------------------------------
-- MONETIZATION (Oct 2026): game passes + developer products.
-- ServerStorage.Shared.Purchases is the ONLY code that grants anything
-- bought with Robux, and it trusts nothing the client says:
--   * pass ownership is asked of Roblox (UserOwnsGamePassAsync), server-side
--   * products are granted only from Roblox's ProcessReceipt callback
--   * every receipt is saved before Roblox is told "granted" (exactly once)
-- Id = the asset id from the Creator Hub. 0 = not created yet: never
-- prompted, never owned. PRICES live on the Creator Hub, not here - the
-- shop reads the real price from Roblox so it can never show a wrong one.
----------------------------------------------------------------
Config.Monetization = {
	--// One-time buys. Perks are wired per pass in a later step (the owner
	--// checks in first); ownership itself is already exploit-safe.
	--// Shop display fields (ShopClient): Order sorts the cards, Emoji is the
	--// placeholder art until Image (an uploaded asset id) is set.
	GamePasses = {
		VIP = {
			Id = 0,
			Display = "VIP",
			Description = "Gold name tag, VIP outfit, and +25% coins from every shift",
			Emoji = "👑", Image = "rbxassetid://104590028335428", Order = 1,
		},
		DoubleCoins = {
			Id = 0,
			Display = "2x Coins",
			Description = "Double the coins you take home from every shift",
			Emoji = "💰", Image = "rbxassetid://116464553241999", Order = 2,
			Badge = "2x", -- a live sticker over the art (the badge art has no text)
		},
	},

	--// Repeatable buys. Coins = how many coins land in the wallet per buy.
	--// Featured = the big "best value" card on top of the Coins tab.
	Products = {
		CoinsSmall  = { Id = 0, Display = "Pile of Coins",  Coins = 500,
			Emoji = "🪙", Image = "rbxassetid://125974545023323", Order = 1 },
		CoinsMedium = { Id = 0, Display = "Bag of Coins",   Coins = 1200,
			Emoji = "💰", Image = "rbxassetid://118410203960355", Order = 2 },
		CoinsLarge  = { Id = 0, Display = "Chest of Coins", Coins = 3000,
			Emoji = "🧰", Image = "rbxassetid://119886693973918", Order = 3 },
		CoinsHuge   = { Id = 0, Display = "Vault of Coins", Coins = 7000,
			Emoji = "🏦", Image = "rbxassetid://87812219301694", Order = 4, Featured = true },
	},

	--// THE SHOP'S ART SLOTS (Oct 2026). "" = the code-drawn placeholder;
	--// paste an uploaded asset id and that piece swaps to the art. Frames
	--// are 9-SLICED: SliceCenter is the stretchable middle rectangle, in
	--// the image's own pixels (Rect min x, min y, max x, max y) - the
	--// corners outside it never stretch. Defaults assume the art kit sizes.
	--// Size = the art's real pixel size (keeps it from squashing, and lets a
	--// 9-sliced frame's border scale with the screen instead of staying a
	--// fixed pixel width). Slice margins measured off the Oct 2026 art kit:
	--// the panel's brass brackets reach ~190px in from each corner.
	--// The Claude Design kit, uploaded Oct 3 2026 (all 32 pieces).
	ShopArt = {
		--// UI CHROME
		PanelFrame       = { Image = "rbxassetid://71849129735816", Size = { 1024, 768 }, Slice = { 200, 200, 824, 568 } },
		HeaderBanner     = { Image = "rbxassetid://136905996885475", Size = { 1024, 256 } },
		TabNormal        = { Image = "rbxassetid://136449305431332", Size = { 512, 256 } },
		TabSelected      = { Image = "rbxassetid://104735560951465", Size = { 512, 256 } },
		ItemCard         = { Image = "rbxassetid://87321545300427", Size = { 512, 640 }, Slice = { 100, 100, 412, 540 } },
		PriceButtonGreen = { Image = "rbxassetid://123410306061261", Size = { 512, 160 }, Slice = { 90, 50, 422, 110 } },
		PriceButtonRed   = { Image = "rbxassetid://83633335950601", Size = { 512, 160 }, Slice = { 90, 50, 422, 110 } }, -- spare (sales later)
		ValueRibbon      = { Image = "rbxassetid://87427359069158", Size = { 256, 384 } },
		CloseButton      = { Image = "rbxassetid://112978255081941", Size = { 256, 256 } },
		TabIconCoins     = { Image = "rbxassetid://120823836721388", Size = { 256, 256 } },
		TabIconPasses    = { Image = "rbxassetid://83044944920425", Size = { 256, 256 } },

		--// EFFECT SPRITES (animated by ShopClient)
		Sparkle          = { Image = "rbxassetid://92980179345226" },  -- twinkles around the featured pack
		FlyingCoin       = { Image = "rbxassetid://115974605149441" }, -- the purchase coin shower
		Sunburst         = { Image = "rbxassetid://112163141616210" }, -- spins behind the featured pack
		SoftGlow         = { Image = "rbxassetid://79101323592617" },  -- light behind every item
		ShineStreak      = { Image = "rbxassetid://115962591494823" },  -- sweeps across the featured card
		Confetti         = { Image = "rbxassetid://103368211838664" },  -- bursts on a purchase
		PopBurst         = { Image = "rbxassetid://81311264549915" },  -- behind the "+coins!" toast

		--// DECORATION
		BistroLights       = { Image = "rbxassetid://94462767630414" }, -- draped over the top, twinkling
		CornerDoodleBurger = { Image = "rbxassetid://118171122286345" }, -- doodles peek round the frame
		CornerDoodleDonut  = { Image = "rbxassetid://97739279838669" },
		CornerDoodleTomato = { Image = "rbxassetid://124288556727329" },
		CornerDoodleCoffee = { Image = "rbxassetid://127239302734501" },
		SteamWisp          = { Image = "rbxassetid://84651089737744" }, -- rises off the coffee
		PanelPattern       = { Image = "rbxassetid://138066682536474" },  -- quiet tile behind the content
		OwnedStamp         = { Image = "rbxassetid://104033637720670" },  -- slams onto owned passes
	},
	FeaturedRibbonText = "BEST VALUE!",

	--// how many recent receipt ids the save remembers (the double-grant guard)
	PurchaseIdCacheSize = 100,
	--// per-player gap between purchase PROMPT requests (anti-spam)
	PromptCooldownSeconds = 1.5,
	--// how long a pass-ownership answer from Roblox is trusted before re-asking
	PassCacheSeconds = 300,
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
